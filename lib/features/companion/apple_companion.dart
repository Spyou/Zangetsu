import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/platform/apple_tv.dart';
import '../../core/tv/tv_keyboard_bridge.dart';
import '../../core/ui/global_messenger.dart';
import 'companion_wire.dart';

/// Method channel the remote UI talks to on every platform.
///
/// On Android calls go to the native Kotlin bridge as usual. On iOS they are
/// answered in Dart by [AppleCompanion], which speaks the same Wi-Fi protocol
/// as Android. Bluetooth HID/RFCOMM stays in Android's platform bridge; it is
/// not emulated with private Apple APIs.
class CompanionChannel extends MethodChannel {
  /// Creates the shared `zangetsu/companion` channel.
  const CompanionChannel() : super('zangetsu/companion');

  /// On iOS, routes the call to [AppleCompanion.invoke] instead of native code.
  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    if (!Platform.isIOS) return super.invokeMethod<T>(method, arguments);
    return await AppleCompanion.instance.invoke(method, arguments) as T?;
  }
}

/// Apple phone client and TV receiver sharing the Android-compatible authenticated protocol.
///
/// On an iPhone it pairs with and drives a TV over TCP ([CompanionWire]); on
/// Apple TV it hosts the receiver that phones connect to. Keychain storage,
/// Bonjour and the AVKit player are reached through the [native] channel.
class AppleCompanion {
  /// [receiverDevice] decides whether this device acts as the TV receiver;
  /// defaults to [isAppleTv] and is overridden in tests.
  AppleCompanion({bool Function()? receiverDevice})
    : _receiverDevice = receiverDevice ?? (() => isAppleTv);

  /// True when this device is the TV side (receiver) rather than the phone.
  final bool Function() _receiverDevice;

  /// App-wide instance used by [CompanionChannel].
  static final instance = AppleCompanion();

  /// Swift bridge for Keychain, Bonjour, QR scanning and the native player.
  static const native = MethodChannel('zangetsu/apple_companion');

  /// TV side: handles catalogue and keyboard requests in the Flutter app.
  /// Set by the app once its catalogue is ready; null until then.
  Future<Map<String, dynamic>> Function(Map<String, dynamic>)? catalogue;

  /// Replaces the LAN UDP probe in tests so they never touch the real network.
  @visibleForTesting
  Future<List<Map<String, String>>> Function()? udpDiscover;

  /// Pairing state mirrored from the Keychain (address, token, clients, PIN...).
  final Map<String, dynamic> _saved = {};

  /// The one in-flight or finished Keychain load; see [_load].
  Future<void>? _loading;

  /// Phone side: the authenticated link to the TV, if any.
  CompanionWire? _client;

  /// TV side: the listening socket while receiver mode is on.
  ServerSocket? _server;

  /// TV side: connected phones (at most four).
  final _peers = <CompanionWire>{};

  /// Repeats a held D-pad or volume press until it is released.
  Timer? _repeat;

  /// [_hold] invalidates a running repeat; [_generation] cancels an older
  /// connect; [_attempts] counts PIN tries in the current minute.
  int _hold = 0, _generation = 0, _attempts = 0;

  /// Start of the one-minute window that limits PIN attempts.
  DateTime _attemptWindow = DateTime.now();

  /// Connects in progress and slow commands currently holding the wire.
  int _connecting = 0, _slowCommands = 0;

  /// TV side: the last playback failure, reported to the phone in `state`.
  String? _playbackError;

  /// Commands that can take many seconds; presses are refused while one runs.
  // Catalogue requests can hold the wire for many seconds.
  static const _slowActions = {
    'catalogues',
    'search',
    'detail',
    'play',
    'browseStatus',
    'openFromPhone',
  };

  /// Last Live Activity snapshot sent and when, used to throttle [_snapshot].
  String _snapshotKey = '';
  DateTime _snapshotAt = DateTime(0);
  // One scan at a time: the background reconnect and Find TVs share it.
  Future<List<dynamic>?>? _discovering;
  // The TV drops a link idle for 95 s; iOS suspension hides that close.
  /// When the TV last answered; see [_dropIfIdle].
  DateTime _lastReply = DateTime(0);

  /// Idle time after which the link is assumed dropped (TV limit is 95 s).
  static const _idleLimit = Duration(seconds: 90);

