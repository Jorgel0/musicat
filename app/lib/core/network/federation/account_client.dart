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

/// One device linked to this account, as `GET /api/v1/account/devices`
/// reports it (server ADR 0048/0056).
///
/// Fetched live every time and never cached anywhere in the app, on
/// purpose: this list is what someone decides *what to revoke* from, and a
/// stale one is a worse answer than no answer. The server takes the same
/// position and fails rather than serving an old copy.
class AccountDevice {
  const AccountDevice({
    required this.nodeId,
    required this.linkedAt,
    required this.isThisDevice,
    this.deviceName,
    this.lastLoginAt,
  });

  /// Needed to unlink this device and for nothing else. **Never rendered**:
  /// a 64-character hex fingerprint is not something a person can recognise
  /// a phone by, and showing one would be internal plumbing on screen.
  final String nodeId;

  /// When this device was linked to the account.
  final DateTime linkedAt;

  /// When this device last signed in, or `null` from a server too old to
  /// say (and from a device row written before the field existed).
  ///
  /// This is what actually makes the list decidable. Two Linux desktops
  /// linked the same afternoon both read "Linux · Added today", and the one
  /// job this screen has is "pick the phone you lost and revoke it" — which
  /// needs "used a minute ago" versus "not since June", not the date they
  /// were both added.
  ///
  /// The account service sends it only to the account itself, never to a
  /// friend, so nothing here leaks a last-seen signal to anyone else.
  final DateTime? lastLoginAt;

  /// The platform this device reported for itself at its last sign-in
  /// (`Android`, `Linux`, ...), or `null` from a device that never sent one.
  /// It is **not** a name anybody chose, and nothing here invents one — see
  /// [label], which degrades to a plainly unknown-sounding phrase rather
  /// than falling back to [nodeId].
  final String? deviceName;

  /// Whether this row is the device the app is running on — computed by
  /// this device's own server, which is the only thing that can know it.
  /// Defaults to `false` for a server too old to say, which costs the "This
  /// device" marker but never mislabels another device as this one.
  final bool isThisDevice;

  /// What to show for this device. Deliberately not the [nodeId], and
  /// deliberately not a made-up name.
  String get label => deviceName ?? 'Unknown device';

  factory AccountDevice.fromJson(Map<String, dynamic> json) => AccountDevice(
    nodeId: json['nodeId'] as String,
    linkedAt: DateTime.parse(json['linkedAt'] as String),
    deviceName: json['deviceName'] as String?,
    isThisDevice: json['isThisDevice'] as bool? ?? false,
    lastLoginAt: json['lastLoginAt'] == null
        ? null
        : DateTime.parse(json['lastLoginAt'] as String),
  );
}

/// What `GET /api/v1/account` says: who this device is signed in as, *and*
/// whether signing in is possible here at all.
///
/// The second half is the capability signal ADR 0053 left open. Until it
/// existed, `{"account": null}` meant both "you are signed out" and "this
/// build has no relay, so there is nothing to sign in to", and the app had
/// to guess between offering a form and explaining why there is none —
/// letting the user find out through a sign-in that could only ever fail.
class AccountStatus {
  const AccountStatus({required this.accountsAvailable, this.account});

  /// Who this device acts for, or `null` when nobody.
  final MyAccount? account;

  /// Whether this device's server has an account service to talk to at all.
  /// `false` is a fact about configuration, not about the network: it never
  /// means "temporarily unreachable" (the calls that can be report that
  /// themselves).
  final bool accountsAvailable;

  /// The same device with nobody signed in — what a sign-out leaves behind.
  /// Keeps [accountsAvailable], which a sign-out cannot change.
  AccountStatus signedOut() =>
      AccountStatus(accountsAvailable: accountsAvailable);

  factory AccountStatus.fromJson(Map<String, dynamic> json) {
    final account = json['account'];
    return AccountStatus(
      account: account == null
          ? null
          : MyAccount.fromJson(account as Map<String, dynamic>),
      // Absent only from a node older than this field. Such a node either
      // has an account service or does not, and the app cannot tell which
      // — assuming it does keeps its behaviour exactly as it was before
      // the flag existed, rather than newly telling those users that
      // accounts are unavailable when they may not be.
      accountsAvailable: json['accountsAvailable'] as bool? ?? true,
    );
  }
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

/// One friend request *this* account sent and is still waiting on.
///
/// A separate type from [IncomingFriendRequest] rather than one class with
/// both usernames nullable: the two are answered differently (one is
/// accept/decline, the other is "wait, or take it back") and the person
/// named on each is a different person. Keeping them apart makes it
/// impossible to render one as the other.
class OutgoingFriendRequest {
  const OutgoingFriendRequest({
    required this.id,
    required this.status,
    this.toUsername,
    this.sentAt,
  });

