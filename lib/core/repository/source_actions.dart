import 'package:flutter/material.dart';

import '../aniyomi/aniyomi_extension_service.dart';
import '../mihon/mihon_extension_service.dart';
import '../provider/cloudstream_provider.dart';
import '../../features/sources/source_settings_screen.dart';

/// Whether [id] has its own settings screen to open. Aniyomi (`ani:`) and
/// Mihon (`mihon:`) report this at runtime through their extension
/// services; CloudStream (`cs:`) via [csPluginHasSettings]. Anything else
/// (plain JS providers) has none.
///
/// Shared so a "source settings" control — the wrong-title sheet's per-row
/// action, BrowseSourceScreen's overflow menu — gates on the same check
/// rather than each re-deriving the id-prefix routing.
Future<bool> hasSourceSettings(String id) {
  if (id.startsWith('ani:')) {
    final raw = int.tryParse(id.substring(4));
    return raw == null
        ? Future.value(false)
        : AniyomiExtensionService().hasSourceSettings(raw);
  }
  if (id.startsWith('mihon:')) {
    final raw = int.tryParse(id.substring(6));
    return raw == null
        ? Future.value(false)
        : MihonExtensionService().hasSourceSettings(raw);
  }
  if (id.startsWith('cs:')) return csPluginHasSettings(id.substring(3));
  return Future.value(false);
}

/// Opens [id]'s own settings screen. [name] pre-fills the CloudStream path's
/// AppBar title (matching [SourceSettingsScreen.displayName]).
Future<void> openSourceSettings(
  BuildContext context,
  String id,
  String name,
) async {
  if (id.startsWith('ani:')) {
    final raw = int.tryParse(id.substring(4));
    if (raw != null) await AniyomiExtensionService().openSourceSettings(raw);
    return;
  }
  if (id.startsWith('mihon:')) {
    final raw = int.tryParse(id.substring(6));
    if (raw != null) await MihonExtensionService().openSourceSettings(raw);
    return;
  }
  if (id.startsWith('cs:') && context.mounted) {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            SourceSettingsScreen(sourceId: id, repoUrl: '', displayName: name),
      ),
    );
  }
}

/// Whether [id]'s source can have its OWN saved state (settings + cookies)
/// reset. Only CloudStream (`cs:`) plugins keep state reachable this way —
/// they persist through a shared DataStore SharedPreferences file, folder-
/// keyed by the plugin's own name, plus site cookies via WebView's
/// CookieManager (see PluginHost.resetPluginData, native side). Mihon and
/// Aniyomi extensions have no equivalent per-source store we can reach
/// without a much broader native change, so they don't offer this action.
bool canResetSourceData(String id) => id.startsWith('cs:');

/// Clears [id]'s own stored state — its DataStore settings and its site's
/// cookies — without touching anything else. Returns true only if the native
/// side reports something was actually cleared. A no-op (false) for any
/// source [canResetSourceData] says no to.
Future<bool> resetSourceData(String id) {
  if (id.startsWith('cs:')) return csPluginResetData(id.substring(3));
  return Future.value(false);
}
