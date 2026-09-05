import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/federation/account_client.dart';
import 'account_controller.dart';

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
          data: (account) => account == null
              ? const _SignInForm()
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
  /// that matters most is the last: a service problem must never read as
  /// "you got your password wrong", which is what a single generic error
  /// message would leave them believing.
  static String _messageFor(AccountClientException e) => switch (e.statusCode) {
    401 =>
      'That password does not match this username. If the account is not '
          'yours, choose a different username.',
    429 =>
      'Too many attempts for that username. Wait about a minute, then try '
          'again.',
    400 =>
      'Choose a username of 3 to 32 characters, using only letters, '
          'numbers, - or _.',
    502 || 503 =>
      'Accounts are not available right now — this is not a problem with '
          'your password. Try again in a moment.',
    _ => 'Could not sign in right now. Try again in a moment.',
  };

  Future<void> _submit() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() => _error = 'Enter a username and a password.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(accountSessionProvider.notifier)
          .signIn(username: username, password: password);
      if (!mounted) return;
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
    } on AccountClientException catch (e) {
      setState(() => _error = _messageFor(e));
    } catch (e) {
      setState(() => _error = 'Could not sign in right now. Try again.');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

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
            'Pick a username and a password. If the username is free, the '
            'account is created for you; if it is already yours, this '
            'device joins it and gets your friends.',
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
