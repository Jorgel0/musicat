import 'dart:io';

import 'package:musicat_server/src/accounts/friend_request.dart';
import 'package:musicat_server/src/accounts/friend_request_store.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late FriendRequestStore store;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync(
      'musicat_friend_request_store_test_',
    );
    store = FriendRequestStore(tempDir);
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('send creates a pending request', () async {
    final request = await store.send('alice', 'bob');

    expect(request.fromAccountId, 'alice');
    expect(request.toAccountId, 'bob');
    expect(request.status, FriendRequestStatus.pending);
  });

  test('sending a second request in the same direction while one is still '
      'pending returns the existing one unchanged, not a new one', () async {
    final first = await store.send('alice', 'bob');
    final second = await store.send('alice', 'bob');

    expect(second.id, first.id);
    final all = await store.loadAll();
    expect(all, hasLength(1));
  });

  test('a new request can be sent after a previous one was declined', () async {
    final first = await store.send('alice', 'bob');
    await store.decline(first.id, 'bob');

    final second = await store.send('alice', 'bob');

    expect(second.id, isNot(equals(first.id)));
    expect(second.status, FriendRequestStatus.pending);
  });

  group('listAddressedTo', () {
    test('lists every request addressed to an account', () async {
      await store.send('alice', 'bob');
      await store.send('carol', 'bob');
      await store.send('bob', 'alice');

      final toBob = await store.listAddressedTo('bob');
      expect(toBob.map((r) => r.fromAccountId).toSet(), {'alice', 'carol'});
    });

    test('narrows by status when given one', () async {
      final request = await store.send('alice', 'bob');
      await store.accept(request.id, 'bob');
      await store.send('carol', 'bob');

      final pending = await store.listAddressedTo(
        'bob',
        status: FriendRequestStatus.pending,
      );
      expect(pending, hasLength(1));
      expect(pending.single.fromAccountId, 'carol');

      final accepted = await store.listAddressedTo(
        'bob',
        status: FriendRequestStatus.accepted,
      );
      expect(accepted, hasLength(1));
      expect(accepted.single.fromAccountId, 'alice');
    });
  });

  group('accept', () {
    test(
      'flips a pending request to accepted for its real recipient',
      () async {
        final request = await store.send('alice', 'bob');

        final (outcome, updated) = await store.accept(request.id, 'bob');

        expect(outcome, RespondOutcome.updated);
        expect(updated!.status, FriendRequestStatus.accepted);
      },
    );

    test('the sender cannot accept their own request', () async {
      final request = await store.send('alice', 'bob');

      final (outcome, _) = await store.accept(request.id, 'alice');

      expect(outcome, RespondOutcome.forbidden);
      final reloaded = await store.findById(request.id);
      expect(reloaded!.status, FriendRequestStatus.pending);
    });

    test('an unrelated account cannot accept a request', () async {
      final request = await store.send('alice', 'bob');

      final (outcome, _) = await store.accept(request.id, 'carol');

      expect(outcome, RespondOutcome.forbidden);
    });

    test('accepting an already-accepted request is a no-op success', () async {
      final request = await store.send('alice', 'bob');
      await store.accept(request.id, 'bob');

      final (outcome, updated) = await store.accept(request.id, 'bob');

      expect(outcome, RespondOutcome.alreadyInThatState);
      expect(updated!.status, FriendRequestStatus.accepted);
    });

    test('accepting an already-declined request conflicts', () async {
      final request = await store.send('alice', 'bob');
      await store.decline(request.id, 'bob');

      final (outcome, _) = await store.accept(request.id, 'bob');

      expect(outcome, RespondOutcome.conflict);
    });

    test('returns notFound for an unknown request id', () async {
      final (outcome, updated) = await store.accept('never-existed', 'bob');
      expect(outcome, RespondOutcome.notFound);
      expect(updated, isNull);
    });
  });

  group('decline', () {
    test(
      'flips a pending request to declined for its real recipient',
      () async {
        final request = await store.send('alice', 'bob');

        final (outcome, updated) = await store.decline(request.id, 'bob');

        expect(outcome, RespondOutcome.updated);
        expect(updated!.status, FriendRequestStatus.declined);
      },
    );

    test('the sender cannot decline their own request', () async {
      final request = await store.send('alice', 'bob');

      final (outcome, _) = await store.decline(request.id, 'alice');

      expect(outcome, RespondOutcome.forbidden);
    });
  });

  group('areMutualFriends', () {
    test('false with no requests at all', () async {
      expect(await store.areMutualFriends('alice', 'bob'), isFalse);
    });

    test('false while a request is only pending', () async {
      await store.send('alice', 'bob');
      expect(await store.areMutualFriends('alice', 'bob'), isFalse);
    });

    test('true once accepted, checked from either direction', () async {
      final request = await store.send('alice', 'bob');
      await store.accept(request.id, 'bob');

      expect(await store.areMutualFriends('alice', 'bob'), isTrue);
      expect(await store.areMutualFriends('bob', 'alice'), isTrue);
    });

    test('false after a decline', () async {
      final request = await store.send('alice', 'bob');
      await store.decline(request.id, 'bob');

      expect(await store.areMutualFriends('alice', 'bob'), isFalse);
    });

    test('unrelated accounts are never mutual friends', () async {
      final request = await store.send('alice', 'bob');
      await store.accept(request.id, 'bob');

      expect(await store.areMutualFriends('alice', 'carol'), isFalse);
      expect(await store.areMutualFriends('carol', 'bob'), isFalse);
    });
  });

  group('revokeFriendship', () {
    /// Makes [a] and [b] accepted friends, with [a] the sender.
    Future<FriendRequest> befriend(String a, String b) async {
      final request = await store.send(a, b);
      await store.accept(request.id, b);
      return request;
    }

    test('either side can end it, whichever of them sent the request '
        'originally', () async {
      await befriend('alice', 'bob');

      // Bob, the *recipient* of the original request, is the one revoking.
      expect(await store.revokeFriendship('bob', 'alice'), 1);

      expect(await store.areMutualFriends('alice', 'bob'), isFalse);
      expect(await store.areMutualFriends('bob', 'alice'), isFalse);
      expect(await store.listAcceptedFriendAccountIds('alice'), isEmpty);
      expect(await store.listAcceptedFriendAccountIds('bob'), isEmpty);
    });

    test('the sender can end it too', () async {
      await befriend('alice', 'bob');

      expect(await store.revokeFriendship('alice', 'bob'), 1);

      expect(await store.areMutualFriends('alice', 'bob'), isFalse);
    });

    test('marks the row revoked rather than deleting it -- absence is what a '
        'bug looks like, a deliberate end should not', () async {
      final request = await befriend('alice', 'bob');

      await store.revokeFriendship('alice', 'bob');

      final stored = await store.findById(request.id);
      expect(stored, isNotNull);
      expect(stored!.status, FriendRequestStatus.revoked);
    });

    test('revokes *every* accepted row between the two, not just the first -- '
        'both directions accepted is one friendship', () async {
      await befriend('alice', 'bob');
      await befriend('bob', 'alice');
      expect(await store.areMutualFriends('alice', 'bob'), isTrue);

      expect(await store.revokeFriendship('alice', 'bob'), 2);

      expect(
        await store.areMutualFriends('alice', 'bob'),
        isFalse,
        reason:
            'a second accepted row survived, so they are still friends after '
            'a revocation that reported success',
      );
    });

    test('is a no-op for two accounts that were never friends', () async {
      await store.send('alice', 'bob'); // pending, never accepted

      expect(await store.revokeFriendship('alice', 'bob'), 0);
      expect(await store.revokeFriendship('alice', 'nobody'), 0);
    });

    test('leaves a still-pending request between the two alone -- that is a '
        'separate, unanswered offer', () async {
      await befriend('alice', 'bob');
      final pending = await store.send('bob', 'alice');

      await store.revokeFriendship('alice', 'bob');

      expect(
        (await store.findById(pending.id))!.status,
        FriendRequestStatus.pending,
      );
    });

    test(
      're-friending afterwards works, through an ordinary new request',
      () async {
        await befriend('alice', 'bob');
        await store.revokeFriendship('alice', 'bob');

        final again = await store.send('alice', 'bob');
        final (outcome, _) = await store.accept(again.id, 'bob');

        expect(outcome, RespondOutcome.updated);
        expect(await store.areMutualFriends('alice', 'bob'), isTrue);
      },
    );

    test('a revoked request can never be re-accepted -- resurrection has to '
        'go through a new request', () async {
      final request = await befriend('alice', 'bob');
      await store.revokeFriendship('alice', 'bob');

      final (outcome, _) = await store.accept(request.id, 'bob');

      expect(outcome, RespondOutcome.conflict);
      expect(await store.areMutualFriends('alice', 'bob'), isFalse);
    });

    test('survives a restart', () async {
      await befriend('alice', 'bob');
      await store.revokeFriendship('alice', 'bob');

      final reloaded = FriendRequestStore(tempDir);
      expect(await reloaded.areMutualFriends('alice', 'bob'), isFalse);
    });
  });

  test('two concurrent send() calls for the same (from, to) pair result in '
      'exactly one persisted pending request', () async {
    final results = await Future.wait([
      store.send('alice', 'bob'),
      store.send('alice', 'bob'),
    ]);

    expect(results[0].id, results[1].id);
    final all = await store.loadAll();
    expect(all, hasLength(1));
  });

  test('persists across store instances', () async {
    final request = await store.send('alice', 'bob');
    await store.accept(request.id, 'bob');

    final reloaded = FriendRequestStore(tempDir);
    expect(await reloaded.areMutualFriends('alice', 'bob'), isTrue);
  });
}
