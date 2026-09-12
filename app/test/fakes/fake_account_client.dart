import 'package:musicat/core/network/federation/account_client.dart';
import 'package:musicat/features/friends/presentation/musicat_server_config_controller.dart';

/// Hand-written in-memory fake standing in for [AccountClient] — same
/// "implements the real interface, log the calls, no mocking framework"
/// pattern as `FakeFederationClient`/`FakeSoulseekClient`.
///
/// Every failure the UI has to tell apart is driven by setting one of the
/// `*Error` fields to a real [AccountClientException], so the widget under
/// test walks the same code path a live 401/429/503 would put it on.
class FakeAccountClient implements AccountClient {
  FakeAccountClient({
    this.account,
    FriendRequestsSnapshot? requests,
    Set<String> existingUsernames = const {},
    List<AccountDevice> devices = const [],
    this.accountsAvailable = true,
  }) : requests =
           requests ?? const FriendRequestsSnapshot(requests: [], live: true),
       existingUsernames = {...existingUsernames},
       devices = [...devices];

  /// Who this fake is currently signed in as — `null` for signed out.
  MyAccount? account;

  /// What `GET /api/v1/account` reports alongside [account]: whether this
  /// node has an account service at all. `false` is a node with no relay,
  /// where signing in could never work — see server ADR 0056.
  bool accountsAvailable;

  /// The devices this fake's account service says are linked, in the order
  /// [listDevices] answers them.
  List<AccountDevice> devices;

  /// What [listFriendRequests] answers, honesty flags included.
  FriendRequestsSnapshot requests;

  /// Usernames this fake's service already has an account for. Everything
  /// else is unknown to it, which is what makes [signIn]'s
  /// `allowCreate: false` leg answer `404` — the real contract, and the
  /// only way a test can walk the "no account called that yet — create
  /// it?" path for real rather than by stubbing an exception.
  final Set<String> existingUsernames;

  Object? signInError;

  /// Thrown by the *create* leg only (`allowCreate: true`). The contract's
  /// too-short-password `400` can only ever happen there, and a test that
  /// used [signInError] for it would never get past the first, no-create
  /// call to reach the case it meant to exercise.
  Object? createError;

  Object? listError;
  Object? sendError;
  Object? respondError;
  Object? cancelError;
  Object? devicesError;
  Object? unlinkError;

  final List<({String username, String password, bool allowCreate})>
  signInCalls = [];
  final List<String> sentRequests = [];
  final List<({String id, bool accept})> respondCalls = [];
  final List<String> cancelledRequests = [];
  final List<String> unlinkedNodeIds = [];
  int signOutCalls = 0;
  int listCalls = 0;
  int deviceListCalls = 0;

  @override
  Future<SignInResult> signIn({
    required String username,
    required String password,
    bool allowCreate = true,
  }) async {
    signInCalls.add((
      username: username,
      password: password,
      allowCreate: allowCreate,
    ));
    final error = signInError;
    if (error != null) throw error;
    final exists = existingUsernames.contains(username);
    // The contract this round is built against: an unknown username with
    // `allowCreate: false` is a 404, not a brand-new account.
    if (!exists && !allowCreate) {
      throw const AccountClientException(404, 'No such account');
    }
    if (!exists) {
      final creationError = createError;
      if (creationError != null) throw creationError;
    }
    existingUsernames.add(username);
    account = MyAccount(
      accountId: 'account-$username',
      username: username,
      loggedInAt: DateTime.utc(2026, 9, 5),
    );
    return SignInResult(
      accountId: account!.accountId,
      username: username,
      created: !exists,
    );
  }

  @override
  Future<AccountStatus> accountStatus() async =>
      AccountStatus(account: account, accountsAvailable: accountsAvailable);

  @override
  Future<void> signOut() async {
    signOutCalls++;
    account = null;
  }

  @override
  Future<FriendRequestsSnapshot> listFriendRequests() async {
    listCalls++;
    final error = listError;
    if (error != null) throw error;
    return requests;
  }

