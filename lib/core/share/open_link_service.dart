import 'dart:async';

import 'package:app_links/app_links.dart';

import '../../features/auth/pair_tv_screen.dart';
import '../../features/auth/send_trackers_to_tv_screen.dart';
import '../../features/detail/detail_screen.dart';
import '../di/injector.dart';
import '../models/media_item.dart';
import '../repository/source_repository.dart';
import '../ui/global_messenger.dart';
import 'share_link.dart';

/// Listens for incoming `zangetsu://open?…` share links and opens the shared
/// title's Detail on its source — or, when that source isn't installed on this
/// device, tells the user instead of failing silently.
///
/// Additive + isolated: it shares the app-wide [AppLinks] stream with the
/// tracker OAuth listeners and simply ignores any link that isn't
/// `zangetsu://open` ([ShareLink.parse] returns null), so nothing else changes.
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
    // zangetsu://pair?code=CODE — a TV pairing QR scanned on the phone.
    if (uri.host == 'pair') {
      final code = uri.queryParameters['code'];
      final nonce = uri.queryParameters['nonce'];
      if (uri.queryParameters['trackers'] == '1') {
        _openSendTrackers(code, nonce); // Flow B — added in Task 11
      } else {
        _openPair(code, nonce);
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
