import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:musicat_server/src/federation/friend.dart';
import 'package:musicat_server/src/federation/friend_reachability.dart';
import 'package:test/test.dart';

void main() {
  const friendWithRelay = Friend(
    nodeId: 'abc123',
    publicKeyBase64: 'key',
    address: 'unreachable.invalid:9999',
    relayUrl: 'ws://relay.example.com:8090/connect',
  );
  const friendWithoutRelay = Friend(
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
}
