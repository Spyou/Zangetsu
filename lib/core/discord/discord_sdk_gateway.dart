import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../platform/apple_tv.dart';
import 'discord_config.dart';
import 'discord_gateway.dart';
import 'discord_presence.dart';

bool get supportsNativeDiscordPresence =>
    !kIsWeb &&
    !isAppleTv &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// Phone activity transport; the SDK owns authentication and reconnection.
class DiscordSdkGateway extends DiscordGateway {
  DiscordSdkGateway(String token, {super.onAuthFailure})
    : _token = token,
      super('');

  static DiscordSdkGateway? _owner;
  static const _channel = MethodChannel('zangetsu/discord_presence');
  String _token;
  bool _started = false;
  bool _closed = false;
  bool _hasPending = false;
  DiscordActivity? _activity;
  String _status = 'online';

  @override
  void connect() {
    _closed = false;
    _owner = this;
    _channel.setMethodCallHandler((call) async {
      if (_closed) return;
      if (call.method == 'authFailed') {
        await onAuthFailure?.call();
      } else {
        debugPrint('[discord] SDK ${call.method}: ${call.arguments}');
      }
    });
    unawaited(_start());
  }

  Future<void> _start() async {
    _started = false;
    final started = await _invoke('start', {
      'applicationId': DiscordConfig.applicationId,
      'token': _token,
    });
    if (_closed || !started || !identical(_owner, this)) return;
    _started = true;
    if (_hasPending) _send();
  }

  Future<bool> _invoke(String method, [Object? arguments]) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
      return true;
    } on PlatformException catch (e) {
      debugPrint('[discord] SDK $method failed: ${e.code}');
    } on MissingPluginException {
      debugPrint('[discord] SDK unavailable on this build');
    }
    return false;
  }

  @override
  void updateToken(String token) {
    if (_closed) return;
    _token = token.startsWith('Bearer ') ? token.substring(7) : token;
    unawaited(_start());
  }

  @override
  void setPresence(DiscordActivity? activity, {String status = 'online'}) {
    if (_closed) return;
    _activity = activity;
    _status = status;
    _hasPending = true;
    if (_started) _send();
  }

  void _send() {
    if (!identical(_owner, this)) return;
    unawaited(
      _invoke(_activity == null ? 'clear' : 'update', {
        'activity': _activity?.toJson(DiscordConfig.applicationId),
        'status': _status,
      }),
    );
  }

  @override
  Future<void> clearThenClose() async {
    if (_closed) return;
    setPresence(null);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await close();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _started = false;
    _activity = null;
    // A delayed close from an old toggle must not shut down its replacement.
    if (!identical(_owner, this)) return;
    _owner = null;
    _channel.setMethodCallHandler(null);
    await _invoke('close');
  }
}
