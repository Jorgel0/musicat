/// Soulseek gives no real metadata for a search result — just a remote
/// file path, and sometimes embedded audio properties (bitrate/duration).
/// This is a best-effort guess at artist/album/title from that path alone,
/// so search results can be grouped the way the rest of the app organizes
/// a library instead of by which peer happens to be sharing the file. It
/// will get things wrong on messy real-world shares — see ADR 0011.
class ParsedSoulseekFilename {
  const ParsedSoulseekFilename({
    required this.artist,
    required this.album,
    required this.title,
  });

  final String artist;
  final String album;
  final String title;
}

ParsedSoulseekFilename parseSoulseekFilename(String remotePath) {
  final segments = remotePath
      .split(RegExp(r'[\\/]'))
      .where((s) => s.trim().isNotEmpty)
      .toList();

  final filename = segments.isNotEmpty ? segments.last : remotePath;
  final folder = segments.length >= 2 ? segments[segments.length - 2] : '';

  final title = _titleFromFilename(filename);
  final (artist, album) = _artistAndAlbumFromFolder(folder);

  return ParsedSoulseekFilename(
    artist: artist.isNotEmpty ? artist : 'Unknown artist',
    album: album.isNotEmpty ? album : 'Unknown album',
    title: title.isNotEmpty ? title : filename,
  );
}

String _titleFromFilename(String filename) {
  var name = filename;
  final dot = name.lastIndexOf('.');
  if (dot > 0) name = name.substring(0, dot);
  // Strip a leading track number: "01", "01.", "01 -", "01_"...
  name = name.replaceFirst(RegExp(r'^\s*\d{1,3}\s*[-._]?\s*'), '');
  return name.trim();
}

/// Folders are commonly named "Artist - Album" or "Artist - Album (Year)"
/// — strip a year marker, then split on the first " - ". No separator
/// means we can't tell artist from album, so the whole (cleaned) folder
/// name becomes the album and the artist is left for the caller to
/// default to "Unknown artist".
(String, String) _artistAndAlbumFromFolder(String folder) {
  final cleaned = folder.replaceAll(RegExp(r'[\(\[]\d{4}[\)\]]'), '').trim();
  final separator = RegExp(r'\s-\s').firstMatch(cleaned);
  if (separator == null) return ('', cleaned);
  return (
    cleaned.substring(0, separator.start).trim(),
    cleaned.substring(separator.end).trim(),
  );
}
