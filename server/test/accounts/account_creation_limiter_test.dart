import 'package:musicat_server/src/accounts/account_creation_limiter.dart';
import 'package:test/test.dart';

void main() {
  test('allows creations up to the cap, then refuses that caller', () {
    final limiter = AccountCreationLimiter(maxCreations: 2);

    expect(limiter.allows('203.0.113.7'), isTrue);
    limiter.record('203.0.113.7');
    expect(limiter.allows('203.0.113.7'), isTrue);
    limiter.record('203.0.113.7');

    expect(limiter.allows('203.0.113.7'), isFalse);
  });

  test('the cap is per caller, not global -- one busy address never locks '
      'everybody else out of signing up', () {
    final limiter = AccountCreationLimiter(maxCreations: 1);
    limiter.record('203.0.113.7');

    expect(limiter.allows('203.0.113.7'), isFalse);
    expect(limiter.allows('198.51.100.4'), isTrue);
  });

  test('the budget comes back once the window has passed', () async {
    final limiter = AccountCreationLimiter(
      maxCreations: 1,
      window: const Duration(milliseconds: 30),
    );
    limiter.record('203.0.113.7');
    expect(limiter.allows('203.0.113.7'), isFalse);

    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(limiter.allows('203.0.113.7'), isTrue);
  });

  test('checking is pure: it never records anything itself, because whether '
      'a login turned out to be a creation is only known afterwards', () {
    final limiter = AccountCreationLimiter(maxCreations: 1);

    for (var i = 0; i < 10; i++) {
      expect(limiter.allows('203.0.113.7'), isTrue);
    }
  });
}
