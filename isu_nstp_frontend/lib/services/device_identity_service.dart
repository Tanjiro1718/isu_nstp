import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../config/api_config.dart';
import '../models/user_model.dart';

/// Stable identity for this installation plus the per-account secret issued by
/// the server on first login.
///
/// The id is generated once and kept across logouts so the admin can recognise
/// the phone. The secret is never shown in the UI and is stored per account:
/// several students may sign in on the same phone without sharing a binding.
class DeviceIdentityService {
  static const String _idKey = 'device_identity_id';
  static const String _idPrefix = 'device_secret_user_';
  static const String _usernamePrefix = 'device_secret_name_';

  static String? _cachedId;

  static String _usernameKey(String username) =>
      username.trim().toLowerCase();

  static String _userKey(int userId) => '$_idPrefix$userId';

  static String _nameKey(String username) =>
      '$_usernamePrefix${_usernameKey(username)}';

  /// The installation id, created lazily on first use.
  static Future<String> getDeviceId() async {
    if (_cachedId != null) return _cachedId!;

    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_idKey);
      if (saved != null && saved.isNotEmpty) {
        _cachedId = saved;
        return saved;
      }

      final generated = const Uuid().v4();
      await prefs.setString(_idKey, generated);
      _cachedId = generated;
      return generated;
    } catch (_) {
      // Only reached when preferences are unavailable. Keep this launch
      // working; the id will be regenerated on the next successful write.
      _cachedId ??= const Uuid().v4();
      return _cachedId!;
    }
  }

  static String get platformName {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.linux:
        return 'linux';
      case TargetPlatform.fuchsia:
        return 'fuchsia';
    }
  }

  static String get deviceLabel {
    if (kIsWeb) return 'Web browser';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'Android device';
      case TargetPlatform.iOS:
        return 'iPhone / iPad';
      case TargetPlatform.macOS:
        return 'Mac';
      case TargetPlatform.windows:
        return 'Windows PC';
      case TargetPlatform.linux:
        return 'Linux PC';
      case TargetPlatform.fuchsia:
        return 'Fuchsia device';
    }
  }

  static Future<String> _appVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return '${info.version}+${info.buildNumber}';
    } catch (_) {
      return '';
    }
  }

  /// Fields the login endpoint needs before it knows which account is signing
  /// in. The saved secret is keyed by username for exactly this reason.
  static Future<Map<String, String>> loginFields(String username) async {
    final fields = <String, String>{
      'device_id': await getDeviceId(),
      'device_label': deviceLabel,
      'platform': platformName,
      'app_version': await _appVersion(),
    };

    final secret = await _readSecret(_nameKey(username));
    if (secret != null && secret.isNotEmpty) {
      fields['device_secret'] = secret;
    }
    return fields;
  }

  /// Persists the one-time secret returned by a successful first login.
  static Future<void> rememberBinding({
    required String username,
    required int userId,
    Map<String, dynamic>? deviceBinding,
  }) async {
    if (deviceBinding == null) return;
    final secret = deviceBinding['device_secret'];
    if (secret is! String || secret.isEmpty) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_userKey(userId), secret);
      await prefs.setString(_nameKey(username), secret);
    } catch (_) {
      // The next login will simply ask again; the server still holds the
      // binding, so a missing local secret becomes an auth failure until the
      // admin resets it. Nothing else can be done offline.
    }
  }

  static Future<String?> _readSecret(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(key);
    } catch (_) {
      return null;
    }
  }

  static Future<String?> secretForUser(int userId) async {
    return _readSecret(_userKey(userId));
  }

  /// Headers for the attendance endpoints that enforce device binding.
  static Future<Map<String, String>> authHeaders(
    int userId, {
    bool json = false,
  }) async {
    final headers = <String, String>{
      'ngrok-skip-browser-warning': 'true',
      'X-Device-Id': await getDeviceId(),
    };
    final secret = await secretForUser(userId);
    if (secret != null && secret.isNotEmpty) {
      headers['X-Device-Secret'] = secret;
    }
    if (json) {
      headers['Content-Type'] = 'application/json';
    }
    return headers;
  }

  /// Confirms a restored session still belongs to the bound device.
  ///
  /// Network/server failures deliberately return valid so an offline launch
  /// does not sign the student out. An explicit 403 is the server telling us
  /// the binding changed, so the cached session and stale secret are dropped.
  static Future<DeviceValidationResult> validateSession(UserModel user) async {
    if (user.role.toLowerCase() != 'student') {
      return const DeviceValidationResult.valid();
    }

    try {
      final response = await http
          .post(
            Uri.parse(ApiConfig.deviceValidateUrl),
            headers: await authHeaders(user.id, json: true),
            body: jsonEncode({'user_id': user.id}),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        return const DeviceValidationResult.valid();
      }

      if (response.statusCode == 403) {
        final decoded = _decodeMap(response.body);
        return DeviceValidationResult.invalid(
          code: decoded['code']?.toString() ?? 'device_rejected',
          message: decoded['message']?.toString() ??
              decoded['detail']?.toString() ??
              'This device is no longer authorized for this account.',
        );
      }

      return const DeviceValidationResult.valid();
    } catch (_) {
      return const DeviceValidationResult.valid();
    }
  }

  /// Removes the local secrets for an account after a failed validation.
  static Future<void> forgetSecret(UserModel user) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_userKey(user.id));
      await prefs.remove(_nameKey(user.username));
    } catch (_) {
      // Nothing else to do locally.
    }
  }

  static Map<String, dynamic> _decodeMap(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map ? decoded.cast<String, dynamic>() : const {};
    } catch (_) {
      return const {};
    }
  }
}

class DeviceValidationResult {
  final bool valid;
  final String code;
  final String message;

  const DeviceValidationResult.valid()
      : valid = true,
        code = '',
        message = '';

  const DeviceValidationResult.invalid({
    required this.code,
    required this.message,
  }) : valid = false;
}
