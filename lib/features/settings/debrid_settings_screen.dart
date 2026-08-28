import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_mode.dart';
import '../../core/debrid/debrid_prefs.dart';
import '../../core/debrid/debrid_provider.dart';
import '../../core/debrid/debrid_resolver.dart';
import '../../core/debrid/debrid_token_store.dart';
import '../../core/di/injector.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/settings_widgets.dart';

/// Hub: routing mode, active service, Real-Debrid + TorBox connect rows.
class DebridSettingsScreen extends StatefulWidget {
  const DebridSettingsScreen({super.key});

  @override
  State<DebridSettingsScreen> createState() => _DebridSettingsScreenState();
}

class _DebridSettingsScreenState extends State<DebridSettingsScreen> {
  DebridPrefs get _prefs => sl<DebridPrefs>();
  final Map<DebridService, bool> _connected = {
    for (final s in DebridService.values) s: false,
  };
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final next = <DebridService, bool>{};
    for (final s in DebridService.values) {
      next[s] = await DebridTokenStore.hasToken(s);
    }
    if (!mounted) return;
    setState(() {
      _connected
        ..clear()
        ..addAll(next);
      _loaded = true;
    });
  }

  int get _connectedCount => _connected.values.where((v) => v).length;

  Future<void> _setMode(DebridMode mode) async {
    await _prefs.setMode(mode);
    if (mounted) setState(() {});
  }

  Future<void> _cycleMode() async {
    const order = DebridMode.values;
    final i = order.indexOf(_prefs.mode);
    await _setMode(order[(i + 1) % order.length]);
  }

  Future<void> _setActive(DebridService s) async {
    await _prefs.setActiveService(s);
    if (mounted) setState(() {});
  }

  Future<void> _openService(DebridService s) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => DebridServiceScreen(service: s)),
    );
    await _refresh();
    // If the active pick is no longer connected, drop it so "first connected"
    // takes over.
    final active = _prefs.activeService;
    if (active != null && _connected[active] != true) {
      await _prefs.setActiveService(null);
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final isTv = sl.isRegistered<AppMode>() && sl<AppMode>().isTv;
    final mode = _prefs.mode;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar('Debrid'),
      body: ListView(
        padding: const EdgeInsets.only(top: 4, bottom: 28),
        children: [
          const SettingsSectionLabel('Routing', first: true),
          SettingsCard(
            children: [
              if (isTv)
                SettingsTile(
                  autofocus: true,
                  icon: Icons.alt_route_rounded,
                  title: 'Mode',
                  subtitle: '${mode.label} — ${mode.description}',
                  subtitleMaxLines: 2,
                  onTap: _cycleMode,
                  trailing: Text(
                    mode.label,
                    style: AppText.caption.copyWith(color: AppColors.accent),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Mode', style: AppText.headline.copyWith(fontSize: 15)),
                      const SizedBox(height: 10),
                      SegmentedButton<DebridMode>(
                        segments: [
                          for (final m in DebridMode.values)
                            ButtonSegment(value: m, label: Text(m.label)),
                        ],
                        selected: {mode},
                        onSelectionChanged: (s) => _setMode(s.first),
                        style: ButtonStyle(
                          visualDensity: VisualDensity.compact,
                          foregroundColor: WidgetStateProperty.resolveWith((st) {
                            if (st.contains(WidgetState.selected)) {
                              return AppColors.textPrimary;
                            }
                            return AppColors.textSecondary;
                          }),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(mode.description, style: AppText.caption),
                    ],
                  ),
                ),
            ],
          ),
          if (_connectedCount > 1) ...[
            const SettingsSectionLabel('Active service'),
            SettingsCard(
              children: [
                for (final s in DebridService.values)
                  if (_connected[s] == true)
                    SettingsTile(
                      icon: Icons.check_circle_outline_rounded,
                      title: s.displayName,
                      subtitle: _prefs.activeService == s ||
                              (_prefs.activeService == null &&
                                  s ==
                                      DebridService.values.firstWhere(
                                        (x) => _connected[x] == true,
                                      ))
                          ? 'Used for playback & downloads'
                          : 'Tap to use this service',
                      onTap: () => _setActive(s),
                      trailing: (_prefs.activeService ??
                                  DebridService.values.firstWhere(
                                    (x) => _connected[x] == true,
                                  )) ==
                              s
                          ? Icon(Icons.check_rounded, color: AppColors.accent, size: 20)
                          : null,
                    ),
              ],
            ),
          ],
          const SettingsSectionLabel('Services'),
          SettingsCard(
            children: [
              for (final s in DebridService.values)
                SettingsTile(
                  icon: Icons.cloud_outlined,
                  title: s.displayName,
                  subtitle: !_loaded
                      ? '…'
                      : (_connected[s] == true ? 'Connected' : 'Not connected'),
                  onTap: () => _openService(s),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Text(
              'Debrid turns a magnet into a direct HTTP stream so playback '
              'starts without waiting for peers. Tokens never leave this device.',
              style: AppText.caption,
            ),
          ),
        ],
      ),
    );
  }
}

/// Paste / validate / disconnect a single debrid API token.
class DebridServiceScreen extends StatefulWidget {
  const DebridServiceScreen({super.key, required this.service});
  final DebridService service;

  @override
  State<DebridServiceScreen> createState() => _DebridServiceScreenState();
}

class _DebridServiceScreenState extends State<DebridServiceScreen> {
  final _controller = TextEditingController();
  bool _connected = false;
  bool _busy = false;
  String? _error;

  DebridService get _s => widget.service;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final has = await DebridTokenStore.hasToken(_s);
    if (!mounted) return;
    setState(() => _connected = has);
  }

  Future<void> _validateAndSave(String raw) async {
    final token = raw.trim();
    if (token.isEmpty) {
      setState(() => _error = 'Paste an API token first.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ok = await sl<DebridResolver>().validate(_s, token);
      if (!ok) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error = 'That token was rejected. Check it and try again.';
        });
        return;
      }
      await DebridTokenStore.write(_s, token);
      _controller.clear();
      // First connection becomes the active service if none is set.
      if (sl<DebridPrefs>().activeService == null) {
        await sl<DebridPrefs>().setActiveService(_s);
      }
      if (!mounted) return;
      setState(() {
        _busy = false;
        _connected = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${_s.displayName} connected')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _disconnect() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Disconnect ${_s.displayName}?'),
        content: const Text(
          'The API token is removed from this device. Your account is not '
          'changed — you can reconnect anytime.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text('Disconnect', style: TextStyle(color: AppColors.accent)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await DebridTokenStore.clear(_s);
    if (sl<DebridPrefs>().activeService == _s) {
      await sl<DebridPrefs>().setActiveService(null);
    }
    if (mounted) setState(() => _connected = false);
  }

  Future<void> _openHelp() async {
    final uri = Uri.parse(_s.tokenHelpUrl);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      await launchUrl(uri, mode: LaunchMode.platformDefault);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar(_s.displayName),
      body: ListView(
        padding: const EdgeInsets.only(top: 4, bottom: 28),
        children: [
          if (_connected)
            SettingsCard(
              children: [
                SettingsTile(
                  icon: Icons.verified_outlined,
                  title: 'Connected',
                  subtitle: 'API token saved on this device',
                ),
                SettingsTile(
                  icon: Icons.logout_rounded,
                  title: 'Disconnect',
                  destructive: true,
                  onTap: _disconnect,
                ),
              ],
            )
          else ...[
            SettingsCard(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: TextField(
                    controller: _controller,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    enabled: !_busy,
                    style: AppText.body.copyWith(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      hintText: 'API token',
                      hintStyle: AppText.body.copyWith(
                        color: AppColors.textTertiary,
                      ),
                      border: InputBorder.none,
                    ),
                    onSubmitted: _busy ? null : _validateAndSave,
                  ),
                ),
                SettingsTile(
                  icon: Icons.link_rounded,
                  title: _busy ? 'Validating…' : 'Validate & connect',
                  onTap: _busy
                      ? null
                      : () => _validateAndSave(_controller.text),
                  trailing: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : null,
                ),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                child: Text(
                  _error!,
                  style: AppText.caption.copyWith(color: AppColors.accent),
                ),
              ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
            child: Text(_s.tokenHelp, style: AppText.caption),
          ),
          SettingsCard(
            margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            children: [
              SettingsTile(
                icon: Icons.open_in_new_rounded,
                title: 'Get an API token',
                onTap: _openHelp,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
