import 'dart:io';
import 'dart:typed_data';

import 'package:audiotags/audiotags.dart' as audiotags;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/library_repository.dart';
import '../domain/track.dart';

const _supportedExtensions = {'.mp3', '.flac', '.m4a', '.ogg', '.wav', '.opus'};

/// The handful of tag fields the scanner cares about, decoupled from
/// `audiotags`'s own `Tag` type so the scanning logic can be tested with a
/// fake reader instead of the real native (flutter_rust_bridge) plugin,
/// which `flutter test` can't load outside of a real app run.
class ParsedAudioTag {
  const ParsedAudioTag({
    this.title,
    this.artist,
    this.album,
    this.trackNumber,
    this.durationSeconds,
    this.coverArtBytes,
  });

  final String? title;
  final String? artist;
  final String? album;
  final int? trackNumber;
  final int? durationSeconds;
  final Uint8List? coverArtBytes;
}

typedef AudioTagReader = Future<ParsedAudioTag?> Function(String path);

Future<ParsedAudioTag?> _readTagWithAudiotags(String path) async {
  final tag = await audiotags.AudioTags.read(path);
  if (tag == null) return null;
  return ParsedAudioTag(
    title: tag.title,
    artist: tag.trackArtist,
    album: tag.album,
    trackNumber: tag.trackNumber,
    durationSeconds: tag.duration,
    coverArtBytes: tag.pictures.isNotEmpty ? tag.pictures.first.bytes : null,
  );
}

/// Walks a folder for audio files, reads their tags, and upserts them into
/// the library via [LibraryRepository]. Runs on the desktop targets today;
/// Android's real import path is `MediaStore`, tracked as a follow-up (see
/// `docs/architecture.md`), not implemented here yet.
class LibraryScanner {
  LibraryScanner(this._repository, {AudioTagReader? tagReader})
    : _readTag = tagReader ?? _readTagWithAudiotags;

  final LibraryRepository _repository;
  final AudioTagReader _readTag;

  Future<int> scanFolder(String folderPath) async {
    final dir = Directory(folderPath);
    if (!dir.existsSync()) return 0;

    final coversDir = Directory(
      p.join((await getApplicationSupportDirectory()).path, 'covers'),
    )..createSync(recursive: true);

    var importedCount = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (!_supportedExtensions.contains(
        p.extension(entity.path).toLowerCase(),
      )) {
        continue;
      }

      final tag = await _readTag(entity.path);
      final coverArtPath = await _extractCoverArt(tag, entity.path, coversDir);

      await _repository.upsertTrack(
        filePath: entity.path,
        title: tag?.title ?? p.basenameWithoutExtension(entity.path),
        artist: tag?.artist ?? 'Unknown artist',
        album: tag?.album ?? 'Unknown album',
        source: TrackSource.local,
        trackNumber: tag?.trackNumber,
        duration: tag?.durationSeconds == null
            ? null
            : Duration(seconds: tag!.durationSeconds!),
        coverArtPath: coverArtPath,
      );
      importedCount++;
    }
    return importedCount;
  }

  Future<String?> _extractCoverArt(
    ParsedAudioTag? tag,
    String trackPath,
    Directory coversDir,
  ) async {
    if (tag == null || tag.coverArtBytes == null) return null;

    final coverFile = File(
      p.join(coversDir.path, '${trackPath.hashCode.abs()}.img'),
    );
    await coverFile.writeAsBytes(tag.coverArtBytes!);
    return coverFile.path;
  }
}
