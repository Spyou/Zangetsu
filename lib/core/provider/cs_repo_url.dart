/// Cleans up a repository link the user pasted before it is fetched.
///
/// People paste from browsers, Discord, Telegram and GitHub, and what arrives
/// is often not a bare URL: it comes wrapped in quotes or angle brackets, with
/// a trailing full stop from a sentence, or missing its scheme entirely. Our
/// fetch hands the string straight to `java.net.URL`, which rejects anything
/// without a scheme outright, so those pastes fail with an error that looks
/// like the repo is broken.
///
/// Modelled on CloudStream's own `RepositoryManager.parseRepoUrl`, which
/// accepts `http(s)://` as-is and rewrites its `cloudstreamrepo://` and
/// `https://cs.repo/?` link formats to https. Two deliberate differences:
///
///  * CloudStream REJECTS a scheme-less link (its short-code pattern allows no
///    dots or slashes, so `github.com/u/r.json` matches nothing and returns
///    null). We prepend `https://` instead — it's the single most common paste
///    and there's no ambiguity about what was meant.
///  * CloudStream also resolves bare short codes through cutt.ly / py.md. That
///    needs a network round-trip and two third-party services, so it's not
///    handled here.
///
/// NEVER rejects. Anything it can't improve is returned trimmed and unchanged,
/// so every link that worked before still works and the caller's own error
/// handling is untouched.
String normalizeCsRepoUrl(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return s;

  // Zero-width characters ride along on copies from chat clients and web pages
  // and are invisible in the field, so a "correct-looking" URL fails.
  s = s.replaceAll(RegExp(r'[​-‍﻿]'), '').trim();

  // Markdown/Discord wrap links in <> to suppress previews; chat and docs wrap
  // them in quotes. Strip a matched pair, repeatedly (quoted angle brackets).
  var stripped = true;
  while (stripped && s.length > 1) {
    stripped = false;
    for (final pair in const [
      ['<', '>'],
      ['"', '"'],
      ["'", "'"],
      ['`', '`'],
      ['“', '”'], // smart double quotes
      ['‘', '’'], // smart single quotes
    ]) {
      if (s.startsWith(pair[0]) && s.endsWith(pair[1])) {
        s = s.substring(1, s.length - 1).trim();
        stripped = true;
        break;
      }
    }
  }

  // Sentence punctuation dragged in from prose. A closing bracket is only
  // dropped when nothing opened it, since it can legitimately end a URL.
  while (s.isNotEmpty) {
    final last = s[s.length - 1];
    final isStray =
        last == '.' ||
        last == ',' ||
        last == ';' ||
        last == '!' ||
        ((last == ')' || last == ']') &&
            !s.contains(last == ')' ? '(' : '['));
    if (!isStray) break;
    s = s.substring(0, s.length - 1).trim();
  }

  if (s.isEmpty) return s;

  // CloudStream's own link formats: `cloudstreamrepo://host/...` (the scheme
  // its "add repo" buttons use) and `https://cs.repo/?host/...`.
  final csPrefix = RegExp(
    r'^(cloudstreamrepo://)|^(https?://cs\.repo/\??)',
    caseSensitive: false,
  );
  if (csPrefix.hasMatch(s)) {
    s = s.replaceFirst(csPrefix, '').trim();
    if (s.isEmpty) return s;
    return _hasScheme(s) ? s : 'https://$s';
  }

  if (_hasScheme(s)) return s;

  // Scheme-less: only add one when it actually looks like a host, so a typo or
  // a stray word isn't turned into a plausible-looking URL that then 404s.
  if (_looksLikeHost(s)) return 'https://$s';

  return s;
}

bool _hasScheme(String s) =>
    RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(s);

/// `raw.githubusercontent.com/u/r/repo.json`, `example.com`, `1.2.3.4:8080/x`.
/// Requires a dot before the first slash so `justawordwithslash/x` is left be.
bool _looksLikeHost(String s) {
  final firstSlash = s.indexOf('/');
  final authority = firstSlash == -1 ? s : s.substring(0, firstSlash);
  if (authority.isEmpty || !authority.contains('.')) return false;
  if (authority.startsWith('.') || authority.endsWith('.')) return false;
  return RegExp(r'^[A-Za-z0-9.-]+(:[0-9]+)?$').hasMatch(authority);
}
