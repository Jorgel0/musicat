import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/soulseek/soulseek_client.dart';
import '../../settings/soulseek/presentation/soulseek_config_controller.dart';
import '../domain/group_search_results.dart';
import 'cover_art_providers.dart';
import 'search_controller.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _queryController = TextEditingController();

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  void _submit() {
    final query = _queryController.text.trim();
    if (query.isEmpty) return;
    ref.read(searchControllerProvider.notifier).search(query);
  }

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(soulseekClientProvider);
    final state = ref.watch(searchControllerProvider);

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _queryController,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: 'Search Soulseek…',
            border: InputBorder.none,
          ),
          onSubmitted: (_) => _submit(),
        ),
        actions: [
          IconButton(icon: const Icon(Icons.search), onPressed: _submit),
        ],
      ),
      body: _buildBody(context, client, state),
    );
  }

  Widget _buildBody(
    BuildContext context,
    SoulseekClient? client,
    SearchState state,
  ) {
    if (client == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'No Soulseek backend configured yet.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => context.push('/settings/soulseek'),
                child: const Text('Set up in Settings'),
              ),
            ],
          ),
        ),
      );
    }

    if (state.errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(state.errorMessage!, textAlign: TextAlign.center),
        ),
      );
    }

    if (state.query.isEmpty) {
      return const Center(child: Text('Search for something to get started.'));
    }

    if (state.results.isEmpty) {
      return state.isSearching
          ? const Center(child: CircularProgressIndicator())
          : const Center(child: Text('No results.'));
    }

    final albums = groupSearchResultsByAlbum(state.results, state.query);

    return ListView.builder(
      itemCount: albums.length,
      itemBuilder: (context, index) => _AlbumResultTile(album: albums[index]),
    );
  }
}

class _AlbumResultTile extends StatelessWidget {
  const _AlbumResultTile({required this.album});

  final SoulseekAlbumResult album;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      leading: _CoverArtThumbnail(
        artist: album.artist,
        album: album.album,
        size: 48,
      ),
      title: Text(album.album),
      subtitle: Text(album.artist),
      children: [
        for (final song in album.songs)
          _SongResultTile(song: song, artist: album.artist, album: album.album),
      ],
    );
  }
}

class _SongResultTile extends ConsumerWidget {
  const _SongResultTile({
    required this.song,
    required this.artist,
    required this.album,
  });

  final SoulseekSongResult song;
  final String artist;
  final String album;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final best = song.bestSource;
    final hasAlternates = song.sources.length > 1;

    return ListTile(
      leading: _CoverArtThumbnail(artist: artist, album: album, size: 40),
      title: Text(song.title),
      subtitle: Text(_sourceSummary(best, song.sources.length)),
      trailing: IconButton(
        icon: const Icon(Icons.download_outlined),
        onPressed: () => _download(context, ref, best),
      ),
      onTap: hasAlternates ? () => _showSourcePicker(context, ref) : null,
    );
  }

  Future<void> _download(
    BuildContext context,
    WidgetRef ref,
    SoulseekSongSource source,
  ) async {
    final client = ref.read(soulseekClientProvider);
    if (client == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await client.enqueueDownload(
        username: source.username,
        files: [source.file],
      );
      messenger.showSnackBar(
        const SnackBar(content: Text('Queued for download.')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not start download: $e')),
      );
    }
  }

  void _showSourcePicker(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final source in song.sources)
              ListTile(
                title: Text(source.username),
                subtitle: Text(_sourceDetail(source)),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _download(context, ref, source);
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _CoverArtThumbnail extends ConsumerWidget {
  const _CoverArtThumbnail({
    required this.artist,
    required this.album,
    required this.size,
  });

  final String artist;
  final String album;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coverArt = ref.watch(
      coverArtUrlProvider((artist: artist, album: album)),
    );

    return SizedBox(
      width: size,
      height: size,
      child: coverArt.when(
        data: (url) => url == null
            ? const Icon(Icons.album_outlined)
            : ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Image.network(
                  url,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) =>
                      const Icon(Icons.album_outlined),
                ),
              ),
        loading: () => const Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
        error: (error, stackTrace) => const Icon(Icons.album_outlined),
      ),
    );
  }
}

String _sourceSummary(SoulseekSongSource source, int sourceCount) {
  final parts = <String>[];
  if (source.file.bitRateKbps != null) {
    parts.add('${source.file.bitRateKbps} kbps');
  }
  if (sourceCount > 1) parts.add('$sourceCount sources');
  return parts.join(' • ');
}

String _sourceDetail(SoulseekSongSource source) {
  final parts = <String>[];
  if (source.file.bitRateKbps != null) {
    parts.add('${source.file.bitRateKbps} kbps');
  }
  parts.add(
    source.hasFreeUploadSlot ? 'free slot' : 'queue: ${source.queueLength}',
  );
  return parts.join(' • ');
}
