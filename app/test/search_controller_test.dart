import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicat/core/network/soulseek/soulseek_client.dart';
import 'package:musicat/features/search/presentation/search_controller.dart';
import 'package:musicat/features/settings/soulseek/presentation/soulseek_config_controller.dart';

import 'fakes/fake_soulseek_client.dart';

const _file = SoulseekFile(filename: 'a.flac', sizeBytes: 100);
const _result = SoulseekSearchResult(
  username: 'someone',
  hasFreeUploadSlot: true,
  queueLength: 0,
  uploadSpeedBytesPerSecond: 1000,
  files: [_file],
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

  test('reports an error when no backend is configured', () async {
    final noBackendContainer = ProviderContainer(
      overrides: [soulseekClientProvider.overrideWithValue(null)],
    );
    addTearDown(noBackendContainer.dispose);

    await noBackendContainer
        .read(searchControllerProvider.notifier)
        .search('daft punk');

    final state = noBackendContainer.read(searchControllerProvider);
    expect(state.errorMessage, isNotNull);
    expect(client.calls, isEmpty);
  });

  test('surfaces an error from startSearch without polling', () async {
    client.startSearchError = const SoulseekNotConnectedException('offline');

    await container.read(searchControllerProvider.notifier).search('q');

    final state = container.read(searchControllerProvider);
    expect(state.errorMessage, contains('offline'));
    expect(client.calls, ['startSearch:q']);
  });

  test('polls until the search completes, then stops', () async {
    client.searchResult = const SoulseekSearch(
      id: 'fake-search-id',
      query: 'daft punk',
      state: SoulseekSearchState.inProgress,
      results: [_result],
    );

    await container.read(searchControllerProvider.notifier).search('daft punk');

    // The first poll happens on the periodic timer's first tick, not
    // immediately (see search_controller.dart for why).
    await Future<void>.delayed(const Duration(milliseconds: 1200));

    var state = container.read(searchControllerProvider);
    expect(state.isSearching, isTrue);
    expect(state.results, [_result]);

    client.searchResult = const SoulseekSearch(
      id: 'fake-search-id',
      query: 'daft punk',
      state: SoulseekSearchState.completed,
      results: [_result],
    );

    // Let the 1s poll timer fire at least once more.
    await Future<void>.delayed(const Duration(milliseconds: 1200));

    state = container.read(searchControllerProvider);
    expect(state.isSearching, isFalse);

    final pollCountAtCompletion = client.calls
        .where((c) => c.startsWith('getSearch'))
        .length;

    // No further polling once completed.
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(
      client.calls.where((c) => c.startsWith('getSearch')).length,
      pollCountAtCompletion,
    );
  });

  test('clear() cancels polling and resets state', () async {
    client.searchResult = const SoulseekSearch(
      id: 'fake-search-id',
      query: 'q',
      state: SoulseekSearchState.inProgress,
      results: [],
    );

    final notifier = container.read(searchControllerProvider.notifier);
    await notifier.search('q');
    notifier.clear();

    final pollCountAtClear = client.calls
        .where((c) => c.startsWith('getSearch'))
        .length;

    await Future<void>.delayed(const Duration(milliseconds: 1200));

    expect(container.read(searchControllerProvider).query, isEmpty);
    expect(
      client.calls.where((c) => c.startsWith('getSearch')).length,
      pollCountAtClear,
    );
  });
}
