import 'package:flutter/painting.dart';

/// Splits one chapter's styled text into page-sized [TextSpan]s for the novel
/// reader's paginated (book) mode.
///
/// The chapter comes in as a single [TextSpan] whose children carry the inline
/// styling (bold/italic runs). We flatten that tree into styled runs, lay the
/// text out with a [TextPainter] at `pageSize.width`, and binary-search the
/// character offset whose laid-out height first exceeds `pageSize.height` —
/// cutting on a word boundary where possible (and never inside a UTF-16
/// surrogate pair). Styling is preserved because each page is rebuilt from the
/// same runs, sliced at the chosen offsets, so a bold run stays bold on
/// whatever page it lands on.
///
/// Pure — no widgets, only `painting` (`TextPainter`/`TextSpan`/`Size`). The
/// critical invariant, covered by tests: concatenating every returned page's
/// [TextSpan.toPlainText] equals the source text, so no character is ever
/// dropped or duplicated (pages are contiguous, non-overlapping substrings).
///
/// [WidgetSpan]s are not supported (a `TextPainter` can't lay one out without
/// placeholder sizes) — the paged view feeds a pure-text span tree, so
/// paragraph-spacing gaps are represented as `\n`, not widget gaps.
List<TextSpan> paginateSpans(
  TextSpan chapter, {
  required Size pageSize,
  required TextStyle style,
}) {
  final runs = <_Run>[];
  _collect(chapter, style, runs);

  final buffer = StringBuffer();
  for (final r in runs) {
    buffer.write(r.text);
  }
  final text = buffer.toString();
  if (text.isEmpty) {
    return [TextSpan(style: style, children: const [])];
  }

  final pages = <TextSpan>[];
  var start = 0;
  while (start < text.length) {
    final end = _pageEnd(runs, text, start, pageSize, style);
    pages.add(_slice(runs, start, end, style));
    start = end;
  }
  return pages;
}

/// A contiguous chunk of text sharing one resolved style.
class _Run {
  const _Run(this.text, this.style);
  final String text;
  final TextStyle style;
}

/// Flattens the span tree into ordered runs, resolving each child's style
/// against its inherited style so the slice output re-lays-out identically.
void _collect(InlineSpan span, TextStyle inherited, List<_Run> out) {
  if (span is! TextSpan) return; // WidgetSpan/other: unsupported in paged text
  final resolved = span.style == null ? inherited : inherited.merge(span.style);
  final text = span.text;
  if (text != null && text.isNotEmpty) out.add(_Run(text, resolved));
  final children = span.children;
  if (children != null) {
    for (final child in children) {
      _collect(child, resolved, out);
    }
  }
}

/// Rebuilds the `[start, end)` character range of the runs into a page span,
/// keeping each run's style so inline styling survives the split.
TextSpan _slice(List<_Run> runs, int start, int end, TextStyle style) {
  final children = <InlineSpan>[];
  var offset = 0;
  for (final r in runs) {
    final rStart = offset;
    final rEnd = offset + r.text.length;
    offset = rEnd;
    if (rEnd <= start) continue;
    if (rStart >= end) break;
    final s = start > rStart ? start - rStart : 0;
    final e = end < rEnd ? end - rStart : r.text.length;
    children.add(TextSpan(text: r.text.substring(s, e), style: r.style));
  }
  return TextSpan(style: style, children: children);
}

double _height(TextSpan span, double maxWidth) {
  final tp = TextPainter(
    text: span,
    textDirection: TextDirection.ltr,
    maxLines: null,
  )..layout(maxWidth: maxWidth);
  final h = tp.height;
  tp.dispose();
  return h;
}

/// Largest end offset (> [start]) whose laid-out slice still fits the page
/// height, backed off to a word boundary. Always makes progress (returns at
/// least `start + 1`) so pagination can't loop even on a degenerate page size.
int _pageEnd(
  List<_Run> runs,
  String text,
  int start,
  Size pageSize,
  TextStyle style,
) {
  final total = text.length;
  bool fits(int end) =>
      _height(_slice(runs, start, end, style), pageSize.width) <=
      pageSize.height;

  if (fits(total)) return total; // whole remainder fits: last page

  var lo = start + 1;
  var hi = total; // known not to fit
  var best = start + 1; // guarantees forward progress
  while (lo < hi) {
    final mid = lo + ((hi - lo) >> 1);
    if (fits(mid)) {
      best = mid;
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }

  final boundary = _wordBoundary(text, start, best);
  var end = boundary > start ? boundary : best;
  // Never leave a page ending on a lone high surrogate.
  if (end > start &&
      end < total &&
      _isLowSurrogate(text.codeUnitAt(end)) &&
      _isHighSurrogate(text.codeUnitAt(end - 1))) {
    end -= 1;
    if (end <= start) end = best;
  }
  return end;
}

/// Position just after the last whitespace in `(start, end]`, so the page
/// breaks between words with the space kept on the current page. Returns [end]
/// unchanged when the range holds no break opportunity (one long word).
int _wordBoundary(String text, int start, int end) {
  for (var i = end; i > start; i--) {
    final ch = text.codeUnitAt(i - 1);
    if (ch == 0x20 || ch == 0x0A || ch == 0x09) return i;
  }
  return end;
}

bool _isHighSurrogate(int c) => c >= 0xD800 && c <= 0xDBFF;
bool _isLowSurrogate(int c) => c >= 0xDC00 && c <= 0xDFFF;
