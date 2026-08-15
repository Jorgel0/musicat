import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import 'cover_art_client.dart';

/// [CoverArtClient] backed by Apple's public iTunes Search API — free, no
/// API key, but unauthenticated and rate-limited (informally ~20
/// requests/minute per Apple), so callers should cache results rather
/// than re-querying the same artist/album repeatedly. See ADR 0012.
class ItunesCoverArtClient implements CoverArtClient {
  ItunesCoverArtClient({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  // The search screen can build a dozen+ cover art lookups at once (one
  // per visible album/song row) as soon as results come in. A burst that
  // size doesn't fail outright, but it does count heavily against Apple's
  // informal ~20 requests/minute limit, so lookups are throttled to a
  // small number in flight at once, queueing the rest. See ADR 0012.
  static const _maxConcurrent = 3;
  int _active = 0;
  final _queue = <Completer<void>>[];

  Future<T> _throttled<T>(Future<T> Function() task) async {
    if (_active >= _maxConcurrent) {
      final completer = Completer<void>();
      _queue.add(completer);
      await completer.future;
    }
    _active++;
    try {
      return await task();
    } finally {
      _active--;
      if (_queue.isNotEmpty) _queue.removeAt(0).complete();
    }
  }

  @override
  Future<String?> findCoverArtUrl({
    required String artist,
    required String album,
  }) {
    // The filename-parsing heuristic (ADR 0011) falls back to this exact
    // string when it can't tell artist from album — searching iTunes for
    // it would just risk a wrong match, so skip the call (and the queue)
    // entirely.
    if (artist == 'Unknown artist') return Future.value(null);
    return _throttled(() => _findCoverArtUrl(artist: artist, album: album));
  }

  Future<String?> _findCoverArtUrl({
    required String artist,
    required String album,
  }) async {
    try {
      // iTunes serves this endpoint as `text/javascript`, not
      // `application/json` — dio only auto-decodes JSON when the
      // response's content-type says so, so a typed `.get<Map<String,
      // dynamic>>()` here would just throw a cast error on the raw
      // string it returns instead. Fetching as plain text and decoding
      // manually sidesteps that entirely.
      final response = await _dio.get<String>(
        'https://itunes.apple.com/search',
        queryParameters: {
          'term': '$artist $album',
          'entity': 'album',
          'limit': 1,
        },
        options: Options(responseType: ResponseType.plain),
      );
      final decoded = jsonDecode(response.data ?? '') as Map<String, dynamic>;
      final results = decoded['results'] as List<dynamic>?;
      if (results == null || results.isEmpty) return null;

      final artworkUrl100 =
          (results.first as Map<String, dynamic>)['artworkUrl100'] as String?;
      if (artworkUrl100 == null) return null;

      // iTunes artwork URLs encode the requested resolution in the path;
      // swap it for something larger than the API's own low-res default.
      return artworkUrl100.replaceFirst('100x100', '600x600');
    } catch (_) {
      return null;
    }
  }
}
