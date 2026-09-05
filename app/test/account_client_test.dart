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

    test('surfaces the status code for each failure the UI has to tell '
        'apart', () async {
      for (final status in [400, 401, 429, 502, 503]) {
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
    });
  });

  group('currentAccount', () {
    test('reads the account out of its "account" envelope', () async {
      final client = _clientWith(
        (options) => const FakeHttpResponse(200, {
          'account': {
            'accountId': 'acc-1',
            'username': 'jorge',
            'loggedInAt': '2026-09-05T10:00:00.000Z',
          },
        }),
      );

      final account = await client.currentAccount();

      expect(account, isNotNull);
      expect(account!.username, 'jorge');
    });

    test('is null, not an error, when signed out', () async {
      final client = _clientWith(
        (options) => const FakeHttpResponse(200, {'account': null}),
      );

      expect(await client.currentAccount(), isNull);
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
  });
}
