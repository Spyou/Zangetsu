import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/playback/title_prefs.dart';

void main() {
  late Directory dir;
  late TitlePrefsStore prefs;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('stremio_link_prefs');
    Hive.init(dir.path);
    await TitlePrefsStore.init();
    prefs = TitlePrefsStore();
  });
  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test(
    'the saved episode link wins over a series-wide torrent group',
    () async {
      const direct = VideoSource(
        url: 'https://pengu.test/episode',
        label: 'Pengu',
        bingeGroup: 'direct-group',
      );
      const torrent = VideoSource(
        url: 'magnet:?xt=urn:btih:hash',
        label: 'Torrent',
        bingeGroup: 'torrent-group',
      );
      await prefs.rememberStremioLink('episode-one', direct);
      await prefs.rememberStremioBingeGroup('show', 'torrent-group');
      expect(
        prefs.preferredStremioLink('episode-one', [
          torrent,
          direct,
        ], showUrl: 'show'),
        same(direct),
      );
      expect(
        prefs.preferredStremioLink('episode-two', [
          torrent,
          direct,
        ], showUrl: 'show'),
        same(torrent),
      );
    },
  );

  test('resume remembers the exact link without storing its URL', () async {
    const first = VideoSource(
      url: 'https://cdn.test/one?token=secret',
      label: '1080p',
    );
    const picked = VideoSource(
      url: 'https://cdn.test/two?token=secret',
      label: '1080p',
    );
    await prefs.rememberStremioLink('episode-one', picked);
    expect(
      prefs.preferredStremioLink('episode-one', [first, picked]),
      same(picked),
    );
    expect(prefs.preferredStremioLink('episode-two', [first, picked]), isNull);
    expect(
      Hive.box<Map>(TitlePrefsStore.boxName).values.toString(),
      isNot(contains('token=secret')),
    );
    await Hive.box<Map>(TitlePrefsStore.boxName).close();
    await TitlePrefsStore.init();
    expect(
      prefs.preferredStremioLink('episode-one', [first, picked]),
      same(picked),
    );
  });

  test(
    'a refreshed URL matches its label; removed choices fall back normally',
    () async {
      await prefs.rememberStremioLink(
        'episode-one',
        const VideoSource(url: 'https://old.test/file', label: 'Chosen'),
      );
      const other = VideoSource(url: 'https://other.test/file', label: 'Other');
      const fresh = VideoSource(url: 'https://new.test/file', label: 'Chosen');
      expect(
        prefs.preferredStremioLink('episode-one', [other, fresh]),
        same(fresh),
      );
      expect(prefs.preferredStremioLink('episode-one', [other]), isNull);
      expect(prefs.preferredStremioLink('another-title', [fresh]), isNull);
    },
  );
}
