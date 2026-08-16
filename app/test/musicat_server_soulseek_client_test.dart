import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicat/core/network/soulseek/musicat_server/musicat_server_soulseek_client.dart';
import 'package:musicat/core/network/soulseek/soulseek_client.dart';

import 'fakes/fake_http_adapter.dart';

MusicatServerSoulseekClient _clientWith(
  FakeHttpResponse Function(RequestOptions options) handler,
) {
  final adapter = FakeHttpAdapter(handler);
  final dio = Dio()..httpClientAdapter = adapter;
  return MusicatServerSoulseekClient(
    baseUrl: 'http://musicat-server.test',
    dio: dio,
  );
}

void main() {
  group('isConnected', () {
    test('true when the server reports connected', () async {
      late RequestOptions seen;
      final client = _clientWith((options) {
        seen = options;
        return const FakeHttpResponse(200, {'connected': true});
      });

      expect(await client.isConnected(), isTrue);
      expect(seen.path, '/api/v1/soulseek/status');
    });

    test('false when the server reports not connected', () async {
      final client = _clientWith(
        (_) => const FakeHttpResponse(200, {'connected': false}),
      );

      expect(await client.isConnected(), isFalse);
    });
  });

  group('startSearch', () {
    test('returns the search id from a normal response', () async {
      late RequestOptions seen;
      final client = _clientWith((options) {
        seen = options;
        return const FakeHttpResponse(201, {'searchId': 'abc'});
      });

      final id = await client.startSearch('daft punk');

      expect(id, 'abc');
      expect(seen.method, 'POST');
      expect(seen.path, '/api/v1/soulseek/searches');
      expect(seen.data, {'query': 'daft punk'});
    });

    test('throws SoulseekNotConnectedException on a 409', () async {
      final client = _clientWith(
        (_) => const FakeHttpResponse(409, {'error': 'not connected'}),
      );

      await expectLater(
        client.startSearch('daft punk'),
        throwsA(isA<SoulseekNotConnectedException>()),
      );
    });
  });

  group('getSearch', () {
    test('parses an already-flattened search response', () async {
      final client = _clientWith(
        (_) => const FakeHttpResponse(200, {
          'id': 'abc',
          'query': 'daft punk',
          'state': 'inProgress',
          'results': [
            {
              'username': 'peer1',
              'hasFreeUploadSlot': true,
              'queueLength': 2,
              'uploadSpeedBytesPerSecond': 1000,
              'files': [
                {
                  'filename': 'One More Time.flac',
                  'sizeBytes': 123,
                  'bitRateKbps': 320,
                  'durationSeconds': 320,
                },
              ],
            },
          ],
        }),
      );

      final search = await client.getSearch('abc');

      expect(search.id, 'abc');
      expect(search.query, 'daft punk');
      expect(search.state, SoulseekSearchState.inProgress);
      expect(search.results.single.username, 'peer1');
      expect(search.results.single.files.single.filename, 'One More Time.flac');
      expect(search.results.single.files.single.sizeBytes, 123);
    });

    test('recognizes the completed state', () async {
      final client = _clientWith(
        (_) => const FakeHttpResponse(200, {
          'id': 'abc',
          'query': 'q',
          'state': 'completed',
          'results': [],
        }),
      );

      final search = await client.getSearch('abc');
      expect(search.state, SoulseekSearchState.completed);
    });
  });

  group('cancelSearch', () {
    test('succeeds on a plain 204', () async {
      final client = _clientWith((_) => const FakeHttpResponse(204, ''));
      await client.cancelSearch('abc'); // does not throw
    });
  });

  group('enqueueDownload', () {
    const files = [SoulseekFile(filename: 'a.flac', sizeBytes: 1)];

    test('succeeds on 201', () async {
      late RequestOptions seen;
      final client = _clientWith((options) {
        seen = options;
        return const FakeHttpResponse(201, '');
      });

      await client.enqueueDownload(username: 'peer1', files: files);
      expect(seen.path, '/api/v1/soulseek/downloads');
      expect(seen.data, {
        'username': 'peer1',
        'files': [
          {'filename': 'a.flac', 'sizeBytes': 1},
        ],
      });
    });

    test('throws SoulseekUserOfflineException on a 404', () async {
      final client = _clientWith(
        (_) => const FakeHttpResponse(404, {'error': 'offline'}),
      );

      await expectLater(
        client.enqueueDownload(username: 'peer1', files: files),
        throwsA(
          isA<SoulseekUserOfflineException>().having(
            (e) => e.username,
            'username',
            'peer1',
          ),
        ),
      );
    });
  });

  group('getDownloads', () {
    test('returns the already-flattened transfer list', () async {
      final client = _clientWith(
        (_) => const FakeHttpResponse(200, [
          {
            'id': 't1',
            'username': 'peer1',
            'filename': 'a.flac',
            'sizeBytes': 100,
            'bytesTransferred': 100,
            'state': 'succeeded',
          },
        ]),
      );

      final downloads = await client.getDownloads();
      expect(downloads, hasLength(1));
      expect(downloads.single.id, 't1');
      expect(downloads.single.state, SoulseekTransferState.succeeded);
    });
  });

  group('cancelDownload', () {
    test('sends a DELETE to the expected path', () async {
      late RequestOptions seen;
      final client = _clientWith((options) {
        seen = options;
        return const FakeHttpResponse(204, '');
      });

      await client.cancelDownload(username: 'peer1', transferId: 't1');
      expect(seen.method, 'DELETE');
      expect(seen.path, '/api/v1/soulseek/downloads/peer1/t1');
    });
  });

  group('getDownloadsDirectory', () {
    test('returns the directory when known', () async {
      final client = _clientWith(
        (_) => const FakeHttpResponse(200, {'directory': '/data/downloads'}),
      );

      expect(await client.getDownloadsDirectory(), '/data/downloads');
    });

    test('returns null on a network error instead of throwing', () async {
      final client = _clientWith((_) => const FakeHttpResponse(500, 'boom'));
      expect(await client.getDownloadsDirectory(), isNull);
    });
  });
}
