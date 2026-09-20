import 'package:flutter/material.dart';

import 'aniyomi_sources_screen.dart';
import 'cloudstream_sources_screen.dart';
import 'lnreader_sources_screen.dart';
import 'mihon_sources_screen.dart';
import 'zangetsu_sources_screen.dart';

/// Opens the Sources screen that owns [sourceId], so the user can uninstall it
/// where uninstalling already lives.
///
/// Deliberately a ROUTE and not an uninstall. Removing a source is ~25 lines of
/// ecosystem-specific work — delete the APK, drop the Hive entry, detach from
/// the manager — written separately inside each of these screens. A second copy
/// of that, here, would be two destructive paths to keep in step, and the way
/// they would fail is silent: a leftover file on disk, or a Hive row that
/// reinstates the source on the next launch.
///
/// So this navigates. The user lands on the screen they already know, with the
/// confirm dialog they already know, and there is exactly one piece of code in
/// the app that deletes a source.
///
/// Null for an id no screen owns, so a caller can hide the action rather than
/// offer one that goes nowhere.
Widget? manageSourceScreenFor(String sourceId) {
  if (sourceId.startsWith('cs:')) return const CloudStreamSourcesScreen();
  if (sourceId.startsWith('ani:')) return const AniyomiSourcesScreen();
  if (sourceId.startsWith('mihon:')) return const MihonSourcesScreen();
  if (sourceId.startsWith('lnr:')) return const LnReaderSourcesScreen();
  // Everything else is a JS provider from the Zangetsu repo — those ids carry
  // no prefix, so this is the fallback rather than a match.
  return const ZangetsuSourcesScreen();
}

/// Whether [sourceId] can be managed at all. Z-Mode is the one that cannot:
/// it is a meta-source with nothing installed behind it.
bool canManageSource(String sourceId) =>
    sourceId.isNotEmpty && sourceId != 'zm';

/// Pushes the owning Sources screen for [sourceId].
Future<void> openManageSource(BuildContext context, String sourceId) async {
  if (!canManageSource(sourceId)) return;
  final screen = manageSourceScreenFor(sourceId);
  if (screen == null) return;
  await Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => screen));
}
