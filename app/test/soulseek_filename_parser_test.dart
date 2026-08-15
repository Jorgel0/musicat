import 'package:flutter_test/flutter_test.dart';
import 'package:musicat/core/network/soulseek/soulseek_filename_parser.dart';

void main() {
  group('parseSoulseekFilename', () {
    test('parses a clean "Artist - Album (Year)" folder', () {
      final parsed = parseSoulseekFilename(
        r'@@user\Music\Daft Punk - Discovery (2001)\03 - Digital Love.mp3',
      );

      expect(parsed.artist, 'Daft Punk');
      expect(parsed.album, 'Discovery');
      expect(parsed.title, 'Digital Love');
    });

    test('handles forward slashes too', () {
      final parsed = parseSoulseekFilename(
        'Music/Daft Punk - Discovery (2001)/03 - Digital Love.mp3',
      );

      expect(parsed.artist, 'Daft Punk');
      expect(parsed.album, 'Discovery');
      expect(parsed.title, 'Digital Love');
    });

    test('falls back to Unknown artist when the folder has no separator', () {
      final parsed = parseSoulseekFilename(
        r'@@user\Music\lcd soundsystem (2005) lcd soundsystem\01 - daft punk is playing at my house.mp3',
      );

      expect(parsed.artist, 'Unknown artist');
      expect(parsed.album, 'lcd soundsystem  lcd soundsystem');
      expect(parsed.title, 'daft punk is playing at my house');
    });

    test('strips various leading track-number formats', () {
      expect(parseSoulseekFilename(r'@@u\A - B\01. Track.mp3').title, 'Track');
      expect(parseSoulseekFilename(r'@@u\A - B\01_Track.mp3').title, 'Track');
      expect(parseSoulseekFilename(r'@@u\A - B\1 Track.mp3').title, 'Track');
    });

    test('falls back to Unknown album when there is no folder at all', () {
      final parsed = parseSoulseekFilename('track.mp3');

      expect(parsed.artist, 'Unknown artist');
      expect(parsed.album, 'Unknown album');
      expect(parsed.title, 'track');
    });
  });
}
