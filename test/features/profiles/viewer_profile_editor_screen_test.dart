import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:dio/dio.dart';
import 'package:watch_app/core/profiles/klipy_gif_service.dart';
import 'package:watch_app/core/profiles/viewer_profile.dart';
import 'package:watch_app/core/supabase/auth_user.dart';
import 'package:watch_app/core/theme/app_colors.dart';
import 'package:watch_app/features/auth/auth_cubit.dart';
import 'package:watch_app/features/profiles/viewer_profile_editor_screen.dart';

Widget _profileEditorHost(
  ValueChanged<ProfileEditorResult?> onResult, {
  ViewerProfile editingProfile = profile,
  KlipyGifService? klipyGifService,
  bool signedIn = true,
}) => BlocProvider<AuthCubit>(
  create: (_) => _RecordingAuthCubit(signedIn: signedIn),
  child: MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () {
            Navigator.of(context)
                .push<ProfileEditorResult>(
                  MaterialPageRoute<ProfileEditorResult>(
                    builder: (_) => ViewerProfileEditorScreen(
                      profile: editingProfile,
                      klipyGifService: klipyGifService,
                    ),
                  ),
                )
                .then(onResult);
          },
          child: const Text('Open editor'),
        ),
      ),
    ),
  ),
);

Widget _profileStoreEditorHost(
  ViewerProfileStore store, {
  ViewerProfile editingProfile = profile,
  ValueChanged<Future<void>>? onOpened,
  bool signedIn = true,
}) => BlocProvider<AuthCubit>(
  create: (_) => _RecordingAuthCubit(signedIn: signedIn),
  child: MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () {
            final future = openViewerProfileEditor(
              context,
              store,
              profile: editingProfile,
            );
            onOpened?.call(future);
          },
          child: const Text('Open editor'),
        ),
      ),
    ),
  ),
);

Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      target,
      240,
      scrollable: find.byType(Scrollable).last,
    );
  }
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

const profile = ViewerProfile(id: 'default', name: 'Home', avatar: 1);

