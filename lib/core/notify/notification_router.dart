import '../../features/detail/detail_screen.dart';
import '../di/injector.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart';
import '../ui/global_messenger.dart';
import 'subscription_store.dart';

/// Open the Detail screen for the show a "new episode" notification points to.
/// [payload] is "sourceId|url" (split on the FIRST '|' — a url may contain one).
/// The full cover / headers / title come from the stored subscription so Detail
/// renders immediately; it then re-fetches by sourceId+url anyway.
Future<void> openShowFromNotification(String? payload) async {
  if (payload == null) return;
  final i = payload.indexOf('|');
  if (i < 0) return;
  final sourceId = payload.substring(0, i);
  final url = payload.substring(i + 1);
  if (sourceId.isEmpty || url.isEmpty) return;

  Subscription? sub;
  if (sl.isRegistered<SubscriptionStore>()) {
    for (final s in sl<SubscriptionStore>().all()) {
      if (s.sourceId == sourceId && s.url == url) {
        sub = s;
        break;
      }
    }
  }

  final nav = rootNavigatorKey.currentState;
  if (nav == null) return;
  await nav.push(
    DetailScreen.route(
      MediaItem(
        id: url,
        title: sub?.title ?? '',
        url: url,
        type: ProviderType.anime,
        sourceId: sourceId,
        cover: sub?.cover,
        coverHeaders: sub?.coverHeaders,
      ),
    ),
  );
}
