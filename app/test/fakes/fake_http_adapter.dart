import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// A minimal [HttpClientAdapter] fake for testing REST clients without a
/// real server — routes requests through a handler the test supplies,
/// mirroring the project's preference for hand-written fakes (e.g.
/// [FakeAudioPlayerController]) over a mocking framework.
class FakeHttpAdapter implements HttpClientAdapter {
  FakeHttpAdapter(this.handler);

  final FakeHttpResponse Function(RequestOptions options) handler;

  /// Every request seen so far, in order — lets tests assert on method,
  /// path, headers, or body without the handler having to do it inline.
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final response = handler(options);
    // Always JSON-encode, even (especially) for a String body: slskd's own
    // bare-error responses are a JSON string literal (e.g. `"offline"`,
    // quotes included), not raw text — encoding here mirrors that so dio's
    // transformer round-trips it the same way a real response would.
    return ResponseBody.fromString(
      jsonEncode(response.body),
      response.statusCode,
      headers: {
        Headers.contentTypeHeader: [
          response.contentType ?? Headers.jsonContentType,
        ],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class FakeHttpResponse {
  const FakeHttpResponse(this.statusCode, this.body, {this.contentType});

  final int statusCode;
  final Object body;

  /// Defaults to `application/json` — override to reproduce a real
  /// service that serves JSON under a different content-type (e.g.
  /// iTunes Search's `text/javascript`), which dio's default transformer
  /// treats differently from an explicit `application/json`.
  final String? contentType;
}
