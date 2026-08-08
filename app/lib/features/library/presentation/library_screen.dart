import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'library_providers.dart';

class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tracksAsync = ref.watch(tracksProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Musicat')),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.create_new_folder_outlined),
        label: const Text('Add folder'),
        onPressed: () => _pickAndScanFolder(context, ref),
      ),
      body: tracksAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => Center(child: Text('Error: $error')),
        data: (tracks) {
          if (tracks.isEmpty) {
            return const Center(
              child: Text('No tracks yet — add a music folder to get started.'),
            );
          }
          return ListView.builder(
            itemCount: tracks.length,
            itemBuilder: (context, index) {
              final track = tracks[index];
              return ListTile(
                leading: track.coverArtPath != null
                    ? Image.file(
                        File(track.coverArtPath!),
                        width: 48,
                        height: 48,
                        fit: BoxFit.cover,
                      )
                    : const Icon(Icons.music_note, size: 48),
                title: Text(track.title),
                subtitle: Text('${track.artist} — ${track.album}'),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _pickAndScanFolder(BuildContext context, WidgetRef ref) async {
    final folderPath = await FilePicker.getDirectoryPath();
    if (folderPath == null) return;

    final imported = await ref
        .read(libraryScannerProvider)
        .scanFolder(folderPath);

    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Imported $imported track(s).')));
  }
}
