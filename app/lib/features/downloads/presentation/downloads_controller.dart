import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/soulseek/soulseek_client.dart';
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
class DownloadsController extends Notifier<DownloadsState> {
  Timer? _pollTimer;

  @override
  DownloadsState build() {
    ref.onDispose(() => _pollTimer?.cancel());

    final client = ref.watch(soulseekClientProvider);
    if (client != null) {
      unawaited(_poll(client));
      _pollTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _poll(client),
      );
    }
    return const DownloadsState();
  }

  Future<void> _poll(SoulseekClient client) async {
    try {
      final transfers = await client.getDownloads();
      state = DownloadsState(transfers: transfers);
    } catch (e) {
      state = DownloadsState(
        transfers: state.transfers,
        errorMessage: e.toString(),
      );
    }
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
