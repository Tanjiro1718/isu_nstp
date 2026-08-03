/// Password rules for the whole app.
///
/// Mirrors attendance/password_policy.py - the server re-checks everything here
/// because a direct API call never runs this code. Change both together.
library;

/// How strong a password looks, purely for feedback in the UI.
enum PasswordStrength { empty, weak, fair, strong }

class PasswordPolicy {
  static const int minLength = 8;

  /// The hard requirements, in the order they should be shown to the user.
  static bool hasMinLength(String pw) => pw.length >= minLength;
  static bool hasNumber(String pw) => pw.contains(RegExp(r'\d'));

  /// Optional extras that only push the strength meter higher.
  static bool hasLetterCaseMix(String pw) =>
      pw.contains(RegExp(r'[a-z]')) && pw.contains(RegExp(r'[A-Z]'));
  static bool hasSymbol(String pw) => pw.contains(RegExp(r'[^A-Za-z0-9]'));

  /// Returns the first unmet requirement, or null when [pw] is acceptable.
  ///
  /// Wire this straight into a TextFormField validator.
  static String? validate(String? pw) {
    final value = pw ?? '';
    if (value.isEmpty) return 'Password is required.';
    if (!hasMinLength(value)) {
      return 'Password must be at least $minLength characters.';
    }
    if (!hasNumber(value)) return 'Password must include at least 1 number.';
    return null;
  }

  /// True when the password clears the minimum bar and can be submitted.
  static bool isAcceptable(String pw) => validate(pw) == null;

  /// Scores the password for the strength meter.
  ///
  /// Anything that fails the required rules is [PasswordStrength.weak] no
  /// matter how exotic it looks - the meter should never read "strong" on a
  /// password the form will reject. Reaching [PasswordStrength.strong] needs
  /// the basics plus two of: mixed case, a symbol, or 12+ characters.
  static PasswordStrength strengthOf(String pw) {
    if (pw.isEmpty) return PasswordStrength.empty;
    if (!isAcceptable(pw)) return PasswordStrength.weak;

    var bonus = 0;
    if (hasLetterCaseMix(pw)) bonus++;
    if (hasSymbol(pw)) bonus++;
    if (pw.length >= 12) bonus++;

    if (bonus >= 2) return PasswordStrength.strong;
    return PasswordStrength.fair;
  }

  static String labelFor(PasswordStrength strength) {
    switch (strength) {
      case PasswordStrength.empty:
        return '';
      case PasswordStrength.weak:
        return 'Weak';
      case PasswordStrength.fair:
        return 'Good';
      case PasswordStrength.strong:
        return 'Strong';
    }
  }
}
