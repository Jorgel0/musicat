import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/federation/account_client.dart';
import 'friends_controller.dart';
import 'musicat_server_config_controller.dart';

/// Who this device is signed in as (server ADR 0050), and the two actions
/// that change that.
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
class AccountSessionController extends AsyncNotifier<MyAccount?> {
  @override
  Future<MyAccount?> build() async {
    final client = ref.watch(accountClientProvider);
    if (client == null) return null;
    return client.currentAccount();
  }

  /// Signs in as [username], creating the account if that username is
  /// free — one call, one flow (see [AccountClient.signIn]). Returns what
  /// actually happened so the caller can say "account created" or
  /// "signed in" truthfully.
  ///
  /// Lets [AccountClientException] out deliberately: the sign-in screen
  /// needs the status code to tell a wrong password from a lockout from
  /// "accounts aren't reachable right now", and swallowing it here would
  /// leave it nothing to tell them apart with.
  Future<SignInResult> signIn({
    required String username,
    required String password,
  }) async {
    final client = ref.read(accountClientProvider);
    if (client == null) {
      throw const AccountClientException(0, 'Musicat Server not configured');
    }
    final result = await client.signIn(username: username, password: password);
    // Re-read rather than synthesise a session from `result`: the server
    // is the thing that persisted it, and its answer includes `loggedInAt`.
    state = AsyncData(await client.currentAccount());
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
    state = const AsyncData(null);
  }
}

final accountSessionProvider =
    AsyncNotifierProvider<AccountSessionController, MyAccount?>(
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
    // Rebuilds whenever the session does, so signing in populates this and
    // signing out empties it with no extra wiring.
    final account = await ref.watch(accountSessionProvider.future);
    if (client == null || account == null) {
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
    final signedIn = ref.read(accountSessionProvider).value != null;
    if (client == null || !signedIn) return;
    state = await AsyncValue.guard(client.listFriendRequests);
  }

  /// Sends a friend request to [toUsername] — the one-field, one-button
  /// path. Lets [AccountClientException] out so the caller can say
  /// something specific about a username nobody is using.
  Future<void> send(String toUsername) async {
    final client = ref.read(accountClientProvider);
    if (client == null) {
      throw const AccountClientException(0, 'Musicat Server not configured');
    }
    await client.sendFriendRequest(toUsername);
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
