import 'dart:io' show Platform;
import 'dart:async';
import 'remote_session.dart';
import 'remote_panel.dart';
import 'remote_prefs.dart';
import 'remote_keyboard.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/theme/app_colors.dart';
import '../../core/ui/settings_widgets.dart';
import 'companion_catalogue.dart';
import 'handoff_sources_wire.dart';
import '../../core/models/episode.dart';
import '../../core/models/video_source.dart';
import '../../core/playback/resume_store.dart';
import '../player/player_screen.dart';
import '../player/tv_native_player.dart';
import '../home/search_screen.dart';
import '../home/phone_voice_search_sheet.dart';

/// TV receiver setup or mobile remote page, selected by the current app mode.
class CompanionSettingsScreen extends StatefulWidget {
  const CompanionSettingsScreen({
    super.key,
    this.phonePlayback,
    this.showBack = true,
    this.active = true,
  });
  /// What the phone is playing (sourceId, title, episodeNumber, positionMs)
  /// when opened from the player; enables "Continue on TV". Null otherwise.
  final Map<String, dynamic>? phonePlayback;

  /// Shows the app bar back button; false when embedded as the Remote tab.
  final bool showBack;

  /// Whether this page is the visible tab, so it may own volume keys and
  /// auto-open the TV keyboard.
  final bool active;
  @override
  State<CompanionSettingsScreen> createState() =>
      _CompanionSettingsScreenState();
}

