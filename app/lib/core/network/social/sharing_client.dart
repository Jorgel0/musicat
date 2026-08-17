import 'dart:convert';

import 'package:dio/dio.dart';

/// One of this node's own shares, as its own Musicat Server tracks it.
class MySharedTrack {
  const MySharedTrack({
    required this.id,
    required this.filePath,
    required this.title,
    required this.artist,
    required this.isAllFriends,
    this.album,
  });

  final String id;

  /// This node's own local path — used to tell whether a given library
  /// [Track] is already shared (see the "My Profile" screen).
  final String filePath;
  final String title;
  final String artist;
  final String? album;

  /// Whether this is a "profile" share (visible to every current friend)
  /// as opposed to one sent to one or more specific friends.
  final bool isAllFriends;

  factory MySharedTrack.fromJson(Map<String, dynamic> json) => MySharedTrack(
    id: json['id'] as String,
    filePath: json['filePath'] as String,
    title: json['title'] as String,
    artist: json['artist'] as String,
    album: json['album'] as String?,
    isAllFriends:
        (json['visibility'] as Map<String, dynamic>?)?['type'] == 'allFriends',
  );
}

/// A track a friend has shared, as seen from this side — metadata only,
/// never the friend's local file path (see server ADR 0025).
class SharedTrackSummary {
  const SharedTrackSummary({
    required this.id,
    required this.title,
    required this.artist,
    required this.hasCoverArt,
    required this.extension,
    this.album,
  });

  final String id;
  final String title;
  final String artist;
  final String? album;
  final bool hasCoverArt;

  /// e.g. `.flac` — needed to name the file this gets saved as locally.
  final String extension;

  factory SharedTrackSummary.fromJson(Map<String, dynamic> json) =>
      SharedTrackSummary(
        id: json['id'] as String,
        title: json['title'] as String,
        artist: json['artist'] as String,
        album: json['album'] as String?,
        hasCoverArt: json['hasCoverArt'] as bool? ?? false,
        extension: json['extension'] as String? ?? '',
      );
}

class SharingClientException implements Exception {
  const SharingClientException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => 'SharingClientException($statusCode, $message)';
}

/// Talks to *this device's own* Musicat Server for the metadata-sharing
/// mechanism (ADR 0025/0027/0029): managing what this node shares, and
/// browsing/downloading what a friend has shared back. The friend-facing
/// calls go through this server rather than straight to the friend's,
/// since the app itself never holds this node's signing key — the server
/// proxies them, signed, exactly like it does for joint-playlist sync.
class SharingClient {
  SharingClient({required String baseUrl, Dio? dio}) : _dio = dio ?? Dio() {
    _dio.options.baseUrl = baseUrl;
  }

  final Dio _dio;

  /// Shares [filePath] under [visibility] — either
  /// `{'type': 'friends', 'nodeIds': [...]}` for one or more specific
  /// friends, or `{'type': 'allFriends'}` — matching the server's
  /// `SharedTrackVisibility.fromJson` wire shape. Returns the new share's id.
  Future<String> shareTrack({
    required String filePath,
    required String title,
    required String artist,
    required Map<String, Object?> visibility,
    String? album,
    String? coverArtPath,
  }) async {
    final response = await _handle(
      () => _dio.post<Map<String, dynamic>>(
        '/api/v1/library/shared-tracks',
        data: {
          'filePath': filePath,
          'title': title,
          'artist': artist,
          'visibility': visibility,
          'album': ?album,
          'coverArtPath': ?coverArtPath,
        },
      ),
    );
    return response.data!['id'] as String;
  }

  Future<List<MySharedTrack>> listMyShares() async {
    final response = await _handle(
      () => _dio.get<List<dynamic>>('/api/v1/library/shared-tracks'),
    );
    return [
      for (final entry in response.data ?? const [])
        MySharedTrack.fromJson(entry as Map<String, dynamic>),
    ];
  }

  Future<void> deleteShare(String id) async {
    await _handle(() => _dio.delete<void>('/api/v1/library/shared-tracks/$id'));
  }

  Future<List<SharedTrackSummary>> listFriendSharedTracks(
    String friendNodeId,
  ) async {
    final response = await _handle(
      () => _dio.get<List<dynamic>>(
        '/api/v1/library/friends/$friendNodeId/shared-tracks',
      ),
    );
    return [
      for (final entry in response.data ?? const [])
        SharedTrackSummary.fromJson(entry as Map<String, dynamic>),
    ];
  }

  Future<List<int>> downloadSharedTrackFile(
    String friendNodeId,
    String trackId,
  ) async {
    final response = await _handle(
      () => _dio.get<List<int>>(
        '/api/v1/library/friends/$friendNodeId/shared-tracks/$trackId/file',
        options: Options(responseType: ResponseType.bytes),
      ),
    );
    return response.data!;
  }

  /// `null` when the track has no cover art, rather than an exception.
  Future<List<int>?> downloadSharedTrackCover(
    String friendNodeId,
    String trackId,
  ) async {
    try {
      final response = await _dio.get<List<int>>(
        '/api/v1/library/friends/$friendNodeId/shared-tracks/$trackId/cover',
        options: Options(responseType: ResponseType.bytes),
      );
      return response.data;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      throw SharingClientException(
        e.response?.statusCode ?? 0,
        _errorMessage(e),
      );
    }
  }

  Future<Response<T>> _handle<T>(Future<Response<T>> Function() request) async {
    try {
      return await request();
    } on DioException catch (e) {
      throw SharingClientException(
        e.response?.statusCode ?? 0,
        _errorMessage(e),
      );
    }
  }

  String _errorMessage(DioException e) {
    var data = e.response?.data;
    // The file/cover downloads request raw bytes (ResponseType.bytes), so
    // a JSON {"error": ...} body on failure arrives undecoded -- decode it
    // ourselves rather than surfacing Dio's generic status-code message.
    if (data is List<int>) {
      try {
        data = jsonDecode(utf8.decode(data));
      } catch (_) {
        // Not JSON after all -- fall through to the generic message below.
      }
    }
    if (data is Map && data['error'] is String) return data['error'] as String;
    if (data is String) return data;
    return e.message ?? 'Unknown error';
  }
}
