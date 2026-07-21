import 'dart:async';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';

import '../announce/announcement.dart';
import '../di/injector.dart';
import 'notification_service.dart';

/// Firebase Cloud Messaging — broadcast a custom notification to every user for
/// free (FCM is $0 on all Firebase plans, unmetered).
///
/// Every device subscribes to the `all` topic; to reach everyone, send a
/// notification to the topic `all` from Firebase Console → Messaging. No server
/// or per-device token bookkeeping needed.
///
/// Delivery:
///   • Background / killed — the system shows the notification (image included).
///   • Foreground — FCM stays silent, so we redraw it via [NotificationService].
///
/// Every message we can see (foreground, or one the user tapped to open the app)
/// is also recorded into the [AnnouncementStore] so it shows in the in-app
/// Notifications list and bumps the bell badge. A background notification the
/// user never taps stays in the system tray only — we don't write from a
/// background isolate, which would risk the Hive box the main isolate holds
/// open. Android-only (matches NotificationService).
class PushService {
  PushService._();
  static final PushService instance = PushService._();

  bool _inited = false;

  Future<void> init() async {
    if (_inited || !Platform.isAndroid) return;
    _inited = true;
    final fm = FirebaseMessaging.instance;
    await fm.requestPermission(); // Android 13+ POST_NOTIFICATIONS
    await fm.subscribeToTopic('all');
    // Foreground: draw it (FCM stays silent up front) + record it.
    FirebaseMessaging.onMessage.listen((m) {
      final n = m.notification;
      if (n != null) {
        NotificationService.instance.showMessage(
          id: m.hashCode & 0x7fffffff,
          title: n.title ?? 'Zangetsu',
          body: n.body ?? '',
          imageUrl: n.android?.imageUrl,
        );
      }
      _record(m);
    });
    // Tapped from the tray (background), or launched by a tap while killed.
    FirebaseMessaging.onMessageOpenedApp.listen(_record);
    final initial = await fm.getInitialMessage();
    if (initial != null) _record(initial);
  }

  /// Persist a received message to the in-app Notifications list. Idempotent
  /// (keyed by message id) so recording the same message twice is a no-op.
  void _record(RemoteMessage m) {
    final n = m.notification;
    if (n == null || (n.title == null && n.body == null)) return;
    try {
      final store = sl<AnnouncementStore>();
      final id = 'push_${m.messageId ?? m.hashCode}';
      if (store.has(id)) return;
      final rawLink = m.data['url'] ?? m.data['link'];
      final link = rawLink is String &&
              (rawLink.startsWith('http://') || rawLink.startsWith('https://'))
          ? rawLink
          : null;
      unawaited(store.saveNew(
        Announcement(
          id: id,
          title: n.title ?? 'Zangetsu',
          body: n.body ?? '',
          actionLabel: link != null ? 'Open' : null,
          actionUrl: link,
          date: _today(m.sentTime),
          imageUrl: n.android?.imageUrl,
        ),
        m.sentTime?.millisecondsSinceEpoch ??
            DateTime.now().millisecondsSinceEpoch,
      ));
    } catch (_) {}
  }

  static String _today(DateTime? t) {
    final d = t ?? DateTime.now();
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '${d.year}-$mm-$dd';
  }
}
