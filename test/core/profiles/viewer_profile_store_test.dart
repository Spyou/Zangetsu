import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/profiles/viewer_profile.dart';
import 'package:watch_app/core/profiles/profile_scope.dart';
import 'package:watch_app/core/playback/resume_store.dart';
import 'package:watch_app/core/theme/app_colors.dart';
import 'package:watch_app/core/theme/theme_controller.dart';

void main() {
  late Directory directory;
  late ViewerProfileStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('viewer_profiles');
    Hive.init(directory.path);
    await ViewerProfileStore.init();
    await ThemeController.init();
    await ThemeController.setAccent(AppColors.defaultAccent);
    await ThemeController.setMaterialYou(false);
    await ThemeController.setAmoled(false);
    await ThemeController.applyProfileTheme(
      accentColor: null,
      materialYou: null,
      amoled: null,
    );
    store = ViewerProfileStore();
    await store.loadForUser(displayName: 'Account');
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
    'logout separates guest data while preserving the account cache',
    () async {
      String? owner = 'account-a';
      final profiles = ViewerProfileStore(currentUserId: () => owner);
      await profiles.loadForUser();
      expect(profiles.dataProfileId, kDefaultProfileId);
      final history = await Hive.openBox('watch_history');
      await history.put('private-title', {'title': 'Private account title'});
      owner = null;
      await profiles.loadForUser();
      expect(profiles.dataProfileId, isNot(kDefaultProfileId));
      expect(profileOwnsKey('private-title', profiles.dataProfileId), isFalse);
      final guestKey = profileScopedKey(profiles.dataProfileId, 'guest-title');
      await history.put(guestKey, {'title': 'Guest title'});
      final restarted = ViewerProfileStore(currentUserId: () => owner);
      await restarted.loadForUser();
      expect(profileOwnsKey(guestKey, restarted.dataProfileId), isTrue);
      owner = 'account-a';
      await restarted.loadForUser();
      expect(restarted.dataProfileId, kDefaultProfileId);
      expect(history.get('private-title')['title'], 'Private account title');
      expect(profileOwnsKey(guestKey, restarted.dataProfileId), isFalse);
    },
  );

  test(
    'a device that never signed in retains its existing guest history',
    () async {
      expect(store.dataProfileId, kDefaultProfileId);
      expect(
        profileOwnsKey('existing-guest-title', store.dataProfileId),
        isTrue,
      );
    },
  );

  test(
    'older account caches are hidden from guest mode without moving rows',
    () async {
      await Hive.box(ViewerProfileStore.boxName).put('profiles:old-account', [
        const ViewerProfile(id: 'default', name: 'Private account').toJson(),
      ]);
      expect(store.dataProfileId, isNot(kDefaultProfileId));
      expect(profileOwnsKey('private-title', store.dataProfileId), isFalse);
    },
  );

  test(
    'guest playback positions stay separate from the signed-in profile',
    () async {
      String? owner = 'account-a';
      final profiles = ViewerProfileStore(currentUserId: () => owner);
      await profiles.loadForUser();
      await ResumeStore.init();
      final resume = ResumeStore(
        currentProfileId: () => profiles.dataProfileId,
      );
      await resume.save(
        'source',
        'show',
        'ep',
        const Duration(seconds: 90),
        const Duration(minutes: 24),
      );
      owner = null;
      await profiles.loadForUser();
      expect(resume.get('source', 'show', 'ep'), isNull);
      await resume.save(
        'source',
        'show',
        'ep',
        const Duration(seconds: 45),
        const Duration(minutes: 24),
      );
      owner = 'account-a';
      await profiles.loadForUser();
      expect(resume.get('source', 'show', 'ep')!.position.inSeconds, 90);
      owner = null;
      await profiles.loadForUser();
      expect(resume.get('source', 'show', 'ep')!.position.inSeconds, 45);
    },
  );

  test(
    'profile deletion retires lock metadata only after local cleanup',
    () async {
      final retired = <String>[];
      final profiles = ViewerProfileStore(
        onProfileDataDeleted: (owner, id) async {
          retired.add('$owner:$id');
        },
      );
      await profiles.loadForUser();
      final profile = (await profiles.create('Private'))!;
      expect(await profiles.delete(profile.id), isTrue);
      expect(retired, ['local:${profile.id}']);
      expect(await profiles.delete(kDefaultProfileId), isFalse);
      expect(retired, hasLength(1));
    },
  );

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
    'keeps the default profile first when cloud rows arrive out of order',
    () async {
      final remote = _MemoryProfileRemote()
        ..rows['custom-a'] = const ViewerProfile(
          id: 'custom-a',
          name: 'Custom A',
        )
        ..rows['custom-b'] = const ViewerProfile(
          id: 'custom-b',
          name: 'Custom B',
        )
        ..rows[kDefaultProfileId] = const ViewerProfile(
          id: kDefaultProfileId,
          name: 'Tamananna',
        );
      final cloudStore = ViewerProfileStore(
        remote: remote,
        currentUserId: () => 'test-user',
      );

      await cloudStore.loadForUser();

      expect(cloudStore.profiles.map((profile) => profile.id), [
        kDefaultProfileId,
        'custom-a',
        'custom-b',
      ]);
      expect(cloudStore.activeProfile.name, 'Tamananna');
    },
  );

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

  test('appearance theme follows the profile and syncs across reloads', () async {
    final remote = _MemoryProfileRemote();
    final cloudStore = ViewerProfileStore(
      remote: remote,
      currentUserId: () => 'test-user',
    );
    await cloudStore.loadForUser();
    final guest = (await cloudStore.create('Guest'))!;
    final blue = ThemeController.accentPresets[1].$2;
    final violet = ThemeController.accentPresets[2].$2;

    await cloudStore.updateTheme(
      kDefaultProfileId,
      accentColor: blue.toARGB32(),
      materialYou: false,
      amoled: true,
    );
    await cloudStore.updateTheme(
      guest.id,
      accentColor: violet.toARGB32(),
      materialYou: true,
      amoled: false,
    );

    await cloudStore.switchTo(guest.id);
    expect(ThemeController.accent, violet);
    // Keep the Android choice in cloud, but never lock the picker on other OSes.
    expect(cloudStore.activeProfile.materialYou, isTrue);
    expect(ThemeController.materialYou, isFalse);
    expect(ThemeController.amoled, isFalse);
    expect(AppColors.bg, AppColors.defaultBg);

    await cloudStore.switchTo(kDefaultProfileId);
    expect(ThemeController.accent, blue);
    expect(ThemeController.materialYou, isFalse);
    expect(ThemeController.amoled, isTrue);
    expect(AppColors.bg, ThemeController.amoledBg);
    expect(Hive.box(ThemeController.boxName).get('amoled'), isFalse);

    final reloaded = ViewerProfileStore(
      remote: remote,
      currentUserId: () => 'test-user',
    );
    await reloaded.loadForUser();
    expect(reloaded.activeProfile.accentColor, blue.toARGB32());
    expect(reloaded.activeProfile.amoled, isTrue);
    expect(ThemeController.accent, blue);
    expect(AppColors.bg, ThemeController.amoledBg);
  });

  test(
    'appearance changes remain local while profile sync is offline',
    () async {
      final remote = _MemoryProfileRemote();
      final cloudStore = ViewerProfileStore(
        remote: remote,
        currentUserId: () => 'test-user',
      );
      await cloudStore.loadForUser();
      remote.offline = true;
      final violet = ThemeController.accentPresets[2].$2;

      expect(
        await cloudStore.updateTheme(
          kDefaultProfileId,
          accentColor: violet.toARGB32(),
          materialYou: false,
          amoled: true,
        ),
        isFalse,
      );
      expect(ThemeController.accent, violet);
      expect(AppColors.bg, ThemeController.amoledBg);
      expect(cloudStore.activeProfile.accentColor, violet.toARGB32());

      remote.offline = false;
      final resumedStore = ViewerProfileStore(
        remote: remote,
        currentUserId: () => 'test-user',
      );
      await resumedStore.loadForUser();
      expect(remote.rows[kDefaultProfileId]?.accentColor, violet.toARGB32());
      expect(remote.rows[kDefaultProfileId]?.amoled, isTrue);
      expect(
        Hive.box(ViewerProfileStore.boxName).get('pending:test-user'),
        isEmpty,
      );
    },
  );

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
    'a cloud-deleted profile is not restored from the local cache',
    () async {
      final remote = _MemoryProfileRemote();
      final first = ViewerProfileStore(
        remote: remote,
        currentUserId: () => 'test-user',
      );
      await first.loadForUser();
      final guest = (await first.create('Guest'))!;
      remote.rows.remove(guest.id); // Deleted on another device.

      final reloaded = ViewerProfileStore(
        remote: remote,
        currentUserId: () => 'test-user',
      );
      await reloaded.loadForUser();

      expect(reloaded.profiles.any((p) => p.id == guest.id), isFalse);
      expect(remote.rows.containsKey(guest.id), isFalse);
      expect(
        Hive.box(ViewerProfileStore.boxName).get('recoverable:test-user'),
        contains(predicate((value) => value is Map && value['id'] == guest.id)),
      );
    },
  );

  test('keeps an old offline-only profile for explicit recovery', () async {
    final remote = _MemoryProfileRemote();
    final box = Hive.box(ViewerProfileStore.boxName);
    await box.put('profiles:test-user', [
      const ViewerProfile(id: kDefaultProfileId, name: 'Home').toJson(),
      const ViewerProfile(id: 'offline-guest', name: 'Offline Guest').toJson(),
    ]);
    remote.rows[kDefaultProfileId] = const ViewerProfile(
      id: kDefaultProfileId,
      name: 'Home',
    );

    final cloudStore = ViewerProfileStore(
      remote: remote,
      currentUserId: () => 'test-user',
    );
    await cloudStore.loadForUser();

    expect(cloudStore.profiles.map((p) => p.id), [kDefaultProfileId]);
    expect(remote.rows.containsKey('offline-guest'), isFalse);
    expect(
      box.get('recoverable:test-user'),
      contains(
        predicate((value) => value is Map && value['id'] == 'offline-guest'),
      ),
    );

    remote.offline = true;
    expect(await cloudStore.restoreRecoverable('offline-guest'), isFalse);
    expect(cloudStore.recoverableProfiles.single.id, 'offline-guest');
    remote.offline = false;
    expect(await cloudStore.restoreRecoverable('offline-guest'), isTrue);
    expect(remote.rows['offline-guest']?.name, 'Offline Guest');
    expect(cloudStore.profiles.any((p) => p.id == 'offline-guest'), isTrue);
    expect(cloudStore.recoverableProfiles, isEmpty);

    final reloaded = ViewerProfileStore(
      remote: remote,
      currentUserId: () => 'test-user',
    );
    await reloaded.loadForUser();
    expect(reloaded.profiles.any((p) => p.id == 'offline-guest'), isTrue);
  });

  test(
    'does not revive a cloud-deleted profile after an offline edit',
    () async {
      final remote = _MemoryProfileRemote();
      final first = ViewerProfileStore(
        remote: remote,
        currentUserId: () => 'test-user',
      );
      await first.loadForUser();
      final guest = (await first.create('Guest'))!;

      remote.offline = true;
      expect(await first.rename(guest.id, 'Edited offline'), isFalse);
      remote.offline = false;
      remote.rows.remove(guest.id); // Deleted from another device.
      final listBox = await Hive.openBox('my_list');
      await listBox.put('p:${guest.id}::saved-title', {'title': 'Guest title'});

      final reloaded = ViewerProfileStore(
        remote: remote,
        currentUserId: () => 'test-user',
      );
      await reloaded.loadForUser();

      expect(
        reloaded.profiles.any((profile) => profile.id == guest.id),
        isFalse,
      );
      expect(remote.rows.containsKey(guest.id), isFalse);
      expect(listBox.containsKey('p:${guest.id}::saved-title'), isFalse);
    },
  );

  test(
    'retries an offline edit while the cloud profile still exists',
    () async {
      final remote = _MemoryProfileRemote();
      final first = ViewerProfileStore(
        remote: remote,
        currentUserId: () => 'test-user',
      );
      await first.loadForUser();
      final guest = (await first.create('Guest'))!;

      remote.offline = true;
      expect(await first.rename(guest.id, 'Edited offline'), isFalse);
      remote.offline = false;

      final reloaded = ViewerProfileStore(
        remote: remote,
        currentUserId: () => 'test-user',
      );
      await reloaded.loadForUser();

      expect(
        reloaded.profiles.firstWhere((p) => p.id == guest.id).name,
        'Edited offline',
      );
      expect(remote.rows[guest.id]?.name, 'Edited offline');
    },
  );

  test(
    'an offline profile edit is retried without reviving other rows',
    () async {
      final remote = _MemoryProfileRemote();
      final first = ViewerProfileStore(
        remote: remote,
        currentUserId: () => 'test-user',
      );
      await first.loadForUser();
      remote.offline = true;
      final guest = (await first.create('Offline Guest'))!;
      expect(await first.rename(guest.id, 'Edited before first sync'), isFalse);
      expect(remote.rows.containsKey(guest.id), isFalse);
      remote.offline = false;

      final reloaded = ViewerProfileStore(
        remote: remote,
        currentUserId: () => 'test-user',
      );
      await reloaded.loadForUser();

      expect(reloaded.profiles.any((p) => p.id == guest.id), isTrue);
      expect(
        reloaded.profiles.firstWhere((p) => p.id == guest.id).name,
        'Edited before first sync',
      );
      expect(remote.rows[guest.id]?.name, 'Edited before first sync');
    },
  );

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

  test('deleting a profile removes its unshared cover object', () async {
    const coverUrl = 'https://cdn.example/avatars/user/cover.jpg';
    final deleted = <String>[];
    final profileStore = ViewerProfileStore(
      deleteAvatar: (url) async {
        deleted.add(url);
        return true;
      },
    );
    await profileStore.loadForUser();
    final guest = (await profileStore.create('Guest', coverUrl: coverUrl))!;

    expect(await profileStore.delete(guest.id), isTrue);
    expect(deleted, [coverUrl]);
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
      photoUrl: 'https://static.klipy.com/zoro-small.gif',
    );
    expect(created?.photoUrl, 'https://static.klipy.com/zoro-small.gif');
    await store.update(
      created!.id,
      photoUrl: 'https://static.klipy.com/zoro-avatar.gif',
    );
    expect(
      store.profiles.firstWhere((p) => p.id == created.id).photoUrl,
      'https://static.klipy.com/zoro-avatar.gif',
    );
    final again = ViewerProfileStore();
    await again.loadForUser(displayName: 'Account');
    expect(
      again.profiles.firstWhere((p) => p.id == created.id).photoUrl,
      'https://static.klipy.com/zoro-avatar.gif',
    );
  });

  test('bio is saved locally and syncs with its own viewer profile', () async {
    final remote = _MemoryProfileRemote();
    final first = ViewerProfileStore(
      remote: remote,
      currentUserId: () => 'test-user',
    );
    await first.loadForUser();
    final guest = (await first.create('Guest', bio: 'Watching anime'))!;
    expect(remote.rows[guest.id]?.bio, 'Watching anime');

    await first.update(guest.id, bio: 'Reading manga');
    final second = ViewerProfileStore(
      remote: remote,
      currentUserId: () => 'test-user',
    );
    await second.loadForUser();
    expect(
      second.profiles.firstWhere((p) => p.id == guest.id).bio,
      'Reading manga',
    );
    expect(second.activeProfile.bio, isEmpty);

    await second.update(guest.id, bio: '');
    expect(remote.rows[guest.id]?.bio, isEmpty);
    expect(await second.update(guest.id, bio: 'x' * 161), isFalse);
  });

  test('old cached profiles without a bio keep loading', () {
    expect(ViewerProfile.fromJson({'id': 'old', 'name': 'Old'}).bio, isEmpty);
  });

  test('profile cover survives cloud reload and can be cleared', () async {
    final remote = _MemoryProfileRemote();
    final first = ViewerProfileStore(
      remote: remote,
      currentUserId: () => 'test-user',
    );
    await first.loadForUser();
    final guest = (await first.create('Guest'))!;
    await first.update(guest.id, coverUrl: 'https://cdn.example/cover.jpg');
    expect(remote.rows[guest.id]?.coverUrl, 'https://cdn.example/cover.jpg');

    final second = ViewerProfileStore(
      remote: remote,
      currentUserId: () => 'test-user',
    );
    await second.loadForUser();
    expect(
      second.profiles.firstWhere((p) => p.id == guest.id).coverUrl,
      'https://cdn.example/cover.jpg',
    );

    await second.update(guest.id, clearCoverUrl: true);
    expect(remote.rows[guest.id]?.coverUrl, isNull);
    expect(
      ViewerProfile.fromJson({'id': 'old', 'name': 'Old'}).coverUrl,
      isNull,
    );
  });

  test(
    'offline cover change survives restart and retries cloud sync',
    () async {
      final remote = _MemoryProfileRemote();
      final first = ViewerProfileStore(
        remote: remote,
        currentUserId: () => 'test-user',
      );
      await first.loadForUser();
      final guest = (await first.create('Guest'))!;
      remote.offline = true;

      expect(
        await first.update(guest.id, coverUrl: 'https://cdn.example/cover.jpg'),
        isFalse,
      );

      remote.offline = false;
      final afterRestart = ViewerProfileStore(
        remote: remote,
        currentUserId: () => 'test-user',
      );
      await afterRestart.loadForUser();

      expect(
        afterRestart.profiles
            .firstWhere((profile) => profile.id == guest.id)
            .coverUrl,
        'https://cdn.example/cover.jpg',
      );
      expect(remote.rows[guest.id]?.coverUrl, 'https://cdn.example/cover.jpg');
    },
  );

  test(
    'emoji count as one bio character, matching the database limit',
    () async {
      final emojiBio = '😀' * 81;
      final created = await store.create('Emoji', bio: emojiBio);
      expect(created?.bio, emojiBio);
      expect(await store.update(created!.id, bio: '😀' * 161), isFalse);
    },
  );

  test('clears a profile photo only when explicitly requested', () async {
    final created = await store.create(
      'Pic',
      photoUrl: 'https://cdn.example/a.jpg',
    );

    await store.update(created!.id, isKids: true);
    expect(
      store.profiles.firstWhere((profile) => profile.id == created.id).photoUrl,
      'https://cdn.example/a.jpg',
    );

    await store.update(created.id, avatar: 4, clearPhotoUrl: true);

    expect(
      store.profiles.firstWhere((profile) => profile.id == created.id).photoUrl,
      isNull,
    );
    final again = ViewerProfileStore();
    await again.loadForUser(displayName: 'Account');
    expect(
      again.profiles.firstWhere((profile) => profile.id == created.id).photoUrl,
      isNull,
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

  test('reports a profile rename that did not reach the cloud', () async {
    final cloudStore = ViewerProfileStore(
      remote: _FailingUpsertProfileRemote(),
      currentUserId: () => 'test-user',
    );
    await cloudStore.loadForUser();

    final synced = await cloudStore.rename(kDefaultProfileId, 'Evening');

    expect(synced, isFalse);
    expect(cloudStore.activeProfile.name, 'Evening');
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

class _MemoryProfileRemote implements ViewerProfileRemote {
  final Map<String, ViewerProfile> rows = {};
  bool offline = false;

  @override
  Future<List<Map<String, dynamic>>> listFor(String userId) async => [
    for (final p in rows.values)
      {
        'profile_id': p.id,
        'name': p.name,
        'avatar': p.avatar,
        'is_kids': p.isKids,
        'photo_url': p.photoUrl,
        'cover_url': p.coverUrl,
        'bio': p.bio,
        'accent_color': p.accentColor,
        'material_you': p.materialYou,
        'amoled': p.amoled,
      },
  ];

  @override
  Future<void> upsert(String userId, ViewerProfile profile) async {
    if (offline) throw const SocketException('offline');
    rows[profile.id] = profile;
  }

  @override
  Future<void> delete(String userId, String profileId) async {
    if (offline) throw const SocketException('offline');
    rows.remove(profileId);
  }
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
