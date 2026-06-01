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
    on<SourceUninstalled>(_onUninstalled);
    on<SourceEnabledToggled>(_onEnabledToggled);
    on<RepoAdded>(_onRepoAdded);
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
      );
      _emitNotice(emit, 'Installed ${source.name}');
    } catch (e) {
      _emitNotice(emit, "Couldn't install ${source.name}: $e");
    }
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
