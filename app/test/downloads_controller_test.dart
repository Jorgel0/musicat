import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicat/core/network/soulseek/soulseek_client.dart';
import 'package:musicat/features/downloads/presentation/downloads_controller.dart';
import 'package:musicat/features/library/data/library_scanner.dart';
import 'package:musicat/features/library/domain/track.dart';
import 'package:musicat/features/library/presentation/library_providers.dart';
import 'package:musicat/features/settings/soulseek/presentation/soulseek_config_controller.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'fakes/fake_library_repository.dart';
import 'fakes/fake_soulseek_client.dart';

/// `getApplicationSupportDirectory()` (used by [LibraryScanner] for cover
/// art extraction) normally goes through a platform channel; `flutter
/// test` has no native side to answer it. See library_scanner_test.dart.
class _TempDirPathProvider extends PathProviderPlatform {
  _TempDirPathProvider(this._path);
  final String _path;

  @override
  Future<String?> getApplicationSupportPath() async => _path;
}

const _transfer = SoulseekTransfer(
  id: 't1',
  username: 'someone',
  filename: 'a.flac',
  sizeBytes: 100,
  bytesTransferred: 50,
  state: SoulseekTransferState.inProgress,
);

const _succeededTransfer = SoulseekTransfer(
  id: 't2',
  username: 'someone',
  filename: 'b.flac',
  sizeBytes: 100,
  bytesTransferred: 100,
  state: SoulseekTransferState.succeeded,
);

class _TrackingLibraryRepository extends FakeEmptyLibraryRepository {
  int upsertCount = 0;

  @override
  Future<void> upsertTrack({
    required String filePath,
    required String title,
    required String artist,
    required String album,
    required TrackSource source,
    int? trackNumber,
    Duration? duration,
    String? coverArtPath,
  }) async {
    upsertCount++;
  }
}

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

  group('auto-import', () {
    late _TrackingLibraryRepository repository;
    late String fixtureDir;
    late Directory supportDir;

    setUp(() {
      repository = _TrackingLibraryRepository();
      fixtureDir = p.join(
        Directory.current.path,
        'test',
        'fixtures',
        'sample_library',
      );
      supportDir = Directory.systemTemp.createTempSync('musicat_test_');
      PathProviderPlatform.instance = _TempDirPathProvider(supportDir.path);
    });

    tearDown(() => supportDir.deleteSync(recursive: true));

    ProviderContainer containerWithScanner() {
      return ProviderContainer(
        overrides: [
          soulseekClientProvider.overrideWithValue(client),
          libraryRepositoryProvider.overrideWithValue(repository),
          libraryScannerProvider.overrideWithValue(
            LibraryScanner(repository, tagReader: (_) async => null),
          ),
        ],
      );
    }

    test('rescans the directory the backend reports when a transfer newly '
        'succeeds — no user configuration needed', () async {
      client.downloadsDirectory = fixtureDir;
      client.downloads = [_succeededTransfer];
      final localContainer = containerWithScanner();
      addTearDown(localContainer.dispose);

      final subscription = localContainer.listen(
        downloadsControllerProvider,
        (a, b) {},
      );
      addTearDown(subscription.close);

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(repository.upsertCount, greaterThan(0));
    });

    test('does not rescan when the reported directory does not exist here '
        '(backend running on a different device)', () async {
      client.downloadsDirectory = '/no/such/directory/on/this/machine';
      client.downloads = [_succeededTransfer];
      final localContainer = containerWithScanner();
      addTearDown(localContainer.dispose);

      final subscription = localContainer.listen(
        downloadsControllerProvider,
        (a, b) {},
      );
      addTearDown(subscription.close);

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(repository.upsertCount, 0);
    });

    test('does not rescan when the backend reports no directory', () async {
      client.downloadsDirectory = null;
      client.downloads = [_succeededTransfer];
      final localContainer = containerWithScanner();
      addTearDown(localContainer.dispose);

      final subscription = localContainer.listen(
        downloadsControllerProvider,
        (a, b) {},
      );
      addTearDown(subscription.close);

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(repository.upsertCount, 0);
    });

    test(
      'does not rescan again for a transfer already seen as succeeded',
      () async {
        client.downloadsDirectory = fixtureDir;
        client.downloads = [_succeededTransfer];
        final localContainer = containerWithScanner();
        addTearDown(localContainer.dispose);

        final subscription = localContainer.listen(
          downloadsControllerProvider,
          (a, b) {},
        );
        addTearDown(subscription.close);

        await Future<void>.delayed(const Duration(milliseconds: 50));
        final countAfterFirstImport = repository.upsertCount;
        expect(countAfterFirstImport, greaterThan(0));

        await Future<void>.delayed(const Duration(milliseconds: 2200));

        expect(repository.upsertCount, countAfterFirstImport);
      },
    );
  });
}
