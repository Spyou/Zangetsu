import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Thin wrapper over flutter_local_notifications for "new episode" alerts.
/// Android-only in practice (iOS background refresh is too restrictive to rely
/// on); a no-op on other platforms.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _inited = false;

  Future<void> init() async {
    if (_inited || !Platform.isAndroid) return;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: android);
    await _plugin.initialize(settings);
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
    _inited = true;
  }

  /// Notify that [title] has a new episode ([episode]). [id] should be stable
  /// per-show so repeated alerts replace rather than stack. [payload] carries
  /// "sourceId|url" for tap handling.
  Future<void> showNewEpisode({
    required int id,
    required String title,
    required int episode,
    String? payload,
  }) async {
    if (!Platform.isAndroid) return;
    if (!_inited) await init();
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'new_episodes',
        'New episodes',
        channelDescription:
            'Alerts when a subscribed show has a new episode available',
        importance: Importance.high,
        priority: Priority.high,
      ),
    );
    await _plugin.show(
      id,
      title,
      'Episode $episode is out',
      details,
      payload: payload,
    );
  }
}
