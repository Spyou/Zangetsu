import 'dart:async';

import 'package:app_links/app_links.dart';

import '../../features/auth/pair_tv_screen.dart';
import '../../features/detail/detail_screen.dart';
import '../di/injector.dart';
import '../models/media_item.dart';
import '../provider/cloudstream_provider.dart';
import '../provider/provider_registry.dart';
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
      _openPair(uri.queryParameters['code']);
      return;
    }
    final item = ShareLink.parse(uri);
    if (item == null) return; // not an open-link (or another handler's link)
    _open(item);
  }

  /// Open the phone's "Pair a TV" screen prefilled with the scanned code.
  /// Waits (cold-start safe) for the root Navigator, like [_open].
  void _openPair(String? code, [int attempt = 0]) {
    final nav = rootNavigatorKey.currentState;
    if (nav == null) {
      if (attempt < 20) {
        Future.delayed(
          const Duration(milliseconds: 250),
          () => _openPair(code, attempt + 1),
        );
      }
      return;
    }
    nav.push(PairTvScreen.route(code));
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
      if (sourceId.startsWith('cs:')) {
        return sl<CloudStreamManager>().get(sourceId) != null;
      }
      return sl<ProviderRegistry>().entryFor(sourceId) != null;
    } catch (_) {
      return false;
    }
  }

  void dispose() {
    _sub?.cancel();
  }
}
