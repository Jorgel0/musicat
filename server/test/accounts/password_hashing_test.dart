import 'package:musicat_server/src/accounts/password_hashing.dart';
import 'package:test/test.dart';

void main() {
  test('a freshly hashed password verifies against itself', () async {
    final hashed = await hashPassword('correct horse battery staple');
    expect(
      await verifyPassword('correct horse battery staple', hashed),
      isTrue,
    );
  });

  test('the wrong password fails verification', () async {
    final hashed = await hashPassword('correct horse battery staple');
    expect(await verifyPassword('wrong password', hashed), isFalse);
  });

  test('two hashes of the same password use different random salts', () async {
    final first = await hashPassword('hunter2');
    final second = await hashPassword('hunter2');
    expect(first.salt, isNot(equals(second.salt)));
    expect(first.hash, isNot(equals(second.hash)));
  });

  test('verification always re-derives with the stored hash\'s own params, not '
      'a currently-configured default', () async {
    const lightParams = Argon2Params(memory: 8, iterations: 1, parallelism: 1);
    final hashed = await hashPassword('hunter2', params: lightParams);

    expect(hashed.params.memory, 8);
    expect(await verifyPassword('hunter2', hashed), isTrue);
    // Raising the recommended default afterward must not invalidate an
    // account hashed under lighter params -- verifyPassword always uses
    // [hashed]'s own stored params, never [Argon2Params.recommended].
    expect(Argon2Params.recommended.memory, isNot(8));
  });

  test('Argon2Params round-trips through JSON', () {
    const params = Argon2Params(memory: 19456, iterations: 2, parallelism: 1);
    final restored = Argon2Params.fromJson(params.toJson());
    expect(restored.memory, params.memory);
    expect(restored.iterations, params.iterations);
    expect(restored.parallelism, params.parallelism);
  });
}
