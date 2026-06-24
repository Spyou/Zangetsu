import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';

import '../../../core/provider/provider_registry.dart';
import '../../../core/provider/provider_repo_registry.dart';
import 'sources_event.dart';
import 'sources_state.dart';

/// Owns the data for the Sources screen — the installed registry and the
/// tracked repos.
///
/// Subscribes to BOTH Hive boxes ([ProviderRegistry.watch] and
/// [ProviderReposRegistry.watch]) in the constructor and re-emits on any
/// change, so the Installed and Repos tabs auto-update regardless of who
/// mutated the registry (including the per-source Install/Uninstall
/// buttons that call the registry directly). Subscriptions are cancelled
/// in [close].
class SourcesBloc extends Bloc<SourcesEvent, SourcesState> {
  SourcesBloc({
    required ProviderRegistry registry,
    required ProviderReposRegistry repos,
  }) : _registry = registry,
       _repos = repos,
       super(const SourcesState()) {
    on<SourcesStarted>(_onStarted);
    on<SourcesRefreshed>(_onRefreshed);
    on<SourceInstalled>(_onInstalled);
    on<SourceUpdated>(_onUpdated);
    on<RepoUpdated>(_onRepoUpdated);
    on<SourceUninstalled>(_onUninstalled);
    on<SourceEnabledToggled>(_onEnabledToggled);
    on<RepoAdded>(_onRepoAdded);
    on<RepoRefreshed>(_onRepoRefreshed);
    on<RepoRemoved>(_onRepoRemoved);
    on<SourcesNoticeRequested>(_onNoticeRequested);

    _registrySub = _registry.watch().listen((_) {
      if (!isClosed) add(const SourcesRefreshed());
    });
    _reposSub = _repos.watch().listen((_) {
      if (!isClosed) add(const SourcesRefreshed());
    });

    add(const SourcesStarted());
  }

  final ProviderRegistry _registry;
  final ProviderReposRegistry _repos;
  StreamSubscription<BoxEvent>? _registrySub;
  StreamSubscription<BoxEvent>? _reposSub;

  @override
  Future<void> close() async {
    await _registrySub?.cancel();
    await _reposSub?.cancel();
    return super.close();
  }

  SourcesState _snapshot({String? notice, int? noticeSeq}) => state.copyWith(
    status: SourcesStatus.ready,
    installed: _registry.getAll(),
    repos: _repos.getAll(),
    notice: notice,
    noticeSeq: noticeSeq,
  );

  void _onStarted(SourcesStarted event, Emitter<SourcesState> emit) {
    emit(_snapshot());
  }

  void _onRefreshed(SourcesRefreshed event, Emitter<SourcesState> emit) {
    emit(_snapshot());
  }

  Future<void> _onInstalled(
    SourceInstalled event,
    Emitter<SourcesState> emit,
  ) async {
    final source = event.source;
    final repo = event.repo;
    try {
      await _registry.install(
        sourceId: source.id,
        fileUrl: _repos.resolveFileUrl(repo, source),
        repoUrl: repo.url,
        displayName: source.name,
        version: source.version,
        // Always pull fresh JS on install: a leftover 24h Hive cache entry from
        // a prior install of this sourceId would otherwise be returned stale,
        // so a reinstall never picks up the provider's current code.
        force: true,
      );
      _emitNotice(emit, 'Installed ${source.name}');
    } catch (e) {
      _emitNotice(emit, "Couldn't install ${source.name}: $e");
    }
  }

  /// Force-reinstalls one source from its repo's current manifest.
  Future<void> _onUpdated(
    SourceUpdated event,
    Emitter<SourcesState> emit,
  ) async {
    final repoUrl = ProviderRegistry.repoUrlOf(event.key);
    final sourceId = ProviderRegistry.sourceIdOf(event.key);
    final repo = _repos.get(repoUrl);
    RepoSource? source;
    if (repo != null) {
      for (final s in repo.sources) {
        if (s.id == sourceId) {
          source = s;
          break;
        }
      }
    }
    if (repo == null || source == null) {
      _emitNotice(emit, "Couldn't find this source's repo to update");
      return;
    }
    try {
      await _registry.install(
        sourceId: source.id,
        fileUrl: _repos.resolveFileUrl(repo, source),
        repoUrl: repo.url,
        displayName: source.name,
        version: source.version,
        force: true,
      );
      _emitNotice(emit, 'Updated ${source.name} to v${source.version}');
    } catch (e) {
      _emitNotice(emit, "Couldn't update ${source.name}: $e");
    }
  }

