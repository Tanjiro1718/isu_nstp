import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

/// Top-level background message handler.
/// MUST be defined outside any class and annotated with `@pragma('vm:entry-point')`
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint("Handling background message ID: ${message.messageId}");
  debugPrint("Background Notification Title: ${message.notification?.title}");
  debugPrint("Background Notification Body: ${message.notification?.body}");
}

class NotificationService {
  final FirebaseMessaging _firebaseMessaging = FirebaseMessaging.instance;

  /// Call this in `main.dart` to initialize all notification listeners
  Future<void> initialize() async {
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
      // Optionally sync newToken with backend here
    });
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
      
      // Customize foreground alert popups here if needed
    });
  }

  /// Handles actions when a user taps a notification banner
  void _setupNotificationClickHandlers() {
    // Case A: App was fully terminated and opened by tapping a notification
    _firebaseMessaging.getInitialMessage().then((RemoteMessage? message) {
      if (message != null) {
        debugPrint("App opened from terminated state via notification click: ${message.notification?.title}");
      }
    });

    // Case B: App was running in background and brought to foreground by tapping notification
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      debugPrint("App opened from background via notification click: ${message.notification?.title}");
    });
  }
}