  /// Sends, and — like the real service, whose next answer includes it —
  /// leaves it in [requests] as one this account is now waiting on. That is
  /// what makes "the request I just sent is visible somewhere" testable
  /// through the UI rather than by hand-editing a snapshot.
  @override
  Future<void> sendFriendRequest(String toUsername) async {
    sentRequests.add(toUsername);
    final error = sendError;
    if (error != null) throw error;
    requests = FriendRequestsSnapshot(
      requests: requests.requests,
      outgoing: [
        ...requests.outgoing,
        OutgoingFriendRequest(
          id: 'sent-${sentRequests.length}',
          toUsername: toUsername,
          status: 'pending',
          sentAt: DateTime.now(),
        ),
      ],
      fetchedAt: requests.fetchedAt ?? DateTime.utc(2026, 9, 5),
      live: true,
    );
  }

  @override
  Future<void> acceptFriendRequest(String requestId) =>
      _respond(requestId, accept: true);

  @override
  Future<void> declineFriendRequest(String requestId) =>
      _respond(requestId, accept: false);

  /// Answers a request the way the real server does: it is gone from the
  /// next [listFriendRequests], so a test can assert the UI stops showing
  /// it without hand-editing [requests].
  Future<void> _respond(String requestId, {required bool accept}) async {
    respondCalls.add((id: requestId, accept: accept));
    final error = respondError;
    if (error != null) throw error;
    requests = FriendRequestsSnapshot(
      requests: [
        for (final request in requests.requests)
          if (request.id != requestId) request,
      ],
      outgoing: requests.outgoing,
      fetchedAt: requests.fetchedAt ?? DateTime.utc(2026, 9, 5),
      live: true,
    );
  }

  /// Withdraws a sent request, and — like the real route, which refreshes
  /// before answering — drops it from the next [listFriendRequests] too.
  /// [cancelError] is how a test walks the `403`/`409` legs for real.
  @override
  Future<void> cancelFriendRequest(String requestId) async {
    cancelledRequests.add(requestId);
    final error = cancelError;
    if (error != null) throw error;
    requests = FriendRequestsSnapshot(
      requests: requests.requests,
      outgoing: [
        for (final request in requests.outgoing)
          if (request.id != requestId) request,
      ],
      fetchedAt: requests.fetchedAt ?? DateTime.utc(2026, 9, 5),
      live: true,
    );
  }

  @override
  Future<List<AccountDevice>> listDevices() async {
    deviceListCalls++;
    final error = devicesError;
    if (error != null) throw error;
    return devices;
  }

  /// Unlinks a device the way the real route does, *including* its return
  /// value: `true` only when the device unlinked is the one asking, which
  /// is also when the session goes. A test never has to compare node ids to
  /// know which happened, and neither does the app.
  @override
  Future<bool> unlinkDevice(String nodeId) async {
    unlinkedNodeIds.add(nodeId);
    final error = unlinkError;
    if (error != null) throw error;
    final unlinked = devices.where((d) => d.nodeId == nodeId).toList();
    devices = [
      for (final device in devices)
        if (device.nodeId != nodeId) device,
    ];
    final signedOut = unlinked.any((device) => device.isThisDevice);
    if (signedOut) {
      account = null;
      requests = FriendRequestsSnapshot.empty;
    }
    return signedOut;
  }
}

/// Puts a test's Friends UI in the "this device never signed in, and no
/// network call is made to find that out" state.
///
/// Every test written before accounts existed assumed exactly this; the
/// assumption only became something to state once the Friends screen
/// started asking its own server who it is. Without it, the real
/// [AccountClient] runs against `flutter_test`'s stub HTTP client and
/// leaves a dio timer pending at the end of the test.
/// Typed by inference: `Override` itself is not part of
/// `flutter_riverpod`'s public export surface in this version.
final signedOutAccountOverride = accountClientProvider.overrideWithValue(null);
