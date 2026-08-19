import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'discord_config.dart';
import 'discord_presence.dart';

/// Minimal Discord Gateway (v10) client for setting a user's Rich Presence.
/// Connects, IDENTIFYs with the user token, heartbeats, and pushes presence
/// (op 3). Auto-reconnects on drop / zombie connection. This is a "self
/// presence" client — it does not read events beyond what's needed.
class DiscordGateway {
  DiscordGateway(this._token);
  final String _token;

  WebSocketChannel? _ch;
  StreamSubscription<dynamic>? _sub;
  Timer? _heartbeat;
  int? _seq;
  bool _acked = true;
  bool _ready = false;
  bool _closed = false;

  /// Latest presence to (re)apply once READY / after a reconnect. null = clear.
  DiscordActivity? _pending;

  void connect() {
    _closed = false;
    _open();
  }

  void _open() {
    _cleanupSocket();
    _ready = false;
    debugPrint('[discord] gateway opening ${DiscordConfig.gatewayUrl}');
    try {
      _ch = WebSocketChannel.connect(Uri.parse(DiscordConfig.gatewayUrl));
      _sub = _ch!.stream.listen(
        _onMessage,
        onDone: _onDone,
        onError: (e, st) {
          debugPrint('[discord] gateway socket error: $e');
          _onDone();
        },
        cancelOnError: true,
      );
    } catch (e) {
      debugPrint('[discord] gateway connect failed: $e');
      _scheduleReconnect();
    }
  }

  void _onMessage(dynamic raw) {
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[discord] gateway bad json: $e');
      return;
    }
    if (msg['s'] != null) _seq = (msg['s'] as num).toInt();
    switch (msg['op'] as int?) {
      case 10: // HELLO
        final interval =
            ((msg['d'] as Map)['heartbeat_interval'] as num).toInt();
        debugPrint('[discord] gateway HELLO heartbeat=${interval}ms — identifying');
        _startHeartbeat(interval);
        _identify();
      case 11: // heartbeat ACK
        _acked = true;
      case 1: // server requested a heartbeat
        _sendHeartbeat();
      case 7: // must reconnect
        debugPrint('[discord] gateway requested reconnect (op 7)');
        _reconnect();
      case 9: // invalid session
        debugPrint('[discord] gateway invalid session (op 9) — token/identify rejected');
        _reconnect();
      case 0: // dispatch
        final t = msg['t'] as String?;
        if (t == 'READY') {
          _ready = true;
          final user = (msg['d'] as Map?)?['user'] as Map?;
          final name = user?['username'] ?? user?['global_name'] ?? '?';
          debugPrint('[discord] gateway READY as $name — pushing presence');
          _sendPresence(_pending);
        }
    }
  }

  void _identify() {
    debugPrint('[discord] gateway IDENTIFY');
    _send({
      'op': 2,
      'd': {
        'token': _token,
        'capabilities': 0,
        'properties': {
          'os': 'Android',
          'browser': 'Discord Android',
          'device': DiscordConfig.appName,
        },
        'presence': {
          'status': 'online',
          'since': 0,
          'activities': [],
          'afk': false,
        },
        'compress': false,
      },
    });
  }

  /// Set (or clear, with null) the presence. Buffered until READY.
  void setPresence(DiscordActivity? activity) {
    _pending = activity;
    if (_ready) {
      _sendPresence(activity);
    } else {
      debugPrint(
        '[discord] presence queued until READY: ${activity == null ? "clear" : "type=${activity.type} ${activity.name}"}',
      );
    }
  }

  /// Push an empty activity list, wait for the frame to flush, then drop the
  /// socket. Closing without this leaves the last Rich Presence on the profile.
  Future<void> clearThenClose() async {
    if (_closed) return;
    setPresence(null);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await close();
  }

  void _sendPresence(DiscordActivity? a) {
    debugPrint(
      a == null
          ? '[discord] sending presence clear'
          : '[discord] sending presence type=${a.type} name="${a.name}" '
              'details=${a.details} start=${a.startMs} end=${a.endMs}',
    );
    _send({
      'op': 3,
      'd': discordPresenceUpdate(a, DiscordConfig.applicationId),
    });
  }

  void _startHeartbeat(int intervalMs) {
    _heartbeat?.cancel();
    _acked = true;
    _heartbeat = Timer.periodic(Duration(milliseconds: intervalMs), (_) {
      if (!_acked) {
        debugPrint('[discord] gateway heartbeat missed — reconnecting');
        _reconnect();
        return;
      }
      _sendHeartbeat();
    });
  }

  void _sendHeartbeat() {
    _acked = false;
    _send({'op': 1, 'd': _seq});
  }

  void _send(Map<String, dynamic> data) {
    try {
      _ch?.sink.add(jsonEncode(data));
    } catch (e) {
      debugPrint('[discord] gateway send failed: $e');
    }
  }

  void _onDone() {
    debugPrint('[discord] gateway socket closed ready=$_ready closed=$_closed');
    if (!_closed) _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _cleanupSocket();
    if (_closed) return;
    debugPrint('[discord] gateway reconnect in 5s');
    Future<void>.delayed(const Duration(seconds: 5), () {
      if (!_closed) _open();
    });
  }

  void _reconnect() {
    if (_closed) return;
    _open();
  }

  void _cleanupSocket() {
    _heartbeat?.cancel();
    _heartbeat = null;
    _sub?.cancel();
    _sub = null;
    try {
      _ch?.sink.close();
    } catch (_) {}
    _ch = null;
    _ready = false;
  }

  Future<void> close() async {
    _closed = true;
    _cleanupSocket();
    _pending = null;
  }
}
