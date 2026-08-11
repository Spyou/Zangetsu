import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

/// Decodes a Mihon `index.pb` repository index into raw extension maps shaped
/// exactly like the objects inside `index.json`'s `extensionList.extensions` —
/// keys `name`, `packageName`, `versionName`, `versionCode`, `contentWarning`,
/// `resources.apkUrl`, and `sources[].{id, language, name, homeUrl}` — so the
/// caller can reuse the same `index.json` → entry mapping unchanged.
///
/// `index.pb` is `gzip( protobuf3( NetworkExtensionStore ) )`. The schema is
/// public (keiyoushi `.github/scripts/index.proto`, mirrored from
/// `mihonapp/tachiyomix`) and carries the identical data to `index.json`, but
/// is ~13x smaller on the wire — so we prefer it and fall back to JSON.
///
/// Only the fields we actually consume are read; everything else (icon/jar URLs,
/// badge, signing key, mirror URLs, …) is skipped by wire type, which is also
/// how forward-compatible unknown fields are handled.
///
/// Throws [FormatException] on malformed/truncated input so the caller can fall
/// back to `index.json`.
///
// ponytail: hand-rolled proto3 reader instead of pulling in the `protobuf`
// package + protoc codegen — the schema is tiny and frozen. Every read is
// bounds-checked; if the schema ever grows a field we care about, add a case.
List<Map<String, dynamic>> decodeMihonPbIndex(List<int> input) {
  // The file is gzip-compressed (magic 0x1f 0x8b). A proxy could in theory hand
  // us already-inflated bytes, so only decompress when the magic is present.
  final Uint8List bytes =
      (input.length >= 2 && input[0] == 0x1f && input[1] == 0x8b)
          ? Uint8List.fromList(gzip.decode(input))
          : Uint8List.fromList(input);

  // NetworkExtensionStore { … ExtensionList extensionList = 101; … }
  final store = _PbReader(bytes);
  Uint8List? extensionListBytes;
  while (!store.isAtEnd) {
    final tag = store.readVarint();
    final field = tag >> 3;
    final wire = tag & 0x7;
    if (field == 101 && wire == 2) {
      extensionListBytes = store.readLengthDelimited();
    } else {
      store.skip(wire);
    }
  }
  if (extensionListBytes == null) return const [];

  // ExtensionList { repeated Extension extensions = 1; }
  final list = _PbReader(extensionListBytes);
  final out = <Map<String, dynamic>>[];
  while (!list.isAtEnd) {
    final tag = list.readVarint();
    final field = tag >> 3;
    final wire = tag & 0x7;
    if (field == 1 && wire == 2) {
      out.add(_decodeExtension(list.readLengthDelimited()));
    } else {
      list.skip(wire);
    }
  }
  return out;
}

/// Extension { name=1 pkg=2 resources=3 extensionLib=4 versionCode=5
/// versionName=6 contentWarning=7 sources=8 }
Map<String, dynamic> _decodeExtension(Uint8List bytes) {
  final r = _PbReader(bytes);
  String name = '';
  String packageName = '';
  String versionName = '';
  int versionCode = 0;
  int contentWarning = 0;
  String apkUrl = '';
  final sources = <Map<String, dynamic>>[];
  while (!r.isAtEnd) {
    final tag = r.readVarint();
    final field = tag >> 3;
    final wire = tag & 0x7;
    switch (field) {
      case 1:
        if (wire == 2) {
          name = r.readString();
        } else {
          r.skip(wire);
        }
        break;
      case 2:
        if (wire == 2) {
          packageName = r.readString();
        } else {
          r.skip(wire);
        }
        break;
      case 3:
        if (wire == 2) {
          apkUrl = _decodeResourcesApkUrl(r.readLengthDelimited());
        } else {
          r.skip(wire);
        }
        break;
      case 5:
        if (wire == 0) {
          versionCode = r.readVarint();
        } else {
          r.skip(wire);
        }
        break;
      case 6:
        if (wire == 2) {
          versionName = r.readString();
        } else {
          r.skip(wire);
        }
        break;
      case 7:
        if (wire == 0) {
          contentWarning = r.readVarint();
        } else {
          r.skip(wire);
        }
        break;
      case 8:
        if (wire == 2) {
          sources.add(_decodeSource(r.readLengthDelimited()));
        } else {
          r.skip(wire);
        }
        break;
      default:
        r.skip(wire);
    }
  }
  return {
    'name': name,
    'packageName': packageName,
    'versionName': versionName,
    'versionCode': versionCode,
    // enum: 3 == CONTENT_WARNING_NSFW; downstream only checks that one flag.
    'contentWarning': contentWarning == 3 ? 'CONTENT_WARNING_NSFW' : '',
    'resources': {'apkUrl': apkUrl},
    'sources': sources,
  };
}

