import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicat/core/network/cover_art/itunes_cover_art_client.dart';

import 'fakes/fake_http_adapter.dart';

void main() {
  test('returns an upsized artwork URL from the first result', () async {
    late RequestOptions seen;
    final adapter = FakeHttpAdapter((options) {
      seen = options;
      return const FakeHttpResponse(200, {
        'results': [
          {'artworkUrl100': 'https://example.com/art/100x100bb.jpg'},
        ],
      });
    });
    final client = ItunesCoverArtClient(
      dio: Dio()..httpClientAdapter = adapter,
    );

    final url = await client.findCoverArtUrl(
      artist: 'Daft Punk',
      album: 'Discovery',
    );

    expect(url, 'https://example.com/art/600x600bb.jpg');
    expect(seen.queryParameters['term'], 'Daft Punk Discovery');
  });

  test('parses correctly even when served as text/javascript, not '
      'application/json — what the real iTunes API actually sends', () async {
    final adapter = FakeHttpAdapter(
      (_) => const FakeHttpResponse(200, {
        'results': [
          {'artworkUrl100': 'https://example.com/art/100x100bb.jpg'},
        ],
      }, contentType: 'text/javascript; charset=utf-8'),
    );
    final client = ItunesCoverArtClient(
      dio: Dio()..httpClientAdapter = adapter,
    );

    final url = await client.findCoverArtUrl(
      artist: 'Daft Punk',
      album: 'Discovery',
    );

    expect(url, 'https://example.com/art/600x600bb.jpg');
  });

  test('returns null when there are no results', () async {
    final adapter = FakeHttpAdapter(
      (_) => const FakeHttpResponse(200, {'results': []}),
    );
    final client = ItunesCoverArtClient(
      dio: Dio()..httpClientAdapter = adapter,
    );

    final url = await client.findCoverArtUrl(
      artist: 'Nobody',
      album: 'Nothing',
    );

    expect(url, isNull);
  });

  test('returns null on a network error instead of throwing', () async {
    final adapter = FakeHttpAdapter((_) => const FakeHttpResponse(500, 'boom'));
    final client = ItunesCoverArtClient(
      dio: Dio()..httpClientAdapter = adapter,
    );

    final url = await client.findCoverArtUrl(artist: 'A', album: 'B');

    expect(url, isNull);
  });

  test('skips the request entirely for an unparseable artist', () async {
    final adapter = FakeHttpAdapter(
      (_) => throw StateError('should not be called'),
    );
    final client = ItunesCoverArtClient(
      dio: Dio()..httpClientAdapter = adapter,
    );

    final url = await client.findCoverArtUrl(
      artist: 'Unknown artist',
      album: 'Some Folder Name',
    );

    expect(url, isNull);
    expect(adapter.requests, isEmpty);
  });
}