  final String id;

  /// Who it was sent to. Nullable on the wire for the same reason
  /// [IncomingFriendRequest.fromUsername] is — see [toLabel].
  final String? toUsername;

  /// `pending`/`accepted`/`declined`/`cancelled`. Parsed as a plain string
  /// so a status this build has never heard of is simply "not pending"
  /// rather than a crash.
  final String status;

  /// When it was sent, if the service said. Shown because "sent three days
  /// ago" is most of what tells "they have not got round to it" apart from
  /// "this never arrived".
  final DateTime? sentAt;

  /// What to actually show for the recipient — never a made-up name, and
  /// never their raw account identifier.
  String get toLabel => toUsername ?? 'Someone';

  bool get isPending => status == 'pending';

  factory OutgoingFriendRequest.fromJson(Map<String, dynamic> json) =>
      OutgoingFriendRequest(
        id: json['id'] as String,
        toUsername: json['toUsername'] as String?,
        status: json['status'] as String,
        sentAt: json['createdAt'] == null
            ? null
            : DateTime.parse(json['createdAt'] as String),
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
    this.outgoing = const [],
    this.fetchedAt,
  });

  final List<IncomingFriendRequest> requests;

  /// The ones this account *sent* and is still waiting on. They come from
  /// the same single fetch as [requests], which is why one [live]/
  /// [fetchedAt] pair honestly describes both: a screen showing "they are
  /// waiting on you" beside "you are waiting on them" is never mixing two
  /// different moments.
  ///
  /// Empty from a server too old to send the key at all, which is
  /// indistinguishable from genuinely having sent nobody a request. That is
  /// the same degradation the server documents, and it is safe here: an
  /// empty list only ever hides a "waiting for an answer" row, it never
  /// claims anything.
  final List<OutgoingFriendRequest> outgoing;

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

  /// Requests still waiting on the other person — the ones there is
  /// anything to say about, or to take back.
  List<OutgoingFriendRequest> get pendingOutgoing => [
    for (final request in outgoing)
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
        outgoing: [
          for (final entry in (json['outgoing'] as List<dynamic>? ?? const []))
            OutgoingFriendRequest.fromJson(entry as Map<String, dynamic>),
        ],
        fetchedAt: json['fetchedAt'] == null
            ? null
            : DateTime.parse(json['fetchedAt'] as String),
        live: json['live'] as bool? ?? false,
      );
}

class AccountClientException implements Exception {
  const AccountClientException(this.statusCode, this.message, {this.code});

  final int statusCode;
  final String message;

  /// The server's machine-readable reason, when it sent one (e.g.
  /// `password_too_short`, `ambiguous_username`) — `null` for an older
  /// node, or for anything that never reached the server at all.
  ///
  /// Branch on this, show [message]. The status alone is not enough: a
  /// `400` is both "that username has characters we don't allow" and
  /// "that password is too short to create an account with", and the two
  /// need different help. Reading [message] to tell them apart works
  /// until somebody rewords a sentence.
  final String? code;

  @override
  String toString() =>
      'AccountClientException($statusCode, $message, code: $code)';
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

  /// Signs in as [username] — one call, because the server has one
  /// endpoint: there is no separate sign-up. [SignInResult.created] says
  /// which of the two just happened.
  ///
  /// [allowCreate] is what keeps a typo from quietly becoming a second,
  /// empty account. With it `false`, an unknown username answers `404`
  /// instead of creating anything, which is how the sign-in screen gets to
  /// ask "no account called this yet — create it?" before anything exists.
  /// Sent explicitly either way rather than relying on the route's own
  /// default (`true`), so what this call means is readable at the call
  /// site.
  ///
  /// By the time this returns, this device's server has already synced the
  /// account's friends, so `GET /api/v1/federation/friends` is up to date.
  ///
  /// Throws [AccountClientException] with the status the UI needs to tell
  /// the cases apart: `401` wrong password, `404` no such account (only
  /// possible with [allowCreate] `false`), `429` too many attempts, `400`
  /// a username the service will not accept *or* a password too short to
  /// create an account with, `502`/`503` accounts unavailable right now
  /// (in particular: *not* the user's fault).
  Future<SignInResult> signIn({
    required String username,
    required String password,
    bool allowCreate = true,
  }) async {
    final response = await _handle(
      () => _dio.post<Map<String, dynamic>>(
        '/api/v1/account/login',
        data: {
          'username': username,
          'password': password,
          'allowCreate': allowCreate,
        },
      ),
    );
    return SignInResult.fromJson(response.data!);
  }

