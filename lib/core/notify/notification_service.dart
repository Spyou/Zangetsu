import 'dart:io';

import 'package:dio/dio.dart';
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
  final Dio _dio = Dio();
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

  /// Stable id for the "source updates available" notification, so a later check
  /// REPLACES the previous one instead of stacking.
  static const int _sourceUpdatesNotifId = 90001;

  /// Notify that [count] installed sources have updates available. A no-op when
  /// [count] is 0. No payload — tapping just opens the app (the badges/Update
  /// buttons live on the Sources screen).
  Future<void> showSourceUpdates({required int count}) async {
    if (!Platform.isAndroid || count <= 0) return;
    if (!_inited) await init();
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'source_updates',
        'Source updates',
        channelDescription:
            'Alerts when installed sources have updates available',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
      ),
    );
    await _plugin.show(
      _sourceUpdatesNotifId,
      'Source updates available',
      count == 1 ? '1 source has an update' : '$count sources have updates',
      details,
    );
  }

  /// Show a general announcement / push message. Used for FCM foreground
  /// messages, which Android does not display on its own (backgrounded ones the
  /// system draws itself, image included). [imageUrl], when set and reachable,
  /// renders as a big-picture notification; [payload] is optional tap data.
  Future<void> showMessage({
    required int id,
    required String title,
    required String body,
    String? imageUrl,
    String? payload,
  }) async {
    if (!Platform.isAndroid) return;
    if (!_inited) await init();
    StyleInformation? style;
    if (imageUrl != null && imageUrl.isNotEmpty) {
      final picture = await _downloadBitmap(imageUrl);
      if (picture != null) {
        style = BigPictureStyleInformation(
          picture,
          contentTitle: title,
          summaryText: body,
          hideExpandedLargeIcon: true,
        );
      }
    }
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        'announcements',
        'Announcements',
        channelDescription: 'News and updates from Zangetsu',
        importance: Importance.high,
        priority: Priority.high,
        styleInformation: style,
      ),
    );
    await _plugin.show(id, title, body, details, payload: payload);
  }

  /// Download a remote image into a temp file for a big-picture notification.
  /// Returns null on any failure so the notification still shows as text.
  Future<FilePathAndroidBitmap?> _downloadBitmap(String url) async {
    try {
      final res = await _dio.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          receiveTimeout: const Duration(seconds: 10),
          sendTimeout: const Duration(seconds: 10),
        ),
      );
      final bytes = res.data;
      if (bytes == null || bytes.isEmpty) return null;
      final file = File('${Directory.systemTemp.path}/notif_${url.hashCode}.img');
      await file.writeAsBytes(bytes);
      return FilePathAndroidBitmap(file.path);
    } catch (_) {
      return null;
    }
  }
}
