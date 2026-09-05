import 'package:dio/dio.dart';

/// The portable account this device is currently signed in as (server ADR
/// 0048/0050), as its own Musicat Server reports it.
///
/// Deliberately carries no password material of any kind: the password is
/// only ever sent once, to [AccountClient.signIn], and is never stored on
/// this device or by its server — after signing in, the device proves who
/// it is with the key it already had.
class MyAccount {
  const MyAccount({
    required this.accountId,
    required this.username,
    required this.loggedInAt,
  });

  /// Never shown to a human: it is a random identifier, not a name. Kept
  /// because it is what the friend-request entries below are keyed by.
  final String accountId;

  /// The name this account is known by — the one thing a friend needs to
  /// type to add this user, and (until now) the one thing the app could
  /// never show its own user.
  final String username;

  final DateTime loggedInAt;

  factory MyAccount.fromJson(Map<String, dynamic> json) => MyAccount(
    accountId: json['accountId'] as String,
    username: json['username'] as String,
    loggedInAt: DateTime.parse(json['loggedInAt'] as String),
  );
}

/// What [AccountClient.signIn] just did — the same call either creates the
/// account or signs an existing one in, so this is how the UI knows which
/// of the two it should say happened.
class SignInResult {
  const SignInResult({
    required this.accountId,
    required this.username,
    required this.created,
  });

  final String accountId;
  final String username;

  /// `true` when this username had no account yet and one was just created
  /// for it; `false` when it already existed and this device was linked to
  /// it (a second phone, a reinstall, a new desktop).
  final bool created;

  factory SignInResult.fromJson(Map<String, dynamic> json) => SignInResult(
    accountId: json['accountId'] as String,
    username: json['username'] as String,
    created: json['created'] as bool,
  );
}

/// One friend request addressed to this account.
class IncomingFriendRequest {
  const IncomingFriendRequest({
    required this.id,
    required this.status,
    this.fromUsername,
  });

  final String id;

  /// Who sent it. Nullable on the wire (the account service returns `null`
  /// if it can't resolve the sender's current username) — never rendered as
  /// a made-up name; see [fromLabel].
  final String? fromUsername;

  /// `pending`/`accepted`/`declined`.
  final String status;

  /// What to actually show for the sender. Falls back to a plainly
  /// unknown-sounding label rather than inventing a name or leaking the
  /// sender's raw account identifier into the UI.
  String get fromLabel => fromUsername ?? 'Someone';

  bool get isPending => status == 'pending';

  factory IncomingFriendRequest.fromJson(Map<String, dynamic> json) =>
      IncomingFriendRequest(
        id: json['id'] as String,
        fromUsername: json['fromUsername'] as String?,
        status: json['status'] as String,
      );
}

/// The answer to "what friend requests am I sitting on", *plus* how much
/// this device actually knows right now.
///
/// [live] and [fetchedAt] are the honest part and the reason this is a
/// class rather than a bare list: this device's server answers from a
/// cached snapshot when it couldn't refresh, and an empty list that was
/// never successfully fetched ([neverFetched]) is emphatically **not** the
/// same thing as "you have no friend requests". Showing the second when
/// you mean the first is how someone quietly misses a request forever.
class FriendRequestsSnapshot {
  const FriendRequestsSnapshot({
    required this.requests,
    required this.live,
    this.fetchedAt,
  });

  final List<IncomingFriendRequest> requests;

  /// When this device last managed a real fetch — `null` if it never has.
  final DateTime? fetchedAt;

  /// Whether [requests] came from a fetch that just succeeded, as opposed
  /// to a cached snapshot served because the fetch failed.
  final bool live;

  /// This device has never once managed to fetch: it genuinely has no idea
  /// whether there are friend requests waiting, and must not claim there
  /// are none.
  bool get neverFetched => !live && fetchedAt == null;

  /// Pending requests only — the ones there is anything to do about.
  List<IncomingFriendRequest> get pending => [
    for (final request in requests)
      if (request.isPending) request,
  ];

  /// A signed-out (or account-less) device: nothing known, nothing claimed.
  static const empty = FriendRequestsSnapshot(requests: [], live: false);

  factory FriendRequestsSnapshot.fromJson(Map<String, dynamic> json) =>
      FriendRequestsSnapshot(
        requests: [
          for (final entry in (json['requests'] as List<dynamic>? ?? const []))
            IncomingFriendRequest.fromJson(entry as Map<String, dynamic>),
        ],
        fetchedAt: json['fetchedAt'] == null
            ? null
            : DateTime.parse(json['fetchedAt'] as String),
        live: json['live'] as bool? ?? false,
      );
}

