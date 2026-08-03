import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/user_model.dart';

/// Keeps the signed-in user on disk so closing the app does not sign them out.
///
/// Only the profile fields already returned by the login response are stored.
/// Nothing secret is added here beyond the auth token the app was holding in
/// memory anyway, and [clear] wipes it on an explicit logout.
class SessionService {
  static const String _userKey = 'session_user';

  /// Persists the signed-in user. Failure is swallowed: a device that cannot
  /// write preferences should still be able to use the app for this session.
  static Future<void> saveUser(UserModel user) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_userKey, jsonEncode(user.toJson()));
    } catch (_) {
      // Non-fatal - the user simply will not be remembered next launch.
    }
  }

  /// Returns the remembered user, or null when nobody is signed in.
  static Future<UserModel?> loadUser() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_userKey);
      if (raw == null || raw.isEmpty) return null;

      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;

      final user = UserModel.fromJson(decoded);
      // A record with no id is corrupt; treat it as no session at all so the
      // app shows the login screen instead of a dashboard with no identity.
      if (user.id == 0) {
        await prefs.remove(_userKey);
        return null;
      }
      return user;
    } catch (_) {
      // Corrupt or unreadable data - fall back to the login screen.
      return null;
    }
  }

  /// Forgets the signed-in user. Called on explicit logout.
  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_userKey);
    } catch (_) {
      // Nothing useful to do; the next launch will simply try again.
    }
  }
}
