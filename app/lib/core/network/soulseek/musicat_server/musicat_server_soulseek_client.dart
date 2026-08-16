import 'package:dio/dio.dart';

import '../soulseek_client.dart';

/// [SoulseekClient] backed by a self-hosted Musicat Server instance's
/// `/api/v1/soulseek/*` API (server ADR 0016) rather than talking to slskd
/// directly.
///
/// Deliberately thinner than `SlskdSoulseekClient`: Musicat Server has
/// already done slskd's quirk-handling server-side (the fire-and-forget
/// search POST, the nested-tree flattening, the transfer-state-flag
/// parsing), so this client is just a JSON decoder for an API that's
/// already shaped the way the app's domain types expect it. See ADR 0017.
class MusicatServerSoulseekClient implements SoulseekClient {
  MusicatServerSoulseekClient({required String baseUrl, Dio? dio})
    : _dio = dio ?? Dio() {
    _dio.options.baseUrl = baseUrl;
  }

  final Dio _dio;

  @override
  Future<bool> isConnected() async {
    final response = await _handle(
      () => _dio.get<Map<String, dynamic>>('/api/v1/soulseek/status'),
    );
    return response.data?['connected'] == true;
  }

  @override
  Future<String> startSearch(String query) async {
    // Unlike SlskdSoulseekClient, this is a normal request/response call:
    // Musicat Server itself already returns as soon as the search is
    // registered, without waiting for slskd's own search to finish.
    final response = await _handle(
      () => _dio.post<Map<String, dynamic>>(
        '/api/v1/soulseek/searches',
        data: {'query': query},
      ),
    );
    return response.data!['searchId'] as String;
  }

  @override
  Future<SoulseekSearch> getSearch(String searchId) async {
    final response = await _handle(
      () =>
          _dio.get<Map<String, dynamic>>('/api/v1/soulseek/searches/$searchId'),
    );
    return _searchFromJson(response.data!);
  }

  @override
  Future<void> cancelSearch(String searchId) async {
    await _handle(
      () => _dio.delete<void>('/api/v1/soulseek/searches/$searchId'),
    );
  }

  @override
  Future<void> enqueueDownload({
    required String username,
    required List<SoulseekFile> files,
  }) async {
    try {
      await _dio.post<void>(
        '/api/v1/soulseek/downloads',
        data: {
          'username': username,
          'files': [
            for (final file in files)
              {'filename': file.filename, 'sizeBytes': file.sizeBytes},
          ],
        },
      );
    } on DioException catch (e) {
      final message = _errorMessage(e);
      if (e.response?.statusCode == 404) {
        throw SoulseekUserOfflineException(username, message);
      }
      throw SoulseekClientException(e.response?.statusCode ?? 0, message);
    }
  }

  @override
  Future<List<SoulseekTransfer>> getDownloads() async {
    final response = await _handle(
      () => _dio.get<List<dynamic>>('/api/v1/soulseek/downloads'),
    );
    return [
      for (final transfer in response.data ?? const [])
        _transferFromJson(transfer as Map<String, dynamic>),
    ];
  }

  @override
  Future<void> cancelDownload({
    required String username,
    required String transferId,
  }) async {
    await _handle(
      () =>
          _dio.delete<void>('/api/v1/soulseek/downloads/$username/$transferId'),
    );
  }

  @override
  Future<String?> getDownloadsDirectory() async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/api/v1/soulseek/downloads-directory',
      );
      return response.data?['directory'] as String?;
    } on DioException {
      return null;
    }
  }

  Future<Response<T>> _handle<T>(Future<Response<T>> Function() request) async {
    try {
      return await request();
    } on DioException catch (e) {
      final statusCode = e.response?.statusCode;
      final message = _errorMessage(e);
      if (statusCode == 409) throw SoulseekNotConnectedException(message);
      throw SoulseekClientException(statusCode ?? 0, message);
    }
  }

  String _errorMessage(DioException e) {
    final data = e.response?.data;
    if (data is Map && data['error'] is String) return data['error'] as String;
    if (data is String) return data;
    return e.message ?? 'Unknown error';
  }

  SoulseekSearch _searchFromJson(Map<String, dynamic> json) {
    final results = json['results'] as List<dynamic>? ?? const [];
    return SoulseekSearch(
      id: json['id'] as String,
      query: json['query'] as String? ?? '',
      state: json['state'] == 'completed'
          ? SoulseekSearchState.completed
          : SoulseekSearchState.inProgress,
      results: [
        for (final result in results)
          _searchResultFromJson(result as Map<String, dynamic>),
      ],
    );
  }

  SoulseekSearchResult _searchResultFromJson(Map<String, dynamic> json) {
    final files = json['files'] as List<dynamic>? ?? const [];
    return SoulseekSearchResult(
      username: json['username'] as String,
      hasFreeUploadSlot: json['hasFreeUploadSlot'] as bool? ?? false,
      queueLength: (json['queueLength'] as num?)?.toInt() ?? 0,
      uploadSpeedBytesPerSecond:
          (json['uploadSpeedBytesPerSecond'] as num?)?.toInt() ?? 0,
      files: [
        for (final file in files) _fileFromJson(file as Map<String, dynamic>),
      ],
    );
  }

  SoulseekFile _fileFromJson(Map<String, dynamic> json) => SoulseekFile(
    filename: json['filename'] as String,
    sizeBytes: (json['sizeBytes'] as num).toInt(),
    bitRateKbps: (json['bitRateKbps'] as num?)?.toInt(),
    durationSeconds: (json['durationSeconds'] as num?)?.toInt(),
  );

  SoulseekTransfer _transferFromJson(Map<String, dynamic> json) =>
      SoulseekTransfer(
        id: json['id'] as String,
        username: json['username'] as String,
        filename: json['filename'] as String,
        sizeBytes: (json['sizeBytes'] as num).toInt(),
        bytesTransferred: (json['bytesTransferred'] as num?)?.toInt() ?? 0,
        state: SoulseekTransferState.values.firstWhere(
          (state) => state.name == json['state'],
          orElse: () => SoulseekTransferState.queued,
        ),
        placeInQueue: (json['placeInQueue'] as num?)?.toInt(),
      );
}
