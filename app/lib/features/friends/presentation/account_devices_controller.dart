import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/federation/account_client.dart';
import 'account_controller.dart';
import 'musicat_server_config_controller.dart';

/// The devices linked to this account, and the one action that changes the
/// list: unlinking one (server ADR 0048/0056).
///
/// An [AsyncNotifier] whose `build()` *is* the fetch, exactly like
/// [AccountSessionController] — no widget ever kicks this off from a
/// lifecycle callback, which is the crash this project has shipped three
/// times (ADR 0037/0039).
///
/// `autoDispose`, and that is the whole caching policy: the list is read
/// when the devices screen opens and thrown away when it closes. Nothing
/// keeps a copy, because the question this list answers is "which of these
/// do I revoke", and answering it from a minute-old snapshot is how
/// somebody revokes the wrong device. This device's server takes the same
/// position and refuses to serve a cached list at all.
class AccountDevicesController extends AsyncNotifier<List<AccountDevice>> {
  @override
  Future<List<AccountDevice>> build() async {
    final client = ref.watch(accountClientProvider);
    if (client == null) {
      throw const AccountClientException(0, 'Musicat Server not configured');
    }
    return client.listDevices();
  }

  /// Asks again. The only way this list is ever refreshed: there is no
  /// timer, and (see the provider below) no retry on failure either.
  Future<void> refresh() async {
    final client = ref.read(accountClientProvider);
    if (client == null) return;
    state = await AsyncValue.guard(client.listDevices);
  }

  /// Unlinks [nodeId] from the account and returns whether that signed
  /// *this* device out — which the server says outright, so nothing here
  /// infers it by comparing ids.
  ///
  /// On a self-unlink the session is already gone server-side, so this
  /// re-reads it rather than leaving the app in a signed-in shell whose
  /// every account call would now fail. On unlinking any other device it
  /// re-reads the list instead, since that is what changed.
  ///
  /// Lets [AccountClientException] out: the caller has to tell "nothing was
  /// unlinked, try again" apart from the rest, and swallowing it here would
  /// leave it nothing to tell them apart with.
  Future<bool> unlink(String nodeId) async {
    final client = ref.read(accountClientProvider);
    if (client == null) {
      throw const AccountClientException(0, 'Musicat Server not configured');
    }
    final signedOut = await client.unlinkDevice(nodeId);
    if (signedOut) {
      ref.read(accountSessionProvider.notifier).reload();
    } else {
      await refresh();
    }
    return signedOut;
  }
}

final accountDevicesProvider =
    AsyncNotifierProvider.autoDispose<
      AccountDevicesController,
      List<AccountDevice>
    >(
      AccountDevicesController.new,
      // Same reasoning as the account providers: Riverpod's default is to
      // re-run a failed provider on a backoff timer, which here would be an
      // invisible stream of calls to the account service from a screen that
      // is only ever open because somebody is looking at it. The failure is
      // shown with a "Try again" next to it, and retrying is something the
      // user asks for.
      retry: (retryCount, error) => null,
    );
