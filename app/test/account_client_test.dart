import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicat/core/network/federation/account_client.dart';

import 'fakes/fake_http_adapter.dart';

AccountClient _clientWith(
  FakeHttpResponse Function(RequestOptions options) handler,
) {
  final dio = Dio()..httpClientAdapter = FakeHttpAdapter(handler);
  return AccountClient(baseUrl: 'http://musicat-server.test', dio: dio);
}

void main() {
  group('signIn', () {
    test('reports a brand-new account as created', () async {
      late RequestOptions seen;
      final client = _clientWith((options) {
        seen = options;
        return const FakeHttpResponse(200, {
          'accountId': 'acc-1',
          'username': 'jorge',
          'created': true,
        });
      });

      final result = await client.signIn(
        username: 'jorge',
        password: 'hunter2',
      );

      expect(result.created, isTrue);
      expect(result.username, 'jorge');
      expect(seen.path, '/api/v1/account/login');
      // The password goes in the body, never the path or query string.
      expect(seen.uri.query, isEmpty);
      expect((seen.data as Map)['username'], 'jorge');
    });

    test('reports an existing account this device just joined as not '
        'created', () async {
      final client = _clientWith(
        (options) => const FakeHttpResponse(200, {
          'accountId': 'acc-1',
          'username': 'jorge',
          'created': false,
        }),
      );

      final result = await client.signIn(username: 'jorge', password: 'pw');

      expect(result.created, isFalse);
    });

    test('sends allowCreate on the wire, so the caller decides whether a '
        'new account may be made at all', () async {
      late RequestOptions seen;
      final client = _clientWith((options) {
        seen = options;
        return const FakeHttpResponse(200, {
          'accountId': 'acc-1',
          'username': 'jorge',
          'created': false,
        });
      });

      await client.signIn(
        username: 'jorge',
        password: 'pw',
        allowCreate: false,
      );
      expect((seen.data as Map)['allowCreate'], isFalse);

      await client.signIn(username: 'jorge', password: 'pw');
      // Sent explicitly even when it matches the route's own default, so
      // the request says what it means on its own.
      expect((seen.data as Map)['allowCreate'], isTrue);
    });

    test(
      'surfaces the status code for each failure the UI has to tell '
      'apart, including the 404 that means "no account by that name"',
      () async {
        for (final status in [400, 401, 404, 429, 502, 503]) {
          final client = _clientWith(
            (options) => FakeHttpResponse(status, {'error': 'nope'}),
          );

          expect(
            () => client.signIn(username: 'jorge', password: 'pw'),
            throwsA(
              isA<AccountClientException>().having(
                (e) => e.statusCode,
                'statusCode',
                status,
              ),
            ),
          );
        }
      },
    );
  });

  group('accountStatus', () {
    test('reads the account out of its "account" envelope', () async {
      final client = _clientWith(
        (options) => const FakeHttpResponse(200, {
          'account': {
            'accountId': 'acc-1',
            'username': 'jorge',
            'loggedInAt': '2026-09-05T10:00:00.000Z',
          },
          'accountsAvailable': true,
        }),
      );

      final status = await client.accountStatus();

      expect(status.account, isNotNull);
      expect(status.account!.username, 'jorge');
    });

    test('is null, not an error, when signed out', () async {
      final client = _clientWith(
        (options) => const FakeHttpResponse(200, {
          'account': null,
          'accountsAvailable': true,
        }),
      );

      expect((await client.accountStatus()).account, isNull);
    });

    test('tells "signed out" apart from "there is nothing here to sign in '
        'to" — the two that used to look identical', () async {
      final signedOut = _clientWith(
        (options) => const FakeHttpResponse(200, {
          'account': null,
          'accountsAvailable': true,
        }),
      );
      final noAccounts = _clientWith(
        (options) => const FakeHttpResponse(200, {
          'account': null,
          'accountsAvailable': false,
        }),
      );

      expect((await signedOut.accountStatus()).accountsAvailable, isTrue);
      expect((await noAccounts.accountStatus()).accountsAvailable, isFalse);
    });

    test('assumes accounts are available against a node too old to say, '
        'which is exactly how the app behaved before the flag', () async {
      final client = _clientWith(
        (options) => const FakeHttpResponse(200, {'account': null}),
      );

      expect((await client.accountStatus()).accountsAvailable, isTrue);
    });
  });

  group('listFriendRequests', () {
    test(
      'keeps the live/fetchedAt honesty flags a fresh answer carries',
      () async {
        final client = _clientWith(
          (options) => const FakeHttpResponse(200, {
            'requests': [
              {
                'id': 'req-1',
                'fromAccountId': 'acc-2',
                'fromUsername': 'bob',
                'toAccountId': 'acc-1',
                'toUsername': 'jorge',
                'status': 'pending',
                'createdAt': '2026-09-05T10:00:00.000Z',
              },
            ],
            'fetchedAt': '2026-09-05T10:00:00.000Z',
            'live': true,
          }),
        );

        final snapshot = await client.listFriendRequests();

        expect(snapshot.live, isTrue);
        expect(snapshot.neverFetched, isFalse);
        expect(snapshot.pending, hasLength(1));
        expect(snapshot.pending.single.fromLabel, 'bob');
      },
    );

    test('an empty list this device has never managed to fetch is flagged '
        'as never fetched, not as "no requests"', () async {
      final client = _clientWith(
        (options) => const FakeHttpResponse(200, {
          'requests': [],
          'fetchedAt': null,
          'live': false,
        }),
      );

      final snapshot = await client.listFriendRequests();

      expect(snapshot.pending, isEmpty);
      expect(snapshot.live, isFalse);
      expect(snapshot.neverFetched, isTrue);
    });

    test('a stale-but-once-fetched snapshot is not "never fetched"', () async {
      final client = _clientWith(
        (options) => const FakeHttpResponse(200, {
          'requests': [],
          'fetchedAt': '2026-09-05T09:00:00.000Z',
          'live': false,
        }),
      );

      final snapshot = await client.listFriendRequests();

      expect(snapshot.live, isFalse);
      expect(snapshot.neverFetched, isFalse);
    });

    test('a sender whose username could not be resolved is never given a '
        'made-up name', () async {
      final client = _clientWith(
        (options) => const FakeHttpResponse(200, {
          'requests': [
            {
              'id': 'req-1',
              'fromAccountId': 'acc-2',
              'fromUsername': null,
              'toAccountId': 'acc-1',
              'toUsername': 'jorge',
              'status': 'pending',
              'createdAt': '2026-09-05T10:00:00.000Z',
            },
          ],
          'fetchedAt': '2026-09-05T10:00:00.000Z',
          'live': true,
        }),
      );

      final snapshot = await client.listFriendRequests();

      expect(snapshot.pending.single.fromUsername, isNull);
      expect(snapshot.pending.single.fromLabel, 'Someone');
      // Emphatically not the raw account id.
      expect(snapshot.pending.single.fromLabel, isNot(contains('acc-2')));
    });

    test('a 409 (this device is not signed in) is surfaced as such', () async {
      final client = _clientWith(
        (options) => const FakeHttpResponse(409, {'error': 'not logged in'}),
      );

      expect(
        client.listFriendRequests,
        throwsA(
          isA<AccountClientException>().having(
            (e) => e.statusCode,
            'statusCode',
            409,
          ),
        ),
      );
    });
  });

  group('friend request actions', () {
    test('sends the username in the body of a POST', () async {
      late RequestOptions seen;
      final client = _clientWith((options) {
        seen = options;
        return const FakeHttpResponse(201, {
          'id': 'req-1',
          'fromAccountId': 'acc-1',
          'toAccountId': 'acc-2',
          'status': 'pending',
          'createdAt': '2026-09-05T10:00:00.000Z',
        });
      });

      await client.sendFriendRequest('bob');

      expect(seen.method, 'POST');
      expect(seen.path, '/api/v1/account/friend-requests');
      expect((seen.data as Map)['toUsername'], 'bob');
    });

    test('accept and decline hit their own routes', () async {
      final paths = <String>[];
      final client = _clientWith((options) {
        paths.add(options.path);
        return const FakeHttpResponse(200, {
          'id': 'req-1',
          'fromAccountId': 'acc-2',
          'toAccountId': 'acc-1',
          'status': 'accepted',
          'createdAt': '2026-09-05T10:00:00.000Z',
        });
      });

      await client.acceptFriendRequest('req-1');
      await client.declineFriendRequest('req-2');

      expect(paths, [
        '/api/v1/account/friend-requests/req-1/accept',
        '/api/v1/account/friend-requests/req-2/decline',
      ]);
    });

    test(
      'cancel hits its own route, which is not the unfriend route',
      () async {
        late RequestOptions seen;
        final client = _clientWith((options) {
          seen = options;
          return const FakeHttpResponse(200, {
            'id': 'req-1',
            'fromAccountId': 'acc-1',
            'toAccountId': 'acc-2',
            'status': 'cancelled',
            'createdAt': '2026-09-05T10:00:00.000Z',
          });
        });

        await client.cancelFriendRequest('req-1');

        expect(seen.method, 'POST');
        expect(seen.path, '/api/v1/account/friend-requests/req-1/cancel');
      },
    );

    test('the two refusals cancel can meet are surfaced by status: not the '
        'sender, and already answered', () async {
      for (final status in [403, 409]) {
        final client = _clientWith(
          (options) =>
              FakeHttpResponse(status, {'error': 'nope', 'code': 'conflict'}),
        );

        await expectLater(
          () => client.cancelFriendRequest('req-1'),
          throwsA(
            isA<AccountClientException>().having(
              (e) => e.statusCode,
              'statusCode',
              status,
            ),
          ),
        );
      }
    });
  });

  group('outgoing friend requests', () {
    test('are read from the same answer as the incoming ones, and the one '
        'honesty flag covers both', () async {
      final client = _clientWith(
        (options) => const FakeHttpResponse(200, {
          'requests': [
            {
              'id': 'req-1',
              'fromAccountId': 'acc-2',
              'fromUsername': 'bob',
              'toAccountId': 'acc-1',
              'toUsername': 'jorge',
              'status': 'pending',
              'createdAt': '2026-09-05T10:00:00.000Z',
            },
          ],
          'outgoing': [
            {
              'id': 'req-2',
              'fromAccountId': 'acc-1',
              'fromUsername': 'jorge',
              'toAccountId': 'acc-3',
              'toUsername': 'carol',
              'status': 'pending',
              'createdAt': '2026-09-04T10:00:00.000Z',
            },
          ],
          'fetchedAt': '2026-09-05T10:00:00.000Z',
          'live': true,
        }),
      );

      final snapshot = await client.listFriendRequests();

      expect(snapshot.pending.single.fromLabel, 'bob');
      expect(snapshot.pendingOutgoing.single.toLabel, 'carol');
      expect(
        snapshot.pendingOutgoing.single.sentAt,
        DateTime.utc(2026, 9, 4, 10),
      );
      expect(snapshot.live, isTrue);
    });

    test('a status this build has never heard of is simply not pending, '
        'rather than a parse failure', () async {
      final client = _clientWith(
        (options) => const FakeHttpResponse(200, {
          'requests': [],
          'outgoing': [
            {
              'id': 'req-2',
              'fromAccountId': 'acc-1',
              'toAccountId': 'acc-3',
              'toUsername': 'carol',
              'status': 'cancelled',
              'createdAt': '2026-09-04T10:00:00.000Z',
            },
            {
              'id': 'req-3',
              'fromAccountId': 'acc-1',
              'toAccountId': 'acc-4',
              'toUsername': 'dave',
              'status': 'something-new',
              'createdAt': '2026-09-04T10:00:00.000Z',
            },
          ],
          'fetchedAt': '2026-09-05T10:00:00.000Z',
          'live': true,
        }),
      );

      final snapshot = await client.listFriendRequests();

      expect(snapshot.outgoing, hasLength(2));
      expect(snapshot.pendingOutgoing, isEmpty);
    });

    test('an answer with no "outgoing" key at all still parses, and claims '
        'nothing', () async {
      final client = _clientWith(
        (options) => const FakeHttpResponse(200, {
          'requests': [],
          'fetchedAt': '2026-09-05T10:00:00.000Z',
          'live': true,
        }),
      );

      final snapshot = await client.listFriendRequests();

      expect(snapshot.outgoing, isEmpty);
    });

    test('a recipient the service could not name is never given a made-up '
        'name either', () async {
      final client = _clientWith(
        (options) => const FakeHttpResponse(200, {
          'requests': [],
          'outgoing': [
            {
              'id': 'req-2',
              'fromAccountId': 'acc-1',
              'toAccountId': 'acc-3',
              'toUsername': null,
              'status': 'pending',
              'createdAt': '2026-09-04T10:00:00.000Z',
            },
          ],
          'fetchedAt': '2026-09-05T10:00:00.000Z',
          'live': true,
        }),
      );

      final snapshot = await client.listFriendRequests();

      expect(snapshot.pendingOutgoing.single.toUsername, isNull);
      expect(snapshot.pendingOutgoing.single.toLabel, 'Someone');
      expect(snapshot.pendingOutgoing.single.toLabel, isNot(contains('acc-3')));
    });
  });

  group('devices', () {
    test('reads what a person can recognise a device by, including one that '
        'never said what it is', () async {
      late RequestOptions seen;
      final client = _clientWith((options) {
        seen = options;
        return FakeHttpResponse(200, {
          'devices': [
            {
              'nodeId': 'a' * 64,
              'publicKeyBase64': 'key-1',
              'linkedAt': '2026-09-01T10:00:00.000Z',
              'relayUrl': 'ws://relay.test:8090/connect',
              'deviceName': 'Android',
              'isThisDevice': false,
            },
            {
              'nodeId': 'b' * 64,
              'publicKeyBase64': 'key-2',
              'linkedAt': '2026-09-05T10:00:00.000Z',
              'relayUrl': null,
              'deviceName': null,
              'isThisDevice': true,
            },
          ],
        });
      });

      final devices = await client.listDevices();

      expect(seen.method, 'GET');
      expect(seen.path, '/api/v1/account/devices');
      expect(devices.map((d) => d.label), ['Android', 'Unknown device']);
      expect(devices.first.linkedAt, DateTime.utc(2026, 9, 1, 10));
      expect(devices.first.isThisDevice, isFalse);
      expect(devices.last.isThisDevice, isTrue);
      // The label never falls back to the node id, which is the one thing
      // on the wire that means nothing to a person.
      expect(devices.last.label, isNot(contains('b')));
    });

    test('a server too old to say which device is asking marks none of them '
        'rather than guessing', () async {
      final client = _clientWith(
        (options) => FakeHttpResponse(200, {
          'devices': [
            {
              'nodeId': 'a' * 64,
              'publicKeyBase64': 'key-1',
              'linkedAt': '2026-09-01T10:00:00.000Z',
              'deviceName': 'Android',
            },
          ],
        }),
      );

      final devices = await client.listDevices();

      expect(devices.single.isThisDevice, isFalse);
    });

    test(
      'each failure the screen has to tell apart arrives with its status',
      () async {
        for (final status in [409, 502, 503]) {
          final client = _clientWith(
            (options) => FakeHttpResponse(status, {'error': 'nope'}),
          );

          await expectLater(
            client.listDevices,
            throwsA(
              isA<AccountClientException>().having(
                (e) => e.statusCode,
                'statusCode',
                status,
              ),
            ),
          );
        }
      },
    );

    test('unlinking another device is a DELETE on that device, and reports '
        'that this one is still signed in', () async {
      late RequestOptions seen;
      final client = _clientWith((options) {
        seen = options;
        return const FakeHttpResponse(200, {'signedOut': false});
      });

      final signedOut = await client.unlinkDevice('a' * 64);

      expect(seen.method, 'DELETE');
      expect(seen.path, '/api/v1/account/devices/${'a' * 64}');
      expect(signedOut, isFalse);
    });

    test('unlinking this device reports the sign-out from the body, which is '
        'the only place that knows it', () async {
      final client = _clientWith(
        (options) => const FakeHttpResponse(200, {'signedOut': true}),
      );

      expect(await client.unlinkDevice('b' * 64), isTrue);
    });

    test('a body with no "signedOut" at all is read as "still signed in", '
        'never as a silent sign-out', () async {
      final client = _clientWith((options) => const FakeHttpResponse(200, {}));

      expect(await client.unlinkDevice('b' * 64), isFalse);
    });
  });
}
