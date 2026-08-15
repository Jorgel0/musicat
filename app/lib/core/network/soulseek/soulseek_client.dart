/// A single file offered by a peer in a search response.
class SoulseekFile {
  const SoulseekFile({
    required this.filename,
    required this.sizeBytes,
    this.bitRateKbps,
    this.durationSeconds,
  });

  /// The full remote path as the peer reports it (e.g.
  /// `@@aaaa\Music\Album\01 Track.flac`) — required as-is to enqueue a
  /// download for this file.
  final String filename;
  final int sizeBytes;
  final int? bitRateKbps;
  final int? durationSeconds;
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
}

/// Coarse transfer state, collapsed from slskd's flag-combination strings
/// (e.g. `"Completed, Succeeded"`, `"Queued, Remotely"`) into the
/// categories the download-queue UI actually needs to distinguish.
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
}

/// Thrown for any error response the backend returns. [statusCode] is the
/// HTTP status; [message] is the backend's own error text where available.
class SoulseekClientException implements Exception {
  const SoulseekClientException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => 'SoulseekClientException($statusCode, $message)';
}

/// Thrown when the backend is reachable but not currently logged into the
/// Soulseek network — a 409 from slskd. Distinct from
/// [SoulseekClientException] so callers can show "reconnecting..." instead
/// of a generic error.
class SoulseekNotConnectedException extends SoulseekClientException {
  const SoulseekNotConnectedException(String message) : super(409, message);
}

/// Thrown when a download is requested from a user who is offline (or
/// blacklisted server-side) — a 404 from slskd's download-enqueue endpoint.
class SoulseekUserOfflineException extends SoulseekClientException {
  const SoulseekUserOfflineException(this.username, String message)
    : super(404, message);

  final String username;
}

/// Talks to a Soulseek backend on behalf of the app. Deliberately
/// Future-based rather than stream-based: the only implementation today
/// (`slskd`) has no push/streaming REST endpoint, so "live" search/download
/// progress is built by polling these methods from the presentation layer,
/// not by the client pretending to be reactive. See ADR 0004 for why this
/// sits behind an interface, and ADR 0010 for the slskd-specific choices
/// (polling, error mapping, why not the deprecated single-file endpoint).
abstract class SoulseekClient {
  /// Whether the backend is reachable *and* logged into the Soulseek
  /// network. Used both for a Settings "test connection" action and to
  /// decide whether to bother attempting a search.
  Future<bool> isConnected();

  /// Starts a new search and returns its id immediately — the id is
  /// generated client-side rather than waited for, because slskd's own
  /// search endpoint doesn't return until the search completes (or times
  /// out, ~15s by default). The search record exists (and accumulates
  /// results) server-side well before that response arrives, so callers
  /// should start polling [getSearch] with the returned id right away
  /// rather than waiting on this future. See ADR 0010.
  ///
  /// slskd only allows one search in flight server-wide; a second call
  /// while one is running throws [SoulseekClientException] with a 429
  /// status.
  Future<String> startSearch(String query);

  /// Polls a search's current state and the results gathered so far —
  /// safe to call while the search is still in progress.
  Future<SoulseekSearch> getSearch(String searchId);

  Future<void> cancelSearch(String searchId);

  /// Enqueues a batch download of [files] from [username]. Throws
  /// [SoulseekUserOfflineException] if the peer isn't reachable.
  Future<void> enqueueDownload({
    required String username,
    required List<SoulseekFile> files,
  });

  Future<List<SoulseekTransfer>> getDownloads();

  Future<void> cancelDownload({
    required String username,
    required String transferId,
  });

  /// The directory this backend saves completed downloads to, as it
  /// reports it — only actually useful when the backend runs on this same
  /// device (see ADR 0013); otherwise it's a path on a different machine.
  /// Returns `null` if it can't be determined.
  Future<String?> getDownloadsDirectory();
}
