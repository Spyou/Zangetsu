import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/di/injector.dart';
import '../../core/app_mode.dart';
import '../../core/stremio/stremio_manager.dart';
import '../../core/stremio/stremio_addon_icon.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_alert_dialog.dart';
import '../../core/tv/tv_text_field.dart';

part 'stremio_sources_screen_tv.dart';

/// Addon manager: install by URL, enable/disable, configure and remove.
class StremioSourcesScreen extends StatefulWidget {
  const StremioSourcesScreen({super.key});

  @override
  State<StremioSourcesScreen> createState() => _StremioSourcesScreenState();
}

class _StremioSourcesScreenState extends State<StremioSourcesScreen> {
  final _url = TextEditingController();
  var _busy = false;
  String _filter = 'All';
  FocusNode? _tvUrlFocus;

  bool get _isTv => sl.isRegistered<AppMode>() && sl<AppMode>().isTv;

  StremioManager get _manager => sl<StremioManager>();

  @override
  void dispose() {
    _tvUrlFocus?.dispose();
    _url.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action, String success) async {
    if (_busy) return;
    final focus = _isTv ? FocusManager.instance.primaryFocus : null;
    setState(() => _busy = true);
    try {
      await action();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(success)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_message(error))));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        if (focus != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || focus.context == null) return;
            if (focus.canRequestFocus) {
              focus.requestFocus();
              Scrollable.ensureVisible(focus.context!, alignment: .5);
            }
          });
        }
      }
    }
  }

  static String _message(Object error) {
    if (error is StremioInstallException) return error.message;
    return 'Addon request failed';
  }

  Future<void> _add() async {
    if (_url.text.trim().isEmpty) return;
    await _run(() async {
      await _manager.install(_url.text);
      if (mounted) _url.clear();
    }, 'Addon installed');
    if (_isTv && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _tvUrlFocus?.requestFocus();
      });
    }
  }

  Future<void> _configure(StremioInstallation installation) async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (dialog) => _isTv
          ? _stremioTvConfigureDialog(dialog, controller, installation.name)
          : AlertDialog(
              title: Text('Update ${installation.name}'),
              content: TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Configured addon URL',
                  hintText: 'Paste the URL from the addon settings page',
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialog).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialog).pop(controller.text),
                  child: const Text('Save'),
                ),
              ],
            ),
    );
    controller.dispose();
    if (!mounted || url == null || url.trim().isEmpty) return;
    await _run(() => _manager.configure(installation.id, url), 'Addon updated');
  }

  Future<void> _remove(StremioInstallation installation) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => _isTv
          ? _stremioTvRemoveDialog(dialog, installation.name)
          : AlertDialog(
              title: const Text('Remove addon?'),
              content: Text(installation.name),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialog).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialog).pop(true),
                  child: const Text('Remove'),
                ),
              ],
            ),
    );
    if (ok != true) return;
    await _run(() => _manager.remove(installation.id), 'Addon removed');
  }

  Future<void> _openConfiguration(StremioInstallation installation) async {
    final raw = installation.configurationUrl;
    final base = raw == null ? await _manager.baseUri(installation.id) : null;
    if (!mounted) return;
    final uri = raw == null
        ? base?.replace(path: '${base.path}/configure')
        : Uri.tryParse(raw);
    if (uri == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This addon has no settings page')),
      );
      return;
    }
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the settings page')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final screen = Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Text('Stremio Addons', style: AppText.barTitle),
      ),
      body: ListenableBuilder(
        listenable: _manager,
        builder: (context, _) {
          final all = _manager.installations;
          final installations = all
              .where(
                (i) => switch (_filter) {
                  'Catalogues' => i.catalogs.isNotEmpty,
                  'Metadata' => i.supports('meta'),
                  'Streams' => i.supports('stream'),
                  'Subtitles' => i.supports('subtitles'),
                  _ => true,
                },
              )
              .toList();
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
            children: [
              _sectionLabel('Overview'),
              _panel(
                child: IntrinsicHeight(
                  child: Row(
                    children: [
                      _stat('${all.length}', 'Addons'),
                      const VerticalDivider(width: 1),
                      _stat('${all.where((i) => i.enabled).length}', 'Active'),
                      const VerticalDivider(width: 1),
                      _stat(
                        '${all.where((i) => i.enabled).fold<int>(0, (sum, i) => sum + i.catalogs.length)}',
                        'Catalogues',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 22),
              _sectionLabel('Add Addon'),
              _panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_isTv)
                      TvTextField(
                        controller: _url,
                        focusNode: _tvUrlFocus ??= FocusNode(
                          debugLabel: 'stremio-addon-url',
                        ),
                        autofocus: true,
                        enabled: !_busy,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        enableSuggestions: false,
                        onSubmitted: (_) => _busy ? null : _add(),
                        decoration: const InputDecoration(
                          hintText: 'Addon URL',
                        ),
                      )
                    else
                      TextField(
                        controller: _url,
                        enabled: !_busy,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        enableSuggestions: false,
                        onSubmitted: (_) => _busy ? null : _add(),
                        decoration: InputDecoration(
                          hintText: 'Addon URL',
                          filled: true,
                          fillColor: AppColors.bg.withValues(alpha: .3),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(18),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.all(18),
                        ),
                      ),
                    const SizedBox(height: 16),
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _url,
                      builder: (context, value, _) => FilledButton(
                        onPressed: _busy || value.text.trim().isEmpty
                            ? null
                            : _add,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(52),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                        ),
                        child: Text(_busy ? 'Please wait…' : 'Install Addon'),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              _sectionLabel('Installed Addons'),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final filter in [
                      'All',
                      'Catalogues',
                      'Metadata',
                      'Streams',
                      'Subtitles',
                    ])
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(filter),
                          selected: _filter == filter,
                          showCheckmark: false,
                          shape: const StadiumBorder(),
                          side: _isTv
                              ? WidgetStateBorderSide.resolveWith(
                                  (states) =>
                                      states.contains(WidgetState.focused)
                                      ? const BorderSide(
                                          color: Colors.white,
                                          width: 2,
                                        )
                                      : BorderSide.none,
                                )
                              : BorderSide.none,
                          backgroundColor: AppColors.surface,
                          selectedColor: AppColors.accentSoft,
                          labelStyle: AppText.caption.copyWith(
                            color: _filter == filter
                                ? AppColors.textPrimary
                                : AppColors.textSecondary,
                            fontWeight: _filter == filter
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          onSelected: (_) => setState(() => _filter = filter),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              if (installations.isEmpty)
                Text(
                  'No addons yet. Add an addon to get started.',
                  style: AppText.caption,
                ),
              for (final installation in installations)
                Card(
                  key: _isTv
                      ? ValueKey('tv-stremio-addon:${installation.id}')
                      : null,
                  margin: const EdgeInsets.only(bottom: 12),
                  color: AppColors.surface,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(28),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: AppColors.bg.withValues(alpha: .25),
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: StremioAddonIcon(
                                url: installation.logo,
                                size: 44,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(installation.name, style: AppText.title),
                                  const SizedBox(height: 6),
                                  Text(
                                    'Version ${installation.version}',
                                    style: AppText.caption,
                                  ),
                                ],
                              ),
                            ),
                            Switch(
                              value: installation.enabled,
                              activeThumbColor: AppColors.accent,
                              onChanged: _busy
                                  ? null
                                  : (enabled) => _run(
                                      () => _manager.setEnabled(
                                        installation.id,
                                        enabled,
                                      ),
                                      enabled
                                          ? 'Addon enabled'
                                          : 'Addon disabled',
                                    ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          alignment: WrapAlignment.end,
                          children: [
                            IconButton(
                              tooltip: 'Move up',
                              icon: const Icon(Icons.arrow_upward_rounded),
                              onPressed:
                                  _busy || all.first.id == installation.id
                                  ? null
                                  : () => _run(
                                      () => _manager.move(installation.id, -1),
                                      'Addon moved',
                                    ),
                            ),
                            IconButton(
                              tooltip: 'Move down',
                              icon: const Icon(Icons.arrow_downward_rounded),
                              onPressed: _busy || all.last.id == installation.id
                                  ? null
                                  : () => _run(
                                      () => _manager.move(installation.id, 1),
                                      'Addon moved',
                                    ),
                            ),
                            if (installation.configurable)
                              IconButton(
                                tooltip: 'Configure addon',
                                onPressed: _busy
                                    ? null
                                    : () => _openConfiguration(installation),
                                icon: const Icon(Icons.settings_outlined),
                              ),
                            IconButton(
                              tooltip: 'Update URL',
                              onPressed: _busy
                                  ? null
                                  : () => _configure(installation),
                              icon: const Icon(Icons.edit_outlined),
                            ),
                            IconButton(
                              tooltip: 'Remove',
                              onPressed: _busy
                                  ? null
                                  : () => _remove(installation),
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ],
                        ),
                        const Divider(height: 28),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            _badge(
                              installation.enabled ? 'Active' : 'Disabled',
                            ),
                            _badge(
                              '${installation.resources.length} resources',
                            ),
                            _badge(
                              '${installation.catalogs.length} catalogues',
                            ),
                            if (installation.configurable)
                              _badge('Configurable'),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _capabilities(installation),
                          style: AppText.caption,
                        ),
                        if (installation.description?.isNotEmpty == true) ...[
                          const SizedBox(height: 8),
                          Text(
                            installation.description!,
                            style: AppText.caption,
                          ),
                        ],
                        if (installation.catalogs.any(
                          (c) => !c.extras.any((e) => e.isRequired),
                        ))
                          ExpansionTile(
                            tilePadding: EdgeInsets.zero,
                            title: const Text('Home rows'),
                            subtitle: const Text(
                              'Hide rows while keeping metadata available',
                            ),
                            children: [
                              for (final catalog in installation.catalogs)
                                if (!catalog.extras.any((e) => e.isRequired))
                                  SwitchListTile(
                                    title: Text(
                                      '${catalog.name} · ${catalog.type == 'series' ? 'Series' : 'Movies'}',
                                    ),
                                    value: installation.isCatalogVisible(
                                      catalog.type,
                                      catalog.id,
                                    ),
                                    onChanged: _busy
                                        ? null
                                        : (visible) => _run(
                                            () => _manager.setCatalogVisible(
                                              installation.id,
                                              catalog.type,
                                              catalog.id,
                                              visible,
                                            ),
                                            visible
                                                ? 'Home row shown'
                                                : 'Home row hidden',
                                          ),
                                  ),
                            ],
                          ),
                        const SizedBox(height: 8),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              Text(
                'Addons supply catalogues, metadata, links and subtitles. '
                'Configured URLs are stored only on this device.',
                style: AppText.caption,
              ),
            ],
          );
        },
      ),
    );
    return _isTv
        ? Theme(data: _stremioTvTheme(Theme.of(context)), child: screen)
        : screen;
  }

  Widget _sectionLabel(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(text, style: AppText.overline),
  );

  Widget _panel({required Widget child}) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(28),
    ),
    child: child,
  );

  Widget _stat(String value, String label) => Expanded(
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        children: [
          Text(value, style: AppText.title),
          const SizedBox(height: 4),
          Text(label, style: AppText.caption),
        ],
      ),
    ),
  );

  Widget _badge(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: AppColors.bg.withValues(alpha: .3),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(text, style: AppText.caption.copyWith(fontSize: 11)),
  );

  static String _capabilities(StremioInstallation installation) {
    final catalogs = installation.catalogs.length;
    final parts = <String>[
      if (catalogs > 0) '$catalogs catalogue${catalogs == 1 ? '' : 's'}',
      if (installation.supports('stream')) 'streams',
      if (installation.supports('meta')) 'metadata',
      if (installation.supports('subtitles')) 'subtitles',
    ];
    final serves = parts.isEmpty ? 'No browsable resources' : parts.join(' · ');
    if (catalogs == 0) {
      return '$serves — add a catalogue addon to browse';
    }
    return serves;
  }
}
