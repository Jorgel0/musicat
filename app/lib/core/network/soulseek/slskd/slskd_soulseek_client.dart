import 'dart:async';

import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import '../soulseek_client.dart';

/// [SoulseekClient] backed by a self-hosted `slskd` instance's REST API.
/// See ADR 0010 for the API research this is based on and the reasoning
/// behind the polling design.
class SlskdSoulseekClient implements SoulseekClient {
  SlskdSoulseekClient({
    required String baseUrl,
    required String apiKey,
    Dio? dio,
  }) : _dio = dio ?? Dio() {
    _dio.options.baseUrl = baseUrl;
    _dio.options.headers['X-API-Key'] = apiKey;
  }

  final Dio _dio;
  static const _uuid = Uuid();

  @override
  Future<bool> isConnected() async {
    final response = await _handle(
      () => _dio.get<Map<String, dynamic>>('/api/v0/server'),
    );
    return response.data?['isLoggedIn'] == true;
  }

  @override
  Future<String> startSearch(String query) async {
    if (!await isConnected()) {
      throw const SoulseekNotConnectedException(
        'Not connected to the Soulseek network',
      );
    }

    final id = _uuid.v4();
    // slskd's POST doesn't return until the search completes (or times
    // out, ~15s by default) — but it creates the search record up front,
    // before doing any of that waiting. So rather than block on this
    // response, we return the client-generated id immediately and let
    // callers poll getSearch(id) to observe live progress.
    unawaited(_fireSearch(id, query));
    return id;
  }

  /// Fire-and-forget: nothing awaits the search POST itself, so a failure
  /// here just means the search never appears to a poller (or 404s) —
  /// there's no caller left to throw to.
  Future<void> _fireSearch(String id, String query) async {
    try {
      await _dio.post<void>(
        '/api/v0/searches',
        data: {'id': id, 'searchText': query},
      );
    } on DioException {
      // Swallowed — see above.
    }
  }

  @override
  Future<SoulseekSearch> getSearch(String searchId) async {
    final response = await _handle(
      () => _dio.get<Map<String, dynamic>>(
        '/api/v0/searches/$searchId',
        queryParameters: {'includeResponses': true},
      ),
    );
    return _searchFromJson(response.data!);
  }

  @override
  Future<void> cancelSearch(String searchId) async {
    // slskd returns 200 if the search was actually stopped, or 304 if it
    // had already finished — both are a normal "not running anymore"
    // outcome, not an error.
    await _handle(
      () => _dio.put<void>(
        '/api/v0/searches/$searchId',
        options: Options(
          validateStatus: (status) => status == 200 || status == 304,
        ),
      ),
    );
  }

  @override
  Future<void> enqueueDownload({
    required String username,
    required List<SoulseekFile> files,
  }) async {
    final Response<Map<String, dynamic>> response;
    try {
      response = await _dio.post<Map<String, dynamic>>(
        '/api/v0/transfers/downloads/batches',
        data: {
          'username': username,
          'files': [
            for (final file in files)
              {'filename': file.filename, 'size': file.sizeBytes},
          ],
        },
        // slskd uses 200 (all failed) and 207 (partial failure) as
        // legitimate outcomes carrying a body we need to inspect, not
        // errors — only actual failures (404/429/500/...) should throw.
        options: Options(
          validateStatus: (status) =>
              status == 200 || status == 201 || status == 207,
        ),
      );
    } on DioException catch (e) {
      final message = _errorMessage(e);
      if (e.response?.statusCode == 404) {
        throw SoulseekUserOfflineException(username, message);
      }
      throw SoulseekClientException(e.response?.statusCode ?? 0, message);
    }

    final failures = response.data?['failures'] as List<dynamic>? ?? const [];
    if (failures.isNotEmpty && failures.length == files.length) {
      // Status 200: the request succeeded, but every file failed to
      // enqueue — surface that as an error rather than a silent no-op.
      final messages = failures
          .map((f) => (f as Map<String, dynamic>)['message'])
          .join('; ');
      throw SoulseekClientException(response.statusCode ?? 200, messages);
    }
    // Status 207 (partial failure): at least one file was enqueued
    // successfully — treated as success for v1; the failed file(s) simply
    // never show up in the download queue.
  }

  @override
  Future<List<SoulseekTransfer>> getDownloads() async {
    final response = await _handle(
      () => _dio.get<List<dynamic>>('/api/v0/transfers/downloads'),
    );
    // slskd groups by username, then by directory: [{username, directories:
    // [{directory, fileCount, files: [Transfer...]}]}] — flatten to a
    // single list, which is all the download-queue UI needs.
    final transfers = <SoulseekTransfer>[];
    for (final userEntry in response.data ?? const []) {
      final directories =
          (userEntry as Map<String, dynamic>)['directories']
              as List<dynamic>? ??
          const [];
      for (final directoryEntry in directories) {
        final files =
            (directoryEntry as Map<String, dynamic>)['files']
                as List<dynamic>? ??
            const [];
        for (final fileEntry in files) {
          transfers.add(_transferFromJson(fileEntry as Map<String, dynamic>));
        }
      }
    }
    return transfers;
  }

