import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import '../models/video_source.dart';

/// Cross-encode subtitle timing when MegaPlay (etc.) serves captions timed to
/// a different pack than the playing video — typically dub video + sub VTT.
///
/// MegaPlay `getSources` exposes per-pack `intro` / `outro`. When the packs
/// share the same pre-OP start but different OP lengths, post-OP dialogue on
/// the longer pack is shifted by `playing.intro.end - vttPack.intro.end`.
/// That delta is measured from the source, not a hardcoded delay.

/// Refine a pack-marker skew using the VTT's real OP gap.
///
/// MegaPlay `intro.end` marks when *content* resumes on the playing cut.
/// The VTT's first cue after its OP silence is that same moment on the caption
/// timeline — their difference is the post-OP shift. Using sibling `intro.end`
/// alone over-corrects when that marker sits a few seconds before dialogue.
({double seconds, double afterSeconds})? refineSubtitleSkewWithVttGap({
  required String vttText,
  required double playingIntroEnd,
  double minAbs = 5,
  double maxAbs = 45,
}) {
  final gap = vttOpeningGapSeconds(vttText);
  if (gap == null) return null;
  final skew = playingIntroEnd - gap.afterStart;
  if (skew.abs() < minAbs || skew.abs() > maxAbs) return null;
  return (seconds: skew, afterSeconds: gap.afterStart);
}

/// Fallback when the VTT cannot be inspected: intro.end delta between packs
/// (outro tails often differ and must not be averaged in).
({double seconds, double afterSeconds})? subtitleSkewFromPackIntros({
  required double? playingIntroEnd,
  required double? vttPackIntroEnd,
  double? playingOutroStart,
  double? vttPackOutroStart,
  double minAbs = 5,
  double maxAbs = 45,
}) {
  final introEnd = playingIntroEnd;
  final vttEnd = vttPackIntroEnd;
  double? skew;
  double? after;
  if (introEnd != null && vttEnd != null) {
    skew = introEnd - vttEnd;
    after = vttEnd;
  } else if (playingOutroStart != null && vttPackOutroStart != null) {
    skew = playingOutroStart - vttPackOutroStart;
    after = vttPackIntroEnd ?? 0;
  }
  if (skew == null) return null;
  if (skew.abs() < minAbs || skew.abs() > maxAbs) return null;
  return (seconds: skew, afterSeconds: after ?? 0);
}

/// Largest ≥[minGap] silence in the first [window] seconds of a WebVTT file.
/// Returns `(beforeEnd, afterStart)` of that opening gap, or null.
({double beforeEnd, double afterStart})? vttOpeningGapSeconds(
  String vtt, {
  double window = 400,
  double minGap = 60,
}) {
  final starts = <double>[];
  final ends = <double>[];
  final re = RegExp(
    r'((?:\d{1,2}:)?\d{1,2}:\d{2}[.,]\d{1,3})\s*-->\s*'
    r'((?:\d{1,2}:)?\d{1,2}:\d{2}[.,]\d{1,3})',
  );
  for (final m in re.allMatches(vtt)) {
    final a = _vttTs(m.group(1)!);
    final b = _vttTs(m.group(2)!);
    if (a == null || b == null || b <= a) continue;
    if (a > window) break;
    starts.add(a);
    ends.add(b);
  }
  if (starts.length < 4) return null;
  var bestI = -1;
  var bestGap = 0.0;
  for (var i = 1; i < starts.length; i++) {
    final gap = starts[i] - ends[i - 1];
    if (gap >= minGap && gap > bestGap) {
      bestGap = gap;
      bestI = i;
    }
  }
  if (bestI < 0) return null;
  return (beforeEnd: ends[bestI - 1], afterStart: starts[bestI]);
}

double? _vttTs(String raw) {
  final s = raw.replaceAll(',', '.');
  final parts = s.split(':');
  if (parts.isEmpty) return null;
  final last = parts.last.split('.');
  final sec = double.tryParse(last[0]);
  if (sec == null) return null;
  final frac = last.length > 1 ? double.tryParse('0.${last[1]}') ?? 0 : 0;
  if (parts.length == 3) {
    final h = double.tryParse(parts[0]);
    final m = double.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return h * 3600 + m * 60 + sec + frac;
  }
  if (parts.length == 2) {
    final m = double.tryParse(parts[0]);
    if (m == null) return null;
    return m * 60 + sec + frac;
  }
  return sec + frac;
}

