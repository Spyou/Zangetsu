import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/category_store.dart';

MediaItem item(String id) => MediaItem(
      id: id,
      title: id,
      url: '/$id',
      type: ProviderType.anime,
      sourceId: 'src',
    );

void main() {
  late Directory dir;
  late CategoryStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('cat_store');
    Hive.init(dir.path);
    await Hive.openBox(CategoryStore.boxName);
    store = CategoryStore();
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('creating', () {
    test('creates in order and rejects blanks', () async {
      expect(await store.create('Persona'), isNotNull);
      expect(await store.create('Gym'), isNotNull);
      expect(store.all().map((c) => c.name), ['Persona', 'Gym']);
      expect(await store.create('   '), isNull);
      expect(await store.create(''), isNull);
    });

    test('refuses a duplicate name regardless of case', () async {
      // "gym" and "Gym" would be indistinguishable as two tabs.
      await store.create('Gym');
      expect(await store.create('gym'), isNull);
      expect(await store.create('  GYM  '), isNull);
      expect(store.all().length, 1);
    });

    test('trims the name', () async {
      final c = await store.create('  Persona  ');
      expect(c!.name, 'Persona');
    });
  });

  group('renaming', () {
    test('assignments survive a rename', () async {
      // Assignments are keyed by id, not name — this is why.
      final c = (await store.create('Persoan'))!;
      await store.setMembership(item('a'), c.id, true);
      expect(await store.rename(c.id, 'Persona'), isTrue);
      expect(store.all().single.name, 'Persona');
      expect(store.isIn(item('a'), c.id), isTrue);
    });

    test('refuses a name another category already has', () async {
      final a = (await store.create('Gym'))!;
      await store.create('Persona');
      expect(await store.rename(a.id, 'persona'), isFalse);
      expect(store.all().map((c) => c.name), containsAll(['Gym', 'Persona']));
    });
  });

  group('membership', () {
    test('a title can be in several categories at once', () async {
      final a = (await store.create('Persona'))!;
      final b = (await store.create('Gym'))!;
      await store.setMembership(item('x'), a.id, true);
      await store.setMembership(item('x'), b.id, true);
      expect(store.categoriesOf(item('x')), {a.id, b.id});
    });

    test('removing from one leaves the other', () async {
      final a = (await store.create('Persona'))!;
      final b = (await store.create('Gym'))!;
      await store.setMembership(item('x'), a.id, true);
      await store.setMembership(item('x'), b.id, true);
      await store.setMembership(item('x'), a.id, false);
      expect(store.categoriesOf(item('x')), {b.id});
    });

    test('counts only what is actually in the category', () async {
      final a = (await store.create('Persona'))!;
      expect(store.countIn(a.id), 0); // an empty category honestly reads 0
      await store.setMembership(item('x'), a.id, true);
      await store.setMembership(item('y'), a.id, true);
      expect(store.countIn(a.id), 2);
    });
  });

  group('deleting', () {
    test('drops the category and its assignments, nothing else', () async {
      final a = (await store.create('Persona'))!;
      final b = (await store.create('Gym'))!;
      await store.setMembership(item('x'), a.id, true);
      await store.setMembership(item('x'), b.id, true);

      await store.delete(a.id);

      expect(store.all().map((c) => c.id), [b.id]);
      // The title keeps its other category — deleting a category must never
      // take a title out of the list or out of anything else.
      expect(store.categoriesOf(item('x')), {b.id});
    });
  });

  group('reordering', () {
    test('applies the given order', () async {
      final a = (await store.create('A'))!;
      final b = (await store.create('B'))!;
      final c = (await store.create('C'))!;
      await store.reorder([c.id, a.id, b.id]);
      expect(store.all().map((x) => x.name), ['C', 'A', 'B']);
    });

    test('a category missing from the order is kept, not dropped', () async {
      await store.create('A');
      final b = (await store.create('B'))!;
      await store.reorder([b.id]); // stale list, missing A
      expect(store.all().map((x) => x.name), ['B', 'A']);
      expect(store.all().length, 2);
    });
  });
}
