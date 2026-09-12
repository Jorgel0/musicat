import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/federation/account_client.dart';
import 'friends_controller.dart';
import 'musicat_server_config_controller.dart';

/// Who this device is signed in as (server ADR 0050) — and whether it has
/// anywhere to sign in to at all — plus the two actions that change that.
///
/// An [AsyncNotifier] whose `build()` *is* the load, rather than a
/// [Notifier] that kicks a fetch off on the side: writing to a provider
/// from a widget lifecycle callback is the bug class this project has
/// already shipped twice (ADR 0037/0039), and letting Riverpod own the
/// asynchrony is the version of that fix with nothing left to get wrong.
/// Nothing here ever writes to another provider's state during a build.
///
/// A failed load stays a failure (`AsyncError`) instead of collapsing to
/// "signed out": those are different facts, and this device's server
/// answers "who am I" from its own disk, so a failure here means something
/// is wrong locally rather than that nobody is signed in.
class AccountSessionController extends AsyncNotifier<AccountStatus> {
  @override
  Future<AccountStatus> build() async {
    final client = ref.watch(accountClientProvider);
    // No server to ask yet: this device is still starting its own one, or
    // has none at all. Fall back to what configuration alone can say about
    // whether accounts are possible here — the pre-ADR-0056 guess, now
    // reduced to just this window instead of being the only answer the app
    // ever had. As soon as there is a server, its own
    // `accountsAvailable` replaces it, and that one also covers the
    // separately self-hosted case this guess deliberately abstains on.
    if (client == null) {
      return AccountStatus(
        accountsAvailable: !ref.watch(accountsHaveNoServerProvider),
      );
    }
    return client.accountStatus();
  }

  /// Signs in as [username] — one call, one flow (see
  /// [AccountClient.signIn]). Returns what actually happened so the caller
  /// can say "account created" or "signed in" truthfully.
  ///
  /// [allowCreate] is passed straight through: the sign-in screen asks
  /// with `false` first and only retries with `true` once the user has
  /// confirmed they meant to create a new account, so a mistyped username
  /// can no longer become one by accident.
  ///
  /// Lets [AccountClientException] out deliberately: the sign-in screen
  /// needs the status code to tell a wrong password from a lockout from
  /// "no account by that name" from "accounts aren't reachable right now",
  /// and swallowing it here would leave it nothing to tell them apart
  /// with.
  Future<SignInResult> signIn({
    required String username,
    required String password,
    bool allowCreate = true,
  }) async {
    final client = ref.read(accountClientProvider);
    if (client == null) {
      throw const AccountClientException(0, 'Musicat Server not configured');
    }
    final result = await client.signIn(
      username: username,
      password: password,
      allowCreate: allowCreate,
    );
    // Re-read rather than synthesise a session from `result`: the server
    // is the thing that persisted it, and its answer includes `loggedInAt`.
    state = AsyncData(await client.accountStatus());
    // The server already synced this account's friends before answering
    // (server ADR 0050), so the list is stale in the app, not on disk —
    // invalidate rather than refresh so this costs nothing when the
    // friends list isn't even on screen.
    ref.invalidate(friendsControllerProvider);
    return result;
  }

  /// Signs this device out. **Friends are deliberately left alone** — the
  /// server keeps them (server ADR 0050) and so does this: signing out is
  /// not unfriending, and the screen says so before you tap it.
  Future<void> signOut() async {
    final client = ref.read(accountClientProvider);
    if (client == null) return;
    await client.signOut();
    // Only the account goes; whether accounts are available here is a fact
    // about this device's configuration, and signing out cannot change it.
    state = AsyncData(
      state.value?.signedOut() ?? const AccountStatus(accountsAvailable: true),
    );
  }

  /// Re-reads who this device is signed in as, after something outside this
  /// controller ended the session — notably unlinking this very device from
  /// its account (see `account_devices_controller.dart`), which the server
  /// signs this node out of as part of the same call.
  void reload() => ref.invalidateSelf();
}

/// Just "who is signed in on this device", which is what most of the UI
/// actually asks. `null` while loading, on a failure, and when signed out —
/// each of which the screens that care about the difference read from
/// [accountSessionProvider] itself.
final signedInAccountProvider = Provider<MyAccount?>(
  (ref) => ref.watch(accountSessionProvider).value?.account,
);

final accountSessionProvider =
    AsyncNotifierProvider<AccountSessionController, AccountStatus>(
      AccountSessionController.new,
      // No hidden retry loop behind a failure. Riverpod's default is to
      // re-run a failed provider on a backoff timer; here that would mean
      // an invisible stream of calls to this device's server whenever it
      // is down, and a screen that silently flips state on its own. The
      // failure is shown, and retrying is something the user asks for.
      retry: (retryCount, error) => null,
    );

