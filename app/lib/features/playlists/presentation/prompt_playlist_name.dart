import 'package:flutter/material.dart';

/// Shows a dialog asking for a playlist name. Returns `null` if cancelled.
/// Pass [initialValue] to pre-fill it for a rename.
Future<String?> promptPlaylistName(
  BuildContext context, {
  String? initialValue,
}) {
  final controller = TextEditingController(text: initialValue);
  final isRename = initialValue != null;

  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(isRename ? 'Rename playlist' : 'New playlist'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Name'),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text),
          child: Text(isRename ? 'Rename' : 'Create'),
        ),
      ],
    ),
  );
}
