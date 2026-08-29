import 'package:flutter/material.dart';

import '../../core/discord/discord_relay.dart';
import '../../core/di/injector.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tracker/relay/tracker_relay_crypto.dart';
import '../../features/auth/tv_pairing_service.dart';
import 'discord_web_login_screen.dart';

/// Phone: after scanning a TV's Discord QR, sign in via WebView and relay the
/// token to the TV. Uses the no-auth `drop` path — no Zangetsu account needed.
class SendDiscordToTvScreen extends StatefulWidget {
  const SendDiscordToTvScreen({super.key, required this.code, required this.nonce});
  final String? code;
  final String? nonce;

  static Route<void> route(String? code, String? nonce) => MaterialPageRoute(
        builder: (_) => SendDiscordToTvScreen(code: code, nonce: nonce),
      );

  @override
  State<SendDiscordToTvScreen> createState() => _SendDiscordToTvScreenState();
}

class _SendDiscordToTvScreenState extends State<SendDiscordToTvScreen> {
  bool _busy = false;
  bool _done = false;
  String? _error;

  Future<void> _signIn() async {
    final code = widget.code, nonce = widget.nonce;
    if (code == null || nonce == null) {
      setState(() => _error = 'Invalid pairing link.');
      return;
    }
    final token = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const DiscordWebLoginScreen()),
    );
    if (token == null || token.length <= 30 || !mounted) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final blob = TrackerRelayCrypto.encrypt(
        DiscordRelayBlob(token: token).encode(),
        nonce,
      );
      final ok = await sl<TvPairingService>().dropRelay(code, blob);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _done = ok;
        if (!ok) _error = 'Send failed. Try again.';
      });
      if (ok) {
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        if (mounted) Navigator.of(context).maybePop();
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Send failed. Try again.';
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _signIn());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text('Discord for TV'),
        backgroundColor: AppColors.bg,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: _done
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.check_circle_rounded,
                        size: 56, color: Colors.green),
                    const SizedBox(height: 16),
                    Text('Sent to your TV', style: AppText.headline),
                    const SizedBox(height: 8),
                    Text(
                      'You can head back to your TV — Discord should connect shortly.',
                      textAlign: TextAlign.center,
                      style:
                          AppText.body.copyWith(color: AppColors.textSecondary),
                    ),
                  ],
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Sign in to Discord', style: AppText.headline),
                  const SizedBox(height: 8),
                  Text(
                    'Your login is sent only to the TV that showed the QR code.',
                    style: AppText.body.copyWith(color: AppColors.textSecondary),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!,
                        style:
                            AppText.caption.copyWith(color: Colors.redAccent)),
                  ],
                  const Spacer(),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _busy ? null : _signIn,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        padding: const EdgeInsets.symmetric(vertical: 15),
                      ),
                      child: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Text(
                              'Continue to Discord',
                              style:
                                  AppText.headline.copyWith(color: Colors.white),
                            ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
