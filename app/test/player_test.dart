import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicat/core/audio/audio_providers.dart';
import 'package:musicat/features/library/domain/track.dart';
import 'package:musicat/features/player/presentation/mini_player.dart';
import 'package:musicat/features/player/presentation/now_playing_screen.dart';
import 'package:musicat/features/player/presentation/player_providers.dart';

import 'fakes/fake_audio_player_controller.dart';

Track _track(int id, String title) => Track(
  id: id,
  filePath: '/music/$id.mp3',
  title: title,
  artist: 'Artist $id',
  album: 'Album $id',
  source: TrackSource.local,
);

void main() {
  late FakeAudioPlayerController controller;

  setUp(() {
    controller = FakeAudioPlayerController();
  });

  ProviderScope wrap(Widget child) => ProviderScope(
    overrides: [audioPlayerControllerProvider.overrideWithValue(controller)],
    child: MaterialApp(home: Scaffold(body: child)),
  );

  test('currentTrackProvider is null until a queue is set', () {
    final container = ProviderContainer(
      overrides: [audioPlayerControllerProvider.overrideWithValue(controller)],
    );
    addTearDown(container.dispose);

    expect(container.read(currentTrackProvider), isNull);
  });

  test('currentTrackProvider reflects the queue and current index', () async {
    final container = ProviderContainer(
      overrides: [audioPlayerControllerProvider.overrideWithValue(controller)],
    );
    addTearDown(container.dispose);

    // Establish subscriptions before emitting, as a real widget tree would.
    container.listen(currentTrackProvider, (_, _) {});

    await controller.setQueue([_track(1, 'Song One'), _track(2, 'Song Two')]);
    await Future<void>.delayed(Duration.zero);

    expect(container.read(currentTrackProvider)?.title, 'Song One');

    await controller.skipToNext();
    await Future<void>.delayed(Duration.zero);

    expect(container.read(currentTrackProvider)?.title, 'Song Two');
  });

  testWidgets('MiniPlayer renders nothing when no track is queued', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const MiniPlayer()));
    await tester.pump();

    expect(find.byType(MiniPlayer), findsOneWidget);
    expect(find.text('Song One'), findsNothing);
  });

  testWidgets('MiniPlayer shows the current track and toggles play/pause', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const MiniPlayer()));
    await controller.setQueue([_track(1, 'Song One')]);
    await tester.pump();
    await tester.pump();

    expect(find.text('Song One'), findsOneWidget);
    expect(find.text('Artist 1'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();

    expect(controller.calls, contains('play'));
    expect(find.byIcon(Icons.pause), findsOneWidget);
  });

  testWidgets('NowPlayingScreen wires shuffle and repeat buttons', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const NowPlayingScreen()));
    await controller.setQueue([_track(1, 'Song One')]);
    await tester.pump();
    await tester.pump();

    expect(find.text('Song One'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.shuffle));
    await tester.pump();
    expect(controller.calls, contains('setShuffleModeEnabled'));

    await tester.tap(find.byIcon(Icons.repeat));
    await tester.pump();
    expect(controller.calls, contains('setRepeat'));
  });

  testWidgets(
    'NowPlayingScreen shows a volume slider on desktop and wires it',
    (tester) async {
      await tester.pumpWidget(wrap(const NowPlayingScreen()));
      await controller.setQueue([_track(1, 'Song One')]);
      await tester.pump();
      await tester.pump();

      // The seek bar is also a Slider — the volume control is the second
      // one, gated to desktop platforms (see ADR 0014); this test only
      // runs on desktop hosts (this dev machine, CI's Linux runner).
      final sliders = find.byType(Slider);
      expect(sliders, findsNWidgets(2));

      final volumeSlider = tester.widget<Slider>(sliders.last);
      volumeSlider.onChanged!(0.5);
      await tester.pump();

      expect(controller.calls, contains('setVolume'));
    },
  );
}
