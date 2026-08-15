import '../../../core/network/soulseek/soulseek_client.dart';
import '../../../core/network/soulseek/soulseek_filename_parser.dart';

/// One peer's copy of a song — the search screen lets the user pick among
/// these when more than one peer has the same song.
class SoulseekSongSource {
  const SoulseekSongSource({
    required this.username,
    required this.file,
    required this.hasFreeUploadSlot,
    required this.queueLength,
    required this.uploadSpeedBytesPerSecond,
  });

  final String username;
  final SoulseekFile file;
  final bool hasFreeUploadSlot;
  final int queueLength;
  final int uploadSpeedBytesPerSecond;
}

/// A distinct song, aggregated across every peer response that appears to
/// offer it (matched by parsed artist+album+title).
class SoulseekSongResult {
  const SoulseekSongResult({required this.title, required this.sources});

  final String title;
  final List<SoulseekSongSource> sources;

  /// The source most likely to give a fast, complete download: a free
  /// upload slot first, then the fewest people ahead in queue, then the
  /// highest bitrate.
  SoulseekSongSource get bestSource {
    final sorted = [...sources]
      ..sort((a, b) {
        if (a.hasFreeUploadSlot != b.hasFreeUploadSlot) {
          return a.hasFreeUploadSlot ? -1 : 1;
        }
        if (a.queueLength != b.queueLength) {
          return a.queueLength.compareTo(b.queueLength);
        }
        return (b.file.bitRateKbps ?? 0).compareTo(a.file.bitRateKbps ?? 0);
      });
    return sorted.first;
  }
}

class SoulseekAlbumResult {
  const SoulseekAlbumResult({
    required this.artist,
    required this.album,
    required this.songs,
  });

  final String artist;
  final String album;
  final List<SoulseekSongResult> songs;

  /// Total peers offering any song in this album — used as a popularity
  /// tiebreaker when sorting: a release many peers share is more likely to
  /// be a real, correctly-matched result than a one-off.
  int get sourceCount => songs.fold(0, (n, s) => n + s.sources.length);
}

/// Groups raw per-peer search responses into Artist > Album > Song, the
/// way the rest of the app already organizes a library — rather than by
/// which peer happens to be sharing a file, which is what slskd itself
/// returns. Best-effort only; see ADR 0011 for why filename-based grouping
/// can't be exact.
///
/// Albums are sorted by relevance to [query] first (does the artist,
/// album, or any song title actually match what was searched for?), then
/// by [SoulseekAlbumResult.sourceCount] as a tiebreaker — with hundreds of
/// peer responses, alphabetical order buries the results that actually
/// match under whatever "Unknown artist" or unrelated folder name happens
/// to sort first.
List<SoulseekAlbumResult> groupSearchResultsByAlbum(
  List<SoulseekSearchResult> peerResults,
  String query,
) {
  final songsByKey = <String, _SongAccumulator>{};

  for (final peer in peerResults) {
    for (final file in peer.files) {
      final parsed = parseSoulseekFilename(file.filename);
      final key =
          '${parsed.artist.toLowerCase()}|${parsed.album.toLowerCase()}|'
          '${parsed.title.toLowerCase()}';
      final accumulator = songsByKey.putIfAbsent(
        key,
        () => _SongAccumulator(
          artist: parsed.artist,
          album: parsed.album,
          title: parsed.title,
        ),
      );
      accumulator.sources.add(
        SoulseekSongSource(
          username: peer.username,
          file: file,
          hasFreeUploadSlot: peer.hasFreeUploadSlot,
          queueLength: peer.queueLength,
          uploadSpeedBytesPerSecond: peer.uploadSpeedBytesPerSecond,
        ),
      );
    }
  }

  final songsByAlbumKey = <String, List<_SongAccumulator>>{};
  for (final accumulator in songsByKey.values) {
    final key =
        '${accumulator.artist.toLowerCase()}|${accumulator.album.toLowerCase()}';
    songsByAlbumKey.putIfAbsent(key, () => []).add(accumulator);
  }

  final albums = songsByAlbumKey.values.map((songAccumulators) {
    final first = songAccumulators.first;
    final songs = songAccumulators.map((a) => a.toResult()).toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return SoulseekAlbumResult(
      artist: first.artist,
      album: first.album,
      songs: songs,
    );
  }).toList();

  final queryTokens = query
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty)
      .toList();

  albums.sort((a, b) {
    final relevanceCompare = _relevance(
      b,
      queryTokens,
    ).compareTo(_relevance(a, queryTokens));
    return relevanceCompare != 0
        ? relevanceCompare
        : b.sourceCount.compareTo(a.sourceCount);
  });

  return albums;
}

/// How well [album] matches the searched-for [queryTokens]: an exact
/// artist or album match ranks highest, otherwise the fraction of query
/// words found anywhere in the artist, album, or song titles.
double _relevance(SoulseekAlbumResult album, List<String> queryTokens) {
  if (queryTokens.isEmpty) return 0;

  final query = queryTokens.join(' ');
  if (album.artist.toLowerCase() == query ||
      album.album.toLowerCase() == query) {
    return 2;
  }

  final songTitles = album.songs.map((s) => s.title).join(' ');
  final haystack = '${album.artist} ${album.album} $songTitles'.toLowerCase();
  final matched = queryTokens.where(haystack.contains).length;
  return matched / queryTokens.length;
}

class _SongAccumulator {
  _SongAccumulator({
    required this.artist,
    required this.album,
    required this.title,
  });

  final String artist;
  final String album;
  final String title;
  final List<SoulseekSongSource> sources = [];

  SoulseekSongResult toResult() =>
      SoulseekSongResult(title: title, sources: sources);
}
