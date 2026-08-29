import 'package:flutter/material.dart';

import '../../features/player/player_screen.dart';
import '../di/injector.dart';
import '../models/episode.dart';
import '../models/video_source.dart';
import '../playback/resume_store.dart';

/// A video file handed to the app from outside — a file manager, Downloads, a
/// share sheet — via `ACTION_VIEW` on a `file://` or `content://` URI.
///
/// Deliberately narrow. This is not a source, has no episode list, no chapter
/// list, no resume mark and nothing to scrobble; it is one file and a play
/// button. Everything the app normally hangs off a [MediaItem] is simply
/// absent, so nothing about the source/tracker paths is involved.
class LocalVideoLink {
  /// Schemes the manifest's video intent-filter claims. `http`/`https` are NOT
  /// claimed — see the filter's comment — so a web video link never lands here.
  static const Set<String> _schemes = {'file', 'content'};

  /// Extensions treated as playable when the URI carries no usable mime type.
  /// `content://` URIs from a document provider often have an opaque path, in
  /// which case this misses and we fall back to the intent's own mime type
  /// having already matched the filter.
  static const Set<String> _exts = {
    'mp4', 'mkv', 'webm', 'avi', 'mov', 'm4v', 'ts', 'm3u8', 'mpd', 'flv',
    '3gp', 'wmv', 'mpg', 'mpeg', 'ogv',
  };

  /// True when [uri] is a local video the player should open.
  ///
  /// Returns false for anything else so [OpenLinkService] can keep handing the
  /// URI to the tracker-OAuth and share-link handlers exactly as before — this
  /// check is additive and never swallows a link another handler owns.
  static bool matches(Uri uri) {
    if (!_schemes.contains(uri.scheme)) return false;
    final path = uri.path.toLowerCase();
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) {
      // No extension to judge by. A content:// URI only reaches us because the
      // manifest's video/* filter already matched, so trust that.
      return uri.scheme == 'content';
    }
    return _exts.contains(path.substring(dot + 1));
  }

  /// A human-ish title for the player bar: the file name, undecorated.
  static String titleFor(Uri uri) {
    final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segs.isEmpty) return 'Video';
    final last = Uri.decodeComponent(segs.last);
    final slash = last.lastIndexOf('/');
    final name = slash >= 0 ? last.substring(slash + 1) : last;
    return name.isEmpty ? 'Video' : name;
  }

  /// The player, wired to play exactly this one file.
  ///
  /// Shaped exactly like `launchDownloadedEpisode`: a ONE-ENTRY episode list
  /// plus a `resolveSources` that ignores its argument and hands back the local
  /// URL. The single episode is the part that matters — the player drives
  /// playback from the episode list and calls `resolveSources` with an episode
  /// url, so passing none left it with nothing to play and a white screen.
  ///
  /// The existing player is otherwise reused untouched; it already plays
  /// `content://`, which is how SAF downloads play today.
  static Route<void> route(Uri uri) {
    final raw = uri.toString();
    final ep = Episode(id: raw, title: titleFor(uri), url: raw);
    return MaterialPageRoute(
      builder: (_) => PlayerScreen(
        // Not a real source id. Prefixed so nothing mistakes it for one: the
        // repository is never asked to resolve against it.
        sourceId: 'local:file',
        episodes: [ep],
        startIndex: 0,
        resume: sl<ResumeStore>(),
        // The raw uri goes straight through: media_kit's Media.normalizeURI
        // already turns an Android content:// into an fd:// itself (see
        // AndroidContentUriProvider). Converting it here first only hid that
        // from it and handed libmpv a scheme it doesn't parse.
        resolveSources: (_) async => [
          VideoSource(
            url: raw,
            container: SourceContainer.mp4,
            quality: 'Local',
            label: titleFor(uri),
          ),
        ],
        showTitle: titleFor(uri),
      ),
    );
  }
}