void main() {
  testWidgets('editor uses one form and removes built-in avatar choices', (
    tester,
  ) async {
    await tester.pumpWidget(_profileEditorHost((_) {}));
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();

    final form = find.byKey(const ValueKey('profile-editor-form-card'));
    expect(form, findsOneWidget);
    expect(
      find.descendant(
        of: form,
        matching: find.byKey(const ValueKey('profile-editor-name')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: form,
        matching: find.byKey(const ValueKey('profile-editor-bio')),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('profile-editor-cover-card')),
      findsOneWidget,
    );
    expect(find.text('Choose an avatar'), findsNothing);
    expect(find.byKey(const ValueKey('profile-editor-avatar-0')), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('profile-editor-name')),
      'Evening',
    );
    await tester.pump();
    expect(
      find.descendant(
        of: form,
        matching: find.byKey(const ValueKey('profile-editor-preview-name')),
      ),
      findsOneWidget,
    );
  });

  testWidgets('signed-out users cannot open avatar or cover image pickers', (
    tester,
  ) async {
    await tester.pumpWidget(_profileEditorHost((_) {}, signedIn: false));
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Choose avatar'));
    await tester.pumpAndSettle();
    expect(find.text('Photo from gallery'), findsNothing);
    expect(find.byType(SnackBar), findsOneWidget);

    await _scrollTo(tester, find.text('Add cover'));
    await tester.tap(find.text('Add cover'));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('editor is a full page and returns the saved values', (
    tester,
  ) async {
    ProfileEditorResult? result;
    await tester.pumpWidget(_profileEditorHost((value) => result = value));
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Edit profile'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('profile-editor-name')),
      'Evening',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(result?.name, 'Evening');
    expect(result?.avatar, 1);
    expect(result?.isKids, isFalse);
  });

  testWidgets('editor saves and clears a viewer bio', (tester) async {
    ProfileEditorResult? result;
    await tester.pumpWidget(
      _profileEditorHost(
        (value) => result = value,
        editingProfile: const ViewerProfile(
          id: 'guest',
          name: 'Guest',
          bio: 'Old bio',
        ),
      ),
    );
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    final bioField = find.byKey(const ValueKey('profile-editor-bio'));
    await _scrollTo(tester, bioField);
    expect(tester.widget<TextField>(bioField).controller?.text, 'Old bio');
    await tester.enterText(bioField, 'New bio');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(result?.bio, 'New bio');
  });

  testWidgets('editor can remove the optional profile cover', (tester) async {
    ProfileEditorResult? result;
    await tester.pumpWidget(
      _profileEditorHost(
        (value) => result = value,
        editingProfile: const ViewerProfile(
          id: 'guest',
          name: 'Guest',
          coverUrl: 'https://cdn.example/cover.jpg',
        ),
      ),
    );
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    await _scrollTo(tester, find.text('Remove cover'));
    await tester.tap(find.text('Remove cover'));
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(result?.coverUrl, isNull);
  });

  testWidgets('cancel returns no profile changes', (tester) async {
    ProfileEditorResult? result;
    await tester.pumpWidget(_profileEditorHost((value) => result = value));
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('profile-editor-name')),
      'Discard',
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(result, isNull);
  });

  testWidgets('removing a profile photo restores its saved icon', (
    tester,
  ) async {
    final profiles = _RecordingProfileStore();
    const photoProfile = ViewerProfile(
      id: 'photo-profile',
      name: 'Photo profile',
      avatar: 4,
      photoUrl: 'https://cdn.example/deleted.jpg',
    );
    profiles.visibleProfiles = [
      photoProfile,
      const ViewerProfile(
        id: 'shared-photo-profile',
        name: 'Shared photo profile',
        photoUrl: 'https://cdn.example/deleted.jpg',
      ),
    ];
    profiles.synced = true;
    Future<void>? editorFinished;
    await tester.pumpWidget(
      _profileStoreEditorHost(
        profiles,
        editingProfile: photoProfile,
        onOpened: (future) => editorFinished = future,
      ),
    );
    await tester.tap(find.text('Open editor'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Change avatar'), findsOneWidget);
    await tester.tap(find.byTooltip('Remove avatar'));
    await tester.pump();

    expect(find.byType(Image), findsNothing);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await editorFinished!;

    expect(profiles.updatedAvatar, 4);
    expect(profiles.updatedPhotoUrl, isNull);
    expect(profiles.clearedPhotoUrl, isTrue);
  });

  testWidgets('photo picker keeps a sharp bounded source', (tester) async {
    const channel = MethodChannel('plugins.flutter.io/image_picker');
    MethodCall? pickedCall;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      pickedCall = call;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(_profileEditorHost((_) {}));
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose avatar'));
    await tester.pumpAndSettle();
    expect(find.text('Animated GIF file'), findsOneWidget);
    await tester.tap(find.text('Photo from gallery'));
    await tester.pump();

    expect(pickedCall?.method, 'pickImage');
    expect(pickedCall?.arguments['maxWidth'], 768.0);
    expect(pickedCall?.arguments['maxHeight'], 768.0);
    expect(pickedCall?.arguments['imageQuality'], 100);
  });

  testWidgets('photo picker offers GIF search', (tester) async {
    await tester.pumpWidget(_profileEditorHost((_) {}));
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose avatar'));
    await tester.pumpAndSettle();

    expect(find.text('Search GIFs'), findsOneWidget);
    expect(
      tester.widget<BottomSheet>(find.byType(BottomSheet)).backgroundColor,
      AppColors.surface,
    );
  });

  testWidgets('choosing a searched GIF saves its durable media URL', (
    tester,
  ) async {
    final gifService = _FakeKlipyGifService();
    ProfileEditorResult? result;
    await tester.pumpWidget(
      _profileEditorHost(
        (value) => result = value,
        klipyGifService: gifService,
      ),
    );
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose avatar'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Search GIFs'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('profile-gif-search')),
      'zoro',
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('Powered by KLIPY'), findsOneWidget);
    expect(gifService.searches, ['zoro']);
    await tester.tap(
      find.byKey(const ValueKey('profile-gif-option-zoro-wave')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(result?.photoUrl, 'https://static.klipy.com/zoro-avatar.gif');
    expect(gifService.registeredQuery, 'zoro');
  });

  testWidgets('cover picker requests a bounded wide source', (tester) async {
    const channel = MethodChannel('plugins.flutter.io/image_picker');
    MethodCall? pickedCall;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      pickedCall = call;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(_profileEditorHost((_) {}));
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    await _scrollTo(tester, find.text('Add cover'));
    await tester.tap(find.text('Add cover'));
    await tester.pump();

    expect(pickedCall?.method, 'pickImage');
    expect(pickedCall?.arguments['maxWidth'], 1600.0);
    expect(pickedCall?.arguments['maxHeight'], 900.0);
  });

  testWidgets(
    'edit saves the name and kids setting without changing the avatar',
    (tester) async {
      final store = _RecordingProfileStore();
      await tester.pumpWidget(_profileStoreEditorHost(store));
      await tester.tap(find.text('Open editor'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('profile-editor-name')),
        'Evening',
      );
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.text('Kids profile'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kids profile'));
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(store.renamedTo, 'Evening');
      expect(store.updatedAvatar, 1);
      expect(store.updatedIsKids, isTrue);
    },
  );

  testWidgets('renaming Home updates the sign-in account name', (tester) async {
    final store = _RecordingProfileStore();
    final auth = _RecordingAuthCubit();
    GetIt.instance.registerSingleton<AuthCubit>(auth);
    addTearDown(() async {
      await GetIt.instance.unregister<AuthCubit>();
      await auth.close();
    });
    await tester.pumpWidget(_profileStoreEditorHost(store));
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('profile-editor-name')),
      'Evening',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(auth.renamedTo, 'Evening');
    expect(store.renamedTo, 'Evening');
  });

  testWidgets('renaming another viewer leaves the account name alone', (
    tester,
  ) async {
    final store = _RecordingProfileStore();
    final auth = _RecordingAuthCubit();
    GetIt.instance.registerSingleton<AuthCubit>(auth);
    addTearDown(() async {
      await GetIt.instance.unregister<AuthCubit>();
      await auth.close();
    });
    await tester.pumpWidget(
      _profileStoreEditorHost(
        store,
        editingProfile: const ViewerProfile(id: 'guest', name: 'Guest'),
      ),
    );
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('profile-editor-name')),
      'Family',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(auth.renamedTo, isNull);
    expect(store.renamedTo, 'Family');
  });

  testWidgets('failed account rename leaves Home name unchanged', (
    tester,
  ) async {
    final store = _RecordingProfileStore();
    final auth = _RecordingAuthCubit()..succeeds = false;
    GetIt.instance.registerSingleton<AuthCubit>(auth);
    addTearDown(() async {
      await GetIt.instance.unregister<AuthCubit>();
      await auth.close();
    });
    await tester.pumpWidget(_profileStoreEditorHost(store));
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('profile-editor-name')),
      'Evening',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(auth.renamedTo, 'Evening');
    expect(store.renamedTo, isNull);
    expect(find.text('Could not update account name'), findsOneWidget);
  });

  testWidgets('failed Home rename restores the account name', (tester) async {
    final store = _RecordingProfileStore()..renameSucceeds = false;
    final auth = _RecordingAuthCubit();
    GetIt.instance.registerSingleton<AuthCubit>(auth);
    addTearDown(() async {
      await GetIt.instance.unregister<AuthCubit>();
      await auth.close();
    });
    await tester.pumpWidget(_profileStoreEditorHost(store));
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('profile-editor-name')),
      'Evening',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(auth.renameCalls, ['Evening', 'Home']);
    expect(store.renameCalls, ['Evening', 'Home']);
    expect(find.text('Could not update profile name'), findsOneWidget);
  });

  testWidgets('reports when profile changes are queued for cloud sync', (
    tester,
  ) async {
    final store = _RecordingProfileStore();
    Future<void>? editorFinished;
    await tester.pumpWidget(
      _profileStoreEditorHost(
        store,
        onOpened: (future) => editorFinished = future,
      ),
    );
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await editorFinished!;

    expect(
      find.text('Saved on this device; cloud sync will retry.'),
      findsOneWidget,
    );
  });
}