  /// UDP port Android TVs answer discovery probes on.
  static const discoveryPort =
      41285; // must equal CompanionReceiver.discoveryPort

  /// Payload of the UDP discovery probe; the TV replies with JSON.
  static const _probe = 'ZANGETSU_DISCOVER_V1';

  /// Throttles optional Live Activity snapshots; media UI failure must not interrupt control.
  Future<void> _snapshot(Map<String, dynamic> state) async {
    if (_receiverDevice()) return;
    final key = jsonEncode([
      state['active'],
      state['playerForeground'],
      state['title'],
      state['episodeLabel'],
      state['playing'],
    ]);
    if (key == _snapshotKey &&
        DateTime.now().difference(_snapshotAt).inSeconds < 60)
      return;
    _snapshotKey = key;
    _snapshotAt = DateTime.now();
    try {
      await native.invokeMethod<void>('remoteSnapshot', state);
    } catch (_) {
      /* Optional OS surface. */
    }
  }

  /// Loads saved receiver/client credentials once from the native Keychain bridge.
  /// A native error (e.g. a locked Keychain) is not cached, so the next
  /// invoke retries and a valid pairing is never overwritten as empty.
  Future<void> _load() => _loading ??= () async {
    String? raw;
    try {
      raw = await native.invokeMethod<String>('readStore');
    } catch (_) {
      _loading = null;
      rethrow;
    }
    if (raw == null) return;
    try {
      _saved.addAll(Map<String, dynamic>.from(jsonDecode(raw) as Map));
    } catch (_) {
      /* Corrupt entry: start empty; the next _persist overwrites it. */
    }
  }();

  /// Closes a link the TV has most likely dropped while the phone slept.
  void _dropIfIdle() {
    // A slow command (up to 90 s) may hold the wire without a reply; keep it.
    if (_client?.alive == true &&
        _slowCommands == 0 &&
        DateTime.now().difference(_lastReply) > _idleLimit) {
      _client!.close();
      _client = null;
    }
  }

  /// Stores the current pairing state in Keychain rather than application preferences.
  Future<void> _persist() =>
      native.invokeMethod('writeStore', jsonEncode(_saved));

