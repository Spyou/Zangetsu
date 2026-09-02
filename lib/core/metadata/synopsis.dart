/// Turns a provider's synopsis into something a person can read.
///
/// AniList is the reason this exists. Its `description(asHtml:false)` still
/// answers with `<br>` tags AND real newlines around them, so the page showed
/// the tags literally, separated by blank lines:
///
///     "In order for something to be obtained..."
///     <br><br>
///     Alchemy is bound by this Law...
///
/// It also mixes in a little markup of its own — `__bold__` and `~!spoiler!~`
/// — and HTML entities survive the round trip.
///
/// Paragraphs are kept, unlike the card cleaner in `airing_service.dart`,
/// which flattens everything to one line on purpose because it has two lines
/// of room. A full synopsis without its paragraph breaks is a wall of text.
String? cleanSynopsis(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;

  var text = raw
      .replaceAll('\r\n', '\n')
      // Tags first, and to a newline rather than a space: they ARE the
      // paragraph breaks in AniList's copy.
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</?p\s*/?>', caseSensitive: false), '\n\n')
      .replaceAll(RegExp(r'<[^>]+>'), '');

  const entities = {
    '&amp;': '&',
    '&lt;': '<',
    '&gt;': '>',
    '&quot;': '"',
    '&#039;': "'",
    '&apos;': "'",
    '&nbsp;': ' ',
    '&mdash;': '—',
    '&ndash;': '–',
    '&hellip;': '…',
  };
  entities.forEach((k, v) => text = text.replaceAll(k, v));

  text = text
      // AniList's own markup. The markers go, the words stay — a hidden
      // spoiler is the reader's call to make, and dropping the sentence
      // outright can gut a synopsis that is mostly one.
      .replaceAll(RegExp(r'~!|!~'), '')
      .replaceAll('__', '')
      // Trailing spaces on a line become a visible ragged edge once the
      // paragraph breaks are real.
      .split('\n')
      .map((l) => l.trimRight())
      .join('\n')
      // Three or more newlines is the <br><br>-plus-real-newlines case.
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();

  return text.isEmpty ? null : text;
}
