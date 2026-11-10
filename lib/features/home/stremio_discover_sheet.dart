import 'package:flutter/material.dart';
import 'package:zangetsu_source_bridge/stremio.dart';

import '../../core/stremio/stremio_manager.dart';
import '../../core/stremio/stremio_provider.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';

class StremioDiscoverSelection {
  const StremioDiscoverSelection({
    required this.addon,
    required this.catalog,
    this.genre,
  });

  final StremioInstallation addon;
  final StremioCatalog catalog;
  final String? genre;

  Object get key => (addon.id, addon.revision, catalog.type, catalog.id, genre);
}

typedef StremioDiscoverSheetResult = ({
  StremioDiscoverSelection? selection,
  bool searchFilters,
});

class StremioDiscoverSheet extends StatefulWidget {
  const StremioDiscoverSheet({super.key, required this.manager, this.initial});

  final StremioManager manager;
  final StremioDiscoverSelection? initial;

  @override
  State<StremioDiscoverSheet> createState() => _StremioDiscoverSheetState();
}

class _StremioDiscoverSheetState extends State<StremioDiscoverSheet> {
  late final List<({StremioInstallation addon, StremioCatalog catalog})>
  _catalogs;
  int? _index;
  String? _genre;

  @override
  void initState() {
    super.initState();
    _catalogs = [
      for (final addon in widget.manager.enabled)
        for (final catalog in addon.catalogs)
          if (StremioProvider.supportsBrowseCatalog(catalog))
            (addon: addon, catalog: catalog),
    ];
    if (_catalogs.isEmpty) return;
    final initial = widget.initial;
    final index = initial == null
        ? -1
        : _catalogs.indexWhere(
            (option) =>
                option.addon.id == initial.addon.id &&
                option.catalog.type == initial.catalog.type &&
                option.catalog.id == initial.catalog.id,
          );
    _select(index < 0 ? 0 : index, initial?.genre);
  }

  void _select(int index, [String? genre]) {
    _index = index;
    final extra = _catalogs[index].catalog.extras
        .where((e) => e.name == 'genre')
        .firstOrNull;
    _genre = genre != null && (extra?.options.contains(genre) ?? false)
        ? genre
        : extra != null && extra.isRequired && extra.options.isNotEmpty
        ? extra.options.firstWhere((option) => option.isNotEmpty)
        : null;
  }

  String _typeLabel(String type) => switch (type.toLowerCase()) {
    'movie' => 'Movies',
    'series' => 'Series',
    _ => type,
  };

  /// Gold micro-label + filled rounded field + outline chevron, shared by
  /// the three dropdowns so they read as one control family. Disabled
  /// fields grey out so an unavailable Genre never looks broken-tappable.
  InputDecoration _field(String label, [String? hint, bool enabled = true]) =>
      InputDecoration(
        labelText: label,
        helperText: hint,
        filled: true,
        fillColor: enabled
            ? AppColors.surface2
            : AppColors.surface2.withValues(alpha: 0.45),
        contentPadding: const EdgeInsets.fromLTRB(14, 10, 12, 9),
        labelStyle: AppText.caption.copyWith(
          color: enabled ? AppColors.accent : AppColors.textTertiary,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.07,
        ),
        helperStyle: AppText.caption.copyWith(color: AppColors.textTertiary),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      );

  static Icon _chevron({bool enabled = true}) => Icon(
    Icons.expand_more_rounded,
    color: enabled
        ? AppColors.textTertiary
        : AppColors.textTertiary.withValues(alpha: 0.4),
    size: 20,
  );

