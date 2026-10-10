import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../../core/ui/settings_widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/buttons.dart';
import '../../core/tv/tv_focusable.dart';
import 'auth_cubit.dart';
import 'auth_screens_tv.dart';
import 'pair_tv_screen.dart';
import 'reconnect.dart';
import '../../l10n/l10n.dart';
import '../../l10n/ui_strings.dart';

/// Returns true if logged in. Otherwise shows a "Sign in to {action}" snackbar
/// with a Sign-in action and returns false — the gate for My List / history.
bool requireLogin(BuildContext context, {String? action}) {
  if (context.read<AuthCubit>().state.isLoggedIn) return true;
  final act = action ?? context.l10n.signInToUseThis;
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        backgroundColor: AppColors.surface2,
        behavior: SnackBarBehavior.floating,
        content: Text(
          context.l10n.signInToAction(act),
          style: AppText.body.copyWith(color: Colors.white),
        ),
        action: SnackBarAction(
          label: context.l10n.signIn,
          textColor: AppColors.accent,
          onPressed: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const LoginScreen())),
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
        prefixIcon: icon == null
            ? null
            : Icon(icon, color: AppColors.textTertiary, size: 20),
        filled: true,
        fillColor: AppColors.surface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.hairline, width: 0.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: AppColors.accent, width: 1),
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

  /// context.l10n.forgotPassword — ask for the account email and send an Appwrite
  /// recovery link (completed on the hosted reset page). Works while signed out.
  Future<void> _forgotPassword(BuildContext context) async {
    final controller = TextEditingController(text: _email.text.trim());
    final email = await showDialog<String>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text(context.l10n.resetPassword),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              "Enter your account email and we'll send a link to set a new "
              'password.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                labelText: context.l10n.email,
                hintText: context.l10n.youExampleCom,
              ),
              onSubmitted: (v) => Navigator.of(dctx).pop(v.trim()),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dctx).pop(controller.text.trim()),
            child: Text(context.l10n.sendLink),
          ),
        ],
      ),
    );
    controller.dispose();
    if (email == null || email.isEmpty || !context.mounted) return;
    final err = await context.read<AuthCubit>().sendRecovery(email);
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(err ?? context.l10n.resetLinkSent)));
  }

  @override
  Widget build(BuildContext context) {
    if (sl<AppMode>().isTv) return const LoginScreenTv();
    return _AuthScaffold(
      title: context.l10n.welcomeBack,
      subtitle: context.l10n.signInToSyncYourListAcrossDevices,
      children: [
        _Field(
          controller: _email,
          hint: context.l10n.email,
          icon: Icons.mail_outline,
          keyboard: TextInputType.emailAddress,
        ),
        const SizedBox(height: 12),
        _Field(
          controller: _password,
          hint: context.l10n.password,
          icon: Icons.lock_outline,
          obscure: true,
        ),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: TextButton(
            onPressed: () => _forgotPassword(context),
            child: Text(context.l10n.forgotPassword),
          ),
        ),
        const SizedBox(height: 8),
        BlocBuilder<AuthCubit, AuthState>(
          builder: (context, state) => _SubmitBlock(
            label: context.l10n.logIn,
            busy: state.busy,
            error: localizeAuthError(context.l10n, state.error),
            onPressed: () => _submit(context),
          ),
        ),
        const SizedBox(height: 14),
        _SwitchLink(
          prompt: context.l10n.dontHaveAnAccount,
          action: context.l10n.signUp,
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

  /// Photo picked before the account exists. Uploaded right after signUp
  /// succeeds (the avatars bucket needs an authenticated session, which only
  /// exists once the account + session are created).
  String? _avatarPath;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    final x = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      // Avatars render at ~40–96px, so 256px is still 2–3× the display size —
      // keeps the Appwrite bucket tiny (~15–30 KB/pic) with no visible quality loss.
      maxWidth: 256,
      maxHeight: 256,
      imageQuality: 80,
    );
    if (x != null && mounted) setState(() => _avatarPath = x.path);
  }

  Future<void> _submit(BuildContext context) async {
    if (_password.text.length < 8) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(context.l10n.passwordMustBeAtLeast8Characters),
          ),
        );
      return;
    }
    final auth = context.read<AuthCubit>();
    final ok = await auth.signUp(
      _name.text.trim(),
      _email.text.trim(),
      _password.text,
    );
    if (!ok) return; // error already surfaced via state
    // Session is live now — upload the chosen photo before leaving.
    if (_avatarPath != null) await auth.updateAvatar(_avatarPath!);
    if (context.mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    if (sl<AppMode>().isTv) return const SignupScreenTv();
    return _AuthScaffold(
      title: context.l10n.createAccount,
      subtitle: context.l10n.saveYourListAndContinueWatchingAnywhere,
      children: [
        Center(
          child: _AvatarPicker(path: _avatarPath, onTap: _pickAvatar),
        ),
        const SizedBox(height: 24),
        _Field(
          controller: _name,
          hint: context.l10n.name,
          icon: Icons.person_outline,
        ),
        const SizedBox(height: 12),
        _Field(
          controller: _email,
          hint: context.l10n.email,
          icon: Icons.mail_outline,
          keyboard: TextInputType.emailAddress,
        ),
        const SizedBox(height: 12),
        _Field(
          controller: _password,
          hint: context.l10n.password8Characters,
          icon: Icons.lock_outline,
          obscure: true,
        ),
        const SizedBox(height: 20),
        BlocBuilder<AuthCubit, AuthState>(
          builder: (context, state) => _SubmitBlock(
            label: context.l10n.createAccount,
            busy: state.busy,
            error: localizeAuthError(context.l10n, state.error),
            onPressed: () => _submit(context),
          ),
        ),
        const SizedBox(height: 14),
        _SwitchLink(
          prompt: 'Already have an account?',
          action: context.l10n.logIn,
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

class ProfileAccountSection extends StatelessWidget {
  const ProfileAccountSection({super.key});

  Future<void> _pickAvatar(BuildContext context) async {
    final x = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      // Avatars render at ~40–96px, so 256px is still 2–3× the display size —
      // keeps the Appwrite bucket tiny (~15–30 KB/pic) with no visible quality loss.
      maxWidth: 256,
      maxHeight: 256,
      imageQuality: 80,
    );
    if (x != null && context.mounted) {
      await context.read<AuthCubit>().updateAvatar(x.path);
    }
  }

  /// Rename dialog → AuthCubit.updateName (writes display_name to the profile
  /// + auth metadata). No-op if unchanged/blank; a snackbar surfaces failure.
  Future<void> _editName(BuildContext context, String current) async {
    final ctrl = TextEditingController(text: current);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.l10n.editName),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.done,
          maxLength: 40,
          decoration: InputDecoration(hintText: context.l10n.yourName),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(context.l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(context.l10n.save),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || name == current || !context.mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final ok = await context.read<AuthCubit>().updateName(name);
    if (!ok && context.mounted) {
      messenger.showSnackBar(
        SnackBar(content: Text(context.l10n.couldnTUpdateYourName)),
      );
    }
  }

  @override
  Widget build(BuildContext context) => BlocBuilder<AuthCubit, AuthState>(
    builder: (context, state) {
      final isTv = sl.isRegistered<AppMode>() && sl<AppMode>().isTv;
      if (!state.isLoggedIn) {
        void signIn() {
          Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const LoginScreen()));
        }

        return Padding(
          padding: EdgeInsets.fromLTRB(24, isTv ? 20 : 28, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(context.l10n.notSignedIn),
              const SizedBox(height: 12),
              if (isTv)
                TvFocusable(
                  autofocus: true,
                  semanticLabel: context.l10n.signIn,
                  onTap: signIn,
                  variant: TvFocusVariant.row,
                  borderRadius: 14,
                  child: Container(
                    height: 56,
                    decoration: BoxDecoration(
                      color: const Color(0x1AFFFFFF),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppColors.hairline, width: 0.5),
                    ),
                    child: Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.login_rounded,
                            color: AppColors.textPrimary,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            context.l10n.signIn,
                            style: AppText.button.copyWith(
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              else
                SecondaryButton(
                  label: context.l10n.signIn,
                  icon: Icons.login_rounded,
                  onPressed: signIn,
                ),
            ],
          ),
        );
      }

      final avatar = CircleAvatar(
        radius: isTv ? 56 : 48,
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
      );
      final name = Text(state.displayName, style: AppText.title);
      final logout = isTv
          ? TvFocusable(
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
                    border: Border.all(color: AppColors.hairline, width: 0.5),
                  ),
                  child: Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.logout_rounded,
                          color: AppColors.textPrimary,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          context.l10n.logOut,
                          style: AppText.button.copyWith(
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            )
          : SecondaryButton(
              label: context.l10n.logOut,
              icon: Icons.logout_rounded,
              onPressed: () async {
                // Backs up an un-synced library first / warns before wiping.
                final done = await safeLogout(context);
                if (done && context.mounted) Navigator.of(context).pop();
              },
            );

      return Padding(
        padding: EdgeInsets.fromLTRB(24, isTv ? 20 : 28, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: isTv
                  ? avatar
                  : GestureDetector(
                      onTap: state.busy ? null : () => _pickAvatar(context),
                      child: Stack(
                        alignment: AlignmentDirectional.bottomEnd,
                        children: [
                          avatar,
                          Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: AppColors.accent,
                              shape: BoxShape.circle,
                            ),
                            child: state.busy
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(
                                    Icons.camera_alt_rounded,
                                    size: 14,
                                    color: Colors.white,
                                  ),
                          ),
                        ],
                      ),
                    ),
            ),
            const SizedBox(height: 16),
            Center(
              child: isTv
                  ? name
                  : InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => _editName(context, state.displayName),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                state.displayName,
                                style: AppText.title,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 7),
                            const Icon(
                              Icons.edit_rounded,
                              size: 15,
                              color: AppColors.textTertiary,
                            ),
                          ],
                        ),
                      ),
                    ),
            ),
            const SizedBox(height: 4),
            Center(
              child: Text(state.user?.email ?? '', style: AppText.caption),
            ),
            SizedBox(height: isTv ? 24 : 32),
            if (!isTv) ...[
              SizedBox(
                width: double.infinity,
                child: SecondaryButton(
                  label: context.l10n.pairATV,
                  icon: Icons.tv_rounded,
                  onPressed: () =>
                      Navigator.of(context).push(PairTvScreen.route()),
                ),
              ),
              const SizedBox(height: 12),
            ],
            SizedBox(width: double.infinity, child: logout),
          ],
        ),
      );
    },
  );
}

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    if (sl<AppMode>().isTv) return const ProfileScreenTv();
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar(context.l10n.profile),
      body: ListView(children: const [ProfileAccountSection()]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared bits
// ─────────────────────────────────────────────────────────────────────────────

/// Circular avatar picker for the signup form — shows the chosen image or a
/// placeholder with a camera badge + context.l10n.addPhoto caption.
class _AvatarPicker extends StatelessWidget {
  const _AvatarPicker({required this.path, required this.onTap});
  final String? path;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            alignment: AlignmentDirectional.bottomEnd,
            children: [
              CircleAvatar(
                radius: 44,
                backgroundColor: AppColors.surface2,
                backgroundImage: path != null ? FileImage(File(path!)) : null,
                child: path == null
                    ? const Icon(
                        Icons.person_outline,
                        size: 40,
                        color: AppColors.textTertiary,
                      )
                    : null,
              ),
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.camera_alt_rounded,
                  size: 14,
                  color: Colors.white,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            path == null ? context.l10n.addPhoto : context.l10n.changePhoto,
            style: AppText.caption.copyWith(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

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
              ? Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: AppColors.accent,
                    ),
                  ),
                )
              : PrimaryButton(label: label, onPressed: onPressed),
        ),
      ],
    );
  }
}

class _SwitchLink extends StatelessWidget {
  const _SwitchLink({
    required this.prompt,
    required this.action,
    required this.onTap,
  });
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
