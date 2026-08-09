import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'library_providers.dart';

class AlbumsTab extends ConsumerWidget {
  const AlbumsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albums = ref.watch(albumsProvider);

    if (albums.isEmpty) {
      return const Center(
        child: Text('No albums yet — add a music folder to get started.'),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 16,
        crossAxisSpacing: 12,
        childAspectRatio: 0.78,
      ),
      itemCount: albums.length,
      itemBuilder: (context, index) {
        final album = albums[index];
        return InkWell(
          onTap: () => context.push(
            '/albums/detail',
            extra: (albumName: album.name, artistName: album.artist),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: album.coverArtPath != null
                      ? Image.file(
                          File(album.coverArtPath!),
                          fit: BoxFit.cover,
                          width: double.infinity,
                        )
                      : Container(
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest,
                          alignment: Alignment.center,
                          child: const Icon(Icons.album, size: 48),
                        ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                album.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              Text(
                album.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        );
      },
    );
  }
}
