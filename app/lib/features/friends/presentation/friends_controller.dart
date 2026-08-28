import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/federation/federation_client.dart';
import 'musicat_server_config_controller.dart';

class FriendWithStatus {
  const FriendWithStatus({required this.friend, this.status});

  final FederationFriend friend;
  final FriendConnectionStatus? status;
}

class FriendsState {
  const FriendsState({
    this.friends = const [],
    this.loading = false,
    this.error,
  });

  final List<FriendWithStatus> friends;
  final bool loading;
  final String? error;

  FriendsState copyWith({
    List<FriendWithStatus>? friends,
    bool? loading,
    String? error,
  }) => FriendsState(
    friends: friends ?? this.friends,
    loading: loading ?? this.loading,
    error: error,
  );
}

/// Manages this device's friends list against its own Musicat Server
/// (server ADR 0019/0020) — refreshing periodically like
/// `DownloadsController` does for the transfer queue, since a friend's
/// connection status (ADR 0024) can change at any time.
class FriendsController extends Notifier<FriendsState> {
  Timer? _pollTimer;

  @override
  FriendsState build() {
    ref.onDispose(() => _pollTimer?.cancel());
    final client = ref.watch(federationClientProvider);
    if (client != null) {
      // Deferred to a microtask: `_refresh` writes `state` as its very
      // first (synchronous) statement, before its first `await`. Calling
      // it directly here would run that write synchronously as part of
      // `build()` itself, before Riverpod has finished initializing this
      // provider's state from `build()`'s return value below — which
      // throws "Tried to read the state of an uninitialized provider."
      // A microtask runs after `build()` returns, once that's set up.
      unawaited(Future.microtask(() => _refresh(client)));
      _pollTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => _refresh(client),
      );
    }
    return const FriendsState();
  }

  Future<void> _refresh(FederationClient client) async {
    state = state.copyWith(loading: true, error: null);
    try {
      final friends = await client.listFriends();
      final withStatus = <FriendWithStatus>[];
      for (final friend in friends) {
        FriendConnectionStatus? status;
        try {
          status = await client.getFriendStatus(friend.nodeId);
        } catch (_) {
          status = null;
        }
        withStatus.add(FriendWithStatus(friend: friend, status: status));
      }
      state = FriendsState(friends: withStatus);
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  Future<void> refresh() async {
    final client = ref.read(federationClientProvider);
    if (client != null) await _refresh(client);
  }

  Future<void> removeFriend(String nodeId) async {
    final client = ref.read(federationClientProvider);
    if (client == null) return;
    await client.removeFriend(nodeId);
    await _refresh(client);
  }

  /// A fresh code to share with a friend so they can add this node — see
  /// [FederationClient.generatePairingCode].
  Future<String> generateMyPairingCode() async {
    final client = ref.read(federationClientProvider);
    if (client == null) throw StateError('Musicat Server not configured');
    return client.generatePairingCode();
  }

  /// Redeems a friend's code, trusting *this* node on their server. See
  /// [FederationClient.addFriend] — the friend still needs to separately
  /// redeem a code of this node's own for the trust to go both ways.
  ///
  /// Always sends this device's own configured `myDisplayName` (see
  /// [MusicatServerConfig]) as the outgoing `displayName` — not anything
  /// supplied by the caller. That value is *this node's own*
  /// self-description, as seen by the friend being added; it is unrelated
  /// to [FederationFriend.localNickname], the purely local label this
  /// device's own user can separately give *that* friend (see
  /// [setLocalNickname]).
  Future<void> addFriend({
    required String friendAddress,
    required String code,
  }) async {
    final client = ref.read(federationClientProvider);
    final config = ref.read(musicatServerConfigControllerProvider);
    if (client == null) throw StateError('Musicat Server not configured');
    await client.addFriend(
      friendBaseUrl: 'http://$friendAddress',
      code: code,
      myPublicAddress: config.myPublicAddress,
      displayName: config.myDisplayName,
    );
    await _refresh(client);
  }

  /// Sets/clears the purely local [FederationFriend.localNickname] for
  /// [nodeId] — see [FederationClient.setLocalNickname]. A no-op if the
  /// Musicat Server isn't configured.
  Future<void> setLocalNickname(String nodeId, String? nickname) async {
    final client = ref.read(federationClientProvider);
    if (client == null) return;
    await client.setLocalNickname(nodeId, nickname);
    await _refresh(client);
  }
}

final friendsControllerProvider =
    NotifierProvider.autoDispose<FriendsController, FriendsState>(
      FriendsController.new,
    );