/// Owns page-only discovery and dialogs while RemoteSession retains the connection.
class _CompanionSettingsScreenState extends State<CompanionSettingsScreen>
    with WidgetsBindingObserver {
  /// Native method channel for receiver, discovery, Bluetooth and scanning.
  static const _channel = CompanionCatalogue.channel;

  /// Typed TV address for a manual Wi-Fi connect.
  final _address = TextEditingController();

  /// Typed pairing code; only needed on the first connect to a TV.
  final _pin = TextEditingController();

  /// App-wide remote connection that outlives this page.
  final _session = RemoteSession.instance;

  /// Latest TV player state pushed by the receiver.
  ValueNotifier<Map<String, dynamic>> get _playback => _session.playback;

  /// TV side: receiver state from native (hosting, pin, qr, address, bluetooth).
  Map<String, dynamic> _receiver = {};

  /// Key of the QR card so focusing it scrolls it into view on TV.
  final _qrSection = GlobalKey();

  /// True while a page action from [_run] is in flight.
  bool _busy = false;
  bool get _connected => _session.connected;

  /// Last user-facing error shown on the page, cleared on the next action.
  String? _error;

  /// Whether this device runs the TV receiver rather than the phone remote.
  bool get _tv => sl.isRegistered<AppMode>() && sl<AppMode>().isTv;

  @override
  /// Subscribes the page to the app-owned session and initializes receiver management.
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_tv) {
      unawaited(_loadReceiver());
      // The TV retires its PIN after each pairing, so keep the shown one fresh.
      _receiverPoll = Timer.periodic(
        const Duration(seconds: 3),
        (_) => unawaited(_refreshReceiver()),
      );
    } else {
      _channel.invokeMethod<String>('lastAddress').then((address) {
        if (mounted && _address.text.isEmpty) {
          _address.text = address ?? '';
        }
      });
      _session.addListener(_onSession);
      unawaited(_session.start());
      unawaited(RemotePrefs.init());
      // Raise iOS's Local Network prompt before the first QR or typed connect.
      if (Platform.isIOS)
        unawaited(
          _channel
              .invokeListMethod<dynamic>('discover')
              .then((_) {}, onError: (_) {}),
        );
    }
  }

  /// Re-evaluates volume-key ownership when the route above changes.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _screenFocus();
  }

  /// Re-evaluates volume-key ownership when [CompanionSettingsScreen.active]
  /// changes.
  @override
  void didUpdateWidget(covariant CompanionSettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _screenFocus();
  }

  /// Gives phone volume keys to the remote only while this page is visible.
  void _screenFocus() {
    if (!_tv)
      unawaited(
        _channel.invokeMethod<void>(
          'remoteScreen',
          widget.active && (ModalRoute.of(context)?.isCurrent ?? true),
        ),
      );
  }

  /// Hands volume keys back to the system while the app is in the background.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed)
      _screenFocus();
    else if (!_tv)
      unawaited(_channel.invokeMethod<void>('remoteScreen', false));
  }

  @override
  /// Releases page listeners and key ownership without disconnecting the app session.
  void dispose() {
    if (!_tv && widget.active)
      unawaited(_channel.invokeMethod<void>('remoteScreen', false));
    WidgetsBinding.instance.removeObserver(this);
    _session.removeListener(_onSession);
    _receiverPoll?.cancel();

    _address.dispose();
    _pin.dispose();

    super.dispose();
  }

  /// Wraps page actions with busy/error state and guards disposal while awaiting.
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = RemoteSession.userMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Refreshes TV setup metadata after receiver start, stop or credential revocation.
  Future<void> _loadReceiver([String method = 'receiverState']) =>
      _run(() async {
        final data = await _channel.invokeMapMethod<String, dynamic>(method);
        if (method == 'receiverStop' || method == 'receiverForget') {
          await TvNativePlayer.stopCompanionSharing();
        }
        if (mounted) setState(() => _receiver = data ?? {});
      });

  /// TV side: polls receiver state every 3 s so a rotated PIN shows promptly.
  Timer? _receiverPoll;

  /// Quietly picks up a new PIN after a phone pairs; never shows busy or errors.
  Future<void> _refreshReceiver() async {
    if (_busy || _receiver['hosting'] != true) return;
    try {
      final data = await _channel.invokeMapMethod<String, dynamic>(
        'receiverState',
      );
      if (!mounted || _busy || data == null) return;
      if (data['pin'] != _receiver['pin'] ||
          data['qr'] != _receiver['qr'] ||
          data['hosting'] != _receiver['hosting'] ||
          data['bluetooth'] != _receiver['bluetooth'])
        setState(() => _receiver = data);
    } catch (_) {
      /* The next explicit load reports failures. */
    }
  }

  /// Rebuilds page chrome when shared connection state changes.
  void _onSession() {
    // A fresh connection resolves any page error left from the dropped one.
    final reconnected = _session.connected && !_wasConnected;
    _wasConnected = _session.connected;
    if (mounted)
      setState(() {
        if (reconnected) _error = null;
      });
  }

  /// Connection state seen by the last [_onSession], to detect reconnects.
  late bool _wasConnected = _session.connected;

  /// Delegates a receiver request to the ordered app session.
  Future<Map<String, dynamic>> _command(
    String action, {
    Map<String, dynamic> values = const {},
  }) async {
    try {
      final result = await _session.command(action, values);
      if (mounted && _error != null) setState(() => _error = null);
      return result;
    } catch (e) {
      if (mounted) setState(() => _error = RemoteSession.userMessage(e));
      return {};
    }
  }

  /// Connects the selected Wi-Fi receiver or bonded Bluetooth device through the shared session.
  Future<void> _connect({String? bluetooth}) => _run(
    () => _session.connect({
      'address': _address.text.trim(),
      'pin': _pin.text.trim(),
      if (bluetooth != null) 'bluetooth': bluetooth,
    }),
  );

  /// Presents labelled choices and returns an index or null when dismissed.
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

  /// Discovers reachable TVs or enumerates bonded devices, then asks the user to choose.
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

  /// Presents versioned player choices so stale source/track indices cannot select another item.
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

  /// Searches the TV catalogue and resolves the selected episode on the receiver.
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

  /// Obtains the active TV stream and resume point before launching local playback.
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
    // How often each episode was asked for. The hand-off itself and the
    // player's first open each ask once; any later ask is a retry after a
    // failure, so the TV is told to fetch fresh links instead of reusing them.
    final asks = <int, int>{};
    // Where the TV's next page of links starts, per episode, while the TV
    // holds more than it sent. A retry reads that page first and asks for a
    // fresh set only once every page has been tried.
    final nextPage = <int, int>{};
    String plain(String url) =>
        url.replaceAll('/dub/', '/x/').replaceAll('/sub/', '/x/');
    Future<List<VideoSource>> resolve(String url) async {
      var i = episodes.indexWhere((e) => e.url == url);
      if (i < 0) i = episodes.indexWhere((e) => plain(e.url) == plain(url));
      if (i < 0)
        throw StateError(
          'This episode is not in the TV list. Open Continue on phone again.',
        );
      final asked = asks[i] = (asks[i] ?? 0) + 1;
      final retry = asked > 2;
      // Taken out before asking, so a failed page makes the next retry ask
      // for a fresh set instead of the same page again.
      final offset = retry ? nextPage.remove(i) : null;
      final result = await _session.command('handoffSources', {
        'session': snapshot['session'],
        'index': i,
        'format': handoffSourcesFormat,
        if (offset != null) 'offset': offset else if (retry) 'refresh': true,
      });
      // An older TV answers in the full format, which has no further pages.
      final page = readHandoffSources(result);
      final next = page.nextOffset;
      if (next != null) {
        nextPage[i] = next;
      } else {
        nextPage.remove(i);
      }
      final sources = page.sources;
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
            // Every link comes from the TV, so the phone needs no source.
            remoteResolve: true,
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
      if (mounted) setState(() => _error = RemoteSession.userMessage(e));
    }
  }

  /// Transfers the local episode and position to the TV, leaving local recovery to the caller.
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

  /// Phone: the remote panel. TV: the receiver setup page with errors on top.
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

  /// TV setup tiles: the on/off switch and, while hosting, the pairing QR
  /// (zangetsu-remote://remote?v=1&address=..&qr=..), PIN, address,
  /// Bluetooth options and "Forget paired phones".
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
                            scheme: 'zangetsu-remote',
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

  /// Embeds the same remote panel in dock/full-screen routes using their available height.
  Widget _mobileRemote() => Scaffold(
    backgroundColor: AppColors.bg,
    appBar: settingsAppBar('Remote', showBack: widget.showBack),
    body: SafeArea(
      top: false,
      child: ValueListenableBuilder<Map<String, dynamic>>(
        valueListenable: _playback,
        builder: (context, state, _) => RemoteKeyboardHost(
          // Auto-open only while this remote page is the visible route.
          autoOpen:
              !_tv &&
              widget.active &&
              (ModalRoute.of(context)?.isCurrent ?? true),
          child: RemotePanel(
            onKeyboard: () => RemoteKeyboardSheet.show(context, manual: true),
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
            companionReady:
                _session.companion && state['appForeground'] == true,
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
    ),
  );

  /// Requests a platform QR scan and delegates validation to RemoteSession.
  Future<void> _scan() => _run(() async {
    final raw = await _channel.invokeMethod<String>('scanPairing');
    if (raw != null) await _session.connectQr(raw);
  });

  /// Presents pairing, reconnection and transport management outside the compact control panel.
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
                          subtitle: 'Search for your TV from this phone',
                          subtitleMaxLines: 2,
                          onTap: () async {
                            await _findBluetoothTv();
                            if (sheetContext.mounted) refresh(() {});
                          },
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

  /// Offers supported text/voice search or phone browsing without hiding traditional controls.
  Future<void> _searchOptions() async {
    final option = await _choose('Search', [
      'Search TV sources',
      'Voice search on TV',
      'Browse on phone',
    ]);
    if (!mounted || option == null) return;
    if (option == 0) {
      await _search();
    }
    if (option == 1 && mounted) {
      final phrase = Platform.isIOS
          ? await showPhoneVoiceSearchSheet(context)
          : await const MethodChannel(
              'zangetsu/voice_search',
            ).invokeMethod<String>('listen', {
              'prompt': 'Say an anime, movie or show',
            });
      if (mounted && phrase != null && phrase.trim().isNotEmpty)
        await _search(phrase.trim());
    }
    if (option == 2 && mounted) {
      await _session.setRemoteMode(true);
      if (mounted)
        await Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const SearchScreen()));
    }
  }

  /// Associates a user-selected bonded TV with the already paired companion receiver.
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

  /// Lets the phone search for nearby Bluetooth TVs and pair with the chosen one.
  Future<void> _findBluetoothTv() async {
    final paired = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.bg,
      showDragHandle: true,
      builder: (_) => const _BluetoothTvSheet(channel: _channel),
    );
    if (paired == true && mounted) {
      await _run(() => _session.refreshConnection());
    }
  }

  /// Routes a contextual playback shortcut to its corresponding action sheet.
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

