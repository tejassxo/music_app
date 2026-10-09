import 'package:flutter_test/flutter_test.dart';
import 'package:music_app/services/fuzzy_search_service.dart';
import 'package:music_app/services/playlist_artist_filter.dart';

void main() {
  group('FuzzySearchService Tests', () {
    final sampleTracks = [
      {'id': '1', 'title': 'Kesariya', 'artist': 'Arijit Singh, Pritam'},
      {'id': '2', 'title': 'Srivalli', 'artist': 'Sid Sriram, DSP'},
      {
        'id': '3',
        'title': 'Naa Ready',
        'artist': 'Anirudh Ravichander, Thalapathy Vijay',
      },
      {'id': '4', 'title': 'Save Your Tears', 'artist': 'The Weeknd'},
      {'id': '5', 'title': 'Blinding Lights', 'artist': 'The Weeknd'},
      {'id': '6', 'title': 'Levitating', 'artist': 'Dua Lipa'},
    ];

    test('searchTrackMaps finds exact and phonetic matches with typos', () {
      // 1. Misspelled "Arijit" as "arjit"
      final result1 = FuzzySearchService.searchTrackMaps(sampleTracks, 'arjit');
      expect(result1.isNotEmpty, isTrue);
      expect(result1.first['title'], equals('Kesariya'));

      // 2. Misspelled "Kesariya" as "kesaria"
      final result2 = FuzzySearchService.searchTrackMaps(
        sampleTracks,
        'kesaria',
      );
      expect(result2.isNotEmpty, isTrue);
      expect(result2.first['title'], equals('Kesariya'));

      // 3. Misspelled "Anirudh" as "anirud"
      final result3 = FuzzySearchService.searchTrackMaps(
        sampleTracks,
        'anirud',
      );
      expect(result3.isNotEmpty, isTrue);
      expect(result3.first['title'], equals('Naa Ready'));

      // 4. Misspelled "Srivalli" as "srivali"
      final result4 = FuzzySearchService.searchTrackMaps(
        sampleTracks,
        'srivali',
      );
      expect(result4.isNotEmpty, isTrue);
      expect(result4.first['title'], equals('Srivalli'));
    });

    test(
      'searchTrackMaps returns full list on empty query and empty list on empty tracks',
      () {
        final resEmpty = FuzzySearchService.searchTrackMaps(
          sampleTracks,
          '   ',
        );
        expect(resEmpty.length, equals(sampleTracks.length));

        final resNoTracks = FuzzySearchService.searchTrackMaps([], 'kesariya');
        expect(resNoTracks, isEmpty);
      },
    );

    test(
      'PlaylistArtistFilter utilizes FuzzySearchService for typo-tolerant fallback',
      () {
        // Strict match for "srivali" would yield 0, but fuzzy fallback catches it!
        final result = PlaylistArtistFilter.searchPlaylist(
          songs: sampleTracks,
          query: 'srivali',
        );

        expect(result.matchedIndices.isNotEmpty, isTrue);
        expect(
          sampleTracks[result.matchedIndices.first]['title'],
          equals('Srivalli'),
        );
      },
    );
  });
}
