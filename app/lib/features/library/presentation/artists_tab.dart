import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'library_providers.dart';

class ArtistsTab extends ConsumerWidget {
  const ArtistsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artists = ref.watch(artistsProvider);

    if (artists.isEmpty) {
      return const Center(
        child: Text('No artists yet — add a music folder to get started.'),
      );
    }

    return ListView.builder(
      itemCount: artists.length,
      itemBuilder: (context, index) {
        final artist = artists[index];
        return ListTile(
          leading: const CircleAvatar(child: Icon(Icons.person)),
          title: Text(artist.name),
          subtitle: Text(
            '${artist.albumCount} album(s) · ${artist.trackCount} song(s)',
          ),
          onTap: () => context.push('/artists/detail', extra: artist.name),
        );
      },
    );
  }
}
