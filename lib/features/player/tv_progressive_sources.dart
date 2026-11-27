import 'dart:async';

import '../../core/models/video_source.dart';

/// Keeps an Android TV source sweep alive after its first playable result.
/// The player starts from [first]; its Sources menu reads [latest] later.
class TvProgressiveSources {
  TvProgressiveSources(this._resolve, {this.poll});

  final Stream<List<VideoSource>> Function(String url, String category)
  _resolve;
  final Future<List<VideoSource>> Function(String url, String category)? poll;
  final _prefetched = <(String, String)>{};
  final _lookups = <(String, String), _SourceLookup>{};

  _SourceLookup _for(String url, String category) => _lookups.putIfAbsent((
    url,
    category,
  ), () => _SourceLookup(_resolve(url, category)));

  Future<List<VideoSource>> first(String url, String category) =>
      _for(url, category).first;

  Future<List<VideoSource>> latest(String url, String category) async {
    final lookup = _for(url, category);
    await lookup.first;
    if (poll != null) {
      try {
        lookup.addMirrors(await poll!(url, category));
      } catch (_) {
        // The picker still shows the sources already resolved.
      }
    }
    return lookup.latest;
  }

  /// Merges [sources] (e.g. a fresh resolve after expired links) into the
  /// mirrors [latest] returns. A link with a known url replaces the old entry.
  void addMirrors(String url, String category, List<VideoSource> sources) =>
      _for(url, category).addMirrors(sources);

  Future<void> prefetch(String url, String category) async {
    final key = (url, category);
    if (!_prefetched.add(key)) return;
    final lookup = _for(url, category);
    try {
      if ((await lookup.first).isNotEmpty) return;
    } catch (_) {
      // A speculative lookup must never prevent an explicit retry.
    }
    if (identical(_lookups[key], lookup)) {
      _lookups.remove(key);
      await lookup.dispose();
    }
  }

  Future<void> dispose() async {
    await Future.wait(_lookups.values.map((lookup) => lookup.dispose()));
    _lookups.clear();
    _prefetched.clear();
  }
}

class _SourceLookup {
  _SourceLookup(Stream<List<VideoSource>> stream) {
    _subscription = stream.listen(
      (sources) {
        _arrived = sources;
        if (!_first.isCompleted) _first.complete(sources);
      },
      onError: (Object error, StackTrace stack) {
        if (!_first.isCompleted) _first.completeError(error, stack);
      },
      onDone: () {
        if (!_first.isCompleted) _first.complete(const []);
      },
    );
  }

  final _first = Completer<List<VideoSource>>();
  late final StreamSubscription<List<VideoSource>> _subscription;
  List<VideoSource> _arrived = const [];
  List<VideoSource> _mirrors = const [];

  Future<List<VideoSource>> get first => _first.future;

  void addMirrors(List<VideoSource> sources) {
    final byUrl = <String, VideoSource>{
      for (final source in _mirrors) source.url: source,
      for (final source in sources) source.url: source,
    };
    _mirrors = byUrl.values.toList();
  }

  List<VideoSource> get latest {
    final byUrl = <String, VideoSource>{
      for (final source in _arrived) source.url: source,
      for (final source in _mirrors) source.url: source,
    };
    return byUrl.values.toList();
  }

  Future<void> dispose() async {
    if (!_first.isCompleted) _first.complete(const []);
    await _subscription.cancel();
  }
}
