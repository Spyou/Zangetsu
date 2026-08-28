import 'dart:typed_data';

import 'package:crypto/crypto.dart';

final _btih = RegExp(r'urn:btih:([a-zA-Z0-9]+)', caseSensitive: false);

/// Info-hash as lowercase 40-char hex, or null if [uri] isn't a magnet / the
/// xt value isn't a v1 (SHA-1) hash.
String? parseMagnetHash(String uri) {
  final m = _btih.firstMatch(uri.trim());
  if (m == null) return null;
  final raw = m.group(1)!;
  if (raw.length == 40 && _isHex(raw)) return raw.toLowerCase();
  if (raw.length == 32) {
    final bytes = decodeBase32(raw);
    if (bytes != null && bytes.length == 20) {
      return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    }
  }
  return null;
}

bool looksLikeTorrentFileUrl(String uri) {
  final u = uri.trim().toLowerCase();
  if (u.startsWith('magnet:')) return false;
  return u.endsWith('.torrent') || u.contains('.torrent?');
}

/// SHA-1 of the bencoded `info` dict (the BitTorrent v1 info-hash).
String? infoHashFromTorrentBytes(List<int> data) {
  final info = _infoDictBytes(data);
  if (info == null || info.isEmpty) return null;
  return sha1.convert(info).toString();
}

bool _isHex(String s) => RegExp(r'^[0-9a-fA-F]+$').hasMatch(s);

/// RFC 4648 base32 (A-Z2-7), no padding required. Returns null on bad input.
Uint8List? decodeBase32(String input) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  final s = input.toUpperCase().replaceAll('=', '');
  var buffer = 0;
  var bits = 0;
  final out = <int>[];
  for (final r in s.runes) {
    final v = alphabet.indexOf(String.fromCharCode(r));
    if (v < 0) return null;
    buffer = (buffer << 5) | v;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      out.add((buffer >> bits) & 0xff);
    }
  }
  return Uint8List.fromList(out);
}

/// Walk a torrent's top-level dict and return the raw bencoded `info` value.
Uint8List? _infoDictBytes(List<int> data) {
  if (data.isEmpty || data[0] != 0x64) return null; // not a dict
  final p = _Bparse(data);
  p.i++; // skip leading 'd'
  while (p.i < data.length && p.peek != 0x65) {
    final key = p.readString();
    if (key == null) return null;
    final start = p.i;
    if (!p.skipValue()) return null;
    if (key == 'info') {
      return Uint8List.fromList(data.sublist(start, p.i));
    }
  }
  return null;
}

class _Bparse {
  _Bparse(this.bytes);
  final List<int> bytes;
  int i = 0;

  int? get peek => i < bytes.length ? bytes[i] : null;

  String? readString() {
    final start = i;
    while (i < bytes.length && bytes[i] >= 0x30 && bytes[i] <= 0x39) {
      i++;
    }
    if (i == start || i >= bytes.length || bytes[i] != 0x3a) {
      i = start;
      return null;
    }
    final len = int.tryParse(String.fromCharCodes(bytes.sublist(start, i)));
    i++; // skip ':'
    if (len == null || len < 0 || i + len > bytes.length) return null;
    final s = String.fromCharCodes(bytes.sublist(i, i + len));
    i += len;
    return s;
  }

  bool skipValue() {
    if (i >= bytes.length) return false;
    final c = bytes[i];
    if (c >= 0x30 && c <= 0x39) {
      return readString() != null;
    }
    if (c == 0x69) {
      // integer: i<digits>e
      i++;
      while (i < bytes.length && bytes[i] != 0x65) {
        i++;
      }
      if (i >= bytes.length) return false;
      i++;
      return true;
    }
    if (c == 0x6c) {
      i++;
      while (i < bytes.length && bytes[i] != 0x65) {
        if (!skipValue()) return false;
      }
      if (i >= bytes.length) return false;
      i++;
      return true;
    }
    if (c == 0x64) {
      i++;
      while (i < bytes.length && bytes[i] != 0x65) {
        if (readString() == null) return false;
        if (!skipValue()) return false;
      }
      if (i >= bytes.length) return false;
      i++;
      return true;
    }
    return false;
  }
}
