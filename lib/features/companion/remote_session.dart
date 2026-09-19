import 'apple_companion.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/di/injector.dart';

/// A connection belongs to the app, not the remote page. Commands are ordered
/// and never replayed when a connection is re-established.
class RemoteSession extends ChangeNotifier with WidgetsBindingObserver {
  static final instance = RemoteSession();
  static const channel = CompanionChannel();
  bool connected = false;
  bool companion = false, hid = false, wifi = false, bluetoothCompanion = false;
  String bluetoothDetail = '';
  Map<String, dynamic>? _pendingSkip;
  bool _polling = false;
  bool saved = false;
  bool reconnecting = false;
  bool remoteMode = false;
  String name = 'Your TV';
  String transport = 'Wi-Fi';
  String? error;
  Map<String, dynamic> state = {};
  final playback = ValueNotifier<Map<String, dynamic>>({});
  Timer? _timer;
  Future<void> _tail = Future.value();
  bool _working = false;
  bool _started = false;
  DateTime _retryAfter = DateTime(0);

  Future<void> start() async {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    PlaybackPrefs.remoteSkipChanges.addListener(_skipChanged);
    await refreshConnection();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (_working || reconnecting || _polling) return;
      _polling = true;
      await refreshConnection();
      if (companion) {
        try {
          if (_pendingSkip != null) {
            final values = _pendingSkip!;
            await command('skipSettings', values);
            if (identical(values, _pendingSkip)) _pendingSkip = null;
          }
          await command('state');
        } catch (_) {}
      } else if (saved && !connected && DateTime.now().isAfter(_retryAfter)) {
        await reconnect();
      }
      _polling = false;
    });
    if (saved && !connected) unawaited(reconnect());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && saved && !connected)
      unawaited(reconnect());
  }

  Future<void> refreshConnection() async {
    try {
      final result =
          await channel.invokeMapMethod<String, dynamic>('connectionState') ??
          {};
      connected = result['connected'] == true;
      companion = result['companion'] == true;
      hid = result['hid'] == true;
      wifi = result['wifi'] == true;
      bluetoothCompanion = result['bluetoothCompanion'] == true;
      bluetoothDetail = result['bluetoothDetail'] as String? ?? '';
      if (!companion && playback.value.isNotEmpty) playback.value = {};
      saved = result['saved'] == true;
      remoteMode = result['remoteMode'] == true;
      name = result['name'] as String? ?? name;
      transport = result['transport'] as String? ?? transport;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> connect(Map<String, dynamic> arguments) async {
    reconnecting = true;
    error = null;
    notifyListeners();
    try {
      await channel.invokeMethod<void>('connect', arguments);
      await refreshConnection();
      connected = true;
      saved = true;
    } catch (e) {
      connected = false;
      error = _message(e);
      rethrow;
    } finally {
      reconnecting = false;
      notifyListeners();
    }
    await command('state');
    try {
      await channel.invokeMethod<void>('enableBluetoothRemote');
    } catch (e) {
      error = _message(e);
      notifyListeners();
    }
  }

  void _skipChanged() {
    if (!sl.isRegistered<PlaybackPrefs>()) return;
    final p = sl<PlaybackPrefs>();
    _pendingSkip = {
      'skipIntro': p.skipIntro,
      'megaSkip': p.megaSkip,
      'megaSkipSeconds': p.megaSkipSeconds,
    };
  }

  Future<void> control(
    String action, [
    Map<String, dynamic> values = const {},
  ]) async {
    // Key releases and HID taps must never wait behind catalogue requests.
    try {
      final raw = await channel.invokeMethod<String>(
        'control',
        jsonEncode({'action': action, ...values}),
      );
      final response = jsonDecode(raw ?? '{}') as Map<String, dynamic>;
      if (response['error'] != null)
        throw StateError(response['error'].toString());
      error = null;
      if (action == 'home') {
        playback.value = {};
        state = {};
      }
      notifyListeners();
    } catch (e) {
      error = _message(e);
      notifyListeners();
    }
  }

  Future<void> reconnect() async {
    if (reconnecting || !saved) return;
    reconnecting = true;
    notifyListeners();
    try {
      await channel.invokeMethod<void>('reconnect');
      error = null;
      await refreshConnection();
    } catch (e) {
      connected = false;
      error = _message(e);
      _retryAfter = DateTime.now().add(const Duration(seconds: 8));
      await refreshConnection();
      try {
        if (saved) await channel.invokeMethod<dynamic>('discover');
      } catch (_) {}
    } finally {
      reconnecting = false;
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>> command(
    String action, [
    Map<String, dynamic> values = const {},
  ]) {
    final result = Completer<Map<String, dynamic>>();
    _tail = _tail.then((_) async {
      if (!connected) {
        result.completeError(StateError('Reconnect to your TV first.'));
        return;
      }
      _working = true;
      try {
        final raw = await channel.invokeMethod<String>(
          'command',
          jsonEncode({'action': action, ...values}),
        );
        final response = jsonDecode(raw!) as Map<String, dynamic>;
        if (response['error'] != null)
          throw StateError(response['error'].toString());
        if (response.containsKey('active')) {
          state = response;
          playback.value = response;
        }
        result.complete(response);
      } catch (e) {
        if (e is PlatformException) {
          await refreshConnection();
          _retryAfter = DateTime.now().add(const Duration(seconds: 2));
        }
        // A failed background status probe is not a failed user button press.
        if (action != 'state')
          error = _message(e);
        else {
          playback.value = {};
          state = {};
        }
        notifyListeners();
        result.completeError(e);
      } finally {
        _working = false;
      }
    });
    return result.future;
  }

  Future<void> setRemoteMode(bool enabled) async {
    remoteMode = enabled;
    await channel.invokeMethod<void>('remoteMode', enabled);
    notifyListeners();
    if (connected)
      await command('browseStatus', {
        'title': enabled ? 'Browsing on phone' : '',
      });
  }

  Future<void> disconnect({bool forget = false}) async {
    await channel.invokeMethod<void>(forget ? 'forget' : 'disconnect');
    connected = false;
    saved = false;
    remoteMode = false;
    error = null;
    await channel.invokeMethod<void>('remoteMode', false);
    notifyListeners();
  }

  Future<void> connectQr(String raw) async {
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.scheme != 'zangetsu-beta' ||
        uri.host != 'remote' ||
        uri.queryParameters['v'] != '1') {
      throw StateError('Scan the code in your TV’s Zangetsu remote settings.');
    }
    final address = uri.queryParameters['address'] ?? '';
    final pin = uri.queryParameters['pin'] ?? '';
    final qr = uri.queryParameters['qr'] ?? '';
    if (!RegExp(r'^\d{1,3}(\.\d{1,3}){3}:\d{1,5}$').hasMatch(address) ||
        !(RegExp(r'^\d{6}$').hasMatch(pin) ||
            RegExp(r'^[a-f0-9]{64}$').hasMatch(qr))) {
      throw StateError(
        'This pairing code is incomplete. Refresh it on the TV.',
      );
    }
    await connect({'address': address, 'pin': pin, 'qr': qr});
  }

  String _message(Object e) => e is PlatformException
      ? e.message ?? 'Connection lost'
      : e.toString().replaceFirst('Bad state: ', '');

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    PlaybackPrefs.remoteSkipChanges.removeListener(_skipChanged);
    playback.dispose();
    super.dispose();
  }
}
