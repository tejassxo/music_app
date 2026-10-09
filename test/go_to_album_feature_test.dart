import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_app/models/jio_album.dart';
import 'package:music_app/screens/album_screen.dart';
import 'package:music_app/services/music_service.dart';

void main() {
  group('Go to Album Feature Tests', () {
    test(
      'extractMovieOrAlbumTitle correctly extracts film/soundtrack names',
      () {
        expect(
          MusicService.extractMovieOrAlbumTitle('Samayama (From "Hi Nanna")'),
          'Hi Nanna',
        );
        expect(
          MusicService.extractMovieOrAlbumTitle(
            "Ammayi (From 'ANIMAL') [Telugu]",
          ),
          'ANIMAL',
        );
        expect(
          MusicService.extractMovieOrAlbumTitle(
            'Devara Thandavam (From "Devara Part 1")',
          ),
          'Devara Part 1',
        );
        expect(
          MusicService.extractMovieOrAlbumTitle('LEO - Naa Ready Song Video'),
          'LEO',
        );
        expect(
          MusicService.extractMovieOrAlbumTitle('Pure Independent Single'),
          isNull,
        );
      },
    );

    test(
      'registerSongAlbum and getCachedAlbum / getCachedAlbumTitle cache correctly',
      () {
        const songId = 'test_song_123';
        const albumTitle = 'Pushpa 2 The Rule';
        const albumId = 'jio_album_pushpa2';

        const testAlbum = JioAlbum(
          id: albumId,
          title: albumTitle,
          artist: 'Devi Sri Prasad',
          artwork: 'https://example.com/art.jpg',
          year: '2024',
          songCount: 6,
          language: 'telugu',
          songs: [
            {
              'id': songId,
              'title': 'Pushpa Pushpa',
              'author': 'Devi Sri Prasad',
              'thumbnail': 'https://example.com/art.jpg',
            },
          ],
        );

        MusicService.registerSongAlbum(
          songId,
          albumTitle: albumTitle,
          albumId: albumId,
          album: testAlbum,
        );

        expect(MusicService.getCachedAlbumTitle(songId), albumTitle);
        expect(MusicService.getCachedAlbumId(songId), albumId);
        expect(MusicService.getCachedAlbum(songId)?.id, albumId);
        expect(MusicService.getCachedAlbum(songId)?.songs.length, 1);
      },
    );

    test('albumSongsToVideos registers album metadata for all tracks', () {
      final music = MusicService();
      const testAlbum = JioAlbum(
        id: 'album_devara_99',
        title: 'Devara',
        artist: 'Anirudh Ravichander',
        artwork: 'https://example.com/devara.jpg',
        year: '2024',
        songCount: 2,
        language: 'telugu',
        songs: [
          {
            'id': 'devara_track_1',
            'title': 'Fear Song',
            'author': 'Anirudh',
            'thumbnail': 'https://example.com/devara.jpg',
            'duration': 190,
          },
          {
            'id': 'devara_track_2',
            'title': 'Chuttamalle',
            'author': 'Anirudh, Shilpa Rao',
            'thumbnail': 'https://example.com/devara.jpg',
            'duration': 210,
          },
        ],
      );

      final videos = music.albumSongsToVideos(testAlbum);
      expect(videos.length, 2);

      // Verify each track was registered in album cache
      for (final v in videos) {
        expect(MusicService.getCachedAlbumTitle(v.id.value), 'Devara');
        expect(MusicService.getCachedAlbumId(v.id.value), 'album_devara_99');
        expect(MusicService.getCachedAlbum(v.id.value)?.title, 'Devara');
      }
    });

    testWidgets('AlbumScreen constructs successfully with albumTitle alone', (
      tester,
    ) async {
      // Must not throw assertion error when albumId is omitted but albumTitle is provided
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AlbumScreen(
              albumTitle: 'Kalki 2898 AD',
              albumArtwork: 'https://example.com/kalki.jpg',
              albumArtist: 'Santhosh Narayanan',
            ),
          ),
        ),
      );

      expect(find.byType(AlbumScreen), findsOneWidget);
    });
  });
}
