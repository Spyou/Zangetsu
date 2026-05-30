# WATCH_APP — Apple-style UI Redesign (cross-platform, Android-optimized) — Design Spec

**Date:** 2026-05-30
**Status:** Approved (design); pending implementation plan
**Builds on:** the working app on `main` (search → detail → player, quality picker).

## Summary

A **visual-only** redesign giving WATCH_APP an **Apple TV / TV+** aesthetic —
deep dark, content-forward, frosted vibrancy, near-monochrome palette — delivered
**consistently on Android and iOS**, with explicit **Android performance**
guardrails. No behavior changes: search, source resolution, playback, quality
switching, resume, autoplay all work exactly as today; only the look changes.

### Decisions locked during brainstorming

| Topic | Decision |
|---|---|
| Aesthetic | Apple TV–style: cinematic dark, poster-forward, frosted vibrancy |
| Cross-platform | Same Apple look on **both** Android + iOS (not iOS-only) |
| Typography | **Bundled Inter** (open SF-adjacent grotesk) — identical on both platforms, offline |
| Widgets | Custom Apple-styled shared widgets (NOT raw Cupertino, which only feels right on iOS) |
| Palette | Near-monochrome: black canvas, white primary actions, restrained system-blue for selection; **art carries the color** |
| Android perf | Real blur only on static overlays; gradient scrims elsewhere; sized image decode; const/builders |
| Scope | Design system + restyle Home, Detail, Player |

## Goals / non-goals

- **Goal:** a distinctive, premium Apple-TV feel that looks the same and runs
  smoothly on Android and iOS.
- **Goal:** measurable Android smoothness — no jank scrolling the poster grid; no
  blur-in-scroll-view stutter.
- **Non-goal:** any behavior/feature change (no new screens, no library/downloads
  tabs, no light theme). Pure restyle of the existing 3 screens + theme.

## 1. Design system (`lib/core/theme/`)

`app_theme.dart` — a single dark `ThemeData` built from tokens:

- **Color** (`app_colors.dart`): `bg` `#0A0A0C`; raised surfaces `surface`
  `#141417`, `surface2` `#1E1E22`; text `#FFFFFF` / `secondary` `#B9B9C0` /
  `tertiary` `#7C7C85`; hairline `#FFFFFF14`; **primary action = white**;
  **accent (selection/active) = system blue `#0A84FF`** (Apple dark system blue).
  A `scrim` gradient token (transparent → `#000000CC`) for art overlays.
- **Typography** (`app_text.dart`): family **Inter** (bundled). Apple-like scale:
  largeTitle 34/bold, title 22/semibold, headline 17/semibold, body 15/regular,
  caption 13/regular, with tight letter-spacing on large weights. Set as
  `ThemeData.textTheme` + `fontFamily: 'Inter'`.
- **Shape:** rounded rects, radius 14 (cards) / 20 (sheets, hero) — approximating
  Apple's continuous corners with standard `BorderRadius` (close enough; true
  squircle is out of scope).
- **Spacing:** 4-pt scale (4/8/12/16/24/32); generous screen padding (20).
- **Component themes:** dark `ColorScheme`, transparent `AppBar`, `BottomSheet`
  rounded-top, etc.

## 2. Shared Apple-styled widgets (`lib/core/ui/`)

- **`FrostedSurface`** — the Android-aware vibrancy primitive. Param
  `blur: bool`. When `blur` true AND the surface is **static** (overlays/sheets):
  `BackdropFilter(ImageFilter.blur(sigmaX/Y: 18))` capped, wrapped in
  `RepaintBoundary`, over a `surface.withOpacity(.6)` fill. When `blur` false (or
  in scroll content): a translucent fill + gradient only (no `BackdropFilter`).
  Screens choose `blur: false` for scrolling contexts.
- **`PosterCard`** — rounded poster via `cached_network_image` with
  **`memCacheWidth`** set to the cell pixel width; bottom gradient scrim + title;
  press-scale (`AnimatedScale` on tap-down). Wrapped in `RepaintBoundary`.