/// Shift WebVTT/SRT cue timestamps by [skewSeconds] when cue start ≥ [afterSeconds].
String applySubtitleSkewToText(
  String raw, {
  required double skewSeconds,
  double afterSeconds = 0,
}) {
  if (skewSeconds.abs() < 0.05) return raw;
  final re = RegExp(
    r'((?:\d{1,2}:)?\d{1,2}:\d{2}[.,]\d{1,3})\s*-->\s*'
    r'((?:\d{1,2}:)?\d{1,2}:\d{2}[.,]\d{1,3})',
  );
  return raw.replaceAllMapped(re, (m) {
    final a = _vttTs(m.group(1)!);
    final b = _vttTs(m.group(2)!);
    if (a == null || b == null) return m.group(0)!;
    if (a < afterSeconds) return m.group(0)!;
    final comma = m.group(1)!.contains(',');
    return '${_fmtTs(a + skewSeconds, comma: comma)} --> '
        '${_fmtTs(b + skewSeconds, comma: comma)}';
  });
}

String _fmtTs(double t, {required bool comma}) {
  if (t < 0) t = 0;
  final h = t ~/ 3600;
  final m = (t % 3600) ~/ 60;
  final s = t % 60;
  final whole = s.floor();
  final ms = ((s - whole) * 1000).round().clamp(0, 999);
  final sep = comma ? ',' : '.';
  final body =
      '${m.toString().padLeft(2, '0')}:'
      '${whole.toString().padLeft(2, '0')}$sep'
      '${ms.toString().padLeft(3, '0')}';
  if (h > 0) return '${h.toString().padLeft(2, '0')}:$body';
  return '00:$body';
}

/// Download provider softsubs, bake [VideoSource.subtitleSkewSeconds] into
/// local files, and clear the skew fields so players do not double-apply.
Future<VideoSource> materializeSkewedSubtitles(VideoSource src) async {
  final baseSkew = src.subtitleSkewSeconds ?? 0;
  if (baseSkew.abs() < 0.05 || src.subtitles.isEmpty) return src;
  final baseAfter = src.subtitleSkewAfterSeconds ?? 0;
  final playingIntroEnd = baseAfter + baseSkew;
  final dir = Directory(
    '${(await getTemporaryDirectory()).path}/zangetsu_sub_skew',
  );
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
      responseType: ResponseType.plain,
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
            'AppleWebKit/537.36 (KHTML, like Gecko) '
            'Chrome/122.0.0.0 Safari/537.36',
        ...?src.headers,
      },
    ),
  );
  final out = <Subtitle>[];
  for (var i = 0; i < src.subtitles.length; i++) {
    final s = src.subtitles[i];
    try {
      final res = await dio.get<String>(s.url);
      final text = res.data;
      if (text == null || text.trim().isEmpty) {
        out.add(s);
        continue;
      }
      var skew = baseSkew;
      var after = baseAfter;
      final gapOnly = refineSubtitleSkewWithVttGap(
        vttText: text,
        playingIntroEnd: playingIntroEnd,
      );
      if (gapOnly != null) {
        skew = (baseSkew + gapOnly.seconds) / 2;
      }
      final skewed = applySubtitleSkewToText(
        text,
        skewSeconds: skew,
        afterSeconds: after,
      );
      final ext = (s.format == 'srt' || s.url.toLowerCase().contains('.srt'))
          ? 'srt'
          : 'vtt';
      final path = '${dir.path}/s${src.url.hashCode.abs()}_$i.$ext';
      await File(path).writeAsString(skewed);
      out.add(
        Subtitle(
          url: path,
          lang: s.lang,
          label: s.label,
          format: s.format ?? ext,
          isDefault: s.isDefault,
        ),
      );
    } catch (_) {
      out.add(s);
    }
  }
  return VideoSource(
    url: src.url,
    quality: src.quality,
    label: src.label,
    container: src.container,
    headers: src.headers,
    kind: src.kind,
    audioLang: src.audioLang,
    subtitles: out,
    proxyUrl: src.proxyUrl,
    drmKid: src.drmKid,
    drmKey: src.drmKey,
  );
}
