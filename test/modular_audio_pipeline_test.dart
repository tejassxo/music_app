import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:music_app/models/song_item.dart';
import 'package:music_app/services/audio/queue_controller.dart';
import 'package:music_app/services/audio/favorites_repository.dart';
import 'package:music_app/services/audio/i_audio_engine.dart';
import 'package:music_app/services/audio/audio_engine_factory.dart';
import 'package:music_app/services/audio/mobile_audio_engine.dart';
import 'package:music_app/services/audio/web_audio_engine.dart';
import 'package:music_app/services/update_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => '.',
        );
  });

  SongItem makeTestSong(String id, String title, String author) {
    return SongItem(
      id: id,
      title: title,
      author: author,
      thumbnailUrl: 'https://img.youtube.com/vi/$id/hqdefault.jpg',
      streamUrl: 'https://saavn.cdn/$id.mp4',
      duration: const Duration(seconds: 210),
    );
  }

  group('SongItem Canonical Model Tests', () {
    test('SongItem parses correctly from heterogeneous JSON', () {
      final json = {
        'id': 'track_123',
        'title': 'Anaganaga',
        'author': 'Anirudh',
        'thumbnail': 'https://example.com/thumb.jpg',
        'durationSeconds': 240, // Integer
        'streamUrl': 'https://example.com/stream.mp4',
      };

      final song = SongItem.fromJson(json);
      expect(song.id, 'track_123');
      expect(song.title, 'Anaganaga');
      expect(song.author, 'Anirudh');
      expect(song.thumbnailUrl, 'https://example.com/thumb.jpg');
      expect(song.duration, const Duration(seconds: 240));
      expect(song.streamUrl, 'https://example.com/stream.mp4');
    });

    test(
      'SongItem gracefully handles corrupt/missing types without throwing',
      () {
        final corruptJson = {
          'id': null,
          'title': null,
          'duration': 'invalid_string',
        };

        final song = SongItem.fromJson(corruptJson);
        expect(song.id, '');
        expect(song.title, 'Unknown Title');
        expect(song.author, 'Unknown Artist');
        expect(song.duration, Duration.zero);
      },
    );

    test('SongItem converts to and from Video seamlessly', () {
      final song = makeTestSong('11111111111', 'Master Song', 'Anirudh');
      final video = song.toVideo();

      expect(video.id.value, '11111111111');
      expect(video.title, 'Master Song');
      expect(video.author, 'Anirudh');
      expect(video.duration, const Duration(seconds: 210));

      final restoredSong = SongItem.fromVideo(video, streamUrl: song.streamUrl);
      expect(restoredSong.id, song.id);
      expect(restoredSong.title, song.title);
      expect(restoredSong.streamUrl, song.streamUrl);
    });
  });

  group('QueueController Pure State Machine Tests', () {
    late QueueController controller;
    late List<SongItem> sampleSongs;

    setUp(() {
      controller = QueueController();
      sampleSongs = [
        makeTestSong('1', 'Song 1', 'Artist A'),
        makeTestSong('2', 'Song 2', 'Artist A'),
        makeTestSong('3', 'Song 3', 'Artist B'),
        makeTestSong('4', 'Song 4', 'Artist C'),
        makeTestSong('5', 'Song 5', 'Artist D'),
      ];
    });

    test('Initializes with playlist and clamped index', () {
      controller.setPlaylist(sampleSongs, initialIndex: 2);
      expect(controller.currentIndex, 2);
      expect(controller.currentSong?.id, '3');
      expect(controller.playlist.length, 5);
      expect(controller.hasNext, true);
      expect(controller.hasPrevious, true);
    });

    test('Linear next and previous navigation works cleanly', () async {
      controller.setPlaylist(sampleSongs, initialIndex: 0);

      final next = await controller.nextTrack();
      expect(next?.id, '2');
      expect(controller.currentIndex, 1);

      final prev = await controller.previousTrack(force: true);
      expect(prev?.id, '1');
      expect(controller.currentIndex, 0);
    });

    test('LoopMode.one repeats once on auto-advance then clears', () async {
      controller.setPlaylist(sampleSongs, initialIndex: 1);
      controller.setLoopMode(LoopMode.one);

      // First auto-advance: repeats same track
      final repeat = await controller.nextTrack(isAutoAdvance: true);
      expect(repeat?.id, '2');
      expect(controller.currentIndex, 1);
      expect(controller.hasRepeatedOnce, true);

      // Second auto-advance: advances to next track and resets loopMode
      final advance = await controller.nextTrack(isAutoAdvance: true);
      expect(advance?.id, '3');
      expect(controller.currentIndex, 2);
      expect(controller.loopMode, LoopMode.off);
      expect(controller.hasRepeatedOnce, false);
    });

    test('LoopMode.all loops back to index 0 at end of queue', () async {
      controller.setPlaylist(sampleSongs, initialIndex: 4); // Last song
      controller.setLoopMode(LoopMode.all);

      final next = await controller.nextTrack();
      expect(next?.id, '1');
      expect(controller.currentIndex, 0);
    });

    test(
      'Low queue callback fires when remaining tracks <= threshold',
      () async {
        SongItem? seedReceived;
        controller.onLowQueue = (seed) {
          seedReceived = seed;
        };
        controller.lowQueueThreshold = 2;

        // Queue of 3 songs, start at index 0 (2 remaining -> triggers)
        controller.setPlaylist(sampleSongs.sublist(0, 3), initialIndex: 0);
        expect(seedReceived?.id, '1');
      },
    );

    test('Concurrency mutex lock ignores rapid nextTrack spam', () async {
      controller.setPlaylist(sampleSongs, initialIndex: 0);

      // Fire 5 rapid parallel calls to nextTrack
      final futures = [
        controller.nextTrack(),
        controller.nextTrack(),
        controller.nextTrack(),
        controller.nextTrack(),
        controller.nextTrack(),
      ];

      await Future.wait(futures);
      // Because mutex discarded overlapping calls, currentIndex progressed cleanly to 1
      expect(controller.currentIndex, 1);
    });

    test('Reordering tracks updates active index safely', () {
      controller.setPlaylist(sampleSongs, initialIndex: 2); // Current is '3'
      expect(controller.currentSong?.id, '3');

      // Move track from index 0 to index 4
      controller.reorder(0, 5);
      // Track '3' was at index 2, now shifted to index 1
      expect(controller.currentIndex, 1);
      expect(controller.currentSong?.id, '3');
    });
  });

  group('FavoritesRepository Data Resilience Tests', () {
    late FavoritesRepository repo;

    setUp(() {
      repo = FavoritesRepository();
      repo.resetForTesting();
    });

    test('Toggle like adds and removes seamlessly', () async {
      final song = makeTestSong('like_1', 'Loved Song', 'Artist X');
      expect(repo.isLiked('like_1'), false);

      final added = await repo.toggleLike(song);
      expect(added, true);
      expect(repo.isLiked('like_1'), true);
      expect(repo.likedSongs.length, 1);

      final removed = await repo.toggleLike(song);
      expect(removed, false);
      expect(repo.isLiked('like_1'), false);
      expect(repo.likedSongs.length, 0);
    });

    test(
      'Legacy map conversion preserves expected string attributes',
      () async {
        final song = makeTestSong('like_2', 'Legacy Title', 'Legacy Artist');
        await repo.toggleLike(song);

        final legacy = repo.legacyLikedSongs;
        expect(legacy.length, 1);
        expect(legacy.first['id'], 'like_2');
        expect(legacy.first['title'], 'Legacy Title');
        expect(legacy.first['author'], 'Legacy Artist');
      },
    );
  });

  group('AudioEngine Platform Adapter & Factory Tests', () {
    test(
      'AudioEngineFactory instantiates MobileAudioEngine on non-web platform',
      () {
        final engine = AudioEngineFactory.createEngine();
        expect(engine, isA<MobileAudioEngine>());
        expect(engine.status, AudioEngineStatus.idle);
        expect(engine.isPlaying, false);
        expect(engine.position, Duration.zero);
        expect(engine.duration, Duration.zero);
        engine.dispose();
      },
    );

    test('WebAudioEngine instantiates and provides valid default streams', () {
      final engine = WebAudioEngine();
      expect(engine.status, AudioEngineStatus.idle);
      expect(engine.isPlaying, false);
      expect(engine.position, Duration.zero);
      expect(engine.duration, Duration.zero);
      expect(engine.statusStream, isNotNull);
      expect(engine.positionStream, isNotNull);
      expect(engine.durationStream, isNotNull);
      expect(engine.onTrackEnded, isNotNull);
      expect(engine.onError, isNotNull);

      // Volume safety clamping test (does not throw on out-of-bounds input)
      expect(() => engine.setVolume(-0.5), returnsNormally);
      expect(() => engine.setVolume(1.5), returnsNormally);
      expect(() => engine.setVolume(50.0), returnsNormally);
      engine.dispose();
    });

    test('MobileAudioEngine setVolume safely clamps values', () async {
      final engine = MobileAudioEngine();
      expect(() => engine.setVolume(-1.0), returnsNormally);
      expect(() => engine.setVolume(2.0), returnsNormally);
      expect(() => engine.setVolume(0.5), returnsNormally);
      engine.dispose();
    });
  });

  group('UpdateService & AppUpdateInfo Web Safety Tests', () {
    test('AppUpdateInfo preserves releasePageUrl and formattedSize', () {
      final info = AppUpdateInfo(
        tagName: 'v2.1.0',
        releaseName: 'DilSe v2.1.0',
        changelog: 'Test changelog',
        downloadUrl: 'https://github.com/releases/app.apk',
        apkSizeBytes: 65 * 1024 * 1024,
        currentVersion: '2.0.0',
        currentBuildNumber: '1',
        hasUpdate: true,
        releasePageUrl:
            'https://github.com/charanteja-k/music_app/releases/tag/v2.1.0',
      );

      expect(info.tagName, 'v2.1.0');
      expect(info.formattedSize, '65.0 MB');
      expect(
        info.releasePageUrl,
        'https://github.com/charanteja-k/music_app/releases/tag/v2.1.0',
      );
      expect(info.hasUpdate, true);
    });

    test('Version comparison handles semver and build numbers', () {
      expect(UpdateService.compareVersion('v2.1.0', '2.0.0'), 1);
      expect(UpdateService.compareVersion('v2.0.0', '2.0.0'), 0);
      expect(UpdateService.compareVersion('v1.9.9', '2.0.0'), -1);
      expect(UpdateService.compareVersion('v2.0.0+2', '2.0.0+1'), 1);
    });
  });
}
