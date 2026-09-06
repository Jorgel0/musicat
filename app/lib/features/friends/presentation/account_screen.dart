import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/federation/account_client.dart';
import 'account_controller.dart';
import 'musicat_server_config_controller.dart';

/// Sign in, or create an account, or see the one you're in — all one
/// screen, because the server has exactly one call for the first two (see
/// [AccountClient.signIn]). Building a sign-up tab and a log-in tab over a
/// single endpoint would be inventing a distinction the system doesn't
/// have, and would make the user pick the right one before they're allowed
/// to type anything.
///
/// Reached from the Friends screen (`/account`). Nothing else in the app is
/// gated on getting here: a device that never signs in keeps adding friends
/// by invite code exactly as before (ADR 0038/0045).
class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionAsync = ref.watch(accountSessionProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: SafeArea(
        child: sessionAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          // "Who am I" is answered by this device's own server from its own
          // disk, so a failure here is a local problem, not a signed-out
          // state — saying "sign in" would be a guess dressed up as a fact.
          error: (error, stackTrace) => const _CentredMessage(
            icon: Icons.error_outline,
            message:
                'Could not check your account on this device. Make sure '
                'Musicat is running properly and try again.',
          ),
          // Signed out *and* nowhere to sign in to: say that, rather than
          // offering a form whose only possible outcome is a failure that
          // reads like a passing glitch. See
          // [accountsHaveNoServerProvider] — this is configuration this
          // device can check locally, not something to find out over the
          // network.
          data: (account) => account == null
              ? (ref.watch(accountsHaveNoServerProvider)
                    ? const _NoServerForAccounts()
                    : const _SignInForm())
              : _SignedIn(account: account),
        ),
      ),
    );
  }
}

