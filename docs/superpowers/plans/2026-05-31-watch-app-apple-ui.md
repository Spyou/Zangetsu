# WATCH_APP Apple-style UI Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. The **frontend-design** skill drives the visual quality of the widget + screen tasks (B–E). Steps use checkbox (`- [ ]`) syntax.

**Goal:** Give the app an Apple-TV / TV+ look (dark, content-forward, frosted vibrancy, near-monochrome) that renders identically and runs smoothly on **Android and iOS** — visual-only, no behavior change.

**Architecture:** A dark `ThemeData` from explicit tokens (`app_colors`/`app_text`/`app_theme`) + bundled **Inter**; a small set of Apple-styled shared widgets (the perf-critical ones — `FrostedSurface`, `PosterCard` — have real code here); then restyle Home/Detail/Player using them. Android-perf rules are enforced (blur only on static overlays; sized image decode; const/builders).

**Tech Stack:** Flutter, bundled Inter font, `cached_network_image` (already a dep), `media_kit_video`. No `google_fonts`.

**Spec:** `docs/superpowers/specs/2026-05-30-watch-app-apple-ui-design.md`.

**Verification model:** UI is visual — Tasks A/B are verified by `flutter analyze` + existing tests; Tasks C–E by `flutter analyze` + an on-device screenshot; Task F is the cross-platform (Android emulator + iOS sim) screenshot + jank acceptance. The frontend-design skill guides visual composition in B–E; expect a build → screenshot → refine loop per screen.

---

## File structure

```
assets/fonts/Inter.ttf                         # NEW (bundled variable font)
pubspec.yaml                                    # MODIFY: + fonts: Inter; + assets/fonts
lib/core/theme/app_colors.dart                  # NEW: color tokens
lib/core/theme/app_text.dart                    # NEW: text styles (Inter, Apple scale)
lib/core/theme/app_theme.dart                   # NEW: dark ThemeData from tokens
lib/main.dart                                   # MODIFY: theme: appTheme
lib/core/ui/frosted_surface.dart                # NEW: Android-aware blur/gradient surface
lib/core/ui/poster_card.dart                    # NEW: sized-decode poster
lib/core/ui/segmented_toggle.dart               # NEW: Apple sliding segmented control
lib/core/ui/buttons.dart                        # NEW: PrimaryButton (white) + SecondaryButton
lib/core/ui/states.dart                         # NEW: SkeletonGrid + EmptyState
lib/features/home/home_screen.dart              # MODIFY: restyle
lib/features/detail/detail_screen.dart          # MODIFY: restyle (hero + resume)
lib/features/player/player_screen.dart          # MODIFY: restyle chrome + sheet
```

---

## Task A: Bundle Inter + theme tokens + wire into the app

**Files:** create `assets/fonts/Inter.ttf`, `lib/core/theme/{app_colors,app_text,app_theme}.dart`; modify `pubspec.yaml`, `lib/main.dart`.

- [ ] **Step 1: Fetch the Inter variable font into `assets/fonts/Inter.ttf`.**
```bash
cd "/Users/krishnavishwakarma/Programming Playground/watch_app"
mkdir -p assets/fonts
curl -fsSL "https://raw.githubusercontent.com/google/fonts/main/ofl/inter/Inter%5Bopsz%2Cwght%5D.ttf" -o assets/fonts/Inter.ttf
ls -l assets/fonts/Inter.ttf   # expect a non-trivial size (> 300 KB)
```
If that URL 404s, fall back to: `curl -fsSL "https://github.com/rsms/inter/raw/master/docs/font-files/Inter.ttf" -o assets/fonts/Inter.ttf` or any official Inter TTF; the only requirement is a valid Inter TTF at that path. Report the source used + file size.

- [ ] **Step 2: Declare the font + assets in `pubspec.yaml`.** Under the `flutter:` section add (alongside the existing `assets:` list — keep it):
```yaml
  fonts:
    - family: Inter
      fonts:
        - asset: assets/fonts/Inter.ttf
```
And add `- assets/fonts/Inter.ttf` to the `assets:` list (or rely on the font decl; the font decl is sufficient — do NOT also list it as a plain asset). Run `flutter pub get` → `Got dependencies!`.

