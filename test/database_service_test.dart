import 'package:flutter_test/flutter_test.dart';
import 'package:music_app/services/database_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DatabaseService dbService;

  setUp(() {
    dbService = DatabaseService();
    dbService.resetForTest();
  });

  group('DatabaseService Tests', () {
    test('records play events and increments play count', () async {
      await dbService.recordPlay(
        songId: 'song_123',
        title: 'Master The Blaster',
        artist: 'Anirudh Ravichander',
        artworkUrl: 'https://example.com/art.jpg',
        durationSeconds: 210,
      );

      final count1 = await dbService.getPlayCount('song_123');
      expect(count1, equals(1));

      // Play same song again
      await dbService.recordPlay(
        songId: 'song_123',
        title: 'Master The Blaster',
        artist: 'Anirudh Ravichander',
      );

      final count2 = await dbService.getPlayCount('song_123');
      expect(count2, equals(2));

      final history = await dbService.getPlayHistory();
      expect(history.length, equals(1));
      expect(history.first['song_id'], equals('song_123'));
      expect(history.first['play_count'], equals(2));
      expect(history.first['title'], equals('Master The Blaster'));
    });

    test('toggles favorite and retrieves favorites list', () async {
      expect(await dbService.isFavorite('song_fav_1'), isFalse);

      final added = await dbService.toggleFavorite(
        songId: 'song_fav_1',
        title: 'Arabic Kuthu',
        artist: 'Anirudh Ravichander',
      );
      expect(added, isTrue);
      expect(await dbService.isFavorite('song_fav_1'), isTrue);

      final favs = await dbService.getFavorites();
      expect(favs.length, equals(1));
      expect(favs.first['title'], equals('Arabic Kuthu'));

      final removed = await dbService.toggleFavorite(
        songId: 'song_fav_1',
        title: 'Arabic Kuthu',
        artist: 'Anirudh Ravichander',
      );
      expect(removed, isFalse);
      expect(await dbService.isFavorite('song_fav_1'), isFalse);
      expect(await dbService.getFavorites(), isEmpty);
    });

    test('clears play history cleanly', () async {
      await dbService.recordPlay(
        songId: 'song_abc',
        title: 'Song ABC',
        artist: 'Artist',
      );
      expect(await dbService.getPlayHistory(), isNotEmpty);

      await dbService.clearPlayHistory();
      expect(await dbService.getPlayHistory(), isEmpty);
      expect(await dbService.getPlayCount('song_abc'), equals(0));
    });
  });
}
