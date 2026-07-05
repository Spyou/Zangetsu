import 'dart:convert';

/// Base type for all Aniyomi filter elements.
///
/// The 8 subtypes mirror the native `AnimeFilter` class hierarchy. The Dart
/// side parses a schema JSON string emitted by the native bridge, the UI sheet
/// mutates the leaf states in place, and [AniyomiFilters.toSelectionJson]
/// re-serialises the list so the native side can apply selections back by
/// position.
sealed class AniyomiFilter {
  const AniyomiFilter({required this.name});

  /// Display label for this filter element.
  final String name;
}

/// A non-interactive section heading. Carries only a [name].
final class AniyomiHeader extends AniyomiFilter {
  const AniyomiHeader({required super.name});
}

/// A visual divider between filter sections.
final class AniyomiSeparator extends AniyomiFilter {
  const AniyomiSeparator({required super.name});
}

/// A single-choice drop-down. [state] is the currently selected index into
/// [values]. Mutable so the filter sheet can update the selection.
final class AniyomiSelect extends AniyomiFilter {
  AniyomiSelect({
    required super.name,
    required this.values,
    required this.state,
  });

  /// Ordered list of display labels; `state` is an index into this list.
  final List<String> values;

  /// Currently selected index. Updated by the filter sheet.
  int state;
}

/// A free-text input filter. [state] holds the current text.
final class AniyomiText extends AniyomiFilter {
  AniyomiText({required super.name, required this.state});

  /// Current text value. Updated by the filter sheet.
  String state;
}

/// A boolean toggle. [state] is `true` when the checkbox is checked.
final class AniyomiCheckBox extends AniyomiFilter {
  AniyomiCheckBox({required super.name, required this.state});

  /// Whether the checkbox is checked. Updated by the filter sheet.
  bool state;
}

/// A three-state toggle mirroring `AnimeFilter.TriState`:
/// - 0 = ignore
/// - 1 = include
/// - 2 = exclude
///
/// [state] is mutable so the filter sheet can cycle through the values.
final class AniyomiTriState extends AniyomiFilter {
  AniyomiTriState({required super.name, required this.state});

  /// Current tri-state value (0/1/2). Updated by the filter sheet.
  int state;

  /// `true` when the filter is in the "ignore" (no preference) state.
  bool get isIgnored => state == 0;

  /// `true` when the filter is in the "include" state.
  bool get isIncluded => state == 1;

  /// `true` when the filter is in the "exclude" state.
  bool get isExcluded => state == 2;
}

/// A named group of child filters (typically [AniyomiCheckBox] or
/// [AniyomiTriState] entries).
final class AniyomiGroup extends AniyomiFilter {
  AniyomiGroup({required super.name, required this.children});

  final List<AniyomiFilter> children;
}

/// A sort selector. [index] is nullable when no sort column is active.
/// Both [index] and [ascending] are mutable so the filter sheet can update
/// the active column and direction independently.
final class AniyomiSort extends AniyomiFilter {
  AniyomiSort({
    required super.name,
    required this.values,
    required this.index,
    required this.ascending,
  });

  /// Ordered list of sortable column labels.
  final List<String> values;

  /// Currently selected column index, or `null` when no sort is active.
  int? index;

  /// Sort direction. `true` = ascending. Updated by the filter sheet.
  bool ascending;
}

/// Utilities for converting between the native bridge JSON and a typed
/// [AniyomiFilter] list.
class AniyomiFilters {
  const AniyomiFilters._();

  /// Parses a schema JSON string produced by the native `filterListToJson`
  /// bridge into a typed [AniyomiFilter] list.
  ///
  /// Unknown `type` values are silently skipped. Returns an empty list when
  /// the input is completely malformed rather than throwing.
  static List<AniyomiFilter> parse(String json) {
    try {
      final dynamic raw = jsonDecode(json);
      if (raw is! List) return const [];
      return _parseList(raw);
    } catch (_) {
      return const [];
    }
  }

