import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/soulseek/soulseek_client.dart';
import '../../settings/soulseek/presentation/soulseek_config_controller.dart';
import 'downloads_controller.dart';

class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(soulseekClientProvider);
    final state = ref.watch(downloadsControllerProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Downloads')),
      body: _buildBody(context, client, state),
    );
  }

  Widget _buildBody(
    BuildContext context,
    SoulseekClient? client,
    DownloadsState state,
  ) {
    if (client == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'No Soulseek backend configured yet.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => context.push('/settings/soulseek'),
                child: const Text('Set up in Settings'),
              ),
            ],
          ),
        ),
      );
    }

    if (state.errorMessage != null && state.transfers.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(state.errorMessage!, textAlign: TextAlign.center),
        ),
      );
    }

    if (state.transfers.isEmpty) {
      return const Center(child: Text('No downloads yet.'));
    }

    return ListView.builder(
      itemCount: state.transfers.length,
      itemBuilder: (context, index) =>
          _TransferTile(transfer: state.transfers[index]),
    );
  }
}

class _TransferTile extends ConsumerWidget {
  const _TransferTile({required this.transfer});

  final SoulseekTransfer transfer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canCancel =
        transfer.state == SoulseekTransferState.queued ||
        transfer.state == SoulseekTransferState.inProgress;

    return ListTile(
      leading: Icon(_stateIcon(transfer.state)),
      title: Text(
        _basename(transfer.filename),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_statusLine(transfer)),
          if (transfer.state == SoulseekTransferState.inProgress)
            LinearProgressIndicator(
              value: transfer.sizeBytes == 0
                  ? null
                  : transfer.bytesTransferred / transfer.sizeBytes,
            ),
        ],
      ),
      trailing: canCancel
          ? IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => ref
                  .read(downloadsControllerProvider.notifier)
                  .cancel(transfer),
            )
          : null,
    );
  }
}

IconData _stateIcon(SoulseekTransferState state) {
  return switch (state) {
    SoulseekTransferState.queued => Icons.schedule,
    SoulseekTransferState.inProgress => Icons.downloading,
    SoulseekTransferState.succeeded => Icons.check_circle_outline,
    SoulseekTransferState.failed => Icons.error_outline,
    SoulseekTransferState.cancelled => Icons.cancel_outlined,
  };
}

String _statusLine(SoulseekTransfer transfer) {
  return switch (transfer.state) {
    SoulseekTransferState.queued =>
      transfer.placeInQueue != null
          ? 'Queued (#${transfer.placeInQueue})'
          : 'Queued',
    SoulseekTransferState.inProgress =>
      '${_percent(transfer)}% • ${_formatBytes(transfer.bytesTransferred)} / '
          '${_formatBytes(transfer.sizeBytes)}',
    SoulseekTransferState.succeeded => 'Completed',
    SoulseekTransferState.failed => 'Failed',
    SoulseekTransferState.cancelled => 'Cancelled',
  };
}

int _percent(SoulseekTransfer transfer) {
  if (transfer.sizeBytes == 0) return 0;
  return (transfer.bytesTransferred / transfer.sizeBytes * 100).round();
}

String _formatBytes(int bytes) {
  final mb = bytes / (1024 * 1024);
  return '${mb.toStringAsFixed(1)} MB';
}

String _basename(String remotePath) {
  final normalized = remotePath.replaceAll('\\', '/');
  return normalized.split('/').last;
}
