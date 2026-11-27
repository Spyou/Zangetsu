import 'apple_companion.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import '../../core/di/injector.dart';
import '../../core/models/media_item.dart';
import '../../core/models/media_detail.dart';
import '../../core/models/episode.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/repository/source_repository.dart';
import '../../core/repository/catalogue_repository.dart';
import '../../core/tv/tv_keyboard_bridge.dart';
import '../../core/zmode/zmode_ids.dart';
import '../player/tv_native_player.dart';

/// TV-side handler for phone remote catalogue requests (search, detail, play, handoff, keyboard).
///
/// The TV owns source resolution. The phone only receives display data and IDs,
/// so a paired phone can never make the TV fetch an arbitrary URL.
/// Requests arrive as JSON `{"action": ...}` maps from the native Android
/// receiver (method `request`) or from [AppleCompanion]; replies are JSON maps,
/// with `{"error": message}` on failure.
class CompanionCatalogue {
  /// Method channel to the native companion receiver (requests in, events out).
  static const channel = CompanionChannel();

  /// Last `search` results; the phone refers to them by index (`selection`).
  static List<MediaItem> _results = [];

  /// Title picked by the last `detail` request, used by `play`.
  static MediaItem? _selected;

  /// Detail loaded for [_selected].
  static MediaDetail? _detail;

  /// Episodes of [_selected]; the phone plays them by index.
  static List<Episode> _episodes = [];

  /// Bumped on every `detail`, so a stale `play` from an older detail is rejected.
  static int _detailId = 0;

  /// True while a `play` launch is running, to block a second launch.
  static bool _launching = false;

  /// What the phone says it is browsing (or "Loading ..."), shown on the TV; empty when idle.
  static final browsing = ValueNotifier<String>('');

  /// True while an `openFromPhone` request is in flight, to reject overlapping ones.
  static bool _phoneOpening = false;

  /// Registers native and Apple request dispatch plus shared playback-preference propagation.
  ///
  /// Call once at TV app start. Native `request` calls carry a JSON string and
  /// get a JSON string back; each request times out after 75 seconds.
  static void bind() {
    AppleCompanion.instance.catalogue = _handle;
    PlaybackPrefs.remoteSkipChanges.addListener(() {
      final p = sl<PlaybackPrefs>();
      unawaited(
        channel.invokeMethod<void>('receiverSkipPrefs', {
          'skipIntro': p.skipIntro,
          'megaSkip': p.megaSkip,
          'megaSkipSeconds': p.megaSkipSeconds,
        }),
      );
    });
    channel.setMethodCallHandler((call) async {
      if (call.method != 'request') throw MissingPluginException();
      try {
        final request =
            jsonDecode(call.arguments as String) as Map<String, dynamic>;
        return jsonEncode(
          await _handle(request).timeout(const Duration(seconds: 75)),
        );
      } catch (e) {
        return jsonEncode({'error': e.toString()});
      }
    });
  }

