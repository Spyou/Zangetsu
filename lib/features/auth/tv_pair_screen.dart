import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/di/injector.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_focusable.dart';
import 'auth_cubit.dart';
import 'tv_pairing_service.dart';

/// TV device-pairing: shows a QR + short code, the user approves on their
/// already-signed-in phone, and the TV signs itself in. TV-only, no typing.
class TvPairScreen extends StatefulWidget {
  const TvPairScreen({super.key});
  @override
  State<TvPairScreen> createState() => _TvPairScreenState();
}

enum _Phase { loading, ready, signingIn, expired, error }

class _TvPairScreenState extends State<TvPairScreen> {
  final _svc = sl<TvPairingService>();
  String? _code;
  String? _tvSecret;
  Timer? _poll;
  DateTime? _expiresAt;
  _Phase _phase = _Phase.loading;
  String? _errMsg;

  @override
  void initState() {
    super.initState();
    _create();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _create() async {
    _poll?.cancel();
    setState(() {
      _phase = _Phase.loading;
      _errMsg = null;
    });
    try {
      final r = await _svc.startPairing('Android TV');
      if (!mounted) return;
      setState(() {
        _code = r.code;
        _tvSecret = r.tvSecret;
        _expiresAt = DateTime.now().add(const Duration(minutes: 5));
        _phase = _Phase.ready;
      });
      _poll = Timer.periodic(const Duration(seconds: 3), (_) => _tick());
    } catch (_) {
      if (mounted) setState(() => _phase = _Phase.error);
    }
  }

  Future<void> _tick() async {
    if (_phase != _Phase.ready) return;
    if (_expiresAt != null && DateTime.now().isAfter(_expiresAt!)) {
      _poll?.cancel();
      if (mounted) setState(() => _phase = _Phase.expired);
      return;
    }
    // Poll errors are transient (not-yet-approved / network) — keep polling.
    PairPoll res;
    try {
      res = await _svc.poll(_code!, _tvSecret!);
    } catch (_) {
      return;
    }
    if (!res.approved || !mounted) return;
    // Approved → stop polling and complete sign-in. Surface any error HERE
    // instead of hanging forever on "Signing in…".
    _poll?.cancel();
    setState(() => _phase = _Phase.signingIn);
    final err = await _svc.completeSignIn(res.appSecret!);
    if (!mounted) return;
    if (err == null) {
      await context.read<AuthCubit>().adoptCurrentSession();
      if (mounted) Navigator.of(context).maybePop(true);
    } else {
      setState(() {
        _phase = _Phase.error;
        _errMsg = err;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Center(
          child: switch (_phase) {
            _Phase.loading => CircularProgressIndicator(color: AppColors.accent),
            _Phase.expired || _Phase.error => _message(),
            _ => _pairing(),
          },
        ),
      ),
    );
  }

  Widget _pairing() => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: QrImageView(data: 'zangetsu://pair?code=$_code', size: 220, gapless: true),
          ),
          const SizedBox(width: 52),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Sign in with your phone', style: AppText.title),
              const SizedBox(height: 14),
              Text(
                'On the Zangetsu app on your phone, open\n"Pair a TV" and enter this code — or scan the QR.',
                style: AppText.body.copyWith(color: AppColors.textSecondary, height: 1.5),
              ),
              const SizedBox(height: 30),
              Text('CODE',
                  style: AppText.caption
                      .copyWith(letterSpacing: 3, color: AppColors.textTertiary)),
              const SizedBox(height: 6),
              Text(_spacedCode(),
                  style: AppText.title.copyWith(
                      fontSize: 46, letterSpacing: 8, fontWeight: FontWeight.w800)),
              const SizedBox(height: 14),
              if (_phase == _Phase.signingIn)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: AppColors.accent)),
                  const SizedBox(width: 10),
                  Text('Signing in…', style: AppText.body),
                ]),
            ],
          ),
        ],
      );

  Widget _message() {
    final expired = _phase == _Phase.expired;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(expired ? 'Code expired' : 'Something went wrong', style: AppText.title),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 60),
          child: Text(
            expired
                ? 'The pairing code timed out. Get a new one.'
                : (_errMsg ?? "Couldn't start pairing — check your connection."),
            textAlign: TextAlign.center,
            style: AppText.body.copyWith(color: AppColors.textSecondary),
          ),
        ),
        const SizedBox(height: 28),
        TvFocusable(
          autofocus: true,
          scale: 1.0,
          onTap: _create,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
            decoration: BoxDecoration(
                color: AppColors.accent, borderRadius: BorderRadius.circular(12)),
            child: Text('Get a new code',
                style: AppText.headline.copyWith(color: Colors.white)),
          ),
        ),
      ],
    );
  }

  String _spacedCode() {
    final c = _code ?? '';
    return c.length == 8 ? '${c.substring(0, 4)} ${c.substring(4)}' : c;
  }
}