- [ ] **Step 3: `lib/core/theme/app_colors.dart`:**
```dart
import 'package:flutter/material.dart';

/// Apple-TV-style dark palette. Near-monochrome; art carries the color.
abstract class AppColors {
  static const bg = Color(0xFF0A0A0C);
  static const surface = Color(0xFF141417);
  static const surface2 = Color(0xFF1E1E22);
  static const textPrimary = Color(0xFFFFFFFF);
  static const textSecondary = Color(0xFFB9B9C0);
  static const textTertiary = Color(0xFF7C7C85);
  static const hairline = Color(0x14FFFFFF); // white @ 8%
  static const accent = Color(0xFF0A84FF); // Apple dark system blue (selection/active)

  /// Bottom-up scrim for art overlays (transparent → near-black).
  static const scrim = LinearGradient(
    begin: Alignment.bottomCenter,
    end: Alignment.topCenter,
    colors: [Color(0xE6000000), Color(0x00000000)],
    stops: [0.0, 0.6],
  );
}
```

- [ ] **Step 4: `lib/core/theme/app_text.dart`:**
```dart
import 'package:flutter/material.dart';
import 'app_colors.dart';

/// Apple-like type scale on bundled Inter.
abstract class AppText {
  static const _f = 'Inter';
  static const largeTitle = TextStyle(fontFamily: _f, fontSize: 32, height: 1.1, fontWeight: FontWeight.w700, letterSpacing: -0.5, color: AppColors.textPrimary);
  static const title = TextStyle(fontFamily: _f, fontSize: 22, height: 1.15, fontWeight: FontWeight.w600, letterSpacing: -0.3, color: AppColors.textPrimary);
  static const headline = TextStyle(fontFamily: _f, fontSize: 17, height: 1.2, fontWeight: FontWeight.w600, color: AppColors.textPrimary);
  static const body = TextStyle(fontFamily: _f, fontSize: 15, height: 1.35, fontWeight: FontWeight.w400, color: AppColors.textSecondary);
  static const caption = TextStyle(fontFamily: _f, fontSize: 13, height: 1.3, fontWeight: FontWeight.w500, color: AppColors.textTertiary);
  static const button = TextStyle(fontFamily: _f, fontSize: 16, fontWeight: FontWeight.w600, letterSpacing: -0.2);
}
```

- [ ] **Step 5: `lib/core/theme/app_theme.dart`:**
```dart
import 'package:flutter/material.dart';
import 'app_colors.dart';

ThemeData buildAppTheme() {
  const scheme = ColorScheme.dark(
    surface: AppColors.bg,
    primary: AppColors.textPrimary, // white primary actions
    secondary: AppColors.accent,
    onPrimary: Colors.black,
  );
  return ThemeData(
    useMaterial3: true,
    fontFamily: 'Inter',
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.bg,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
    ),
    dividerTheme: const DividerThemeData(color: AppColors.hairline, thickness: 0.5, space: 0.5),
  );
}
```

- [ ] **Step 6: Wire it in `lib/main.dart`.** Add `import 'core/theme/app_theme.dart';`, and change the `MaterialApp`'s `theme:` to `buildAppTheme()` (replace the existing `ThemeData.dark(...)`).

- [ ] **Step 7: Verify** `flutter analyze` → No issues; `flutter test` → all pass (20). Run `flutter run` briefly OR `flutter build` is not required — analyze is the gate here.

- [ ] **Step 8: Commit**
```bash
git add assets/fonts/Inter.ttf pubspec.yaml pubspec.lock lib/core/theme/ lib/main.dart
git commit -m "feat(ui): bundle Inter + Apple-style dark theme tokens"
```

---

## Task B: Apple-styled shared widgets

**Files:** create `lib/core/ui/{frosted_surface,poster_card,segmented_toggle,buttons,states}.dart`. The **frontend-design** skill informs the visual details; the perf-critical code below is mandatory.

- [ ] **Step 1: `lib/core/ui/frosted_surface.dart`** (the Android-aware vibrancy primitive):
```dart
import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// Apple-style vibrancy. [blur] true → real BackdropFilter (use ONLY on static
/// overlays: sheets, controls, nav — never inside scrolling content). [blur]
/// false → a translucent fill only (cheap; for scroll contexts). Always
/// RepaintBoundary-wrapped so it never repaints its neighbors.
class FrostedSurface extends StatelessWidget {
  const FrostedSurface({super.key, required this.child, this.blur = true, this.opacity = 0.6, this.borderRadius});
  final Widget child;
  final bool blur;
  final double opacity;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final r = borderRadius ?? BorderRadius.zero;
    final fill = DecoratedBox(
      decoration: BoxDecoration(color: AppColors.surface.withValues(alpha: opacity), borderRadius: r),
      child: child,
    );
    if (!blur) return ClipRRect(borderRadius: r, child: fill);
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: r,
        child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18), child: fill),
      ),
    );
  }
}
```

