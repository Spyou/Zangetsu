/// One fetched WebVTT segment of an HLS subtitle rendition.
class VttSegment {
  const VttSegment({required this.text, required this.startSeconds});

  final String text;

  /// Where this segment begins on the media timeline, summed from the
  /// playlist's `#EXTINF` durations.
  final double startSeconds;
}

final RegExp _cueLine = RegExp(
  r'^((?:\d+:)?\d{1,2}:\d{2}[.,]\d{1,3})\s*-->\s*((?:\d+:)?\d{1,2}:\d{2}[.,]\d{1,3})(.*)$',
);

/// Seconds for a `HH:MM:SS.mmm` / `MM:SS.mmm` timestamp, or null if unparseable.
double? parseVttTimestamp(String s) {
  final parts = s.trim().replaceAll(',', '.').split(':');
  if (parts.length < 2 || parts.length > 3) return null;
  final secs = double.tryParse(parts.last);
  if (secs == null) return null;
  final mins = int.tryParse(parts[parts.length - 2]);
  if (mins == null) return null;
  final hours = parts.length == 3 ? int.tryParse(parts[0]) : 0;
  if (hours == null) return null;
  return hours * 3600 + mins * 60 + secs;
}

String _fmt(double t) {
  final clamped = t < 0 ? 0.0 : t;
  final h = clamped ~/ 3600;
  final m = (clamped % 3600) ~/ 60;
  final s = clamped % 60;
  final ss = s.toStringAsFixed(3).padLeft(6, '0');
  return '${h.toString().padLeft(2, '0')}:'
      '${m.toString().padLeft(2, '0')}:$ss';
}

/// Joins HLS WebVTT segments into one playable file.
///
/// Not a concatenation. Every segment carries its own `WEBVTT` header and an
/// `X-TIMESTAMP-MAP`, and a player stops at the second header it meets — glue
/// them together and you get the first few seconds of subtitles and nothing
/// after, which looks exactly like "subtitles are broken".
///
/// Segment cue times come in two flavours and the playlist does not say which:
///   * ALREADY on the media timeline (the common VOD case) — kept as they are;
///   * relative to the segment's own start — shifted by [VttSegment.startSeconds].
///
/// Told apart by looking: a segment whose cues start a full second before the
/// segment itself does cannot be on the media timeline, so it must be relative.
/// Judged per segment, because a stream can be inconsistent.
///
/// Cue payloads, positioning settings and `NOTE` blocks pass through untouched.
String mergeWebVtt(List<VttSegment> segments) {
  final out = StringBuffer('WEBVTT\n');
  for (final seg in segments) {
    final lines = seg.text.split(RegExp(r'\r?\n'));

    // Does this segment speak in its own time, or the media's?
    var earliest = double.infinity;
    for (final line in lines) {
      final m = _cueLine.firstMatch(line.trim());
      if (m == null) continue;
      final t = parseVttTimestamp(m.group(1)!);
      if (t != null && t < earliest) earliest = t;
    }
    final relative =
        earliest.isFinite && earliest + 1.0 < seg.startSeconds;
    final offset = relative ? seg.startSeconds : 0.0;

    var wroteAnything = false;
    for (final raw in lines) {
      final line = raw.trimRight();
      final t = line.trim();
      // Each segment's own header and timing map belong to that segment only.
      if (t.startsWith('WEBVTT')) continue;
      if (t.startsWith('X-TIMESTAMP-MAP')) continue;
      final m = _cueLine.firstMatch(t);
      if (m != null) {
        final start = parseVttTimestamp(m.group(1)!);
        final end = parseVttTimestamp(m.group(2)!);
        if (start == null || end == null) continue; // malformed cue — drop it
        if (!wroteAnything) out.write('\n');
        wroteAnything = true;
        out.writeln(
          '${_fmt(start + offset)} --> ${_fmt(end + offset)}${m.group(3)}',
        );
        continue;
      }
      if (t.isEmpty && !wroteAnything) continue; // eat the header's blank lines
      if (wroteAnything) out.writeln(line);
    }
  }
  return out.toString();
}
