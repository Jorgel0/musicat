import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/cover_art/cover_art_client.dart';
import '../../../core/network/cover_art/itunes_cover_art_client.dart';

final coverArtClientProvider = Provider<CoverArtClient>(
  (ref) => ItunesCoverArtClient(),
);

/// Cached per (artist, album) for the life of the app — the search
/// results screen may show the same album many times (once per song row),
/// and the underlying API is rate-limited, so avoiding repeat lookups
/// matters more than freshness here.
final coverArtUrlProvider =
    FutureProvider.family<String?, ({String artist, String album})>((ref, key) {
      return ref
          .watch(coverArtClientProvider)
          .findCoverArtUrl(artist: key.artist, album: key.album);
    });
