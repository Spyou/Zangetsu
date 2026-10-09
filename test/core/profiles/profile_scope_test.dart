import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/profiles/profile_scope.dart';

void main() {
  test('default profile keeps legacy Hive keys unchanged', () {
    expect(profileScopedKey(kDefaultProfileId, 'source::show'), 'source::show');
    expect(profileOwnsKey('source::show', kDefaultProfileId), isTrue);
    expect(profileOwnsKey('p:kid::source::show', kDefaultProfileId), isFalse);
  });

  test('secondary profile keys cannot overlap another profile', () {
    final kidKey = profileScopedKey('kid', 'source::show');

    expect(profileOwnsKey(kidKey, 'kid'), isTrue);
    expect(profileOwnsKey(kidKey, 'teen'), isFalse);
    expect(profileOwnsKey(kidKey, kDefaultProfileId), isFalse);
  });

  test('secondary profile keys stay within Hive byte limit', () {
    const profileId = '12345678-1234-1234-1234-123456789012';
    final key = profileScopedKey(profileId, 'x' * 220);

    expect(key, startsWith('p:$profileId::'));
    expect(utf8.encode(key).length, lessThanOrEqualTo(255));
    expect(profileOwnsKey(key, profileId), isTrue);
    expect(profileScopedKey(profileId, 'x' * 220), key);
    expect(profileScopedKey(profileId, 'y' * 220), isNot(key));
  });

  test(
    'long profile IDs also stay within Hive byte limit and remain owned',
    () {
      final profileId = '🌀' * 100;
      final key = profileScopedKey(profileId, 'source::show');

      expect(utf8.encode(key).length, lessThanOrEqualTo(255));
      expect(profileOwnsKey(key, profileId), isTrue);
    },
  );
}
