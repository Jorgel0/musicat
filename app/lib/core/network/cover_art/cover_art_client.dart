/// Best-effort cover art lookup by artist/album name — Soulseek search
/// results carry no artwork at all, so this queries a separate, unrelated
/// service based on the artist/album guessed from a filename (see
/// core/network/soulseek/soulseek_filename_parser.dart). See ADR 0012.
abstract class CoverArtClient {
  /// Returns `null` if nothing reasonable is found — never throws.
  Future<String?> findCoverArtUrl({
    required String artist,
    required String album,
  });
}
