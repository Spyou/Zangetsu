import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/models/provider_setting_schema.dart';
import '../../core/provider/cloudstream_provider.dart';
import '../../core/provider/provider_manager.dart';
import '../../core/provider/provider_registry.dart';
import '../../core/repository/provider_settings_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_list_focusable.dart';
import '../../core/tv/tv_text_field.dart';
import '../../core/ui/settings_widgets.dart';
import '../../core/ui/states.dart';
import '../../l10n/l10n.dart';

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

  bool get _isTv => sl.isRegistered<AppMode>() && sl<AppMode>().isTv;

  @override
  void initState() {
    super.initState();
    _schemaFuture = _loadSchema();
    final api = _csApiName;
    _nativeSettingsFuture = api == null
        ? Future.value(false)
        : csPluginHasSettings(api);
  }

  @override
  void dispose() {
    for (final t in _textDebounce.values) {
      t.cancel();
    }
    super.dispose();
  }

  Future<List<ProviderSettingSchema>?> _loadSchema() async {
    // CloudStream (`cs:`) sources live natively, not in the JS runtime, so
    // there is no JS schema to wait for — return early and let the native
    // settings card (or the no-settings state) below handle them.
    if (_csApiName != null) return null;
    // TV skips loadAll at boot; open settings before playback and the JS
    // provider may not be in the runtime yet.
    if (_manager.get(widget.sourceId) == null) {
      final loaded = await sl<ProviderRegistry>().ensureRuntimeLoaded(
        widget.sourceId,
      );
      if (!loaded) {
        throw StateError(
          'Could not load ${widget.displayName ?? widget.sourceId}. '
          'Try again or check that the source is enabled.',
        );
      }
    }
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
    if (_isTv) {
      final current = _values[schema.key] as String?;
      final selected = await showDialog<String>(
        context: context,
        barrierColor: Colors.black54,
        builder: (ctx) => Dialog(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          insetPadding: const EdgeInsets.symmetric(horizontal: 80, vertical: 48),
          child: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
                  child: Text(schema.label, style: AppText.title),
                ),
                const Divider(height: 1, color: AppColors.hairline),
                Flexible(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(context).size.height * 0.6,
                    ),
                    child: ListView(
                      shrinkWrap: true,
                      clipBehavior: Clip.none,
                      padding: const EdgeInsets.only(bottom: 12),
                      children: [
                        for (var i = 0; i < schema.options.length; i++)
                          TvListFocusable(
                            autofocus: schema.options[i].value == current,
                            semanticLabel: schema.options[i].label,
                            onTap: () =>
                                Navigator.pop(ctx, schema.options[i].value),
                            child: ExcludeSemantics(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 24,
                                  vertical: 14,
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        schema.options[i].label,
                                        style: AppText.headline,
                                      ),
                                    ),
                                    if (schema.options[i].value == current)
                                      Icon(
                                        Icons.check,
                                        color: AppColors.accent,
                                        size: 20,
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      if (selected != null) _updateImmediate(schema.key, selected);
      return;
    }

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

  Future<void> _editText(ProviderSettingSchema schema) async {
    final current = _values[schema.key] as String? ?? '';
    final controller = TextEditingController(text: current);
    final saved = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black54,
      builder: (ctx) => Dialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 80, vertical: 48),
        child: SizedBox(
          width: 520,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(schema.label, style: AppText.title),
                const SizedBox(height: 16),
                TvTextField(
                  controller: controller,
                  autofocus: true,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TvListFocusable(
                      semanticLabel: context.l10n.cancel,
                      onTap: () => Navigator.pop(ctx, false),
                      child: ExcludeSemantics(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          child: Text(context.l10n.cancel, style: AppText.body),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TvListFocusable(
                      semanticLabel: context.l10n.save,
                      onTap: () => Navigator.pop(ctx, true),
                      child: ExcludeSemantics(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          child: Text(
                            context.l10n.save,
                            style: AppText.body.copyWith(
                              color: AppColors.accent,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (saved == true) {
      _updateImmediate(schema.key, controller.text);
    }
    controller.dispose();
  }

  Future<void> _pickMultiEnum(ProviderSettingSchema schema) async {
    final raw = _values[schema.key];
    final chosen = raw is List
        ? raw.whereType<String>().toSet()
        : <String>{};
    if (_isTv) {
      final saved = await showDialog<bool>(
        context: context,
        barrierColor: Colors.black54,
        builder: (ctx) => Dialog(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          insetPadding: const EdgeInsets.symmetric(horizontal: 80, vertical: 48),
          child: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
                  child: Text(schema.label, style: AppText.title),
                ),
                const Divider(height: 1, color: AppColors.hairline),
                Flexible(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(context).size.height * 0.55,
                    ),
                    child: StatefulBuilder(
                      builder: (ctx2, setInner) => ListView(
                        shrinkWrap: true,
                        clipBehavior: Clip.none,
                        padding: const EdgeInsets.only(bottom: 8),
                        children: [
                          for (var j = 0; j < schema.options.length; j++)
                            TvListFocusable(
                              autofocus: j == 0,
                              semanticLabel: schema.options[j].label,
                              onTap: () => setInner(() {
                                final v = schema.options[j].value;
                                chosen.contains(v)
                                    ? chosen.remove(v)
                                    : chosen.add(v);
                              }),
                              child: ExcludeSemantics(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 24,
                                    vertical: 14,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          schema.options[j].label,
                                          style: AppText.headline,
                                        ),
                                      ),
                                      if (chosen.contains(schema.options[j].value))
                                        Icon(
                                          Icons.check,
                                          color: AppColors.accent,
                                          size: 20,
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                const Divider(height: 1, color: AppColors.hairline),
                TvListFocusable(
                  semanticLabel: context.l10n.save,
                  onTap: () => Navigator.pop(ctx, true),
                  child: ExcludeSemantics(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 14,
                      ),
                      child: Text(
                        context.l10n.save,
                        style: AppText.body.copyWith(
                          color: AppColors.accent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      );
      if (saved == true) {
        _updateImmediate(schema.key, chosen.toList());
      }
    }
  }

  List<Widget> _buildSchemaList(List<ProviderSettingSchema> schema, bool hasNative) {
    if (_isTv) {
      return [
        SettingsCard(
          children: [
            for (var i = 0; i < schema.length; i++)
              _buildEntry(
                schema[i],
                autofocus: !hasNative && i == 0,
              ),
          ],
        ),
        const SizedBox(height: 16),
        TvListFocusable(
          semanticLabel: context.l10n.resetToDefaults,
          onTap: () => _resetDefaults(schema),
          child: ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 8, 20, 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.restore_rounded,
                    color: AppColors.textSecondary,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    context.l10n.resetToDefaults,
                    style: AppText.body.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ];
    }
    return [
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
            context.l10n.resetToDefaults,
            style: AppText.body.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar(widget.displayName ?? widget.sourceId),
      body: FutureBuilder<List<ProviderSettingSchema>?>(
        future: _schemaFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return Center(
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
          final schema = (data != null && data.isNotEmpty) ? data : null;
          return FutureBuilder<bool>(
            future: _nativeSettingsFuture,
            builder: (context, nativeSnap) {
              final hasNative = nativeSnap.data ?? false;
              if (schema == null && !hasNative) {
                return EmptyState(
                  icon: Icons.tune,
                  message: context.l10n.thisSourceHasNoSettings,
                );
              }
              return ListView(
                clipBehavior: _isTv ? Clip.none : Clip.hardEdge,
                padding: EdgeInsets.fromLTRB(
                  _isTv ? 0 : 12,
                  8,
                  _isTv ? 0 : 12,
                  24,
                ),
                children: [
                  if (hasNative) _providerSettingsCard(autofocus: true),
                  if (hasNative && schema != null) const SizedBox(height: 8),
                  if (schema != null) ..._buildSchemaList(schema, hasNative),
                ],
              );
            },
          );
        },
      ),
    );
  }

  /// Tile that opens the CloudStream plugin's OWN settings UI (native sheet).
  Widget _providerSettingsCard({bool autofocus = false}) {
    if (_isTv) {
      return SettingsCard(
        children: [
          SettingsTile(
            icon: Icons.tune_rounded,
            iconAccent: true,
            autofocus: autofocus,
            title: context.l10n.providerSettings,
            subtitle: context.l10n.openThisSourceSOwnSettingsEGServerLanguage,
            subtitleMaxLines: null,
            onTap: () {
              final api = _csApiName;
              if (api != null) csPluginOpenSettings(api);
            },
          ),
        ],
      );
    }
    return _card(
      child: ListTile(
        leading: Icon(Icons.tune_rounded, color: AppColors.accent),
        title: Text(context.l10n.providerSettings, style: AppText.body),
        subtitle: Text(
          context.l10n.openThisSourceSOwnSettingsEGServerLanguage,
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
  }

  Widget _card({required Widget child, EdgeInsets? padding}) => Container(
    margin: const EdgeInsets.symmetric(vertical: 4),
    padding: padding,
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(12),
    ),
    child: child,
  );

  Widget _buildEntry(ProviderSettingSchema schema, {bool autofocus = false}) {
    if (_isTv) {
      return _buildEntryTv(schema, autofocus: autofocus);
    }
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

  Widget _buildEntryTv(ProviderSettingSchema schema, {bool autofocus = false}) {
    switch (schema.type) {
      case ProviderSettingType.bool_:
        final v = _values[schema.key] as bool? ?? false;
        return SettingsTile(
          icon: Icons.toggle_on_outlined,
          title: schema.label,
          autofocus: autofocus,
          trailing: Switch.adaptive(
            value: v,
            activeThumbColor: AppColors.accent,
            onChanged: (next) => _updateImmediate(schema.key, next),
          ),
          onTap: () => _updateImmediate(schema.key, !v),
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
        return SettingsTile(
          icon: Icons.list_rounded,
          title: schema.label,
          subtitle: label,
          autofocus: autofocus,
          onTap: () => _pickEnum(schema),
        );
      case ProviderSettingType.multiEnum:
        final raw = _values[schema.key];
        final selected = raw is List
            ? raw.whereType<String>().toSet()
            : <String>{};
        return SettingsTile(
          icon: Icons.checklist_rounded,
          title: schema.label,
          subtitle: selected.isEmpty
              ? null
              : '${selected.length} selected',
          autofocus: autofocus,
          onTap: () => _pickMultiEnum(schema),
        );
      case ProviderSettingType.text:
        final v = _values[schema.key] as String? ?? '';
        return SettingsTile(
          icon: Icons.edit_rounded,
          title: schema.label,
          subtitle: v.isEmpty ? null : v,
          subtitleMaxLines: 2,
          autofocus: autofocus,
          onTap: () => _editText(schema),
        );
    }
  }
}
