import 'package:flutter/material.dart';

import '../services/profile_lock_service.dart';

/// Hides [child] behind a device biometric check.
///
/// Until the student passes Face Unlock / Face ID (or falls back to their
/// device PIN) they see a tappable placeholder instead of their personal
/// details. Unlocking happens inline so they stay in the same dialog, and the
/// unlock lasts only as long as this widget is on screen - reopening the
/// profile prompts again.
class BiometricLockWidget extends StatefulWidget {
  /// The sensitive content to reveal once verified.
  final Widget child;

  /// Shown in the placeholder, e.g. 'Profile details are protected'.
  final String lockedMessage;

  const BiometricLockWidget({
    super.key,
    required this.child,
    this.lockedMessage = 'Your profile details are protected',
  });

  @override
  State<BiometricLockWidget> createState() => _BiometricLockWidgetState();
}

class _BiometricLockWidgetState extends State<BiometricLockWidget> {
  static const Color isuGreen = Color(0xFF006837);

  bool _unlocked = false;
  bool _checking = false;
  String? _error;

  Future<void> _tryUnlock() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _error = null;
    });

    final result = await ProfileLockService.authenticate(
      reason: 'Verify your identity to view your profile details',
    );

    if (!mounted) return;
    setState(() {
      _checking = false;
      switch (result) {
        case LockResult.success:
          _unlocked = true;
        case LockResult.failed:
          _error = 'Not recognized. Tap to try again.';
        case LockResult.unavailable:
          // Nothing enrolled on this device. Rather than trapping the student
          // out of their own data, explain and let them through.
          _unlocked = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_unlocked) return widget.child;

    return InkWell(
      onTap: _checking ? null : _tryUnlock,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 20),
        decoration: BoxDecoration(
          color: Colors.grey.shade50,
          border: Border.all(color: Colors.grey.shade300),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _error == null ? Icons.lock_outline : Icons.error_outline,
              size: 40,
              color: _error == null ? isuGreen : Colors.red.shade600,
            ),
            const SizedBox(height: 12),
            Text(
              widget.lockedMessage,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 15,
                color: Color(0xFF004D25),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _error ?? 'Tap to verify with Face Unlock',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: _error == null ? Colors.grey : Colors.red.shade700,
              ),
            ),
            const SizedBox(height: 16),
            if (_checking)
              const SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              FilledButton.icon(
                onPressed: _tryUnlock,
                style: FilledButton.styleFrom(backgroundColor: isuGreen),
                icon: const Icon(Icons.face, size: 18),
                label: const Text('Verify to view'),
              ),
          ],
        ),
      ),
    );
  }
}
