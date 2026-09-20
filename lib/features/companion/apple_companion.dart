import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/platform/apple_tv.dart';
import '../../core/ui/global_messenger.dart';
import 'companion_wire.dart';

/// Apple uses the same Wi-Fi protocol as Android. Bluetooth HID/RFCOMM stays
/// in Android's platform bridge; it is not emulated with private Apple APIs.
class CompanionChannel extends MethodChannel {
  const CompanionChannel() : super('zangetsu/beta_companion');
  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    if (!Platform.isIOS) return super.invokeMethod<T>(method, arguments);
    return await AppleCompanion.instance.invoke(method, arguments) as T?;
  }
}

class AppleCompanion {
  AppleCompanion({bool Function()? receiverDevice})
    : _receiverDevice = receiverDevice ?? (() => isAppleTv);
  final bool Function() _receiverDevice;
  static final instance = AppleCompanion();
  static const native = MethodChannel('zangetsu/apple_companion');
  Future<Map<String, dynamic>> Function(Map<String, dynamic>)? catalogue;
  final Map<String, dynamic> _saved = {};
  Future<void>? _loading;
  CompanionWire? _client;
  ServerSocket? _server;
  final _peers = <CompanionWire>{};
  Timer? _repeat;
  int _hold = 0, _generation = 0, _attempts = 0;
  DateTime _attemptWindow = DateTime.now();
  bool _connecting = false;
  String? _playbackError;
  String _snapshotKey = '';
  DateTime _snapshotAt = DateTime(0);
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

  Future<void> _load() => _loading ??= () async {
    final raw = await native.invokeMethod<String>('readStore');
    if (raw != null)
      _saved.addAll(Map<String, dynamic>.from(jsonDecode(raw) as Map));
  }();
  Future<void> _persist() =>
      native.invokeMethod('writeStore', jsonEncode(_saved));
  Future<dynamic> invoke(String method, dynamic args) async {
    await _load();
    switch (method) {
      case 'connectionState':
        return {
          'connected': _client?.alive == true,
          'companion': _client?.alive == true,
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
        if (_saved['autoConnect'] == true && _client?.alive != true)
          await _connect({});
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
        return jsonEncode(
          await _exchange(
            Map<String, dynamic>.from(jsonDecode(args as String) as Map),
          ),
        );
      case 'control':
        return jsonEncode(
          await _control(
            Map<String, dynamic>.from(jsonDecode(args as String) as Map),
          ),
        );
      case 'enableBluetoothRemote':
        return null;
      case 'discover':
        return native.invokeMethod('discover');
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
      case 'receiverStream':
        return native.invokeMethod('stream');
      case 'receiverSkipPrefs':
        if (_receiverDevice())
          await native.invokeMethod('player', {
            'action': 'skipSettings',
            ...Map<String, dynamic>.from(args as Map),
          });
        return null;
      case 'playbackError':
        _playbackError = args as String?;
        return null;
      default:
        throw PlatformException(
          code: 'unsupported',
          message: 'This control is not available on Apple devices.',
        );
    }
  }

  Future<void> _connect(Map<String, dynamic> args) async {
    if (_connecting) return;
    _connecting = true;
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
      wire = CompanionWire(
        await Socket.connect(
          uri.host,
          uri.port,
          timeout: const Duration(seconds: 7),
        ),
      );
      final challenge = await wire.read(timeout: const Duration(seconds: 10));
      if (challenge['type'] != 'challenge' || challenge['version'] != 1)
        throw StateError('Unsupported TV receiver');
      final id = challenge['deviceId'] as String;
      final qr = args['qr'] as String? ?? '';
      final pin = args['pin'] as String? ?? '';
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
      wire.send({
        'clientId': _saved['clientId'],
        'mode': qr.isNotEmpty
            ? 'qr'
            : pin.isNotEmpty
            ? 'pin'
            : 'remembered',
        'proof': companionProof(secret, challenge['nonce'] as String),
      });
      final reply = await wire.read(timeout: const Duration(seconds: 10));
      if (reply['type'] != 'paired')
        throw StateError(reply['error'] as String? ?? 'Scan the TV again.');
      if (generation != _generation) throw StateError('Connection cancelled');
      _client?.close();
      _client = wire;
      _saved.addAll({
        'deviceId': id,
        'address': address,
        'name': reply['name'] ?? 'TV',
        'autoConnect': true,
      });
      if (reply['token'] != null) _saved['token'] = reply['token'];
      await _persist();
    } catch (e) {
      wire?.close();
      throw PlatformException(code: 'connection', message: e.toString());
    } finally {
      _connecting = false;
    }
  }

  Future<Map<String, dynamic>> _exchange(Map<String, dynamic> command) async {
    final client = _client;
    if (client == null || !client.alive)
      throw PlatformException(
        code: 'connection',
        message: 'Reconnect to your TV.',
      );
    try {
      final response = await client.exchange(command);
      if (response.containsKey('active')) await _snapshot(response);
      return response;
    } catch (e) {
      await _snapshot({});
      throw PlatformException(code: 'connection', message: e.toString());
    }
  }

  void _release() {
    _hold++;
    _repeat?.cancel();
    _repeat = null;
  }

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

  Future<void> _start() async {
    if (!_receiverDevice()) throw StateError('Receiver mode requires a TV.');
    if (_server != null) return;
    _saved['receiverId'] ??= companionSecret();
    _saved['qr'] ??= companionSecret();
    _saved['pin'] ??=
        (100000 +
                int.parse(companionSecret().substring(0, 6), radix: 16) %
                    900000)
            .toString();
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

  Future<void> _serve(Socket socket) async {
    if (_peers.length >= 4) {
      socket.destroy();
      return;
    }
    final peer = CompanionWire(socket);
    _peers.add(peer);
    try {
      final nonce = companionSecret();
      peer.send({
        'type': 'challenge',
        'version': 1,
        'deviceId': _saved['receiverId'],
        'nonce': nonce,
        'name': 'Apple TV',
      });
      final hello = await peer.read(timeout: const Duration(seconds: 10));
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
      if (secret is! String ||
          !companionProofMatches(
            companionProof(secret, nonce),
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
      };
      if (mode != 'remembered') {
        final token = companionSecret();
        if (clients.length >= 10 && !clients.containsKey(id))
          clients.remove(clients.keys.first);
        clients[id] = token;
        _saved['clients'] = clients;
        await _persist();
        reply['token'] = token;
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
          response = {'error': e.toString()};
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

  Future<Map<String, dynamic>> _dispatch(Map<String, dynamic> c) async {
    final action = c['action'];
    if (action == 'state')
      return {
        ...await native.invokeMapMethod<String, dynamic>('player', c) ?? {},
        'playbackError': _playbackError,
      };
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed)
      throw StateError('Open Zangetsu on Apple TV.');
    if (action == 'key') {
      final key = c['value'];
      final state = await native.invokeMapMethod<String, dynamic>('player', {
        'action': 'state',
      });
      if (state?['active'] == true) {
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
      'skipSettings',
      'catalogues',
      'search',
      'detail',
      'play',
      'handoffSnapshot',
      'handoffSources',
      'handoffValidate',
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
