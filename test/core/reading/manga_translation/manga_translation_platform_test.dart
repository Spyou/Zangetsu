import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/reading/manga_translation/manga_page_translation_models.dart';
import 'package:watch_app/core/reading/manga_translation/manga_translation_platform.dart';

const _channel = MethodChannel('AniAura/manga_translation');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(_channel, null);
  });

  group('MangaTranslationMethodChannelPlatform', () {
    test('loads supported languages from their dedicated methods', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'supportedOcrLanguages' => <String>['ja', 'ko'],
          'supportedOfflineLanguages' => <String>['en', 'fr'],
          _ => throw PlatformException(code: 'not_implemented'),
        };
      });

      const platform = MangaTranslationMethodChannelPlatform();

      expect(await platform.supportedOcrLanguages(), {'ja', 'ko'});
      expect(await platform.supportedOfflineLanguages(), {'en', 'fr'});
      expect(calls.map((call) => call.method), [
        'supportedOcrLanguages',
        'supportedOfflineLanguages',
      ]);
    });

    test(
      'modelStatus checks readiness without starting a model download',
      () async {
        final calls = <MethodCall>[];
        messenger.setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          expect(call.method, 'modelStatus');
          expect(call.arguments, {
            'sourceLanguage': 'ja',
            'targetLanguage': 'en',
            'engine': 'offline',
          });
          return {
            'ocrReady': true,
            'sourceTranslationReady': true,
            'targetTranslationReady': false,
          };
        });

        const platform = MangaTranslationMethodChannelPlatform();
        final status = await platform.modelStatus(
          sourceLanguage: 'ja',
          targetLanguage: 'en',
          engine: MangaTranslationEngine.offline,
        );

        expect(status.ocrReady, isTrue);
        expect(status.sourceTranslationReady, isTrue);
        expect(status.targetTranslationReady, isFalse);
        expect(calls.map((call) => call.method), ['modelStatus']);
      },
    );

    test(
      'downloads models only through the explicit download method',
      () async {
        final calls = <MethodCall>[];
        messenger.setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          return null;
        });

        const platform = MangaTranslationMethodChannelPlatform();
        await platform.downloadModels(
          sourceLanguage: 'ja',
          targetLanguage: 'en',
          engine: MangaTranslationEngine.offline,
        );

        expect(calls, hasLength(1));
        expect(calls.single.method, 'downloadModels');
        expect(calls.single.arguments, {
          'sourceLanguage': 'ja',
          'targetLanguage': 'en',
          'engine': 'offline',
        });
      },
    );

    test(
      'recognize sends a local path and parses normalized top-left bounds',
      () async {
        MethodCall? receivedCall;
        messenger.setMockMethodCallHandler(_channel, (call) async {
          receivedCall = call;
          return {
            'imageWidth': 1200,
            'imageHeight': 1800,
            'regions': [
              {
                'text': 'こんにちは',
                'left': 0.1,
                'top': 0.2,
                'right': 0.8,
                'bottom': 0.3,
              },
            ],
          };
        });

        const platform = MangaTranslationMethodChannelPlatform();
        final result = await platform.recognize(
          filePath: '/local/cache/page.jpg',
          sourceLanguage: 'ja',
        );

        expect(receivedCall!.method, 'recognize');
        expect(receivedCall!.arguments, {
          'filePath': '/local/cache/page.jpg',
          'sourceLanguage': 'ja',
        });
        expect(result.imageWidth, 1200);
        expect(result.imageHeight, 1800);
        expect(result.regions, hasLength(1));
        expect(result.regions.single.text, 'こんにちは');
        expect(
          result.regions.single.normalizedBounds,
          const Rect.fromLTRB(0.1, 0.2, 0.8, 0.3),
        );
      },
    );

    test(
      'translateTexts sends text only and preserves exact response order',
      () async {
        MethodCall? receivedCall;
        messenger.setMockMethodCallHandler(_channel, (call) async {
          receivedCall = call;
          return <String>['first translated', 'second translated'];
        });

        const platform = MangaTranslationMethodChannelPlatform();
        final result = await platform.translateTexts(
          texts: ['first source', 'second source'],
          sourceLanguage: 'ja',
          targetLanguage: 'en',
        );

        expect(receivedCall!.method, 'translateTexts');
        expect(receivedCall!.arguments, {
          'sourceLanguage': 'ja',
          'targetLanguage': 'en',
          'texts': ['first source', 'second source'],
        });
        expect(result, ['first translated', 'second translated']);
        expect(result, hasLength(2));
        final argumentKeys =
            (receivedCall!.arguments as Map<Object?, Object?>).keys;
        expect(argumentKeys, isNot(contains('filePath')));
        expect(argumentKeys, isNot(contains('imageBytes')));
        expect(argumentKeys, isNot(contains('image')));
      },
    );

    test(
      'rejects a translation response with a different number of strings',
      () async {
        messenger.setMockMethodCallHandler(
          _channel,
          (call) async => ['only one'],
        );

        const platform = MangaTranslationMethodChannelPlatform();
        await expectLater(
          platform.translateTexts(
            texts: ['one', 'two'],
            sourceLanguage: 'ja',
            targetLanguage: 'en',
          ),
          throwsA(
            isA<MangaTranslationPlatformException>().having(
              (error) => error.code,
              'code',
              'invalid_response',
            ),
          ),
        );
      },
    );

    test(
      'maps native method failures into a typed platform exception',
      () async {
        messenger.setMockMethodCallHandler(_channel, (call) async {
          throw PlatformException(
            code: 'model_unavailable',
            message: 'The requested language is unsupported.',
            details: {'language': 'ja'},
          );
        });

        const platform = MangaTranslationMethodChannelPlatform();
        await expectLater(
          platform.supportedOcrLanguages(),
          throwsA(
            isA<MangaTranslationPlatformException>()
                .having((error) => error.code, 'code', 'model_unavailable')
                .having(
                  (error) => error.message,
                  'message',
                  'The requested language is unsupported.',
                )
                .having((error) => error.details, 'details', {
                  'language': 'ja',
                }),
          ),
        );
      },
    );

    test('maps malformed supported-language output to a typed error', () async {
      messenger.setMockMethodCallHandler(_channel, (call) async => ['ja', 7]);

      const platform = MangaTranslationMethodChannelPlatform();
      await expectLater(
        platform.supportedOcrLanguages(),
        throwsA(
          isA<MangaTranslationPlatformException>().having(
            (error) => error.code,
            'code',
            'invalid_response',
          ),
        ),
      );
    });

    test('maps an unimplemented native channel to a typed error', () async {
      messenger.setMockMethodCallHandler(_channel, (call) async {
        throw MissingPluginException('No manga translation handler.');
      });

      const platform = MangaTranslationMethodChannelPlatform();
      await expectLater(
        platform.supportedOcrLanguages(),
        throwsA(
          isA<MangaTranslationPlatformException>().having(
            (error) => error.code,
            'code',
            'not_implemented',
          ),
        ),
      );
    });

    test(
      'maps malformed native OCR output to a typed invalid-response error',
      () async {
        messenger.setMockMethodCallHandler(_channel, (call) async {
          return {
            'imageWidth': 1200,
            'imageHeight': 1800,
            'regions': [
              {
                'text': 'outside page',
                'left': -0.1,
                'top': 0.2,
                'right': 0.8,
                'bottom': 0.3,
              },
            ],
          };
        });

        const platform = MangaTranslationMethodChannelPlatform();
        await expectLater(
          platform.recognize(filePath: '/local/page.jpg', sourceLanguage: 'ja'),
          throwsA(
            isA<MangaTranslationPlatformException>().having(
              (error) => error.code,
              'code',
              'invalid_response',
            ),
          ),
        );
      },
    );
  });
}
