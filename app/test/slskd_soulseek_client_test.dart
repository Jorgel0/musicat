import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicat/core/network/soulseek/slskd/slskd_soulseek_client.dart';
import 'package:musicat/core/network/soulseek/soulseek_client.dart';

import 'fakes/fake_http_adapter.dart';

SlskdSoulseekClient _clientWith(
  FakeHttpResponse Function(RequestOptions options) handler,
) {
  final adapter = FakeHttpAdapter(handler);
  final dio = Dio()..httpClientAdapter = adapter;
  return SlskdSoulseekClient(
    baseUrl: 'http://slskd.test',
    apiKey: 'k',
    dio: dio,
  );
}

void main() {
  group('isConnected', () {
    test('true when the server reports isLoggedIn', () async {
      late RequestOptions seen;
      final client = _clientWith((options) {
        seen = options;
        return FakeHttpResponse(200, {'isLoggedIn': true, 'isConnected': true});
      });

      expect(await client.isConnected(), isTrue);
      expect(seen.path, '/api/v0/server');
      expect(seen.headers['X-API-Key'], 'k');
    });

    test('false when the server is up but not logged in', () async {
      final client = _clientWith(
        (_) =>
            FakeHttpResponse(200, {'isLoggedIn': false, 'isConnected': true}),
      );

      expect(await client.isConnected(), isFalse);
    });
  });

  group('startSearch', () {
    test(
      'throws SoulseekNotConnectedException without ever posting a search',
      () async {
        final adapter = FakeHttpAdapter(
          (_) => const FakeHttpResponse(200, {'isLoggedIn': false}),
        );
        final client = SlskdSoulseekClient(
          baseUrl: 'http://slskd.test',
          apiKey: 'k',
          dio: Dio()..httpClientAdapter = adapter,
        );

        await expectLater(
          client.startSearch('some query'),
          throwsA(isA<SoulseekNotConnectedException>()),
        );
        expect(
          adapter.requests.any((r) => r.path == '/api/v0/searches'),
          isFalse,
        );
      },
    );

    test('returns a search id and fires the search POST', () async {
      final adapter = FakeHttpAdapter((options) {
        if (options.path == '/api/v0/server') {
          return const FakeHttpResponse(200, {'isLoggedIn': true});
        }
        return const FakeHttpResponse(200, {});
      });
      final client = SlskdSoulseekClient(
        baseUrl: 'http://slskd.test',
        apiKey: 'k',
        dio: Dio()..httpClientAdapter = adapter,
      );

      final id = await client.startSearch('pink floyd');
      expect(id, isNotEmpty);

      // The POST is fired without being awaited by startSearch — give it
      // real time to work through dio's async pipeline before asserting.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final searchRequest = adapter.requests.firstWhere(
        (r) => r.path == '/api/v0/searches',
      );
      expect(searchRequest.method, 'POST');
      expect(searchRequest.data, {'id': id, 'searchText': 'pink floyd'});
    });
  });

  group('getSearch', () {
    test('parses an in-progress search with results', () async {
      final client = _clientWith(
        (_) => const FakeHttpResponse(200, {
          'id': 'abc',
          'searchText': 'pink floyd',
          'state': 'InProgress',
          'responses': [
            {
              'username': 'someone',
              'hasFreeUploadSlot': true,
              'queueLength': 3,
              'uploadSpeed': 102400,
              'files': [
                {
                  'filename': '@@abc\\Music\\Wish You Were Here.flac',
                  'size': 30000000,
                  'bitRate': 1000,
                  'length': 334,
                },
              ],
            },
          ],
        }),
      );

      final search = await client.getSearch('abc');
      expect(search.id, 'abc');
      expect(search.query, 'pink floyd');
      expect(search.state, SoulseekSearchState.inProgress);
      expect(search.results, hasLength(1));

      final result = search.results.single;
      expect(result.username, 'someone');
      expect(result.hasFreeUploadSlot, isTrue);
      expect(result.queueLength, 3);
      expect(result.uploadSpeedBytesPerSecond, 102400);
      expect(result.files, hasLength(1));
      expect(
        result.files.single.filename,
        '@@abc\\Music\\Wish You Were Here.flac',
      );
      expect(result.files.single.sizeBytes, 30000000);
      expect(result.files.single.bitRateKbps, 1000);
      expect(result.files.single.durationSeconds, 334);
    });

    test('recognizes a completed search regardless of extra flags', () async {
      final client = _clientWith(
        (_) => const FakeHttpResponse(200, {
          'id': 'abc',
          'searchText': 'q',
          'state': 'Completed, TimedOut',
          'responses': [],
        }),
      );

      final search = await client.getSearch('abc');
      expect(search.state, SoulseekSearchState.completed);
      expect(search.results, isEmpty);
    });

    test('sends includeResponses=true', () async {
      late RequestOptions seen;
      final client = _clientWith((options) {
        seen = options;
        return const FakeHttpResponse(200, {
          'id': 'abc',
          'searchText': 'q',
          'state': 'InProgress',
        });
      });

      await client.getSearch('abc');
      expect(seen.path, '/api/v0/searches/abc');
      expect(seen.queryParameters['includeResponses'], true);
    });
  });

  group('cancelSearch', () {
    test('succeeds when the search was actually stopped (200)', () async {
      final client = _clientWith((_) => const FakeHttpResponse(200, ''));
      await client.cancelSearch('abc'); // does not throw
    });

    test('succeeds when the search had already finished (304)', () async {
      final client = _clientWith((_) => const FakeHttpResponse(304, ''));
      await client.cancelSearch('abc'); // does not throw
    });
  });

  group('enqueueDownload', () {
    const files = [SoulseekFile(filename: 'a.flac', sizeBytes: 100)];

    test('succeeds (201, all enqueued)', () async {
      final client = _clientWith(
        (_) => const FakeHttpResponse(201, {'batch': {}, 'failures': []}),
      );
      await client.enqueueDownload(username: 'u', files: files); // no throw
    });

    test('succeeds with a partial failure (207)', () async {
      final client = _clientWith(
        (_) => const FakeHttpResponse(207, {
          'batch': {},
          'failures': [
            {'filename': 'b.flac', 'message': 'already queued'},
          ],
        }),
      );
      await client.enqueueDownload(
        username: 'u',
        files: const [
          SoulseekFile(filename: 'a.flac', sizeBytes: 100),
          SoulseekFile(filename: 'b.flac', sizeBytes: 200),
        ],
      ); // no throw — at least one file succeeded
    });

    test('throws when every file failed (200)', () async {
      final client = _clientWith(
        (_) => const FakeHttpResponse(200, {
          'batch': {},
          'failures': [
            {'filename': 'a.flac', 'message': 'already in progress'},
          ],
        }),
      );

      await expectLater(
        client.enqueueDownload(username: 'u', files: files),
        throwsA(isA<SoulseekClientException>()),
      );
    });

    test('throws SoulseekUserOfflineException on 404', () async {
      final client = _clientWith(
        (_) => const FakeHttpResponse(404, 'User u appears to be offline'),
      );

      await expectLater(
        client.enqueueDownload(username: 'u', files: files),
        throwsA(
          isA<SoulseekUserOfflineException>().having(
            (e) => e.username,
            'username',
            'u',
          ),
        ),
      );
    });

    test('sends the request body slskd expects', () async {
      late RequestOptions seen;
      final client = _clientWith((options) {
        seen = options;
        return const FakeHttpResponse(201, {'batch': {}, 'failures': []});
      });

      await client.enqueueDownload(username: 'u', files: files);
      expect(seen.path, '/api/v0/transfers/downloads/batches');
      expect(seen.data, {
        'username': 'u',
        'files': [
          {'filename': 'a.flac', 'size': 100},
        ],
      });
    });
  });

  group('getDownloads', () {
    test('flattens the username/directory/file tree', () async {
      final client = _clientWith(
        (_) => const FakeHttpResponse(200, [
          {
            'username': 'someone',
            'directories': [
              {
                'directory': '@@abc\\Music',
                'fileCount': 2,
                'files': [
                  {
                    'id': 't1',
                    'username': 'someone',
                    'filename': 'a.flac',
                    'size': 100,
                    'bytesTransferred': 100,
                    'state': 'Completed, Succeeded',
                  },
                  {
                    'id': 't2',
                    'username': 'someone',
                    'filename': 'b.flac',
                    'size': 200,
                    'bytesTransferred': 50,
                    'state': 'InProgress',
                    'placeInQueue': null,
                  },
                ],
              },
            ],
          },
        ]),
      );

      final downloads = await client.getDownloads();
      expect(downloads, hasLength(2));
      expect(downloads[0].id, 't1');
      expect(downloads[0].state, SoulseekTransferState.succeeded);
      expect(downloads[1].id, 't2');
      expect(downloads[1].state, SoulseekTransferState.inProgress);
      expect(downloads[1].bytesTransferred, 50);
    });
  });

  group('cancelDownload', () {
    test('sends a DELETE to the expected path', () async {
      late RequestOptions seen;
      final client = _clientWith((options) {
        seen = options;
        return const FakeHttpResponse(204, '');
      });

      await client.cancelDownload(username: 'u', transferId: 't1');
      expect(seen.method, 'DELETE');
      expect(seen.path, '/api/v0/transfers/downloads/u/t1');
    });
  });

  group('getDownloadsDirectory', () {
    test('reads directories.downloads from the options endpoint', () async {
      late RequestOptions seen;
      final client = _clientWith((options) {
        seen = options;
        return const FakeHttpResponse(200, {
          'directories': {
            'downloads': '/home/user/Music/SoulseekDownloads',
            'incomplete': '/home/user/.local/share/slskd/incomplete',
          },
        });
      });

      final directory = await client.getDownloadsDirectory();
      expect(directory, '/home/user/Music/SoulseekDownloads');
      expect(seen.path, '/api/v0/options');
    });

    test('returns null on a network error instead of throwing', () async {
      final client = _clientWith((_) => const FakeHttpResponse(500, 'boom'));

      final directory = await client.getDownloadsDirectory();
      expect(directory, isNull);
    });
  });
}
