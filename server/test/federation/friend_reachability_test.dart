import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:musicat_server/src/federation/friend.dart';
import 'package:musicat_server/src/federation/friend_reachability.dart';
import 'package:test/test.dart';

void main() {
  final friendWithRelay = Friend.devicePinned(
    nodeId: 'abc123',
    publicKeyBase64: 'key',
    address: 'unreachable.invalid:9999',
    relayUrl: 'ws://relay.example.com:8090/connect',
  );
  final friendWithoutRelay = Friend.devicePinned(
    nodeId: 'abc123',
    publicKeyBase64: 'key',
    address: 'unreachable.invalid:9999',
  );

  group('relayForwardUri', () {
    test('rebuilds the address from scheme/host/port only, ignoring path', () {
      final uri = relayForwardUri(
        'ws://relay.example.com:8090/connect',
        'abc123',
        '/api/v1/sharing/shared-tracks',
      );
      expect(
        uri,
        Uri.parse(
          'http://relay.example.com:8090/abc123/api/v1/sharing/shared-tracks',
        ),
      );
    });

    test('maps wss to https', () {
      final uri = relayForwardUri(
        'wss://relay.example.com/connect',
        'abc123',
        '/x',
      );
      expect(uri.scheme, 'https');
    });
  });

  group('reachFriend', () {
    test('returns the direct response when the friend answers', () async {
      final client = MockClient((request) async {
        expect(request.url.host, 'unreachable.invalid');
        return http.Response('direct-ok', 200);
      });

      final response = await reachFriend(client, friendWithRelay, '/some/path');
      expect(response.body, 'direct-ok');
    });

    test("an application-level error response isn't treated as unreachable "
        '(no relay fallback attempted)', () async {
      var callCount = 0;
      final client = MockClient((request) async {
        callCount++;
        return http.Response('not found', 404);
      });

      final response = await reachFriend(client, friendWithRelay, '/some/path');
      expect(response.statusCode, 404);
      expect(callCount, 1);
    });

    test('falls back to the relay when direct reachability throws', () async {
      final client = MockClient((request) async {
        if (request.url.host == 'unreachable.invalid') {
          throw const SocketException('nope');
        }
        expect(request.url.host, 'relay.example.com');
        expect(request.url.path, '/abc123/some/path');
        return http.Response('via-relay', 200);
      });

      final response = await reachFriend(client, friendWithRelay, '/some/path');
      expect(response.body, 'via-relay');
    });

    test(
      'rethrows when direct reachability fails and there is no relay',
      () async {
        final client = MockClient((request) async {
          throw const SocketException('nope');
        });

        expect(
          () => reachFriend(client, friendWithoutRelay, '/some/path'),
          throwsA(isA<SocketException>()),
        );
      },
    );
  });

  group('reachFriendStreamed', () {
    test('falls back to the relay when direct reachability throws', () async {
      final client = MockClient((request) async {
        if (request.url.host == 'unreachable.invalid') {
          throw const SocketException('nope');
        }
        expect(request.url.host, 'relay.example.com');
        expect(request.url.path, '/abc123/file/path');
        return http.Response('bytes-via-relay', 200);
      });

      final streamed = await reachFriendStreamed(
        client,
        friendWithRelay,
        '/file/path',
      );
      final body = await streamed.stream.bytesToString();
      expect(body, 'bytes-via-relay');
    });
  });

  group('reachFriend across an account friend\'s several devices', () {
    // Two devices: the most recently linked one (the "new phone") has no
    // usable address, the older desktop does. Ordering is
    // most-recently-linked first, so the phone is tried first.
    final accountFriend = Friend(
      accountId: 'account-1',
      devices: [
        FriendDevice(
          nodeId: 'desktop-node',
          publicKeyBase64: 'desktop-key',
          address: 'desktop.invalid:9999',
          linkedAt: DateTime.utc(2026, 1, 1),
        ),
        FriendDevice(
          nodeId: 'phone-node',
          publicKeyBase64: 'phone-key',
          address: 'phone.invalid:9999',
          relayUrl: 'ws://relay.example.com:8090/connect',
          linkedAt: DateTime.utc(2026, 6, 1),
        ),
      ],
    );

    test('tries the most recently linked device first', () async {
      final tried = <String>[];
      final client = MockClient((request) async {
        tried.add(request.url.host);
        return http.Response('ok', 200);
      });

      await reachFriend(client, accountFriend, '/p');

      expect(tried, ['phone.invalid']);
    });

    test(
      'tries every device directly before falling back to any relay',
      () async {
        final tried = <Uri>[];
        final client = MockClient((request) async {
          tried.add(request.url);
          if (request.url.host == 'desktop.invalid') {
            return http.Response('desktop-ok', 200);
          }
          throw const SocketException('nope');
        });

        final response = await reachFriend(client, accountFriend, '/p');

        expect(response.body, 'desktop-ok');
        // The phone's relay is never touched: a device that answers directly
        // always wins over another device's relay. This is the whole point of
        // ordering direct-before-relay rather than per-device
        // direct-then-relay -- see the group below for what the old
        // interleaved order cost.
        expect(tried.map((u) => '${u.host}${u.path}').toList(), [
          'phone.invalid/p',
          'desktop.invalid/p',
        ]);
      },
    );

    test('falls back to the relays, in device order, once no device answers '
        'directly', () async {
      final tried = <Uri>[];
      final client = MockClient((request) async {
        tried.add(request.url);
        if (request.url.host == 'relay.example.com') {
          return http.Response('relay-ok', 200);
        }
        throw const SocketException('nope');
      });

      final response = await reachFriend(client, accountFriend, '/p');

      expect(response.body, 'relay-ok');
      expect(tried.map((u) => '${u.host}${u.path}').toList(), [
        'phone.invalid/p',
        'desktop.invalid/p',
        // the phone's own relay, addressed to the phone's nodeId
        'relay.example.com/phone-node/p',
      ]);
    });

    test('an application-level error from the first device is a real answer, '
        'not a reason to try the next one', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        return http.Response('nope', 403);
      });

      final response = await reachFriend(client, accountFriend, '/p');

      expect(response.statusCode, 403);
      expect(calls, 1);
    });

    test('throws FriendUnreachableException when no device has any address '
        'or relay at all', () async {
      final unreachable = Friend(
        accountId: 'account-2',
        devices: const [FriendDevice(nodeId: 'n1', publicKeyBase64: 'k1')],
      );
      final client = MockClient((_) async => http.Response('never', 200));

      expect(
        () => reachFriend(client, unreachable, '/p'),
        throwsA(isA<FriendUnreachableException>()),
      );
    });
  });
}
