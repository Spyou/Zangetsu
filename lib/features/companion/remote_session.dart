import 'apple_companion.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/di/injector.dart';
import 'remote_keyboard.dart';

/// The phone side of the "phone as TV remote" feature: app-owned connection
/// and playback state that survives disposal of individual remote pages.
///
/// A connection belongs to the app, not the remote page. Commands are ordered
/// and never replayed when a connection is re-established. All native work
/// goes through [channel]; the TV answers each command with a JSON reply.
class RemoteSession extends ChangeNotifier with WidgetsBindingObserver {
  /// The single app-wide session shared by every remote screen.
  static final instance = RemoteSession();

  /// Platform channel to the native companion code (Android / Apple).
  static const channel = CompanionChannel();

  /// True while native code reports a usable link to the TV (any transport).
  bool connected = false;

  /// Per-transport flags from the last `connectionState` reply: [companion]
  /// is the request/reply command link, [hid] the Bluetooth keyboard/remote
  /// profile, [wifi] the LAN link and [bluetoothCompanion] commands over
  /// Bluetooth.
  bool companion = false, hid = false, wifi = false, bluetoothCompanion = false;

  /// Human-readable Bluetooth status from native code, shown in settings.
  String bluetoothDetail = '';

  /// Guards against overlapping poll ticks.
  bool _polling = false;

  /// True when pairing credentials for a TV are stored on this phone.
  bool saved = false;

  /// True while a connect or reconnect attempt is in flight.
  bool reconnecting = false;

  /// When on, browsing on the phone starts playback on the TV instead.
  bool remoteMode = false;

  /// Display name of the paired TV.
  String name = 'Your TV';

  /// Label of the active transport (for example `Wi-Fi` or `Bluetooth`).
  String transport = 'Wi-Fi';

  /// Last user-facing failure, or null when the last action succeeded.
  String? error;

  /// Last full state reply from the TV (contains `active` when it played).
  Map<String, dynamic> state = {};

  /// Same as [state] but listenable, so the now-playing UI can rebuild alone.
  final playback = ValueNotifier<Map<String, dynamic>>({});

  /// The TV text box the phone keyboard can type into (protocol v1), or null.
  final keyboard = ValueNotifier<Map<String, dynamic>?>(null);

  /// True only while the last state reply advertised `keyboardVersion: 1`;
  /// older TVs reject keyboard actions, so nothing is sent without it.
  bool keyboardSupported = false;

  /// One-second poller that refreshes state and retries saved connections.
  Timer? _timer;

  /// End of the serial command queue; each [command] chains onto it.
  Future<void> _tail = Future.value();

  /// True while a queued command is talking to the TV; the poller skips then.
  bool _working = false;

  /// Makes [start] idempotent.
  bool _started = false;

  /// Earliest time the poller may try another automatic reconnect.
  DateTime _retryAfter = DateTime(0);

