import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/di/injector.dart';
import '../../core/stremio/stremio_manager.dart';
import '../../core/stremio/stremio_addon_icon.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';

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

  StremioManager get _manager => sl<StremioManager>();

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action, String success) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (!mounted) return;
      _url.clear();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(success)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_message(error))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _message(Object error) {
    if (error is StremioInstallException) return error.message;
    return 'Addon request failed';
  }

  Future<void> _add() async {
    var installing = false;
    String? error;
    _url.clear();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, update) {
          Future<void> install() async {
            if (installing || _url.text.trim().isEmpty) return;
            update(() {
              installing = true;
              error = null;
            });
            try {
              await _manager.install(_url.text);
              if (sheet.mounted) Navigator.of(sheet).pop();
            } catch (e) {
              if (sheet.mounted) {
                update(() {
                  installing = false;
                  error = _message(e);
                });
              }
            }
          }

          return SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                24,
                24,
                24,
                24 + MediaQuery.viewInsetsOf(sheet).bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Install addon', style: AppText.headline),
                  const SizedBox(height: 8),
                  Text(
                    'Paste an HTTPS or stremio:// installation link. Configured links may contain account credentials.',
                    style: AppText.caption,
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _url,
                    enabled: !installing,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    autofocus: true,
                    onSubmitted: (_) => install(),
                    decoration: InputDecoration(
                      labelText: 'Addon URL',
                      hintText: 'https://addon.example/manifest.json',
                      errorText: error,
                    ),
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: installing ? null : install,
                    icon: installing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.add_rounded),
                    label: Text(installing ? 'Checking addon…' : 'Install'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _configure(StremioInstallation installation) async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
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
      builder: (dialog) => AlertDialog(
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
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: const Text('Stremio addons'),
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
              Text('Your addons', style: AppText.headline),
              const SizedBox(height: 6),
              Text(
                'Combine catalogues, metadata, streams and subtitles.',
                style: AppText.caption,
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: _busy ? null : _add,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add addon'),
              ),
              const SizedBox(height: 24),
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
                        child: FilterChip(
                          label: Text(filter),
                          selected: _filter == filter,
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
                  margin: const EdgeInsets.only(bottom: 12),
                  color: AppColors.surface,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            StremioAddonIcon(url: installation.logo),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                installation.name,
                                style: AppText.headline,
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
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
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
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
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
  }

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