  static List<AniyomiFilter> _parseList(List<dynamic> raw) {
    final result = <AniyomiFilter>[];
    for (final dynamic element in raw) {
      if (element is! Map) continue;
      try {
        final filter = _parseElement(element as Map<String, dynamic>);
        if (filter != null) result.add(filter);
      } catch (_) {
        // Skip malformed elements defensively.
      }
    }
    return result;
  }

  static AniyomiFilter? _parseElement(Map<String, dynamic> e) {
    final String? type = e['type'] as String?;
    final String name = (e['name'] as String?) ?? '';

    switch (type) {
      case 'header':
        return AniyomiHeader(name: name);

      case 'separator':
        return AniyomiSeparator(name: name);

      case 'select':
        final selectVals = _stringList(e['values']);
        int selectState = (e['state'] as num?)?.toInt() ?? 0;
        if (selectVals.isEmpty || selectState < 0 || selectState >= selectVals.length) {
          selectState = 0;
        }
        return AniyomiSelect(
          name: name,
          values: selectVals,
          state: selectState,
        );

      case 'text':
        return AniyomiText(
          name: name,
          state: (e['state'] as String?) ?? '',
        );

      case 'checkbox':
        return AniyomiCheckBox(
          name: name,
          state: (e['state'] as bool?) ?? false,
        );

      case 'tristate':
        return AniyomiTriState(
          name: name,
          state: (e['state'] as num?)?.toInt() ?? 0,
        );

      case 'sort':
        final dynamic stateObj = e['state'];
        int? index;
        bool ascending = true;
        if (stateObj is Map) {
          index = (stateObj['index'] as num?)?.toInt();
          ascending = (stateObj['ascending'] as bool?) ?? true;
        }
        final sortVals = _stringList(e['values']);
        if (index != null &&
            (sortVals.isEmpty || index < 0 || index >= sortVals.length)) {
          index = null;
        }
        return AniyomiSort(
          name: name,
          values: sortVals,
          index: index,
          ascending: ascending,
        );

      case 'group':
        final dynamic filtersRaw = e['filters'];
        final List<AniyomiFilter> children =
            filtersRaw is List ? _parseList(filtersRaw) : const [];
        return AniyomiGroup(name: name, children: children);

      default:
        // Unknown type — skip defensively.
        return null;
    }
  }

  static List<String> _stringList(dynamic raw) {
    if (raw is! List) return const [];
    return raw.map<String>((dynamic v) => v.toString()).toList();
  }

  /// Serialises [list] to a selection JSON string consumed by the native
  /// `applySelectionJson` bridge.
  ///
  /// The output array preserves the SAME order as [parse] produced, so native
  /// applies mutations back by position. Every element (including
  /// header/separator/group) is emitted so positional alignment is exact.
  /// `values` arrays are included to keep a clean round-trip.
  static String toSelectionJson(List<AniyomiFilter> list) {
    return jsonEncode(list.map(_encode).toList());
  }

  static Map<String, dynamic> _encode(AniyomiFilter f) {
    return switch (f) {
      AniyomiHeader() => {'type': 'header', 'name': f.name},
      AniyomiSeparator() => {'type': 'separator', 'name': f.name},
      AniyomiSelect() => {
          'type': 'select',
          'name': f.name,
          'values': f.values,
          'state': f.state,
        },
      AniyomiText() => {
          'type': 'text',
          'name': f.name,
          'state': f.state,
        },
      AniyomiCheckBox() => {
          'type': 'checkbox',
          'name': f.name,
          'state': f.state,
        },
      AniyomiTriState() => {
          'type': 'tristate',
          'name': f.name,
          'state': f.state,
        },
      AniyomiSort() => {
          'type': 'sort',
          'name': f.name,
          'values': f.values,
          'state': f.index != null
              ? {'index': f.index, 'ascending': f.ascending}
              : null,
        },
      AniyomiGroup() => {
          'type': 'group',
          'name': f.name,
          'filters': f.children.map(_encode).toList(),
        },
    };
  }
}
