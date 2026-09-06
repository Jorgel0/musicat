import 'package:musicat_server/src/accounts/login_nonce_store.dart';
import 'package:test/test.dart';

void main() {
  test('a freshly generated nonce redeems exactly once', () {
    final store = LoginNonceStore();
    final nonce = store.generate('alice');

    expect(store.redeem('alice'), nonce);
    // Single-use: a second redeem for the same username finds nothing.
    expect(store.redeem('alice'), isNull);
  });

  test('redeeming a username with no pending nonce returns null', () {
    final store = LoginNonceStore();
    expect(store.redeem('never-started'), isNull);
  });

  test('generating a new nonce for the same username replaces the previous '
      'still-pending one', () {
    final store = LoginNonceStore();
    final first = store.generate('alice');
    final second = store.generate('alice');

    expect(first, isNot(equals(second)));
    // Only the most recently issued nonce is redeemable.
    expect(store.redeem('alice'), second);
  });

  test('a nonce past its ttl is no longer redeemable', () async {
    final store = LoginNonceStore(ttl: const Duration(milliseconds: 20));
    store.generate('alice');

    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(store.redeem('alice'), isNull);
  });

  test('expired nonces are swept, so an unauthenticated caller cannot grow '
      'this map forever with made-up usernames', () async {
    final store = LoginNonceStore(ttl: const Duration(milliseconds: 20));
    for (var i = 0; i < 50; i++) {
      store.generate('made-up-$i');
    }
    expect(store.pendingCount, 50);

    await Future<void>.delayed(const Duration(milliseconds: 60));
    // Any further `login/start` sweeps what has expired -- the map is
    // bounded by "logins started in the last ttl", not by the process's
    // lifetime.
    store.generate('alice');

    expect(store.pendingCount, 1);
    expect(store.redeem('made-up-7'), isNull);
    expect(store.redeem('alice'), isNotNull);
  });

  test('maxPending caps even un-expired nonces, so a flood costs bounded '
      'memory rather than the process', () {
    final store = LoginNonceStore(maxPending: 3);
    for (var i = 0; i < 20; i++) {
      store.generate('made-up-$i');
    }

    expect(store.pendingCount, lessThanOrEqualTo(3));
    // The most recent attempt is always still redeemable: eviction takes
    // whatever was closest to expiring.
    expect(store.redeem('made-up-19'), isNotNull);
  });

  test('nonces for different usernames are independent', () {
    final store = LoginNonceStore();
    final aliceNonce = store.generate('alice');
    final bobNonce = store.generate('bob');

    expect(aliceNonce, isNot(equals(bobNonce)));
    expect(store.redeem('alice'), aliceNonce);
    expect(store.redeem('bob'), bobNonce);
  });
}