  @override
  Future<void> cancelDownload({
    required String username,
    required String transferId,
  }) async {
    await _handle(
      () => _dio.delete<void>(
        '/api/v0/transfers/downloads/$username/$transferId',
      ),
    );
  }

  @override
  Future<String?> getDownloadsDirectory() async {
    try {
      final response = await _dio.get<Map<String, dynamic>>('/api/v0/options');
      final directories =
          response.data?['directories'] as Map<String, dynamic>?;
      return directories?['downloads'] as String?;
    } on DioException {
      return null;
    }
  }

  Future<Response<T>> _handle<T>(Future<Response<T>> Function() request) async {
    try {
      return await request();
    } on DioException catch (e) {
      throw SoulseekClientException(
        e.response?.statusCode ?? 0,
        _errorMessage(e),
      );
    }
  }

  String _errorMessage(DioException e) {
    final data = e.response?.data;
    if (data is String) return data;
    if (data is Map && data['message'] is String) {
      return data['message'] as String;
    }
    return e.message ?? 'Unknown error';
  }

  SoulseekSearch _searchFromJson(Map<String, dynamic> json) {
    final state = json['state'] as String? ?? '';
    final responses = json['responses'] as List<dynamic>? ?? const [];
    return SoulseekSearch(
      id: json['id'] as String,
      query: json['searchText'] as String? ?? '',
      state: state.contains('Completed')
          ? SoulseekSearchState.completed
          : SoulseekSearchState.inProgress,
      results: [
        for (final response in responses)
          _searchResultFromJson(response as Map<String, dynamic>),
      ],
    );
  }

  SoulseekSearchResult _searchResultFromJson(Map<String, dynamic> json) {
    final files = json['files'] as List<dynamic>? ?? const [];
    return SoulseekSearchResult(
      username: json['username'] as String,
      hasFreeUploadSlot: json['hasFreeUploadSlot'] as bool? ?? false,
      queueLength: (json['queueLength'] as num?)?.toInt() ?? 0,
      uploadSpeedBytesPerSecond: (json['uploadSpeed'] as num?)?.toInt() ?? 0,
      files: [
        for (final file in files) _fileFromJson(file as Map<String, dynamic>),
      ],
    );
  }

  SoulseekFile _fileFromJson(Map<String, dynamic> json) {
    return SoulseekFile(
      filename: json['filename'] as String,
      sizeBytes: (json['size'] as num).toInt(),
      bitRateKbps: (json['bitRate'] as num?)?.toInt(),
      durationSeconds: (json['length'] as num?)?.toInt(),
    );
  }

  SoulseekTransfer _transferFromJson(Map<String, dynamic> json) {
    return SoulseekTransfer(
      id: json['id'] as String,
      username: json['username'] as String,
      filename: json['filename'] as String,
      sizeBytes: (json['size'] as num).toInt(),
      bytesTransferred: (json['bytesTransferred'] as num?)?.toInt() ?? 0,
      state: _transferStateFromJson(json['state'] as String? ?? ''),
      placeInQueue: (json['placeInQueue'] as num?)?.toInt(),
    );
  }

  /// slskd's `TransferStates` is a C# `[Flags]` enum serialized as a
  /// comma-joined string of the set flags (e.g. `"Completed, Succeeded"`,
  /// `"Queued, Remotely"`). Collapsed here into the coarse categories the
  /// download queue UI needs, mirroring slskd's own
  /// `TransferStateCategories` groupings.
  SoulseekTransferState _transferStateFromJson(String raw) {
    final flags = raw.split(',').map((s) => s.trim()).toSet();
    if (flags.contains('Succeeded')) return SoulseekTransferState.succeeded;
    if (flags.any(
      const {
        'Cancelled',
        'TimedOut',
        'Errored',
        'Rejected',
        'Aborted',
      }.contains,
    )) {
      return SoulseekTransferState.failed;
    }
    // Bare "Completed" with neither Succeeded nor a failure flag set is a
    // state slskd's own code documents as "in case of some sort of a
    // malfunction or regression" — treat it as failed rather than queued.
    if (flags.contains('Completed')) return SoulseekTransferState.failed;
    if (flags.contains('InProgress') || flags.contains('Initializing')) {
      return SoulseekTransferState.inProgress;
    }
    return SoulseekTransferState.queued;
  }
}
