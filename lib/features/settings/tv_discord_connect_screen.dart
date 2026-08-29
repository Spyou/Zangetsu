import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/discord/discord_relay.dart';
import '../../core/di/injector.dart';
import '../../core/share/pair_link.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tracker/relay/tracker_relay_crypto.dart';
import '../../features/auth/tv_pairing_service.dart';

/// Apple TV: pair with a phone to relay a Discord login (no WebView on tvOS).
class TvDiscordConnectScreen extends StatefulWidget {
  const TvDiscordConnectScreen({super.key});

  @override
  State<TvDiscordConnectScreen> createState() => _TvDiscordConnectScreenState();
}

class _TvDiscordConnectScreenState extends State<TvDiscordConnectScreen> {
  final _svc = sl<TvPairingService>();
  String? _code, _tvSecret, _nonce, _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _code = null;
      _error = null;
    });
    try {
      final r = await _svc.startPairing('Apple TV · Discord');
      if (!mounted) return;
      setState(() {
        _code = r.code;
        _tvSecret = r.tvSecret;
        _nonce = r.nonce;
      });
      _poll = Timer.periodic(const Duration(seconds: 2), (_) => _tick());
    } catch (_) {
      if (mounted) setState(() => _error = "Couldn't start. Try again.");
    }
  }

  Future<void> _tick() async {
    if (_code == null || _tvSecret == null) return;
    PairPoll res;
    try {
      res = await _svc.poll(_code!, _tvSecret!);
    } catch (_) {
      return;
    }
    if (!res.approved || !mounted) return;
    _poll?.cancel();
    final token = _tokenFromBlob(res.trackerBlob);
    if (!mounted) return;
    if (token != null && token.length > 30) {
      Navigator.of(context).pop(token);
    } else {
      setState(() => _error = "Couldn't read the Discord login. Try again.");
    }
  }

  String? _tokenFromBlob(String? blob) {
    final nonce = _nonce;
    if (blob == null || blob.isEmpty || nonce == null) return null;
    try {
      final json = TrackerRelayCrypto.decrypt(blob, nonce);
      return DiscordRelayBlob.tryTokenFromJson(json);
    } catch (_) {
      return null;
    }
  }

  Widget _qrOption({
    required String data,
    required String title,
    required String subtitle,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          child: QrImageView(data: data, size: 200, gapless: true),
        ),
        const SizedBox(height: 14),
        Text(title, style: AppText.title),
        const SizedBox(height: 4),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: AppText.body.copyWith(color: AppColors.textSecondary),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Text('Connect Discord', style: AppText.headline),
      ),
      body: Center(
        child: _code == null
            ? (_error != null
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!, style: AppText.body),
                      const SizedBox(height: 16),
                      TextButton(onPressed: _start, child: const Text('Try again')),
                    ],
                  )
                : const CircularProgressIndicator())
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Scan with your phone to sign in',
                    style: AppText.body.copyWith(color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 8),
                  Text('Code: $_code', style: AppText.title),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _qrOption(
                        data: PairLink.deepLink(
                          code: _code!,
                          nonce: _nonce,
                          discord: true,
                        ),
                        title: 'Have the app?',
                        subtitle: 'Open Zangetsu on your\nphone and scan',
                      ),
                      const SizedBox(width: 36),
                      _qrOption(
                        data: PairLink.qrData(
                          code: _code!,
                          nonce: _nonce,
                          discord: true,
                        ),
                        title: 'No app?',
                        subtitle: 'Scan to open Zangetsu\nand sign in to Discord',
                      ),
                    ],
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      _error!,
                      style: AppText.caption.copyWith(color: Colors.redAccent),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    'Waiting for your phone…',
                    style: AppText.caption.copyWith(color: AppColors.textSecondary),
                  ),
                ],
              ),
      ),
    );
  }
}
