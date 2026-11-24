import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/di/injector.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../l10n/l10n.dart';
import '../../l10n/ui_strings.dart';
import '../auth/auth_cubit.dart';
import '../auth/auth_screens.dart' show SignupScreen;

/// Fades + lifts its child in once when [active] is true, staggered by
/// [order].
class OnbReveal extends StatefulWidget {
  const OnbReveal({
    super.key,
    required this.active,
    required this.child,
    this.order = 0,
  });

  final bool active;
  final int order;
  final Widget child;

  @override
  State<OnbReveal> createState() => _OnbRevealState();
}

class _OnbRevealState extends State<OnbReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );
  Timer? _delay;

  @override
  void initState() {
    super.initState();
    if (widget.active) _play();
  }

  @override
  void didUpdateWidget(OnbReveal old) {
    super.didUpdateWidget(old);
    if (widget.active == old.active) return;
    // Plays once. Resetting on leave would blank a page that is still
    // half on screen mid-swipe.
    if (widget.active && _c.value == 0) _play();
  }

  void _play() {
    _delay?.cancel();
    _delay = Timer(Duration(milliseconds: widget.order * 90), () {
      if (mounted && widget.active) _c.forward(from: 0);
    });
  }

  @override
  void dispose() {
    _delay?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (_, child) {
        final t = Curves.easeOutCubic.transform(_c.value.clamp(0.0, 1.0));
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, 18 * (1 - t)),
            child: child,
          ),
        );
      },
    );
  }
}

/// Slowly drifting wall of anime posters behind the intro and sign-in.
class OnbPosterWall extends StatefulWidget {
  const OnbPosterWall({
    super.key,
    this.posters = const [],
    this.animate = true,
  });

  /// False once the wall is dimmed behind other pages — stops the drift.
  final bool animate;

  /// Cover URLs; gradient tiles stand in until (or if) they load.
  final List<String> posters;

  @override
  State<OnbPosterWall> createState() => _OnbPosterWallState();
}

