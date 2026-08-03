import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import 'notification_service.dart';

/// Keeps the backend's copy of this device's FCM token current.
///
/// Previously this only ran at login. Now that sessions survive a restart a
/// user may not log in for weeks, and FCM tokens rotate (app restore, cache
/// clear, long idle) - so a restored session refreshes it on launch too,
/// otherwise presence-check pushes would quietly stop arriving.
class DeviceTokenService {
  /// Fire-and-forget: push is a nice-to-have and must never block the UI.
  static Future<void> register(int userId) async {
    try {
      final token = await NotificationService().getDeviceToken();
      if (token == null || token.isEmpty) return;

      await http
          .post(
            Uri.parse('${ApiConfig.baseUrl}/api/device-token/'),
            headers: const {
              'Content-Type': 'application/json',
              'ngrok-skip-browser-warning': 'true',
            },
            body: jsonEncode({'user_id': userId, 'fcm_token': token}),
          )
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      // The email fallback still delivers codes, so this is not fatal.
      debugPrint('Could not register device token: $e');
    }
  }
}
