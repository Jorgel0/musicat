import 'dart:convert';

import 'package:musicat_server/src/soulseek/soulseek_models.dart';
import 'package:musicat_server/src/soulseek/soulseek_routes.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

class _FakeGateway implements SoulseekGateway {
  bool connected = true;
  String? lastQuery;
  String? lastCancelledSearchId;
  String? lastEnqueuedUsername;
  List<SoulseekFile>? lastEnqueuedFiles;
  ({String username, String transferId})? lastCancelledDownload;
  String? downloadsDirectory;
  Object? searchError;
  Object? enqueueError;

  @override
  Future<bool> isConnected() async => connected;

  @override
  Future<String> startSearch(String query) async {
    if (!connected) {
      throw const SoulseekNotConnectedException('not connected');
    }
    lastQuery = query;
    return 'search-1';
  }

  @override
  Future<SoulseekSearch> getSearch(String searchId) async {
    if (searchError != null) throw searchError!;
    return SoulseekSearch(
      id: searchId,
      query: 'daft punk',
      state: SoulseekSearchState.inProgress,
      results: const [
        SoulseekSearchResult(
          username: 'peer1',
          hasFreeUploadSlot: true,
          queueLength: 0,
          uploadSpeedBytesPerSecond: 1000,
          files: [
            SoulseekFile(
              filename: 'One More Time.flac',
              sizeBytes: 123,
              bitRateKbps: 320,
            ),
          ],
        ),
      ],
    );
  }

  @override
  Future<void> cancelSearch(String searchId) async {
    lastCancelledSearchId = searchId;
  }

  @override
  Future<void> enqueueDownload({
    required String username,
    required List<SoulseekFile> files,
  }) async {
    if (enqueueError != null) throw enqueueError!;
    lastEnqueuedUsername = username;
    lastEnqueuedFiles = files;
  }

  @override
  Future<List<SoulseekTransfer>> getDownloads() async => const [
    SoulseekTransfer(
      id: 't1',
      username: 'peer1',
      filename: 'a.flac',
      sizeBytes: 100,
      bytesTransferred: 100,
      state: SoulseekTransferState.succeeded,
    ),
  ];

  @override
  Future<void> cancelDownload({
    required String username,
    required String transferId,
  }) async {
    lastCancelledDownload = (username: username, transferId: transferId);
  }

  @override
  Future<String?> getDownloadsDirectory() async => downloadsDirectory;
}

void main() {
  late _FakeGateway gateway;
  late Handler handler;

  setUp(() {
    gateway = _FakeGateway();
    handler = buildSoulseekRouter(gateway).call;
  });

  Future<Response> get(String path) async =>
      await handler(Request('GET', Uri.parse('http://localhost$path')));

  Future<Response> post(String path, Object body) async => await handler(
    Request('POST', Uri.parse('http://localhost$path'), body: jsonEncode(body)),
  );

  Future<Response> delete(String path) async =>
      await handler(Request('DELETE', Uri.parse('http://localhost$path')));

  Future<Map<String, dynamic>> jsonBody(Response response) => response
      .readAsString()
      .then((s) => jsonDecode(s) as Map<String, dynamic>);

  group('GET /status', () {
    test('reports connected', () async {
      final response = await get('/status');
      expect(response.statusCode, 200);
      expect((await jsonBody(response))['connected'], isTrue);
    });
  });

  group('POST /searches', () {
    test('starts a search and returns its id', () async {
      final response = await post('/searches', {'query': 'daft punk'});

      expect(response.statusCode, 201);
      expect((await jsonBody(response))['searchId'], 'search-1');
      expect(gateway.lastQuery, 'daft punk');
    });

    test('rejects a missing query with 400', () async {
      final response = await post('/searches', {});
      expect(response.statusCode, 400);
    });

    test('maps SoulseekNotConnectedException to 409', () async {
      gateway.connected = false;
      final response = await post('/searches', {'query': 'daft punk'});
      expect(response.statusCode, 409);
    });
  });

  group('GET /searches/<id>', () {
    test('returns the parsed search', () async {
      final response = await get('/searches/search-1');
      expect(response.statusCode, 200);
      final body = await jsonBody(response);
      expect(body['id'], 'search-1');
      expect(body['state'], 'inProgress');
      expect(body['results'], hasLength(1));
    });

    test(
      'maps a generic SoulseekGatewayException to its status code',
      () async {
        gateway.searchError = const SoulseekGatewayException(429, 'slow down');
        final response = await get('/searches/search-1');
        expect(response.statusCode, 429);
      },
    );
  });

  group('DELETE /searches/<id>', () {
    test('cancels the search', () async {
      final response = await delete('/searches/search-1');
      expect(response.statusCode, 204);
      expect(gateway.lastCancelledSearchId, 'search-1');
    });
  });

  group('POST /downloads', () {
    test('enqueues a download', () async {
      final response = await post('/downloads', {
        'username': 'peer1',
        'files': [
          {'filename': 'a.flac', 'sizeBytes': 123},
        ],
      });

      expect(response.statusCode, 201);
      expect(gateway.lastEnqueuedUsername, 'peer1');
      expect(gateway.lastEnqueuedFiles, hasLength(1));
    });

    test('rejects an empty file list with 400', () async {
      final response = await post('/downloads', {
        'username': 'peer1',
        'files': <Object?>[],
      });
      expect(response.statusCode, 400);
    });

    test('maps SoulseekUserOfflineException to 404', () async {
      gateway.enqueueError = const SoulseekUserOfflineException(
        'peer1',
        'offline',
      );
      final response = await post('/downloads', {
        'username': 'peer1',
        'files': [
          {'filename': 'a.flac', 'sizeBytes': 1},
        ],
      });
      expect(response.statusCode, 404);
    });
  });

  group('GET /downloads', () {
    test('returns the transfer list', () async {
      final response = await get('/downloads');
      expect(response.statusCode, 200);
      final body = jsonDecode(await response.readAsString()) as List<dynamic>;
      expect(body, hasLength(1));
      expect((body.single as Map<String, dynamic>)['state'], 'succeeded');
    });
  });

  group('DELETE /downloads/<username>/<transferId>', () {
    test('cancels the download', () async {
      final response = await delete('/downloads/peer1/t1');
      expect(response.statusCode, 204);
      expect(gateway.lastCancelledDownload, (
        username: 'peer1',
        transferId: 't1',
      ));
    });
  });

  group('GET /downloads-directory', () {
    test('returns null when unknown', () async {
      final response = await get('/downloads-directory');
      expect(response.statusCode, 200);
      expect((await jsonBody(response))['directory'], isNull);
    });

    test('returns the directory when known', () async {
      gateway.downloadsDirectory = '/data/downloads';
      final response = await get('/downloads-directory');
      expect((await jsonBody(response))['directory'], '/data/downloads');
    });
  });
}
