import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/playback/category_store.dart';
import 'package:watch_app/core/playback/list_status_store.dart';
import 'package:watch_app/core/playback/resume_store.dart';
import 'package:watch_app/core/reading/read_store.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('profile_local_store');
    Hive.init(directory.path);
    await ResumeStore.init();
    await ReadStore.init();
    await ListStatusStore.init();
    await CategoryStore.init();
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('episode and chapter marks are separate per profile', () async {
    var activeProfileId = 'default';
    final resume = ResumeStore(currentProfileId: () => activeProfileId);
    final read = ReadStore(currentProfileId: () => activeProfileId);

    await resume.save(
      'src',
      'show',
      'ep',
      const Duration(seconds: 20),
      const Duration(minutes: 20),
    );
    await read.save('src', 'manga', 'chapter', pos: 4, total: 20);
    activeProfileId = 'kid';
    expect(resume.get('src', 'show', 'ep'), isNull);
    expect(read.get('src', 'manga', 'chapter'), isNull);

    await resume.save(
      'src',
      'show',
      'ep',
      const Duration(seconds: 70),
      const Duration(minutes: 20),
    );
    await read.save('src', 'manga', 'chapter', pos: 12, total: 20);
    activeProfileId = 'default';
    expect(resume.get('src', 'show', 'ep')!.position.inSeconds, 20);
    expect(read.get('src', 'manga', 'chapter')!.pos, 4);
  });

  test('statuses and custom categories are separate per profile', () async {
    var activeProfileId = 'default';
    final status = ListStatusStore(currentProfileId: () => activeProfileId);
    final categories = CategoryStore(currentProfileId: () => activeProfileId);
    final item = MediaItem(
      id: 'show',
      sourceId: 'src',
      title: 'Show',
      cover: '',
      url: '/show',
      type: ProviderType.anime,
    );

    await status.setStatus(item, WatchStatus.watching);
    await categories.create('Family');
    activeProfileId = 'kid';
    expect(status.statusOf(item), isNull);
    expect(categories.all(), isEmpty);
    await status.setStatus(item, WatchStatus.planning);
    await categories.create('Kids');

    activeProfileId = 'default';
    expect(status.statusOf(item), WatchStatus.watching);
    expect(categories.all().single.name, 'Family');
  });
}
