import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicat/core/database/app_database.dart';
import 'package:musicat/features/library/data/library_repository_drift.dart';
import 'package:musicat/features/library/data/library_scanner.dart';
import 'package:musicat/features/library/domain/track.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// `getApplicationSupportDirectory()` normally goes through a platform
/// channel; `flutter test` has no native side to answer it, so the scanner
/// test points it at a plain temp directory instead of mocking a channel.
class _TempDirPathProvider extends PathProviderPlatform {
  _TempDirPathProvider(this._path);
  final String _path;

  @override
  Future<String?> getApplicationSupportPath() async => _path;
}

final _fakeTagsByFileName = <String, ParsedAudioTag>{
  '01 Low Tone.mp3': ParsedAudioTag(
    title: 'Low Tone',
    artist: 'Sine Waves',
    album: 'Test Wave EP',
    trackNumber: 1,
    durationSeconds: 5,
    coverArtBytes: Uint8List.fromList([1, 2, 3]),
  ),
  '02 High Tone.flac': ParsedAudioTag(
    title: 'High Tone',
    artist: 'Sine Waves',
    album: 'Test Wave EP',
    trackNumber: 2,
    durationSeconds: 5,
    coverArtBytes: Uint8List.fromList([4, 5, 6]),
  ),
  '03 Noise Interlude.ogg': const ParsedAudioTag(
    title: 'Noise Interlude',
    artist: 'Sine Waves',
    album: 'Test Wave EP',
    trackNumber: 3,
    durationSeconds: 3,
    // No embedded picture, matching the real fixture.
  ),
};

/// The real `audiotags` (flutter_rust_bridge) plugin needs a native library
/// that's only available in a fully built app, not under plain `flutter
/// test` — so this fakes tag *content* while still exercising the real
/// scanner logic (file walking, extension filtering, cover-art writing)
/// against real files on disk. See test/fixtures/sample_library for the
/// fixtures and how they were generated.
Future<ParsedAudioTag?> _fakeTagReader(String path) async =>
    _fakeTagsByFileName[p.basename(path)];

void main() {
  late AppDatabase db;
  late DriftLibraryRepository repository;
  late LibraryScanner scanner;
  late Directory supportDir;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repository = DriftLibraryRepository(db);
    scanner = LibraryScanner(repository, tagReader: _fakeTagReader);
    supportDir = Directory.systemTemp.createTempSync('musicat_test_');
    PathProviderPlatform.instance = _TempDirPathProvider(supportDir.path);
  });

  tearDown(() {
    db.close();
    supportDir.deleteSync(recursive: true);
  });

  test(
    'imports every supported audio file with correct tags and duration',
    () async {
      final fixtureDir = p.join(
        Directory.current.path,
        'test',
        'fixtures',
        'sample_library',
      );

      final imported = await scanner.scanFolder(fixtureDir);
      expect(imported, 3);

      final tracks = await repository.watchAllTracks().first;
      final byTitle = {for (final t in tracks) t.title: t};

      expect(
        byTitle.keys,
        containsAll(['Low Tone', 'High Tone', 'Noise Interlude']),
      );

      final lowTone = byTitle['Low Tone']!;
      expect(lowTone.artist, 'Sine Waves');
      expect(lowTone.album, 'Test Wave EP');
      expect(lowTone.trackNumber, 1);
      expect(lowTone.source, TrackSource.local);
      expect(lowTone.duration, const Duration(seconds: 5));
      expect(lowTone.coverArtPath, isNotNull);
      expect(File(lowTone.coverArtPath!).readAsBytesSync(), [1, 2, 3]);

      final highTone = byTitle['High Tone']!;
      expect(highTone.trackNumber, 2);
      expect(highTone.duration, const Duration(seconds: 5));
      expect(highTone.coverArtPath, isNotNull);

      // The ogg fixture has no embedded picture — the scanner should leave
      // coverArtPath null rather than inventing one.
      final noise = byTitle['Noise Interlude']!;
      expect(noise.trackNumber, 3);
      expect(noise.duration, const Duration(seconds: 3));
      expect(noise.coverArtPath, isNull);
    },
  );

  test('ignores files with unsupported extensions', () async {
    final dir = Directory.systemTemp.createTempSync('musicat_scan_');
    addTearDown(() => dir.deleteSync(recursive: true));
    File(p.join(dir.path, 'notes.txt')).writeAsStringSync('not audio');

    final imported = await scanner.scanFolder(dir.path);

    expect(imported, 0);
    expect(await repository.watchAllTracks().first, isEmpty);
  });
}
