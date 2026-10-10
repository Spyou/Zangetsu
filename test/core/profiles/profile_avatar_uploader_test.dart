import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
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

  test(
    'compresses a large transparent PNG below the Worker size limit',
    () async {
      final adapter = _RecordingAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final source = img.Image(width: 512, height: 512, numChannels: 4);
      final random = Random(42);
      for (var y = 0; y < source.height; y++) {
        for (var x = 0; x < source.width; x++) {
          source.setPixelRgba(
            x,
            y,
            random.nextInt(256),
            random.nextInt(256),
            random.nextInt(256),
            128 + random.nextInt(128),
          );
        }
      }
      final png = img.encodePng(source, level: 0);
      expect(png.length, greaterThan(ProfileAvatarUploader.maxAvatarBytes));

      final result = await ProfileAvatarUploader(
        dio,
      ).upload(bytes: png, token: 'token');

      expect(result, 'https://cdn.example/avatar.jpg');
      expect(adapter.authorization, 'Bearer token');
      expect(adapter.contentType, 'image/png');
      expect(
        adapter.contentLength,
        lessThanOrEqualTo(ProfileAvatarUploader.maxAvatarBytes),
      );
      expect(adapter.uploadedBytes.length, adapter.contentLength);
      final uploaded = img.decodeImage(adapter.uploadedBytes)!;
      expect(uploaded.hasAlpha, isTrue);
      expect(uploaded.width, lessThan(512));
    },
  );

  test('uploads a small PNG with its actual content type', () async {
    final adapter = _RecordingAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final source = img.Image(width: 12, height: 12, numChannels: 4);
    source.clear(img.ColorRgba8(30, 60, 90, 120));
    final png = img.encodePng(source);

    final result = await ProfileAvatarUploader(
      dio,
    ).upload(bytes: png, token: 'token');

    expect(result, 'https://cdn.example/avatar.jpg');
    expect(adapter.requests, 1);
    expect(adapter.contentType, 'image/png');
  });

  test('compresses a large opaque image under the Worker size limit', () async {
    final adapter = _RecordingAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final source = img.Image(width: 512, height: 512, numChannels: 3);
    for (var y = 0; y < source.height; y++) {
      for (var x = 0; x < source.width; x++) {
        source.setPixelRgb(
          x,
          y,
          (x * 37 + y * 17) & 255,
          (x * 13 + y * 31) & 255,
          (x * 29 + y * 7) & 255,
        );
      }
    }
    final png = img.encodePng(source, level: 0);
    expect(png.length, greaterThan(ProfileAvatarUploader.maxAvatarBytes));

    final result = await ProfileAvatarUploader(
      dio,
    ).upload(bytes: png, token: 'token');

    expect(result, 'https://cdn.example/avatar.jpg');
    expect(adapter.contentType, 'image/jpeg');
    expect(
      adapter.contentLength,
      lessThanOrEqualTo(ProfileAvatarUploader.maxAvatarBytes),
    );
    expect(img.findFormatForData(adapter.uploadedBytes), img.ImageFormat.jpg);
    expect(img.decodeImage(adapter.uploadedBytes)!.hasAlpha, isFalse);
  });

  test('rejects non-image data without making an upload request', () async {
    final adapter = _RecordingAdapter();
    final dio = Dio()..httpClientAdapter = adapter;

    final result = await ProfileAvatarUploader(
      dio,
    ).upload(bytes: Uint8List.fromList([1, 2, 3]), token: 'token');

    expect(result, isNull);
    expect(adapter.requests, 0);
  });

  test('requests owner-checked deletion of an uploaded avatar URL', () async {
    final adapter = _RecordingAdapter();
    final dio = Dio()..httpClientAdapter = adapter;

    final deleted = await ProfileAvatarUploader(
      dio,
    ).delete(url: 'https://cdn.example/avatars/user/photo.jpg', token: 'token');

    expect(deleted, isTrue);
    expect(adapter.method, 'DELETE');
    expect(adapter.data, {'url': 'https://cdn.example/avatars/user/photo.jpg'});
    expect(adapter.authorization, 'Bearer token');
  });
}

class _RecordingAdapter implements HttpClientAdapter {
  int requests = 0;
  String? method;
  dynamic data;
  String? authorization;
  String? contentType;
  int? contentLength;
  Uint8List uploadedBytes = Uint8List(0);

  @override
  Future<ResponseBody> fetch(RequestOptions options, _, _) async {
    requests++;
    method = options.method;
    data = options.data;
    authorization = options.headers['Authorization'] as String?;
    contentType = options.headers[Headers.contentTypeHeader] as String?;
    contentLength = int.tryParse(
      options.headers[Headers.contentLengthHeader].toString(),
    );
    final chunks = <int>[];
    if (data is Stream<List<int>>) {
      await for (final chunk in data as Stream<List<int>>) {
        chunks.addAll(chunk);
      }
    }
    uploadedBytes = Uint8List.fromList(chunks);
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