  /// Implements the shared channel contract and rejects unsupported platform operations.
  ///
  /// [method] is a channel method name (`connect`, `command`, `discover`,
  /// `receiverStart`...); `command` and `control` take and return JSON strings.
  /// Throws [PlatformException] with code `unsupported` for unknown methods.
  Future<dynamic> invoke(String method, dynamic args) async {
    await _load();
    switch (method) {
      case 'connectionState':
        _dropIfIdle();
        // A silent reconnect after one failed command still counts as
        // connected, so a refresh in that window does not drop the session.
        return {
          'connected': _client?.alive == true || _recovering > 0,
          'companion': _client?.alive == true || _recovering > 0,
          'wifi': _client?.alive == true,
          'hid': false,
          'bluetoothCompanion': false,
          'saved': _saved['autoConnect'] == true,
          'name': _saved['name'] ?? 'Your TV',
          'transport': 'Wi-Fi',
          'remoteMode': _saved['remoteMode'] == true,
        };
      case 'lastAddress':
        return _saved['address'];
      case 'connect':
        await _connect(Map<String, dynamic>.from(args as Map));
        return null;
      case 'reconnect':
        // A silent reconnect is already running; it finishes the job.
        if (_recovering > 0) return null;
        _dropIfIdle();
        if (_saved['autoConnect'] == true && _client?.alive != true)
          await _connect({}, background: true);
        return null;
      case 'remoteMode':
        _saved['remoteMode'] = args == true;
        await _persist();
        return null;
      case 'remoteScreen':
        if (args != true) _release();
        return null;
      case 'disconnect':
      case 'forget':
        _generation++;
        _release();
        _client?.close();
        _client = null;
        await _snapshot({});
        _saved['autoConnect'] = false;
        if (method == 'forget') {
          for (final key in ['address', 'token', 'deviceId', 'name']) {
            _saved.remove(key);
          }
        }
        await _persist();
        return null;
      case 'command':
        final command = Map<String, dynamic>.from(
          jsonDecode(args as String) as Map,
        );
        final slow = _slowActions.contains(command['action']);
        if (slow) _slowCommands++;
        try {
          return jsonEncode(await _exchange(command));
        } finally {
          if (slow) _slowCommands--;
        }
      case 'control':
        return jsonEncode(
          await _control(
            Map<String, dynamic>.from(jsonDecode(args as String) as Map),
          ),
        );
      case 'enableBluetoothRemote':
        return null;
      case 'discover':
        final found = await (_discovering ??= _discoverAll().whenComplete(
          () => _discovering = null,
        ));
        // Follow a saved TV to its new address, as Android does.
        final id = _saved['deviceId'];
        for (final tv in found ?? const []) {
          final address = tv is Map ? tv['address'] : null;
          if (id is String &&
              id.isNotEmpty &&
              tv is Map &&
              tv['deviceId'] == id &&
              address is String &&
              address.isNotEmpty &&
              address != _saved['address']) {
            _saved['address'] = address;
            await _persist();
            break;
          }
        }
        return found;
      case 'scanPairing':
        return native.invokeMethod('scanPairing');
      case 'restoreReceiver':
        if (_receiverDevice() && _saved['receiverEnabled'] == true)
          await _start();
        return null;
      case 'receiverStart':
        await _start();
        return _receiverState();
      case 'receiverState':
        return _receiverState();
      case 'receiverStop':
      case 'receiverForget':
        for (final peer in _peers.toList()) {
          peer.close();
        }
        if (method == 'receiverForget') {
          _saved['clients'] = <String, dynamic>{};
          _saved['qr'] = companionSecret();
        } else {
          await _server?.close();
          _server = null;
          _saved['receiverEnabled'] = false;
          await native.invokeMethod('unpublish');
        }
        await _persist();
        return _receiverState();
      case 'playbackError':
        _playbackError = args as String?;
        return null;
      case 'receiverClosePlayer':
        if (_receiverDevice()) {
          try {
            await native.invokeMethod('player', {'action': 'closePlayer'});
          } catch (_) {
            /* No player open. */
          }
        }
        return null;
      default:
        throw PlatformException(
          code: 'unsupported',
          message: 'This control is not available on Apple devices.',
        );
    }
  }

