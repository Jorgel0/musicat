import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/soulseek/soulseek_client.dart';
import '../../settings/soulseek/presentation/soulseek_config_controller.dart';

class SearchState {
  const SearchState({
    this.query = '',
    this.results = const [],
    this.isSearching = false,
    this.errorMessage,
  });

  final String query;
  final List<SoulseekSearchResult> results;
  final bool isSearching;
  final String? errorMessage;
}

/// Drives a Soulseek search by polling [SoulseekClient.getSearch] — slskd
/// has no push/streaming endpoint, so this is how "live" results are
/// surfaced. See ADR 0010.
class SearchController extends Notifier<SearchState> {
  Timer? _pollTimer;

  @override
  SearchState build() {
    ref.onDispose(() => _pollTimer?.cancel());
    return const SearchState();
  }

  Future<void> search(String query) async {
    _pollTimer?.cancel();

    final client = ref.read(soulseekClientProvider);
    if (client == null) {
      state = const SearchState(
        errorMessage: 'Configure a Soulseek backend in Settings first.',
      );
      return;
    }

    state = SearchState(query: query, isSearching: true);

    final String searchId;
    try {
      searchId = await client.startSearch(query);
    } catch (e) {
      state = SearchState(query: query, errorMessage: e.toString());
      return;
    }

    // Deliberately not polled immediately: startSearch's POST is only
    // just being fired (unawaited) as this line runs, and slskd hasn't
    // necessarily created the search record yet — an immediate poll here
    // reliably 404s in practice. The first tick a second from now is
    // effectively always fast enough. See ADR 0010.
    _pollTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _poll(client, searchId),
    );
  }

  Future<void> _poll(SoulseekClient client, String searchId) async {
    try {
      final search = await client.getSearch(searchId);
      final stillSearching = search.state == SoulseekSearchState.inProgress;
      state = SearchState(
        query: state.query,
        results: search.results,
        isSearching: stillSearching,
      );
      if (!stillSearching) _pollTimer?.cancel();
    } catch (e) {
      _pollTimer?.cancel();
      state = SearchState(
        query: state.query,
        results: state.results,
        errorMessage: e.toString(),
      );
    }
  }

  void clear() {
    _pollTimer?.cancel();
    state = const SearchState();
  }
}

final searchControllerProvider =
    NotifierProvider<SearchController, SearchState>(SearchController.new);
