import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `copyWith` lists its fields by hand. Every time a field is added to a
/// model's constructor and not to its copyWith, every caller silently loses
/// it — no error, no crash, the value is just gone.
///
/// It has happened twice: MediaDetail dropped 24 fields on the manga path,
/// and MediaItem dropped `genres` and `status` for long enough that nobody
/// noticed. Both were found by reading the code, which is not a plan.
///
/// So this reads the source instead of trusting a person to. It is a blunt
/// text scan, not a parser — that is fine, because it only has to answer one
/// question: is every constructor field mentioned in copyWith?
void main() {
  /// Constructor fields (`this.x`) that copyWith never passes.
  List<String> dropped(String path, String cls) {
    final src = File(path).readAsStringSync();

    final ctorMatch = RegExp(
      'const $cls\\(\\{(.*?)\\}\\)',
      dotAll: true,
    ).firstMatch(src);
    expect(ctorMatch, isNotNull, reason: 'no const $cls({...}) found');
    final ctor = RegExp(r'this\.(\w+)')
        .allMatches(ctorMatch!.group(1)!)
        .map((m) => m.group(1)!)
        .toSet();
    expect(ctor, isNotEmpty, reason: '$cls has no this.x fields?');

    // The `Cls(` call copyWith returns, up to its closing paren.
    final open = src.indexOf(RegExp('\\}\\)\\s*=>\\s*$cls\\('));
    expect(open, isNot(-1), reason: '$cls has no copyWith');
    final close = src.indexOf(RegExp(r'\n\s*\);'), open);
    final body = src.substring(open, close);
    final passed = RegExp(r'^\s*(\w+):', multiLine: true)
        .allMatches(body)
        .map((m) => m.group(1)!)
        .toSet();

    return (ctor.difference(passed).toList())..sort();
  }

  const models = {
    'lib/core/models/media_item.dart': 'MediaItem',
    'lib/core/models/media_detail.dart': 'MediaDetail',
    'lib/core/models/episode.dart': 'Episode',
  };

  models.forEach((path, cls) {
    test('$cls.copyWith carries every field', () {
      expect(
        dropped(path, cls),
        isEmpty,
        reason:
            'These are on $cls\'s constructor but copyWith never passes them, '
            'so every caller silently loses them. Add them to copyWith.',
      );
    });
  });

  test('the check can actually fail', () {
    // A guard that cannot fail is decoration. This proves the scan finds a
    // dropped field, using a fixture rather than by breaking a real model.
    final tmp = File(
      '${Directory.systemTemp.createTempSync('cw').path}/fake.dart',
    )..writeAsStringSync('''
class Fake {
  const Fake({this.kept, this.lost});
  final int? kept;
  final int? lost;
  Fake copyWith({int? kept}) => Fake(
    kept: kept ?? this.kept,
  );
}
''');
    expect(dropped(tmp.path, 'Fake'), ['lost']);
    tmp.parent.deleteSync(recursive: true);
  });
}
