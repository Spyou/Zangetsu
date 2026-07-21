import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_back_button.dart';
import '../../core/tv/tv_focusable.dart';
import 'auth_cubit.dart';
import 'tv_pair_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Login (TV)
// ─────────────────────────────────────────────────────────────────────────────

/// TV Login: email + password TextFields with the email field autofocused so
/// the Android TV leanback keyboard appears on entry. The login button is a
/// [TvFocusable] so OK/Enter submits via the same [AuthCubit.login] call as
/// the phone path. D-pad DOWN moves email → password → button.
class LoginScreenTv extends StatefulWidget {
  const LoginScreenTv({super.key});
  @override
  State<LoginScreenTv> createState() => _LoginScreenTvState();
}

class _LoginScreenTvState extends State<LoginScreenTv> {
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

  InputDecoration _fieldDecoration(String hint, IconData icon) =>
      InputDecoration(
        hintText: hint,
        hintStyle: AppText.body.copyWith(color: AppColors.textTertiary),
        prefixIcon: Icon(icon, color: AppColors.textTertiary, size: 20),
        filled: true,
        fillColor: AppColors.surface,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.hairline, width: 0.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: AppColors.accent, width: 2),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(
        children: [
          SafeArea(
            child: Center(
              child: SizedBox(
                width: 480,
                child: ListView(
                  shrinkWrap: true,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 48, vertical: 48),
                  children: [
                    Text('Welcome back', style: AppText.largeTitle),
                const SizedBox(height: 8),
                Text(
                  'Sign in to sync your list across devices.',
                  style: AppText.body,
                ),
                const SizedBox(height: 32),

                // Email — autofocus=true triggers the Android TV leanback
                // on-screen keyboard as soon as this screen is displayed.
                TextField(
                  controller: _email,
                  autofocus: true,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  style:
                      AppText.body.copyWith(color: AppColors.textPrimary),
                  cursorColor: AppColors.accent,
                  decoration: _fieldDecoration('Email', Icons.mail_outline),
                ),
                const SizedBox(height: 14),

                // Password — textInputAction.done → calls _submit on TV keyboard OK.
                TextField(
                  controller: _password,
                  obscureText: true,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submit(context),
                  style:
                      AppText.body.copyWith(color: AppColors.textPrimary),
                  cursorColor: AppColors.accent,
                  decoration:
                      _fieldDecoration('Password', Icons.lock_outline),
                ),
                const SizedBox(height: 24),

                BlocBuilder<AuthCubit, AuthState>(
                  builder: (context, state) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (state.error != null) ...[
                          Text(
                            state.error!,
                            style: AppText.caption
                                .copyWith(color: AppColors.accent),
                          ),
                          const SizedBox(height: 10),
                        ],
                        if (state.busy)
                          Center(
                            child: SizedBox(
                              width: 28,
                              height: 28,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.4,
                                color: AppColors.accent,
                              ),
                            ),
                          )
                        else
                          // D-pad OK on this TvFocusable submits the login form —
                          // identical to the phone's "Log in" PrimaryButton.
                          TvFocusable(
                            onTap: () => _submit(context),
                            child: SizedBox(
                              height: 56,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Center(
                                  child: Text(
                                    'Log in',
                                    style: AppText.button
                                        .copyWith(color: Colors.black),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),

                const SizedBox(height: 14),
                // Sign in without typing: pair with the already-signed-in phone.
                TvFocusable(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const TvPairScreen()),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text.rich(
                      TextSpan(
                        text: 'Typing is a pain?  ',
                        style: AppText.caption,
                        children: [
                          TextSpan(
                            text: 'Sign in with your phone',
                            style: AppText.caption.copyWith(
                              color: AppColors.accent,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),

                const SizedBox(height: 8),
                TvFocusable(
                  onTap: () => Navigator.of(context).pushReplacement(
                    MaterialPageRoute(
                        builder: (_) => const SignupScreenTv()),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text.rich(
                      TextSpan(
                        text: "Don't have an account?  ",
                        style: AppText.caption,
                        children: [
                          TextSpan(
                            text: 'Sign up',
                            style: AppText.caption.copyWith(
                              color: AppColors.accent,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ],
                ),
              ),
            ),
          ), // SafeArea
          const Positioned(top: 8, left: 8, child: SafeArea(child: TvBackButton())),
        ], // Stack children
      ), // Stack (body)
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Signup (TV)
// ─────────────────────────────────────────────────────────────────────────────

/// TV Signup: name, email, and password TextFields with the name field
/// autofocused. Avatar selection is omitted on TV (gallery picker is not
/// remote-friendly). Submit calls [AuthCubit.signUp] — same logic as the phone.
class SignupScreenTv extends StatefulWidget {
  const SignupScreenTv({super.key});
  @override
  State<SignupScreenTv> createState() => _SignupScreenTvState();
}

class _SignupScreenTvState extends State<SignupScreenTv> {
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
        ..showSnackBar(
          const SnackBar(
              content: Text('Password must be at least 8 characters')),
        );
      return;
    }
    final ok = await context.read<AuthCubit>().signUp(
      _name.text.trim(),
      _email.text.trim(),
      _password.text,
    );
    if (ok && context.mounted) Navigator.of(context).pop();
  }

  InputDecoration _fieldDecoration(String hint, IconData icon) =>
      InputDecoration(
        hintText: hint,
        hintStyle: AppText.body.copyWith(color: AppColors.textTertiary),
        prefixIcon: Icon(icon, color: AppColors.textTertiary, size: 20),
        filled: true,
        fillColor: AppColors.surface,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.hairline, width: 0.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: AppColors.accent, width: 2),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(
        children: [
          SafeArea(
            child: Center(
              child: SizedBox(
                width: 480,
                child: ListView(
                  shrinkWrap: true,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 48, vertical: 48),
                  children: [
                    Text('Create account', style: AppText.largeTitle),
                const SizedBox(height: 8),
                Text(
                  'Save your list and continue watching anywhere.',
                  style: AppText.body,
                ),
                const SizedBox(height: 32),

                // Name — autofocused so the TV keyboard appears on entry.
                TextField(
                  controller: _name,
                  autofocus: true,
                  textInputAction: TextInputAction.next,
                  style:
                      AppText.body.copyWith(color: AppColors.textPrimary),
                  cursorColor: AppColors.accent,
                  decoration: _fieldDecoration('Name', Icons.person_outline),
                ),
                const SizedBox(height: 14),

                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  style:
                      AppText.body.copyWith(color: AppColors.textPrimary),
                  cursorColor: AppColors.accent,
                  decoration: _fieldDecoration('Email', Icons.mail_outline),
                ),
                const SizedBox(height: 14),

                TextField(
                  controller: _password,
                  obscureText: true,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submit(context),
                  style:
                      AppText.body.copyWith(color: AppColors.textPrimary),
                  cursorColor: AppColors.accent,
                  decoration: _fieldDecoration(
                      'Password (8+ characters)', Icons.lock_outline),
                ),
                const SizedBox(height: 24),

                BlocBuilder<AuthCubit, AuthState>(
                  builder: (context, state) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (state.error != null) ...[
                          Text(
                            state.error!,
                            style: AppText.caption
                                .copyWith(color: AppColors.accent),
                          ),
                          const SizedBox(height: 10),
                        ],
                        if (state.busy)
                          Center(
                            child: SizedBox(
                              width: 28,
                              height: 28,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.4,
                                color: AppColors.accent,
                              ),
                            ),
                          )
                        else
                          TvFocusable(
                            onTap: () => _submit(context),
                            child: SizedBox(
                              height: 56,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Center(
                                  child: Text(
                                    'Create account',
                                    style: AppText.button
                                        .copyWith(color: Colors.black),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),

                const SizedBox(height: 16),
                TvFocusable(
                  onTap: () => Navigator.of(context).pushReplacement(
                    MaterialPageRoute(
                        builder: (_) => const LoginScreenTv()),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text.rich(
                      TextSpan(
                        text: 'Already have an account?  ',
                        style: AppText.caption,
                        children: [
                          TextSpan(
                            text: 'Log in',
                            style: AppText.caption.copyWith(
                              color: AppColors.accent,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ],
                ),
              ),
            ),
          ), // SafeArea
          const Positioned(top: 8, left: 8, child: SafeArea(child: TvBackButton())),
        ], // Stack children
      ), // Stack (body)
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Profile (TV)
// ─────────────────────────────────────────────────────────────────────────────

/// TV Profile: account info + a focusable Logout button. Avatar change is
/// omitted on TV (gallery picker is not remote-friendly). All data and logout
/// flow come from [AuthCubit] — identical to the phone [ProfileScreen].
class ProfileScreenTv extends StatelessWidget {
  const ProfileScreenTv({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(
        children: [
          SafeArea(
            child: BlocBuilder<AuthCubit, AuthState>(
              builder: (context, state) {
                if (!state.isLoggedIn) {
                  return const Center(child: Text('Not signed in'));
                }
            return Center(
              child: SizedBox(
                width: 520,
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 48, vertical: 48),
                  children: [
                    // Avatar
                    Center(
                      child: CircleAvatar(
                        radius: 56,
                        backgroundColor: AppColors.surface2,
                        backgroundImage: state.avatarUrl != null
                            ? CachedNetworkImageProvider(state.avatarUrl!)
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
                    ),
                    const SizedBox(height: 20),

                    Center(
                        child: Text(state.displayName,
                            style: AppText.title)),
                    const SizedBox(height: 6),
                    Center(
                      child: Text(
                        state.user?.email ?? '',
                        style: AppText.caption,
                      ),
                    ),
                    const SizedBox(height: 40),

                    // Logout
                    TvFocusable(
                      autofocus: true,
                      onTap: () {
                        context.read<AuthCubit>().logout();
                        Navigator.of(context).pop();
                      },
                      child: SizedBox(
                        height: 56,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: const Color(0x1AFFFFFF),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                                color: AppColors.hairline, width: 0.5),
                          ),
                          child: Center(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.logout_rounded,
                                    color: AppColors.textPrimary, size: 20),
                                const SizedBox(width: 8),
                                Text(
                                  'Log out',
                                  style: AppText.button.copyWith(
                                      color: AppColors.textPrimary),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
              },
            ),
          ), // SafeArea
          const Positioned(top: 8, left: 8, child: SafeArea(child: TvBackButton())),
        ], // Stack children
      ), // Stack (body)
    );
  }
}
