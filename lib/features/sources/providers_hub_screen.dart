import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/provider/cloudstream_provider.dart';
import '../../core/provider/provider_manager.dart';
import '../../core/provider/provider_registry.dart';
import '../../core/provider/provider_repo_registry.dart';
import '../../core/state/active_source_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_back_button.dart';
import '../../core/tv/tv_focusable.dart';
import 'aniyomi_sources_screen.dart';
import 'bloc/sources_state.dart';
import 'cloudstream_sources_screen.dart';
import 'zangetsu_sources_screen.dart';

const Widget _kChevron = Icon(
  Icons.chevron_right_rounded,
  color: AppColors.textTertiary,
  size: 22,
);

// CloudStream/Aniyomi don't have a dedicated brand color in AppColors, so we
// keep small local tints here — same "@ ~15%" recipe as AppColors.accentSoft.
const _csBlue = Color(0xFF4D9DFF);
const _aniGreen = Color(0xFF4DD68C);

/// Providers hub — lists the three provider ecosystems (Zangetsu always,
/// CloudStream/Aniyomi on Android only), each row pushing its dedicated
/// ecosystem screen (Tasks 1-3). Stateful only so counts refresh when the
/// user returns from an ecosystem screen (install/remove there is reflected
/// here without re-entering the hub).
///
/// Reached via `SourcesScreen` (Settings → Providers), on both phone and TV.
class ProvidersHubScreen extends StatefulWidget {
  const ProvidersHubScreen({super.key});

  @override
  State<ProvidersHubScreen> createState() => _ProvidersHubScreenState();
}

class _ProvidersHubScreenState extends State<ProvidersHubScreen> {
  Future<void> _open(Widget screen) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => screen),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return sl<AppMode>().isTv ? const _HubTvView() : _HubPhoneView(open: _open);
  }
}

// ---------------------------------------------------------------------------
// Phone
// ---------------------------------------------------------------------------

class _HubPhoneView extends StatelessWidget {
  const _HubPhoneView({required this.open});
  final void Function(Widget screen) open;

  @override
  Widget build(BuildContext context) {
    final zangetsuCount = sl<ProviderRegistry>().getAll().length;
    final showCs = Platform.isAndroid;
    final showAniyomi = Platform.isAndroid;

    final csGroups = sl<CloudStreamManager>().repoGroups;
    final csInstalled = csGroups.fold<int>(0, (s, g) => s + g.sources.length);
    final csRepos = csGroups.length;
    final aniCount = sl<AniyomiManager>().all.length;

    // Read-only pending-update counts. Zangetsu reuses SourcesState's own
    // installed-vs-manifest comparison (same result the Zangetsu screen shows);
    // CS/Aniyomi expose an aggregate updateCount. Nothing is fetched or mutated.
    final zUpdates = SourcesState(
      installed: sl<ProviderRegistry>().getAll(),
      repos: sl<ProviderReposRegistry>().getAll(),
    ).updatableKeys.length;
    final csUpdates = showCs ? sl<CloudStreamManager>().updateCount : 0;
    final aniUpdates = showAniyomi ? sl<AniyomiManager>().updateCount : 0;
    final totalUpdates = zUpdates + csUpdates + aniUpdates;

    final total =
        zangetsuCount +
        (showCs ? csInstalled : 0) +
        (showAniyomi ? aniCount : 0);
    final ecoCount = 1 + (showCs ? 1 : 0) + (showAniyomi ? 1 : 0);

    final activeId = sl<ActiveSourceCubit>().state;
    final activeName = activeId.isEmpty ? 'None' : _activeSourceLabel(activeId);
    final activeIsCs = activeId.startsWith('cs:');
    final activeIsAni = activeId.startsWith('ani:');
    final activeIsZangetsu = activeId.isNotEmpty && !activeIsCs && !activeIsAni;

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: Text('Providers', style: AppText.title)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          _HubHeader(
            total: total,
            ecoCount: ecoCount,
            activeName: activeName,
            totalUpdates: totalUpdates,
          ),
          const SizedBox(height: 24),
          _EcoRow(
            icon: Icons.dns_rounded,
            title: 'Zangetsu',
            desc: 'Built-in JS providers',
            info: '$zangetsuCount sources',
            active: activeIsZangetsu,
            updateCount: zUpdates,
            onTap: () => open(const ZangetsuSourcesScreen()),
          ),
          if (showCs) ...[
            const SizedBox(height: 12),
            _EcoRow(
              icon: Icons.extension_outlined,
              title: 'CloudStream',
              desc: 'CloudStream extensions',
              info: '$csInstalled sources · $csRepos repo${csRepos == 1 ? '' : 's'}',
              active: activeIsCs,
              updateCount: csUpdates,
              onTap: () => open(const CloudStreamSourcesScreen()),
            ),
          ],
          if (showAniyomi) ...[
            const SizedBox(height: 12),
            _EcoRow(
              icon: Icons.movie_filter_outlined,
              title: 'Aniyomi',
              desc: 'Aniyomi extensions',
              info: '$aniCount sources',
              active: activeIsAni,
              updateCount: aniUpdates,
              onTap: () => open(const AniyomiSourcesScreen()),
            ),
          ],
        ],
      ),
    );
  }
}

