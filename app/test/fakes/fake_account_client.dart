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
    this.createdOnSignIn = false,
  }) : requests =
           requests ?? const FriendRequestsSnapshot(requests: [], live: true);

  /// Who this fake is currently signed in as — `null` for signed out.
  MyAccount? account;

  /// What [listFriendRequests] answers, honesty flags included.
  FriendRequestsSnapshot requests;

  /// Whether a successful [signIn] reports having *created* the account
  /// rather than linked this device to an existing one.
  bool createdOnSignIn;

  Object? signInError;
  Object? listError;
  Object? sendError;
  Object? respondError;

  final List<({String username, String password})> signInCalls = [];
  final List<String> sentRequests = [];
  final List<({String id, bool accept})> respondCalls = [];
  int signOutCalls = 0;
  int listCalls = 0;

  @override
  Future<SignInResult> signIn({
    required String username,
    required String password,
  }) async {
    signInCalls.add((username: username, password: password));
    final error = signInError;
    if (error != null) throw error;
    account = MyAccount(
      accountId: 'account-$username',
      username: username,
      loggedInAt: DateTime.utc(2026, 9, 5),
    );
    return SignInResult(
      accountId: account!.accountId,
      username: username,
      created: createdOnSignIn,
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
