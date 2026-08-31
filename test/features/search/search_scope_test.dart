import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/playback/search_prefs.dart';
import 'package:watch_app/core/playback/search_scope.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('search_scope');
    Hive.init(dir.path);
    await SearchPrefs.init();
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('scope is null until the user picks one', () {
    expect(SearchPrefs().scope, isNull);
  });

  test('scope round-trips and survives a new instance', () async {
    await SearchPrefs().setScope(SearchScope.sources);
    expect(SearchPrefs().scope, SearchScope.sources);
  });

  test('a stored value that is no longer a valid name reads as null', () async {
    await Hive.box(SearchPrefs.boxName).put('scope', 'nonsense');
    expect(SearchPrefs().scope, isNull);
  });

  test('setting the same scope twice does not notify', () async {
    final prefs = SearchPrefs();
    await prefs.setScope(SearchScope.library);
    var notifications = 0;
    prefs.addListener(() => notifications++);
    await prefs.setScope(SearchScope.library);
    expect(notifications, 0);
  });
}
