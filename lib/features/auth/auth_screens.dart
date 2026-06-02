import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/buttons.dart';
import 'auth_cubit.dart';

/// Returns true if logged in. Otherwise shows a "Sign in to {action}" snackbar
/// with a Sign-in action and returns false — the gate for My List / history.
bool requireLogin(BuildContext context, {String action = 'use this'}) {
  if (context.read<AuthCubit>().state.isLoggedIn) return true;
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        backgroundColor: AppColors.surface2,
        behavior: SnackBarBehavior.floating,
        content: Text(
          'Sign in to $action',
          style: AppText.body.copyWith(color: Colors.white),
        ),
        action: SnackBarAction(
          label: 'Sign in',
          textColor: AppColors.accent,
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const LoginScreen()),
          ),
        ),
      ),
    );
  return false;
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared dark text field
// ─────────────────────────────────────────────────────────────────────────────

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.hint,
    this.icon,
    this.obscure = false,
    this.keyboard,
  });
  final TextEditingController controller;
  final String hint;
  final IconData? icon;
  final bool obscure;
  final TextInputType? keyboard;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboard,
      style: AppText.body.copyWith(color: AppColors.textPrimary),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: AppText.body.copyWith(color: AppColors.textTertiary),
        prefixIcon: icon == null ? null : Icon(icon, color: AppColors.textTertiary, size: 20),
        filled: true,
        fillColor: AppColors.surface,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.hairline, width: 0.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.accent, width: 1),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Login
// ─────────────────────────────────────────────────────────────────────────────

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit(BuildContext context) async {
    final ok = await context.read<AuthCubit>().login(
      _email.text.trim(),
      _password.text,
    );
    if (ok && context.mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return _AuthScaffold(
      title: 'Welcome back',
      subtitle: 'Sign in to sync your list across devices.',
      children: [
        _Field(controller: _email, hint: 'Email', icon: Icons.mail_outline, keyboard: TextInputType.emailAddress),
        const SizedBox(height: 12),
        _Field(controller: _password, hint: 'Password', icon: Icons.lock_outline, obscure: true),
        const SizedBox(height: 20),
        BlocBuilder<AuthCubit, AuthState>(
          builder: (context, state) => _SubmitBlock(
            label: 'Log in',
            busy: state.busy,
            error: state.error,
            onPressed: () => _submit(context),
          ),
        ),
        const SizedBox(height: 14),
        _SwitchLink(
          prompt: "Don't have an account?",
          action: 'Sign up',
          onTap: () => Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const SignupScreen()),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Signup
// ─────────────────────────────────────────────────────────────────────────────

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});
  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit(BuildContext context) async {
    if (_password.text.length < 8) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(content: Text('Password must be at least 8 characters')));
      return;
    }
    final ok = await context.read<AuthCubit>().signUp(
      _name.text.trim(),
      _email.text.trim(),
      _password.text,
    );
    if (ok && context.mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return _AuthScaffold(
      title: 'Create account',
      subtitle: 'Save your list and continue watching anywhere.',
      children: [
        _Field(controller: _name, hint: 'Name', icon: Icons.person_outline),
        const SizedBox(height: 12),
        _Field(controller: _email, hint: 'Email', icon: Icons.mail_outline, keyboard: TextInputType.emailAddress),
        const SizedBox(height: 12),
        _Field(controller: _password, hint: 'Password (8+ characters)', icon: Icons.lock_outline, obscure: true),
        const SizedBox(height: 20),
        BlocBuilder<AuthCubit, AuthState>(
          builder: (context, state) => _SubmitBlock(
            label: 'Create account',
            busy: state.busy,
            error: state.error,
            onPressed: () => _submit(context),
          ),
        ),
        const SizedBox(height: 14),
        _SwitchLink(
          prompt: 'Already have an account?',
          action: 'Log in',
          onTap: () => Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const LoginScreen()),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Profile (logged-in)
// ─────────────────────────────────────────────────────────────────────────────

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  Future<void> _pickAvatar(BuildContext context) async {
    final x = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 512,
      maxHeight: 512,
      imageQuality: 88,
    );
    if (x != null && context.mounted) {
      await context.read<AuthCubit>().updateAvatar(x.path);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: Text('Profile', style: AppText.title)),
      body: BlocBuilder<AuthCubit, AuthState>(
        builder: (context, state) {
          if (!state.isLoggedIn) {
            return const Center(child: Text('Not signed in'));
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
            children: [
              Center(
                child: GestureDetector(
                  onTap: state.busy ? null : () => _pickAvatar(context),
                  child: Stack(
                    alignment: Alignment.bottomRight,
                    children: [
                      CircleAvatar(
                        radius: 48,
                        backgroundColor: AppColors.surface2,
                        backgroundImage: state.avatarUrl != null
                            ? NetworkImage(state.avatarUrl!)
                            : null,
                        child: state.avatarUrl == null
                            ? Text(
                                state.displayName.isNotEmpty
                                    ? state.displayName[0].toUpperCase()
                                    : '?',
                                style: AppText.largeTitle,
                              )
                            : null,
                      ),
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: const BoxDecoration(
                          color: AppColors.accent,
                          shape: BoxShape.circle,
                        ),
                        child: state.busy
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.camera_alt_rounded, size: 14, color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Center(child: Text(state.displayName, style: AppText.title)),
              const SizedBox(height: 4),
              Center(child: Text(state.user?.email ?? '', style: AppText.caption)),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: SecondaryButton(
                  label: 'Log out',
                  icon: Icons.logout_rounded,
                  onPressed: () {
                    context.read<AuthCubit>().logout();
                    Navigator.of(context).pop();
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared bits
// ─────────────────────────────────────────────────────────────────────────────

class _AuthScaffold extends StatelessWidget {
  const _AuthScaffold({
    required this.title,
    required this.subtitle,
    required this.children,
  });
  final String title;
  final String subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(backgroundColor: Colors.transparent),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          children: [
            Text(title, style: AppText.largeTitle),
            const SizedBox(height: 8),
            Text(subtitle, style: AppText.body),
            const SizedBox(height: 28),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _SubmitBlock extends StatelessWidget {
  const _SubmitBlock({
    required this.label,
    required this.busy,
    required this.error,
    required this.onPressed,
  });
  final String label;
  final bool busy;
  final String? error;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (error != null) ...[
          Text(
            error!,
            style: AppText.caption.copyWith(color: AppColors.accent),
          ),
          const SizedBox(height: 10),
        ],
        SizedBox(
          height: 52,
          child: busy
              ? const Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2.4, color: AppColors.accent),
                  ),
                )
              : PrimaryButton(label: label, onPressed: onPressed),
        ),
      ],
    );
  }
}

class _SwitchLink extends StatelessWidget {
  const _SwitchLink({required this.prompt, required this.action, required this.onTap});
  final String prompt;
  final String action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Text.rich(
          TextSpan(
            text: '$prompt ',
            style: AppText.caption,
            children: [
              TextSpan(
                text: action,
                style: AppText.caption.copyWith(
                  color: AppColors.accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
