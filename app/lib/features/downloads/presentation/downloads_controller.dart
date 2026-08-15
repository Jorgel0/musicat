import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/soulseek/soulseek_client.dart';
import '../../library/presentation/library_providers.dart';
import '../../settings/soulseek/presentation/soulseek_config_controller.dart';

class DownloadsState {
  const DownloadsState({this.transfers = const [], this.errorMessage});

  final List<SoulseekTransfer> transfers;
  final String? errorMessage;
}

/// Polls [SoulseekClient.getDownloads] while the Downloads screen is on
/// screen — same reasoning as [SearchController]: slskd has no push
/// endpoint for transfer progress. Scoped `autoDispose` so this stops
/// polling the backend once the user navigates away.
///
/// Also asks the backend where it saves completed downloads
/// ([SoulseekClient.getDownloadsDirectory]) and, whenever that directory
/// actually exists on this device (slskd running locally — see ADR 0013),
/// rescans it whenever a transfer newly finishes, so completed downloads
/// land in the library without a manual "Add folder" rescan. No user
/// configuration needed: if the reported directory doesn't exist here
/// (slskd running on a separate machine), auto-import just stays off.
class DownloadsController extends Notifier<DownloadsState> {
  Timer? _pollTimer;
  final Set<String> _knownSucceededIds = {};
  String? _downloadsDirectory;

  @override
  DownloadsState build() {
    ref.onDispose(() => _pollTimer?.cancel());

    final client = ref.watch(soulseekClientProvider);
    if (client != null) {
      unawaited(_loadDownloadsDirectory(client));
      unawaited(_poll(client));
      _pollTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _poll(client),
      );
    }
    return const DownloadsState();
  }

  Future<void> _loadDownloadsDirectory(SoulseekClient client) async {
    _downloadsDirectory = await client.getDownloadsDirectory();
  }

  Future<void> _poll(SoulseekClient client) async {
    try {
      final transfers = await client.getDownloads();
      state = DownloadsState(transfers: transfers);
      await _importNewlySucceeded(transfers);
    } catch (e) {
      state = DownloadsState(
        transfers: state.transfers,
        errorMessage: e.toString(),
      );
    }
  }

  Future<void> _importNewlySucceeded(List<SoulseekTransfer> transfers) async {
    final directory = _downloadsDirectory;
    if (directory == null || !Directory(directory).existsSync()) return;

    final succeededIds = transfers
        .where((t) => t.state == SoulseekTransferState.succeeded)
        .map((t) => t.id)
        .toSet();
    final newlySucceeded = succeededIds.difference(_knownSucceededIds);
    _knownSucceededIds
      ..clear()
      ..addAll(succeededIds);

    if (newlySucceeded.isEmpty) return;
    await ref.read(libraryScannerProvider).scanFolder(directory);
  }

  Future<void> cancel(SoulseekTransfer transfer) async {
    final client = ref.read(soulseekClientProvider);
    if (client == null) return;
    await client.cancelDownload(
      username: transfer.username,
      transferId: transfer.id,
    );
    await _poll(client);
  }
}

final downloadsControllerProvider =
    NotifierProvider.autoDispose<DownloadsController, DownloadsState>(
      DownloadsController.new,
    );
