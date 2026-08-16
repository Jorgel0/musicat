import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'slskd_config.dart';
import 'soulseek_models.dart';

/// [SoulseekGateway] backed by a self-hosted `slskd` instance's REST API.
///
/// Ported from the app's `SlskdSoulseekClient` (ADR 0010) — same API
/// research and polling design, just fronting slskd on the server's behalf
/// instead of the app's. See ADR 0016 for why this logic now lives here.
class SlskdGateway implements SoulseekGateway {
  SlskdGateway({required this.config, http.Client? httpClient})
    : _http = httpClient ?? http.Client();

  final SlskdConfig config;
  final http.Client _http;
  static const _uuid = Uuid();

  Map<String, String> get _headers => {'X-API-Key': config.apiKey};

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('${config.baseUrl}$path').replace(queryParameters: query);

  @override
  Future<bool> isConnected() async {
    final response = await _send(
      () => _http.get(_uri('/api/v0/server'), headers: _headers),
    );
    if (response.statusCode != 200) {
      throw SoulseekGatewayException(
        response.statusCode,
        _errorMessage(response),
      );
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return json['isLoggedIn'] == true;
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
    // response, return the id immediately and let callers poll getSearch.
    unawaited(_fireSearch(id, query));
    return id;
  }

  Future<void> _fireSearch(String id, String query) async {
    try {
      await _http.post(
        _uri('/api/v0/searches'),
        headers: {..._headers, 'content-type': 'application/json'},
        body: jsonEncode({'id': id, 'searchText': query}),
      );
    } catch (_) {
      // Swallowed — nothing awaits this, so there's no caller left to throw
      // to; a failure here just means the search never appears to a poller.
    }
  }

  @override
  Future<SoulseekSearch> getSearch(String searchId) async {
    final response = await _send(
      () => _http.get(
        _uri('/api/v0/searches/$searchId', {'includeResponses': 'true'}),
        headers: _headers,
      ),
    );
    if (response.statusCode != 200) {
      throw SoulseekGatewayException(
        response.statusCode,
        _errorMessage(response),
      );
    }
    return _searchFromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  @override
  Future<void> cancelSearch(String searchId) async {
    final response = await _send(
      () => _http.put(_uri('/api/v0/searches/$searchId'), headers: _headers),
    );
    // 200: stopped. 304: had already finished. Both are a normal "not
    // running anymore" outcome, not an error.
    if (response.statusCode != 200 && response.statusCode != 304) {
      throw SoulseekGatewayException(
        response.statusCode,
        _errorMessage(response),
      );
    }
  }

  @override
  Future<void> enqueueDownload({
    required String username,
    required List<SoulseekFile> files,
  }) async {
    final response = await _send(
      () => _http.post(
        _uri('/api/v0/transfers/downloads/batches'),
        headers: {..._headers, 'content-type': 'application/json'},
        body: jsonEncode({
          'username': username,
          'files': [
            for (final file in files)
              {'filename': file.filename, 'size': file.sizeBytes},
          ],
        }),
      ),
    );

    if (response.statusCode == 404) {
      throw SoulseekUserOfflineException(username, _errorMessage(response));
    }
    // 200/201: enqueued. 207: partial failure, at least one file enqueued —
    // treated as success for v1, same as the app's client.
    if (![200, 201, 207].contains(response.statusCode)) {
      throw SoulseekGatewayException(
        response.statusCode,
        _errorMessage(response),
      );
    }

    final body = jsonDecode(response.body);
    final failures =
        (body is Map<String, dynamic>
            ? body['failures'] as List<dynamic>?
            : null) ??
        const [];
    if (failures.isNotEmpty && failures.length == files.length) {
      // Status 200 but every file failed to enqueue — surface as an error
      // rather than a silent no-op.
      final messages = failures
          .map((f) => (f as Map<String, dynamic>)['message'])
          .join('; ');
      throw SoulseekGatewayException(response.statusCode, messages);
    }
  }

  @override
  Future<List<SoulseekTransfer>> getDownloads() async {
    final response = await _send(
      () => _http.get(_uri('/api/v0/transfers/downloads'), headers: _headers),
    );
    if (response.statusCode != 200) {
      throw SoulseekGatewayException(
        response.statusCode,
        _errorMessage(response),
      );
    }

    // slskd groups by username, then by directory: [{username, directories:
    // [{directory, fileCount, files: [Transfer...]}]}] — flatten to a
    // single list, which is all the app's download-queue UI needs.
    final userEntries = jsonDecode(response.body) as List<dynamic>;
    final transfers = <SoulseekTransfer>[];
    for (final userEntry in userEntries) {
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
    final response = await _send(
      () => _http.delete(
        _uri('/api/v0/transfers/downloads/$username/$transferId'),
        headers: _headers,
      ),
    );
    if (response.statusCode != 200 && response.statusCode != 204) {
      throw SoulseekGatewayException(
        response.statusCode,
        _errorMessage(response),
      );
    }
  }

  @override
  Future<String?> getDownloadsDirectory() async {
    try {
      final response = await _http.get(
        _uri('/api/v0/options'),
        headers: _headers,
      );
      if (response.statusCode != 200) return null;
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final directories = json['directories'] as Map<String, dynamic>?;
      return directories?['downloads'] as String?;
    } catch (_) {
      return null;
    }
  }

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request();
    } catch (e) {
      throw SoulseekGatewayException(0, e.toString());
    }
  }

  String _errorMessage(http.Response response) {
    try {
      final data = jsonDecode(response.body);
      if (data is String) return data;
      if (data is Map && data['message'] is String) {
        return data['message'] as String;
      }
    } catch (_) {
      // Not JSON — fall through to the raw body.
    }
    return response.body;
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
  /// app needs, mirroring slskd's own `TransferStateCategories` groupings.
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
