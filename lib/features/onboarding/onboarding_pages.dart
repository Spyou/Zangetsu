import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/di/injector.dart';
import '../../core/mode/content_mode.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/theme/theme_controller.dart';
import '../../l10n/l10n.dart';
import '../../l10n/ui_strings.dart';
import '../auth/auth_cubit.dart';
import '../../core/profiles/viewer_profile.dart';
import '../auth/auth_screens.dart' show SignupScreen;

/// Fades + lifts its child in when [active] turns true (staggered by
/// [order]) and resets when the page is left, so each page "plays" every
/// time you land on it.
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

/// Slowly drifting wall of poster-coloured tiles behind the brand page.
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
  static const _tints = <Color>[
    Color(0xFFFF4D57),
    Color(0xFF4D9BFF),
    Color(0xFFFFB84D),
    Color(0xFF7A5CFF),
    Color(0xFF3AD6A0),
    Color(0xFFFF6FB5),
  ];
  static const _cols = 4, _rows = 12, _gap = 10.0, _loop = 6;

  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 28),
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
  Widget _tile(int i, double w, double h) {
    final posters = widget.posters;
    final fallback = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _tints[i % _tints.length].withValues(alpha: 0.6),
            const Color(0xFF14141A),
          ],
        ),
      ),
    );
    return Container(
      width: w,
      height: h,
      margin: const EdgeInsets.only(bottom: _gap),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(10)),
      child: posters.isEmpty
          ? fallback
          : CachedNetworkImage(
              imageUrl: posters[i % posters.length],
              fit: BoxFit.cover,
              memCacheWidth: 240,
              fadeInDuration: const Duration(milliseconds: 400),
              placeholder: (_, _) => fallback,
              errorWidget: (_, _, _) => fallback,
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ClipRect(
        child: LayoutBuilder(
          builder: (_, box) {
            final tileW = box.maxWidth * 1.25 / _cols;
            final step = tileW * 1.5 + _gap;
            return Transform.rotate(
              angle: -0.14,
              child: OverflowBox(
                maxWidth: box.maxWidth * 1.25,
                maxHeight: double.infinity,
                alignment: Alignment.topCenter,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var c = 0; c < _cols; c++)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: _gap / 2,
                        ),
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
                            children: [
                              for (var r = 0; r < _rows; r++)
                                _tile(
                                  c * _loop + r % _loop,
                                  tileW - _gap,
                                  tileW * 1.5,
                                ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Brand moment: pulsing logo + wordmark + the one-line pitch.
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
      padding: const EdgeInsets.fromLTRB(28, 0, 28, 140),
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
          const SizedBox(height: 26),
          OnbReveal(
            active: widget.active,
            order: 2,
            child: Text(
              context.l10n.goodToHaveYouHere,
              style: AppText.title,
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 10),
          OnbReveal(
            active: widget.active,
            order: 3,
            child: Text(
              context.l10n.onboardingIntro,
              style: AppText.body.copyWith(color: AppColors.textSecondary),
              textAlign: TextAlign.center,
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
      padding: const EdgeInsets.fromLTRB(26, 64, 26, 150),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }
}

/// Sign in, or carry on as a guest. Guests keep everything on the device.
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
    return _PageScroll(
      children: [
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
                  child: const Text('Continue as guest'),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'An account keeps My List, Continue Watching and your settings '
                'in sync across devices. As a guest everything stays on this '
                'phone. You can sign in later from Settings.',
                style: AppText.caption.copyWith(color: AppColors.textTertiary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Accent colour + wallpaper colours, previewed live on a mini Home card.
class OnbLookPage extends StatefulWidget {
  const OnbLookPage({super.key, required this.active});
  final bool active;

  @override
  State<OnbLookPage> createState() => _OnbLookPageState();
}

class _OnbLookPageState extends State<OnbLookPage> {
  bool _wallpaperOk = false;

  @override
  void initState() {
    super.initState();
    ThemeController.supported().then((ok) {
      if (mounted && ok) setState(() => _wallpaperOk = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.active;
    return ValueListenableBuilder<int>(
      valueListenable: ThemeController.revision,
      builder: (context, _, _) => _PageScroll(
        children: [
          OnbReveal(
            active: a,
            child: Text('Make it yours', style: AppText.title),
          ),
          const SizedBox(height: 8),
          OnbReveal(
            active: a,
            order: 1,
            child: Text(
              'Pick an accent. The whole app follows.',
              style: AppText.body.copyWith(color: AppColors.textSecondary),
            ),
          ),
          const SizedBox(height: 22),
          OnbReveal(
            active: a,
            order: 2,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColors.hairline),
              ),
              child: Column(
                children: [
                  Container(
                    height: 90,
                    alignment: Alignment.bottomLeft,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      gradient: const LinearGradient(
                        colors: [Color(0xFF2A2B35), Color(0xFF14141A)],
                      ),
                    ),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.accent,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: const Text(
                        '▶  Play',
                        style: TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      for (var i = 0; i < 3; i++) ...[
                        if (i > 0) const SizedBox(width: 8),
                        Expanded(
                          child: Container(
                            height: 44,
                            decoration: BoxDecoration(
                              color: AppColors.surface2,
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          OnbReveal(
            active: a,
            order: 3,
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final (name, color) in ThemeController.accentPresets)
                  _Swatch(
                    name: name,
                    color: color,
                    selected:
                        !ThemeController.materialYou &&
                        ThemeController.accent.toARGB32() == color.toARGB32(),
                    onTap: () => _saveTheme(accent: color),
                  ),
              ],
            ),
          ),
          if (_wallpaperOk) ...[
            const SizedBox(height: 16),
            OnbReveal(
              active: a,
              order: 4,
              child: Container(
                padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.hairline),
                ),
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Match my wallpaper'),
                  subtitle: const Text('Material You colours'),
                  value: ThemeController.materialYou,
                  onChanged: (on) => _saveTheme(materialYou: on),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.name,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: name,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedScale(
          scale: selected ? 1.12 : 1,
          duration: const Duration(milliseconds: 200),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? Colors.white : Colors.transparent,
                width: 3,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Which kinds of content to open the app on.
class OnbInterestsPage extends StatelessWidget {
  const OnbInterestsPage({
    super.key,
    required this.active,
    required this.selected,
    required this.onSelect,
  });

  final bool active;
  final ContentMode selected;
  final ValueChanged<ContentMode> onSelect;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final items = <(ContentMode, IconData, String, String)>[
      (
        ContentMode.anime,
        Icons.movie_filter_outlined,
        l10n.modeStreaming,
        'Anime, series and movies',
      ),
      (
        ContentMode.manga,
        Icons.menu_book_outlined,
        l10n.modeManga,
        'Read chapters',
      ),
      (
        ContentMode.novel,
        Icons.auto_stories_outlined,
        l10n.modeNovel,
        'Light novels',
      ),
    ];
    return _PageScroll(
      children: [
        OnbReveal(
          active: active,
          child: Text("What's your main priority?", style: AppText.title),
        ),
        const SizedBox(height: 8),
        OnbReveal(
          active: active,
          order: 1,
          child: Text(
            'The app opens on it first. Switch anytime.',
            style: AppText.body.copyWith(color: AppColors.textSecondary),
          ),
        ),
        const SizedBox(height: 22),
        for (var i = 0; i < items.length; i++)
          OnbReveal(
            active: active,
            order: 2 + i,
            child: _InterestCard(
              icon: items[i].$2,
              title: items[i].$3,
              subtitle: items[i].$4,
              selected: selected == items[i].$1,
              onTap: () => onSelect(items[i].$1),
            ),
          ),
      ],
    );
  }
}

class _InterestCard extends StatelessWidget {
  const _InterestCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Semantics(
        button: true,
        selected: selected,
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: selected
                  ? Color.alphaBlend(
                      AppColors.accent.withValues(alpha: 0.14),
                      AppColors.surface,
                    )
                  : AppColors.surface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: selected ? AppColors.accent : AppColors.hairline,
                width: 1.5,
              ),
            ),
            child: Row(
              children: [
                Icon(icon, size: 28, color: AppColors.accent),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: AppText.body),
                      Text(
                        subtitle,
                        style: AppText.caption.copyWith(
                          color: AppColors.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: selected ? 1 : 0,
                  child: Icon(
                    Icons.radio_button_checked,
                    color: AppColors.accent,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Hand-off: the app ships with no sources, so point at Providers.
class OnbFinishPage extends StatelessWidget {
  const OnbFinishPage({
    super.key,
    required this.active,
    required this.onAddSourcesNow,
    required this.onLater,
  });

  final bool active;
  final VoidCallback onAddSourcesNow;
  final VoidCallback onLater;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 0, 28, 40),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          OnbReveal(
            active: active,
            child: Text(
              context.l10n.readyWhenYouAre,
              style: AppText.title,
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 12),
          OnbReveal(
            active: active,
            order: 1,
            child: Text(
              context.l10n.providersWaitingInSettings,
              style: AppText.body.copyWith(color: AppColors.textSecondary),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 32),
          OnbReveal(
            active: active,
            order: 2,
            child: SizedBox(
              width: double.infinity,
              height: 54,
              child: FilledButton(
                onPressed: onAddSourcesNow,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(27),
                  ),
                ),
                child: Text(
                  context.l10n.addSourcesNow,
                  style: AppText.button.copyWith(color: Colors.white),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          OnbReveal(
            active: active,
            order: 3,
            child: TextButton(
              onPressed: onLater,
              child: Text(
                context.l10n.illDoItLater,
                style: AppText.caption.copyWith(color: AppColors.textTertiary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Trending anime covers for the brand backdrop. Best-effort: any failure
/// returns an empty list and the wall keeps its gradient tiles.
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

/// Saves a theme pick the same way the app's own settings do: the device-wide
/// value, plus the active profile when one exists (a profile's own accent
/// would otherwise win and the pick would seem to do nothing).
Future<void> _saveTheme({Color? accent, bool? materialYou}) async {
  if (accent != null) await ThemeController.setAccent(accent);
  if (materialYou != null) await ThemeController.setMaterialYou(materialYou);
  if (!sl.isRegistered<ViewerProfileStore>()) return;
  final store = sl<ViewerProfileStore>();
  if (!store.isLoadedForCurrentUser) return;
  await store.updateTheme(
    store.activeId,
    accentColor: accent?.toARGB32(),
    materialYou: materialYou,
  );
}