  /// Authenticates QR/PIN or remembered credentials before replacing the current client link.
  Future<void> _connect(
    Map<String, dynamic> args, {
    bool background = false,
  }) async {
    final qr = args['qr'] as String? ?? '';
    final pin = args['pin'] as String? ?? '';
    // Same checks as Android, before the TV is contacted. A bad typed code
    // must not cancel a background reconnect that is still running.
    if (pin.isNotEmpty && !RegExp(r'^\d{6}$').hasMatch(pin))
      throw PlatformException(
        code: 'connection',
        message: 'Enter the TV code or scan its QR.',
      );
    if (qr.isNotEmpty && !RegExp(r'^[a-f0-9]{64}$').hasMatch(qr))
      throw PlatformException(code: 'connection', message: 'Invalid QR code.');
    final explicit = [
      'qr',
      'pin',
      'address',
    ].any((k) => (args[k] as String? ?? '').isNotEmpty);
    // Scanned or typed credentials replace an in-flight reconnect.
    if (_connecting > 0 && !explicit) {
      if (background) return;
      throw PlatformException(
        code: 'busy',
        message: 'Still reconnecting, try again.',
      );
    }
    _connecting++;
    final generation = ++_generation;
    CompanionWire? wire;
    try {
      final address = (args['address'] ?? _saved['address']) as String? ?? '';
      final uri = Uri.tryParse('tcp://$address');
      if (uri == null ||
          uri.host.isEmpty ||
          !uri.hasPort ||
          uri.port < 1 ||
          uri.port > 65535)
        throw StateError('Enter the TV address shown in settings.');
      wire = CompanionWire(await _open(uri.host, uri.port));
      final challenge = await wire.read(timeout: const Duration(seconds: 10));
      if (challenge['type'] != 'challenge')
        throw StateError('Unsupported TV receiver');
      if (challenge['version'] != companionPairingVersion)
        throw StateError(companionOldTvError);
      final id = challenge['deviceId'] as String;
      final remembered = qr.isEmpty && pin.isEmpty;
      if (remembered && id != _saved['deviceId'])
        throw StateError('This is a different TV. Scan it first.');
      final secret = qr.isNotEmpty
          ? qr
          : pin.isNotEmpty
          ? pin
          : _saved['token'] as String? ?? '';
      if (secret.isEmpty) throw StateError('Scan this TV once to connect.');
      _saved['clientId'] ??= companionSecret();
      final nonce = challenge['nonce'];
      final tvKey = challenge['key'];
      if (nonce is! String ||
          !companionNoncePattern.hasMatch(nonce) ||
          tvKey is! String ||
          !CompanionKey.pattern.hasMatch(tvKey))
        throw StateError('Unsupported TV receiver');
      final clientId = _saved['clientId'] as String;
      final mode = qr.isNotEmpty
          ? 'qr'
          : pin.isNotEmpty
          ? 'pin'
          : 'remembered';
      // Both sides derive the remembered token by ECDH, so it is never sent
      // in the clear. Both public keys go into the proofs, so a key swapped
      // by someone on the network makes both proofs fail.
      final pairingKey = remembered ? null : CompanionKey.generate();
      final clientKey = pairingKey?.publicHex ?? '';
      String proofFor(String label) => companionPairingProof(
        secret,
        label: label,
        mode: mode,
        nonce: nonce,
        tvKey: tvKey,
        clientKey: clientKey,
        clientId: clientId,
      );
      wire.send({
        'version': companionPairingVersion,
        'clientId': clientId,
        'mode': mode,
        'proof': proofFor('phone'),
        if (pairingKey != null) 'key': clientKey,
      });
      final reply = await wire.read(timeout: const Duration(seconds: 10));
      if (reply['type'] != 'paired')
        throw StateError(reply['error'] as String? ?? 'Scan the TV again.');
      // The TV proves it holds the same secret and saw the same keys before
      // anything it sent is trusted.
      final tvProof = reply['proof'];
      if (tvProof is! String ||
          !companionProofMatches(proofFor('tv'), tvProof) ||
          reply.containsKey('token'))
        throw StateError('The TV could not prove its identity. Scan it again.');
      if (generation != _generation) throw StateError('Connection cancelled');
      if (pairingKey != null)
        reply['token'] = companionPairingToken(
          pairingKey.shared(tvKey),
          nonce,
          clientId,
        );
      _client?.close();
      _client = wire;
      _lastReply = DateTime.now();
      _saved.addAll({
        'deviceId': id,
        'address': address,
        'name': reply['name'] ?? 'TV',
        'autoConnect': true,
      });
      if (reply['token'] != null) _saved['token'] = reply['token'];
      try {
        await _persist();
      } catch (_) {
        /* Link is authenticated; only the restart memory is lost. */
      }
    } catch (e) {
      // Never close a wire the TV has already paired.
      if (!identical(wire, _client)) wire?.close();
      throw PlatformException(code: 'connection', message: _text(e));
    } finally {
      _connecting--;
    }
  }

