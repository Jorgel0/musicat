import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import 'library_providers.dart';

/// Opens a folder picker, scans it into the catalog, and remembers it in
/// the watched-folders list. Shared by the library screen's FAB and the
/// settings screen's folder manager.
Future<void> pickAndScanFolder(BuildContext context, WidgetRef ref) async {
  if (!await _ensureAudioPermission()) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Musicat needs permission to read audio files to scan a folder.',
        ),
      ),
    );
    return;
  }

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

/// The SAF folder picker only grants a `content://` URI permission; the
/// scanner then reads that folder with plain `dart:io`, which Android's
/// scoped storage silently empties out unless the app also holds a real
/// storage permission. `READ_MEDIA_AUDIO` (Android 13+, via
/// [Permission.audio]) is the modern one; [Permission.storage] covers
/// `READ_EXTERNAL_STORAGE` on older versions. See
/// docs/adr/0009-android-storage-permission.md.
Future<bool> _ensureAudioPermission() async {
  if (!Platform.isAndroid) return true;
  final statuses = await [Permission.audio, Permission.storage].request();
  return statuses.values.any((status) => status.isGranted);
}
