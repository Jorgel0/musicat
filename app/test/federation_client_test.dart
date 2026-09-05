import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicat/core/network/federation/federation_client.dart';

import 'fakes/fake_http_adapter.dart';

FederationClient _clientWith(
  FakeHttpResponse Function(RequestOptions options) handler, {
  String? apiKey,
}) {
  final adapter = FakeHttpAdapter(handler);
  final dio = Dio()..httpClientAdapter = adapter;
  return FederationClient(
    baseUrl: 'http://musicat-server.test',
    dio: dio,
    apiKey: apiKey,
  );
}

void main() {
  group('X-Api-Key header — this device\'s own server', () {
    test('is sent on every call when apiKey is configured', () async {
      late RequestOptions seen;
      final client = _clientWith((options) {
        seen = options;
        return const FakeHttpResponse(200, {
          'nodeId': 'n',
          'publicKeyBase64': 'pk',
        });
      }, apiKey: 'secret-key');

      await client.getMyNode();

      expect(seen.headers['X-Api-Key'], 'secret-key');
    });

    test('is not sent when apiKey is null (the default)', () async {
      late RequestOptions seen;
      final client = _clientWith((options) {
        seen = options;
        return const FakeHttpResponse(200, {
          'nodeId': 'n',
          'publicKeyBase64': 'pk',
        });
      });

      await client.getMyNode();

      expect(seen.headers.containsKey('X-Api-Key'), isFalse);
    });

    test('is not sent when apiKey is empty', () async {
      late RequestOptions seen;
      final client = _clientWith((options) {
        seen = options;
        return const FakeHttpResponse(200, {
          'nodeId': 'n',
          'publicKeyBase64': 'pk',
        });
      }, apiKey: '');

      await client.getMyNode();

      expect(seen.headers.containsKey('X-Api-Key'), isFalse);
    });
  });

  group('listFriends — a friend is an account with devices', () {
    test('parses the devices a friend account is signed in on', () async {
      final client = _clientWith(
        (options) => const FakeHttpResponse(200, [
          {
            'nodeId': 'device-1',
            'publicKeyBase64': 'pk1',
            'address': 'a.example:8080',
            'displayName': 'Ada',
            'relayUrl': null,
            'localNickname': null,
            'accountId': 'acc-ada',
            'devices': [
              {
                'nodeId': 'device-1',
                'publicKeyBase64': 'pk1',
                'address': 'a.example:8080',
                'relayUrl': null,
                'linkedAt': '2026-09-01T10:00:00.000Z',
              },
              {
                'nodeId': 'device-2',
                'publicKeyBase64': 'pk2',
                'address': null,
                'relayUrl': 'wss://relay.example/session/xyz',
                'linkedAt': '2026-09-04T10:00:00.000Z',
              },
            ],
          },
        ]),
      );

      final friends = await client.listFriends();

      expect(friends, hasLength(1));
      expect(friends.single.accountId, 'acc-ada');
      expect(friends.single.devices, hasLength(2));
      // A device reachable only through a relay is still reachable — the
      // shape every friend made purely by username has (server ADR 0051).
      expect(friends.single.devices[1].address, isNull);
      expect(friends.single.devices[1].isReachable, isTrue);
      expect(friends.single.devices[0].linkedAt, DateTime.utc(2026, 9, 1, 10));
    });

    test('a pre-accounts response (no "devices" key at all) reads as the '
        'one device its flat fields describe, not as none', () async {
      final client = _clientWith(
        (options) => const FakeHttpResponse(200, [
          {
            'nodeId': 'legacy-node',
            'publicKeyBase64': 'pk1',
            'address': 'a.example:8080',
          },
        ]),
      );

      final friends = await client.listFriends();

      expect(friends.single.devices, hasLength(1));
      expect(friends.single.devices.single.address, 'a.example:8080');
      expect(friends.single.devices.single.isReachable, isTrue);
      expect(friends.single.accountId, isNull);
    });

    test('a device with neither an address nor a relay is honestly not '
        'reachable', () async {
      final client = _clientWith(
        (options) => const FakeHttpResponse(200, [
          {
            'nodeId': 'device-1',
            'publicKeyBase64': 'pk1',
            'address': '',
            'accountId': 'acc-ada',
            'devices': [
              {'nodeId': 'device-1', 'publicKeyBase64': 'pk1'},
            ],
          },
        ]),
      );

      final friends = await client.listFriends();

      expect(friends.single.devices.single.isReachable, isFalse);
      expect(friends.single.devices.single.linkedAt, isNull);
    });
  });

  group('addFriend — the friend\'s server', () {
    test("never carries this device's own configured apiKey, even when one "
        'is configured for calls to this device\'s own server (that call is '
        "federation-facing, going to someone else's server with its own, "
        'unrelated pairing-code auth)', () async {
      // addFriend's call to the friend's server goes through a second,
      // non-injectable Dio built internally from `friendBaseUrl` — a real
      // loopback HttpServer is the only way to observe what it actually
      // sends, since the shared FakeHttpAdapter pattern can't intercept
      // it (see FakeFederationClient's doc comment).
      Map<String, String>? seenHeaders;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final headers = <String, String>{};
        request.headers.forEach(
          (name, values) => headers[name] = values.join(','),
        );
        seenHeaders = headers;
        request.response.statusCode = 200;
        await request.response.close();
      });
      addTearDown(server.close);

      final ownAdapter = FakeHttpAdapter(
        (_) => const FakeHttpResponse(200, {
          'nodeId': 'my-node',
          'publicKeyBase64': 'my-pk',
        }),
      );
      final ownDio = Dio()..httpClientAdapter = ownAdapter;
      final client = FederationClient(
        baseUrl: 'http://musicat-server.test',
        dio: ownDio,
        apiKey: 'this-devices-own-secret',
      );

      await client.addFriend(
        friendBaseUrl: 'http://${server.address.address}:${server.port}',
        code: 'the-code',
        myPublicAddress: 'me.example:8080',
      );

      expect(seenHeaders, isNotNull);
      expect(seenHeaders!.containsKey('x-api-key'), isFalse);
    });
  });
}
