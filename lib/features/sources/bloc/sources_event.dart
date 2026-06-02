import 'package:equatable/equatable.dart';

import '../../../core/provider/provider_repo_registry.dart';

abstract class SourcesEvent extends Equatable {
  const SourcesEvent();
  @override
  List<Object?> get props => [];
}

/// First load — read both boxes and emit a ready state.
class SourcesStarted extends SourcesEvent {
  const SourcesStarted();
}

/// Re-read both boxes and emit. Fired internally whenever either Hive box
/// changes (install/uninstall/enable from any caller, repo add/remove).
class SourcesRefreshed extends SourcesEvent {
  const SourcesRefreshed();
}

/// Install [source] from [repo] into the registry.
class SourceInstalled extends SourcesEvent {
  const SourceInstalled({required this.repo, required this.source});
  final ProviderRepo repo;
  final RepoSource source;
  @override
  List<Object?> get props => [repo.url, source.id];
}

/// Re-install the source at composite [key] from its repo's CURRENT manifest,
/// forcing a fresh JS download (an "Update"). The bloc resolves the repo +
/// source from the key, so it works from either tab.
class SourceUpdated extends SourcesEvent {
  const SourceUpdated(this.key);
  final String key;
  @override
  List<Object?> get props => [key];
}

/// Update every installed source in [repoUrl] that has a newer manifest
/// version ("Update all").
class RepoUpdated extends SourcesEvent {
  const RepoUpdated(this.repoUrl);
  final String repoUrl;
  @override
  List<Object?> get props => [repoUrl];
}

/// Re-fetch a repo's manifest so newer source versions become visible
/// ("Check for updates").
class RepoRefreshed extends SourcesEvent {
  const RepoRefreshed(this.repoUrl);
  final String repoUrl;
  @override
  List<Object?> get props => [repoUrl];
}

/// Remove the installed entry at composite [key].
class SourceUninstalled extends SourcesEvent {
  const SourceUninstalled(this.key, {this.displayName});
  final String key;

  /// Name to show in the confirmation snackbar.
  final String? displayName;
  @override
  List<Object?> get props => [key, displayName];
}

/// Flip the enabled flag at composite [key].
class SourceEnabledToggled extends SourcesEvent {
  const SourceEnabledToggled(this.key, {required this.enabled});
  final String key;
  final bool enabled;
  @override
  List<Object?> get props => [key, enabled];
}

/// Fetch + cache a repo manifest from [url], optionally renaming it.
class RepoAdded extends SourcesEvent {
  const RepoAdded(this.url, {this.customName});
  final String url;
  final String? customName;
  @override
  List<Object?> get props => [url, customName];
}

/// Remove a tracked repo (installed sources stay installed).
class RepoRemoved extends SourcesEvent {
  const RepoRemoved(this.url, {this.displayName});
  final String url;
  final String? displayName;
  @override
  List<Object?> get props => [url, displayName];
}

/// Internal: surface a transient snackbar notice. Dispatched by the bloc
/// itself (e.g. after the imperative [SourcesBloc.addRepo] succeeds), not
/// directly by the UI.
class SourcesNoticeRequested extends SourcesEvent {
  const SourcesNoticeRequested(this.message);
  final String message;
  @override
  List<Object?> get props => [message];
}
