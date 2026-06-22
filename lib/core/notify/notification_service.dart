import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'notification_router.dart';

/// Thin wrapper over flutter_local_notifications for "new episode" alerts.
/// Android-only in practice (iOS background refresh is too restrictive to rely
/// on); a no-op on other platforms.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  // Native (CS worker) notification taps come over this channel.
  static const MethodChannel _notifChannel =
      MethodChannel('zangetsu/notifications');
  bool _inited = false;

  Future<void> init() async {
    if (_inited || !Platform.isAndroid) return;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: android);
    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: (r) =>
          openShowFromNotification(r.payload),
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
    _inited = true;
  }

  /// Wire notification taps and open the show if the app was launched by one.
  /// Call once the navigator is ready. Handles both notification kinds:
  ///   • Flutter-plugin (JS): init callback for live taps, launch-details here.
  ///   • Native worker (CS): the zangetsu/notifications channel — openShow for
  ///     live taps (onNewIntent), getInitialNotification for cold/back launch.
  Future<void> handleLaunch() async {
    if (!Platform.isAndroid) return;
    if (!_inited) await init();
    _notifChannel.setMethodCallHandler((call) async {
      if (call.method == 'openShow') {
        await openShowFromNotification(call.arguments as String?);
      }
    });
    final d = await _plugin.getNotificationAppLaunchDetails();
    if (d?.didNotificationLaunchApp ?? false) {
      await openShowFromNotification(d!.notificationResponse?.payload);
    }
    try {
      final native = await _notifChannel.invokeMethod<String>(
        'getInitialNotification',
      );
      await openShowFromNotification(native);
    } catch (_) {}
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
