import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicat/features/search/presentation/cover_art_providers.dart';

import 'fakes/fake_cover_art_client.dart';

void main() {
  test('delegates to the overridden CoverArtClient', () async {
    final fakeClient = FakeCoverArtClient()
      ..nextUrl = 'https://example.com/a.jpg';
    final container = ProviderContainer(
      overrides: [coverArtClientProvider.overrideWithValue(fakeClient)],
    );
    addTearDown(container.dispose);

    final url = await container.read(
      coverArtUrlProvider((artist: 'Daft Punk', album: 'Discovery')).future,
    );

    expect(url, 'https://example.com/a.jpg');
    expect(fakeClient.calls, ['Daft Punk|Discovery']);
  });

  test('caches by (artist, album) instead of re-querying', () async {
    final fakeClient = FakeCoverArtClient()
      ..nextUrl = 'https://example.com/a.jpg';
    final container = ProviderContainer(
      overrides: [coverArtClientProvider.overrideWithValue(fakeClient)],
    );
    addTearDown(container.dispose);

    const key = (artist: 'Daft Punk', album: 'Discovery');
    await container.read(coverArtUrlProvider(key).future);
    await container.read(coverArtUrlProvider(key).future);

    expect(fakeClient.calls, ['Daft Punk|Discovery']);
  });
}
