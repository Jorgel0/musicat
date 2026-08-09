import 'package:flutter_test/flutter_test.dart';
import 'package:musicat/features/library/domain/library_grouping.dart';
import 'package:musicat/features/library/domain/track.dart';

Track _track({
  required int id,
  required String title,
  required String artist,
  required String album,
  int? trackNumber,
  String? coverArtPath,
}) {
  return Track(
    id: id,
    filePath: '/music/$id.mp3',
    title: title,
    artist: artist,
    album: album,
    source: TrackSource.local,
    trackNumber: trackNumber,
    coverArtPath: coverArtPath,
  );
}

void main() {
  group('groupTracksByAlbum', () {
    test('groups tracks by album+artist and counts them', () {
      final tracks = [
        _track(id: 1, title: 'Song A', artist: 'Artist X', album: 'Album 1'),
        _track(id: 2, title: 'Song B', artist: 'Artist X', album: 'Album 1'),
        _track(id: 3, title: 'Song C', artist: 'Artist Y', album: 'Album 2'),
      ];

      final albums = groupTracksByAlbum(tracks);

      expect(albums, hasLength(2));
      expect(albums.firstWhere((a) => a.name == 'Album 1').trackCount, 2);
      expect(albums.firstWhere((a) => a.name == 'Album 2').trackCount, 1);
    });

    test(
      'treats the same album title by different artists as separate albums',
      () {
        final tracks = [
          _track(
            id: 1,
            title: 'Song A',
            artist: 'Artist X',
            album: 'Greatest Hits',
          ),
          _track(
            id: 2,
            title: 'Song B',
            artist: 'Artist Y',
            album: 'Greatest Hits',
          ),
        ];

        final albums = groupTracksByAlbum(tracks);

        expect(albums, hasLength(2));
      },
    );

    test('picks a cover art path from any track that has one', () {
      final tracks = [
        _track(
          id: 1,
          title: 'Song A',
          artist: 'Artist X',
          album: 'Album 1',
          coverArtPath: null,
        ),
        _track(
          id: 2,
          title: 'Song B',
          artist: 'Artist X',
          album: 'Album 1',
          coverArtPath: '/covers/album1.jpg',
        ),
      ];

      final albums = groupTracksByAlbum(tracks);

      expect(albums.single.coverArtPath, '/covers/album1.jpg');
    });
  });

  group('groupTracksByArtist', () {
    test('counts distinct tracks and albums per artist', () {
      final tracks = [
        _track(id: 1, title: 'Song A', artist: 'Artist X', album: 'Album 1'),
        _track(id: 2, title: 'Song B', artist: 'Artist X', album: 'Album 1'),
        _track(id: 3, title: 'Song C', artist: 'Artist X', album: 'Album 2'),
        _track(id: 4, title: 'Song D', artist: 'Artist Y', album: 'Album 3'),
      ];

      final artists = groupTracksByArtist(tracks);

      final artistX = artists.firstWhere((a) => a.name == 'Artist X');
      expect(artistX.trackCount, 3);
      expect(artistX.albumCount, 2);

      final artistY = artists.firstWhere((a) => a.name == 'Artist Y');
      expect(artistY.trackCount, 1);
      expect(artistY.albumCount, 1);
    });
  });
}
