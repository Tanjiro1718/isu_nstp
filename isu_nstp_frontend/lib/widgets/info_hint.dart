import 'package:flutter/material.dart';

/// A tappable info icon that reveals an explanation in a dialog when tapped.
///
/// Keeps forms and lists compact: the explanatory text lives behind the icon
/// instead of taking up a paragraph on screen.
class InfoHint extends StatelessWidget {
  final String message;
  final double iconSize;
  final Color? color;

  static const Color isuGreen = Color(0xFF006837);

  const InfoHint({
    super.key,
    required this.message,
    this.iconSize = 16,
    this.color,
  });

  /// Shows the explanation for [message] in a rounded dialog.
  static void showInfo(
    BuildContext context,
    String message, {
    String title = 'Good to know',
  }) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.info_outline, color: isuGreen),
            const SizedBox(width: 8),
            Text(title, style: const TextStyle(fontSize: 18)),
          ],
        ),
        content: Text(
          message,
          style: const TextStyle(
            fontSize: 14,
            color: Colors.black87,
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'Close',
              style: TextStyle(color: isuGreen, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'More info',
      child: InkWell(
        onTap: () => showInfo(context, message),
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Icon(
            Icons.info_outline,
            size: iconSize,
            color: color ?? Colors.grey.shade600,
          ),
        ),
      ),
    );
  }
}

/// A section heading with its explanation tucked behind an inline info icon.
///
/// Lets titles like "When Does It Start?" carry their hint on the same line
/// instead of spending a full row on paragraph text.
class InfoHeading extends StatelessWidget {
  final String title;
  final String message;
  final TextStyle? titleStyle;

  const InfoHeading({
    super.key,
    required this.title,
    required this.message,
    this.titleStyle,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            title,
            style:
                titleStyle ??
                const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ),
        const SizedBox(width: 6),
        InfoHint(message: message),
      ],
    );
  }
}
