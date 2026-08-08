import '../aniyomi/aniyomi_repo.dart';

/// One available update for an installed Mihon manga extension package.
///
/// Structural twin of [AniyomiUpdate] (`lib/core/aniyomi/aniyomi_update.dart`) —
/// duplicated per spec Decision 3 rather than shared. [entry] is typed
/// [AniyomiRepoEntry] because that type carries everything the install needs
/// and is reused unchanged — the Mihon index has its own shape, but
/// `MihonRepo` (`mihon_repo.dart`) maps it onto this same entry type.
/// Comparison is by integer [availableCode]
/// vs the installed versionCode; [availableVersion] is the human versionName
/// shown on the Update button.
class MihonUpdate {
  const MihonUpdate({
    required this.pkg,
    required this.name,
    required this.installedCode,
    required this.availableCode,
    required this.availableVersion,
    required this.entry,
  });

  final String pkg;
  final String name;
  final int installedCode;
  final int availableCode;
  final String availableVersion;
  final AniyomiRepoEntry entry;
}
