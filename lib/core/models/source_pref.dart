/// One setting a source declares for itself.
///
/// Aniyomi and Mihon extensions describe their settings the Android way, and
/// the native bridge hands that description over as plain maps
/// (`SourcePrefsCodec`). This is the Dart side of that shape, so the app can
/// draw the settings itself instead of launching the extension's own screen.
enum SourcePrefType {
  switchToggle,
  checkbox,
  list,
  multi,
  text,

  /// A preference kind we cannot draw. One of these anywhere on a page sends
  /// the WHOLE page to the native screen: showing a settings list with a
  /// setting quietly missing is worse than showing the plain one.
  unknown,
}

class SourcePref {
  const SourcePref({
    required this.key,
    required this.type,
    required this.title,
    this.summary = '',
    this.value,
    this.entries = const [],
    this.values = const [],
  });

  final String key;
  final SourcePrefType type;
  final String title;
  final String summary;

  /// bool for a switch/checkbox, String for a list/text, List&lt;String&gt; for
  /// a multi-select, null when the source has never had one set.
  final Object? value;

  /// Labels and their stored values, for the two list kinds. Same length.
  final List<String> entries;
  final List<String> values;

  bool get asBool => value == true;
  String get asText => value is String ? value! as String : '';
  List<String> get asList =>
      value is List ? (value! as List).map((e) => '$e').toList() : const [];

  /// The label for the currently stored value of a single-choice list, or ''.
  String get selectedEntry {
    final i = values.indexOf(asText);
    return i >= 0 && i < entries.length ? entries[i] : '';
  }

  /// Never throws. A malformed entry becomes [SourcePrefType.unknown], which
  /// routes the page to the native screen rather than dropping a setting the
  /// user might need.
  static SourcePref fromMap(Map<Object?, Object?> m) {
    List<String> strings(Object? v) =>
        v is List ? v.map((e) => '$e').toList() : const [];
    final type = switch (m['type']) {
      'switch' => SourcePrefType.switchToggle,
      'checkbox' => SourcePrefType.checkbox,
      'list' => SourcePrefType.list,
      'multi' => SourcePrefType.multi,
      'text' => SourcePrefType.text,
      _ => SourcePrefType.unknown,
    };
    final key = m['key'] is String ? m['key']! as String : '';
    return SourcePref(
      // A preference with no key cannot be written back, so it is as good as
      // unknown however well we could draw it.
      key: key,
      type: key.isEmpty ? SourcePrefType.unknown : type,
      title: m['title'] is String ? m['title']! as String : '',
      summary: m['summary'] is String ? m['summary']! as String : '',
      value: switch (type) {
        SourcePrefType.multi => strings(m['value']),
        _ => m['value'],
      },
      entries: strings(m['entries']),
      values: strings(m['values']),
    );
  }

  bool get drawable => type != SourcePrefType.unknown;

  /// Whether the app has anything of its own to show for this page.
  ///
  /// False means the read failed, or every row is a kind we cannot draw — in
  /// both cases the extension's own screen is the only honest answer. One
  /// drawable row is enough to be worth drawing, because the rest stay
  /// reachable through [hasUndrawable].
  static bool canDrawAny(List<SourcePref>? prefs) =>
      prefs != null && prefs.any((p) => p.drawable);

  /// Whether some row cannot be drawn here, so the page needs to offer a way
  /// into the extension's own screen. Without that, an odd setting would be
  /// invisible AND unreachable, which is worse than a plainer screen.
  static bool hasUndrawable(List<SourcePref>? prefs) =>
      prefs != null && prefs.any((p) => !p.drawable);

  static List<SourcePref> listFrom(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map) SourcePref.fromMap(e.cast<Object?, Object?>()),
    ];
  }
}
