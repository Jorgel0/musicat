import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicat/core/embedded_server/embedded_server.dart';
import 'package:musicat/core/network/federation/federation_client.dart';
import 'package:musicat/features/friends/presentation/android_background_reachability_controller.dart';
import 'package:musicat/features/friends/presentation/friends_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A [FriendsController] a test can mutate directly, without going through
/// the real client/polling machinery -- mirrors `_FixedFriendsController`
/// in friends_screen_test.dart, but mutable so a single test can simulate
/// a live 0 -> 1 friend transition the way a real Friends screen would.
class _MutableFriendsController extends FriendsController {
  _MutableFriendsController([this._initial = const FriendsState()]);

  final FriendsState _initial;

  @override
  FriendsState build() => _initial;

  void setFriends(List<FriendWithStatus> friends) {
    state = FriendsState(friends: friends);
  }
}

const _friend = FriendWithStatus(
  friend: FederationFriend(
    nodeId: 'n1',
    publicKeyBase64: 'pk1',
    address: 'a.example:8080',
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('loadAndroidBackgroundReachabilityOverride', () {
    test('defaults to null (automatic) when never saved', () async {
      expect(await loadAndroidBackgroundReachabilityOverride(), isNull);
    });

    test('returns a persisted explicit true', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(androidBackgroundReachabilityOverrideKey, true);

      expect(await loadAndroidBackgroundReachabilityOverride(), isTrue);
    });

    test('returns a persisted explicit false', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(androidBackgroundReachabilityOverrideKey, false);

      expect(await loadAndroidBackgroundReachabilityOverride(), isFalse);
    });
  });

  group('AndroidBackgroundReachabilityOverrideController.save', () {
    test('persists an explicit true, and updates state immediately', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container
          .read(androidBackgroundReachabilityOverrideProvider.notifier)
          .save(true);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(androidBackgroundReachabilityOverrideKey), isTrue);
      expect(
        container.read(androidBackgroundReachabilityOverrideProvider),
        isTrue,
      );
    });

    test(
      'saving null clears the persisted key entirely (back to automatic)',
      () async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(androidBackgroundReachabilityOverrideKey, false);
        final container = ProviderContainer(
          overrides: [
            androidBackgroundReachabilityOverrideProvider.overrideWith(
              () => AndroidBackgroundReachabilityOverrideController(false),
            ),
          ],
        );
        addTearDown(container.dispose);

        await container
            .read(androidBackgroundReachabilityOverrideProvider.notifier)
            .save(null);

        final reloaded = await SharedPreferences.getInstance();
        expect(
          reloaded.containsKey(androidBackgroundReachabilityOverrideKey),
          isFalse,
        );
        expect(
          container.read(androidBackgroundReachabilityOverrideProvider),
          isNull,
        );
      },
    );
  });

  group('desiredAndroidBackgroundReachableProvider', () {
    test('false when there is no override and no friends yet', () {
      final container = ProviderContainer(
        overrides: [
          friendsControllerProvider.overrideWith(_MutableFriendsController.new),
        ],
      );
      addTearDown(container.dispose);

      expect(
        container.read(desiredAndroidBackgroundReachableProvider),
        isFalse,
      );
    });

    test('flips to true the moment friends become non-empty, with no override '
        '(the automatic, friend-count-based default this feature is built '
        'around)', () {
      final controller = _MutableFriendsController();
      final container = ProviderContainer(
        overrides: [friendsControllerProvider.overrideWith(() => controller)],
      );
      addTearDown(container.dispose);
      // Keeps the autoDispose provider chain alive across the mutation
      // below -- a real widget's ref.watch plays this role normally
      // (same pattern as friends_controller_test.dart).
      final subscription = container.listen(
        desiredAndroidBackgroundReachableProvider,
        (a, b) {},
      );
      addTearDown(subscription.close);

      expect(
        container.read(desiredAndroidBackgroundReachableProvider),
        isFalse,
      );

      controller.setFriends([_friend]);

      expect(container.read(desiredAndroidBackgroundReachableProvider), isTrue);
    });

    test('an explicit false override wins even with friends present', () {
      final container = ProviderContainer(
        overrides: [
          friendsControllerProvider.overrideWith(
            () => _MutableFriendsController(
              const FriendsState(friends: [_friend]),
            ),
          ),
          androidBackgroundReachabilityOverrideProvider.overrideWith(
            () => AndroidBackgroundReachabilityOverrideController(false),
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(
        container.read(desiredAndroidBackgroundReachableProvider),
        isFalse,
      );
    });

    test('an explicit true override wins even with no friends at all', () {
      final container = ProviderContainer(
        overrides: [
          friendsControllerProvider.overrideWith(_MutableFriendsController.new),
          androidBackgroundReachabilityOverrideProvider.overrideWith(
            () => AndroidBackgroundReachabilityOverrideController(true),
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(desiredAndroidBackgroundReachableProvider), isTrue);
    });
  });

  group('androidBackgroundReachabilityEffectProvider', () {
    test(
      'a cold read never throws -- setAndroidBackgroundReachable is a no-op '
      'on this (non-Android) test host, and nothing here ever writes to '
      "another provider's state mid-build (same care as ADR 0037/0039)",
      () async {
        final container = ProviderContainer(
          overrides: [
            friendsControllerProvider.overrideWith(
              _MutableFriendsController.new,
            ),
          ],
        );
        addTearDown(container.dispose);

        expect(
          () => container.read(androidBackgroundReachabilityEffectProvider),
          returnsNormally,
        );

        // Lets the fireImmediately listeners' own deferred
        // SharedPreferences writes settle before the container disposes.
        await Future<void>.delayed(const Duration(milliseconds: 20));
      },
    );

    test(
      'reacts to a live 0 -> 1 friend transition without throwing',
      () async {
        final controller = _MutableFriendsController();
        final container = ProviderContainer(
          overrides: [friendsControllerProvider.overrideWith(() => controller)],
        );
        addTearDown(container.dispose);
        final subscription = container.listen(
          androidBackgroundReachabilityEffectProvider,
          (a, b) {},
        );
        addTearDown(subscription.close);

        controller.setFriends([_friend]);

        await Future<void>.delayed(const Duration(milliseconds: 20));
      },
    );
  });
}
