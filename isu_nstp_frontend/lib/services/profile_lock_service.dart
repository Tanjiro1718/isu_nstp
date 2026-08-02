import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Outcome of a biometric prompt, so callers can tell "user said no" apart from
/// "this device cannot do it" and message accordingly.
enum LockResult {
  /// Face / fingerprint matched.
  success,

  /// User cancelled or the match failed.
  failed,

  /// No biometrics enrolled, or the hardware is missing.
  unavailable,
}

/// Guards the student's profile details behind the device's own biometrics.
///
/// Deliberately stores no biometric data: `local_auth` hands the check to the
/// OS (Face ID / Android BiometricPrompt) and only ever returns a bool, so the
/// face template stays in the secure enclave and never reaches our servers.
/// The only thing persisted is a per-student on/off flag.
class ProfileLockService {
  static final LocalAuthentication _auth = LocalAuthentication();

  /// Scoped per user id so two students sharing a device keep separate settings.
  static String _prefsKey(int userId) => 'profile_lock_enabled_$userId';

  /// True when the device can actually perform a biometric check right now.
  ///
  /// `isDeviceSupported` covers the hardware; `canCheckBiometrics` tells us
  /// whether anything is enrolled. Both must hold or the prompt would throw.
  static Future<bool> isBiometricAvailable() async {
    try {
      final supported = await _auth.isDeviceSupported();
      if (!supported) return false;
      return await _auth.canCheckBiometrics;
    } on Exception catch (e) {
      debugPrint('Biometric availability check failed: $e');
      return false;
    }
  }

  /// Whether the device specifically offers face recognition, so the UI can say
  /// "Face Unlock" instead of the generic "biometrics".
  static Future<bool> hasFaceUnlock() async {
    try {
      final available = await _auth.getAvailableBiometrics();
      return available.contains(BiometricType.face) ||
          available.contains(BiometricType.strong);
    } on Exception catch (e) {
      debugPrint('Could not list biometrics: $e');
      return false;
    }
  }

  static Future<bool> isLockEnabled(int userId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_prefsKey(userId)) ?? false;
  }

  static Future<void> setLockEnabled(int userId, bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsKey(userId), enabled);
  }

  /// Prompts for face / fingerprint before revealing profile details.
  ///
  /// `biometricOnly` stays false so a student whose face fails in bad lighting
  /// can still fall back to their device PIN rather than being locked out.
  static Future<LockResult> authenticate({
    String reason = 'Verify your identity to view your profile details',
  }) async {
    if (!await isBiometricAvailable()) return LockResult.unavailable;

    try {
      final didAuth = await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
          useErrorDialogs: true,
        ),
      );
      return didAuth ? LockResult.success : LockResult.failed;
    } on Exception catch (e) {
      // Thrown for locked-out-after-too-many-tries, no-enrolled-biometrics, etc.
      debugPrint('Biometric authentication error: $e');
      return LockResult.unavailable;
    }
  }
}
