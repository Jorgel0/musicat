import 'package:flutter_test/flutter_test.dart';
import 'package:musicat/core/network/soulseek/soulseek_client.dart';
import 'package:musicat/features/search/domain/group_search_results.dart';

SoulseekSearchResult _peer({
  required String username,
  required List<SoulseekFile> files,
  bool hasFreeUploadSlot = true,
  int queueLength = 0,
  int uploadSpeedBytesPerSecond = 1000,
}) {
  return SoulseekSearchResult(
    username: username,
    hasFreeUploadSlot: hasFreeUploadSlot,
    queueLength: queueLength,
    uploadSpeedBytesPerSecond: uploadSpeedBytesPerSecond,
    files: files,
  );
}

void main() {
  group('groupSearchResultsByAlbum', () {
    test('groups files from different peers into one album/song', () {
      final peers = [
        _peer(
          username: 'alice',
          files: const [
            SoulseekFile(
              filename:
                  r'@@a\Daft Punk - Discovery (2001)\03 - Digital Love.mp3',
              sizeBytes: 100,
              bitRateKbps: 128,
            ),
          ],
        ),
        _peer(
          username: 'bob',
          files: const [
            SoulseekFile(
              filename:
                  r'@@b\Daft Punk - Discovery (2001)\03 - Digital Love.flac',
              sizeBytes: 200,
              bitRateKbps: 1000,
            ),
          ],
        ),
      ];

      final albums = groupSearchResultsByAlbum(peers, '');

      expect(albums, hasLength(1));
      expect(albums.single.artist, 'Daft Punk');
      expect(albums.single.album, 'Discovery');
      expect(albums.single.songs, hasLength(1));

      final song = albums.single.songs.single;
      expect(song.title, 'Digital Love');
      expect(song.sources, hasLength(2));
    });

    test('keeps distinct songs within the same album separate', () {
      final peers = [
        _peer(
          username: 'alice',
          files: const [
            SoulseekFile(
              filename:
                  r'@@a\Daft Punk - Discovery (2001)\01 - One More Time.mp3',
              sizeBytes: 100,
            ),
            SoulseekFile(
              filename:
                  r'@@a\Daft Punk - Discovery (2001)\03 - Digital Love.mp3',
              sizeBytes: 100,
            ),
          ],
        ),
      ];

      final albums = groupSearchResultsByAlbum(peers, '');

      expect(albums, hasLength(1));
      expect(albums.single.songs, hasLength(2));
    });

    test('treats the same album title from different artists separately', () {
      final peers = [
        _peer(
          username: 'alice',
          files: const [
            SoulseekFile(
              filename: r'@@a\Artist X - Greatest Hits (2001)\01 - Song.mp3',
              sizeBytes: 100,
            ),
          ],
        ),
        _peer(
          username: 'bob',
          files: const [
            SoulseekFile(
              filename: r'@@b\Artist Y - Greatest Hits (2005)\01 - Song.mp3',
              sizeBytes: 100,
            ),
          ],
        ),
      ];

      final albums = groupSearchResultsByAlbum(peers, '');

      expect(albums, hasLength(2));
    });

    test('sorts songs within an album by title', () {
      final peers = [
        _peer(
          username: 'alice',
          files: const [
            SoulseekFile(
              filename: r'@@a\Zeta - Album (2001)\02 - B Song.mp3',
              sizeBytes: 100,
            ),
            SoulseekFile(
              filename: r'@@a\Zeta - Album (2001)\01 - A Song.mp3',
              sizeBytes: 100,
            ),
          ],
        ),
      ];

      final albums = groupSearchResultsByAlbum(peers, '');

      expect(albums.single.songs.map((s) => s.title), ['A Song', 'B Song']);
    });

    test('ranks an album matching the query above one that does not, '
        'regardless of alphabetical order', () {
      final peers = [
        _peer(
          username: 'alice',
          files: const [
            SoulseekFile(
              filename: r'@@a\Abba - Greatest Hits (1992)\01 - Song.mp3',
              sizeBytes: 100,
            ),
          ],
        ),
        _peer(
          username: 'bob',
          files: const [
            SoulseekFile(
              filename: r'@@b\Daft Punk - Discovery (2001)\01 - Song.mp3',
              sizeBytes: 100,
            ),
          ],
        ),
      ];

      final albums = groupSearchResultsByAlbum(peers, 'daft punk');

      expect(albums.first.artist, 'Daft Punk');
    });

    test(
      'matches the query against song titles too, not just artist/album',
      () {
        final peers = [
          _peer(
            username: 'alice',
            files: const [
              SoulseekFile(
                filename: r'@@a\Zeta - Unrelated Album\01 - Something Else.mp3',
                sizeBytes: 100,
              ),
            ],
          ),
          _peer(
            username: 'bob',
            files: const [
              SoulseekFile(
                filename: r'@@b\Abba - Greatest Hits\01 - One More Time.mp3',
                sizeBytes: 100,
              ),
            ],
          ),
        ];

        final albums = groupSearchResultsByAlbum(peers, 'one more time');

        expect(albums.first.album, 'Greatest Hits');
      },
    );

    test('breaks a relevance tie by how many peers offer the album', () {
      final peers = [
        _peer(
          username: 'alice',
          files: const [
            SoulseekFile(
              filename: r'@@a\Daft Punk - Homework\01 - Song.mp3',
              sizeBytes: 100,
            ),
          ],
        ),
        _peer(
          username: 'bob',
          files: const [
            SoulseekFile(
              filename: r'@@b\Daft Punk - Discovery\01 - Song.mp3',
              sizeBytes: 100,
            ),
          ],
        ),
        _peer(
          username: 'carol',
          files: const [
            SoulseekFile(
              filename: r'@@c\Daft Punk - Discovery\01 - Song.mp3',
              sizeBytes: 100,
            ),
          ],
        ),
      ];

      final albums = groupSearchResultsByAlbum(peers, 'daft punk');

      // Both albums match "daft punk" equally well (artist name only) —
      // Discovery has 2 sources, Homework has 1.
      expect(albums.first.album, 'Discovery');
    });
  });

  group('SoulseekSongResult.bestSource', () {
    test('prefers a free upload slot over queue length or bitrate', () {
      const song = SoulseekSongResult(
        title: 'Song',
        sources: [
          SoulseekSongSource(
            username: 'busy',
            file: SoulseekFile(
              filename: 'a.flac',
              sizeBytes: 1,
              bitRateKbps: 1000,
            ),
            hasFreeUploadSlot: false,
            queueLength: 0,
            uploadSpeedBytesPerSecond: 1000,
          ),
          SoulseekSongSource(
            username: 'free',
            file: SoulseekFile(
              filename: 'b.mp3',
              sizeBytes: 1,
              bitRateKbps: 128,
            ),
            hasFreeUploadSlot: true,
            queueLength: 5,
            uploadSpeedBytesPerSecond: 1000,
          ),
        ],
      );

      expect(song.bestSource.username, 'free');
    });

    test('breaks ties on queue length, then bitrate', () {
      const song = SoulseekSongResult(
        title: 'Song',
        sources: [
          SoulseekSongSource(
            username: 'low-bitrate',
            file: SoulseekFile(
              filename: 'a.mp3',
              sizeBytes: 1,
              bitRateKbps: 128,
            ),
            hasFreeUploadSlot: true,
            queueLength: 0,
            uploadSpeedBytesPerSecond: 1000,
          ),
          SoulseekSongSource(
            username: 'high-bitrate',
            file: SoulseekFile(
              filename: 'b.flac',
              sizeBytes: 1,
              bitRateKbps: 1000,
            ),
            hasFreeUploadSlot: true,
            queueLength: 0,
            uploadSpeedBytesPerSecond: 1000,
          ),
        ],
      );

      expect(song.bestSource.username, 'high-bitrate');
    });
  });
}
