import 'package:flutter/material.dart';

import '../screens/login_screen.dart';
import '../services/session_service.dart';

/// Shared logout flow for every dashboard.
///
/// Sessions now survive closing the app, so signing out has to be deliberate:
/// a stray tap on the toolbar icon should not force someone to type their
/// password again. Confirm first, then clear the stored session.
class LogoutHelper {
  static const Color _isuGreen = Color(0xFF006837);

  /// Asks for confirmation and, if given, clears the session and returns to
  /// the login screen. Safe to call from any dashboard.
  static Future<void> confirmAndLogout(BuildContext context) async {
    final shouldLogout = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.logout, color: Colors.red, size: 26),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Log out?',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: const Text(
          'You will need to enter your username and password again to get '
          'back in. Stay logged in if you just want to close the app.',
          style: TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: _isuGreen, fontWeight: FontWeight.bold),
            ),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            icon: const Icon(Icons.logout, size: 18),
            label: const Text('Log out'),
          ),
        ],
      ),
    );

    if (shouldLogout != true) return;

    // Wipe the remembered session before navigating, otherwise the next launch
    // would silently restore the account they just signed out of.
    await SessionService.clear();

    // The dialog's await means this context may be gone by now.
    if (!context.mounted) return;

    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (context) => const LoginScreen()),
      (route) => false,
    );
  }
}
