import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/di/injector.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import 'auth_cubit.dart';
import 'tv_pairing_service.dart';

/// Phone: approve a TV pairing. Enter the code shown on the TV (or arrive here
/// via the `zangetsu://pair` QR deep-link), confirm the device, and sign the TV
/// into this account. Requires the phone to be signed in.
class PairTvScreen extends StatefulWidget {
  const PairTvScreen({super.key, this.initialCode});
  final String? initialCode;

  static Route<void> route([String? code]) =>
      MaterialPageRoute(builder: (_) => PairTvScreen(initialCode: code));

  @override
  State<PairTvScreen> createState() => _PairTvScreenState();
}

enum _P { enter, confirm, done }

class _PairTvScreenState extends State<PairTvScreen> {
  final _svc = sl<TvPairingService>();
  late final TextEditingController _code =
      TextEditingController(text: widget.initialCode ?? '');
  _P _phase = _P.enter;
  String? _deviceName;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if ((widget.initialCode ?? '').trim().length >= 6) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _lookup());
    }
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  bool get _signedIn => context.read<AuthCubit>().state.isLoggedIn;

  Future<void> _lookup() async {
    final code = _code.text.trim();
    if (code.length < 6) {
      setState(() => _error = 'Enter the code shown on your TV.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final name = await _svc.lookup(code);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (name == null) {
        _error = "That code wasn't found — it may have expired.";
      } else {
        _deviceName = name;
        _phase = _P.confirm;
      }
    });
  }

  Future<void> _approve() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await _svc.approve(_code.text.trim());
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) {
        _phase = _P.done;
      } else {
        _error = 'Approval failed. Try again.';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pair a TV'),
        backgroundColor: AppColors.bg,
        elevation: 0,
      ),
      backgroundColor: AppColors.bg,
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: !_signedIn
            ? _notSignedIn()
            : switch (_phase) {
                _P.enter => _enter(),
                _P.confirm => _confirm(),
                _P.done => _done(),
              },
      ),
    );
  }

  Widget _notSignedIn() => Center(
        child: Text(
          'Sign in to your account first,\nthen pair your TV.',
          textAlign: TextAlign.center,
          style: AppText.body.copyWith(color: AppColors.textSecondary),
        ),
      );

  Widget _enter() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Enter the code from your TV', style: AppText.headline),
          const SizedBox(height: 8),
          Text('Open Zangetsu on your TV and sign in with your phone to see it.',
              style: AppText.body.copyWith(color: AppColors.textSecondary)),
          const SizedBox(height: 24),
          TextField(
            controller: _code,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            maxLength: 9,
            inputFormatters: [UpperCaseFormatter()],
            style: AppText.title.copyWith(letterSpacing: 6),
            decoration: const InputDecoration(
              hintText: 'ABCD 2345',
              counterText: '',
            ),
            onSubmitted: (_) => _lookup(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: AppText.caption.copyWith(color: Colors.redAccent)),
          ],
          const SizedBox(height: 24),
          _primary('Continue', _busy ? null : _lookup),
        ],
      );

  Widget _confirm() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.tv_rounded, size: 48, color: AppColors.accent),
          const SizedBox(height: 16),
          Text('Sign in on ${_deviceName ?? 'this TV'}?', style: AppText.headline),
          const SizedBox(height: 8),
          Text('This TV will sign into your account. You can sign it out later.',
              style: AppText.body.copyWith(color: AppColors.textSecondary)),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: AppText.caption.copyWith(color: Colors.redAccent)),
          ],
          const SizedBox(height: 24),
          _primary('Approve', _busy ? null : _approve),
        ],
      );

  Widget _done() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle_rounded, size: 56, color: Colors.green),
            const SizedBox(height: 16),
            Text('Your TV is signed in', style: AppText.headline),
            const SizedBox(height: 8),
            Text('It should switch to your account in a moment.',
                textAlign: TextAlign.center,
                style: AppText.body.copyWith(color: AppColors.textSecondary)),
            const SizedBox(height: 24),
            _primary('Done', () => Navigator.of(context).maybePop()),
          ],
        ),
      );

  Widget _primary(String label, VoidCallback? onTap) => SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: onTap,
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.accent,
            padding: const EdgeInsets.symmetric(vertical: 15),
          ),
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : Text(label, style: AppText.headline.copyWith(color: Colors.white)),
        ),
      );
}

/// Force typed pairing codes to uppercase (matches the TV's alphabet).
class UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue _, TextEditingValue n) =>
      n.copyWith(text: n.text.toUpperCase());
}
