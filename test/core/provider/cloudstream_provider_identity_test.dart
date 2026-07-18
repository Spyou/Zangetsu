import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';

void main() {
  // A "bundle" plugin registers several sources under ONE .cs3 file id (e.g.
  // CNC Verse → Netflix, Disney, Star Wars…). The bug: they shared one hostKey
  // (the file id), so tapping Disney played Netflix. hostKey now carries the
  // name too, so each bundle member resolves to itself.
  const fileId = 'CNC Verse@92@70d52323';

  CloudStreamProvider p(String name, {String? sp}) => CloudStreamProvider(
    name: name,
    lang: 'ta',
    types: const ['Movie', 'TvSeries'],
    sourcePlugin: sp,
  );

  group('hostKey', () {
    test('combines the file id and the name for a plugin-backed source', () {
      expect(p('Disney', sp: fileId).hostKey, '$fileId${CloudStreamProvider.keySep}Disney');
    });

    test('two bundle members (same file id) get DISTINCT host keys', () {
      final netflix = p('Netflix', sp: fileId).hostKey;
      final disney = p('Disney', sp: fileId).hostKey;
      expect(netflix, isNot(equals(disney)));
    });

    test('falls back to the bare name when there is no file id', () {
      expect(p('AllAnime').hostKey, 'AllAnime');
      expect(p('AllAnime', sp: '').hostKey, 'AllAnime');
    });
  });

  group('sourceId', () {
    test('stays cs:<name> for unique-named sources (persistence unchanged)', () {
      expect(p('Disney', sp: fileId).sourceId, 'cs:Disney');
      expect(p('AllAnime').sourceId, 'cs:AllAnime');
    });

    test('bundle members keep distinct sourceIds', () {
      expect(p('Netflix', sp: fileId).sourceId, isNot(p('Disney', sp: fileId).sourceId));
    });
  });
}