  /// Starts one lifecycle observer and state poller; repeated calls reuse the session.
  ///
  /// Each tick pushes pending skip settings, asks the TV for `state`, or
  /// reconnects a saved TV once [_retryAfter] has passed.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    RemoteKeyboardPrompter.start();
    await refreshConnection();
    // Phones that never paired a TV pay nothing: the poller only runs while a
    // TV is saved or connected, and [connect] starts it after pairing.
    if (saved) _ensurePoller();
    if (saved && !connected) unawaited(reconnect());
  }

  /// Starts the one-second poller if it is not already running.
  void _ensurePoller() {
    if (_timer != null) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (_working || reconnecting || _polling) return;
      _polling = true;
      await refreshConnection();
      if (companion) {
        try {
          await command('state');
        } catch (_) {}
      } else if (saved && !connected && DateTime.now().isAfter(_retryAfter)) {
        await reconnect();
      } else if (!saved && !connected) {
        // Forgotten TV: stop polling until the next pairing.
        _timer?.cancel();
        _timer = null;
      }
      _polling = false;
    });
  }

  /// Refreshes receiver availability when the phone returns to the foreground.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // The cached `connected` predates suspension; the TV may have dropped the
    // idle link meanwhile, so read fresh state before deciding to reconnect.
    unawaited(() async {
      await refreshConnection();
      if (saved && !connected) await reconnect();
    }());
  }

  /// Reads native transport status without treating a companion failure as HID disconnection.
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
      if (!companion) _clearKeyboard();
      saved = result['saved'] == true;
      remoteMode = result['remoteMode'] == true;
      name = result['name'] as String? ?? name;
      transport = result['transport'] as String? ?? transport;
      notifyListeners();
    } catch (_) {}
  }

  /// Pairs/connects a receiver and then refreshes capabilities before notifying the UI.
  ///
  /// [arguments] holds `address` plus a `pin` or `qr` secret (see [connectQr]).
  /// Rethrows pairing failures; a Bluetooth remote failure only sets [error].
  Future<void> connect(Map<String, dynamic> arguments) async {
    reconnecting = true;
    error = null;
    notifyListeners();
    try {
      await channel.invokeMethod<void>('connect', arguments);
      await refreshConnection();
      connected = true;
      saved = true;
      _ensurePoller();
    } catch (e) {
      connected = false;
      error = userMessage(e);
      rethrow;
    } finally {
      reconnecting = false;
      notifyListeners();
    }
    await command('state');
    try {
      await channel.invokeMethod<void>('enableBluetoothRemote');
    } catch (e) {
      error = userMessage(e);
      notifyListeners();
    }
  }

  /// Dispatches touch controls; releases bypass queued commands to avoid stuck held keys.
  ///
  /// Sends `{"action": action, ...values}` as JSON over the `control` method;
  /// errors are shown via [error] rather than thrown.
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
      error = userMessage(e);
      notifyListeners();
    }
  }

  /// Retries saved credentials with a bounded retry interval and no automatic command replay.
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
      error = userMessage(e);
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

  /// Serializes request/reply traffic and publishes current playback state or a recoverable error.
  ///
  /// The request is `{"action": action, ...values}` as JSON; the reply is a
  /// JSON map, with an `error` key on failure. Completes with the reply.
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
        if (action == 'state') {
          keyboardSupported = response['keyboardVersion'] == 1;
          keyboard.value = keyboardSupported
              ? _keyboardSnapshot(response['keyboard'])
              : null;
        } else if (action.startsWith('keyboard') &&
            response.containsKey('keyboard')) {
          keyboard.value = _keyboardSnapshot(response['keyboard']);
        }
        // A user command that succeeds clears the last command failure.
        if (action != 'state' && error != null) {
          error = null;
          notifyListeners();
        }
        result.complete(response);
      } catch (e) {
        if (e is PlatformException) {
          await refreshConnection();
          _retryAfter = DateTime.now().add(const Duration(seconds: 2));
        }
        // A failed background status probe is not a failed user button press.
        if (action != 'state')
          error = userMessage(e);
        else {
          playback.value = {};
          state = {};
          _clearKeyboard();
        }
        notifyListeners();
        result.completeError(e);
      } finally {
        _working = false;
      }
    });
    return result.future;
  }

  /// Sends a phone keyboard action; returns `{}` instead of throwing, and
  /// sends nothing to a TV that never advertised keyboard support.
  Future<Map<String, dynamic>> keyboardCommand(
    String action, [
    Map<String, dynamic> values = const {},
  ]) async {
    if (!keyboardSupported) return {};
    try {
      return await command(action, values);
    } catch (_) {
      return {};
    }
  }

  /// Restarts the command queue in the caller's zone (widget tests use fake
  /// async; a queue created elsewhere would never drain there).
  @visibleForTesting
  void resetCommandQueue() => _tail = Future.value();

  /// Copies the TV's `keyboard` reply field into a typed map, or null.
  static Map<String, dynamic>? _keyboardSnapshot(Object? raw) =>
      raw is Map ? Map<String, dynamic>.from(raw) : null;

  /// Forgets keyboard support and hides the phone keyboard prompt.
  void _clearKeyboard() {
    keyboardSupported = false;
    keyboard.value = null;
  }

  /// Persists whether normal phone browsing should launch playback on the connected TV.
  Future<void> setRemoteMode(bool enabled) async {
    remoteMode = enabled;
    await channel.invokeMethod<void>('remoteMode', enabled);
    notifyListeners();
    if (connected)
      await command('browseStatus', {
        'title': enabled ? 'Browsing on phone' : '',
      });
  }

  /// Stops reconnection and optionally removes the saved receiver credentials.
  Future<void> disconnect({bool forget = false}) async {
    await channel.invokeMethod<void>(forget ? 'forget' : 'disconnect');
    connected = false;
    saved = false;
    remoteMode = false;
    error = null;
    _clearKeyboard();
    await channel.invokeMethod<void>('remoteMode', false);
    notifyListeners();
  }

  /// Validates the companion QR scheme and required fields before connecting.
  ///
  /// Expects `zangetsu-remote://remote?v=1&address=IP:PORT` with a 6-digit
  /// `pin` or a 64-hex `qr` secret; throws [StateError] with a user message.
  Future<void> connectQr(String raw) async {
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.scheme != 'zangetsu-remote' ||
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

  /// Extracts a user-facing platform failure without exposing a stack trace.
  static String userMessage(Object e) =>
      (e is PlatformException
              ? e.message ?? 'Lost connection to the TV.'
              : e is StateError
              ? e.message
              : e.toString())
          .replaceFirst('Bad state: ', '');

  /// Cancels polling and preference/lifecycle listeners owned by this session.
  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    playback.dispose();
    keyboard.dispose();
    super.dispose();
  }
}
