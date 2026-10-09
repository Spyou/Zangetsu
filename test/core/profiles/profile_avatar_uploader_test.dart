import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/profiles/profile_avatar_uploader.dart';

void main() {
  test('urlOf takes the Worker public URL', () {
    expect(
      ProfileAvatarUploader.urlOf({'url': 'https://cdn.example/a.jpg'}),
      'https://cdn.example/a.jpg',
    );
  });

  test('urlOf rejects error payloads and junk', () {
    expect(ProfileAvatarUploader.urlOf({'error': 'unauthorized'}), isNull);
    expect(ProfileAvatarUploader.urlOf('<html>login</html>'), isNull);
    expect(ProfileAvatarUploader.urlOf(null), isNull);
  });
}