  /// Resolves allowlisted catalogue actions on the TV; replies expose IDs and display metadata.
  ///
  /// [request] must hold an `action` key; unknown actions throw a [StateError],
  /// which the caller turns into an `error` reply.
  static Future<Map<String, dynamic>> _handle(
    Map<String, dynamic> request,
  ) async {
    final repo = sl<SourceRepository>();
    switch (request['action']) {
      case 'skipSettings':
        final p = sl<PlaybackPrefs>();
        await p.setSkipIntro(request['skipIntro'] == true);
        await p.setMegaSkip(request['megaSkip'] == true);
        await p.setMegaSkipSeconds((request['megaSkipSeconds'] as num).toInt());
        return {'ok': true};
      case 'browseStatus':
        browsing.value = (request['title'] as String? ?? '').substring(
          0,
          (request['title'] as String? ?? '').length.clamp(0, 160),
        );
        return {'ok': true};
      case 'openFromPhone':
        if (_phoneOpening)
          throw StateError('The TV is already loading a title.');
        _phoneOpening = true;
        try {
          return await _openFromPhone(request);
        } finally {
          _phoneOpening = false;
        }
      case 'handoffSnapshot':
        return TvNativePlayer.companionSnapshot();
      case 'handoffSources':
        return TvNativePlayer.companionSources(
          request['session'] as int,
          request['index'] as int,
          refresh: request['refresh'] == true,
        );
      case 'handoffValidate':
        if (!TvNativePlayer.companionSessionMatches(
          request['session'] as int,
        )) {
          throw StateError(
            'The TV title changed. Choose it again before continuing.',
          );
        }
        return {'ok': true};
      case 'catalogues':
        return {
          'items': [
            for (final source in repo.loadedSources)
              {'id': source.id, 'name': source.name},
          ],
        };
      case 'search':
        final query = (request['query'] as String).trim();
        final source = request['sourceId'] as String;
        if (query.isEmpty || query.length > 200 || !repo.hasSource(source)) {
          throw StateError('Choose an installed source and enter a search');
        }
        _results = (await repo.search(
          query,
          sourceId: source,
        )).take(100).toList();
        return {
          'items': [
            for (var i = 0; i < _results.length; i++)
              {'selection': i, 'title': _results[i].title},
          ],
        };
      case 'detail':
        final index = request['selection'] as int;
        if (index < 0 || index >= _results.length) {
          throw StateError('Search again');
        }
        final selected = _results[index];
        final detail = await repo.detail(
          selected.url,
          sourceId: selected.sourceId,
        );
        final episodes = detail.episodes.isNotEmpty
            ? detail.episodes
            : await repo.episodes(selected.url, sourceId: selected.sourceId);
        _selected = selected;
        _detail = detail;
        _episodes = episodes;
        _detailId++;
        return {
          'title': detail.title,
          'detailId': '$_detailId',
          'episodes': [
            for (final ep in episodes)
              {
                'label':
                    '${ep.season == null ? '' : 'S${ep.season} · '}${ep.title}',
                'number': ep.number,
              },
          ],
        };
      case 'play':
        final selected = _selected;
        final detail = _detail;
        final index = request['index'] as int;
        if (selected == null ||
            detail == null ||
            request['detailId'] != '$_detailId' ||
            index < 0 ||
            index >= _episodes.length) {
          throw StateError('Load the title again');
        }
        if (_launching) {
          throw StateError(
            'A remote playback session is already open. Use its episode controls or close the player first.',
          );
        }
        _launching = true;
        final position = (request['positionMs'] as num?)?.toInt() ?? 0;
        if (position > 0) {
          await sl<ResumeStore>().save(
            selected.sourceId,
            selected.url,
            _episodes[index].id,
            Duration(milliseconds: position.clamp(0, 86400000)),
            Duration.zero,
          );
        }
        // Native launch returns when playback exits, so do not block the socket.
        unawaited(() async {
          try {
            final started = await TvNativePlayer.play(
              sourceId: selected.sourceId,
              episodes: List.of(_episodes),
              startIndex: index,
              resume: sl<ResumeStore>(),
              showUrl: selected.url,
              showTitle: detail.title,
              cover: detail.cover,
              coverHeaders: detail.coverHeaders,
              resolveSources: (url) =>
                  repo.sources(url, sourceId: selected.sourceId),
            );
            if (!started) {
              await channel.invokeMethod<void>(
                'playbackError',
                'The TV could not resolve or play this episode. Try another source.',
              );
            }
          } catch (e) {
            await channel.invokeMethod<void>('playbackError', e.toString());
          } finally {
            _launching = false;
          }
        }());
        return {'ok': true, 'message': 'Loading on TV'};
      case 'keyboardOpen':
      case 'keyboardInput':
      case 'keyboardSubmit':
      case 'keyboardDismiss':
        // Phone keyboard: Android native 'request' path and Apple catalogue.
        return TvKeyboardBridge.instance.handle(request);
      default:
        throw StateError('Unsupported catalogue command');
    }
  }

