import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../../core/app_config.dart';
import '../../core/di/injector.dart';
import '../../core/provider/provider_downloader.dart';
import '../../core/provider/provider_registry.dart';
import '../../core/state/active_source_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/settings_widgets.dart';
import '../sources/sources_screen.dart';

/// Top-level Settings screen — a grouped list of cards mirroring the
/// iOS Settings look in our dark/coral language.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  ActiveSourceCubit get _active => context.read<ActiveSourceCubit>();

  ProviderRegistry get _registry => sl<ProviderRegistry>();

  Future<void> _push(Widget screen) => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => screen));

  String _activeLabel(String activeId) {
    final entry = _registry.entryFor(activeId);
    if (entry == null) return activeId;
    return entry.displayName.isNotEmpty ? entry.displayName : entry.name;
  }

  /// Bottom sheet listing enabled providers; sets the active source on the
  /// [ActiveSourceCubit].
  Future<void> _pickActiveSource() async {
    final enabled = _registry.getAll().where((e) => e.enabled).toList()
      ..sort((a, b) {
        final an = a.displayName.isNotEmpty ? a.displayName : a.name;
        final bn = b.displayName.isNotEmpty ? b.displayName : b.name;
        return an.toLowerCase().compareTo(bn.toLowerCase());
      });
    final currentId = _active.state;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.textTertiary.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Active source', style: AppText.headline),
              ),
            ),
            const Divider(color: AppColors.hairline, height: 1),
            if (enabled.isEmpty)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text('No enabled sources', style: AppText.body),
              )
            else
              ...enabled.map((e) {
                final label = e.displayName.isNotEmpty ? e.displayName : e.name;
                final isActive = e.name == currentId;
                return ListTile(
                  onTap: () => Navigator.pop(ctx, e.name),
                  title: Text(
                    label,
                    style: AppText.body.copyWith(color: AppColors.textPrimary),
                  ),
                  trailing: isActive
                      ? const Icon(Icons.check, color: AppColors.accent)
                      : null,
                );
              }),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked != null && picked != currentId) {
      _active.setSource(picked);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabledCount = _registry.getAll().where((e) => e.enabled).length;
    final activeId = context.watch<ActiveSourceCubit>().state;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Text('Settings', style: AppText.largeTitle),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(top: 4, bottom: 24),
                children: [
                  SettingsCard(
                    children: [
                      SettingsTile(
                        icon: Icons.dns_rounded,
                        title: 'Sources',
                        subtitle: '$enabledCount enabled',
                        onTap: () async {
                          await _push(const SourcesScreen());
                          if (mounted) setState(() {});
                        },
                      ),
                      SettingsTile(
                        icon: Icons.swap_horiz_rounded,
                        title: 'Active source',
                        subtitle: _activeLabel(activeId),
                        onTap: _pickActiveSource,
                      ),
                    ],
                  ),
                  SettingsCard(
                    children: [
                      SettingsTile(
                        icon: Icons.sd_storage_outlined,
                        title: 'Storage',
                        onTap: () => _push(const StorageSettingsScreen()),
                      ),
                    ],
                  ),
                  SettingsCard(
                    children: [
                      SettingsTile(
                        icon: Icons.info_outline_rounded,
                        title: 'About',
                        subtitle: 'v$kAppVersion',
                        onTap: () => _push(const AboutSettingsScreen()),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// App version string. Kept here so the About screen and the Settings
/// list share a single source.
const String kAppVersion = '1.0.0';

// ---------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------

class StorageSettingsScreen extends StatelessWidget {
  const StorageSettingsScreen({super.key});

  Future<void> _clearImageCache(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    try {
      await DefaultCacheManager().emptyCache();
    } catch (_) {
      // Best-effort — clearing the live image cache above is the part
      // that matters for freeing memory immediately.
    }
    messenger.showSnackBar(
      const SnackBar(content: Text('Image cache cleared')),
    );
  }

  Future<void> _clearProviderCache(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    await sl<ProviderDownloader>().clear();
    messenger.showSnackBar(
      const SnackBar(content: Text('Provider cache cleared')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: Text('Storage', style: AppText.title)),
      body: ListView(
        padding: const EdgeInsets.only(top: 8),
        children: [
          SettingsCard(
            children: [
              SettingsTile(
                icon: Icons.image_outlined,
                title: 'Clear image cache',
                onTap: () => _clearImageCache(context),
              ),
              SettingsTile(
                icon: Icons.cleaning_services_outlined,
                title: 'Clear provider cache',
                subtitle: 'Cached source .js files',
                onTap: () => _clearProviderCache(context),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// About
// ---------------------------------------------------------------------------

class AboutSettingsScreen extends StatelessWidget {
  const AboutSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: Text('About', style: AppText.title)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
        children: [
          Center(
            child: Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AppColors.accentSoft,
                borderRadius: BorderRadius.circular(18),
              ),
              alignment: Alignment.center,
              child: const Icon(
                Icons.play_circle_fill_rounded,
                color: AppColors.accent,
                size: 40,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Center(child: Text(kAppName, style: AppText.title)),
          const SizedBox(height: 4),
          Center(child: Text('Version $kAppVersion', style: AppText.caption)),
          const SizedBox(height: 24),
          Text(
            'A community-driven video app. Install sources from repos to '
            'browse and stream — anime, movies and TV — all in one '
            'place, in a clean dark interface.',
            style: AppText.body,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
