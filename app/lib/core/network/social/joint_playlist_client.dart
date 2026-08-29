import 'package:dio/dio.dart';

/// One track in a [JointPlaylist] — always backed by a `SharedTrack` on
/// [ownerNodeId]'s own server, downloadable the same way as any other
/// shared track (see `SharingClient`), just discovered via a playlist
/// instead of a direct share.
class JointPlaylistItem {
  const JointPlaylistItem({
    required this.id,
    required this.title,
    required this.artist,
    required this.ownerNodeId,
    required this.sharedTrackId,
    required this.extension,
    required this.addedAt,
    this.album,
  });

  final String id;
  final String title;
  final String artist;
  final String? album;
  final String ownerNodeId;
  final String sharedTrackId;
  final String extension;
  final DateTime addedAt;

  factory JointPlaylistItem.fromJson(Map<String, dynamic> json) =>
      JointPlaylistItem(
        id: json['id'] as String,
        title: json['title'] as String,
        artist: json['artist'] as String,
        album: json['album'] as String?,
        ownerNodeId: json['ownerNodeId'] as String,
        sharedTrackId: json['sharedTrackId'] as String,
        extension: json['extension'] as String? ?? '',
        addedAt: DateTime.parse(json['addedAt'] as String),
      );
}

/// A playlist shared between this node and one or more friends — each
/// participant keeps their own copy (see server ADR 0026) and reconciles
/// it with the others' via [JointPlaylistClient.sync].
class JointPlaylist {
  const JointPlaylist({
    required this.id,
    required this.name,
    required this.participantNodeIds,
    required this.items,
    required this.updatedAt,
  });

  final String id;
  final String name;

  /// The *other* participants — never includes this node's own id.
  final List<String> participantNodeIds;
  final List<JointPlaylistItem> items;
  final DateTime updatedAt;

  factory JointPlaylist.fromJson(Map<String, dynamic> json) => JointPlaylist(
    id: json['id'] as String,
    name: json['name'] as String,
    participantNodeIds: [
      for (final id in json['participantNodeIds'] as List<dynamic>)
        id as String,
    ],
    items: [
      for (final item in json['items'] as List<dynamic>)
        JointPlaylistItem.fromJson(item as Map<String, dynamic>),
    ],
    updatedAt: DateTime.parse(json['updatedAt'] as String),
  );
}

class JointPlaylistSyncResult {
  const JointPlaylistSyncResult({required this.playlist, required this.errors});

  final JointPlaylist playlist;

  /// Per-participant sync failures (unreachable, not a friend, ...) — a
  /// partial sync still returns whichever participants *did* respond.
  final List<String> errors;
}

class JointPlaylistClientException implements Exception {
  const JointPlaylistClientException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => 'JointPlaylistClientException($statusCode, $message)';
}

/// Talks to *this device's own* Musicat Server for joint playlists
/// (ADR 0026/0027) — this node's own view of each playlist, reconciled
/// with the other participants' copies via an explicit [sync] call.
class JointPlaylistClient {
  /// [apiKey], when non-null and non-empty, is sent as `X-Api-Key` on every
  /// call — only ever meaningful for a genuinely remote, self-hosted
  /// server configured to require it (see
  /// `server/lib/src/http/require_local.dart`); `null`/empty (the default)
  /// sends no such header.
  JointPlaylistClient({required String baseUrl, Dio? dio, String? apiKey})
    : _dio = dio ?? Dio() {
    _dio.options.baseUrl = baseUrl;
    if (apiKey != null && apiKey.isNotEmpty) {
      _dio.options.headers['X-Api-Key'] = apiKey;
    }
  }

  final Dio _dio;

  /// Creates a new playlist, or — when [id] matches one a friend already
  /// created — joins it, so both sides agree on which playlist they're
  /// talking about. Returns the playlist id (either the new one, or [id]
  /// echoed back).
  Future<String> createOrJoinPlaylist({
    required String name,
    required List<String> participantNodeIds,
    String? id,
  }) async {
    final response = await _handle(
      () => _dio.post<Map<String, dynamic>>(
        '/api/v1/playlists',
        data: {
          'name': name,
          'participantNodeIds': participantNodeIds,
          'id': ?id,
        },
      ),
    );
    return response.data!['id'] as String;
  }

  Future<List<JointPlaylist>> listPlaylists() async {
    final response = await _handle(
      () => _dio.get<List<dynamic>>('/api/v1/playlists'),
    );
    return [
      for (final entry in response.data ?? const [])
        JointPlaylist.fromJson(entry as Map<String, dynamic>),
    ];
  }

  Future<JointPlaylist> getPlaylist(String id) async {
    final response = await _handle(
      () => _dio.get<Map<String, dynamic>>('/api/v1/playlists/$id'),
    );
    return JointPlaylist.fromJson(response.data!);
  }

  Future<void> deletePlaylist(String id) async {
    await _handle(() => _dio.delete<void>('/api/v1/playlists/$id'));
  }

  /// Adds [filePath] (a track from this node's own library) to the
  /// playlist — the server shares it with exactly this playlist's other
  /// participants and records it as a new item. Returns the new item id.
  Future<String> addItem({
    required String playlistId,
    required String filePath,
    required String title,
    required String artist,
    String? album,
    String? coverArtPath,
  }) async {
    final response = await _handle(
      () => _dio.post<Map<String, dynamic>>(
        '/api/v1/playlists/$playlistId/items',
        data: {
          'filePath': filePath,
          'title': title,
          'artist': artist,
          'album': ?album,
          'coverArtPath': ?coverArtPath,
        },
      ),
    );
    return response.data!['itemId'] as String;
  }

  Future<JointPlaylistSyncResult> sync(String id) async {
    final response = await _handle(
      () => _dio.post<Map<String, dynamic>>('/api/v1/playlists/$id/sync'),
    );
    final data = response.data!;
    return JointPlaylistSyncResult(
      playlist: JointPlaylist.fromJson(
        data['playlist'] as Map<String, dynamic>,
      ),
      errors: [for (final e in data['errors'] as List<dynamic>) e as String],
    );
  }

  Future<Response<T>> _handle<T>(Future<Response<T>> Function() request) async {
    try {
      return await request();
    } on DioException catch (e) {
      throw JointPlaylistClientException(
        e.response?.statusCode ?? 0,
        _errorMessage(e),
      );
    }
  }

  String _errorMessage(DioException e) {
    final data = e.response?.data;
    if (data is Map && data['error'] is String) return data['error'] as String;
    if (data is String) return data;
    return e.message ?? 'Unknown error';
  }
}
