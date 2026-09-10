import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../models/user_model.dart';
import '../services/profile_lock_service.dart';
import '../utils/password_policy.dart';
import '../widgets/password_strength_meter.dart';

/// Shared "Change Password" flow for every role.
///
/// The user proves who they are with their current password + account email,
/// receives a 6-digit code as a push notification (and email), then sets the
/// new password. Before the sheet opens, the device asks for a biometric match
/// (PIN deliberately refused) when one is enrolled, so an unlocked phone in
/// the wrong hands cannot take over the account.
class ChangePasswordFlow {
  static const Color isuGreen = Color(0xFF006837);
  static const Color isuDarkGreen = Color(0xFF004D25);

  /// Runs the biometric gate (if a biometric is enrolled) and opens the
  /// two-step change sheet. Call with the page context, not a dialog's.
  static Future<void> show(BuildContext context, UserModel user) async {
    final hasBiometric = await ProfileLockService.hasBiometricEnrolled();
    if (!context.mounted) return;

    if (!hasBiometric) {
      _showChangePasswordSheet(context, user);
      return;
    }

    final result = await ProfileLockService.authenticate(
      reason: 'Verify your identity to change your password',
      biometricOnly: true,
    );
    if (!context.mounted) return;

    switch (result) {
      case LockResult.success:
        _showChangePasswordSheet(context, user);
      case LockResult.failed:
        _showLockMessage(
          context,
          'Verification failed. Your password was not changed.',
          Colors.red,
        );
      case LockResult.lockedOut:
        _showLockMessage(
          context,
          'Too many attempts. Unlock your device the usual way, then try again.',
          Colors.orange,
        );
      case LockResult.notEnrolled:
      case LockResult.error:
        // The enrolment check passed a moment ago, so this is a device quirk
        // rather than a real absence. Fall back rather than trap the user.
        _showChangePasswordSheet(context, user);
    }
  }