class _OnbPosterWallState extends State<OnbPosterWall>
    with SingleTickerProviderStateMixin {
  static const _cols = 5, _gap = 10.0, _loop = 6;

  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 44),
  )..repeat();

  @override
  void didUpdateWidget(OnbPosterWall old) {
    super.didUpdateWidget(old);
    if (widget.animate == old.animate) return;
    widget.animate ? _c.repeat() : _c.stop();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// Index repeats every [_loop] rows so the drift loops without a seam.
  /// Posters fade in one after another as they load; until then (or offline)
  /// a tile is just a faint dark card, never a coloured placeholder.
  Widget _tile(int i, double h) {
    final posters = widget.posters;
    final base = DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.5),
      ),
    );
    return Container(
      height: h,
      margin: const EdgeInsets.only(bottom: _gap),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(12)),
      child: posters.isEmpty
          ? base
          : CachedNetworkImage(
              imageUrl: posters[i % posters.length],
              memCacheWidth: 240,
              fadeInDuration: Duration.zero,
              placeholder: (_, _) => base,
              errorWidget: (_, _, _) => base,
              imageBuilder: (_, image) => _FadeIn(
                delay: Duration(
                  milliseconds: (i % _loop) * 110 + (i ~/ _loop) * 80,
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    image: DecorationImage(
                      image: image,
                      fit: BoxFit.cover,
                      // Tones the art down so it sits behind the text.
                      colorFilter: ColorFilter.mode(
                        Colors.black.withValues(alpha: 0.28),
                        BlendMode.darken,
                      ),
                    ),
                  ),
                ),
              ),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (_, box) {
          final w = box.maxWidth, h = box.maxHeight;
          // The wall is laid out twice the screen size and tilted about the
          // screen centre, so the tilt can never leave bare corners.
          final tileH = (2 * w / _cols) * 1.5;
          final step = tileH + _gap;
          final rows = (2 * h / step).ceil() + _loop + 1;
          return ClipRect(
            child: OverflowBox(
              minWidth: 2 * w,
              maxWidth: 2 * w,
              minHeight: 2 * h,
              maxHeight: 2 * h,
              child: Transform.rotate(
                angle: -0.14,
                child: SizedBox(
                  width: 2 * w,
                  height: 2 * h,
                  child: Row(
                    children: [
                      for (var c = 0; c < _cols; c++)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: _gap / 2,
                            ),
                            child: OverflowBox(
                              alignment: Alignment.topCenter,
                              minHeight: 0,
                              maxHeight: double.infinity,
                              // Tiles are built once; only the offset moves.
                              child: AnimatedBuilder(
                                animation: _c,
                                builder: (_, tiles) => Transform.translate(
                                  offset: Offset(
                                    0,
                                    -step *
                                        _loop *
                                        (c.isEven ? _c.value : 1 - _c.value),
                                  ),
                                  child: tiles,
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    for (var r = 0; r < rows; r++)
                                      _tile(c * _loop + r % _loop, tileH),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Intro: the pulsing logo and wordmark, shown for a moment before sign-in.
class OnbBrandPage extends StatefulWidget {
  const OnbBrandPage({super.key, required this.active});
  final bool active;

  @override
  State<OnbBrandPage> createState() => _OnbBrandPageState();
}

class _OnbBrandPageState extends State<OnbBrandPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 0, 28, 20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          OnbReveal(
            active: widget.active,
            child: ScaleTransition(
              scale: Tween(begin: 1.0, end: 1.05).animate(
                CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
              ),
              child: Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.accent.withValues(alpha: 0.35),
                      blurRadius: 60,
                    ),
                  ],
                ),
                child: Image.asset(
                  'assets/icon/logo_mark.png',
                  width: 96,
                  height: 96,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          OnbReveal(
            active: widget.active,
            order: 1,
            child: FractionallySizedBox(
              widthFactor: 0.62,
              child: Image.asset(
                'assets/icon/wordmark.png',
                fit: BoxFit.contain,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PageScroll extends StatelessWidget {
  const _PageScroll({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(26, 56, 26, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }
}

class _LogoRow extends StatelessWidget {
  const _LogoRow();

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Image.asset('assets/icon/logo_mark.png', width: 40, height: 40),
      const SizedBox(width: 10),
      SizedBox(
        width: 120,
        child: Image.asset('assets/icon/wordmark.png', fit: BoxFit.contain),
      ),
    ],
  );
}

/// Sign in, sign up, or continue without an account. Without one, everything
/// stays on this device.
class OnbAccountPage extends StatefulWidget {
  const OnbAccountPage({super.key, required this.active, required this.onNext});
  final bool active;
  final VoidCallback onNext;

  @override
  State<OnbAccountPage> createState() => _OnbAccountPageState();
}

class _OnbAccountPageState extends State<OnbAccountPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  StreamSubscription<AuthState>? _auth;

  @override
  void initState() {
    super.initState();
    // Sign-in and sign-up (a separate screen) both end here: once someone is
    // signed in, move on exactly once.
    _auth = sl<AuthCubit>().stream.listen((st) {
      if (st.isLoggedIn && mounted) widget.onNext();
    });
  }

  @override
  void dispose() {
    _auth?.cancel();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() =>
      sl<AuthCubit>().login(_email.text.trim(), _password.text);

  InputDecoration _deco(String hint, IconData icon) => InputDecoration(
    hintText: hint,
    prefixIcon: Icon(icon, size: 20, color: AppColors.textTertiary),
    filled: true,
    fillColor: AppColors.surface,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: AppColors.hairline),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: AppColors.hairline),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: AppColors.accent),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final a = widget.active;
    final auth = sl<AuthCubit>().state;
    if (auth.isLoggedIn) {
      // Only reachable when replaying from Settings.
      return _PageScroll(
        children: [
          const _LogoRow(),
          const SizedBox(height: 28),
          Text('You are signed in', style: AppText.title),
          const SizedBox(height: 8),
          Text(
            auth.displayName,
            style: AppText.body.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 28),
          SizedBox(
            height: 52,
            child: FilledButton(
              onPressed: widget.onNext,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(26),
                ),
              ),
              child: Text(context.l10n.continueLabel),
            ),
          ),
        ],
      );
    }
    return _PageScroll(
      children: [
        const _LogoRow(),
        const SizedBox(height: 22),
        OnbReveal(
          active: a,
          child: Text(context.l10n.welcomeBack, style: AppText.title),
        ),
        const SizedBox(height: 8),
        OnbReveal(
          active: a,
          order: 1,
          child: Text(
            context.l10n.signInToSyncYourListAcrossDevices,
            style: AppText.body.copyWith(color: AppColors.textSecondary),
          ),
        ),
        const SizedBox(height: 24),
        OnbReveal(
          active: a,
          order: 2,
          child: Column(
            children: [
              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                decoration: _deco(context.l10n.email, Icons.mail_outline),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _password,
                obscureText: true,
                autofillHints: const [AutofillHints.password],
                decoration: _deco(context.l10n.password, Icons.lock_outline),
                onSubmitted: (_) => _login(),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SignupScreen()),
            ),
            child: Text(
              '${context.l10n.dontHaveAnAccount} ${context.l10n.signUp}',
            ),
          ),
        ),
        OnbReveal(
          active: a,
          order: 3,
          child: BlocBuilder<AuthCubit, AuthState>(
            bloc: sl<AuthCubit>(),
            builder: (context, state) {
              final error = localizeAuthError(context.l10n, state.error);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (error != null) ...[
                    Text(
                      error,
                      style: AppText.caption.copyWith(color: AppColors.accent),
                    ),
                    const SizedBox(height: 10),
                  ],
                  SizedBox(
                    height: 52,
                    child: FilledButton(
                      onPressed: state.busy ? null : _login,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(26),
                        ),
                      ),
                      child: state.busy
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.4,
                                color: Colors.white,
                              ),
                            )
                          : Text(
                              context.l10n.logIn,
                              style: AppText.button.copyWith(
                                color: Colors.white,
                              ),
                            ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 14),
        OnbReveal(
          active: a,
          order: 4,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 52,
                child: OutlinedButton(
                  onPressed: widget.onNext,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: BorderSide(color: AppColors.hairline),
                    backgroundColor: AppColors.surface,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(26),
                    ),
                  ),
                  child: const Text('Continue without account'),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'Your data will only be stored on this phone. An account '
                'syncs My List and history across devices.',
                textAlign: TextAlign.center,
                style: AppText.caption.copyWith(color: AppColors.textTertiary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Trending anime covers for the onboarding backdrop. Best-effort: any failure
/// returns an empty list and the wall stays as faint dark cards.
Future<List<String>> fetchOnboardingPosters() async {
  try {
    final res = await sl<Dio>().post<dynamic>(
      'https://graphql.anilist.co',
      data: {
        'query':
            '{ Page(perPage: 24) { media(type: ANIME, sort: TRENDING_DESC, '
            'isAdult: false) { coverImage { large } } } }',
      },
      options: Options(
        receiveTimeout: const Duration(seconds: 6),
        sendTimeout: const Duration(seconds: 6),
      ),
    );
    final media = (res.data as Map)['data']['Page']['media'] as List;
    return [
      for (final m in media)
        if (m is Map && m['coverImage']?['large'] is String)
          m['coverImage']['large'] as String,
    ];
  } catch (_) {
    return const [];
  }
}

/// Fades and eases a poster in after [delay].
class _FadeIn extends StatefulWidget {
  const _FadeIn({required this.delay, required this.child});

  final Duration delay;
  final Widget child;

  @override
  State<_FadeIn> createState() => _FadeInState();
}

class _FadeInState extends State<_FadeIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  late final Timer _t;

  @override
  void initState() {
    super.initState();
    _t = Timer(widget.delay, () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _t.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
    return FadeTransition(
      opacity: curve,
      child: ScaleTransition(
        scale: Tween(begin: 1.08, end: 1.0).animate(curve),
        child: widget.child,
      ),
    );
  }
}
