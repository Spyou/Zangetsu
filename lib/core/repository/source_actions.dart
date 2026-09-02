import 'package:flutter/material.dart';

import '../aniyomi/aniyomi_extension_service.dart';
import '../di/injector.dart';
import '../mihon/mihon_extension_service.dart';
import '../provider/cloudstream_provider.dart';
import '../zmode/zmode_ids.dart';
import 'source_repository.dart';
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

/// The site to open for [sourceId], or null when there is none.
///
/// [SourceRepository.baseUrlFor] answers for every ecosystem and returns an
/// empty string when it cannot; this is the null-typed twin the callers gate
/// on. The metadata catalogue is excluded outright — it is a catalogue, not a
/// provider with an account behind it.
String? webViewUrlFor(String sourceId) {
  if (sourceId == ZmodeIds.sourceId) return null;
  // Unregistered only in a unit test that never bootstrapped the injector —
  // in the running app SourceRepository is always up by the time a screen
  // can call this. Same guard main.dart/injector.dart use elsewhere for a
  // dependency that may not exist yet.
  if (!sl.isRegistered<SourceRepository>()) return null;
  final url = sl<SourceRepository>().baseUrlFor(sourceId).trim();
  return url.isEmpty ? null : url;
}

/// Opens the source's site in the in-app browser so the user can sign in.
///
/// Silent no-op when the source has no site — the callers hide the action in
/// that case, and a second guard here means a new caller cannot open a blank
/// screen by forgetting to check.
Future<void> openSourceWebView(BuildContext context, String sourceId) async {
  final url = webViewUrlFor(sourceId);
  if (url == null) return;
  await MihonExtensionService.openSourceWebView(
    url,
    title: sl<SourceRepository>().displayName(sourceId),
  );
}
