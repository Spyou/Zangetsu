import 'aniyomi_repo.dart';

/// One available update for an installed Aniyomi extension package.
///
/// Mirrors CloudStream's `CsUpdate`. Comparison is by integer [availableCode]
/// vs the installed versionCode; [availableVersion] is the human versionName
/// shown on the Update button. [entry] carries the repo entry (with `apkUrl`)
/// used to apply the update via the existing install flow.
class AniyomiUpdate {
  const AniyomiUpdate({
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
