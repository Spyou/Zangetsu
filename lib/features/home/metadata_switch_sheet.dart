import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/mode/content_mode.dart';
import '../../core/mode/content_mode_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tracker/tracker_hub.dart';
import '../../core/zmode/metadata_provider_prefs.dart';
import '../../core/zmode/zmode_prefs.dart';
import '../../l10n/l10n.dart';

/// Which metadata setting matches where the user is standing. The sheet shows
/// both either way; this only decides which one it puts first.
///
/// There is no separate movies tab: [ContentMode.anime] is "Streaming" and
/// covers anime, movies and series together, with [StreamKind] choosing between
/// them inside it. So the answer comes from BOTH, not from the mode alone —
/// everything reading-shaped, plus anime, is the anime setting; only Streaming
/// switched to movies is the movie/TV one.
enum MetadataAxis { anime, video }

MetadataAxis metadataAxisFor(ContentMode mode, StreamKind kind) =>
    mode == ContentMode.anime && kind == StreamKind.movie
    ? MetadataAxis.video
    : MetadataAxis.anime;

/// Whether picking MyAnimeList would leave the user's list unreachable.
///
/// Browsing MAL works signed out; the list does not. Settings says so on its
/// own row, and this shortcut has to carry the same warning or switching here
/// silently costs someone their list with no explanation.
bool malListNeedsLogin() =>
    sl.isRegistered<TrackerHub>() &&
    !sl<TrackerHub>().connected.any(
      (t) => t.displayName.toLowerCase().contains('myanimelist'),
    );

/// One row's worth of provider identity, so the sheet body stays declarative.
///
/// [asset] is the service's own mark, taken from its own site. [mark] and
/// [colour] are the fallback drawn if that ever fails to decode, so a missing
/// or corrupt file costs a logo rather than the row.
typedef _Brand = ({
  String asset,
  String mark,
  Color colour,
  String name,
  String blurb,
});

/// The sheet behind the Home wordmark: swap metadata provider without going
/// through Settings. Writes the same preference the Settings rows write, so
/// the two can never disagree, and the existing revision notifier is what
/// reloads Home.
///
/// A no-op when the preference isn't registered, same guard Settings uses.
Future<void> showMetadataSwitchSheet(BuildContext context) async {
  if (!sl.isRegistered<MetadataProviderPrefs>()) return;
  final prefs = sl<MetadataProviderPrefs>();
  final l10n = context.l10n;
  // Both sections, always. Hiding the one you are not standing in made the
  // movie/TV choice unreachable from Manga and Novel, and left you guessing
  // which pair a tap would bring up. Where you ARE only decides the order.
  final animeFirst =
      metadataAxisFor(sl<ContentModeCubit>().state, ZModePrefs.streamKind) ==
      MetadataAxis.anime;

  List<Widget> animeSection(BuildContext sheet) => [
    _SectionLabel(title: l10n.animeMetadata, blurb: l10n.animeMetadataSubtitle),
    for (final p in AnimeProvider.values)
      _ProviderRow(
        brand: _animeBrand(p),
        selected: prefs.anime == p,
        // Only worth saying while it is actually true.
        warning: p == AnimeProvider.mal && malListNeedsLogin()
            ? l10n.malLoginForLists
            : null,
        onTap: () => Navigator.of(sheet).pop(p),
      ),
  ];

  List<Widget> videoSection(BuildContext sheet) => [
    _SectionLabel(title: l10n.videoMetadata, blurb: l10n.videoMetadataSubtitle),
    for (final p in VideoProvider.values)
      _ProviderRow(
        brand: _videoBrand(p),
        selected: prefs.video == p,
        onTap: () => Navigator.of(sheet).pop(p),
      ),
  ];

  final picked = await showModalBottomSheet<Object>(
    context: context,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 10),
          Center(
            child: Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.textTertiary.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          if (animeFirst) ...[
            ...animeSection(sheet),
            const SizedBox(height: 6),
            ...videoSection(sheet),
          ] else ...[
            ...videoSection(sheet),
            const SizedBox(height: 6),
            ...animeSection(sheet),
          ],
          const SizedBox(height: 10),
        ],
      ),
    ),
  );

  if (picked == null) return;
  if (picked is VideoProvider) {
    await prefs.setVideo(picked);
  } else if (picked is AnimeProvider) {
    await prefs.setAnime(picked);
  }
}

/// Header above each pair. Two settings live in one sheet now, so each needs
/// to say which content it governs.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.title, required this.blurb});

  final String title;
  final String blurb;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: AppText.headline),
        const SizedBox(height: 1),
        Text(
          blurb,
          style: AppText.caption.copyWith(color: AppColors.textTertiary),
        ),
      ],
    ),
  );
}

_Brand _animeBrand(AnimeProvider p) => p == AnimeProvider.mal
    ? (
        asset: 'assets/icon/providers/mal.png',
        mark: 'MAL',
        colour: const Color(0xFF2E51A2),
        name: 'MyAnimeList',
        blurb: 'Browsing works signed out',
      )
    : (
        asset: 'assets/icon/providers/anilist.png',
        mark: 'AL',
        colour: const Color(0xFF02A9FF),
        name: 'AniList',
        blurb: 'Browse and your list, signed out or in',
      );

_Brand _videoBrand(VideoProvider p) => p == VideoProvider.simkl
    ? (
        asset: 'assets/icon/providers/simkl.png',
        mark: 'SK',
        colour: const Color(0xFF19212B),
        name: 'Simkl',
        blurb: 'Public catalogue, no sign-in needed',
      )
    : (
        asset: 'assets/icon/providers/tmdb.png',
        mark: 'TM',
        colour: const Color(0xFF01B4E4),
        name: 'TMDB',
        blurb: 'Full artwork, genres and filters',
      );

class _ProviderRow extends StatelessWidget {
  const _ProviderRow({
    required this.brand,
    required this.selected,
    required this.onTap,
    this.warning,
  });

  final _Brand brand;
  final bool selected;
  final VoidCallback onTap;
  final String? warning;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        // The whole row tints when it's the active one, so which provider is
        // answering reads at a glance rather than from the tick alone.
        color: selected ? AppColors.accentSoft : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: SizedBox(
                width: 34,
                height: 34,
                child: Image.asset(
                  brand.asset,
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (_, _, _) => _InitialsMark(brand: brand),
                ),
              ),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    brand.name,
                    style: AppText.body.copyWith(
                      fontWeight: FontWeight.w600,
                      color: selected
                          ? AppColors.accent
                          : AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    warning ?? brand.blurb,
                    style: AppText.caption.copyWith(
                      color: warning != null
                          ? const Color(0xFFE6B450)
                          : AppColors.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
            if (selected) ...[
              const SizedBox(width: 10),
              Icon(Icons.check_rounded, color: AppColors.accent, size: 20),
            ],
          ],
        ),
      ),
    );
  }
}


/// Drawn only when a provider's own mark cannot be decoded.
class _InitialsMark extends StatelessWidget {
  const _InitialsMark({required this.brand});

  final _Brand brand;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: brand.colour,
    child: Center(
      child: Text(
        brand.mark,
        style: AppText.caption.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: 10.5,
        ),
      ),
    ),
  );
}
