import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../models/user_model.dart';

/// Lets a student explain why they missed a session, or why they failed the
/// random presence checks while they were actually there.
///
/// The letter goes to the instructor who owns the session. Nothing is marked
/// "Excused" until that instructor approves it, so this dialog deliberately
/// promises a review rather than a correction.
///
/// Returns `true` when a letter was filed, so the caller can refresh.
Future<bool> showSubmitExcuseDialog({
  required BuildContext context,
  required UserModel user,
  required Map<String, dynamic> record,
}) async {
  final sessionId = record['session_id'];
  if (sessionId == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('This activity cannot be excused.'),
        backgroundColor: Colors.red,
      ),
    );
    return false;
  }

  final submitted = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ExcuseDialog(
      user: user,
      sessionId: sessionId is int ? sessionId : int.parse('$sessionId'),
      title: record['title']?.toString() ?? 'Activity',
      className: record['class_name']?.toString() ?? '',
      dateTime: record['date_time']?.toString() ?? '',
    ),
  );

  return submitted ?? false;
}

class _ExcuseDialog extends StatefulWidget {
  final UserModel user;
  final int sessionId;
  final String title;
  final String className;
  final String dateTime;

  const _ExcuseDialog({
    required this.user,
    required this.sessionId,
    required this.title,
    required this.className,
    required this.dateTime,
  });

  @override
  State<_ExcuseDialog> createState() => _ExcuseDialogState();
}

class _ExcuseDialogState extends State<_ExcuseDialog> {
  static const Color isuGreen = Color(0xFF006837);

  /// The shortest reason we will forward to an instructor. "sick" on its own
  /// gives them nothing to rule on.
  static const int _minReasonLength = 10;

  final TextEditingController _reasonController = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final reason = _reasonController.text.trim();
    if (reason.length < _minReasonLength) {
      setState(() {
        _error = 'Please explain in a little more detail '
            '(at least $_minReasonLength characters).';
      });
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      final response = await http
          .post(
            Uri.parse(ApiConfig.excusesUrl),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'student_id': widget.user.id,
              'session_id': widget.sessionId,
              'reason': reason,
            }),
          )
          .timeout(const Duration(seconds: 20));

      if (!mounted) return;

      if (response.statusCode == 201 || response.statusCode == 200) {
        Navigator.of(context).pop(true);
        return;
      }

      // The backend explains the refusal (duplicate letter, session too old,
      // not enrolled); surfacing its wording beats a generic failure.
      String message = 'Could not submit your excuse. Please try again.';
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map && decoded['error'] != null) {
          message = decoded['error'].toString();
        }
      } catch (_) {
        // Non-JSON error body: keep the generic message.
      }

      setState(() {
        _submitting = false;
        _error = message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = 'Network error. Check your connection and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: const Row(
        children: [
          Icon(Icons.drafts_outlined, color: isuGreen),
          SizedBox(width: 8),
          Expanded(child: Text('File an excuse', style: TextStyle(fontSize: 18))),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.title,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  if (widget.className.isNotEmpty)
                    Text(
                      widget.className,
                      style: const TextStyle(fontSize: 11, color: Colors.black54),
                    ),
                  if (widget.dateTime.isNotEmpty)
                    Text(
                      widget.dateTime,
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _reasonController,
              enabled: !_submitting,
              maxLines: 5,
              maxLength: 1000,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: 'Reason',
                hintText: 'Explain why you missed this activity, or why you '
                    'could not answer the presence checks.',
                hintStyle: const TextStyle(fontSize: 12),
                alignLabelWithHint: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 4),
              Text(
                _error!,
                style: const TextStyle(color: Colors.red, fontSize: 12),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 14, color: Colors.grey.shade600),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Your instructor decides whether this is approved. Your '
                    'record only changes if they approve it.',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _submitting ? null : _submit,
          style: ElevatedButton.styleFrom(
            backgroundColor: isuGreen,
            foregroundColor: Colors.white,
          ),
          child: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('Submit'),
        ),
      ],
    );
  }
}

/// Small coloured pill describing where an excuse currently stands.
///
/// Shared by the student history rows and the instructor review queue so the
/// same letter never looks like two different things in two places.
class ExcuseStatusChip extends StatelessWidget {
  final String status;

  const ExcuseStatusChip({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final normalized = status.toLowerCase();

    final MaterialColor color;
    final IconData icon;
    final String label;
    switch (normalized) {
      case 'approved':
        color = Colors.green;
        icon = Icons.verified_outlined;
        label = 'Excuse approved';
        break;
      case 'rejected':
        color = Colors.red;
        icon = Icons.do_not_disturb_on_outlined;
        label = 'Excuse rejected';
        break;
      default:
        color = Colors.blue;
        icon = Icons.hourglass_top_outlined;
        label = 'Excuse pending';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.shade50,
        border: Border.all(color: color.shade300),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color.shade700),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: color.shade900,
            ),
          ),
        ],
      ),
    );
  }
}