/// The friend requests waiting for an answer, and the actions that answer
/// them.
///
/// Deliberately **not** `autoDispose` and deliberately without a poll
/// timer. Not autoDispose because the nav bar's own unanswered-request
/// badge (`AppShell`) has to survive leaving the Friends screen — a
/// request nobody notices is the same as no feature at all. No timer
/// because every read of this hits the account service through this
/// device's server, and this device's *server* already polls on its own
/// schedule (server ADR 0051); the app refreshes at the moments a person
/// could act on it instead — app start, opening Friends, pull-to-refresh,
/// and after every answer.
class FriendRequestsController extends AsyncNotifier<FriendRequestsSnapshot> {
  @override
  Future<FriendRequestsSnapshot> build() async {
    final client = ref.watch(accountClientProvider);
    // Rebuilds whenever the session does, so signing in populates this,
    // and signing out — including by unlinking this device from its own
    // account — empties it with no extra wiring.
    final status = await ref.watch(accountSessionProvider.future);
    if (client == null || status.account == null) {
      return FriendRequestsSnapshot.empty;
    }
    return client.listFriendRequests();
  }

  /// Re-reads the list. Never throws: a failure becomes an `AsyncError`
  /// the UI renders as "couldn't check", which is the honest thing to say
  /// and is not the same claim as "you have no requests".
  Future<void> refresh() async {
    final client = ref.read(accountClientProvider);
    // Signed out, there is nothing to ask about and the server would only
    // answer 409 — see the routes' own doc comment (server ADR 0051).
    final signedIn = ref.read(accountSessionProvider).value?.account != null;
    if (client == null || !signedIn) return;
    state = await AsyncValue.guard(client.listFriendRequests);
  }

  /// Sends a friend request to [toUsername] — the one-field, one-button
  /// path. Lets [AccountClientException] out so the caller can say
  /// something specific about a username nobody is using.
  ///
  /// Re-reads the lists afterwards so the request the user just sent shows
  /// up as one they are waiting on, rather than disappearing into nothing
  /// until the next time something happens to refresh. That vanishing act
  /// is the whole problem outgoing requests exist to fix.
  Future<void> send(String toUsername) async {
    final client = ref.read(accountClientProvider);
    if (client == null) {
      throw const AccountClientException(0, 'Musicat Server not configured');
    }
    await client.sendFriendRequest(toUsername);
    await refresh();
  }

  /// Takes back a request this account sent and is still waiting on.
  ///
  /// **Not unfriending**: nobody is friends yet and nothing is removed —
  /// see [AccountClient.cancelFriendRequest]. Lets
  /// [AccountClientException] out so the caller can say what happened, and
  /// on the one failure that means the world moved on (`409`, they already
  /// answered) re-reads both lists first, so by the time the user is told,
  /// the screen already shows the truth.
  Future<void> cancel(String requestId) async {
    final client = ref.read(accountClientProvider);
    if (client == null) {
      throw const AccountClientException(0, 'Musicat Server not configured');
    }
    try {
      await client.cancelFriendRequest(requestId);
    } on AccountClientException catch (e) {
      if (e.statusCode == 409) {
        await refresh();
        // They may have said yes, in which case this device's server has
        // already added them — re-read rather than claim either way.
        ref.invalidate(friendsControllerProvider);
      }
      rethrow;
    }
    await refresh();
  }

  /// Answers [requestId]. On accept, the new friend is already in the
  /// server's own friends list by the time this returns (server ADR
  /// 0051), so the friends list is invalidated rather than polled.
  Future<void> respond(String requestId, {required bool accept}) async {
    final client = ref.read(accountClientProvider);
    if (client == null) return;
    if (accept) {
      await client.acceptFriendRequest(requestId);
      ref.invalidate(friendsControllerProvider);
    } else {
      await client.declineFriendRequest(requestId);
    }
    await refresh();
  }
}

final friendRequestsProvider =
    AsyncNotifierProvider<FriendRequestsController, FriendRequestsSnapshot>(
      FriendRequestsController.new,
      // Same reasoning as [accountSessionProvider]: every retry here is a
      // real round trip to the account service, and this provider is
      // deliberately the one that does not poll.
      retry: (retryCount, error) => null,
    );

/// How many friend requests are waiting for an answer — what the Friends
/// tab's badge is built from. `0` while loading, while signed out, and on
/// a failed check: a badge is a claim that there is something to do, and
/// none of those three know that there is.
final pendingFriendRequestCountProvider = Provider<int>(
  (ref) => ref.watch(friendRequestsProvider).value?.pending.length ?? 0,
);
