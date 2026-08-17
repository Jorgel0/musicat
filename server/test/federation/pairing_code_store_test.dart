import 'package:musicat_server/src/federation/pairing_code_store.dart';
import 'package:test/test.dart';

void main() {
  test('generates a non-empty code', () {
    final store = PairingCodeStore();
    expect(store.generate(), isNotEmpty);
  });

  test('generated codes are not obviously predictable duplicates', () {
    final store = PairingCodeStore();
    final codes = {for (var i = 0; i < 20; i++) store.generate()};
    expect(codes, hasLength(20));
  });

  test('redeems a freshly generated code', () {
    final store = PairingCodeStore();
    final code = store.generate();
    expect(store.redeem(code), isTrue);
  });

  test('a code can only be redeemed once', () {
    final store = PairingCodeStore();
    final code = store.generate();

    expect(store.redeem(code), isTrue);
    expect(store.redeem(code), isFalse);
  });

  test('rejects a code that was never generated', () {
    final store = PairingCodeStore();
    expect(store.redeem('never-generated'), isFalse);
  });

  test('rejects a code past its ttl', () async {
    final store = PairingCodeStore(ttl: Duration.zero);
    final code = store.generate();

    // ttl of zero means it's already expired the moment it's checked.
    expect(store.redeem(code), isFalse);
  });
}
