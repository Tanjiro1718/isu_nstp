import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

class NotificationService {
  final FirebaseMessaging _firebaseMessaging = FirebaseMessaging.instance;

  Future<String?> getDeviceToken() async {
    // Request permission on iOS / Web / Android 13+
    NotificationSettings settings = await _firebaseMessaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    if (settings.authorizationStatus == AuthorizationStatus.authorized) {
      String? token = await _firebaseMessaging.getToken();
      debugPrint("FCM Device Token: $token");
      return token;
    } else {
      debugPrint("User declined or has not accepted notification permissions.");
      return null;
    }
  }

  void initializeForegroundHandler() {
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      debugPrint('Received foreground notification: ${message.notification?.title}');
      // Handle foreground alert UI here (e.g., show a dialog or local notification)
    });
  }
}