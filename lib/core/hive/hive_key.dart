import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Hive stores a String key's length in a single byte, so a key longer than
/// 255 bytes is written with a wrapped length (10 740 becomes 244) and every
/// later read lands mid-key and reports a nonsense typeId. The box is gone.
///
/// Hive does guard against it — `assert(assertKey(key))` in `Frame` — but an
/// assert is stripped from release builds, so the check only ever runs here
/// and never on a user's phone. Its limit is also counted in characters while
/// the file counts bytes, so non-Latin keys slip past it either way. We count
/// bytes.
///
/// Keys are built from source ids and show URLs, and some sources hand out
/// URLs carrying a multi-kilobyte `?data={...}` blob — that is what has been
/// eating My List and Watch History.
///
/// Anything that fits comes back untouched, so existing rows keep the key they
/// already have. Only the oversized ones change, and those cannot be read back
/// today anyway.
String hiveKey(String raw) {
  final bytes = utf8.encode(raw);
  if (bytes.length <= 255) return raw;
  return 'h:${md5.convert(bytes)}';
}
