import 'dart:typed_data';

import 'package:dio/dio.dart';
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

  test('does not send avatar photos larger than 256 KiB', () async {
    final adapter = _RecordingAdapter();
    final dio = Dio()..httpClientAdapter = adapter;

    final result = await ProfileAvatarUploader(dio).upload(
      bytes: Uint8List(256 * 1024 + 1),
      contentType: 'image/jpeg',
      token: 'token',
    );

    expect(result, isNull);
    expect(adapter.requests, 0);
  });

  test('allows an avatar photo exactly at the 256 KiB limit', () async {
    final adapter = _RecordingAdapter();
    final dio = Dio()..httpClientAdapter = adapter;

    final result = await ProfileAvatarUploader(dio).upload(
      bytes: Uint8List(256 * 1024),
      contentType: 'image/jpeg',
      token: 'token',
    );

    expect(result, 'https://cdn.example/avatar.jpg');
    expect(adapter.requests, 1);
  });
}

class _RecordingAdapter implements HttpClientAdapter {
  int requests = 0;

  @override
  Future<ResponseBody> fetch(RequestOptions options, _, _) async {
    requests++;
    return ResponseBody.fromString(
      '{"url":"https://cdn.example/avatar.jpg"}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
