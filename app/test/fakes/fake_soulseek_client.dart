import 'package:musicat/core/network/soulseek/soulseek_client.dart';

/// In-memory [SoulseekClient] for tests — configure the canned responses a
/// test needs, then assert on [calls] to check the right methods were
/// invoked with the right arguments.
class FakeSoulseekClient implements SoulseekClient {
  final List<String> calls = [];

  bool connected = true;
  String nextSearchId = 'fake-search-id';
  Object? startSearchError;
  SoulseekSearch? searchResult;
  Object? getSearchError;
  Object? enqueueError;
  List<SoulseekTransfer> downloads = const [];
  String? downloadsDirectory;

  @override
  Future<bool> isConnected() async {
    calls.add('isConnected');
    return connected;
  }

  @override
  Future<String> startSearch(String query) async {
    calls.add('startSearch:$query');
    if (startSearchError != null) throw startSearchError!;
    return nextSearchId;
  }

  @override
  Future<SoulseekSearch> getSearch(String searchId) async {
    calls.add('getSearch:$searchId');
    if (getSearchError != null) throw getSearchError!;
    return searchResult ??
        SoulseekSearch(
          id: searchId,
          query: '',
          state: SoulseekSearchState.completed,
          results: const [],
        );
  }

  @override
  Future<void> cancelSearch(String searchId) async {
    calls.add('cancelSearch:$searchId');
  }

  @override
  Future<void> enqueueDownload({
    required String username,
    required List<SoulseekFile> files,
  }) async {
    calls.add(
      'enqueueDownload:$username:${files.map((f) => f.filename).join(',')}',
    );
    if (enqueueError != null) throw enqueueError!;
  }

  @override
  Future<List<SoulseekTransfer>> getDownloads() async {
    calls.add('getDownloads');
    return downloads;
  }

  @override
  Future<void> cancelDownload({
    required String username,
    required String transferId,
  }) async {
    calls.add('cancelDownload:$username:$transferId');
  }

  @override
  Future<String?> getDownloadsDirectory() async {
    calls.add('getDownloadsDirectory');
    return downloadsDirectory;
  }
}
