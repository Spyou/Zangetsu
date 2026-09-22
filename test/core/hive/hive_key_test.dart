import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:hive/src/binary/binary_reader_impl.dart';
// ignore: implementation_imports
import 'package:hive/src/binary/binary_writer_impl.dart';
// ignore: implementation_imports
import 'package:hive/src/binary/frame.dart';
// ignore: implementation_imports
import 'package:hive/src/registry/type_registry_impl.dart';
import 'package:watch_app/core/hive/hive_key.dart';

/// Hive writes a String key's length into a single byte, and the guard it
/// ships for that is an `assert` — stripped from release builds, so only
/// users ever hit it. These tests pin both halves: what Hive actually does,
/// and that [hiveKey] keeps us on the safe side of it.
void main() {
  final registry = TypeRegistryImpl();

  /// Writes [key] through Hive's own frame writer and reads it back, exactly
  /// as opening a box does.
  String roundTrip(String key) {
    final w = BinaryWriterImpl(registry)..writeKey(key);
    return BinaryReaderImpl(w.toBytes(), registry).readKey() as String;
  }

  group('what Hive does', () {
    test('a key up to 255 bytes survives', () {
      expect(roundTrip('a' * 255), 'a' * 255);
    });

    test('past 255 bytes the length wraps and the key comes back short', () {
      // 256 -> the length byte holds 0, so the key reads as empty and every
      // byte of the real key is then read as though it were frame data.
      expect(roundTrip('a' * 256), isEmpty);
      // The size seen in a user's report: 10740 % 256 == 244.
      expect(roundTrip('a' * 10740).length, 244);
    });

    test("Hive's own guard counts characters, but the file counts bytes", () {
      // 200 Arabic characters pass `key.length > 0xFF` yet occupy 400 bytes,
      // so even a key Hive considers legal is written wrong.
      const arabic = 'م';
      expect(Frame.assertKey(arabic * 200), isTrue);
      expect(roundTrip(arabic * 200).length, lessThan(200));
    });
  });

  group('hiveKey', () {
    test('leaves an ordinary key exactly as it was', () {
      // Existing rows must keep the key they already have on disk.
      const key = 'cs:AnimeWitcher::https://example.test/anime/1';
      expect(hiveKey(key), same(key));
    });

    test('leaves the last legal key alone', () {
      expect(hiveKey('a' * 255), 'a' * 255);
    });

    test('shortens an oversized key enough to survive the round trip', () {
      // A real key shape: the URL carries a multi-kilobyte `?data={...}` blob.
      final huge = 'cs:AnimeWitcher::https://example.test/e?data='
          '${'x' * 10000}';
      final key = hiveKey(huge);

      expect(key, isNot(huge));
      expect(utf8.encode(key).length, lessThanOrEqualTo(255));
      expect(roundTrip(key), key); // survives, where `huge` would not
    });

    test('catches a key that is short in characters but long in bytes', () {
      final arabic = 'م' * 200; // 200 chars, 400 bytes
      expect(hiveKey(arabic), isNot(arabic));
      expect(utf8.encode(hiveKey(arabic)).length, lessThanOrEqualTo(255));
    });

    test('is stable, so a key still finds its own row next launch', () {
      final huge = 'x' * 900;
      expect(hiveKey(huge), hiveKey(huge));
    });

    test('keeps two different titles apart', () {
      expect(hiveKey('a' * 900), isNot(hiveKey('b' * 900)));
    });
  });
}
