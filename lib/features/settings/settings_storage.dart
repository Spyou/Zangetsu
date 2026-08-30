// Storage settings: cache and space used by the app.
part of 'settings_screen.dart';


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
      SnackBar(content: Text(context.l10n.imageCacheCleared)),
    );
  }

  Future<void> _clearProviderCache(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    await sl<ProviderDownloader>().clear();
    messenger.showSnackBar(
      SnackBar(content: Text(context.l10n.providerCacheCleared)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar(context.l10n.storage),
      body: ListView(
        clipBehavior: sl<AppMode>().isTv ? Clip.none : Clip.hardEdge,
        padding: const EdgeInsets.only(top: 8),
        children: [
          SettingsCard(
            children: [
              SettingsTile(
                autofocus: true,
                icon: Icons.image_outlined,
                title: context.l10n.clearImageCache,
                onTap: () => _clearImageCache(context),
              ),
              SettingsTile(
                icon: Icons.cleaning_services_outlined,
                title: context.l10n.clearProviderCache,
                subtitle: context.l10n.cachedSourceJsFiles,
                onTap: () => _clearProviderCache(context),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