class _CentredMessage extends StatelessWidget {
  const _CentredMessage({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

/// What this device shows instead of a sign-in form when there is nowhere
/// to sign in to: this build of Musicat ships no relay of its own
/// (`defaultRelayUrl`) and the user has not set one either, so every
/// account call would fail no matter what they typed.
///
/// Worth a screen of its own rather than an error under the form. The form
/// invites you to try again; the truth is that trying again cannot work,
/// and the only way forward is an address someone has to give you. Says
/// what a relay is in the same breath as asking for one, since nobody
/// installing a music player is expected to already know.
class _NoServerForAccounts extends StatelessWidget {
  const _NoServerForAccounts();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 48),
            const SizedBox(height: 16),
            Text(
              'Accounts need a relay',
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            const Text(
              'A relay is a small shared server that carries sign-ins and '
              'friend requests between people. This copy of Musicat does '
              'not come with one, so there is nothing to sign in to yet.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            const Text(
              'Ask whoever gave you Musicat which relay to use — or use '
              'your own, if you run one — and enter its address under '
              'Musicat Server on the Friends screen.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Text(
              'Everything else keeps working: you can still add friends '
              'with an invite code or a QR, exactly as before.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// The signed-in half: mostly here so the username is finally *visible*
/// somewhere in the app — until now this device could hold an identity its
/// own user had no way to read back.
class _SignedIn extends ConsumerWidget {
  const _SignedIn({required this.account});

  final MyAccount account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          const Icon(Icons.account_circle_outlined, size: 64),
          const SizedBox(height: 16),
          Text(
            'Signed in as',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 4),
          Text(
            account.username,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 16),
          Text(
            'Friends can add you with this username, and you can sign in '
            'with it on your other devices to keep the same friends there.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const Spacer(),
          OutlinedButton.icon(
            onPressed: () => _confirmSignOut(context, ref),
            icon: const Icon(Icons.logout),
            label: const Text('Sign out'),
          ),
          const SizedBox(height: 8),
          Text(
            'Your friends stay on this device if you sign out.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Future<void> _confirmSignOut(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out?'),
        // Says the reassuring part out loud, because the alternative
        // reading ("does this delete my friends?") is the one that stops
        // people from ever tapping it.
        content: const Text(
          'Your friends stay on this device — signing out does not remove '
          'anyone. You can sign back in with the same username and '
          'password whenever you like.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(accountSessionProvider.notifier).signOut();
  }
}

/// What one call to the login route left the sign-in screen with — see
/// [_SignInFormState._attemptSignIn]. Only [noSuchAccount] leaves anything
/// undecided; the other two have already been said to the user.
enum _SignInOutcome { done, noSuchAccount, failed }

class _SignInForm extends ConsumerStatefulWidget {
  const _SignInForm();

  @override
  ConsumerState<_SignInForm> createState() => _SignInFormState();
}

class _SignInFormState extends ConsumerState<_SignInForm> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  /// The failure cases a person can actually act on, told apart. The one
  /// that matters most is the 502/503: a service problem must never read
  /// as "you got your password wrong", which is what a single generic
  /// error message would leave them believing.
  static String _messageFor(AccountClientException e) => switch (e.code) {
    // Branch on the machine-readable reason where the service sent one,
    // and fall back to the status for an older node that sends none.
    'password_too_short' => e.message.trim(),
    'invalid_username' || 'invalid_request' => _usernameRule,
    'incorrect_password' =>
      'That password does not match this username. If the account is not '
          'yours, choose a different username.',
    'login_expired' => 'That took too long. Try signing in again.',
    'rate_limited' =>
      'Too many attempts for that username. Wait about a minute, then try '
          'again.',
    'too_many_new_accounts' =>
      'Too many new accounts have been created from here recently. Wait a '
          'while, or sign in to an account you already have.',
    // Two accounts differ only in capitalisation, so the service cannot
    // tell which one is meant. Retrying never fixes this -- somebody has
    // to sort it out on the service -- so the copy must not imply waiting
    // will help, which is exactly what the generic 5xx line does.
    'ambiguous_username' =>
      'This username cannot be used right now: two accounts share it. '
          'Whoever runs this relay needs to resolve that — trying again '
          'will not help.',
    'no_account_service' =>
      'This copy of Musicat has no relay set, so accounts are not '
          'available. You can still add friends with an invite code.',
    'service_unreachable' || 'service_failed' => _serviceDownRule,
    _ => _messageForStatus(e),
  };

  /// The pre-`code` path, kept for a node old enough not to send one.
  static String _messageForStatus(AccountClientException e) =>
      switch (e.statusCode) {
        401 =>
          'That password does not match this username. If the account is '
              'not yours, choose a different username.',
        409 =>
          'This username cannot be used right now: two accounts share it. '
              'Whoever runs this relay needs to resolve that — trying '
              'again will not help.',
        429 =>
          'Too many attempts for that username. Wait about a minute, then '
              'try again.',
        400 => _badRequestMessage(e),
        502 || 503 => _serviceDownRule,
        _ => 'Could not sign in right now. Try again in a moment.',
      };

  static const _usernameRule =
      'Choose a username of 3 to 32 characters, using only letters, '
      'numbers, - or _.';

  static const _serviceDownRule =
      'Accounts are not available right now — this is not a problem with '
      'your password. Try again in a moment.';

  /// A `400` is two different mistakes wearing one status code: a username
  /// the service will not accept, and a password too short to create an
  /// account with. Only the second carries a number this app does not know
  /// — the minimum length lives on the service — so that one is passed
  /// through in the service's own words rather than replaced by a rule
  /// this side would have to guess at; anything else falls back to the
  /// username rule, which this app does know.
  ///
  /// Only reached for a node old enough to send no `code` — a current one
  /// takes the `password_too_short`/`invalid_username` branches above.
  /// Sniffing the sentence for "password" is the only signal such a node
  /// gives, and it is exactly the fragility the codes exist to remove.
  static String _badRequestMessage(AccountClientException e) {
    final message = e.message.trim();
    if (message.toLowerCase().contains('password')) return message;
    return _usernameRule;
  }

  /// Sign in, in two deliberate steps.
  ///
  /// The first asks **without permission to create anything**
  /// (`allowCreate: false`), so a mistyped username answers "no such
  /// account" instead of silently becoming a second, empty account with
  /// none of your friends in it — the failure mode that is worst precisely
  /// because it looks like success. Creating one is then something the
  /// user is asked out loud, and only then does the second call go out.
  Future<void> _submit() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() => _error = 'Enter a username and a password.');
      return;
    }

    final outcome = await _attemptSignIn(
      username: username,
      password: password,
      allowCreate: false,
    );
    if (outcome != _SignInOutcome.noSuchAccount || !mounted) return;

    final confirmed = await _confirmCreate(username);
    if (confirmed != true || !mounted) return;
    await _attemptSignIn(
      username: username,
      password: password,
      allowCreate: true,
    );
  }

  /// One real call to the login route, with everything the screen has to
  /// do about its outcome. [_SignInOutcome.noSuchAccount] is the only one
  /// the caller has anything left to decide about; the rest are already
  /// reported to the user by the time this returns.
  Future<_SignInOutcome> _attemptSignIn({
    required String username,
    required String password,
    required bool allowCreate,
  }) async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(accountSessionProvider.notifier)
          .signIn(
            username: username,
            password: password,
            allowCreate: allowCreate,
          );
      if (!mounted) return _SignInOutcome.done;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.created
                ? 'Account created — you are signed in as ${result.username}.'
                : 'Signed in as ${result.username}.',
          ),
        ),
      );
      // Back to wherever this was opened from (the Friends screen), which
      // now shows the username in its own header.
      if (context.canPop()) context.pop();
      return _SignInOutcome.done;
    } on AccountClientException catch (e) {
      // A 404 is only reachable on the first, no-create call, and it is
      // not a failure to report — it is the question this screen then
      // asks. (A server old enough to ignore `allowCreate` never sends
      // one, and behaves exactly as it did before this round.)
      if (e.statusCode == 404 && !allowCreate) {
        return _SignInOutcome.noSuchAccount;
      }
      if (mounted) setState(() => _error = _messageFor(e));
      return _SignInOutcome.failed;
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Could not sign in right now. Try again.');
      }
      return _SignInOutcome.failed;
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// Asks before an account exists, in the same dialog idiom the sign-out
  /// confirmation above uses. Names the username, since the whole point is
  /// giving the user a chance to notice it is not the one they meant.
  Future<bool?> _confirmCreate(String username) => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Create the account "$username"?'),
      content: const Text(
        'Nobody is using that username yet, so this would be a brand-new '
        'account, with no friends in it. If you already have an account, '
        'cancel and check the username for typos.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Create account'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Sign in or create an account',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            'Pick a username and a password. If the account is already '
            'yours, this device joins it and gets your friends. If nobody '
            'is using that username yet, Musicat asks before creating a '
            'new account.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _usernameController,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Username',
              hintText: '3 to 32 letters, numbers, - or _',
              prefixIcon: Icon(Icons.alternate_email),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _passwordController,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submitting ? null : _submit(),
            decoration: const InputDecoration(
              labelText: 'Password',
              prefixIcon: Icon(Icons.lock_outline),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _submitting ? null : _submit,
            child: _submitting
                ? const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Continue'),
          ),
          const SizedBox(height: 12),
          Text(
            'You can also add friends without an account, using an invite '
            'code or QR — signing in just means people can find you by '
            'username.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