class _RecordingAuthCubit extends Cubit<AuthState> implements AuthCubit {
  _RecordingAuthCubit({bool signedIn = true})
    : super(
        signedIn
            ? const AuthState(
                status: AuthStatus.authenticated,
                user: AuthUser(
                  id: 'user',
                  name: 'Home',
                  email: 'user@example.com',
                ),
              )
            : const AuthState(status: AuthStatus.unauthenticated),
      );

  String? renamedTo;
  final renameCalls = <String>[];
  bool succeeds = true;

  @override
  Future<bool> updateName(String name) async {
    renamedTo = name;
    renameCalls.add(name);
    return succeeds;
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingProfileStore extends ViewerProfileStore {
  List<ViewerProfile> visibleProfiles = [];
  bool synced = false;
  String? renamedTo;
  final renameCalls = <String>[];
  bool renameSucceeds = true;
  int? updatedAvatar;
  bool? updatedIsKids;
  String? updatedPhotoUrl;
  bool? clearedPhotoUrl;
  String? updatedBio;
  String? updatedCoverUrl;
  bool? clearedCoverUrl;

  @override
  List<ViewerProfile> get profiles => visibleProfiles;

  @override
  Future<bool> rename(String profileId, String name) async {
    renamedTo = name;
    renameCalls.add(name);
    return renameSucceeds;
  }

  @override
  Future<bool> update(
    String profileId, {
    String? bio,
    int? avatar,
    bool? isKids,
    String? photoUrl,
    bool clearPhotoUrl = false,
    String? coverUrl,
    bool clearCoverUrl = false,
  }) async {
    updatedAvatar = avatar;
    updatedBio = bio;
    updatedIsKids = isKids;
    updatedPhotoUrl = photoUrl;
    clearedPhotoUrl = clearPhotoUrl;
    updatedCoverUrl = coverUrl;
    clearedCoverUrl = clearCoverUrl;
    return synced;
  }
}

class _FakeKlipyGifService extends KlipyGifService {
  _FakeKlipyGifService()
    : super(
        Dio(),
        baseUrl: 'https://sync.AniAura.online/klipy/v1',
        accessToken: () => 'test-access-token',
      );

  static const gif = KlipyGif(
    slug: 'zoro-wave',
    title: 'Zoro Wave',
    thumbnailUrl: 'https://static.klipy.com/zoro-small.gif',
    avatarUrl: 'https://static.klipy.com/zoro-avatar.gif',
  );

  final searches = <String>[];
  String? registeredQuery;

  @override
  Future<List<KlipyGif>> search(
    String query, {
    CancelToken? cancelToken,
  }) async {
    searches.add(query);
    return [gif];
  }

  @override
  Future<void> registerSelection(KlipyGif gif, String query) async {
    registeredQuery = query;
  }

  @override
  Future<String?> avatarUrlForSlug(String slug) async =>
      slug == gif.slug ? gif.avatarUrl : null;
}
