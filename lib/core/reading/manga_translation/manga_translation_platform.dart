import 'package:flutter/services.dart';

import 'manga_page_translation_models.dart';

/// Platform boundary for manga-page OCR and on-device translation.
abstract interface class MangaTranslationPlatform {
  Future<Set<String>> supportedOcrLanguages();

  Future<Set<String>> supportedOfflineLanguages();

  Future<MangaTranslationModelStatus> modelStatus({
    required String sourceLanguage,
    required String targetLanguage,
    required MangaTranslationEngine engine,
  });

  Future<void> downloadModels({
    required String sourceLanguage,
    required String targetLanguage,
    required MangaTranslationEngine engine,
  });

  Future<MangaPageOcrResult> recognize({
    required String filePath,
    required String sourceLanguage,
  });

  Future<List<String>> translateTexts({
    required List<String> texts,
    required String sourceLanguage,
    required String targetLanguage,
  });
}

/// A native manga-translation operation failed or returned an invalid result.
class MangaTranslationPlatformException implements Exception {
  const MangaTranslationPlatformException({
    required this.code,
    required this.message,
    this.details,
  });

  final String code;
  final String message;
  final Object? details;

  @override
  String toString() => 'MangaTranslationPlatformException($code): $message';
}

/// Flutter method-channel implementation shared by Android and iOS.
class MangaTranslationMethodChannelPlatform
    implements MangaTranslationPlatform {
  const MangaTranslationMethodChannelPlatform();

  static const MethodChannel _channel = MethodChannel(
    'AniAura/manga_translation',
  );

  @override
  Future<Set<String>> supportedOcrLanguages() async {
    final raw = await _invoke<Object?>('supportedOcrLanguages');
    return _parseResponse(
      () => Set.unmodifiable(_parseStringList(raw, 'supportedOcrLanguages')),
    );
  }

  @override
  Future<Set<String>> supportedOfflineLanguages() async {
    final raw = await _invoke<Object?>('supportedOfflineLanguages');
    return _parseResponse(
      () =>
          Set.unmodifiable(_parseStringList(raw, 'supportedOfflineLanguages')),
    );
  }

  @override
  Future<MangaTranslationModelStatus> modelStatus({
    required String sourceLanguage,
    required String targetLanguage,
    required MangaTranslationEngine engine,
  }) async {
    final raw = await _invoke<Object?>(
      'modelStatus',
      _languageArguments(sourceLanguage, targetLanguage, engine),
    );
    return _parseResponse(() {
      final map = _asStringKeyedMap(raw, 'modelStatus');
      return MangaTranslationModelStatus(
        ocrReady: _asBool(map['ocrReady'], 'ocrReady'),
        sourceTranslationReady: _asBool(
          map['sourceTranslationReady'],
          'sourceTranslationReady',
        ),
        targetTranslationReady: _asBool(
          map['targetTranslationReady'],
          'targetTranslationReady',
        ),
      );
    });
  }

  @override
  Future<void> downloadModels({
    required String sourceLanguage,
    required String targetLanguage,
    required MangaTranslationEngine engine,
  }) async {
    await _invoke<Object?>(
      'downloadModels',
      _languageArguments(sourceLanguage, targetLanguage, engine),
    );
  }

  @override
  Future<MangaPageOcrResult> recognize({
    required String filePath,
    required String sourceLanguage,
  }) async {
    final raw = await _invoke<Object?>('recognize', {
      'filePath': filePath,
      'sourceLanguage': sourceLanguage,
    });
    return _parseResponse(() {
      final map = _asStringKeyedMap(raw, 'recognize');
      final rawRegions = map['regions'];
      if (rawRegions is! List) {
        throw const FormatException('regions must be a list');
      }
      final regions = rawRegions.map((rawRegion) {
        final region = _asStringKeyedMap(rawRegion, 'region');
        return MangaOcrRegion(
          text: _asString(region['text'], 'text'),
          normalizedBounds: Rect.fromLTRB(
            _asNum(region['left'], 'left').toDouble(),
            _asNum(region['top'], 'top').toDouble(),
            _asNum(region['right'], 'right').toDouble(),
            _asNum(region['bottom'], 'bottom').toDouble(),
          ),
        );
      });
      return MangaPageOcrResult(
        imageWidth: _asInt(map['imageWidth'], 'imageWidth'),
        imageHeight: _asInt(map['imageHeight'], 'imageHeight'),
        regions: regions,
      );
    });
  }

  @override
  Future<List<String>> translateTexts({
    required List<String> texts,
    required String sourceLanguage,
    required String targetLanguage,
  }) async {
    final inputCount = texts.length;
    final raw = await _invoke<Object?>('translateTexts', {
      'sourceLanguage': sourceLanguage,
      'targetLanguage': targetLanguage,
      'texts': List<String>.of(texts),
    });
    return _parseResponse(() {
      final translated = _parseStringList(raw, 'translateTexts');
      if (translated.length != inputCount) {
        throw FormatException(
          'translateTexts returned ${translated.length} strings for '
          '$inputCount inputs',
        );
      }
      return List.unmodifiable(translated);
    });
  }

  Map<String, Object?> _languageArguments(
    String sourceLanguage,
    String targetLanguage,
    MangaTranslationEngine engine,
  ) => {
    'sourceLanguage': sourceLanguage,
    'targetLanguage': targetLanguage,
    'engine': engine.name,
  };

  Future<T?> _invoke<T>(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (error) {
      throw MangaTranslationPlatformException(
        code: error.code,
        message: error.message ?? 'Native manga translation operation failed.',
        details: error.details,
      );
    } on MissingPluginException catch (error) {
      throw MangaTranslationPlatformException(
        code: 'not_implemented',
        message: error.message ?? 'Manga translation is unavailable here.',
      );
    }
  }

  T _parseResponse<T>(T Function() parse) {
    try {
      return parse();
    } on MangaTranslationPlatformException {
      rethrow;
    } on Object catch (error) {
      if (error is FormatException ||
          error is TypeError ||
          error is ArgumentError) {
        throw MangaTranslationPlatformException(
          code: 'invalid_response',
          message: 'Native manga translation returned an invalid response.',
          details: error.toString(),
        );
      }
      rethrow;
    }
  }

  static Map<String, Object?> _asStringKeyedMap(Object? raw, String field) {
    if (raw is! Map) {
      throw FormatException('$field must be a map');
    }
    final result = <String, Object?>{};
    for (final entry in raw.entries) {
      if (entry.key is! String) {
        throw FormatException('$field keys must be strings');
      }
      result[entry.key as String] = entry.value;
    }
    return result;
  }

  static List<String> _parseStringList(Object? raw, String field) {
    if (raw is! List) {
      throw FormatException('$field must be a list');
    }
    return raw.map((value) => _asString(value, field)).toList(growable: false);
  }

  static String _asString(Object? raw, String field) {
    if (raw is! String) throw FormatException('$field must be a string');
    return raw;
  }

  static bool _asBool(Object? raw, String field) {
    if (raw is! bool) throw FormatException('$field must be a bool');
    return raw;
  }

  static int _asInt(Object? raw, String field) {
    if (raw is! int) throw FormatException('$field must be an integer');
    return raw;
  }

  static num _asNum(Object? raw, String field) {
    if (raw is! num) throw FormatException('$field must be numeric');
    return raw;
  }
}
