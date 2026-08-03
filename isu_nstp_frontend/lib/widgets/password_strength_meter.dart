import 'package:flutter/material.dart';

import '../utils/password_policy.dart';

/// Live feedback under a password field: a strength bar plus a checklist of the
/// rules, so the student can see what is still missing instead of guessing.
///
/// Purely presentational - the field's own validator is what blocks submission.
class PasswordStrengthMeter extends StatelessWidget {
  /// The current text of the password field.
  final String password;

  const PasswordStrengthMeter({super.key, required this.password});

  static const Color isuGreen = Color(0xFF006837);

  Color _colorFor(PasswordStrength strength) {
    switch (strength) {
      case PasswordStrength.empty:
        return Colors.grey.shade300;
      case PasswordStrength.weak:
        return Colors.red.shade600;
      case PasswordStrength.fair:
        return Colors.orange.shade700;
      case PasswordStrength.strong:
        return isuGreen;
    }
  }

  /// How much of the bar to fill. Weak deliberately still shows something so
  /// the bar reads as "progress", not "broken".
  double _fractionFor(PasswordStrength strength) {
    switch (strength) {
      case PasswordStrength.empty:
        return 0;
      case PasswordStrength.weak:
        return 0.33;
      case PasswordStrength.fair:
        return 0.66;
      case PasswordStrength.strong:
        return 1;
    }
  }

  @override
  Widget build(BuildContext context) {
    final strength = PasswordPolicy.strengthOf(password);
    final color = _colorFor(strength);

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: _fractionFor(strength),
                    minHeight: 6,
                    backgroundColor: Colors.grey.shade300,
                    valueColor: AlwaysStoppedAnimation<Color>(color),
                  ),
                ),
              ),
              if (strength != PasswordStrength.empty) ...[
                const SizedBox(width: 10),
                Text(
                  PasswordPolicy.labelFor(strength),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          _rule(
            met: PasswordPolicy.hasMinLength(password),
            text: 'At least ${PasswordPolicy.minLength} characters',
          ),
          _rule(
            met: PasswordPolicy.hasNumber(password),
            text: 'At least 1 number',
          ),
          // Not required, but shows how to reach "Strong".
          _rule(
            met: PasswordPolicy.hasLetterCaseMix(password) ||
                PasswordPolicy.hasSymbol(password),
            text: 'Mix upper/lower case or add a symbol (for a strong password)',
            optional: true,
          ),
        ],
      ),
    );
  }

  Widget _rule({
    required bool met,
    required String text,
    bool optional = false,
  }) {
    final Color color;
    if (met) {
      color = isuGreen;
    } else if (optional) {
      color = Colors.grey;
    } else {
      color = Colors.grey.shade600;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            met
                ? Icons.check_circle
                : (optional ? Icons.star_outline : Icons.circle_outlined),
            size: 14,
            color: color,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 11.5,
                color: color,
                fontWeight: met ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
