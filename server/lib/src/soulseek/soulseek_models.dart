/// Domain types Musicat Server exposes for Soulseek search/downloads.
///
/// These deliberately mirror the app's own `SoulseekClient` domain types
/// (see `app/lib/core/network/soulseek/soulseek_client.dart`, ADR 0004): the
/// app's future `MusicatServerSoulseekClient` should be able to decode this
/// server's JSON with nearly the same field names it already knows, since
/// the slskd-quirk handling (flag parsing, tree flattening) now happens
/// once, here, instead of once per client. See ADR 0016.
library;

/// A single file offered by a peer in a search response.
class SoulseekFile {
  const SoulseekFile({
    required this.filename,
    required this.sizeBytes,
    this.bitRateKbps,
    this.durationSeconds,
  });

  final String filename;
  final int sizeBytes;
  final int? bitRateKbps;
  final int? durationSeconds;

  Map<String, Object?> toJson() => {
    'filename': filename,
    'sizeBytes': sizeBytes,
    'bitRateKbps': bitRateKbps,
    'durationSeconds': durationSeconds,
  };

  /// Parses a file entry as submitted by a client requesting a download —
  /// only `filename`/`sizeBytes` are needed to enqueue one.
  factory SoulseekFile.fromRequestJson(Map<String, dynamic> json) =>
      SoulseekFile(
        filename: json['filename'] as String,
        sizeBytes: (json['sizeBytes'] as num).toInt(),
      );
}

/// One peer's response to a search: the files they have matching the query.
class SoulseekSearchResult {
  const SoulseekSearchResult({
    required this.username,
    required this.hasFreeUploadSlot,
    required this.queueLength,
    required this.uploadSpeedBytesPerSecond,
    required this.files,
  });

  final String username;
  final bool hasFreeUploadSlot;
  final int queueLength;
  final int uploadSpeedBytesPerSecond;
  final List<SoulseekFile> files;

  Map<String, Object?> toJson() => {
    'username': username,
    'hasFreeUploadSlot': hasFreeUploadSlot,
    'queueLength': queueLength,
    'uploadSpeedBytesPerSecond': uploadSpeedBytesPerSecond,
    'files': [for (final file in files) file.toJson()],
  };
}

enum SoulseekSearchState { inProgress, completed }

class SoulseekSearch {
  const SoulseekSearch({
    required this.id,
    required this.query,
    required this.state,
    required this.results,
  });

  final String id;
  final String query;
  final SoulseekSearchState state;
  final List<SoulseekSearchResult> results;

  Map<String, Object?> toJson() => {
    'id': id,
    'query': query,
    'state': state.name,
    'results': [for (final result in results) result.toJson()],
  };
}

/// Coarse transfer state, already collapsed from slskd's flag-combination
/// strings (e.g. `"Completed, Succeeded"`, `"Queued, Remotely"`) — see
/// `SlskdGateway._transferStateFromJson`.
enum SoulseekTransferState { queued, inProgress, succeeded, failed, cancelled }

class SoulseekTransfer {
  const SoulseekTransfer({
    required this.id,
    required this.username,
    required this.filename,
    required this.sizeBytes,
    required this.bytesTransferred,
    required this.state,
    this.placeInQueue,
  });

  final String id;
  final String username;
  final String filename;
  final int sizeBytes;
  final int bytesTransferred;
  final SoulseekTransferState state;
  final int? placeInQueue;

  Map<String, Object?> toJson() => {
    'id': id,
    'username': username,
    'filename': filename,
    'sizeBytes': sizeBytes,
    'bytesTransferred': bytesTransferred,
    'state': state.name,
    'placeInQueue': placeInQueue,
  };
}

/// Thrown for any error the upstream slskd instance returns. [statusCode] is
/// the HTTP status where meaningful; [message] is slskd's own error text
/// where available.
class SoulseekGatewayException implements Exception {
  const SoulseekGatewayException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => 'SoulseekGatewayException($statusCode, $message)';
}

/// slskd is reachable but not currently logged into the Soulseek network.
class SoulseekNotConnectedException extends SoulseekGatewayException {
  const SoulseekNotConnectedException(String message) : super(409, message);
}

/// A download was requested from a user who is offline (or blacklisted
/// server-side).
class SoulseekUserOfflineException extends SoulseekGatewayException {
  const SoulseekUserOfflineException(this.username, String message)
    : super(404, message);

  final String username;
}

/// What Musicat Server needs from a Soulseek backend to serve its own
/// `/api/v1/soulseek/*` routes. `SlskdGateway` is the only implementation
/// today, but keeping this as an interface mirrors the app's own
/// `SoulseekClient` abstraction (ADR 0004) and keeps the route handlers
/// testable against a fake.
abstract class SoulseekGateway {
  Future<bool> isConnected();
  Future<String> startSearch(String query);
  Future<SoulseekSearch> getSearch(String searchId);
  Future<void> cancelSearch(String searchId);
  Future<void> enqueueDownload({
    required String username,
    required List<SoulseekFile> files,
  });
  Future<List<SoulseekTransfer>> getDownloads();
  Future<void> cancelDownload({
    required String username,
    required String transferId,
  });
  Future<String?> getDownloadsDirectory();
}
