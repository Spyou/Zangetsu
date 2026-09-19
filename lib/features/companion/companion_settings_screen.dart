import 'dart:io' show Platform;
import 'dart:async';
import 'remote_session.dart';
import 'remote_panel.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/theme/app_colors.dart';
import '../../core/ui/settings_widgets.dart';
import 'beta_catalogue.dart';
import '../../core/models/episode.dart';
import '../../core/models/video_source.dart';
import '../../core/playback/resume_store.dart';
import '../player/player_screen.dart';
import '../player/tv_native_player.dart';
import '../home/search_screen.dart';

class CompanionSettingsScreen extends StatefulWidget {
  const CompanionSettingsScreen({
    super.key,
    this.phonePlayback,
    this.showBack = true,
    this.active = true,
  });
  final Map<String, dynamic>? phonePlayback;
  final bool showBack;
  final bool active;
  @override
  State<CompanionSettingsScreen> createState() =>
      _CompanionSettingsScreenState();
}

class _CompanionSettingsScreenState extends State<CompanionSettingsScreen>
    with WidgetsBindingObserver {
  static const _channel = BetaCatalogue.channel;
  final _address = TextEditingController();
  final _pin = TextEditingController();
  final _session = RemoteSession.instance;
  ValueNotifier<Map<String, dynamic>> get _playback => _session.playback;
  Map<String, dynamic> _receiver = {};
  final _qrSection = GlobalKey();

  bool _busy = false;
  bool get _connected => _session.connected;

  String? _error;
  bool get _tv => sl.isRegistered<AppMode>() && sl<AppMode>().isTv;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_tv) {
      unawaited(_loadReceiver());
    } else {
      _channel.invokeMethod<String>('lastAddress').then((address) {
        if (mounted && _address.text.isEmpty) {
          _address.text = address ?? '';
        }
      });
      _session.addListener(_onSession);
      unawaited(_session.start());
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _screenFocus();
  }

  @override
  void didUpdateWidget(covariant CompanionSettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _screenFocus();
  }

  void _screenFocus() {
    if (!_tv)
      unawaited(
        _channel.invokeMethod<void>(
          'remoteScreen',
          widget.active && (ModalRoute.of(context)?.isCurrent ?? true),
        ),
      );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed)
      _screenFocus();
    else if (!_tv)
      unawaited(_channel.invokeMethod<void>('remoteScreen', false));
  }

  @override
  void dispose() {
    if (!_tv && widget.active)
      unawaited(_channel.invokeMethod<void>('remoteScreen', false));
    WidgetsBinding.instance.removeObserver(this);
    _session.removeListener(_onSession);

    _address.dispose();
    _pin.dispose();

    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted)
        setState(
          () => _error = e is PlatformException ? e.message : e.toString(),
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadReceiver([String method = 'receiverState']) =>
      _run(() async {
        final data = await _channel.invokeMapMethod<String, dynamic>(method);
        if (method == 'receiverStop' || method == 'receiverForget') {
          await TvNativePlayer.stopCompanionSharing();
        }
        if (mounted) setState(() => _receiver = data ?? {});
      });

  void _onSession() {
    if (mounted) setState(() {});
  }

  Future<Map<String, dynamic>> _command(
    String action, {
    Map<String, dynamic> values = const {},
  }) async {
    try {
      return await _session.command(action, values);
    } catch (e) {
      if (mounted)
        setState(() => _error = e.toString().replaceFirst('Bad state: ', ''));
      return {};
    }
  }

  Future<void> _connect({String? bluetooth}) => _run(
    () => _session.connect({
      'address': _address.text.trim(),
      'pin': _pin.text.trim(),
      if (bluetooth != null) 'bluetooth': bluetooth,
    }),
  );
  Future<int?> _choose(String title, List<String> labels) async {
    if (!mounted) return null;
    if (labels.isEmpty) {
      setState(() => _error = 'No options available yet.');
      return null;
    }
    return showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(title),
        children: [
          for (var i = 0; i < labels.length; i++)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, i),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(labels[i]),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _find({bool bluetooth = false}) async {
    List<Map<String, dynamic>> devices = [];
    await _run(() async {
      final found = await _channel.invokeListMethod<dynamic>(
        bluetooth ? 'bluetoothDevices' : 'discover',
      );
      devices = (found ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    });
    if (!mounted || _error != null) return;
    if (devices.isEmpty) {
      setState(
        () => _error = bluetooth
            ? 'Pair your phone and TV in Bluetooth settings, then try again.'
            : 'No TVs found. Turn on TV remote on your TV, or enter its address.',
      );
      return;
    }
    final index = await _choose(
      bluetooth ? 'Paired devices' : 'Nearby TVs',
      devices.map((e) => e['name'].toString()).toList(),
    );
    if (index == null || !mounted) return;
    if (bluetooth) {
      await _connect(bluetooth: devices[index]['address'] as String);
    } else {
      _address.text = devices[index]['address'] as String;
    }
  }

  Future<void> _options(
    String kind,
    Map<String, dynamic> state, [
    int? type,
  ]) async {
    final List<dynamic> items = List.of(state[kind] as List? ?? []);
    final guard = {
      'episodeIndex': state['episodeIndex'],
      'optionsVersion': state['optionsVersion'],
    };
    if (kind == 'tracks') {
      final tracks = items.where((e) => e['type'] == type).toList();
      final index = await _choose(
        type == 3
            ? 'Subtitles'
            : type == 2
            ? 'Quality'
            : 'Audio',
        [
          type == 3 ? 'Off' : 'Automatic',
          ...tracks.map((e) => e['label'].toString()),
        ],
      );
      if (index == null) return;
      await _command(
        'track',
        values: {
          'type': type,
          ...guard,
          'group': index == 0 ? -1 : tracks[index - 1]['group'],
          if (index > 0) 'track': tracks[index - 1]['track'],
        },
      );
    } else {
      final index = await _choose(
        kind == 'episodes' ? 'Episodes' : 'Sources',
        items
            .map(
              (e) => kind == 'episodes' ? e.toString() : e['label'].toString(),
            )
            .toList(),
      );
      if (index == null) return;
      await _command(
        kind == 'episodes' ? 'episode' : 'source',
        values: {'index': index, if (kind == 'sources') ...guard},
      );
    }
  }

  Future<void> _search([String? spoken]) async {
    final catalogue = await _command('catalogues');
    if (!mounted || catalogue['items'] == null) return;
    final sources = catalogue['items'] as List;
    final sourceIndex = await _choose(
      'TV sources',
      sources.map((e) => e['name'].toString()).toList(),
    );
    if (sourceIndex == null || !mounted) return;
    String query = spoken ?? '';
    final submitted = spoken != null
        ? true
        : await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Search on TV'),
              content: TextField(
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Title'),
                onChanged: (value) => query = value,
                onSubmitted: (_) => Navigator.pop(context, true),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Search'),
                ),
              ],
            ),
          );
    if (submitted != true || !mounted) return;
    final results = await _command(
      'search',
      values: {'sourceId': sources[sourceIndex]['id'], 'query': query},
    );
    if (!mounted || results['items'] == null) return;
    final items = results['items'] as List;
    final item = await _choose(
      'Search results',
      items.map((e) => e['title'].toString()).toList(),
    );
    if (item == null) return;
    final detail = await _command(
      'detail',
      values: {'selection': items[item]['selection']},
    );
    if (!mounted || detail['episodes'] == null) return;
    final episodes = detail['episodes'] as List;
    final episode = await _choose(
      detail['title'].toString(),
      episodes.map((e) => e['label'].toString()).toList(),
    );
    if (episode != null)
      await _command(
        'play',
        values: {'detailId': detail['detailId'], 'index': episode},
      );
  }

  Future<void> _continueOnPhone() async {
    final snapshot = await _command('handoffSnapshot');
    if (!mounted || snapshot['episodes'] == null) return;
    final state = await _command('state');
    if (!mounted || state['active'] != true) return;
    final episodes = (snapshot['episodes'] as List)
        .map((e) => Episode.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    final index = (state['episodeIndex'] as num?)?.toInt() ?? 0;
    if (index < 0 || index >= episodes.length) return;
    Future<List<VideoSource>> resolve(String url) async {
      final i = episodes.indexWhere((e) => e.url == url);
      final result = await _session.command('handoffSources', {
        'session': snapshot['session'],
        'index': i,
      });
      final sources = (result['sources'] as List? ?? [])
          .map((e) => VideoSource.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      if (sources.isEmpty)
        throw StateError(
          'No phone-compatible stream is available for this episode.',
        );
      return sources;
    }

    try {
      // Resolve before pausing TV, so a failed transfer leaves playback alone.
      final sources = await resolve(episodes[index].url);
      final current = await _command('state');
      if (!mounted || current['episodeIndex'] != index) return;
      final paused = await _command('playing', values: {'value': false});
      if (paused.isEmpty || !mounted) return;

      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PlayerScreen(
            sourceId: snapshot['sourceId'] as String,
            resume: sl<ResumeStore>(),
            resolveSources: resolve,
            episodes: episodes,
            startIndex: index,
            initialSource: sources.first,
            resumePosition: Duration(
              milliseconds: (current['positionMs'] as num? ?? 0).toInt(),
            ),
            showTitle: snapshot['title'] as String?,
            showUrl: snapshot['showUrl'] as String?,
            cover: snapshot['cover'] as String?,
            playerOverride: '',
            onContinueOnTv: (episode, position) async {
              final valid = await _command(
                'handoffValidate',
                values: {'session': snapshot['session']},
              );
              if (valid['ok'] != true) return false;
              final response = await _command(
                'handoffResume',
                values: {
                  'index': episode,
                  'positionMs': position.inMilliseconds,
                },
              );
              if (response.isEmpty) return false;
              for (var attempt = 0; attempt < 45; attempt++) {
                await Future<void>.delayed(const Duration(seconds: 1));
                final playing = await _command('state');
                if (playing['episodeIndex'] == episode &&
                    playing['playing'] == true &&
                    playing['buffering'] != true &&
                    ((playing['positionMs'] as num? ?? 0) -
                                position.inMilliseconds)
                            .abs() <
                        6000)
                  return true;
                if (!_connected || playing['playbackError'] != null) break;
              }
              await _command('playing', values: {'value': false});
              return false;
            },
          ),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _continueFromPhone() async {
    final phone = widget.phonePlayback!;
    final catalogue = await _command('catalogues');
    if (!mounted || catalogue['items'] == null) return;
    final sources = catalogue['items'] as List;
    var sourceIndex = sources.indexWhere((e) => e['id'] == phone['sourceId']);
    if (sourceIndex < 0) {
      final chosen = await _choose(
        'Choose a TV source',
        sources.map((e) => e['name'].toString()).toList(),
      );
      if (chosen == null) return;
      sourceIndex = chosen;
    }
    final results = await _command(
      'search',
      values: {'sourceId': sources[sourceIndex]['id'], 'query': phone['title']},
    );
    if (!mounted || results['items'] == null) return;
    final items = results['items'] as List;
    final selected = await _choose(
      'Choose the same title on TV',
      items.map((e) => e['title'].toString()).toList(),
    );
    if (selected == null) return;
    final detail = await _command(
      'detail',
      values: {'selection': items[selected]['selection']},
    );
    if (!mounted || detail['episodes'] == null) return;
    final episodes = detail['episodes'] as List;
    final index = await _choose(
      'Continue episode ${phone['episodeNumber']}',
      episodes.map((e) => e['label'].toString()).toList(),
    );
    if (index == null) return;
    final current = await _command('state');
    if (current['active'] == true) {
      await _command('closePlayer');
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
    final response = await _command(
      'play',
      values: {
        'detailId': detail['detailId'],
        'index': index,
        'positionMs': phone['positionMs'],
      },
    );
    if (response['ok'] != true) return;
    for (var attempt = 0; attempt < 60 && mounted; attempt++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      final state = await _command('state');
      if (state['active'] == true &&
          state['title'] == detail['title'] &&
          state['episodeIndex'] == index &&
          state['buffering'] != true &&
          state['playing'] == true) {
        if (mounted) Navigator.pop(context, true);
        return;
      }
      if (!_connected || state['playbackError'] != null) return;
    }
    if (mounted)
      setState(
        () => _error =
            'The TV has not started yet. You can keep watching on your phone.',
      );
  }

  @override
  Widget build(BuildContext context) => !_tv
      ? _mobileRemote()
      : Scaffold(
          backgroundColor: AppColors.bg,
          appBar: settingsAppBar('TV remote'),
          body: SingleChildScrollView(
            padding: EdgeInsets.only(top: 12, bottom: _tv ? 32 : 100),
            child: FocusTraversalGroup(
              child: Column(
                children: [
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                      child: Text(
                        _error!,
                        style: TextStyle(color: AppColors.accent),
                      ),
                    ),
                  if (_busy && !_connected)
                    const LinearProgressIndicator(minHeight: 2),
                  ..._receiverWidgets(),
                ],
              ),
            ),
          ),
        );

  List<Widget> _receiverWidgets() {
    final hosting = _receiver['hosting'] == true;
    return [
      const SettingsSectionLabel('Connection', first: true),
      SettingsCard(
        children: [
          SettingsTile(
            autofocus: true,
            icon: Icons.phonelink_rounded,
            title: 'Allow phone remote',
            subtitle: 'Control playback and browse using your phone',
            subtitleMaxLines: 2,
            trailing: Switch(
              value: hosting,
              onChanged: _busy
                  ? null
                  : (_) => _loadReceiver(
                      hosting ? 'receiverStop' : 'receiverStart',
                    ),
            ),
            onTap: _busy
                ? null
                : () =>
                      _loadReceiver(hosting ? 'receiverStop' : 'receiverStart'),
          ),
        ],
      ),
      if (hosting) ...[
        const SettingsSectionLabel('Pair your phone'),
        SettingsCard(
          children: [
            Focus(
              key: _qrSection,
              onFocusChange: (focused) {
                if (focused && _qrSection.currentContext != null)
                  Scrollable.ensureVisible(
                    _qrSection.currentContext!,
                    alignment: .1,
                    duration: const Duration(milliseconds: 180),
                  );
              },
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        color: Colors.white,
                        padding: const EdgeInsets.all(10),
                        child: QrImageView(
                          size: 170,
                          data: Uri(
                            scheme: 'zangetsu-beta',
                            host: 'remote',
                            queryParameters: {
                              'v': '1',
                              'address': (_receiver['address'] as String? ?? '')
                                  .split('\n')
                                  .first,
                              'qr': _receiver['qr'] as String? ?? '',
                            },
                          ).toString(),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Scan to connect',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      (_receiver['pin'] as String? ?? '').split('').join(' '),
                      style: Theme.of(context).textTheme.headlineLarge
                          ?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: AppColors.accent,
                          ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Open Remote on your phone and scan this QR. It does not expire. The number above is an optional manual connection code.',
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
            ),
            SettingsTile(
              icon: Icons.wifi_rounded,
              title: 'TV address',
              subtitle: _receiver['address'] as String? ?? '',
              subtitleMaxLines: 3,
            ),
          ],
        ),
        if (!Platform.isIOS) const SettingsSectionLabel('Bluetooth'),
        if (!Platform.isIOS)
          SettingsCard(
            children: [
              SettingsTile(
                icon: Icons.bluetooth_rounded,
                title: 'Connect over Bluetooth',
                subtitle: _receiver['bluetooth'] as String?,
                subtitleMaxLines: 2,
                onTap: () => _loadReceiver('receiverBluetooth'),
              ),
              if (!Platform.isIOS)
                SettingsTile(
                  icon: Icons.settings_bluetooth_rounded,
                  title: 'Pair a Bluetooth device',
                  onTap: () => _run(
                    () => _channel.invokeMethod<void>('bluetoothSettings'),
                  ),
                ),
            ],
          ),
      ],
      if (hosting)
        SettingsCard(
          children: [
            SettingsTile(
              icon: Icons.link_off_rounded,
              title: 'Forget paired phones',
              subtitle: 'Require a new scan or code next time',
              onTap: () => _loadReceiver('receiverForget'),
            ),
          ],
        ),
    ];
  }

  Widget _mobileRemote() => Scaffold(
    backgroundColor: AppColors.bg,
    appBar: settingsAppBar('Remote', showBack: widget.showBack),
    body: SafeArea(
      top: false,
      child: ValueListenableBuilder<Map<String, dynamic>>(
        valueListenable: _playback,
        builder: (context, state, _) => RemotePanel(
          inRemoteTab: !widget.showBack,
          systemControls: !Platform.isIOS && _session.hid,
          connected: _connected,
          name: _session.name,
          status: _connected
              ? (_session.hid || _session.bluetoothCompanion
                    ? 'Bluetooth · ${_session.wifi ? "Wi-Fi ready" : "connected"}'
                    : (Platform.isIOS
                          ? 'Wi-Fi · connected'
                          : 'Wi-Fi fallback · Bluetooth not connected'))
              : _session.reconnecting
              ? 'Reconnecting…'
              : _session.saved
              ? 'Waiting for your TV'
              : 'Scan your TV to connect',
          remoteMode: _session.remoteMode,
          companionReady: _session.companion && state['appForeground'] == true,
          state: state,
          error: _error ?? _session.error,
          onMode: (value) => _run(() => _session.setRemoteMode(value)),
          onManage: _manage,
          onScan: _scan,
          onSearch: _searchOptions,
          onShortcut: _shortcut,
          command: (action, values) {
            if (const {
              'key',
              'release',
              'toggle',
              'rewind',
              'forward',
              'previous',
              'next',
              'stop',
              'home',
              'menu',
              'power',
              'escape',
              'volumeUp',
              'volumeDown',
              'mute',
            }.contains(action)) {
              unawaited(_session.control(action, values));
            } else {
              unawaited(_command(action, values: values));
            }
          },
        ),
      ),
    ),
  );

  Future<void> _scan() => _run(() async {
    final raw = await _channel.invokeMethod<String>('scanPairing');
    if (raw != null) await _session.connectQr(raw);
  });

  Future<void> _manage() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.bg,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, refresh) => SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
            ),
            child: SizedBox(
              height: MediaQuery.sizeOf(sheetContext).height * .68,
              child: ListView(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                    child: Text(
                      'Connection',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  SettingsCard(
                    children: [
                      if (widget.phonePlayback != null)
                        SettingsTile(
                          icon: Icons.connected_tv_rounded,
                          title: 'Continue on TV',
                          onTap: () {
                            Navigator.pop(sheetContext);
                            _continueFromPhone();
                          },
                        ),
                      if (!Platform.isIOS)
                        SettingsTile(
                          icon: Icons.bluetooth_connected,
                          title: 'Bluetooth remote',
                          subtitle: _session.bluetoothDetail,
                          subtitleMaxLines: 3,
                          onTap: _linkBluetooth,
                        ),
                      if (!Platform.isIOS)
                        SettingsTile(
                          icon: Icons.add_link,
                          title: 'Pair a new Bluetooth TV',
                          subtitle:
                              'Then choose this phone in TV › Remotes & accessories',
                          subtitleMaxLines: 2,
                          onTap: () => _run(
                            () => _channel.invokeMethod<void>('pairBluetooth'),
                          ),
                        ),
                    ],
                  ),
                  if (_connected)
                    SettingsCard(
                      children: [
                        SettingsTile(
                          icon: Icons.connected_tv_rounded,
                          title: _session.name,
                          subtitle: 'Paired · reconnects automatically',
                        ),
                        if (!Platform.isIOS)
                          SettingsTile(
                            icon: Icons.power_settings_new_rounded,
                            title: 'TV power',
                            onTap: () {
                              Navigator.pop(sheetContext);
                              _run(() => _session.control('power'));
                            },
                          ),
                        SettingsTile(
                          icon: Icons.qr_code_scanner_rounded,
                          title: 'Scan another TV',
                          onTap: () {
                            Navigator.pop(sheetContext);
                            _scan();
                          },
                        ),
                        SettingsTile(
                          icon: Icons.link_off_rounded,
                          title: 'Disconnect',
                          onTap: () async {
                            await _session.disconnect();
                            if (sheetContext.mounted)
                              Navigator.pop(sheetContext);
                          },
                        ),
                        SettingsTile(
                          icon: Icons.delete_outline_rounded,
                          title: 'Forget TV',
                          destructive: true,
                          onTap: () async {
                            await _session.disconnect(forget: true);
                            if (sheetContext.mounted)
                              Navigator.pop(sheetContext);
                          },
                        ),
                      ],
                    )
                  else ...[
                    SettingsCard(
                      children: [
                        SettingsTile(
                          icon: Icons.qr_code_scanner_rounded,
                          title: 'Scan TV code',
                          onTap: () {
                            Navigator.pop(sheetContext);
                            _scan();
                          },
                        ),
                        SettingsTile(
                          icon: Icons.wifi_find_rounded,
                          title: 'Find TVs',
                          onTap: () async {
                            await _find();
                            if (sheetContext.mounted) refresh(() {});
                          },
                        ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Column(
                        children: [
                          TextField(
                            controller: _address,
                            decoration: const InputDecoration(
                              labelText: 'TV address',
                              hintText: 'Shown in TV remote settings',
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _pin,
                            keyboardType: TextInputType.number,
                            maxLength: 6,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                            decoration: const InputDecoration(
                              labelText: 'Pairing code',
                              helperText: 'Only needed the first time',
                              counterText: '',
                            ),
                          ),
                          const SizedBox(height: 16),
                          FilledButton(
                            onPressed: () async {
                              await _connect();
                              if (sheetContext.mounted && _connected)
                                Navigator.pop(sheetContext);
                              else if (sheetContext.mounted)
                                refresh(() {});
                            },
                            child: const Text('Connect to TV'),
                          ),
                          if (_error != null)
                            Text(
                              _error!,
                              style: TextStyle(color: AppColors.accent),
                            ),
                        ],
                      ),
                    ),
                    if (!Platform.isIOS)
                      SettingsCard(
                        children: [
                          SettingsTile(
                            icon: Icons.bluetooth_rounded,
                            title: 'Use Bluetooth',
                            onTap: () async {
                              await _find(bluetooth: true);
                              if (sheetContext.mounted && _connected)
                                Navigator.pop(sheetContext);
                            },
                          ),
                          if (!Platform.isIOS)
                            SettingsTile(
                              icon: Icons.settings_bluetooth_rounded,
                              title: 'Bluetooth settings',
                              onTap: () => _run(
                                () => _channel.invokeMethod<void>(
                                  'bluetoothSettings',
                                ),
                              ),
                            ),
                        ],
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _searchOptions() async {
    final option = await _choose('Search', [
      'Search TV sources',
      if (!Platform.isIOS) 'Voice search on TV',
      'Browse on phone',
    ]);
    if (!mounted || option == null) return;
    if (option == 0) {
      await _search();
    }
    if (option == 1 && !Platform.isIOS) {
      final phrase = await const MethodChannel('zangetsu/voice_search')
          .invokeMethod<String>('listen', {
            'prompt': 'Say an anime, movie or show',
          });
      if (phrase != null && phrase.trim().isNotEmpty)
        await _search(phrase.trim());
    }
    if (option == (Platform.isIOS ? 1 : 2) && mounted) {
      await _session.setRemoteMode(true);
      if (mounted)
        await Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const SearchScreen()));
    }
  }

  Future<void> _linkBluetooth() => _run(() async {
    final devices =
        await _channel.invokeListMethod<dynamic>('bluetoothDevices') ?? [];
    if (!mounted) return;
    final index = await _choose(
      'Choose the same TV for Bluetooth',
      devices.map((d) => d['name'].toString()).toList(),
    );
    if (index != null) {
      await _channel.invokeMethod<void>(
        'linkBluetooth',
        devices[index]['address'],
      );
      await _session.refreshConnection();
    }
  });

  void _shortcut(String action) {
    final state = Map<String, dynamic>.of(_playback.value);
    switch (action) {
      case 'phone':
        _continueOnPhone();
      case 'episodes':
        _options('episodes', state);
      case 'sources':
        _options('sources', state);
      case 'quality':
        _options('tracks', state, 2);
      case 'audio':
        _options('tracks', state, 1);
      case 'subtitles':
        _options('tracks', state, 3);
    }
  }
}
