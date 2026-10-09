import 'package:flutter_test/flutter_test.dart';
import 'package:music_app/services/dynamic_artist_service.dart';
import 'package:music_app/services/canonical_song_dedup.dart';

void main() {
  group('Player Screen View Artist Feature Tests', () {
    final artistService = DynamicArtistService();

    String resolveArtistName(String rawTitle, String rawAuthor) {
      final direct = rawAuthor.trim();

      // 1. Direct match with curated artist catalog or aliases
      if (direct.isNotEmpty && direct.toLowerCase() != 'unknown artist') {
        final directMatch = artistService.findArtist(direct);
        if (directMatch != null) return directMatch.name;
      }

      // 2. Extract artist candidate from song title / context keywords
      final ctx = CanonicalSongDedup.extractSongContext(rawTitle, rawAuthor);
      final ctxArtist = (ctx['artist'] as String?)?.trim() ?? '';
      if (ctxArtist.isNotEmpty) {
        final ctxMatch = artistService.findArtist(ctxArtist);
        if (ctxMatch != null) return ctxMatch.name;

        final lowerAuthor = direct.toLowerCase();
        if (lowerAuthor.isEmpty ||
            lowerAuthor.contains('music') ||
            lowerAuthor.contains('records') ||
            lowerAuthor.contains('series') ||
            lowerAuthor.contains('channel') ||
            lowerAuthor.contains('media') ||
            lowerAuthor.contains('studios') ||
            lowerAuthor.contains('audio') ||
            lowerAuthor.contains('label') ||
            lowerAuthor.contains('company')) {
          return ctxArtist;
        }
      }

      // 3. Fallback to direct author if non-empty, otherwise ctxArtist or 'Unknown Artist'
      if (direct.isNotEmpty && direct.toLowerCase() != 'unknown artist') {
        return direct;
      }
      if (ctxArtist.isNotEmpty) {
        return ctxArtist;
      }
      return 'Unknown Artist';
    }

    test('Resolves direct curated artist correctly', () {
      final resolved = resolveArtistName('Naa Ready', 'Anirudh Ravichander');
      expect(resolved, 'Anirudh Ravichander');
      final item = artistService.findArtist(resolved);
      expect(item, isNotNull);
      expect(item!.name, 'Anirudh Ravichander');
    });

    test('Resolves alias artist correctly to canonical name', () {
      final resolved = resolveArtistName('Samajavaragamana', 'DSP');
      expect(resolved, 'Devi Sri Prasad');
      final item = artistService.findArtist(resolved);
      expect(item, isNotNull);
      expect(item!.name, 'Devi Sri Prasad');
    });

    test(
      'Resolves record label channel by extracting artist from title context',
      () {
        final resolved = resolveArtistName(
          'Chuttamalle Video Song | Devara | Jr NTR | Janhvi Kapoor | Anirudh',
          'T-Series Telugu',
        );
        expect(resolved, 'Anirudh Ravichander');
        final item = artistService.findArtist(resolved);
        expect(item, isNotNull);
        expect(item!.name, 'Anirudh Ravichander');
      },
    );

    test('Preserves non-curated indie or international artist cleanly', () {
      final resolved = resolveArtistName('Blinding Lights', 'The Weeknd');
      expect(resolved, 'The Weeknd');
    });

    test('Handles empty author and falls back gracefully without throwing', () {
      final resolved = resolveArtistName('Random Track', '');
      expect(resolved.isNotEmpty, isTrue);
    });

    test('Handles unknown author cleanly', () {
      final resolved = resolveArtistName('Unknown Track', 'Unknown Artist');
      expect(resolved.isNotEmpty, isTrue);
    });
  });
}
