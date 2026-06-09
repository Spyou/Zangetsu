import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/models/provider_setting_schema.dart';
import '../../core/provider/cloudstream_provider.dart';
import '../../core/provider/provider_manager.dart';
import '../../core/provider/provider_registry.dart';
import '../../core/repository/provider_settings_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/states.dart';

/// Generic per-provider settings form rendered from the provider's
/// `getSettings()` schema. The composite `(repoUrl, sourceId)` key keeps
/// settings independent across repos that publish the same sourceId.
class SourceSettingsScreen extends StatefulWidget {
  const SourceSettingsScreen({
    super.key,
    required this.sourceId,
    required this.repoUrl,
    this.displayName,
  });

  final String sourceId;
  final String repoUrl;

  /// Optional pre-fetched pretty name for the AppBar title.
  final String? displayName;

  @override
  State<SourceSettingsScreen> createState() => _SourceSettingsScreenState();
}

class _SourceSettingsScreenState extends State<SourceSettingsScreen> {
  late Future<List<ProviderSettingSchema>?> _schemaFuture;
  // Whether the underlying CloudStream plugin exposes its OWN settings UI
  // (separate from our app-side schema settings). Always false for non-CS.
  late Future<bool> _nativeSettingsFuture;
  Map<String, dynamic> _values = <String, dynamic>{};

  /// The bare CloudStream api name for this source (`cs:AnimePahe` → `AnimePahe`),
  /// or null when this isn't a CloudStream source.
  String? get _csApiName =>
      widget.sourceId.startsWith('cs:') ? widget.sourceId.substring(3) : null;

  // One debounce timer per text field so typing in two boxes back to
  // back doesn't cancel each other's pending save.
  final Map<String, Timer> _textDebounce = {};

  ProviderSettingsRepository get _repo => sl<ProviderSettingsRepository>();
  ProviderManager get _manager => sl<ProviderManager>();
  String get _key =>
      ProviderRegistry.providerKey(widget.repoUrl, widget.sourceId);

  @override
  void initState() {
    super.initState();
    _schemaFuture = _loadSchema();
    final api = _csApiName;
    _nativeSettingsFuture =
        api == null ? Future.value(false) : csPluginHasSettings(api);
  }

  @override
  void dispose() {
    for (final t in _textDebounce.values) {
      t.cancel();
    }
    super.dispose();
  }

  Future<List<ProviderSettingSchema>?> _loadSchema() async {
    final provider = _manager.get(widget.sourceId);
    if (provider == null) return null;
    final raw = await provider.getSettingsSchema();
    if (raw == null) return null;
    final parsed = ProviderSettingSchema.parseAll(raw);
    // Seed: saved row blended on top of schema defaults so newly-added
    // fields show their default.
    final saved = _repo.getFor(_key);
    final values = <String, dynamic>{};
    for (final entry in parsed) {
      if (saved.containsKey(entry.key)) {
        values[entry.key] = _coerceSavedValue(entry, saved[entry.key]);
      } else {
        values[entry.key] = entry.defaultValue;
      }
    }
    if (mounted) {
      setState(() => _values = values);
    } else {
      _values = values;
    }
    return parsed;
  }

  /// Re-shape a saved Hive value to the type the schema expects so a
  /// renamed/retyped field can't crash the form.
  Object? _coerceSavedValue(ProviderSettingSchema schema, Object? raw) {
    switch (schema.type) {
      case ProviderSettingType.bool_:
        return raw is bool ? raw : schema.defaultValue;
      case ProviderSettingType.enum_:
        if (raw is String && schema.options.any((o) => o.value == raw)) {
          return raw;
        }
        return schema.defaultValue;
      case ProviderSettingType.multiEnum:
        if (raw is List) {
          final allowed = schema.options.map((o) => o.value).toSet();
          return raw.whereType<String>().where(allowed.contains).toList();
        }
        return schema.defaultValue;
      case ProviderSettingType.text:
        return raw is String ? raw : schema.defaultValue;
    }
  }

  /// Persist the full map and mirror it into the JS runtime so the next
  /// provider call reads the updated values.
  Future<void> _persist() async {
    await _repo.setFor(_key, _values);
    _manager.setSettings(widget.sourceId, _values);
  }

  void _updateImmediate(String key, Object? value) {
    setState(() => _values[key] = value);
    // ignore: discarded_futures
    _persist();
  }

  void _updateDebounced(String key, String value) {
    _values[key] = value;
    _textDebounce[key]?.cancel();
    _textDebounce[key] = Timer(const Duration(milliseconds: 300), () {
      // ignore: discarded_futures
      _persist();
    });
  }

  Future<void> _resetDefaults(List<ProviderSettingSchema> schema) async {
    final defaults = <String, dynamic>{
      for (final s in schema) s.key: s.defaultValue,
    };
    await _repo.clearFor(_key);
    setState(() => _values = defaults);
    _manager.setSettings(widget.sourceId, defaults);
  }

