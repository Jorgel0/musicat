import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:musicat_server/src/soulseek/slskd_config.dart';
import 'package:musicat_server/src/soulseek/slskd_gateway.dart';
import 'package:musicat_server/src/soulseek/soulseek_models.dart';
import 'package:test/test.dart';

void main() {
  final config = const SlskdConfig(
    host: 'slskd.test',
    port: 5030,
    apiKey: 'test-key',
  );

  http.Response jsonResponse(Object? body, {int status = 200}) =>
      http.Response(jsonEncode(body), status);

  group('isConnected', () {
    test('returns true when slskd reports isLoggedIn', () async {
      final gateway = SlskdGateway(
        config: config,
        httpClient: MockClient((request) async {
          expect(request.url.path, '/api/v0/server');
          expect(request.headers['X-API-Key'], 'test-key');
          return jsonResponse({'isLoggedIn': true});
        }),
      );

      expect(await gateway.isConnected(), isTrue);
    });

    test('returns false when slskd reports not logged in', () async {
      final gateway = SlskdGateway(
        config: config,
        httpClient: MockClient((request) async {
          return jsonResponse({'isLoggedIn': false});
        }),
      );

      expect(await gateway.isConnected(), isFalse);
    });

    test('throws SoulseekGatewayException on a non-200 response', () async {
      final gateway = SlskdGateway(
        config: config,
        httpClient: MockClient((request) async {
          return http.Response('boom', 500);
        }),
      );

      expect(gateway.isConnected, throwsA(isA<SoulseekGatewayException>()));
    });
  });

  group('startSearch', () {
    test(
      'throws SoulseekNotConnectedException without firing a search',
      () async {
        var searchPosted = false;
        final gateway = SlskdGateway(
          config: config,
          httpClient: MockClient((request) async {
            if (request.url.path == '/api/v0/server') {
              return jsonResponse({'isLoggedIn': false});
            }
            searchPosted = true;
            return http.Response('', 200);
          }),
        );

        await expectLater(
          gateway.startSearch('daft punk'),
          throwsA(isA<SoulseekNotConnectedException>()),
        );
        expect(searchPosted, isFalse);
      },
    );

    test('returns an id immediately without waiting for the POST', () async {
      final postStarted = Completer<void>();
      final gateway = SlskdGateway(
        config: config,
        httpClient: MockClient((request) async {
          if (request.url.path == '/api/v0/server') {
            return jsonResponse({'isLoggedIn': true});
          }
          postStarted.complete();
          // Never resolves within the test — if startSearch awaited this,
          // the test itself would hang.
          return Completer<http.Response>().future;
        }),
      );

      final id = await gateway
          .startSearch('daft punk')
          .timeout(const Duration(seconds: 2));

      expect(id, isNotEmpty);
      await postStarted.future.timeout(const Duration(seconds: 2));
    });
  });

  group('getSearch', () {
    test('parses an in-progress search with results', () async {
      final gateway = SlskdGateway(
        config: config,
        httpClient: MockClient((request) async {
          expect(request.url.path, '/api/v0/searches/abc');
          expect(request.url.queryParameters['includeResponses'], 'true');
          return jsonResponse({
            'id': 'abc',
            'searchText': 'daft punk',
            'state': 'InProgress',
            'responses': [
              {
                'username': 'peer1',
                'hasFreeUploadSlot': true,
                'queueLength': 0,
                'uploadSpeed': 1000,
                'files': [
                  {
                    'filename': 'One More Time.flac',
                    'size': 123456,
                    'bitRate': 320,
                    'length': 320,
                  },
                ],
              },
            ],
          });
        }),
      );

      final search = await gateway.getSearch('abc');

      expect(search.id, 'abc');
      expect(search.query, 'daft punk');
      expect(search.state, SoulseekSearchState.inProgress);
      expect(search.results, hasLength(1));
      expect(search.results.single.username, 'peer1');
      expect(search.results.single.files.single.filename, 'One More Time.flac');
      expect(search.results.single.files.single.sizeBytes, 123456);
    });

    test('parses a completed search state', () async {
      final gateway = SlskdGateway(
        config: config,
        httpClient: MockClient((request) async {
          return jsonResponse({
            'id': 'abc',
            'searchText': 'q',
            'state': 'Completed, TimedOut',
            'responses': <Object?>[],
          });
        }),
      );

      final search = await gateway.getSearch('abc');
      expect(search.state, SoulseekSearchState.completed);
    });
  });

  group('cancelSearch', () {
    test('treats 200 and 304 as success', () async {
      for (final status in [200, 304]) {
        final gateway = SlskdGateway(
          config: config,
          httpClient: MockClient((request) async {
            expect(request.method, 'PUT');
            return http.Response('', status);
          }),
        );
        await gateway.cancelSearch('abc');
      }
    });

    test('throws on any other status', () async {
      final gateway = SlskdGateway(
        config: config,
        httpClient: MockClient((request) async => http.Response('nope', 500)),
      );

      expect(
        () => gateway.cancelSearch('abc'),
        throwsA(isA<SoulseekGatewayException>()),
      );
    });
  });

  group('enqueueDownload', () {
    const files = [SoulseekFile(filename: 'a.flac', sizeBytes: 1)];

    test('succeeds on 200/201/207 with no full failure', () async {
      for (final status in [200, 201, 207]) {
        final gateway = SlskdGateway(
          config: config,
          httpClient: MockClient((request) async {
            expect(request.method, 'POST');
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['username'], 'peer1');
            return jsonResponse({'failures': <Object?>[]}, status: status);
          }),
        );

        await gateway.enqueueDownload(username: 'peer1', files: files);
      }
    });

    test('throws SoulseekUserOfflineException on 404', () async {
      final gateway = SlskdGateway(
        config: config,
        httpClient: MockClient(
          (request) async => http.Response('offline', 404),
        ),
      );

      expect(
        () => gateway.enqueueDownload(username: 'peer1', files: files),
        throwsA(isA<SoulseekUserOfflineException>()),
      );
    });

    test('throws when every requested file is reported as a failure', () async {
      final gateway = SlskdGateway(
        config: config,
        httpClient: MockClient((request) async {
          return jsonResponse({
            'failures': [
              {'filename': 'a.flac', 'message': 'rejected'},
            ],
          }, status: 200);
        }),
      );

      expect(
        () => gateway.enqueueDownload(username: 'peer1', files: files),
        throwsA(isA<SoulseekGatewayException>()),
      );
    });
  });

  group('getDownloads', () {
    test('flattens the nested username/directory/file tree', () async {
      final gateway = SlskdGateway(
        config: config,
        httpClient: MockClient((request) async {
          return jsonResponse([
            {
              'username': 'peer1',
              'directories': [
                {
                  'directory': '/music',
                  'files': [
                    {
                      'id': 't1',
                      'username': 'peer1',
                      'filename': 'a.flac',
                      'size': 100,
                      'bytesTransferred': 100,
                      'state': 'Completed, Succeeded',
                    },
                    {
                      'id': 't2',
                      'username': 'peer1',
                      'filename': 'b.flac',
                      'size': 200,
                      'bytesTransferred': 0,
                      'state': 'Queued, Remotely',
                    },
                  ],
                },
              ],
            },
          ]);
        }),
      );

      final transfers = await gateway.getDownloads();

      expect(transfers, hasLength(2));
      expect(transfers[0].id, 't1');
      expect(transfers[0].state, SoulseekTransferState.succeeded);
      expect(transfers[1].id, 't2');
      expect(transfers[1].state, SoulseekTransferState.queued);
    });

    test('maps transfer state flags to the coarse categories', () async {
      Future<SoulseekTransferState> stateFor(String raw) async {
        final gateway = SlskdGateway(
          config: config,
          httpClient: MockClient((request) async {
            return jsonResponse([
              {
                'username': 'peer1',
                'directories': [
                  {
                    'files': [
                      {
                        'id': 't1',
                        'username': 'peer1',
                        'filename': 'a.flac',
                        'size': 1,
                        'state': raw,
                      },
                    ],
                  },
                ],
              },
            ]);
          }),
        );
        return (await gateway.getDownloads()).single.state;
      }

      expect(
        await stateFor('Completed, Succeeded'),
        SoulseekTransferState.succeeded,
      );
      expect(
        await stateFor('Completed, Cancelled'),
        SoulseekTransferState.failed,
      );
      expect(await stateFor('Completed'), SoulseekTransferState.failed);
      expect(await stateFor('InProgress'), SoulseekTransferState.inProgress);
      expect(await stateFor('Queued, Remotely'), SoulseekTransferState.queued);
    });
  });

  group('getDownloadsDirectory', () {
    test('returns the configured downloads directory', () async {
      final gateway = SlskdGateway(
        config: config,
        httpClient: MockClient((request) async {
          expect(request.url.path, '/api/v0/options');
          return jsonResponse({
            'directories': {'downloads': '/data/downloads'},
          });
        }),
      );

      expect(await gateway.getDownloadsDirectory(), '/data/downloads');
    });

    test('returns null rather than throwing on error', () async {
      final gateway = SlskdGateway(
        config: config,
        httpClient: MockClient((request) async => http.Response('nope', 500)),
      );

      expect(await gateway.getDownloadsDirectory(), isNull);
    });
  });
}