  /// Resolves a phone selection using TV sources rather than accepting an arbitrary playback URL.
  ///
  /// Accepts either a `zm://` canonical ID or a title plus `sourceId` that must
  /// match exactly one TV search result. Closes any open player, saves the
  /// phone's position, then starts playback without waiting for it to end.
  /// Returns `{ok, title, index}`.
  static Future<Map<String, dynamic>> _openFromPhone(
    Map<String, dynamic> request,
  ) async {
    final catalogue = sl<CatalogueRepository>();
    final sources = sl<SourceRepository>();
    final title = (request['title'] as String? ?? '').trim();
    if (title.isEmpty || title.length > 300)
      throw StateError('Choose a title before playing on TV.');
    String sourceId = request['sourceId'] as String? ?? '';
    String showUrl;
    final canonical = request['canonical'] as String?;
    if (canonical != null) {
      // Only canonical catalogue identifiers are accepted, never peer-supplied stream URLs.
      if (!RegExp(
        r'^zm://(anime|movie|tv)/(mal|al|tmdb):[0-9]+$',
      ).hasMatch(canonical)) {
        throw StateError('This title cannot be opened on TV.');
      }
      showUrl = canonical;
      sourceId = ZmodeIds.sourceId;
    } else {
      if (!sources.hasSource(sourceId))
        throw StateError(
          'Install the same source on your TV, or choose this title in Z Mode.',
        );
      final results = await sources.search(title, sourceId: sourceId);
      // Lowercase letters and digits only, so punctuation and spacing don't block a match.
      String normal(String value) =>
          value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
      final matches = results
          .where((item) => normal(item.title) == normal(title))
          .toList();
      if (matches.length != 1)
        throw StateError(
          'Select the matching title using Search TV sources in the remote.',
        );
      showUrl = matches.single.url;
    }
    final detail = await catalogue.detail(showUrl, sourceId: sourceId);
    final episodes = detail.episodes.isNotEmpty
        ? detail.episodes
        : await catalogue.episodes(showUrl, sourceId: sourceId);
    if (episodes.isEmpty)
      throw StateError('No episodes are available on this TV source.');
    final number = (request['number'] as num?)?.toDouble();
    final season = (request['season'] as num?)?.toInt();
    var index = episodes.indexWhere(
      (e) => e.number == number && (season == null || e.season == season),
    );
    if (index < 0 && episodes.length == 1) index = 0;
    if (index < 0)
      throw StateError('This episode is not listed on the TV source.');
    final position = (request['positionMs'] as num? ?? 0).toInt().clamp(
      0,
      86400000,
    );
    final resume = sl<ResumeStore>();
    await channel.invokeMethod<void>('receiverClosePlayer');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await resume.save(
      sourceId,
      showUrl,
      episodes[index].id,
      Duration(milliseconds: position),
      Duration.zero,
    );
    browsing.value = 'Loading ${detail.title}';
    unawaited(() async {
      try {
        final ok = await TvNativePlayer.play(
          sourceId: sourceId,
          episodes: episodes,
          startIndex: index,
          resume: resume,
          showUrl: showUrl,
          showTitle: detail.title,
          cover: detail.cover,
          coverHeaders: detail.coverHeaders,
          category: request['category'] == 'dub' ? 'dub' : 'sub',
          resolveSources: (url) => catalogue.sources(url, sourceId: sourceId),
        );
        if (!ok)
          await channel.invokeMethod<void>(
            'playbackError',
            'The TV could not play this episode. Try another source.',
          );
      } catch (e) {
        await channel.invokeMethod<void>('playbackError', e.toString());
      } finally {
        browsing.value = '';
      }
    }());
    return {'ok': true, 'title': detail.title, 'index': index};
  }
}