  /// One dropdown menu row. Selected rows read accent + bold; kept as a
  /// plain Text (no Row/Expanded) because menus measure children with
  /// unbounded width, where flex would fail layout.
  static Widget _menuRow(String text, {bool selected = false}) => Text(
    text,
    overflow: TextOverflow.ellipsis,
    style: AppText.body.copyWith(
      fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
      color: selected ? AppColors.accent : AppColors.textPrimary,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final types = _catalogs.map((e) => e.catalog.type).toSet().toList();
    final selected = _index == null ? null : _catalogs[_index!];
    final genre = selected?.catalog.extras
        .where((e) => e.name == 'genre')
        .firstOrNull;
    final genres =
        genre?.options.where((option) => option.isNotEmpty).toSet().toList() ??
        <String>[];
    final hasGenres = genres.isNotEmpty;
    final addonCount = _catalogs.map((e) => e.addon.id).toSet().length;
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          10,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.textTertiary.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text('Browse catalogues', style: AppText.headline),
            const SizedBox(height: 4),
            Text(
              'Choose an addon catalogue to browse. Search filters are separate.',
              style: AppText.caption,
            ),
            const SizedBox(height: 18),
            if (selected == null)
              Text(
                'No browseable addon catalogues are available.',
                style: AppText.body,
              )
            else ...[
              DropdownButtonFormField<String>(
                key: ValueKey(('type', selected.catalog.type)),
                initialValue: selected.catalog.type,
                decoration: _field('Type'),
                icon: _chevron(),
                dropdownColor: AppColors.surface2,
                borderRadius: BorderRadius.circular(14),
                itemHeight: 52,
                items: [
                  for (final type in types)
                    DropdownMenuItem(
                      value: type,
                      child: _menuRow(
                        _typeLabel(type),
                        selected: type == selected.catalog.type,
                      ),
                    ),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  final index = _catalogs.indexWhere(
                    (option) => option.catalog.type == value,
                  );
                  if (index >= 0) setState(() => _select(index));
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                key: ValueKey(('catalog', _index)),
                initialValue: _index,
                isExpanded: true,
                decoration: _field(
                  'Catalogue',
                  '${_catalogs.length} catalogues from $addonCount addon${addonCount == 1 ? '' : 's'}',
                ),
                icon: _chevron(),
                dropdownColor: AppColors.surface2,
                borderRadius: BorderRadius.circular(14),
                itemHeight: 52,
                items: [
                  for (var i = 0; i < _catalogs.length; i++)
                    if (_catalogs[i].catalog.type == selected.catalog.type)
                      DropdownMenuItem(
                        value: i,
                        child: _menuRow(
                          '${_catalogs[i].addon.name} · ${_catalogs[i].catalog.name}',
                          selected: i == _index,
                        ),
                      ),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _select(value));
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: ValueKey(('genre', _index, _genre)),
                initialValue: _genre ?? '',
                isExpanded: true,
                decoration: _field('Genre', null, hasGenres),
                icon: _chevron(enabled: hasGenres),
                style: AppText.body.copyWith(
                  color: hasGenres
                      ? AppColors.textPrimary
                      : AppColors.textTertiary,
                ),
                dropdownColor: AppColors.surface2,
                borderRadius: BorderRadius.circular(14),
                itemHeight: 52,
                items: [
                  if (genre?.isRequired != true || !hasGenres)
                    DropdownMenuItem(
                      value: '',
                      child: _menuRow(
                        'All genres',
                        selected: _genre == null,
                      ),
                    ),
                  if (hasGenres)
                    for (final option in genres)
                      DropdownMenuItem(
                        value: option,
                        child: _menuRow(
                          option,
                          selected: option == _genre,
                        ),
                      ),
                ],
                onChanged: !hasGenres
                    ? null
                    : (value) => setState(
                        () => _genre = value == null || value.isEmpty
                            ? null
                            : value,
                      ),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () => Navigator.pop(context, (
                  selection: StremioDiscoverSelection(
                    addon: selected.addon,
                    catalog: selected.catalog,
                    genre: _genre,
                  ),
                  searchFilters: false,
                )),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  textStyle: AppText.body.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                child: const Text('Browse'),
              ),
            ],
            TextButton(
              onPressed: () => Navigator.pop(context, (
                selection: null,
                searchFilters: true,
              )),
              child: const Text('Search result filters'),
            ),
          ],
        ),
      ),
    );
  }
}
