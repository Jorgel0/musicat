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
  }) : requests =
           requests ?? const FriendRequestsSnapshot(requests: [], live: true),
       existingUsernames = {...existingUsernames};

  /// Who this fake is currently signed in as — `null` for signed out.
  MyAccount? account;

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

  final List<({String username, String password, bool allowCreate})>
  signInCalls = [];
  final List<String> sentRequests = [];
  final List<({String id, bool accept})> respondCalls = [];
  int signOutCalls = 0;
  int listCalls = 0;

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
  Future<MyAccount?> currentAccount() async => account;

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

  @override
  Future<void> sendFriendRequest(String toUsername) async {
    sentRequests.add(toUsername);
    final error = sendError;
    if (error != null) throw error;
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
      fetchedAt: requests.fetchedAt ?? DateTime.utc(2026, 9, 5),
      live: true,
    );
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