/// Bottom sheet where the phone searches for nearby Bluetooth TVs and pairs with one.
class _BluetoothTvSheet extends StatefulWidget {
  const _BluetoothTvSheet({required this.channel});

  /// Companion channel providing the bluetoothScan* and bluetoothPair calls.
  final MethodChannel channel;
  @override
  State<_BluetoothTvSheet> createState() => _BluetoothTvSheetState();
}

/// Runs a native Bluetooth scan while open and pops `true` once a TV pairs.
class _BluetoothTvSheetState extends State<_BluetoothTvSheet> {
  /// Polls native scan results every second while the sheet is open.
  Timer? _poll;

  /// Whether the native scan is still running.
  bool _scanning = false;

  /// Found devices as maps of name, address, tv, bonding and bonded.
  List<Map<String, dynamic>> _devices = const [];

  /// Address of the device being paired, or null when idle.
  String? _pairing;

  /// True while "Let the TV find this phone" is starting.
  bool _fallbackBusy = false;

  /// Last user-facing scan or pairing error.
  String? _error;

  /// Starts scanning at once and begins polling for results.
  @override
  void initState() {
    super.initState();
    unawaited(_startScan());
    _poll = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_refresh()),
    );
  }

  /// Stops polling and the native scan, which drains battery and slows links.
  @override
  void dispose() {
    _poll?.cancel();
    unawaited(
      widget.channel.invokeMethod<void>('bluetoothScanStop').catchError((_) {}),
    );
    super.dispose();
  }

  /// Asks native to (re)start a Bluetooth scan; shows an error if refused.
  Future<void> _startScan() async {
    setState(() {
      _error = null;
      _scanning = true;
    });
    try {
      await widget.channel.invokeMethod<void>('bluetoothScan');
      await _refresh();
    } catch (e) {
      if (mounted)
        setState(() {
          _scanning = false;
          _error = RemoteSession.userMessage(e);
        });
    }
  }

  /// Reads the current scan results; failures are ignored until the next poll.
  Future<void> _refresh() async {
    try {
      final data = await widget.channel.invokeMapMethod<String, dynamic>(
        'bluetoothScanResults',
      );
      if (!mounted || data == null) return;
      final raw = data['devices'] as List<dynamic>? ?? const [];
      setState(() {
        _scanning = data['scanning'] == true;
        _devices = raw
            .whereType<Map<dynamic, dynamic>>()
            .map((d) => Map<String, dynamic>.from(d))
            .toList();
      });
    } catch (_) {}
  }

  /// Bonds with [device] (the TV shows a code to confirm) and closes on success.
  Future<void> _pair(Map<String, dynamic> device) async {
    if (_pairing != null) return;
    final address = device['address']?.toString() ?? '';
    if (address.isEmpty) return;
    setState(() {
      _pairing = address;
      _error = null;
    });
    try {
      await widget.channel.invokeMapMethod<String, dynamic>(
        'bluetoothPair',
        address,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted)
        setState(() {
          _pairing = null;
          _error = RemoteSession.userMessage(e);
        });
    }
  }

  /// Fallback: makes this phone discoverable so the TV can pair from its side.
  Future<void> _letTvFind() async {
    if (_fallbackBusy) return;
    setState(() {
      _fallbackBusy = true;
      _error = null;
    });
    try {
      // An active search slows the TV's own connection, so stop it first.
      await widget.channel.invokeMethod<void>('bluetoothScanStop');
      await _refresh();
      await widget.channel.invokeMethod<void>('pairBluetooth');
    } catch (e) {
      if (mounted) setState(() => _error = RemoteSession.userMessage(e));
    } finally {
      if (mounted) setState(() => _fallbackBusy = false);
    }
  }

  /// Lists found devices with pairing status, plus retry and fallback actions.
  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: AppColors.textSecondary);
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .68,
        child: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Text(
                'Find your TV',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            SettingsCard(
              children: [
                if (_scanning)
                  const SettingsTile(
                    icon: Icons.bluetooth_searching_rounded,
                    title: 'Searching…',
                    trailing: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                for (final device in _devices)
                  SettingsTile(
                    icon: device['tv'] == true
                        ? Icons.tv_rounded
                        : Icons.bluetooth_rounded,
                    title: (device['name'] ?? device['address'] ?? '')
                        .toString(),
                    subtitle: _pairing == device['address']
                        ? 'Confirm the code on your TV'
                        : device['bonding'] == true
                        ? 'Pairing…'
                        : device['bonded'] == true
                        ? 'Paired'
                        : null,
                    subtitleMaxLines: 2,
                    trailing: _pairing == device['address']
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : null,
                    onTap: _pairing == null ? () => _pair(device) : null,
                  ),
                if (!_scanning)
                  SettingsTile(
                    icon: Icons.refresh_rounded,
                    title: 'Search again',
                    onTap: _pairing == null ? _startScan : null,
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
              child: Text(
                'Not listed? On the TV, open Settings › Remotes & accessories so it can be found.',
                style: muted,
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
                child: Text(_error!, style: TextStyle(color: AppColors.accent)),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: _fallbackBusy || _pairing != null
                      ? null
                      : _letTvFind,
                  child: const Text('Let the TV find this phone instead'),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: Text(
                'Then choose this phone in TV › Remotes & accessories',
                style: muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
