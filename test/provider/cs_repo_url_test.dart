import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/provider/cs_repo_url.dart';

/// Pasted repo links rarely arrive clean. These pin the tidy-up applied before
/// a repo is fetched — modelled on CloudStream's `RepositoryManager.parseRepoUrl`
/// (verified against their source) but never rejecting, so no link that worked
/// before can stop working.
void main() {
  group('leaves a good URL alone', () {
    test('https passes through untouched', () {
      const u = 'https://raw.githubusercontent.com/user/repo/builds/repo.json';
      expect(normalizeCsRepoUrl(u), u);
    });

    test('http is NOT upgraded — the scheme is the user\'s choice', () {
      // Whether cleartext is allowed at all is a separate (security) decision;
      // silently rewriting it here would hide which one was actually used.
      const u = 'http://example.com/repo.json';
      expect(normalizeCsRepoUrl(u), u);
    });

    test('query strings and ports survive', () {
      const u = 'https://example.com:8443/repo.json?ref=main&x=1';
      expect(normalizeCsRepoUrl(u), u);
    });
  });

  group('paste hygiene', () {
    test('whitespace and newlines around the link', () {
      expect(
        normalizeCsRepoUrl('  https://example.com/repo.json \n'),
        'https://example.com/repo.json',
      );
    });

    test('Discord/markdown angle brackets that suppress link previews', () {
      expect(
        normalizeCsRepoUrl('<https://example.com/repo.json>'),
        'https://example.com/repo.json',
      );
    });

    test('quotes, including smart quotes from docs and chat', () {
      for (final q in [
        '"https://example.com/repo.json"',
        "'https://example.com/repo.json'",
        '`https://example.com/repo.json`',
        '“https://example.com/repo.json”',
      ]) {
        expect(normalizeCsRepoUrl(q), 'https://example.com/repo.json');
      }
    });

    test('a full stop dragged in from the end of a sentence', () {
      expect(
        normalizeCsRepoUrl('https://example.com/repo.json.'),
        'https://example.com/repo.json',
      );
    });

    test('a closing bracket is kept when something opened it', () {
      // Legitimately part of the URL — dropping it would break the link.
      const u = 'https://example.com/repo_(v2).json';
      expect(normalizeCsRepoUrl(u), u);
    });

    test('an unmatched closing bracket from "(see https://…)" is dropped', () {
      expect(
        normalizeCsRepoUrl('https://example.com/repo.json)'),
        'https://example.com/repo.json',
      );
    });

    test('invisible zero-width characters copied from a web page', () {
      expect(
        normalizeCsRepoUrl('https://example.com/repo.json​'),
        'https://example.com/repo.json',
      );
    });
  });

  group("CloudStream's own link formats", () {
    test('cloudstreamrepo:// becomes https', () {
      expect(
        normalizeCsRepoUrl('cloudstreamrepo://example.com/repo.json'),
        'https://example.com/repo.json',
      );
    });

    test('https://cs.repo/? prefix is stripped', () {
      expect(
        normalizeCsRepoUrl('https://cs.repo/?example.com/repo.json'),
        'https://example.com/repo.json',
      );
    });

    test('cs.repo without the question mark', () {
      expect(
        normalizeCsRepoUrl('https://cs.repo/example.com/repo.json'),
        'https://example.com/repo.json',
      );
    });

    test('a prefix wrapping a full URL keeps that URL"s scheme', () {
      expect(
        normalizeCsRepoUrl('cloudstreamrepo://http://example.com/repo.json'),
        'http://example.com/repo.json',
      );
    });
  });

  group('missing scheme', () {
    test('a host gets https:// — the most common paste', () {
      expect(
        normalizeCsRepoUrl('raw.githubusercontent.com/u/r/repo.json'),
        'https://raw.githubusercontent.com/u/r/repo.json',
      );
    });

    test('host:port too', () {
      expect(
        normalizeCsRepoUrl('192.168.1.5:8080/repo.json'),
        'https://192.168.1.5:8080/repo.json',
      );
    });

    test('a word that is not a host is left alone, not turned into a URL', () {
      // Would otherwise become https://notaurl and fail confusingly rather than
      // failing as the nonsense it is.
      expect(normalizeCsRepoUrl('notaurl'), 'notaurl');
      expect(normalizeCsRepoUrl('some/path/only'), 'some/path/only');
    });
  });

  group('never rejects', () {
    test('empty and whitespace-only input come back empty', () {
      expect(normalizeCsRepoUrl(''), '');
      expect(normalizeCsRepoUrl('   '), '');
    });

    test('junk is returned unchanged so the caller reports its own error', () {
      expect(normalizeCsRepoUrl('¯\\_(ツ)_/¯'), '¯\\_(ツ)_/¯');
    });
  });
}