- [ ] **Step 2: `lib/core/ui/poster_card.dart`** (sized decode — the Android scroll win):
```dart
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

class PosterCard extends StatelessWidget {
  const PosterCard({super.key, required this.title, this.imageUrl, this.headers, this.onTap, this.cellWidth = 180});
  final String title;
  final String? imageUrl;
  final Map<String, String>? headers;
  final VoidCallback? onTap;
  final double cellWidth;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final memW = (cellWidth * dpr).round();
    return RepaintBoundary(
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Stack(fit: StackFit.expand, children: [
                  if (imageUrl == null)
                    const ColoredBox(color: AppColors.surface2)
                  else
                    CachedNetworkImage(
                      imageUrl: imageUrl!,
                      httpHeaders: headers,
                      memCacheWidth: memW, // decode at cell size, not full-res
                      fit: BoxFit.cover,
                      fadeInDuration: const Duration(milliseconds: 180),
                      placeholder: (_, __) => const ColoredBox(color: AppColors.surface2),
                      errorWidget: (_, __, ___) => const ColoredBox(color: AppColors.surface2),
                    ),
                  const DecoratedBox(decoration: BoxDecoration(gradient: AppColors.scrim)),
                ]),
              ),
            ),
            const SizedBox(height: 8),
            Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: AppColors.textPrimary)),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 3: `lib/core/ui/buttons.dart`** — `PrimaryButton` (full-width white, black label, leading icon) + `SecondaryButton` (translucent). Use `AppText.button`, radius 14, height 52. (Standard `FilledButton`/`Material` impl; keep it simple and tasteful — frontend-design refines.)

- [ ] **Step 4: `lib/core/ui/segmented_toggle.dart`** — a two-segment Apple sliding control (`SegmentedToggle({required List<String> segments, required int index, required ValueChanged<int> onChanged})`): a `surface2` track, an animated white-ish thumb (`AnimatedAlign`/`AnimatedPositioned`, 200ms), labels in `AppText.headline`. Pure widget, no platform branching.

- [ ] **Step 5: `lib/core/ui/states.dart`** — `SkeletonGrid` (a `GridView` of shimmering `surface2` rounded rects; a simple `AnimatedOpacity`/gradient shimmer, not a heavy package) and `EmptyState({required IconData icon, required String message})` (centered, `textTertiary`).

- [ ] **Step 6: Verify** `flutter analyze lib/core/ui/` → No issues. (These are presentational; no unit tests — verified visually in C–E.)

- [ ] **Step 7: Commit**
```bash
git add lib/core/ui/
git commit -m "feat(ui): Apple-styled shared widgets (frosted surface, poster, segmented, buttons, states)"
```

---

## Task C: Restyle Home

**Files:** modify `lib/features/home/home_screen.dart`. **Use the frontend-design skill** for visual composition; behavior (search → `SourceRepository`) unchanged.

- [ ] **Step 1:** Rebuild the screen with: a transparent/translucent **large-title** area ("WATCH_APP") + a rounded search field (`surface2` fill, `AppText.body`); results in a `GridView.builder` of `PosterCard` (crossAxisCount 3, childAspectRatio ~0.62, spacing 12, `cacheExtent: 800`, `padding: 20`); `SkeletonGrid` while the `FutureBuilder` waits; `EmptyState(icon: Icons.search, ...)` before first search / on no results; error → `EmptyState` with the error. Tapping a `PosterCard` pushes `DetailScreen(item:)` as today. Pass `cellWidth` ≈ `(screenWidth - 2*20 - 2*12) / 3` to `PosterCard`.
- [ ] **Step 2:** `flutter analyze` → No issues; `flutter test` → pass.
- [ ] **Step 3:** Build → on-device screenshot (Task F covers cross-platform; here just confirm it renders without overflow). Iterate visually with frontend-design.
- [ ] **Step 4:** Commit `feat(ui): restyle Home (large-title, poster grid, skeleton/empty states)`.

---

## Task D: Restyle Detail (hero + resume indicators)

**Files:** modify `lib/features/detail/detail_screen.dart`. **frontend-design** drives the hero composition.

- [ ] **Step 1:** Rebuild with a **`CustomScrollView`**: a `SliverAppBar` (expandedHeight ~360) whose `flexibleSpace` is the **cover image** (`CachedNetworkImage`, `httpHeaders`) with `AppColors.scrim` gradient on top (NO live `BackdropFilter` — gradient only, per Android rule) + the title (`AppText.largeTitle`) + meta (`${eps.length} episodes`) over the scrim; a pinned translucent bar with the title on collapse. Below: a white **`PrimaryButton`** ("Play" / "Continue E{n}" when a `ResumeStore` mark exists for some episode), the **`SegmentedToggle`** (Sub/Dub — currently informational unless dub wiring exists; default Sub), then the episode list as `SliverList` rows: number + title (`AppText.headline`/`body`), a filler chip if `ep.filler`, and a **resume indicator** — read `sl<ResumeStore>().get(sourceId, ep.id)`: if present & not finished, show a thin `accent` progress bar (`mark.position/mark.duration`) under the row + a "Resume" affordance; if finished, a subtle ✓. Tapping a row opens the player (unchanged args).
- [ ] **Step 2:** `flutter analyze` → No issues; `flutter test` → pass.
- [ ] **Step 3:** Build → screenshot; iterate visually (frontend-design).
- [ ] **Step 4:** Commit `feat(ui): restyle Detail (hero backdrop, Play/Continue, resume indicators)`.

---

## Task E: Restyle Player chrome + quality sheet

**Files:** modify `lib/features/player/player_screen.dart`. Behavior (controller, quality menu) unchanged.

- [ ] **Step 1:** Wrap the bottom controls `Row` in a `FrostedSurface(blur: true, ...)` (static overlay — blur OK) with white icons + `AppText.caption` status; restyle the `_openPicker` bottom sheet to a `FrostedSurface(blur: true, borderRadius: top-20)` with section headers (`AppText.headline`), `accent` checkmarks on the active quality/source, and comfortable row spacing; style the loading state ("Resolving sources…") with a centered `CupertinoActivityIndicator`-style spinner + `AppText.body`. Keep `_c.qualities`/`selectQuality`/`switchSource` wiring exactly as is.
- [ ] **Step 2:** `flutter analyze` → No issues; `flutter test` → pass.
- [ ] **Step 3:** Commit `feat(ui): restyle player controls + quality sheet (frosted, accent)`.

---

## Task F: Cross-platform on-device acceptance (Android + iOS)

- [ ] **Step 1: Android.** Start an emulator: `flutter emulators` → `flutter emulators --launch <id>` (or create one if none). `env -u GEM_HOME -u GEM_PATH PATH="/opt/homebrew/bin:$PATH" flutter run -d <android>`. Screenshot Home, Detail, Player. **Scroll the poster grid** and confirm no visible jank; open Detail/Player and confirm the frosted overlays look right and don't stutter.
- [ ] **Step 2: iOS.** `flutter run -d "iPhone 15 Pro Max"`. Screenshot the same three. Confirm the look matches Android (Inter type, palette, layout parity).
- [ ] **Step 3:** Record results (both platforms). If Android janks on scroll, verify the `memCacheWidth` is set and no `BackdropFilter` is inside the grid; if a screen overflows, fix and re-screenshot. Only static overlays may use blur.

---

## Self-review

**Spec coverage:** §1 tokens → Task A. §2 shared widgets → Task B. §3 screens → C/D/E. §4 Android perf (blur-only-static via `FrostedSurface` design + `memCacheWidth` in `PosterCard` + const/builders/cacheExtent in screens) → B + C/D/E. §5 fonts → Task A. §6 testing (analyze + tests + dual-platform screenshots + jank) → all tasks + F. ✓

**Type/name consistency:** `AppColors`/`AppText`/`buildAppTheme` (A) used by B–E. `FrostedSurface`/`PosterCard`/`SegmentedToggle`/`PrimaryButton`/`SkeletonGrid`/`EmptyState` (B) used by C/D/E. `cellWidth`/`memCacheWidth`, `ResumeStore.get(sourceId, episodeId)` (existing), `SourceRepository`/`PlayerController` wiring unchanged.

**Placeholder scan:** Tasks A/B carry full real code for the deterministic + perf-critical parts. Tasks C–E are *concrete composition specs* (exact widgets, layout params, perf rules, behavior-preservation) rather than pixel-final code — deliberate: the frontend-design skill + on-device screenshot iteration set the final visual values, and pre-writing exact pixels would be discarded. Each C–E task names every widget/param it uses; none reference undefined types. No "TBD".

## Risks / notes
- **Variable-font weights:** if the bundled Inter variable TTF doesn't render distinct weights on a target, fall back to bundling static `Inter-Regular/Medium/SemiBold/Bold.ttf` and declaring per-weight assets. Verify in the Task A/F screenshots.
- **BackdropFilter is the Android jank risk** — the `FrostedSurface(blur:true)` is used ONLY on the player controls + sheets (static). The Detail hero + Home grid use gradient scrims only. Hold this line in review.
- **iOS-sim audio** is still absent (unrelated); the screenshots judge layout/visuals, not playback.