- **`SegmentedToggle`** — Apple sliding segmented control (Sub/Dub), custom-drawn
  (animated thumb), works identically on both platforms.
- **`PrimaryButton`** — full-width **white** filled button (black label) for
  Play/Continue; `SecondaryButton` = translucent.
- **`SkeletonGrid` / `EmptyState`** — shimmer placeholder + tasteful empty copy.
- **`SectionHeader`** — large-title text style.

## 3. Screen redesigns (behavior unchanged)

- **Home** (`features/home`): translucent large-title nav ("WATCH_APP" + search
  field). Roomy `GridView.builder` of `PosterCard` (~2.3–3 cols, `cacheExtent`).
  `SkeletonGrid` while searching; `EmptyState` before first search / on no results.
- **Detail** (`features/detail`): full-bleed **blurred cover backdrop** —
  implemented as the cover image with a `gradient scrim` (NOT a live BackdropFilter
  over scroll); crisp poster + title + meta over the scrim; a white **Play /
  Continue** `PrimaryButton` (Continue when a resume mark exists → opens the
  next/in-progress episode); `SegmentedToggle` Sub/Dub; episode list with refined
  rows (number • title, filler chip) and a **resume indicator** (thin progress bar
  / "Resume" affordance) from `ResumeStore`.
- **Player** (`features/player`): keep `media_kit` `Video`; restyle the custom
  controls row + the quality/source bottom sheet using `FrostedSurface(blur: true)`
  (static overlays — blur is fine here), accent-blue checkmarks, white icons;
  styled "Resolving sources…" state.

## 4. Android performance rules (enforced in the plan)

1. **`BackdropFilter` blur ONLY on static overlays** (player controls, bottom
   sheets, nav bar) — never inside a scrolling list/grid or over the parallaxing
   hero. Those use gradient scrims + translucent fills. Cap `sigma ≤ 20`. Wrap in
   `RepaintBoundary`.
2. **Posters decode at cell size:** `CachedNetworkImage(memCacheWidth: <cellPx>)`
   so we never hold/​decode full-res art (huge Android memory + scroll win).
3. **`const` constructors** wherever possible; `GridView.builder`/`ListView.builder`
   with a sensible `cacheExtent`; `RepaintBoundary` around the hero + animated bits.
4. Cheap implicit animations (`AnimatedScale`/`AnimatedOpacity`); no continuous
   repaints; no shadows on list items (use hairline borders).

## 5. Fonts

Bundle **Inter** static weights (Regular 400 / Medium 500 / SemiBold 600 /
Bold 700) as `assets/fonts/Inter-*.ttf`, declared in `pubspec.yaml` under
`fonts:` (family `Inter`), set as the theme's `fontFamily`. No `google_fonts`
dependency (offline, deterministic). The plan fetches the TTFs from the official
Inter release (OFL licensed).

## 6. Testing

- `flutter analyze` clean; existing **20 Dart + JS** test suites stay green (no
  logic touched).
- **On-device screenshots on BOTH** an **Android emulator** (start an AVD) **and**
  the **iOS simulator** for Home / Detail / Player, confirming the look matches and
  renders.
- **Android jank check:** scroll the poster grid + open Detail/Player on the Android
  emulator and confirm no obvious stutter (the blur-in-scroll prohibition + sized
  image decode are the levers).

## 7. Build phasing (one plan)

A: bundle Inter + `app_colors`/`app_text`/`app_theme` + wire into `main.dart` →
B: shared widgets (`FrostedSurface`, `PosterCard`, `SegmentedToggle`,
`PrimaryButton`, `SkeletonGrid`/`EmptyState`, `SectionHeader`) → C: restyle Home →
D: restyle Detail (hero + resume indicators) → E: restyle Player chrome + sheet →
F: on-device screenshots on Android **and** iOS + jank check. The
**frontend-design** skill guides the visual quality during B–E.

## Out of scope

- Any behavior/feature change; new screens/tabs (Library/Downloads); light theme;
  true squircle corners; custom launcher icon/splash branding (separate pass).