  static void _showLockMessage(BuildContext context, String message, Color color) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Step 1: verify current password + email, then send the code.
  /// Returns null on success, or the error message to display.
  static Future<String?> _requestChangeCode(
    UserModel user,
    String currentPassword,
    String email,
  ) async {
    try {
      final response = await http
          .post(
            Uri.parse('${ApiConfig.baseUrl}/api/change-password/request-code/'),
            headers: const {
              'Content-Type': 'application/json',
              'ngrok-skip-browser-warning': 'true',
            },
            body: json.encode({
              'user_id': user.id,
              'current_password': currentPassword,
              'email': email,
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) return null;

      final data = json.decode(response.body) as Map<String, dynamic>;
      return data['detail']?.toString() ?? 'Could not send the code.';
    } on TimeoutException {
      return 'Connection timed out. Please try again.';
    } catch (e) {
      return 'Failed to reach server: $e';
    }
  }

  /// Step 2: confirm the code and apply the new password.
  static Future<String?> _confirmChange(
    UserModel user,
    String currentPassword,
    String code,
    String newPassword,
  ) async {
    try {
      final response = await http
          .post(
            Uri.parse('${ApiConfig.baseUrl}/api/change-password/confirm/'),
            headers: const {
              'Content-Type': 'application/json',
              'ngrok-skip-browser-warning': 'true',
            },
            body: json.encode({
              'user_id': user.id,
              'current_password': currentPassword,
              'code': code,
              'new_password': newPassword,
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) return null;

      final data = json.decode(response.body) as Map<String, dynamic>;
      return data['detail']?.toString() ?? 'Could not change your password.';
    } on TimeoutException {
      return 'Connection timed out. Please try again.';
    } catch (e) {
      return 'Failed to reach server: $e';
    }
  }

  static void _showChangePasswordSheet(
    BuildContext pageContext,
    UserModel user,
  ) {
    final currentPasswordController = TextEditingController();
    final emailController = TextEditingController(text: user.email);
    final codeController = TextEditingController();
    final newPasswordController = TextEditingController();
    final confirmPasswordController = TextEditingController();

    final step1Key = GlobalKey<FormState>();
    final step2Key = GlobalKey<FormState>();

    int step = 1;
    bool busy = false;
    bool obscureCurrent = true;
    bool obscureNew = true;
    String? error;

    showModalBottomSheet(
      context: pageContext,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            Future<void> submit() async {
              setSheetState(() => error = null);

              if (step == 1) {
                if (!step1Key.currentState!.validate()) return;
                setSheetState(() => busy = true);
                final failure = await _requestChangeCode(
                  user,
                  currentPasswordController.text,
                  emailController.text.trim(),
                );
                setSheetState(() {
                  busy = false;
                  if (failure == null) {
                    step = 2;
                  } else {
                    error = failure;
                  }
                });
              } else {
                if (!step2Key.currentState!.validate()) return;
                setSheetState(() => busy = true);
                final failure = await _confirmChange(
                  user,
                  currentPasswordController.text,
                  codeController.text.trim(),
                  newPasswordController.text,
                );
                setSheetState(() => busy = false);

                if (failure == null) {
                  // The sheet may have been torn down while the request was in
                  // flight, so confirm it is still on screen before popping.
                  if (sheetContext.mounted) Navigator.pop(sheetContext);
                  if (pageContext.mounted) {
                    _showPasswordChangedDialog(pageContext);
                  }
                } else {
                  setSheetState(() => error = failure);
                }
              }
            }

            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 20,
                // Lift the sheet above the keyboard.
                bottom: MediaQuery.of(context).viewInsets.bottom + 20,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.lock_reset, color: isuGreen),
                        const SizedBox(width: 8),
                        Text(
                          step == 1 ? 'Change Password' : 'Enter Code',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: isuDarkGreen,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed:
                              busy ? null : () => Navigator.pop(sheetContext),
                        ),
                      ],
                    ),

                    // Two-step progress hint.
                    Text(
                      'Step $step of 2',
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                    const SizedBox(height: 16),

                    if (error != null)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: Colors.red.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.red.shade200),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.error_outline,
                                color: Colors.red.shade700, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                error!,
                                style: TextStyle(
                                    color: Colors.red.shade700, fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                      ),

                    if (step == 1)
                      Form(
                        key: step1Key,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Confirm your current password and the email on '
                              'your account. We will push a 6-digit code to '
                              'your phone and email it to you.',
                              style:
                                  TextStyle(fontSize: 13, color: Colors.grey),
                            ),
                            const SizedBox(height: 16),
                            TextFormField(
                              controller: currentPasswordController,
                              obscureText: obscureCurrent,
                              decoration: InputDecoration(
                                labelText: 'Current Password',
                                border: const OutlineInputBorder(),
                                prefixIcon:
                                    const Icon(Icons.lock_outline, color: isuGreen),
                                suffixIcon: IconButton(
                                  icon: Icon(
                                    obscureCurrent
                                        ? Icons.visibility_off
                                        : Icons.visibility,
                                    color: Colors.grey,
                                  ),
                                  onPressed: () => setSheetState(
                                      () => obscureCurrent = !obscureCurrent),
                                ),
                              ),
                              validator: (v) => (v == null || v.isEmpty)
                                  ? 'Enter your current password.'
                                  : null,
                            ),
                            const SizedBox(height: 12),
                            TextFormField(
                              controller: emailController,
                              keyboardType: TextInputType.emailAddress,
                              decoration: const InputDecoration(
                                labelText: 'Account Email',
                                border: OutlineInputBorder(),
                                prefixIcon: Icon(Icons.email, color: isuGreen),
                              ),
                              validator: (v) {
                                final email = (v ?? '').trim();
                                if (email.isEmpty) return 'Enter your email.';
                                if (!email.contains('@')) {
                                  return 'Enter a valid email address.';
                                }
                                return null;
                              },
                            ),
                          ],
                        ),
                      )
                    else
                      Form(
                        key: step2Key,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'We sent a 6-digit code to your device and to '
                              '${emailController.text.trim()}.',
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: isuDarkGreen,
                              ),
                            ),
                            const SizedBox(height: 16),
                            TextFormField(
                              controller: codeController,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'Verification Code',
                                hintText: 'e.g. 123456',
                                border: OutlineInputBorder(),
                                prefixIcon: Icon(Icons.pin, color: isuGreen),
                              ),
                              validator: (v) => (v == null || v.trim().isEmpty)
                                  ? 'Enter the 6-digit code.'
                                  : null,
                            ),
                            const SizedBox(height: 12),
                            TextFormField(
                              controller: newPasswordController,
                              obscureText: obscureNew,
                              decoration: InputDecoration(
                                labelText: 'New Password',
                                border: const OutlineInputBorder(),
                                prefixIcon: const Icon(Icons.lock, color: isuGreen),
                                suffixIcon: IconButton(
                                  icon: Icon(
                                    obscureNew
                                        ? Icons.visibility_off
                                        : Icons.visibility,
                                    color: Colors.grey,
                                  ),
                                  onPressed: () => setSheetState(
                                      () => obscureNew = !obscureNew),
                                ),
                              ),
                              // Same rule the server enforces: 8+ chars, 1 number.
                              validator: PasswordPolicy.validate,
                              onChanged: (_) => setSheetState(() {}),
                            ),
                            PasswordStrengthMeter(
                              password: newPasswordController.text,
                            ),
                            const SizedBox(height: 12),
                            TextFormField(
                              controller: confirmPasswordController,
                              obscureText: obscureNew,
                              decoration: const InputDecoration(
                                labelText: 'Confirm New Password',
                                border: OutlineInputBorder(),
                                prefixIcon:
                                    Icon(Icons.lock_outline, color: isuGreen),
                              ),
                              validator: (v) => v != newPasswordController.text
                                  ? 'Passwords do not match.'
                                  : null,
                            ),
                            const SizedBox(height: 8),
                            TextButton.icon(
                              onPressed: busy
                                  ? null
                                  : () => setSheetState(() {
                                        step = 1;
                                        codeController.clear();
                                      }),
                              icon: const Icon(Icons.arrow_back, size: 16),
                              label: const Text('Back'),
                              style: TextButton.styleFrom(
                                  foregroundColor: Colors.grey),
                            ),
                          ],
                        ),
                      ),

                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: isuGreen,
                          foregroundColor: Colors.white,
                          minimumSize: const Size.fromHeight(48),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        onPressed: busy ? null : submit,
                        child: busy
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(
                                step == 1 ? 'Send Code' : 'Change Password',
                                style: const TextStyle(
                                    fontSize: 15, fontWeight: FontWeight.bold),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  static void _showPasswordChangedDialog(BuildContext context) {
    if (!context.mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.check_circle, color: isuGreen),
            SizedBox(width: 8),
            Text('Password Changed', style: TextStyle(fontSize: 18)),
          ],
        ),
        content: const Text(
          'Your password has been updated. Use your new password the next time '
          'you sign in.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK', style: TextStyle(color: isuGreen)),
          ),
        ],
      ),
    );
  }
}