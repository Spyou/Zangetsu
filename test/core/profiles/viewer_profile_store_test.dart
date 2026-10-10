import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/profiles/viewer_profile.dart';

void main() {
  late Directory directory;
  late ViewerProfileStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('viewer_profiles');
    Hive.init(directory.path);
    await ViewerProfileStore.init();
    store = ViewerProfileStore();
    await store.loadForUser(displayName: 'Account');
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('keeps Home and caps the total at four profiles', () async {
    expect(ViewerProfileStore.maxProfiles, 4);
    expect(store.profiles, hasLength(1));
    expect(store.activeProfile.id, kDefaultProfileId);

    for (var i = 1; i < ViewerProfileStore.maxProfiles; i++) {
      expect(await store.create('Profile $i'), isNotNull);
    }
    expect(await store.create('One too many'), isNull);
    expect(store.profiles, hasLength(ViewerProfileStore.maxProfiles));
  });

  test(
    'keeps a previously saved fifth profile when loading old data',
    () async {
      final legacyProfiles = [
        for (var i = 0; i < 5; i++)
          ViewerProfile(
            id: i == 0 ? kDefaultProfileId : 'legacy-$i',
            name: i == 0 ? 'Home' : 'Legacy $i',
          ).toJson(),
      ];
      await Hive.box(
        ViewerProfileStore.boxName,
      ).put('profiles:local', legacyProfiles);

      await store.loadForUser();

      expect(store.profiles, hasLength(5));
      expect(store.profiles.last.id, 'legacy-4');
      expect(await store.create('Another'), isNull);
    },
  );

  test(
    'asks for a profile on launch by default and persists the setting',
    () async {
      expect(store.askOnLaunch, isTrue);

      await store.setAskOnLaunch(false);

      expect(ViewerProfileStore().askOnLaunch, isFalse);
    },
  );

  test('switches profiles without changing the default profile', () async {
    final kid = await store.create('Kid', isKids: true);
    expect(kid, isNotNull);
    await store.switchTo(kid!.id);
    expect(store.contextRevision.value, 1);
    expect(store.activeProfile.isKids, isTrue);
    expect(store.adultMetadataAllowed, isFalse);

    await store.rename(kid.id, 'Kids');
    expect(store.activeProfile.name, 'Kids');
    expect(store.contextRevision.value, 1);
    await store.update(kid.id, isKids: false);
    expect(store.contextRevision.value, 2);

    await store.switchTo(kDefaultProfileId);
    expect(store.contextRevision.value, 3);
    expect(store.activeProfile.name, 'Account');
    expect(store.adultMetadataAllowed, isTrue);
    expect(await store.delete(kDefaultProfileId), isFalse);
  });

  test(
    'ignores a profile response after the signed-in account changes',
    () async {
      String? userId = 'account-a';
      final remote = _AccountSwitchProfileRemote();
      final switchingStore = ViewerProfileStore(
        remote: remote,
        currentUserId: () => userId,
      );

      final oldLoad = switchingStore.loadForUser(displayName: 'Account A');
      await remote.accountAStarted.future;
      userId = 'account-b';
      await switchingStore.loadForUser(displayName: 'Account B');
      remote.accountAResult.complete([
        {'profile_id': kDefaultProfileId, 'name': 'Account A'},
        {'profile_id': 'a-private', 'name': 'Private A'},
      ]);
      await oldLoad;

      expect(switchingStore.profiles.map((profile) => profile.name), [
        'Account B',
      ]);
    },
  );

  test(
    'deleting a profile clears only its local profile-scoped rows',
    () async {
      final kid = (await store.create('Kid'))!;
      final box = await Hive.openBox('my_list');
      await box.put('p:${kid.id}::saved-title', {'title': 'Kid title'});
      await box.put('saved-title', {'title': 'Default title'});

      expect(await store.delete(kid.id), isTrue);
      expect(box.containsKey('p:${kid.id}::saved-title'), isFalse);
      expect(box.containsKey('saved-title'), isTrue);
    },
  );

  test('keeps profile visible until cloud deletion completes', () async {
    final remote = _BlockingDeleteProfileRemote();
    final cloudStore = ViewerProfileStore(
      remote: remote,
      currentUserId: () => 'test-user',
    );
    await cloudStore.loadForUser();
    final profile = (await cloudStore.create('Guest'))!;
    final previousRevision = cloudStore.revision.value;

    final deletion = cloudStore.delete(profile.id);
    await remote.deleteStarted.future;

    expect(cloudStore.revision.value, previousRevision);
    expect(cloudStore.profiles.any((item) => item.id == profile.id), isTrue);

    remote.allowDelete.complete();
    expect(await deletion, isTrue);
    expect(cloudStore.revision.value, greaterThan(previousRevision));
    expect(cloudStore.profiles.any((item) => item.id == profile.id), isFalse);
  });

  test(
    'deletes a profile avatar only after cloud profile deletion succeeds',
    () async {
      const photoUrl = 'https://cdn.example/avatars/user/photo.jpg';
      final remote = _BlockingDeleteProfileRemote();
      String? deletedAvatarUrl;
      final cloudStore = ViewerProfileStore(
        remote: remote,
        currentUserId: () => 'test-user',
        deleteAvatar: (url) async {
          deletedAvatarUrl = url;
          return true;
        },
      );
      await cloudStore.loadForUser();
      final profile = (await cloudStore.create('Guest', photoUrl: photoUrl))!;

      final deletion = cloudStore.delete(profile.id);
      await remote.deleteStarted.future;

      expect(deletedAvatarUrl, isNull);
      expect(cloudStore.profiles.any((item) => item.id == profile.id), isTrue);

      remote.allowDelete.complete();
      expect(await deletion, isTrue);
      expect(deletedAvatarUrl, photoUrl);
    },
  );

  test('does not delete an avatar still used by another profile', () async {
    const photoUrl = 'https://cdn.example/avatars/user/shared.jpg';
    String? deletedAvatarUrl;
    final profileStore = ViewerProfileStore(
      deleteAvatar: (url) async {
        deletedAvatarUrl = url;
        return true;
      },
    );
    await profileStore.loadForUser();
    final first = (await profileStore.create('First', photoUrl: photoUrl))!;
    await profileStore.create('Second', photoUrl: photoUrl);

    expect(await profileStore.delete(first.id), isTrue);

    expect(deletedAvatarUrl, isNull);
    expect(
      profileStore.profiles.any((profile) => profile.photoUrl == photoUrl),
      isTrue,
    );
  });

  test('keeps profile and local data when cloud deletion fails', () async {
    var avatarDeleteCalled = false;
    final cloudStore = ViewerProfileStore(
      remote: _FailingDeleteProfileRemote(),
      currentUserId: () => 'test-user',
      deleteAvatar: (_) async {
        avatarDeleteCalled = true;
        return true;
      },
    );
    await cloudStore.loadForUser();
    final guest = (await cloudStore.create(
      'Guest',
      photoUrl: 'https://cdn.example/avatars/user/retained.jpg',
    ))!;
    final box = await Hive.openBox('my_list');
    final key = 'p:${guest.id}::saved-title';
    await box.put(key, {'title': 'Guest title'});

    final deleted = await cloudStore.delete(guest.id);

    expect(deleted, isFalse);
    expect(
      cloudStore.profiles.any((profile) => profile.id == guest.id),
      isTrue,
    );
    expect(box.containsKey(key), isTrue);
    expect(avatarDeleteCalled, isFalse);
  });

  test('photoUrl round-trips through create, update, and reload', () async {
    final created = await store.create(
      'Pic',
      photoUrl: 'https://cdn.example/a.jpg',
    );
    expect(created?.photoUrl, 'https://cdn.example/a.jpg');
    await store.update(created!.id, photoUrl: 'https://cdn.example/b.jpg');
    expect(
      store.profiles.firstWhere((p) => p.id == created.id).photoUrl,
      'https://cdn.example/b.jpg',
    );
    final again = ViewerProfileStore();
    await again.loadForUser(displayName: 'Account');
    expect(
      again.profiles.firstWhere((p) => p.id == created.id).photoUrl,
      'https://cdn.example/b.jpg',
    );
  });

  test('does not confirm a photo update when cloud sync fails', () async {
    final cloudStore = ViewerProfileStore(
      remote: _FailingUpsertProfileRemote(),
      currentUserId: () => 'test-user',
    );
    await cloudStore.loadForUser();

    final synced = await cloudStore.update(
      kDefaultProfileId,
      photoUrl: 'https://cdn.example/new.jpg',
    );

    expect(synced, isFalse);
    expect(cloudStore.activeProfile.photoUrl, 'https://cdn.example/new.jpg');
  });

  test('old rows without a photo read as icon-only', () {
    final hive = ViewerProfile.fromJson({'id': 'x', 'name': 'X'});
    expect(hive.photoUrl, isNull);
  });
}