  /// Who this device is signed in as, and whether it could sign in to
  /// anything at all — see [AccountStatus]. Answered by the server from its
  /// own disk and its own configuration, with no network call of its own,
  /// so it keeps working when nothing else about accounts does.
  Future<AccountStatus> accountStatus() async {
    final response = await _handle(
      () => _dio.get<Map<String, dynamic>>('/api/v1/account'),
    );
    return AccountStatus.fromJson(response.data!);
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

  /// Takes back a request *this* account sent, while it is still waiting.
  ///
  /// **Not the same thing as unfriending**, and the UI must not read like
  /// it: nobody is friends yet, nothing is removed, and no record is kept
  /// that would stop the two of them becoming friends later. Ending an
  /// actual friendship is [FederationClient.removeFriend], a different
  /// action with its own confirmation.
  ///
  /// Throws [AccountClientException] `403` if this account did not send it
  /// and `409` once the other person has already answered — at which point
  /// there is nothing to take back, and if they said yes, they are a
  /// friend.
  Future<void> cancelFriendRequest(String requestId) async {
    await _handle(
      () => _dio.post<Map<String, dynamic>>(
        '/api/v1/account/friend-requests/$requestId/cancel',
      ),
    );
  }

  /// Every device linked to this account, this one included (server ADR
  /// 0056).
  ///
  /// Always a live fetch — the server caches nothing here and neither does
  /// the app. A device list is what somebody decides what to revoke from,
  /// and a stale one is a worse answer than an honest failure.
  ///
  /// Throws [AccountClientException] `409` when this device isn't signed
  /// in, `503` when accounts are unavailable or the service could not be
  /// reached, and `502` when it answered with something unusable.
  Future<List<AccountDevice>> listDevices() async {
    final response = await _handle(
      () => _dio.get<Map<String, dynamic>>('/api/v1/account/devices'),
    );
    return [
      for (final entry
          in (response.data?['devices'] as List<dynamic>? ?? const []))
        AccountDevice.fromJson(entry as Map<String, dynamic>),
    ];
  }

  /// Unlinks [nodeId] from this account: it stops being able to act as the
  /// account. The recovery path for a lost or stolen device.
  ///
  /// Returns whether *this* device is the one that was unlinked, in which
  /// case the server has already cleared the local session and this device
  /// is now signed out (friends untouched, exactly as an ordinary sign-out
  /// leaves them). Read from the response rather than compared against a
  /// nodeId here on purpose: the server says which of the two happened, so
  /// nothing in the app has to infer it.
  ///
  /// The unlinked device is **not** told; it finds out when its next call
  /// as this account fails.
  Future<bool> unlinkDevice(String nodeId) async {
    final response = await _handle(
      () => _dio.delete<Map<String, dynamic>>(
        '/api/v1/account/devices/${Uri.encodeComponent(nodeId)}',
      ),
    );
    return response.data?['signedOut'] as bool? ?? false;
  }

  Future<Response<T>> _handle<T>(Future<Response<T>> Function() request) async {
    try {
      return await request();
    } on DioException catch (e) {
      throw AccountClientException(
        e.response?.statusCode ?? 0,
        _errorMessage(e),
        code: _errorCode(e),
      );
    }
  }

  String _errorMessage(DioException e) {
    final data = e.response?.data;
    if (data is Map && data['error'] is String) return data['error'] as String;
    if (data is String) return data;
    return e.message ?? 'Unknown error';
  }

  /// The `code` field the node sends beside `error`. Absent on an older
  /// node, so every caller has to cope with `null` rather than assume it.
  String? _errorCode(DioException e) {
    final data = e.response?.data;
    if (data is Map && data['code'] is String) return data['code'] as String;
    return null;
  }
}
