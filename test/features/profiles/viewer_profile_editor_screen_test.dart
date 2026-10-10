import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/profiles/viewer_profile.dart';
import 'package:watch_app/features/profiles/viewer_profile_editor_screen.dart';

Widget _profileEditorHost(ValueChanged<ProfileEditorResult?> onResult) =>
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () {
              Navigator.of(context)
                  .push<ProfileEditorResult>(
                    MaterialPageRoute<ProfileEditorResult>(
                      builder: (_) =>
                          const ViewerProfileEditorScreen(profile: profile),
                    ),
                  )
                  .then(onResult);
            },
            child: const Text('Open editor'),
          ),
        ),
      ),
    );

Widget _profileStoreEditorHost(_RecordingProfileStore store) => MaterialApp(
  home: Builder(
    builder: (context) => Scaffold(
      body: TextButton(
        onPressed: () =>
            openViewerProfileEditor(context, store, profile: profile),
        child: const Text('Open editor'),
      ),
    ),
  ),
);

const profile = ViewerProfile(id: 'default', name: 'Home', avatar: 1);

void main() {
  testWidgets('editor is a full page and returns the saved values', (
    tester,
  ) async {
    ProfileEditorResult? result;
    await tester.pumpWidget(_profileEditorHost((value) => result = value));
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Edit profile'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Evening');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(result?.name, 'Evening');
    expect(result?.avatar, 1);
    expect(result?.isKids, isFalse);
  });

  testWidgets('cancel returns no profile changes', (tester) async {
    ProfileEditorResult? result;
    await tester.pumpWidget(_profileEditorHost((value) => result = value));
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Discard');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(result, isNull);
  });

  testWidgets('photo picker keeps a sharp bounded 512 pixel source', (
    tester,
  ) async {
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
    await tester.tap(find.text('Choose photo'));
    await tester.pump();

    expect(pickedCall?.method, 'pickImage');
    expect(pickedCall?.arguments['maxWidth'], 512.0);
    expect(pickedCall?.arguments['maxHeight'], 512.0);
    expect(pickedCall?.arguments['imageQuality'], 90);
  });

  testWidgets('edit saves the entered name, avatar, and kids setting', (
    tester,
  ) async {
    final store = _RecordingProfileStore();
    await tester.pumpWidget(_profileStoreEditorHost(store));
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Evening');
    await tester.tap(find.byKey(const ValueKey('profile-editor-avatar-4')));
    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(store.renamedTo, 'Evening');
    expect(store.updatedAvatar, 4);
    expect(store.updatedIsKids, isTrue);
  });
}

class _RecordingProfileStore extends ViewerProfileStore {
  String? renamedTo;
  int? updatedAvatar;
  bool? updatedIsKids;

  @override
  Future<bool> rename(String profileId, String name) async {
    renamedTo = name;
    return true;
  }

  @override
  Future<bool> update(
    String profileId, {
    int? avatar,
    bool? isKids,
    String? photoUrl,
  }) async {
    updatedAvatar = avatar;
    updatedIsKids = isKids;
    return true;
  }
}