/// Resolves an active-source id to its display name, mirroring the Settings
/// screen's `_activeLabel` (cs:/ani: prefixes route to their managers).
String _activeSourceLabel(String id) {
  if (id.startsWith('cs:')) {
    return sl<CloudStreamManager>().get(id)?.displayName ?? id;
  }
  if (id.startsWith('ani:')) {
    return sl<AniyomiManager>().get(id)?.displayName ?? id;
  }
  final e = sl<ProviderRegistry>().entryFor(id);
  if (e == null) return id;
  return e.displayName.isNotEmpty ? e.displayName : e.name;
}

/// Branded header — the app logo, the total source count and the currently
/// active source, so the screen opens with identity and real information.
class _HubHeader extends StatelessWidget {
  const _HubHeader({
    required this.total,
    required this.ecoCount,
    required this.activeName,
    required this.totalUpdates,
  });

  final int total;
  final int ecoCount;
  final String activeName;
  final int totalUpdates;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 54,
          height: 54,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: AppColors.surface2,
            borderRadius: BorderRadius.circular(15),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.asset('assets/icon/app_icon.png', fit: BoxFit.cover),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$total sources ready',
                style: AppText.headline.copyWith(fontSize: 18),
              ),
              const SizedBox(height: 3),
              Text(
                '$ecoCount ecosystems · Active: $activeName',
                style: AppText.caption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (totalUpdates > 0) ...[
                const SizedBox(height: 7),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.download_rounded,
                      color: AppColors.accent,
                      size: 15,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      '$totalUpdates update${totalUpdates == 1 ? '' : 's'} available',
                      style: AppText.caption.copyWith(
                        color: AppColors.accent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// One ecosystem row — monochrome icon tile, title with an optional "Active"
/// tag, a description and a source/repo count line that gains an accent
/// "· N updates" note when that ecosystem has pending updates.
class _EcoRow extends StatelessWidget {
  const _EcoRow({
    required this.icon,
    required this.title,
    required this.desc,
    required this.info,
    required this.active,
    required this.updateCount,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String desc;
  final String info;
  final bool active;
  final int updateCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.surface2,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: AppColors.textSecondary, size: 24),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            style: AppText.headline,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (active) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.accent.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              'ACTIVE',
                              style: AppText.overline.copyWith(
                                color: AppColors.accent,
                                fontWeight: FontWeight.w700,
                                fontSize: 10,
                                letterSpacing: 0.4,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(desc, style: AppText.caption),
                    const SizedBox(height: 7),
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            info,
                            style: AppText.caption.copyWith(
                              color: AppColors.textTertiary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (updateCount > 0)
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: Text(
                              '· $updateCount update${updateCount == 1 ? '' : 's'}',
                              style: AppText.caption.copyWith(
                                color: AppColors.accent,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _kChevron,
            ],
          ),
        ),
      ),
    );
  }
}

String _csSubtitle() {
  final groups = sl<CloudStreamManager>().repoGroups;
  final installed = groups.fold<int>(0, (sum, g) => sum + g.sources.length);
  return '$installed installed · ${groups.length} repo${groups.length == 1 ? '' : 's'}';
}

String _aniyomiSubtitle() {
  final installed = sl<AniyomiManager>().all.length;
  return '$installed installed';
}

// ---------------------------------------------------------------------------
// TV
// ---------------------------------------------------------------------------

class _HubTvView extends StatefulWidget {
  const _HubTvView();

  @override
  State<_HubTvView> createState() => _HubTvViewState();
}

class _HubTvViewState extends State<_HubTvView> {
  Future<void> _open(Widget screen) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => screen),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final zangetsuCount = sl<ProviderRegistry>().getAll().length;
    final showCs = Platform.isAndroid;
    final showAniyomi = Platform.isAndroid;
    var autofocusAssigned = false;

    Widget row({
      required IconData icon,
      required String title,
      required String subtitle,
      required Color tint,
      required VoidCallback onTap,
    }) {
      final autofocus = !autofocusAssigned;
      autofocusAssigned = true;
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TvFocusable(
          scale: 1.02,
          autofocus: autofocus,
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: tint.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: tint, size: 22),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title, style: AppText.headline),
                      const SizedBox(height: 3),
                      Text(subtitle, style: AppText.caption),
                    ],
                  ),
                ),
                _kChevron,
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(48, 24, 48, 16),
                  child: Text('Providers', style: AppText.largeTitle),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(40, 0, 40, 48),
                    children: [
                      row(
                        icon: Icons.dns_rounded,
                        title: 'Zangetsu providers',
                        subtitle: '$zangetsuCount installed',
                        tint: AppColors.accent,
                        onTap: () => _open(const ZangetsuSourcesScreen()),
                      ),
                      if (showCs)
                        row(
                          icon: Icons.extension_outlined,
                          title: 'CloudStream',
                          subtitle: _csSubtitle(),
                          tint: _csBlue,
                          onTap: () => _open(const CloudStreamSourcesScreen()),
                        ),
                      if (showAniyomi)
                        row(
                          icon: Icons.movie_filter_outlined,
                          title: 'Aniyomi',
                          subtitle: _aniyomiSubtitle(),
                          tint: _aniGreen,
                          onTap: () => _open(const AniyomiSourcesScreen()),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Positioned(
            top: 8,
            left: 8,
            child: SafeArea(child: TvBackButton()),
          ),
        ],
      ),
    );
  }
}
