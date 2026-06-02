import 'package:equatable/equatable.dart';

import '../../../core/provider/provider_registry.dart';
import '../../../core/provider/provider_repo_registry.dart';

enum SourcesStatus { initial, ready }

/// Immutable snapshot for the Sources screen.
///
/// Holds the full installed registry ([installed]) and the tracked repos
/// ([repos]). Both are re-read straight from Hive whenever either box
/// changes, so the Installed and Repos tabs stay in sync no matter who
/// mutated the registry.
class SourcesState extends Equatable {
  const SourcesState({
    this.status = SourcesStatus.initial,
    this.installed = const [],
    this.repos = const [],
    this.notice,
    this.noticeSeq = 0,
  });

  final SourcesStatus status;
  final List<ProviderRegistryEntry> installed;
  final List<ProviderRepo> repos;

  /// Transient user-facing notice (e.g. "Installed X"). Paired with
  /// [noticeSeq] so the UI's BlocListener can detect repeats — two
  /// identical messages still need to fire two snackbars, which would
  /// otherwise be deduped by Equatable.
  final String? notice;
  final int noticeSeq;

  /// Composite keys (`providerKey(repoUrl, sourceId)`) of every installed
  /// entry — drives the Repos tab's Install / Installed pill state.
  Set<String> get installedKeys => installed
      .map((e) => ProviderRegistry.providerKey(e.originRepoUrl, e.name))
      .toSet();

  /// Installed version per composite key.
  Map<String, String> get installedVersions => {
    for (final e in installed)
      ProviderRegistry.providerKey(e.originRepoUrl, e.name): e.version,
  };

  /// The latest manifest version advertised per composite key, across all
  /// tracked repos.
  Map<String, String> get manifestVersions => {
    for (final repo in repos)
      for (final s in repo.sources)
        ProviderRegistry.providerKey(repo.url, s.id): s.version,
  };

  /// Whether the installed source at [key] has a newer version available in
  /// its repo's current manifest.
  bool hasUpdate(String key) {
    final installedV = installedVersions[key];
    final manifestV = manifestVersions[key];
    if (installedV == null || manifestV == null) return false;
    return isProviderVersionNewer(manifestV, installedV);
  }

  /// Composite keys (in any repo) that have an update available.
  Set<String> get updatableKeys =>
      installedKeys.where(hasUpdate).toSet();

  SourcesState copyWith({
    SourcesStatus? status,
    List<ProviderRegistryEntry>? installed,
    List<ProviderRepo>? repos,
    String? notice,
    int? noticeSeq,
  }) => SourcesState(
    status: status ?? this.status,
    installed: installed ?? this.installed,
    repos: repos ?? this.repos,
    notice: notice ?? this.notice,
    noticeSeq: noticeSeq ?? this.noticeSeq,
  );

  @override
  List<Object?> get props => [
    status,
    // ProviderRegistryEntry / ProviderRepo aren't Equatable, so compare
    // on their serialisable shape to get value equality for rebuilds.
    installed.map((e) => e.toJson()).toList(),
    repos.map((r) => r.toJson()).toList(),
    notice,
    noticeSeq,
  ];
}
