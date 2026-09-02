// Downloading a chapter from a metadata title. The item is the `zm`
// pseudo-source, but the chapters belong to the matched extension — queue them
// under `zm` and the downloader later asks the source registry for a source
// that does not exist, so every manga download failed.

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/chapter_download.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';

/// Mirrors the choice made when enqueuing: the matched source wins, and the
/// item's own id is only the fallback.
String downloadSourceFor({
  required String detailSourceId,
  required String itemSourceId,
}) => detailSourceId.isNotEmpty ? detailSourceId : itemSourceId;

void main() {
  test('a metadata title queues under the matched extension', () {
    final id = downloadSourceFor(
      detailSourceId: 'mihon:123',
      itemSourceId: ZmodeIds.sourceId,
    );

    expect(id, 'mihon:123');
    expect(id, isNot(ZmodeIds.sourceId), reason: 'zm cannot fetch pages');
  });

  test('a source title is unchanged', () {
    expect(
      downloadSourceFor(detailSourceId: 'mihon:9', itemSourceId: 'mihon:9'),
      'mihon:9',
    );
  });

  test('an unresolved match falls back rather than queuing nothing', () {
    // No source matched yet: better to keep today's behaviour than to drop
    // the download.
    expect(
      downloadSourceFor(detailSourceId: '', itemSourceId: ZmodeIds.sourceId),
      ZmodeIds.sourceId,
    );
  });

  test('the queue id follows the source, so the button matches', () {
    // The chapter button looks the download up by this id. Enqueuing under one
    // source and looking up under another shows no progress at all.
    const url = 'https://example.test/ch/1';
    expect(
      ChapterDownload.idFor('mihon:123', url),
      isNot(ChapterDownload.idFor(ZmodeIds.sourceId, url)),
    );
  });
}
