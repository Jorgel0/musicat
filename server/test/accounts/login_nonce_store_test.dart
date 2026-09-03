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

  test('nonces for different usernames are independent', () {
    final store = LoginNonceStore();
    final aliceNonce = store.generate('alice');
    final bobNonce = store.generate('bob');

    expect(aliceNonce, isNot(equals(bobNonce)));
    expect(store.redeem('alice'), aliceNonce);
    expect(store.redeem('bob'), bobNonce);
  });
}
