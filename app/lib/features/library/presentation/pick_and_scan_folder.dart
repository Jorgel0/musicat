import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'library_providers.dart';

/// Opens a folder picker, scans it into the catalog, and remembers it in
/// the watched-folders list. Shared by the library screen's FAB and the
/// settings screen's folder manager.
Future<void> pickAndScanFolder(BuildContext context, WidgetRef ref) async {
  final folderPath = await FilePicker.getDirectoryPath();
  if (folderPath == null) return;

  final imported = await ref
      .read(libraryScannerProvider)
      .scanFolder(folderPath);
  await ref.read(libraryRepositoryProvider).addFolder(folderPath);

  if (!context.mounted) return;
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text('Imported $imported track(s).')));
}
