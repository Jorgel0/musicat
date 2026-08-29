import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicat/core/network/social/joint_playlist_client.dart';

import 'fakes/fake_http_adapter.dart';

JointPlaylistClient _clientWith(
  FakeHttpResponse Function(RequestOptions options) handler, {
  String? apiKey,
}) {
  final adapter = FakeHttpAdapter(handler);
  final dio = Dio()..httpClientAdapter = adapter;
  return JointPlaylistClient(
    baseUrl: 'http://musicat-server.test',
    dio: dio,
    apiKey: apiKey,
  );
}

void main() {
  group('X-Api-Key header', () {
    test('is sent on every call when apiKey is configured', () async {
      late RequestOptions seen;
      final client = _clientWith((options) {
        seen = options;
        return const FakeHttpResponse(200, <Object?>[]);
      }, apiKey: 'secret-key');

      await client.listPlaylists();

      expect(seen.headers['X-Api-Key'], 'secret-key');
    });

    test('is not sent when apiKey is null (the default, and always the '
        'case for the embedded server)', () async {
      late RequestOptions seen;
      final client = _clientWith((options) {
        seen = options;
        return const FakeHttpResponse(200, <Object?>[]);
      });

      await client.listPlaylists();

      expect(seen.headers.containsKey('X-Api-Key'), isFalse);
    });

    test('is not sent when apiKey is empty', () async {
      late RequestOptions seen;
      final client = _clientWith((options) {
        seen = options;
        return const FakeHttpResponse(200, <Object?>[]);
      }, apiKey: '');

      await client.listPlaylists();

      expect(seen.headers.containsKey('X-Api-Key'), isFalse);
    });
  });
}
