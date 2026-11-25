/// Moves every cue of a subtitle file by [deltaMs] (positive = later).
///
/// Handles SRT and WebVTT (`00:01:02,500 --> …` / `00:01:02.500 --> …`) and
/// ASS/SSA (`Dialogue:` lines). Anything that isn't a timing line is left
/// alone, and a time pushed before zero stops at zero.
String shiftSubtitle(String content, int deltaMs) {
  if (deltaMs == 0) return content;
  return content.contains('[Events]')
      ? _shiftAss(content, deltaMs)
      : _shiftTimed(content, deltaMs);
}

final _stamp = RegExp(
  r'(?:(\d{1,2}):)?(\d{1,2}):(\d{2})([.,])(\d{3})\s*-->\s*'
  r'(?:(\d{1,2}):)?(\d{1,2}):(\d{2})([.,])(\d{3})',
);

int _ms(String? h, String m, String s, String ms) =>
    ((int.parse(h ?? '0') * 60 + int.parse(m)) * 60 + int.parse(s)) * 1000 +
    int.parse(ms);

String _fmt(int total, String sep) {
  final t = total < 0 ? 0 : total;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(t ~/ 3600000)}:${two(t ~/ 60000 % 60)}:${two(t ~/ 1000 % 60)}'
      '$sep${(t % 1000).toString().padLeft(3, '0')}';
}

String _shiftTimed(String content, int deltaMs) =>
    content.replaceAllMapped(_stamp, (m) {
      final start = _ms(m[1], m[2]!, m[3]!, m[5]!) + deltaMs;
      final end = _ms(m[6], m[7]!, m[8]!, m[10]!) + deltaMs;
      return '${_fmt(start, m[4]!)} --> ${_fmt(end, m[9]!)}';
    });

final _dialogue = RegExp(
  r'^(Dialogue:[^,]*,)(\d+):(\d{2}):(\d{2})\.(\d{2}),(\d+):(\d{2}):(\d{2})\.(\d{2})',
  multiLine: true,
);

String _shiftAss(String content, int deltaMs) =>
    content.replaceAllMapped(_dialogue, (m) {
      String stamp(String h, String mi, String s, String cs, int delta) {
        final total = (_ms(h, mi, s, '${cs}0') + delta).clamp(0, 1 << 40);
        final h2 = total ~/ 3600000;
        return '$h2:${(total ~/ 60000 % 60).toString().padLeft(2, '0')}:'
            '${(total ~/ 1000 % 60).toString().padLeft(2, '0')}.'
            '${(total % 1000 ~/ 10).toString().padLeft(2, '0')}';
      }

      return '${m[1]}${stamp(m[2]!, m[3]!, m[4]!, m[5]!, deltaMs)},'
          '${stamp(m[6]!, m[7]!, m[8]!, m[9]!, deltaMs)}';
    });