  /// Opens the TCP link; retries once while the Local Network prompt shows.
  Future<Socket> _open(String host, int port) async {
    try {
      return await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 7),
      );
    } on SocketException catch (e) {
      final code = e.osError?.errorCode;
      if (code != 65 && code != 64) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      return Socket.connect(host, port, timeout: const Duration(seconds: 7));
    }
  }

  /// Bonjour plus Android's UDP probe; Bonjour entries come first.
  Future<List<dynamic>> _discoverAll() async {
    Object? nativeError;
    final results = await Future.wait<List<dynamic>>([
      native
          .invokeMethod<List<dynamic>>('discover')
          .then((v) => v ?? const <dynamic>[])
          .catchError((Object e) {
            nativeError = e;
            return const <dynamic>[];
          }),
      // try/catch, not catchError: a probe future typed Future<Never> would
      // turn catchError's fallback list into an ArgumentError.
      () async {
        try {
          return await (udpDiscover ?? _udpDiscover)();
        } catch (_) {
          return const <Map<String, String>>[];
        }
      }(),
    ]);
    final merged = <dynamic>[];
    final seen = <String>{};
    for (final tv in results.expand((r) => r)) {
      final address = tv is Map ? tv['address'] : null;
      if (address is String && !seen.add(address)) continue;
      merged.add(tv);
    }
    if (merged.isEmpty && nativeError != null) throw nativeError!;
    return merged;
  }

  /// Unicast ZANGETSU_DISCOVER_V1 to each local /24; broadcast would need
  /// the multicast entitlement.
  Future<List<Map<String, String>>> _udpDiscover() async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final found = <String, Map<String, String>>{};
    try {
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = socket.receive();
        if (dg == null) return;
        try {
          final data = jsonDecode(utf8.decode(dg.data));
          if (data is! Map || data['service'] != 'zangetsu-remote') return;
          final port = data['port'];
          if (port is! int || port < 1 || port > 65535) return;
          final address = '${dg.address.address}:$port';
          found[address] ??= {
            'name': (data['name'] ?? 'TV').toString(),
            'address': address,
            'deviceId': (data['deviceId'] ?? '').toString(),
          };
        } catch (_) {
          /* Not a receiver reply. */
        }
      });
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final own = <String>{};
      final prefixes = <String>{};
      // Wi-Fi/hotspot only: never probe cellular (pdp_ip) or VPN tunnels.
      const skip = ['pdp_ip', 'utun', 'ipsec', 'ppp', 'llw', 'awdl'];
      final local = interfaces
          .where((i) => !skip.any(i.name.startsWith))
          .expand((i) => i.addresses);
      for (final a in local) {
        if (a.address.startsWith('169.254.')) continue;
        own.add(a.address);
        final parts = a.address.split('.');
        if (parts.length == 4 && prefixes.length < 4)
          prefixes.add(parts.take(3).join('.'));
      }
      final probe = utf8.encode(_probe);
      for (final prefix in prefixes) {
        for (var host = 1; host <= 254; host++) {
          final ip = '$prefix.$host';
          if (own.contains(ip)) continue;
          try {
            // send() returns 0 when the socket buffer is full; let it drain.
            if (socket.send(probe, InternetAddress(ip), discoveryPort) == 0) {
              await Future<void>.delayed(const Duration(milliseconds: 20));
              socket.send(probe, InternetAddress(ip), discoveryPort);
            }
          } catch (_) {
            /* One unreachable host must not stop the scan. */
          }
        }
      }
      await Future<void>.delayed(const Duration(seconds: 3));
    } finally {
      socket.close();
    }
    return found.values.toList();
  }

  /// Sends on the current authenticated link. When the link fails it is
  /// dropped for good, the saved TV is quietly reconnected (see [_revive]),
  /// and a read-only command ([companionRetryableActions]) is sent once more.
  /// Other commands are never sent twice: they fail with a "try again" error
  /// while the session stays connected. Only a failed reconnect clears the
  /// activity state and reports the link as lost. [retried] marks the retry:
  /// a retry that fails too skips the reconnect and reports the link as lost,
  /// the same as Android's sendCompanion. A command that arrives while that
  /// reconnect runs was never sent, so it waits for it and is sent once.
  Future<Map<String, dynamic>> _exchange(
    Map<String, dynamic> command, {
    bool retried = false,
  }) async {
    var client = _client;
    if ((client == null || !client.alive) && _recovering > 0 && !retried) {
      if (await _revive(_generation)) return _exchange(command, retried: true);
      client = _client;
    }
    if (client == null || !client.alive)
      throw PlatformException(
        code: 'connection',
        message: 'Reconnect to your TV.',
      );
    final generation = _generation;
    try {
      final response = await client.exchange(command);
      _lastReply = DateTime.now();
      if (response.containsKey('active')) await _snapshot(response);
      return response;
    } catch (e) {
      // The wire closed itself; it is never reused mid-frame.
      client.close();
      if (identical(_client, client)) _client = null;
      bool revived = false;
      if (!retried) {
        _recovering++;
        try {
          revived = await _revive(generation);
        } finally {
          _recovering--;
        }
      }
      if (revived) {
        if (companionRetryableActions.contains(command['action']))
          return _exchange(command, retried: true);
        throw PlatformException(
          code: 'connection',
          message: 'The TV did not confirm that. Try again.',
        );
      }
      await _snapshot({});
      throw PlatformException(code: 'connection', message: _text(e));
    }
  }

  /// The one silent reconnect running after a failed exchange, shared by
  /// every command that failed with it.
  Future<void>? _reviving;

  /// Commands currently waiting on a silent reconnect after a failed
  /// exchange; while above zero the session still reports as connected.
  int _recovering = 0;

  /// Reopens the saved TV link with the remembered token, as the background
  /// reconnect does. Returns true when a link is up again. Skipped when the
  /// user disconnected, or connected elsewhere, since [generation] was read;
  /// a command that failed with an earlier one waits for that reconnect.
  /// When another reconnect is already running (an app resume, say), it
  /// waits up to 12 s for that one instead, like Android's awaitLink.
  Future<bool> _revive(int generation) async {
    if (_reviving == null && _connecting > 0) {
      final deadline = DateTime.now().add(const Duration(seconds: 12));
      while (_connecting > 0 && DateTime.now().isBefore(deadline))
        await Future<void>.delayed(const Duration(milliseconds: 250));
      return _client?.alive == true;
    }
    if (_reviving == null &&
        (_saved['autoConnect'] != true || generation != _generation))
      return _client?.alive == true;
    try {
      await (_reviving ??= _connect(
        {},
        background: true,
      ).whenComplete(() => _reviving = null));
    } catch (_) {
      return false;
    }
    return _client?.alive == true;
  }

  /// Cancels deliberate-hold repetition without sending a second navigation event.
  void _release() {
    _hold++;
    _repeat?.cancel();
    _repeat = null;
  }

  /// Maps remote input to app-scoped commands; Apple does not emulate system HID keys.
  Future<Map<String, dynamic>> _control(Map<String, dynamic> c) async {
    final action = c['action'];
    if (action == 'release') {
      _release();
      return {};
    }
    final key = action == 'key' ? c['value'] : action;
    final request = switch (key) {
      'up' ||
      'down' ||
      'left' ||
      'right' ||
      'ok' ||
      'back' => {'action': 'key', 'value': key},
      'volumeUp' || 'volumeDown' => {
        'action': 'systemVolume',
        'direction': key == 'volumeUp' ? 1 : -1,
      },
      'mute' => {'action': 'systemMute'},
      'toggle' ||
      'rewind' ||
      'forward' ||
      'previous' ||
      'next' => {'action': key},
      _ => throw StateError(
        'Use the TV remote for system Home and Power on this connection.',
      ),
    };
    _release();
    // Presses must not queue behind a catalogue request and fire late.
    if (_slowCommands > 0)
      throw PlatformException(code: 'busy', message: 'TV is busy, try again');
    final hold = _hold;
    final result = await _exchange(request);
    if (c['phase'] == 'press' &&
        hold == _hold &&
        [
          'up',
          'down',
          'left',
          'right',
          'volumeUp',
          'volumeDown',
        ].contains(key)) {
      void repeat() {
        _repeat = Timer(const Duration(milliseconds: 130), () async {
          if (hold != _hold) return;
          try {
            await _exchange(request);
            if (hold == _hold) repeat();
          } catch (_) {
            _release();
          }
        });
      }

      _repeat = Timer(const Duration(milliseconds: 450), () {
        if (hold == _hold) repeat();
      });
    }
    return result;
  }

  /// A fresh 6-digit pairing PIN.
  static String _newPin() =>
      (100000 +
              int.parse(companionSecret().substring(0, 6), radix: 16) % 900000)
          .toString();

  /// Turns a failure into a plain sentence for the phone.
  static String _text(Object e) => e is StateError
      ? e.message
      : e is TimeoutException
      ? 'The TV did not answer in time.'
      : e is PlatformException
      ? e.message ?? 'Lost connection to the TV.'
      : e is SocketException
      ? _socketText(e)
      : e.toString();

  /// Plain-language socket failures, including iOS Local Network denial.
  static String _socketText(SocketException e) {
    final code = e.osError?.errorCode;
    if (code == 65 || code == 64)
      return 'Allow Local Network for Zangetsu in iPhone Settings > Privacy & Security > Local Network, then try again.';
    if (code == 61)
      return 'TV remote is off on the TV. Turn it on in the TV\'s Zangetsu settings.';
    if (code == 60 || e.message.toLowerCase().contains('timed out'))
      return 'The TV did not answer. Check both are on the same Wi-Fi and TV remote is on.';
    return 'Cannot reach the TV. Check both are on the same Wi-Fi.';
  }

  /// Binds the opted-in TV receiver and advertises it through the native Bonjour bridge.
  Future<void> _start() async {
    if (!_receiverDevice()) throw StateError('Receiver mode requires a TV.');
    if (_server != null) return;
    _saved['receiverId'] ??= companionSecret();
    _saved['qr'] ??= companionSecret();
    _saved['pin'] ??= _newPin();
    try {
      _server = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        (_saved['port'] as int?) ?? 0,
      );
    } on SocketException {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    }
    _saved['port'] = _server!.port;
    _saved['receiverEnabled'] = true;
    await _persist();
    _server!.listen((socket) {
      unawaited(_serve(socket));
    });
    await native.invokeMethod('publish', {
      'port': _server!.port,
      'deviceId': _saved['receiverId'],
    });
  }

  /// Builds TV pairing metadata from the active listener and persisted credentials.
  Future<Map<String, dynamic>> _receiverState() async {
    final addresses = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    return {
      'hosting': _server != null,
      'qr': _saved['qr'] ?? '',
      'pin': _saved['pin'] ?? '',
      'address': addresses
          .expand((i) => i.addresses)
          .where((a) => !a.isLoopback)
          .map((a) => '${a.address}:${_server?.port ?? 0}')
          .join('\n'),
    };
  }

  /// Authenticates one bounded client connection before accepting ordered allowlisted requests.
  Future<void> _serve(Socket socket) async {
    if (_peers.length >= 4) {
      socket.destroy();
      return;
    }
    final peer = CompanionWire(socket);
    _peers.add(peer);
    try {
      final nonce = companionSecret();
      final pairingKey = CompanionKey.generate();
      peer.send({
        'type': 'challenge',
        'version': companionPairingVersion,
        'deviceId': _saved['receiverId'],
        'nonce': nonce,
        'name': 'Apple TV',
        'key': pairingKey.publicHex,
      });
      final hello = await peer.read(timeout: const Duration(seconds: 10));
      if (hello['version'] != companionPairingVersion) {
        // A version-1 phone proves only the nonce, which does not cover the keys.
        peer.send({'error': companionOldPhoneError});
        await peer.socket.flush();
        return;
      }
      final id = hello['clientId'] as String? ?? '';
      if (!RegExp(r'^[a-zA-Z0-9-]{16,64}$').hasMatch(id))
        throw StateError('Invalid client');
      final clients = Map<String, dynamic>.from(
        _saved['clients'] as Map? ?? {},
      );
      final mode = hello['mode'];
      if (DateTime.now().difference(_attemptWindow).inMinutes >= 1) {
        _attempts = 0;
        _attemptWindow = DateTime.now();
      }
      final secret = mode == 'qr'
          ? _saved['qr']
          : mode == 'pin' && ++_attempts <= 10
          ? _saved['pin']
          : mode == 'remembered'
          ? clients[id]
          : null;
      // QR and PIN pairing need the phone's ECDH key; a reconnect sends none.
      final sentKey = hello['key'];
      final clientKey = mode == 'remembered'
          ? ''
          : sentKey is String && CompanionKey.pattern.hasMatch(sentKey)
          ? sentKey
          : null;
      String proofFor(String label) => companionPairingProof(
        secret as String,
        label: label,
        mode: mode as String,
        nonce: nonce,
        tvKey: pairingKey.publicHex,
        clientKey: clientKey!,
        clientId: id,
      );
      if (secret is! String ||
          clientKey == null ||
          !companionProofMatches(
            proofFor('phone'),
            hello['proof'] as String? ?? '',
          )) {
        peer.send({'error': 'Scan the TV QR to connect.'});
        await peer.socket.flush();
        return;
      }
      final reply = <String, dynamic>{
        'type': 'paired',
        'deviceId': _saved['receiverId'],
        'name': 'Apple TV',
        // Mutual proof: the phone checks it before trusting this TV.
        'proof': proofFor('tv'),
      };
      if (mode != 'remembered') {
        // Both sides derive the token by ECDH, so it never crosses the wire.
        final token = companionPairingToken(
          pairingKey.shared(clientKey),
          nonce,
          id,
        );
        if (clients.length >= 10 && !clients.containsKey(id))
          clients.remove(clients.keys.first);
        clients[id] = token;
        _saved['clients'] = clients;
        // A 6-digit PIN can be brute-forced from an observed proof, so retire it.
        if (mode == 'pin') {
          _saved['pin'] = _newPin();
          _attempts = 0;
        }
        await _persist();
      }
      peer.send(reply);
      var previousId = 0;
      while (peer.alive) {
        final command = await peer.read();
        final sequence = command['id'];
        if (sequence is! int || sequence <= previousId)
          throw StateError('Invalid command sequence');
        previousId = sequence;
        Map<String, dynamic> response;
        try {
          response = await _dispatch(
            command,
          ).timeout(const Duration(seconds: 80));
        } catch (e) {
          response = {'error': _text(e)};
        }
        peer.send({...response, 'id': sequence});
      }
    } catch (_) {
      /* Disconnection and malformed frames close this client only. */
    } finally {
      peer.close();
      _peers.remove(peer);
    }
  }

  /// True while the Flutter app is in the foreground.
  bool get _resumed =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  /// The phone keyboard only needs the app on screen. The tvOS system keyboard
  /// can leave Flutter 'inactive' while a text box is being edited, so only a
  /// hidden/paused app hides the text box.
  bool get _keyboardReachable {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null ||
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
  }

  /// Checks foreground capabilities before routing catalogue, focus or native player actions.
  Future<Map<String, dynamic>> _dispatch(Map<String, dynamic> c) async {
    final action = c['action'];
    // A new play replaces any earlier failure, as on Android.
    if (action == 'play' || action == 'openFromPhone') _playbackError = null;
    if (action == 'state') {
      final player =
          await native.invokeMapMethod<String, dynamic>('player', c) ?? {};
      return {
        ...player,
        'playbackError': _playbackError,
        // Phone keyboard v1; no text box behind the player or in background.
        'keyboardVersion': 1,
        'keyboard': player['active'] == true || !_keyboardReachable
            ? null
            : TvKeyboardBridge.instance.snapshot(),
      };
    }
    // The AVKit modal pauses Flutter's lifecycle, so skip the guard while it plays.
    final playerActive =
        (await native.invokeMapMethod<String, dynamic>('player', {
          'action': 'state',
        }))?['active'] ==
        true;
    // Unavailable keyboard targets are a normal ok:false reply, never an error banner.
    if (TvKeyboardBridge.actions.contains(action)) {
      if (catalogue == null) throw StateError('Catalogue is not ready');
      if (playerActive || !_keyboardReachable) {
        return {'ok': false, 'keyboard': null};
      }
      return catalogue!(c);
    }
    if (!playerActive && !_resumed)
      throw StateError('Open Zangetsu on Apple TV.');
    if (action == 'key') {
      final key = c['value'];
      if (playerActive) {
        if (key == 'back')
          return await native.invokeMapMethod<String, dynamic>('player', {
                'action': 'closePlayer',
              }) ??
              {};
        throw StateError('Use the playback controls while a video is open.');
      }
      final direction = {
        'up': TraversalDirection.up,
        'down': TraversalDirection.down,
        'left': TraversalDirection.left,
        'right': TraversalDirection.right,
      }[key];
      if (direction != null) {
        FocusManager.instance.primaryFocus?.focusInDirection(direction);
      } else if (key == 'back') {
        await rootNavigatorKey.currentState?.maybePop();
      } else if (key == 'ok') {
        final context = FocusManager.instance.primaryFocus?.context;
        if (context != null)
          Actions.maybeInvoke(context, const ActivateIntent());
      } else {
        throw StateError('Unsupported navigation button');
      }
      return {'ok': true};
    }
    if ([
      'catalogues',
      'search',
      'detail',
      'play',
      'browseStatus',
      'openFromPhone',
    ].contains(action)) {
      if (catalogue == null) throw StateError('Catalogue is not ready');
      return catalogue!(c);
    }
    const playerActions = [
      'toggle',
      'playing',
      'rewind',
      'forward',
      'seek',
      'next',
      'previous',
      'episode',
      'source',
      'track',
      'skipIntro',
      'megaSkip',
      'systemVolume',
      'systemMute',
      'closePlayer',
      'handoffResume',
    ];
    if (!playerActions.contains(action))
      throw StateError('Unsupported command');
    return await native.invokeMapMethod<String, dynamic>('player', c) ?? {};
  }
}
