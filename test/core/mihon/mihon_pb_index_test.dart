import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/mihon/mihon_pb_index.dart';

// Minimal proto3 encoders so the test builds its own NetworkExtensionStore
// bytes — decoded against the real keiyoushi index.pb during development, this
// guards the wire logic (field numbers, wire types, nested/repeated messages,
// the NSFW enum, int64 ids) without committing a ~98KB binary fixture.
List<int> _varint(int v) {
  final out = <int>[];
  var n = v;
  while (true) {
    final b = n & 0x7f;
    n >>= 7;
    if (n == 0) {
      out.add(b);
      break;
    }
    out.add(b | 0x80);
  }
  return out;
}

List<int> _tag(int field, int wire) => _varint((field << 3) | wire);
List<int> _varintField(int field, int v) => [..._tag(field, 0), ..._varint(v)];
List<int> _lenField(int field, List<int> payload) =>
    [..._tag(field, 2), ..._varint(payload.length), ...payload];
List<int> _strField(int field, String s) => _lenField(field, utf8.encode(s));

void main() {
  test('decodes a NetworkExtensionStore with two extensions', () {
    // Source { id=1, name=2, language=3, homeUrl=4 } — id is a large int64.
    final source = <int>[
      ..._varintField(1, 4638673959522768501),
      ..._strField(2, 'MangaDex'),
      ..._strField(3, 'en'),
      ..._strField(4, 'https://mangadex.org'),
      // mirrorUrls=5 (repeated string) and message=7 must be skipped cleanly.
      ..._strField(5, 'https://mirror.example'),
    ];
    // Resources { apkUrl=1, iconUrl=2, jarUrl=501 } — only apkUrl is read.
    final resources = <int>[
      ..._strField(1, 'https://cdn.example/apk/test-v1.2.3.apk'),
      ..._strField(2, 'https://cdn.example/icon.png'),
      ..._strField(501, 'https://cdn.example/test.jar'),
    ];
    // Extension { name=1, pkg=2, resources=3, extensionLib=4, versionCode=5,
    //             versionName=6, contentWarning=7, sources=8 }
    final ext1 = <int>[
      ..._strField(1, 'Test Ext'),
      ..._strField(2, 'eu.kanade.tachiyomi.extension.en.test'),
      ..._lenField(3, resources),
      ..._strField(4, '1.5'), // extensionLib — skipped
      ..._varintField(5, 211),
      ..._strField(6, '1.2.3'),
      ..._varintField(7, 3), // CONTENT_WARNING_NSFW
      ..._lenField(8, source),
    ];
    final ext2 = <int>[
      ..._strField(2, 'eu.kanade.tachiyomi.extension.all.other'),
      ..._lenField(3, [..._strField(1, 'https://cdn.example/apk/other.apk')]),
      ..._varintField(7, 1), // CONTENT_WARNING_SAFE
    ];
    final extensionList = <int>[..._lenField(1, ext1), ..._lenField(1, ext2)];
    // NetworkExtensionStore { name=1, …, extensionList=101 }
    final store = <int>[
      ..._strField(1, 'TestRepo'),
      ..._strField(3, 'signingkey'), // skipped
      ..._lenField(101, extensionList),
    ];

    final out = decodeMihonPbIndex(store);

    expect(out.length, 2);

    final a = out[0];
    expect(a['packageName'], 'eu.kanade.tachiyomi.extension.en.test');
    expect(a['versionName'], '1.2.3');
    expect(a['versionCode'], 211);
    expect(a['contentWarning'], 'CONTENT_WARNING_NSFW');
    expect(
      (a['resources'] as Map)['apkUrl'],
      'https://cdn.example/apk/test-v1.2.3.apk',
    );
    final srcs = a['sources'] as List;
    expect(srcs.length, 1);
    final s0 = srcs.first as Map;
    expect(s0['id'], 4638673959522768501);
    expect(s0['language'], 'en');
    expect(s0['name'], 'MangaDex');
    expect(s0['homeUrl'], 'https://mangadex.org');

    final b = out[1];
    expect(b['packageName'], 'eu.kanade.tachiyomi.extension.all.other');
    expect(b['contentWarning'], ''); // not NSFW → empty
    expect(b['sources'], isEmpty);
  });

  test('empty / no-extensionList store decodes to an empty list', () {
    expect(decodeMihonPbIndex(const []), isEmpty);
    expect(decodeMihonPbIndex(_strField(1, 'JustAName')), isEmpty);
  });

  test('truncated length-delimited field throws FormatException', () {
    // tag for field 101 (len-delimited) claiming 50 bytes, but none follow.
    final bad = <int>[..._tag(101, 2), ..._varint(50)];
    expect(() => decodeMihonPbIndex(bad), throwsFormatException);
  });
}
