import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/provider/cloudstream_provider.dart';
import '../../core/provider/provider_manager.dart';
import '../../core/provider/provider_registry.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_back_button.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/ui/settings_widgets.dart';
import 'aniyomi_sources_screen.dart';
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

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: Text('Providers', style: AppText.title)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(0, 12, 0, 96),
        children: [
          SettingsCard(
            children: [
              SettingsTile(
                icon: Icons.dns_rounded,
                title: 'Zangetsu providers',
                subtitle: '$zangetsuCount installed',
                onTap: () => open(const ZangetsuSourcesScreen()),
              ),
              if (showCs)
                SettingsTile(
                  icon: Icons.extension_outlined,
                  title: 'CloudStream',
                  subtitle: _csSubtitle(),
                  onTap: () => open(const CloudStreamSourcesScreen()),
                ),
              if (showAniyomi)
                SettingsTile(
                  icon: Icons.movie_filter_outlined,
                  title: 'Aniyomi',
                  subtitle: _aniyomiSubtitle(),
                  onTap: () => open(const AniyomiSourcesScreen()),
                ),
            ],
          ),
        ],
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