  Future<void> _pickEnum(ProviderSettingSchema schema) async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final current = _values[schema.key] as String?;
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 12, bottom: 8),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.textTertiary.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: Text(schema.label, style: AppText.headline),
              ),
              const Divider(color: AppColors.hairline, height: 1),
              for (final opt in schema.options)
                ListTile(
                  onTap: () => Navigator.pop(ctx, opt.value),
                  title: Text(
                    opt.label,
                    style: AppText.body.copyWith(color: AppColors.textPrimary),
                  ),
                  trailing: Icon(
                    current == opt.value
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_unchecked_rounded,
                    color: current == opt.value
                        ? AppColors.accent
                        : AppColors.textTertiary,
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (selected != null) _updateImmediate(schema.key, selected);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: Text(
          widget.displayName ?? widget.sourceId,
          style: AppText.title,
        ),
      ),
      body: FutureBuilder<List<ProviderSettingSchema>?>(
        future: _schemaFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(color: AppColors.accent),
            );
          }
          if (snapshot.hasError) {
            return EmptyState(
              icon: Icons.error_outline_rounded,
              message: 'Could not load settings:\n${snapshot.error}',
            );
          }
          final data = snapshot.data;
          final schema =
              (data != null && data.isNotEmpty) ? data : null;
          return FutureBuilder<bool>(
            future: _nativeSettingsFuture,
            builder: (context, nativeSnap) {
              final hasNative = nativeSnap.data ?? false;
              if (schema == null && !hasNative) {
                return const EmptyState(
                  icon: Icons.tune,
                  message: 'This source has no settings',
                );
              }
              return ListView(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                children: [
                  // The plugin's OWN settings UI (e.g. server picker), opened
                  // natively. Shown above the app-side schema settings.
                  if (hasNative) _providerSettingsCard(),
                  if (hasNative && schema != null) const SizedBox(height: 8),
                  if (schema != null) ...[
                    for (final entry in schema) _buildEntry(entry),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: TextButton.icon(
                        onPressed: () => _resetDefaults(schema),
                        icon: const Icon(
                          Icons.restore_rounded,
                          color: AppColors.textSecondary,
                          size: 20,
                        ),
                        label: Text(
                          'Reset to defaults',
                          style: AppText.body.copyWith(
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              );
            },
          );
        },
      ),
    );
  }

  /// Tile that opens the CloudStream plugin's OWN settings UI (native sheet).
  Widget _providerSettingsCard() => _card(
    child: ListTile(
      leading: const Icon(Icons.tune_rounded, color: AppColors.accent),
      title: Text('Provider settings', style: AppText.body),
      subtitle: Text(
        "Open this source's own settings (e.g. server, language)",
        style: AppText.caption,
      ),
      trailing: const Icon(
        Icons.open_in_new_rounded,
        size: 18,
        color: AppColors.textSecondary,
      ),
      onTap: () {
        final api = _csApiName;
        if (api != null) csPluginOpenSettings(api);
      },
    ),
  );

  Widget _card({required Widget child, EdgeInsets? padding}) => Container(
    margin: const EdgeInsets.symmetric(vertical: 4),
    padding: padding,
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(12),
    ),
    child: child,
  );

  Widget _buildEntry(ProviderSettingSchema schema) {
    switch (schema.type) {
      case ProviderSettingType.bool_:
        final v = _values[schema.key] as bool? ?? false;
        return _card(
          child: SwitchListTile.adaptive(
            value: v,
            activeThumbColor: AppColors.accent,
            title: Text(
              schema.label,
              style: AppText.body.copyWith(color: AppColors.textPrimary),
            ),
            onChanged: (next) => _updateImmediate(schema.key, next),
          ),
        );
      case ProviderSettingType.enum_:
        final current = _values[schema.key] as String?;
        final label = schema.options
            .firstWhere(
              (o) => o.value == current,
              orElse: () => ProviderSettingOption(
                value: current ?? '',
                label: current ?? '',
              ),
            )
            .label;
        return _card(
          child: ListTile(
            title: Text(
              schema.label,
              style: AppText.body.copyWith(color: AppColors.textPrimary),
            ),
            subtitle: Text(label, style: AppText.caption),
            trailing: const Icon(
              Icons.chevron_right_rounded,
              color: AppColors.textSecondary,
            ),
            onTap: () => _pickEnum(schema),
          ),
        );
      case ProviderSettingType.multiEnum:
        final raw = _values[schema.key];
        final selected = raw is List
            ? raw.whereType<String>().toSet()
            : <String>{};
        return _card(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                schema.label,
                style: AppText.body.copyWith(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final opt in schema.options)
                    ChoiceChip(
                      label: Text(opt.label),
                      selected: selected.contains(opt.value),
                      selectedColor: AppColors.accentSoft,
                      backgroundColor: AppColors.surface2,
                      side: BorderSide(
                        color: selected.contains(opt.value)
                            ? AppColors.accent
                            : AppColors.hairline,
                      ),
                      labelStyle: AppText.caption.copyWith(
                        color: AppColors.textPrimary,
                      ),
                      onSelected: (next) {
                        final updated = selected.toSet();
                        if (next) {
                          updated.add(opt.value);
                        } else {
                          updated.remove(opt.value);
                        }
                        _updateImmediate(schema.key, updated.toList());
                      },
                    ),
                ],
              ),
            ],
          ),
        );
      case ProviderSettingType.text:
        final v = _values[schema.key] as String? ?? '';
        return _card(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: TextFormField(
            initialValue: v,
            style: AppText.body.copyWith(color: AppColors.textPrimary),
            cursorColor: AppColors.accent,
            decoration: InputDecoration(
              labelText: schema.label,
              labelStyle: AppText.body,
              border: InputBorder.none,
              isDense: true,
            ),
            onChanged: (next) => _updateDebounced(schema.key, next),
          ),
        );
    }
  }
}
