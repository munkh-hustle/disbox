import 'package:flutter/material.dart';

/// A dialog that shows upload/download progress.
class ProgressDialog extends StatelessWidget {
  final String title;
  final String message;
  final double? progress; // null for indeterminate

  const ProgressDialog({
    super.key,
    required this.title,
    required this.message,
    this.progress,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message),
          const SizedBox(height: 16),
          progress != null
              ? Column(
                  children: [
                    LinearProgressIndicator(value: progress),
                    const SizedBox(height: 8),
                    Text('${(progress! * 100).toInt()}%'),
                  ],
                )
              : const CircularProgressIndicator(),
        ],
      ),
    );
  }
}
