import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicat/core/network/soulseek/soulseek_client.dart';
import 'package:musicat/features/downloads/presentation/downloads_controller.dart';
import 'package:musicat/features/settings/soulseek/presentation/soulseek_config_controller.dart';

import 'fakes/fake_soulseek_client.dart';

const _transfer = SoulseekTransfer(
  id: 't1',
  username: 'someone',
  filename: 'a.flac',
  sizeBytes: 100,
  bytesTransferred: 50,
  state: SoulseekTransferState.inProgress,
);

void main() {
  late FakeSoulseekClient client;
  late ProviderContainer container;

  setUp(() {
    client = FakeSoulseekClient();
    container = ProviderContainer(
      overrides: [soulseekClientProvider.overrideWithValue(client)],
    );
  });

  tearDown(() => container.dispose());

  test('does nothing when no backend is configured', () {
    final noBackendContainer = ProviderContainer(
      overrides: [soulseekClientProvider.overrideWithValue(null)],
    );
    addTearDown(noBackendContainer.dispose);

    final state = noBackendContainer.read(downloadsControllerProvider);

    expect(state.transfers, isEmpty);
  });

  test('polls immediately, then periodically', () async {
    client.downloads = [_transfer];

    // autoDispose providers tear down once nothing is listening — a bare
    // .read() doesn't keep it alive, so the poll's later `state =` write
    // would land on an already-disposed (and silently rebuilt) instance.
    // A real widget's ref.watch plays the role this listener does here.
    final subscription = container.listen(
      downloadsControllerProvider,
      (a, b) {},
    );
    addTearDown(subscription.close);

    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(container.read(downloadsControllerProvider).transfers, [_transfer]);
    final firstPollCount = client.calls
        .where((c) => c == 'getDownloads')
        .length;
    expect(firstPollCount, greaterThanOrEqualTo(1));

    await Future<void>.delayed(const Duration(milliseconds: 2200));

    expect(
      client.calls.where((c) => c == 'getDownloads').length,
      greaterThan(firstPollCount),
    );
  });

  test('cancel() calls cancelDownload and refreshes', () async {
    client.downloads = [_transfer];
    final subscription = container.listen(
      downloadsControllerProvider,
      (a, b) {},
    );
    addTearDown(subscription.close);

    await Future<void>.delayed(const Duration(milliseconds: 50));

    await container
        .read(downloadsControllerProvider.notifier)
        .cancel(_transfer);

    expect(client.calls, contains('cancelDownload:someone:t1'));
  });
}