/// Resources { apkUrl=1 iconUrl=2 jarUrl=501 } — we only need the APK URL.
String _decodeResourcesApkUrl(Uint8List bytes) {
  final r = _PbReader(bytes);
  String apkUrl = '';
  while (!r.isAtEnd) {
    final tag = r.readVarint();
    final field = tag >> 3;
    final wire = tag & 0x7;
    if (field == 1 && wire == 2) {
      apkUrl = r.readString();
    } else {
      r.skip(wire);
    }
  }
  return apkUrl;
}

/// Source { id=1 name=2 language=3 homeUrl=4 mirrorUrls=5 message=7 }.
///
// ponytail: `id` is an int64 varint; Dart `int` is 64-bit on the mobile/TV
// targets this app runs on, so it's exact. (Would lose precision only on Dart
// web > 2^53, which this app never targets.)
Map<String, dynamic> _decodeSource(Uint8List bytes) {
  final r = _PbReader(bytes);
  int id = 0;
  String name = '';
  String language = '';
  String homeUrl = '';
  while (!r.isAtEnd) {
    final tag = r.readVarint();
    final field = tag >> 3;
    final wire = tag & 0x7;
    switch (field) {
      case 1:
        if (wire == 0) {
          id = r.readVarint();
        } else {
          r.skip(wire);
        }
        break;
      case 2:
        if (wire == 2) {
          name = r.readString();
        } else {
          r.skip(wire);
        }
        break;
      case 3:
        if (wire == 2) {
          language = r.readString();
        } else {
          r.skip(wire);
        }
        break;
      case 4:
        if (wire == 2) {
          homeUrl = r.readString();
        } else {
          r.skip(wire);
        }
        break;
      default:
        r.skip(wire);
    }
  }
  return {'id': id, 'language': language, 'name': name, 'homeUrl': homeUrl};
}

/// Minimal, bounds-checked proto3 wire reader over a byte view.
class _PbReader {
  _PbReader(this._buf);

  final Uint8List _buf;
  int _pos = 0;

  bool get isAtEnd => _pos >= _buf.length;

  /// Reads a base-128 varint (used for tags, int64, and enums).
  int readVarint() {
    int result = 0;
    int shift = 0;
    while (true) {
      if (_pos >= _buf.length) {
        throw const FormatException('protobuf: varint truncated');
      }
      final b = _buf[_pos++];
      result |= (b & 0x7f) << shift;
      if ((b & 0x80) == 0) return result;
      shift += 7;
      if (shift >= 64) {
        throw const FormatException('protobuf: varint too long');
      }
    }
  }

  /// Reads a length-delimited field as a zero-copy view into the buffer.
  Uint8List readLengthDelimited() {
    final len = readVarint();
    if (len < 0 || _pos + len > _buf.length) {
      throw const FormatException('protobuf: length-delimited overruns buffer');
    }
    final view = Uint8List.sublistView(_buf, _pos, _pos + len);
    _pos += len;
    return view;
  }

  String readString() => utf8.decode(readLengthDelimited());

  /// Skips a field of the given wire type (0 varint, 1 64-bit, 2 len-delimited,
  /// 5 32-bit). Groups (3/4) are obsolete and rejected.
  void skip(int wire) {
    switch (wire) {
      case 0:
        readVarint();
        break;
      case 1:
        _advance(8);
        break;
      case 2:
        _advance(readVarint());
        break;
      case 5:
        _advance(4);
        break;
      default:
        throw FormatException('protobuf: unsupported wire type $wire');
    }
  }

  void _advance(int n) {
    if (n < 0 || _pos + n > _buf.length) {
      throw const FormatException('protobuf: advance overruns buffer');
    }
    _pos += n;
  }
}
