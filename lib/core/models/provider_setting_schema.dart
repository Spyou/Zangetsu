/// Typed representation of one entry in a provider's `getSettings()`
/// return value. The JS side is loosely typed — this model is the
/// trust boundary: a malformed entry is silently skipped instead of
/// crashing the settings form.
enum ProviderSettingType { bool_, enum_, multiEnum, text }

class ProviderSettingOption {
  const ProviderSettingOption({required this.value, required this.label});
  final String value;
  final String label;

  static ProviderSettingOption? tryParse(dynamic raw) {
    if (raw is! Map) return null;
    final v = raw['value'];
    final l = raw['label'];
    if (v is! String || l is! String) return null;
    return ProviderSettingOption(value: v, label: l);
  }
}

class ProviderSettingSchema {
  const ProviderSettingSchema({
    required this.key,
    required this.label,
    required this.type,
    required this.defaultValue,
    this.options = const [],
  });

  final String key;
  final String label;
  final ProviderSettingType type;

  /// The provider-supplied default. Already coerced to the right Dart
  /// shape for [type] — `bool` for bool_, `String` for enum_/text,
  /// `List<String>` for multiEnum.
  final Object? defaultValue;

  /// Empty for `bool_` and `text`. For enum / multiEnum these are the
  /// selectable options in display order.
  final List<ProviderSettingOption> options;

  static ProviderSettingType? _parseType(dynamic raw) {
    if (raw is! String) return null;
    switch (raw) {
      case 'bool':
        return ProviderSettingType.bool_;
      case 'enum':
        return ProviderSettingType.enum_;
      case 'multiEnum':
        return ProviderSettingType.multiEnum;
      case 'text':
        return ProviderSettingType.text;
    }
    return null;
  }

  /// Tolerant parser. Returns null for any entry that's missing
  /// required fields or whose default value doesn't match its declared
  /// type — the form drops those rows rather than rendering a broken
  /// widget that can't roundtrip the value.
  static ProviderSettingSchema? tryParse(dynamic raw) {
    if (raw is! Map) return null;
    final key = raw['key'];
    final label = raw['label'];
    final type = _parseType(raw['type']);
    if (key is! String || key.isEmpty) return null;
    if (label is! String || label.isEmpty) return null;
    if (type == null) return null;

    final rawOptions = raw['options'];
    final options = <ProviderSettingOption>[];
    if (rawOptions is List) {
      for (final o in rawOptions) {
        final parsed = ProviderSettingOption.tryParse(o);
        if (parsed != null) options.add(parsed);
      }
    }

    final rawDefault = raw['default'];
    Object? defaultValue;
    switch (type) {
      case ProviderSettingType.bool_:
        defaultValue = rawDefault is bool ? rawDefault : false;
        break;
      case ProviderSettingType.enum_:
        if (options.isEmpty) return null;
        if (rawDefault is String && options.any((o) => o.value == rawDefault)) {
          defaultValue = rawDefault;
        } else {
          defaultValue = options.first.value;
        }
        break;
      case ProviderSettingType.multiEnum:
        if (options.isEmpty) return null;
        final values = <String>[];
        if (rawDefault is List) {
          for (final v in rawDefault) {
            if (v is String && options.any((o) => o.value == v)) {
              values.add(v);
            }
          }
        }
        defaultValue = values;
        break;
      case ProviderSettingType.text:
        defaultValue = rawDefault is String ? rawDefault : '';
        break;
    }

    return ProviderSettingSchema(
      key: key,
      label: label,
      type: type,
      defaultValue: defaultValue,
      options: options,
    );
  }

  /// Parses the raw `getSettings()` return value into a list of valid
  /// entries. Non-list inputs and malformed rows are skipped.
  static List<ProviderSettingSchema> parseAll(dynamic raw) {
    if (raw is! List) return const [];
    final out = <ProviderSettingSchema>[];
    for (final entry in raw) {
      final parsed = tryParse(entry);
      if (parsed != null) out.add(parsed);
    }
    return out;
  }
}
