import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'device_token_service.dart';
import 'session_service.dart';

/// The Android notification channel every push from the backend targets
/// (matching `_urgent_android()` in the Django `fcm_utils.py`).
const String kAttendanceChannelId = 'attendance_alerts';
const String kAttendanceChannelName = 'Attendance Alerts';
const String kAttendanceChannelDescription =
    'Alerts for attendance sessions, presence checks and time-out windows.';

/// Tab index of the instructor's Monitor/Headcounts tab, used by the
/// deep-link that fires when an instructor taps a "student checked in" push.
const int kInstructorMonitorTabIndex = 1;

/// A request to move the instructor dashboard to a specific place after the
/// user taps a push notification.
class InstructorNavRequest {
  final int tabIndex;
  final int recordId;
  final int sessionId;
  const InstructorNavRequest({
    required this.tabIndex,
    this.recordId = 0,
    this.sessionId = 0,
  });
}

/// Global intent bus: NotificationService publishes to it when an instructor
/// taps a notification; InstructorDashboard listens and switches tabs.
final ValueNotifier<InstructorNavRequest?> instructorNavRequests =
    ValueNotifier<InstructorNavRequest?>(null);

/// Top-level background message handler.
/// MUST be defined outside any class and annotated with `@pragma('vm:entry-point')`
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint("Handling background message ID: ${message.messageId}");
  debugPrint("Background Notification Title: ${message.notification?.title}");
  debugPrint("Background Notification Body: ${message.notification?.body}");
}

/// Show a push as a system-style notification, even while the app is open in
/// the foreground, so the student is not dependent on the polling loop alone.
Future<void> showLocalNotification(RemoteMessage message) async {
  final title = message.notification?.title ?? 'ISU NSTP';
  final body = message.notification?.body ?? 'Tap to view details.';
  const androidDetails = AndroidNotificationDetails(
    kAttendanceChannelId,
    kAttendanceChannelName,
    channelDescription: kAttendanceChannelDescription,
    importance: Importance.max,
    priority: Priority.high,
    playSound: true,
  );
  const darwinDetails = DarwinNotificationDetails(
    presentAlert: true,
    presentBanner: true,
    presentBadge: true,
    presentSound: true,
  );
  try {
    await NotificationService.localNotifications.show(
      message.messageId.hashCode,
      title,
      body,
      const NotificationDetails(
        android: androidDetails,
        iOS: darwinDetails,
      ),
    );
  } catch (e) {
    debugPrint('Could not show local notification: $e');
  }
}

class NotificationService {
  final FirebaseMessaging _firebaseMessaging = FirebaseMessaging.instance;

  /// Plugin used to surface notifications while the app is foregrounded.
  static final FlutterLocalNotificationsPlugin localNotifications =
      FlutterLocalNotificationsPlugin();

  /// Call this in `main.dart` to initialize all notification listeners
  Future<void> initialize() async {
    // 0. Create the Android channel so the backend's `attendance_alerts`
    //    channel reference resolves on Android 8+. Without this the OS drops or
    //    demotes every push (no heads-up alert, no sound, silent or hidden).
    await _initLocalNotifications();

    // 1. Set top-level background message handler
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

    // 2. Request permission for iOS & Android 13+
    await requestPermission();

    // 3. Setup foreground notification listener
    _initializeForegroundHandler();

    // 4. Setup notification click/tap listeners
    _setupNotificationClickHandlers();

    // 5. Listen for FCM Token updates
    _firebaseMessaging.onTokenRefresh.listen((newToken) {
      debugPrint("FCM Device Token Refreshed: $newToken");
      // FCM rotates tokens (app restore, cache clear, long idle). If the
      // backend keeps the old token, pushes to it are silently rejected, so
      // re-register the fresh token for the signed-in user.
      _syncRefreshedToken(newToken);
    });
  }

  Future<void> _initLocalNotifications() async {
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwinInit = DarwinInitializationSettings();
    const initSettings =
        InitializationSettings(android: androidInit, iOS: darwinInit);
    await localNotifications.initialize(initSettings);

    const androidChannel = AndroidNotificationChannel(
      kAttendanceChannelId,
      kAttendanceChannelName,
      description: kAttendanceChannelDescription,
      importance: Importance.max,
      playSound: true,
    );
    await localNotifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(androidChannel);
  }

  Future<void> _syncRefreshedToken(String newToken) async {
    try {
      final user = await SessionService.loadUser();
      if (user == null || user.id == 0) return;
      await DeviceTokenService.registerWithToken(user.id, newToken);
    } catch (e) {
      debugPrint('Could not sync refreshed device token: $e');
    }
  }

  /// Request push notification permissions from the user
  Future<bool> requestPermission() async {
    NotificationSettings settings = await _firebaseMessaging.requestPermission(
      alert: true,
      announcement: false,
      badge: true,
      carPlay: false,
      criticalAlert: false,
      provisional: false,
      sound: true,
    );

    if (settings.authorizationStatus == AuthorizationStatus.authorized) {
      debugPrint("Notification permissions granted.");
      return true;
    } else if (settings.authorizationStatus == AuthorizationStatus.provisional) {
      debugPrint("Provisional notification permissions granted.");
      return true;
    } else {
      debugPrint("User declined notification permissions.");
      return false;
    }
  }

  /// Retrieves the device FCM token (for registration)
  Future<String?> getDeviceToken() async {
    try {
      // Ensure permissions are granted before requesting token
      NotificationSettings settings = await _firebaseMessaging.getNotificationSettings();
      if (settings.authorizationStatus != AuthorizationStatus.authorized) {
        bool granted = await requestPermission();
        if (!granted) return null;
      }

      String? token = await _firebaseMessaging.getToken();
      debugPrint("FCM Device Token: $token");
      return token;
    } catch (e) {
      debugPrint("Error fetching FCM device token: $e");
      return null;
    }
  }

  /// Handles notifications received while the app is actively open on screen
  void _initializeForegroundHandler() {
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      debugPrint('Foreground Notification Received: ${message.notification?.title}');
      debugPrint('Notification Body: ${message.notification?.body}');
      debugPrint('Data payload: ${message.data}');

      // Show the push as a system-style notification so the student still sees
      // presence checks and session alerts while the app is open.
      showLocalNotification(message);
    });
  }

  /// Routes a tapped notification to the right place.
  ///
  /// Currently used to send an instructor who taps a "student checked in"
  /// push to their Monitor/Headcounts tab.
  void _handleTap(RemoteMessage message) {
    debugPrint("Notification tap data: ${message.data}");
    if (message.data['type'] == 'check_in') {
      instructorNavRequests.value = const InstructorNavRequest(
        tabIndex: kInstructorMonitorTabIndex,
      );
    }
  }

  /// Handles actions when a user taps a notification banner
  void _setupNotificationClickHandlers() {
    // Case A: App was fully terminated and opened by tapping a notification
    _firebaseMessaging.getInitialMessage().then((RemoteMessage? message) {
      if (message != null) {
        debugPrint("App opened from terminated state via notification click: ${message.notification?.title}");
        _handleTap(message);
      }
    });

    // Case B: App was running in background and brought to foreground by tapping notification
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      debugPrint("App opened from background via notification click: ${message.notification?.title}");
      _handleTap(message);
    });
  }
}
