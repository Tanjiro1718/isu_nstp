import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Outcome of a biometric prompt, so callers can tell "user said no" apart from
/// "this device cannot do it" and message accordingly.
enum LockResult {
  /// Face / fingerprint / device PIN matched.
  success,

  /// User cancelled or the match failed.
  failed,

  /// Nothing enrolled and no screen lock set, so we cannot prompt at all.
  notEnrolled,

  /// Too many wrong attempts; the OS has temporarily disabled biometrics.
  lockedOut,

  /// Anything else (missing hardware, plugin/platform misconfiguration).
  error,
}

/// Guards the student's profile details behind the device's own lock screen.
///
/// Deliberately stores no biometric data: `local_auth` hands the check to the
/// OS (Face ID / Android BiometricPrompt) and only ever returns a bool, so the
/// face template stays in the secure enclave and never reaches our servers.
/// The only thing persisted is a per-student on/off flag.
///
/// Android note: this only works because MainActivity extends
/// FlutterFragmentActivity - BiometricPrompt is a Fragment and cannot attach to
/// a plain FlutterActivity.
class ProfileLockService {
  static final LocalAuthentication _auth = LocalAuthentication();

  /// Scoped per user id so two students sharing a device keep separate settings.
  static String _prefsKey(int userId) => 'profile_lock_enabled_$userId';

  /// True when the device has any usable lock: face, fingerprint, or PIN.
  ///
  /// [canCheckBiometrics] alone is unreliable - several Android skins report
  /// false when only a face is enrolled, because the OS classes that camera as
  /// "weak" biometrics. [isDeviceSupported] is true whenever a device credential
  /// exists, and since we allow the PIN fallback that is enough to prompt.
  static Future<bool> isBiometricAvailable() async {
    try {
      if (await _auth.isDeviceSupported()) return true;
      return await _auth.canCheckBiometrics;
    } on Exception catch (e) {
      debugPrint('Biometric availability check failed: $e');
      return false;
    }
  }

  /// Whether any biometric (as opposed to just a PIN) is enrolled.
  ///
  /// Do not use this to claim "Face Unlock" specifically. On Android the
  /// plugin only ever reports weak/strong classes, never [BiometricType.face],
  /// and most phones treat their face unlock as convenience-grade and refuse
  /// to offer it to third-party apps at all - which is why the system prompt
  /// typically shows only fingerprint and PIN. Only iOS reliably distinguishes
  /// Face ID here.
  static Future<bool> hasBiometricEnrolled() async {
    try {
      final available = await _auth.getAvailableBiometrics();
      return available.isNotEmpty;
    } on Exception catch (e) {
      debugPrint('Could not list biometrics: $e');
      return false;
    }
  }

  static Future<bool> isLockEnabled(int userId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_prefsKey(userId)) ?? true;
  }

  static Future<void> setLockEnabled(int userId, bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsKey(userId), enabled);
  }

  /// Prompts for face / fingerprint before revealing profile details.
  ///
  /// `biometricOnly` stays false so a student whose face fails in bad lighting
  /// can still fall back to their device PIN rather than being locked out.
  ///
  /// Note there is no availability pre-check here: it used to reject devices
  /// that were perfectly capable of prompting. We just prompt and let the
  /// platform tell us why if it refuses.
  ///
  /// Pass [biometricOnly] for sensitive actions that should not accept the PIN
  /// shortcut. Only do that after [hasBiometricEnrolled] returns true, or the
  /// prompt has no way to succeed and the user is simply locked out.
  static Future<LockResult> authenticate({
    String reason = 'Verify your identity to view your profile details',
    bool biometricOnly = false,
  }) async {
    try {
      final didAuth = await _auth.authenticate(
        localizedReason: reason,
        options: AuthenticationOptions(
          // When false the device PIN/pattern is accepted as a fallback.
          biometricOnly: biometricOnly,
          stickyAuth: true,
          useErrorDialogs: true,
        ),
      );
      return didAuth ? LockResult.success : LockResult.failed;
    } on PlatformException catch (e) {
      // Map the platform's reason instead of lumping everything into
      // "not enrolled", which previously told users with a working face
      // unlock to go and set one up.
      debugPrint('Biometric error: ${e.code} / ${e.message}');
      switch (e.code) {
        case 'NotEnrolled':
        case 'PasscodeNotSet':
          return LockResult.notEnrolled;
        case 'LockedOut':
        case 'PermanentlyLockedOut':
          return LockResult.lockedOut;
        default:
          // Includes no_fragment_activity and NotAvailable.
          return LockResult.error;
      }
    } on Exception catch (e) {
      debugPrint('Unexpected biometric failure: $e');
      return LockResult.error;
    }
  }
}