class AccountClientException implements Exception {
  const AccountClientException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => 'AccountClientException($statusCode, $message)';
}

/// Talks to *this device's own* Musicat Server about the portable account
/// it acts for, and about friend requests (server ADR 0048/0050/0051).
///
/// A sibling of [FederationClient], not part of it, for the same reason
/// `SharingClient` and `JointPlaylistClient` are their own classes: same
/// server, separate concern. This one is the only place in the app that
/// ever handles a password, which is worth being able to point at.
///
/// Every route it calls is app-facing and loopback-restricted server-side
/// (ADR 0044); [apiKey] exists only for the deliberately-remote
/// self-hosted case, exactly as in [FederationClient].
class AccountClient {
  AccountClient({required String baseUrl, Dio? dio, String? apiKey})
    : _dio = dio ?? Dio() {
    _dio.options.baseUrl = baseUrl;
    if (apiKey != null && apiKey.isNotEmpty) {
      _dio.options.headers['X-Api-Key'] = apiKey;
    }
  }

  final Dio _dio;

  /// Signs in as [username], **creating the account if that username is
  /// free** — one call, because the server has one endpoint: there is no
  /// separate sign-up. [SignInResult.created] says which of the two just
  /// happened.
  ///
  /// By the time this returns, this device's server has already synced the
  /// account's friends, so `GET /api/v1/federation/friends` is up to date.
  ///
  /// Throws [AccountClientException] with the status the UI needs to tell
  /// the cases apart: `401` wrong password, `429` too many attempts, `400`
  /// an unusable username, `502`/`503` accounts unavailable right now (in
  /// particular: *not* the user's fault).
  Future<SignInResult> signIn({
    required String username,
    required String password,
  }) async {
    final response = await _handle(
      () => _dio.post<Map<String, dynamic>>(
        '/api/v1/account/login',
        data: {'username': username, 'password': password},
      ),
    );
    return SignInResult.fromJson(response.data!);
  }

  /// Who this device is signed in as, or `null` if nobody. Answered by the
  /// server from its own disk, so it keeps working when nothing else about
  /// accounts does.
  Future<MyAccount?> currentAccount() async {
    final response = await _handle(
      () => _dio.get<Map<String, dynamic>>('/api/v1/account'),
    );
    final account = response.data?['account'];
    if (account == null) return null;
    return MyAccount.fromJson(account as Map<String, dynamic>);
  }

  /// Signs this device out. Idempotent, and deliberately leaves this
  /// device's friends exactly where they are — see the copy in
  /// `account_screen.dart`, which says so out loud.
  Future<void> signOut() async {
    await _handle(() => _dio.delete<void>('/api/v1/account'));
  }

  /// The friend requests addressed to this account, together with whether
  /// this is fresh information — see [FriendRequestsSnapshot].
  ///
  /// Throws [AccountClientException] `409` when this device isn't signed
  /// in, and `503` when it has no accounts available at all.
  Future<FriendRequestsSnapshot> listFriendRequests() async {
    final response = await _handle(
      () => _dio.get<Map<String, dynamic>>('/api/v1/account/friend-requests'),
    );
    return FriendRequestsSnapshot.fromJson(response.data!);
  }

  /// Asks [toUsername] to be friends. Throws [AccountClientException] with
  /// `404` for a username nobody is using and `400` for one that can't be
  /// asked (notably your own).
  Future<void> sendFriendRequest(String toUsername) async {
    await _handle(
      () => _dio.post<Map<String, dynamic>>(
        '/api/v1/account/friend-requests',
        data: {'toUsername': toUsername},
      ),
    );
  }

  /// Accepts [requestId]. When this returns, the new friend is *already*
  /// in `GET /api/v1/federation/friends` (the server syncs before it
  /// answers), so callers refresh the friends list rather than poll it.
  Future<void> acceptFriendRequest(String requestId) async {
    await _handle(
      () => _dio.post<Map<String, dynamic>>(
        '/api/v1/account/friend-requests/$requestId/accept',
      ),
    );
  }

  Future<void> declineFriendRequest(String requestId) async {
    await _handle(
      () => _dio.post<Map<String, dynamic>>(
        '/api/v1/account/friend-requests/$requestId/decline',
      ),
    );
  }

  Future<Response<T>> _handle<T>(Future<Response<T>> Function() request) async {
    try {
      return await request();
    } on DioException catch (e) {
      throw AccountClientException(
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