  /// Updates every installed source in a repo that has a newer manifest version.
  Future<void> _onRepoUpdated(
    RepoUpdated event,
    Emitter<SourcesState> emit,
  ) async {
    final repo = _repos.get(event.repoUrl);
    if (repo == null) return;
    final installed = <String, ProviderRegistryEntry>{
      for (final e in _registry.getAll())
        ProviderRegistry.providerKey(e.originRepoUrl, e.name): e,
    };
    var updated = 0;
    for (final source in repo.sources) {
      final key = ProviderRegistry.providerKey(repo.url, source.id);
      final entry = installed[key];
      if (entry == null) continue;
      if (!isProviderVersionNewer(source.version, entry.version)) continue;
      try {
        await _registry.install(
          sourceId: source.id,
          fileUrl: _repos.resolveFileUrl(repo, source),
          repoUrl: repo.url,
          displayName: source.name,
          version: source.version,
          force: true,
        );
        updated++;
      } catch (_) {}
    }
    _emitNotice(
      emit,
      updated > 0
          ? 'Updated $updated source${updated == 1 ? '' : 's'} in ${repo.displayName}'
          : '${repo.displayName} is already up to date',
    );
  }

  Future<void> _onUninstalled(
    SourceUninstalled event,
    Emitter<SourcesState> emit,
  ) async {
    await _registry.uninstall(event.key);
    final name = event.displayName ?? ProviderRegistry.sourceIdOf(event.key);
    _emitNotice(emit, 'Removed $name');
  }

  Future<void> _onEnabledToggled(
    SourceEnabledToggled event,
    Emitter<SourcesState> emit,
  ) async {
    await _registry.setEnabled(event.key, event.enabled);
    // The box-watch subscription re-emits the fresh snapshot.
  }

  Future<void> _onRepoAdded(RepoAdded event, Emitter<SourcesState> emit) async {
    try {
      final repo = await _repos.fetchAndCache(
        event.url,
        customName: event.customName,
      );
      _emitNotice(emit, 'Added ${repo.displayName}');
    } on ProviderRepoException catch (e) {
      _emitNotice(emit, e.message);
    } catch (e) {
      _emitNotice(emit, e.toString());
    }
  }

  Future<void> _onRepoRefreshed(
    RepoRefreshed event,
    Emitter<SourcesState> emit,
  ) async {
    try {
      final repo = await _repos.fetchAndCache(event.repoUrl);
      // The box-watch re-emits the snapshot; surface a count of updates found.
      final installed = <String, ProviderRegistryEntry>{
        for (final e in _registry.getAll())
          ProviderRegistry.providerKey(e.originRepoUrl, e.name): e,
      };
      var updates = 0;
      for (final s in repo.sources) {
        final entry =
            installed[ProviderRegistry.providerKey(repo.url, s.id)];
        if (entry != null && isProviderVersionNewer(s.version, entry.version)) {
          updates++;
        }
      }
      _emitNotice(
        emit,
        updates > 0
            ? '$updates update${updates == 1 ? '' : 's'} available in ${repo.displayName}'
            : '${repo.displayName} is up to date',
      );
    } on ProviderRepoException catch (e) {
      _emitNotice(emit, e.message);
    } catch (e) {
      _emitNotice(emit, e.toString());
    }
  }

  /// Pull-to-refresh: re-fetch every tracked repo's manifest. Awaitable so the
  /// RefreshIndicator can spin until done.
  Future<void> refreshAllRepos() async {
    for (final repo in _repos.getAll()) {
      try {
        await _repos.fetchAndCache(repo.url);
      } catch (_) {}
    }
    if (!isClosed) add(const SourcesRefreshed());
  }

  Future<void> _onRepoRemoved(
    RepoRemoved event,
    Emitter<SourcesState> emit,
  ) async {
    await _repos.remove(event.url);
    final name = event.displayName ?? event.url;
    _emitNotice(emit, 'Removed $name');
  }

  void _onNoticeRequested(
    SourcesNoticeRequested event,
    Emitter<SourcesState> emit,
  ) {
    _emitNotice(emit, event.message);
  }

  void _emitNotice(Emitter<SourcesState> emit, String message) {
    emit(_snapshot(notice: message, noticeSeq: state.noticeSeq + 1));
  }

  /// Imperative add-repo used by the add-repo dialog, which needs the
  /// outcome inline (it shows the error in the dialog and keeps it open on
  /// failure). Returns null on success (and queues an "Added …" notice via
  /// [SourcesNoticeRequested]), or the error message on failure (no notice
  /// — the dialog renders it inline).
  Future<String?> addRepo(String url, {String? customName}) async {
    try {
      final repo = await _repos.fetchAndCache(url, customName: customName);
      if (!isClosed) add(SourcesNoticeRequested('Added ${repo.displayName}'));
      return null;
    } on ProviderRepoException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }
}
