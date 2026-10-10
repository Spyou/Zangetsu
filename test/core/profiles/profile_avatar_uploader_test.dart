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

  test('preserves accepted animated GIF data for looping playback', () async {
    final adapter = _RecordingAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final gif = _animatedGif();

    final result = await ProfileAvatarUploader(
      dio,
    ).upload(bytes: gif, token: 'token');

    expect(result, 'https://cdn.example/avatar.gif');
    expect(adapter.contentType, 'image/gif');
    expect(ProfileAvatarUploader.isAllowedGif(adapter.uploadedBytes), isTrue);
    expect(adapter.uploadedBytes, gif);
    expect(img.decodeGif(adapter.uploadedBytes)!.numFrames, 2);
  });

  test('forces finite GIFs to loop forever without losing frames', () async {
    final adapter = _RecordingAdapter();
    final dio = Dio()..httpClientAdapter = adapter;

    await ProfileAvatarUploader(
      dio,
    ).upload(bytes: _animatedGif(repeat: 2), token: 'token');

    final uploaded = img.decodeGif(adapter.uploadedBytes)!;
    expect(uploaded.loopCount, 0);
    expect(uploaded.numFrames, 2);
    expect(_hasLoopMetadata(adapter.uploadedBytes), isTrue);
  });

  test('adds looping metadata when the source GIF has none', () async {
    final adapter = _RecordingAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final gifWithoutLoopMetadata = _withoutLoopMetadata(_animatedGif());

    await ProfileAvatarUploader(
      dio,
    ).upload(bytes: gifWithoutLoopMetadata, token: 'token');

    final uploaded = img.decodeGif(adapter.uploadedBytes)!;
    expect(uploaded.loopCount, 0);
    expect(uploaded.numFrames, 2);
    expect(_hasLoopMetadata(adapter.uploadedBytes), isTrue);
  });

  test(
    'resizes GIFs wider than the Worker limit without losing color',
    () async {
      final adapter = _RecordingAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final source = img.GifEncoder(repeat: 0, samplingFactor: 1);
      source.addFrame(
        img.Image(width: 640, height: 40, numChannels: 3)
          ..clear(img.ColorRgb8(240, 20, 30)),
        duration: 10,
      );
      source.addFrame(
        img.Image(width: 640, height: 40, numChannels: 3)
          ..clear(img.ColorRgb8(20, 30, 240)),
        duration: 10,
      );
      final gif = source.finish()!;

      await ProfileAvatarUploader(dio).upload(bytes: gif, token: 'token');

      final uploaded = img.decodeGif(adapter.uploadedBytes)!;
      expect(uploaded.width, 512);
      expect(uploaded.height, 32);
      expect(uploaded.frames.first.getPixel(0, 0).r.toInt(), greaterThan(200));
      expect(uploaded.frames.last.getPixel(0, 0).b.toInt(), greaterThan(200));
    },
  );

  test('keeps a 700px photo sharp when it fits the byte limit', () async {
    final adapter = _RecordingAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final source = img.Image(width: 700, height: 700, numChannels: 3)
      ..clear(img.ColorRgb8(30, 60, 90));
    final png = img.encodePng(source);
    expect(png.length, lessThanOrEqualTo(ProfileAvatarUploader.maxAvatarBytes));

    await ProfileAvatarUploader(dio).upload(bytes: png, token: 'token');

    final uploaded = img.decodeImage(adapter.uploadedBytes)!;
    expect(uploaded.width, 700);
    expect(uploaded.height, 700);
  });

  test(
    'preserves photo proportions when a large image is compressed',
    () async {
      final adapter = _RecordingAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final source = img.Image(width: 1200, height: 600, numChannels: 3);
      final random = Random(7);
      for (var y = 0; y < source.height; y++) {
        for (var x = 0; x < source.width; x++) {
          source.setPixelRgb(
            x,
            y,
            random.nextInt(256),
            random.nextInt(256),
            random.nextInt(256),
          );
        }
      }
      final png = img.encodePng(source, level: 0);
      expect(png.length, greaterThan(ProfileAvatarUploader.maxAvatarBytes));

      await ProfileAvatarUploader(dio).upload(bytes: png, token: 'token');

      final uploaded = img.decodeImage(adapter.uploadedBytes)!;
      expect(uploaded.width / uploaded.height, closeTo(2, 0.01));
    },
  );

  test('compresses large GIFs to the avatar size and frame limits', () async {
    final adapter = _RecordingAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final gif = _largeAnimatedGif();
    expect(gif.length, greaterThan(ProfileAvatarUploader.maxAvatarBytes));

    final result = await ProfileAvatarUploader(
      dio,
    ).upload(bytes: gif, token: 'token');

    expect(result, 'https://cdn.example/avatar.gif');
    expect(adapter.contentType, 'image/gif');
    expect(ProfileAvatarUploader.isAllowedGif(adapter.uploadedBytes), isTrue);
    expect(
      adapter.contentLength,
      lessThanOrEqualTo(ProfileAvatarUploader.maxAvatarBytes),
    );
    final uploaded = img.decodeGif(adapter.uploadedBytes)!;
    expect(uploaded.width, lessThanOrEqualTo(512));
    expect(uploaded.height, lessThanOrEqualTo(512));
    expect(uploaded.numFrames, lessThanOrEqualTo(60));
    expect(uploaded.loopCount, 0);
    expect(
      uploaded.frames.fold<int>(
        0,
        (total, frame) => total + frame.frameDuration,
      ),
      2800,
    );
  });

  test(
    'rejects GIFs beyond the safe source-frame bound before upload',
    () async {
      final adapter = _RecordingAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final encoder = img.GifEncoder(repeat: 0, samplingFactor: 1);
      for (var i = 0; i <= ProfileAvatarUploader.maxGifSourceFrames; i++) {
        encoder.addFrame(
          img.Image(width: 1, height: 1, numChannels: 3)
            ..clear(img.ColorRgb8(i & 255, 0, 0)),
          duration: 1,
        );
      }

      final result = await ProfileAvatarUploader(
        dio,
      ).upload(bytes: encoder.finish()!, token: 'token');

      expect(result, isNull);
      expect(adapter.requests, 0);
    },
  );

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

