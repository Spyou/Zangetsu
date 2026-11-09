import 'dart:async';
import 'dart:collection';

import 'package:zangetsu_source_bridge/stremio.dart';

import 'stremio_manager.dart';
import 'stremio_ref.dart';

/// One playable row inside an addon group, carrying the complete stream so the
/// selected response is not resolved again.
class StremioLinkChoice {
  const StremioLinkChoice({
    required this.installationId,
    required this.ref,
    required this.stream,
    required this.label,
    this.inline = false,
  });

  final String installationId;
  final StremioRef ref;
  final StremioStream stream;
  final String label;
  final bool inline;
}

enum StremioLinkGroupState { pending, ready, empty, error, stale }

class StremioLinkGroup {
  const StremioLinkGroup({
    required this.installation,
    this.choices = const [],
    this.state = StremioLinkGroupState.pending,
    this.error,
  });

  final StremioInstallation installation;
  final List<StremioLinkChoice> choices;
  final StremioLinkGroupState state;
  final String? error;

  bool get hasPlayable => choices.isNotEmpty;
}

/// One sheet's link collection. Owns the four-active-request cap and makes a
/// disposed session unable to emit or start queued work.
class StremioLinkSession {
  StremioLinkSession._(
    this._manager,
    this._ref, {
    required List<StremioStream> inlineStreams,
    required this.activeLimit,
  }) {
    final origin = _manager.byId(_ref.installationId);
    final eligible = _manager.enabled.where(
      (i) => i.supports('stream') && i.accepts(_ref.type, _ref.itemId),
    );
    final list = [...eligible];
    if (origin != null &&
        origin.enabled &&
        inlineStreams.isNotEmpty &&
        !list.any((i) => i.id == origin.id)) {
      list.insert(0, origin);
    }
    for (final installation in list) {
      _revisions[installation.id] = installation.revision;
      _groups[installation.id] = StremioLinkGroup(installation: installation);
      final isOrigin = installation.id == _ref.installationId;
      if (isOrigin && inlineStreams.isNotEmpty) {
        final choices = _choices(installation, inlineStreams, inline: true);
        _inline[installation.id] = choices;
        _groups[installation.id] = StremioLinkGroup(
          installation: installation,
          choices: choices,
          state: choices.isEmpty
              ? StremioLinkGroupState.empty
              : StremioLinkGroupState.ready,
        );
      }
      if (installation.supports('stream')) {
        _queue.add(installation);
      }
    }
    scheduleMicrotask(() {
      if (_disposed) return;
      for (final group in _groups.values) {
        if (group.hasPlayable) _controller.add(group);
      }
      _pump();
    });
  }

  static StremioLinkSession start(
    StremioManager manager,
    StremioRef ref, {
    List<StremioStream> inlineStreams = const [],
    int activeLimit = 4,
  }) {
    return StremioLinkSession._(
      manager,
      ref,
      inlineStreams: inlineStreams,
      activeLimit: activeLimit,
    );
  }

  final StremioManager _manager;
  final StremioRef _ref;
  final int activeLimit;
  final LinkedHashMap<String, StremioLinkGroup> _groups = LinkedHashMap();
  final Map<String, int> _revisions = {};
  final Map<String, List<StremioLinkChoice>> _inline = {};
  final List<StremioInstallation> _queue = [];
  final StreamController<StremioLinkGroup> _controller =
      StreamController<StremioLinkGroup>();
  final Completer<void> _done = Completer<void>();
  var _active = 0;
  var _disposed = false;

  Stream<StremioLinkGroup> get groups => _controller.stream;

  List<StremioLinkGroup> get currentGroups =>
      List<StremioLinkGroup>.unmodifiable(_groups.values);

  Future<void> get done => _done.future;

  bool isCurrent(StremioLinkChoice choice) {
    final current = _manager.byId(choice.installationId);
    return !_disposed &&
        current != null &&
        current.enabled &&
        current.revision == _revisions[choice.installationId];
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _queue.clear();
    if (!_done.isCompleted) _done.complete();
    _controller.close();
  }

  void _pump() {
    while (!_disposed && _active < activeLimit && _queue.isNotEmpty) {
      final installation = _queue.removeAt(0);
      _active++;
      unawaited(_run(installation));
    }
    _finishIfIdle();
  }

  Future<void> _run(StremioInstallation installation) async {
    final revision = _revisions[installation.id]!;
    try {
      final streams = await _manager.streams(
        installation.id,
        type: _ref.type,
        itemId: _ref.requestId,
      );
      if (_disposed) return;
      final current = _manager.byId(installation.id);
      if (current == null || !current.enabled || current.revision != revision) {
        _emit(
          StremioLinkGroup(
            installation: installation,
            state: StremioLinkGroupState.stale,
            error: 'Addon changed — reopen the links',
          ),
        );
        return;
      }
      final choices = _merge(installation.id, _choices(installation, streams));
      _emit(
        StremioLinkGroup(
          installation: installation,
          choices: choices,
          state: choices.isEmpty
              ? StremioLinkGroupState.empty
              : StremioLinkGroupState.ready,
        ),
      );
    } on StremioFailure catch (error) {
      if (_disposed) return;
      _emit(
        StremioLinkGroup(
          installation: installation,
          state: StremioLinkGroupState.error,
          error: error.message,
        ),
      );
    } catch (_) {
      if (_disposed) return;
      _emit(
        StremioLinkGroup(
          installation: installation,
          state: StremioLinkGroupState.error,
          error: 'Addon failed',
        ),
      );
    } finally {
      _active--;
      if (!_disposed) _pump();
    }
  }

  List<StremioLinkChoice> _merge(
    String installationId,
    List<StremioLinkChoice> fetched,
  ) {
    final inline = _inline[installationId];
    if (inline == null || inline.isEmpty) return fetched;
    final seen = <String>{};
    return List<StremioLinkChoice>.unmodifiable([
      for (final choice in [...inline, ...fetched])
        if (seen.add(_dedupeKey(choice.stream))) choice,
    ]);
  }

  List<StremioLinkChoice> _choices(
    StremioInstallation installation,
    List<StremioStream> streams, {
    bool inline = false,
  }) {
    final seen = <String>{};
    final choices = <StremioLinkChoice>[];
    for (final stream in streams) {
      if (!stream.isPlayable) continue;
      final key = _dedupeKey(stream);
      if (!seen.add(key)) continue;
      choices.add(
        StremioLinkChoice(
          installationId: installation.id,
          ref: _ref,
          stream: stream,
          label: _label(stream),
          inline: inline,
        ),
      );
    }
    return List<StremioLinkChoice>.unmodifiable(choices);
  }

  static String _dedupeKey(StremioStream stream) {
    final headers = stream.headers.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return [
      stream.kind.name,
      stream.url ?? '',
      stream.infoHash ?? '',
      stream.fileIndex ?? '',
      headers.map((e) => '${e.key}=${e.value}').join('&'),
      stream.subtitles.map((s) => s.url).join(','),
    ].join('|');
  }

  static String _label(StremioStream stream) {
    final parts = [
      if (stream.name != null && stream.name!.isNotEmpty) stream.name!,
      if (stream.description != null && stream.description!.isNotEmpty)
        stream.description!,
    ];
    return parts.isEmpty ? 'Stream' : parts.join(' · ');
  }

  void _emit(StremioLinkGroup group) {
    if (_disposed) return;
    _groups[group.installation.id] = group;
    _controller.add(group);
    _finishIfIdle();
  }

  void _finishIfIdle() {
    if (_disposed || _done.isCompleted) return;
    if (_active == 0 && _queue.isEmpty) _done.complete();
  }
}
