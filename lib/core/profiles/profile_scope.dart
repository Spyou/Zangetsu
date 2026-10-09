import 'dart:convert';

import '../hive/hive_key.dart';

const String kDefaultProfileId = 'default';

String profileScopePrefix(String profileId) =>
    'p:${hiveKey(profileId, maxBytes: 96)}::';

String profileScopedKey(String profileId, String legacyKey) {
  if (profileId == kDefaultProfileId) return legacyKey;
  final prefix = profileScopePrefix(profileId);
  return '$prefix${hiveKey(legacyKey, maxBytes: 255 - utf8.encode(prefix).length)}';
}

bool profileOwnsKey(Object? key, String profileId) {
  if (key is! String) return false;
  if (profileId == kDefaultProfileId) return !key.startsWith('p:');
  return key.startsWith(profileScopePrefix(profileId));
}
