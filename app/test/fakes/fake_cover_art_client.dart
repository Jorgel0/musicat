import 'package:musicat/core/network/cover_art/cover_art_client.dart';

class FakeCoverArtClient implements CoverArtClient {
  final List<String> calls = [];
  String? nextUrl;

  @override
  Future<String?> findCoverArtUrl({
    required String artist,
    required String album,
  }) async {
    calls.add('$artist|$album');
    return nextUrl;
  }
}
