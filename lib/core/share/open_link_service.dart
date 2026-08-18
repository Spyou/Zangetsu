import 'dart:async';

import 'package:app_links/app_links.dart';

import '../../features/auth/pair_tv_screen.dart';
import '../../features/auth/send_trackers_to_tv_screen.dart';
import '../../features/detail/detail_screen.dart';
import '../di/injector.dart';
import '../models/media_item.dart';
import '../repository/source_repository.dart';
import '../ui/global_messenger.dart';
import 'pair_link.dart';
import 'share_link.dart';

/// Listens for incoming share links (`zangetsu://open?…`) and pairing links
/// (`https://zangetsu.online/pair/?…` or `zangetsu://pair?…`) and opens the
/// matching screen. Tracker OAuth listeners share the same [AppLinks] stream
/// and ignore anything they don't own.
class OpenLinkService {
  OpenLinkService() {
    _sub = _appLinks.uriLinkStream.listen(_onLink, onError: (_) {});
    // Cold start: the browser/OS may have launched the app straight to the link.
    _appLinks.getInitialLink().then((uri) {
      if (uri != null) _onLink(uri);
    }).catchError((_) {});
  }

  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _sub;

  void _onLink(Uri uri) {
    // HTTPS /pair/?code=… (iPhone Camera) or zangetsu://pair?code=… (site
    // redirect / Android custom-scheme). Same payload either way.
    final pair = PairLink.parse(uri);
    if (pair != null) {
      if (pair.trackers) {
        _openSendTrackers(pair.code, pair.nonce);
      } else {
        _openPair(pair.code, pair.nonce);
      }
      return;
    }
    final item = ShareLink.parse(uri);
    if (item == null) return; // not an open-link (or another handler's link)
    _open(item);
  }

  /// Open the phone's "Pair a TV" screen prefilled with the scanned code.
  /// Waits (cold-start safe) for the root Navigator, like [_open].
  void _openPair(String? code, String? nonce, [int attempt = 0]) {
    final nav = rootNavigatorKey.currentState;
    if (nav == null) {
      if (attempt < 20) {
        Future.delayed(
          const Duration(milliseconds: 250),
          () => _openPair(code, nonce, attempt + 1),
        );
      }
      return;
    }
    nav.push(PairTvScreen.route(code, nonce));
  }

  /// Open the phone's "Send to TV" tracker picker (Flow B — trackers-only,
  /// no account pairing). Same cold-start-safe wait as [_openPair].
  void _openSendTrackers(String? code, String? nonce, [int attempt = 0]) {
    final nav = rootNavigatorKey.currentState;
    if (nav == null) {
      if (attempt < 20) {
        Future.delayed(
          const Duration(milliseconds: 250),
          () => _openSendTrackers(code, nonce, attempt + 1),
        );
      }
      return;
    }
    nav.push(SendTrackersToTvScreen.route(code, nonce));
  }

  /// Waits (briefly, cold-start safe) for the root Navigator to exist, then
  /// either opens the Detail or shows a "source not installed" toast.
  void _open(MediaItem item, [int attempt = 0]) {
    final nav = rootNavigatorKey.currentState;
    if (nav == null) {
      if (attempt < 20) {
        Future.delayed(
          const Duration(milliseconds: 250),
          () => _open(item, attempt + 1),
        );
      }
      return;
    }
    if (!_sourceInstalled(item.sourceId)) {
      showGlobalSnack(
        "That title's source isn't installed. Add it in Settings › Providers.",
      );
      return;
    }
    nav.push(DetailScreen.route(item));
  }

  bool _sourceInstalled(String sourceId) {
    try {
      // Canonical check across cs:/ani:/JS ids (CS also matches a compatible
      // repo/version). The old code only knew cs: + JS, so every Aniyomi
      // (`ani:`) share fell through to the JS registry and wrongly reported
      // "not installed".
      return sl<SourceRepository>().hasSource(sourceId);
    } catch (_) {
      return false;
    }
  }

  void dispose() {
    _sub?.cancel();
  }
}
