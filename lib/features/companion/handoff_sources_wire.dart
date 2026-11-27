import 'dart:convert';

import '../../core/models/video_source.dart';

/// Wire format of the compact 'handoffSources' reply (TV -> phone). A reply
/// without a 'format' field is the old one: every source in full.
const handoffSourcesFormat = 2;

/// How many links the TV sends per 'handoffSources' reply; the phone asks
/// for the next ones (by 'offset') only when all sent ones fail.
const handoffSourcesPageSize = 5;

/// One page of TV links for 'Continue on phone', read from either format.
class HandoffSourcesPage {
  /// Creates a page of [sources]; [nextOffset] is set when the TV has more.
  const HandoffSourcesPage(this.sources, {this.nextOffset, this.total});

  /// The links in this page, in the TV's preference order.
  final List<VideoSource> sources;

  /// Where the next page starts, or null when this was the last one.
  final int? nextOffset;

  /// How many links the TV has for the episode in all, when it said so.
  final int? total;

  /// True when the TV holds more links after this page.
  bool get more => nextOffset != null;
}

/// Packs [page] for the wire: subtitles and header sets go once into shared
/// tables, and each source names the entries it uses by index. A source that
/// uses the whole subtitle table, in order, carries no subtitle list at all.
/// [next] is where the following page starts (null when this is the last
/// one) and [total] the number of links the TV has.
Map<String, dynamic> compactHandoffSources(
  List<VideoSource> page, {
  int? next,
  int? total,
}) {
  final subtitles = <Map<String, dynamic>>[];
  final subtitleIndex = <String, int>{};
  final headers = <Map<String, String>>[];
  final headerIndex = <String, int>{};
  final perSource = <List<int>>[];
  for (final s in page) {
    perSource.add([
      for (final t in s.subtitles)
        subtitleIndex.putIfAbsent(jsonEncode([t.url, t.lang, t.label]), () {
          subtitles.add(_withoutNulls(t.toJson()));
          return subtitles.length - 1;
        }),
    ]);
  }
  final sources = <Map<String, dynamic>>[];
  for (var i = 0; i < page.length; i++) {
    final s = page[i];
    final json = _withoutNulls(s.toJson())
      ..remove('subtitles')
      ..remove('headers');
    final used = perSource[i];
    var whole = used.length == subtitles.length;
    for (var j = 0; whole && j < used.length; j++) {
      whole = used[j] == j;
    }
    if (!whole) json['subs'] = used;
    final h = s.headers;
    if (h != null) {
      json['h'] = headerIndex.putIfAbsent(jsonEncode(_sorted(h)), () {
        headers.add(h);
        return headers.length - 1;
      });
    }
    sources.add(json);
  }
  return {
    'format': handoffSourcesFormat,
    'sources': sources,
    if (subtitles.isNotEmpty) 'subtitles': subtitles,
    if (headers.isNotEmpty) 'headers': headers,
    'more': next != null,
    'next': ?next,
    'total': ?total,
  };
}

/// Reads a 'handoffSources' reply in either format back into [VideoSource]s.
/// Subtitles that differ only by default flag or format are read as the
/// first one the TV listed, as the TV deduplicates them by url, lang, label.
HandoffSourcesPage readHandoffSources(Map<String, dynamic> reply) {
  final raw = reply['sources'] as List? ?? const [];
  if (reply['format'] == null) {
    return HandoffSourcesPage([
      for (final e in raw)
        VideoSource.fromJson(Map<String, dynamic>.from(e as Map)),
    ]);
  }
  final subtitles = (reply['subtitles'] as List? ?? const [])
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();
  final headers = (reply['headers'] as List? ?? const [])
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();
  final out = <VideoSource>[];
  for (final e in raw) {
    final json = Map<String, dynamic>.from(e as Map);
    final subs = json.remove('subs') as List?;
    final h = json.remove('h') as num?;
    json['subtitles'] = subs == null
        ? subtitles
        : [for (final i in subs) subtitles[(i as num).toInt()]];
    if (h != null) json['headers'] = headers[h.toInt()];
    out.add(VideoSource.fromJson(json));
  }
  return HandoffSourcesPage(
    out,
    nextOffset: reply['more'] == true ? (reply['next'] as num?)?.toInt() : null,
    total: (reply['total'] as num?)?.toInt(),
  );
}

/// [json] without its null values, which the reader restores as defaults.
Map<String, dynamic> _withoutNulls(Map<String, dynamic> json) =>
    Map.of(json)..removeWhere((_, v) => v == null);

/// [headers] as a key-sorted list, so equal header sets compare equal.
List<List<String>> _sorted(Map<String, String> headers) =>
    (headers.entries.map((e) => [e.key, e.value]).toList()
      ..sort((a, b) => a[0].compareTo(b[0])));