class _BlockingDeleteProfileRemote implements ViewerProfileRemote {
  final deleteStarted = Completer<void>();
  final allowDelete = Completer<void>();

  @override
  Future<void> delete(String userId, String profileId) {
    deleteStarted.complete();
    return allowDelete.future;
  }

  @override
  Future<List<Map<String, dynamic>>> listFor(String userId) async => [];

  @override
  Future<void> upsert(String userId, ViewerProfile profile) async {}
}

class _FailingUpsertProfileRemote implements ViewerProfileRemote {
  @override
  Future<List<Map<String, dynamic>>> listFor(String userId) async => [];

  @override
  Future<void> delete(String userId, String profileId) async {}

  @override
  Future<void> upsert(String userId, ViewerProfile profile) async {
    throw const SocketException('offline');
  }
}

class _FailingDeleteProfileRemote implements ViewerProfileRemote {
  @override
  Future<List<Map<String, dynamic>>> listFor(String userId) async => [];

  @override
  Future<void> delete(String userId, String profileId) async {
    throw const SocketException('offline');
  }

  @override
  Future<void> upsert(String userId, ViewerProfile profile) async {}
}

class _AccountSwitchProfileRemote implements ViewerProfileRemote {
  final accountAStarted = Completer<void>();
  final accountAResult = Completer<List<Map<String, dynamic>>>();

  @override
  Future<List<Map<String, dynamic>>> listFor(String userId) {
    if (userId == 'account-a') {
      accountAStarted.complete();
      return accountAResult.future;
    }
    return Future.value([
      {'profile_id': kDefaultProfileId, 'name': 'Account B'},
    ]);
  }

  @override
  Future<void> delete(String userId, String profileId) async {}

  @override
  Future<void> upsert(String userId, ViewerProfile profile) async {}
}
