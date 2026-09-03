import 'package:musicat_server/src/accounts/login_rate_limiter.dart';
import 'package:test/test.dart';

void main() {
  test('is not locked out before any failures', () {
    final limiter = LoginRateLimiter();
    expect(limiter.isLockedOut('alice'), isFalse);
  });

  test('locks out after maxAttempts consecutive failures', () {
    final limiter = LoginRateLimiter(
      maxAttempts: 3,
      lockoutDuration: const Duration(seconds: 60),
    );

    limiter.recordFailure('alice');
    expect(limiter.isLockedOut('alice'), isFalse);
    limiter.recordFailure('alice');
    expect(limiter.isLockedOut('alice'), isFalse);
    limiter.recordFailure('alice');

    expect(limiter.isLockedOut('alice'), isTrue);
  });

  test('a lockout expires after lockoutDuration', () async {
    final limiter = LoginRateLimiter(
      maxAttempts: 2,
      lockoutDuration: const Duration(milliseconds: 30),
    );

    limiter.recordFailure('alice');
    limiter.recordFailure('alice');
    expect(limiter.isLockedOut('alice'), isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(limiter.isLockedOut('alice'), isFalse);
  });

  test('a success resets the failure count', () {
    final limiter = LoginRateLimiter(
      maxAttempts: 3,
      lockoutDuration: const Duration(seconds: 60),
    );

    limiter.recordFailure('alice');
    limiter.recordFailure('alice');
    limiter.recordSuccess('alice');
    limiter.recordFailure('alice');
    limiter.recordFailure('alice');

    // Only 2 consecutive failures since the reset -- still below the
    // threshold of 3.
    expect(limiter.isLockedOut('alice'), isFalse);
  });

  test('lockouts are scoped per username', () {
    final limiter = LoginRateLimiter(
      maxAttempts: 2,
      lockoutDuration: const Duration(seconds: 60),
    );

    limiter.recordFailure('alice');
    limiter.recordFailure('alice');

    expect(limiter.isLockedOut('alice'), isTrue);
    expect(limiter.isLockedOut('bob'), isFalse);
  });
}