Uint8List _animatedGif({int repeat = 0}) {
  final encoder = img.GifEncoder(repeat: repeat, samplingFactor: 1);
  for (final color in [img.ColorRgb8(255, 0, 0), img.ColorRgb8(0, 0, 255)]) {
    final frame = img.Image(width: 8, height: 8, numChannels: 3)..clear(color);
    encoder.addFrame(frame, duration: 10);
  }
  return encoder.finish()!;
}

Uint8List _largeAnimatedGif() {
  final encoder = img.GifEncoder(repeat: 2, samplingFactor: 1);
  final random = Random(42);
  for (var frameIndex = 0; frameIndex < 70; frameIndex++) {
    final frame = img.Image(width: 80, height: 80, numChannels: 3);
    for (var y = 0; y < frame.height; y++) {
      for (var x = 0; x < frame.width; x++) {
        frame.setPixelRgb(
          x,
          y,
          random.nextInt(256),
          random.nextInt(256),
          random.nextInt(256),
        );
      }
    }
    encoder.addFrame(frame, duration: 4);
  }
  return encoder.finish()!;
}

Uint8List _withoutLoopMetadata(Uint8List gif) {
  for (var start = 0; start + 19 <= gif.length; start++) {
    if (gif[start] != 0x21 || gif[start + 1] != 0xff || gif[start + 2] != 11) {
      continue;
    }
    if (String.fromCharCodes(gif.sublist(start + 3, start + 14)) !=
        'NETSCAPE2.0') {
      continue;
    }
    return Uint8List.fromList([
      ...gif.sublist(0, start),
      ...gif.sublist(start + 19),
    ]);
  }
  throw StateError('GIF fixture has no Netscape loop extension');
}

bool _hasLoopMetadata(Uint8List gif) {
  for (var start = 0; start + 14 <= gif.length; start++) {
    if (gif[start] == 0x21 &&
        gif[start + 1] == 0xff &&
        gif[start + 2] == 11 &&
        String.fromCharCodes(gif.sublist(start + 3, start + 14)) ==
            'NETSCAPE2.0') {
      return true;
    }
  }
  return false;
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
    final extension = contentType == 'image/gif' ? 'gif' : 'jpg';
    return ResponseBody.fromString(
      '{"url":"https://cdn.example/avatar.$extension"}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
