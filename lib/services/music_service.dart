import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart';
import 'audio_handler.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:palette_generator/palette_generator.dart';
import 'api_config.dart';
import 'preferences_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audio_session/audio_session.dart';
import 'web_player_bridge.dart';
import 'canonical_song_dedup.dart';
import 'youtube_music_client.dart';
import 'album_color_deriver.dart';
import 'lyrics_transliteration_service.dart';
import 'widget_update_service.dart';
import 'dynamic_artist_service.dart';
import 'taste_matrix_scorer.dart';
import '../models/jio_album.dart';
import 'bug_report_service.dart';
import 'device_audio_service.dart';
import '../models/song_item.dart';
import 'audio/favorites_repository.dart';
import 'database_service.dart';

enum SearchSuggestionType { artist, song, album, history, query }

class SearchSuggestion {
  final String text;
  final String subtitle;
  final SearchSuggestionType type;

  const SearchSuggestion({
    required this.text,
    required this.subtitle,
    required this.type,
  });
}

class StreamCandidate {
  final String url;
  final int tag;
  final String type;
  final int bitrateKbps;
  final String codec;

  StreamCandidate(
    this.url,
    this.tag,
    this.type, {
    this.bitrateKbps = 128,
    this.codec = 'aac',
  });
}

class ActiveStreamInfo {
  final String format; // 'AAC (.mp4)', 'Opus (.webm)', 'MP3', 'Local File'
  final String
  qualityLabel; // '320 kbps (Studio Master)', '160 kbps (High Fidelity)', '128 kbps (Balanced)', '64 kbps (Data Saver)'
  final String
  source; // 'JioSaavn Studio CDN', 'YouTube Direct Audio', 'Offline Storage', 'Cloudflare Edge'
  final int? tag;
  final bool isHd;

  const ActiveStreamInfo({
    required this.format,
    required this.qualityLabel,
    required this.source,
    this.tag,
    this.isHd = false,
  });

  String get displayTag {
    if (source.contains('Offline') || source.contains('Local')) {
      return 'OFFLINE';
    }
    if (source.contains('JioSaavn')) {
      if (qualityLabel.contains('320')) return '320 KBPS';
      if (qualityLabel.contains('160')) return '160 KBPS';
      if (qualityLabel.contains('96')) return '96 KBPS';
      return '48 KBPS';
    }
    if (format.contains('Opus')) {
      if (tag == 251) return 'OPUS 160K';
      if (tag == 250) return 'OPUS 70K';
      if (tag == 249) return 'OPUS 50K';
      return 'OPUS';
    }
    if (format.contains('AAC')) {
      if (tag == 22) return 'AAC HD';
      if (tag == 140) return 'AAC 128K';
      if (tag == 139) return 'AAC 48K';
      return 'AAC';
    }
    return isHd ? 'HD AUDIO' : 'HQ AUDIO';
  }

  static const ActiveStreamInfo standard = ActiveStreamInfo(
    format: 'AAC (.mp4)',
    qualityLabel: '128 kbps (Balanced)',
    source: 'Standard Adaptive Stream',
    isHd: false,
  );
}

class MusicService extends ChangeNotifier with WidgetsBindingObserver {
  static final MusicService _instance = MusicService._internal();
  factory MusicService() => _instance;

  MusicService._internal() {
    _initAudioPlayer();
    if (!kIsWeb) {
      _initAudioSession();

      if (defaultTargetPlatform == TargetPlatform.android) {
        _initWidgetBridge();
      }
      _deviceAudioService.loadDeviceSongs();
    }
    loadDownloadedSongs();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      persistPlaybackSession(force: true);
    }
  }

  Duration? _savedPosition;
  Duration? _savedDuration;
  DateTime _lastSessionSaveTime = DateTime.fromMillisecondsSinceEpoch(0);

  late final AudioPlayer _playerA;
  late final AudioPlayer _playerB;
  late AudioPlayer _activePlayer;
  late AudioPlayer _standbyPlayer;
  AndroidEqualizer? _equalizerA;
  AndroidEqualizer? _equalizerB;

  // Concurrency & Gapless Dual-Deck State
  int _activePlaySessionToken = 0;
  String? _standbyBufferedTrackId;
  bool _isPrebufferingStandby = false;

  final StreamController<Duration> _positionBroadcaster =
      StreamController<Duration>.broadcast();
  final StreamController<Duration?> _durationBroadcaster =
      StreamController<Duration?>.broadcast();

  final YoutubeExplode _ytExplode = YoutubeExplode();

  Video? _currentSong;
  List<Video> _playlist = [];
  int _currentIndex = 0;
  bool _isLoading = false;
  bool _isShuffle = false;
  LoopMode _loopMode = LoopMode.off;
  bool _hasRepeatedOnce = false;
  List<Map<String, String>> _likedSongs = [];
  List<Map<String, dynamic>> _customPlaylists = [];
  final DeviceAudioService _deviceAudioService = DeviceAudioService();

  DeviceAudioService get deviceAudioService => _deviceAudioService;
  List<Map<String, String>> get deviceSongs => _deviceAudioService.deviceSongs;

  // Bidirectional Shuffle History Stack
  final List<int> _shuffleHistory = [];
  int _shuffleHistoryPointer = -1;
  bool _isGeneratingQueue = false;

  // Multi-artist playlist recommendation state
  List<String> _seedPlaylistArtists = [];
  int _playlistArtistRecommendationOffset = 0;

  String? _cachedLyrics;
  String? _cachedLyricsSongId;
  String? _cachedPronunciationLyrics;
  bool _isFetchingLyrics = false;

  // Palette Extraction
  Color _dominantColor = const Color(0xFF1E1E2C);
  Color _vibrantColor = const Color(0xFFFA2D48);
  Color _darkVibrantColor = const Color(0xFF101018);

  // Sleep Timer (DateTime-based: immune to lock-screen throttling)
  DateTime? _sleepEndTime;
  Timer? _sleepCountdownTimer;
  bool _stopAtEndOfTrack = false;
  bool _wasInterruptedBySystem = false;

  // Crossfade & Volume Fading Engine
  bool _isCrossfading = false;
  StreamSubscription<Duration>? _positionCrossfadeSub;

  int _consecutivePlaybackFailures = 0;

  void _showToast(String message) {
    try {
      final ctx = BugReportService.instance.rootNavKey.currentContext;
      if (ctx != null) {
        final messenger = ScaffoldMessenger.maybeOf(ctx);
        if (messenger != null) {
          messenger.hideCurrentSnackBar();
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              backgroundColor: const Color(0xFF1E1E2C),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(milliseconds: 2200),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(
                  color: Colors.white.withValues(alpha: 0.15),
                  width: 1,
                ),
              ),
            ),
          );
        }
      }
    } catch (_) {}
  }

  Video? get currentSong => _currentSong;
  List<Video> get playlist => _playlist;
  int get currentIndex => _currentIndex;
  bool get isLoading => _isLoading;
  bool get isShuffle => _isShuffle;
  LoopMode get loopMode => _loopMode;
  List<Map<String, String>> get likedSongs => _likedSongs;
  List<Map<String, dynamic>> get customPlaylists => _customPlaylists;
  AudioPlayer get audioPlayer => _activePlayer;
  AudioPlayer get _audioPlayer => _activePlayer;
  bool get isCrossfading => _isCrossfading;
  ActiveStreamInfo _activeStreamInfo = ActiveStreamInfo.standard;
  ActiveStreamInfo get activeStreamInfo => _activeStreamInfo;

  String get currentStreamType {
    if (_activeStreamInfo.format.isNotEmpty) {
      return '${_activeStreamInfo.format} (${_activeStreamInfo.qualityLabel})';
    }
    return 'None';
  }

  String get activeDeckName =>
      (_activePlayer == _playerA) ? '_playerA' : '_playerB';
  String get playbackStateString {
    if (_isLoading) {
      return 'buffering';
    }
    if (isPlaying) {
      return 'playing';
    }
    return 'paused';
  }

  static final List<Map<String, dynamic>> _clientLogRingBuffer = [];
  static List<Map<String, dynamic>> get clientLogRingBuffer =>
      List.unmodifiable(_clientLogRingBuffer);

  bool get isPlaying =>
      kIsWeb ? WebPlayerBridge.isPlaying : _activePlayer.playing;
  Duration get position {
    if (_isLoading) return Duration.zero;
    if (kIsWeb) {
      final p = WebPlayerBridge.currentPosition;
      if (p > Duration.zero) return p;
      return _savedPosition ?? Duration.zero;
    }
    final p = _activePlayer.position;
    if (p > Duration.zero) return p;
    return _savedPosition ?? Duration.zero;
  }

  Duration? get duration {
    if (_isLoading) return _currentSong?.duration;
    if (kIsWeb) {
      final d = WebPlayerBridge.currentDuration;
      if (d > Duration.zero) return d;
      return _savedDuration ?? _currentSong?.duration;
    }
    final d = _activePlayer.duration;
    if (d != null && d > Duration.zero) return d;
    return _savedDuration ?? _currentSong?.duration;
  }

  Stream<Duration> get positionStream => _positionBroadcaster.stream;
  Stream<Duration?> get durationStream => _durationBroadcaster.stream;

  String? get cachedLyrics => _cachedLyrics;
  String? get cachedPronunciationLyrics => _cachedPronunciationLyrics;
  bool get isFetchingLyrics => _isFetchingLyrics;

  String? get currentSongLanguage {
    if (_currentSong == null) return null;
    return CanonicalSongDedup.getSongLanguage(_currentSong!.id.value) ??
        CanonicalSongDedup.detectLanguage(_currentSong!.title) ??
        CanonicalSongDedup.detectLanguage(_currentSong!.author);
  }

  Color get dominantColor => _dominantColor;
  Color get vibrantColor => _vibrantColor;
  Color get darkVibrantColor => _darkVibrantColor;

  bool get isSleepTimerActive =>
      (_sleepEndTime != null && _sleepEndTime!.isAfter(DateTime.now())) ||
      _stopAtEndOfTrack;

  Duration? get sleepRemaining {
    if (_sleepEndTime == null) return null;
    final diff = _sleepEndTime!.difference(DateTime.now());
    return diff.isNegative ? Duration.zero : diff;
  }

  bool get stopAtEndOfTrack => _stopAtEndOfTrack;

  String get sleepTimerLabel {
    if (_stopAtEndOfTrack) return 'End of Track';
    final rem = sleepRemaining;
    if (rem != null) {
      final mins = rem.inMinutes;
      final secs = rem.inSeconds.remainder(60).toString().padLeft(2, '0');
      return '$mins:$secs';
    }
    return 'Off';
  }

  static String _cleanSongTitle(String raw) {
    // 1. Remove text inside parentheses & brackets like (Official Video), [4K], (Telugu)
    var s = raw.replaceAll(RegExp(r'\([^)]*\)|\[[^\]]*\]'), ' ');

    // 2. Split on common delimiters and keep primary song name
    final parts = s.split(RegExp(r'\s*[|:–—/]\s*|\s+-\s+'));
    if (parts.isNotEmpty) {
      s = parts.first;
    }

    // 3. Remove common YouTube noise words (case-insensitive)
    s = s.replaceAll(
      RegExp(
        r'\b(full\s+video\s+song|video\s+song|lyric\s+video|official\s+video|official\s+music\s+video|official\s+song|full\s+song|full\s+audio|audio\s+song|lyrics|lyrical|hd|4k|8k|song|track|remix|mashup)\b',
        caseSensitive: false,
      ),
      ' ',
    );

    // 4. Clean extra whitespace
    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String _cleanArtistName(String raw) {
    var s = raw.replaceAll(' - Topic', '').trim();
    final lower = s.toLowerCase();
    const labels = [
      't-series',
      'aditya music',
      'sony music',
      'zee music',
      'lahari music',
      'speed audio',
      'tips official',
      'saregama',
      'yrf',
      'think music',
      'tseries',
      'vevo',
      'records',
      'entertainment',
      'music',
    ];
    for (final label in labels) {
      if (lower.contains(label)) return '';
    }
    return s;
  }

  Future<void> fetchLyrics(Video song) async {
    if (_cachedLyricsSongId == song.id.value && _cachedLyrics != null) return;

    _isFetchingLyrics = true;
    _cachedLyrics = null;
    _cachedPronunciationLyrics = null;
    _cachedLyricsSongId = song.id.value;
    notifyListeners();

    try {
      final songCtx = CanonicalSongDedup.extractSongContext(
        song.title,
        song.author,
      );
      final isTargetFeatured = CanonicalSongDedup.isFeaturedTrack(
        song.title,
        song.author,
      );
      final targetFeaturedArtist = CanonicalSongDedup.extractFeaturedArtist(
        song.title,
        song.author,
      );
      final cleanTitle = (songCtx['title'] as String?)?.isNotEmpty == true
          ? songCtx['title'] as String
          : _cleanSongTitle(song.title);
      final cleanArtist = (songCtx['artist'] as String?)?.isNotEmpty == true
          ? songCtx['artist'] as String
          : _cleanArtistName(song.author);
      final contextKeywords =
          (songCtx['contextKeywords'] as List<String>?) ?? [];
      final durationSec = song.duration?.inSeconds;

      // High-precision language detection:
      // 1. Check registered song language (from JioSaavn or Spotify import)
      String? targetLang = CanonicalSongDedup.getSongLanguage(song.id.value);
      // 2. Check title (native Unicode script or keywords)
      targetLang ??= CanonicalSongDedup.detectLanguage(song.title);
      // 3. Check author / channel
      targetLang ??= CanonicalSongDedup.detectLanguage(song.author);
      // 4. Check user's preferred primary language if available and not generic English
      if (targetLang == null &&
          PreferencesService().preferredLanguages.isNotEmpty) {
        final pref = PreferencesService().preferredLanguages.first
            .toLowerCase();
        if (pref != 'english') {
          targetLang = pref;
        }
      }

      final safeHeaders = {'Accept': 'application/json'};
      final List<dynamic> candidatePool = [];

      // Query Edge, Backend, and Direct LRCLIB in parallel with Future.wait for maximum speed & coverage
      final List<Future<void>> queries = [];

      if (cleanTitle.isNotEmpty) {
        // 1. Cloudflare Edge Worker
        queries.add(() async {
          try {
            final edgeUri = ApiConfig.cloudflareLyricsUri(
              cleanTitle,
              artist: cleanArtist,
              lang: targetLang,
              duration: durationSec,
            );
            final res = await http
                .get(edgeUri, headers: safeHeaders)
                .timeout(const Duration(seconds: 4));
            if (res.statusCode == 200) {
              final data = json.decode(res.body);
              if (data is Map &&
                  data['status'] == 'ok' &&
                  data['data'] != null) {
                candidatePool.add(data['data']);
              }
            }
          } catch (_) {}
        }());

        // 2. Render Backend Lyrics Proxy
        queries.add(() async {
          try {
            final backendUri = ApiConfig.backendLyricsUri(
              cleanTitle,
              artist: cleanArtist,
              lang: targetLang,
              duration: durationSec,
            );
            final res = await http
                .get(backendUri, headers: safeHeaders)
                .timeout(const Duration(seconds: 4));
            if (res.statusCode == 200) {
              final data = json.decode(res.body);
              if (data is Map &&
                  data['status'] == 'ok' &&
                  data['data'] != null) {
                candidatePool.add(data['data']);
              }
            }
          } catch (_) {}
        }());

        // 3. Direct LRCLIB get API
        if (cleanArtist.isNotEmpty) {
          queries.add(() async {
            try {
              final getUri = Uri.parse(
                'https://lrclib.net/api/get?track_name=${Uri.encodeComponent(cleanTitle)}&artist_name=${Uri.encodeComponent(cleanArtist)}',
              );
              final res = await http
                  .get(getUri, headers: safeHeaders)
                  .timeout(const Duration(seconds: 4));
              if (res.statusCode == 200) {
                final data = json.decode(res.body);
                if (data is Map &&
                    (data['syncedLyrics'] != null ||
                        data['plainLyrics'] != null)) {
                  candidatePool.add(data);
                }
              }
            } catch (_) {}
          }());
        }

        // 4. Direct LRCLIB search by Title + Artist
        if (cleanArtist.isNotEmpty) {
          queries.add(() async {
            try {
              final urlSearch = Uri.parse(
                'https://lrclib.net/api/search?q=${Uri.encodeComponent("$cleanTitle $cleanArtist")}',
              );
              final res = await http
                  .get(urlSearch, headers: safeHeaders)
                  .timeout(const Duration(seconds: 4));
              if (res.statusCode == 200) {
                final list = json.decode(res.body);
                if (list is List) candidatePool.addAll(list);
              }
            } catch (_) {}
          }());
        }

        // 5. Direct LRCLIB search by Movie / Context Keywords
        if (contextKeywords.isNotEmpty) {
          queries.add(() async {
            try {
              final urlCtx = Uri.parse(
                'https://lrclib.net/api/search?q=${Uri.encodeComponent("$cleanTitle ${contextKeywords.first}")}',
              );
              final res = await http
                  .get(urlCtx, headers: safeHeaders)
                  .timeout(const Duration(seconds: 4));
              if (res.statusCode == 200) {
                final list = json.decode(res.body);
                if (list is List) candidatePool.addAll(list);
              }
            } catch (_) {}
          }());
        }

        // 6. Direct LRCLIB track_name only search
        queries.add(() async {
          try {
            final urlTrack = Uri.parse(
              'https://lrclib.net/api/search?track_name=${Uri.encodeComponent(cleanTitle)}',
            );
            final res = await http
                .get(urlTrack, headers: safeHeaders)
                .timeout(const Duration(seconds: 4));
            if (res.statusCode == 200) {
              final list = json.decode(res.body);
              if (list is List) candidatePool.addAll(list);
            }
          } catch (_) {}
        }());

        // 7. Explicit query for featured artist lyrics
        if (isTargetFeatured &&
            targetFeaturedArtist != null &&
            targetFeaturedArtist.isNotEmpty) {
          queries.add(() async {
            try {
              final urlFeat = Uri.parse(
                'https://lrclib.net/api/search?q=${Uri.encodeComponent("$cleanTitle feat $targetFeaturedArtist")}',
              );
              final res = await http
                  .get(urlFeat, headers: safeHeaders)
                  .timeout(const Duration(seconds: 4));
              if (res.statusCode == 200) {
                final list = json.decode(res.body);
                if (list is List) candidatePool.addAll(list);
              }
            } catch (_) {}
          }());

          queries.add(() async {
            try {
              final urlTrackFeat = Uri.parse(
                'https://lrclib.net/api/search?track_name=${Uri.encodeComponent("$cleanTitle (feat. $targetFeaturedArtist)")}',
              );
              final res = await http
                  .get(urlTrackFeat, headers: safeHeaders)
                  .timeout(const Duration(seconds: 4));
              if (res.statusCode == 200) {
                final list = json.decode(res.body);
                if (list is List) candidatePool.addAll(list);
              }
            } catch (_) {}
          }());

          if (cleanArtist.isNotEmpty) {
            queries.add(() async {
              try {
                final urlCombo = Uri.parse(
                  'https://lrclib.net/api/search?q=${Uri.encodeComponent("$cleanTitle $cleanArtist $targetFeaturedArtist")}',
                );
                final res = await http
                    .get(urlCombo, headers: safeHeaders)
                    .timeout(const Duration(seconds: 4));
                if (res.statusCode == 200) {
                  final list = json.decode(res.body);
                  if (list is List) candidatePool.addAll(list);
                }
              } catch (_) {}
            }());
          }
        }
      }

      await Future.wait(queries);

      // Score all gathered candidates with high-preference for synced lyrics
      final seenIds = <dynamic>{};
      Map<String, dynamic>? bestCandidate;
      int bestScore = 120;
      Map<String, dynamic>? bestSyncedCandidate;
      int bestSyncedScore = 120;

      Map<String, dynamic>? bestNativeCandidate;
      int bestNativeScore = 120;
      Map<String, dynamic>? bestRomanizedCandidate;
      int bestRomanizedScore = 120;

      for (final item in candidatePool) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        final id = map['id'] ?? '${map['trackName']}_${map['artistName']}';
        if (seenIds.contains(id)) continue;
        seenIds.add(id);

        final score = CanonicalSongDedup.scoreLyricsCandidate(
          targetLang: targetLang,
          targetTitle: cleanTitle,
          targetArtist: cleanArtist,
          targetDuration: durationSec,
          candidate: map,
          contextKeywords: contextKeywords,
          isTargetFeatured: isTargetFeatured,
          targetFeaturedArtist: targetFeaturedArtist,
        );

        if (score > bestScore) {
          bestScore = score;
          bestCandidate = map;
        }

        final synced = (map['syncedLyrics'] as String?)?.trim();
        final plain = (map['plainLyrics'] as String?)?.trim();
        final text = (synced?.isNotEmpty == true ? synced! : (plain ?? ''))
            .trim();

        if (synced != null && synced.isNotEmpty && score > bestSyncedScore) {
          bestSyncedScore = score;
          bestSyncedCandidate = map;
        }

        if (text.isNotEmpty && score > 120) {
          final isNative = LyricsTransliterationService.hasIndicScript(text);
          if (isNative && score > bestNativeScore) {
            bestNativeScore = score;
            bestNativeCandidate = map;
          } else if (!isNative && score > bestRomanizedScore) {
            bestRomanizedScore = score;
            bestRomanizedCandidate = map;
          }
        }
      }

      // Synced candidates ALWAYS supersede plain lyrics whenever available!
      final chosenCandidate = bestSyncedCandidate ?? bestCandidate;

      if (bestNativeCandidate != null && bestRomanizedCandidate != null) {
        final nativeSynced = (bestNativeCandidate['syncedLyrics'] as String?)
            ?.trim();
        final nativePlain = (bestNativeCandidate['plainLyrics'] as String?)
            ?.trim();
        final romanSynced = (bestRomanizedCandidate['syncedLyrics'] as String?)
            ?.trim();
        final romanPlain = (bestRomanizedCandidate['plainLyrics'] as String?)
            ?.trim();

        _cachedLyrics = (nativeSynced != null && nativeSynced.isNotEmpty)
            ? nativeSynced
            : (nativePlain != null && nativePlain.isNotEmpty
                  ? nativePlain
                  : null);
        _cachedPronunciationLyrics =
            (romanSynced != null && romanSynced.isNotEmpty)
            ? romanSynced
            : (romanPlain != null && romanPlain.isNotEmpty ? romanPlain : null);
      } else if (chosenCandidate != null) {
        final synced = (chosenCandidate['syncedLyrics'] as String?)?.trim();
        final plain = (chosenCandidate['plainLyrics'] as String?)?.trim();
        final text = (synced != null && synced.isNotEmpty)
            ? synced
            : (plain != null && plain.isNotEmpty ? plain : null);
        _cachedLyrics = text;
        if (text != null &&
            !LyricsTransliterationService.hasIndicScript(text) &&
            (targetLang == 'telugu' ||
                LyricsTransliterationService.isRomanizedTelugu(text))) {
          _cachedPronunciationLyrics = text;
        }
      }

      if (_cachedLyrics == null || _cachedLyrics!.isEmpty) {
        _cachedLyrics = 'No lyrics found for "$cleanTitle".';
      }
    } catch (e) {
      _cachedLyrics = 'Lyrics temporarily unavailable.';
    } finally {
      _isFetchingLyrics = false;
      notifyListeners();
    }
  }

  static final Map<String, String> _artworkMap = {};
  static final Map<String, String> _webStreamUrls = {};
  static final Map<String, String> _songAlbumMap = {};
  static final Map<String, String> _songAlbumIdMap = {};
  static final Map<String, JioAlbum> _songAlbumObjMap = {};

  static void registerSongAlbum(
    String songId, {
    String? albumTitle,
    String? albumId,
    JioAlbum? album,
  }) {
    if (songId.isEmpty) return;
    if (albumTitle != null && albumTitle.trim().isNotEmpty) {
      _songAlbumMap[songId] = albumTitle.trim();
    }
    if (albumId != null && albumId.trim().isNotEmpty) {
      _songAlbumIdMap[songId] = albumId.trim();
    }
    if (album != null) {
      _songAlbumObjMap[songId] = album;
      if (album.title.isNotEmpty) _songAlbumMap[songId] = album.title;
      if (album.id.isNotEmpty) _songAlbumIdMap[songId] = album.id;
    }
  }

  static String? getCachedAlbumTitle(String songId) => _songAlbumMap[songId];
  static String? getCachedAlbumId(String songId) => _songAlbumIdMap[songId];
  static JioAlbum? getCachedAlbum(String songId) => _songAlbumObjMap[songId];

  static void cacheWebStreamUrl(String videoId, String streamUrl) {
    if (videoId.isEmpty || streamUrl.isEmpty) return;
    _webStreamUrls[videoId] = streamUrl;
    if (kIsWeb) {
      SharedPreferences.getInstance()
          .then((prefs) {
            prefs.setString('web_stream_$videoId', streamUrl);
          })
          .catchError((_) {});
    }
  }

  static String? getCachedWebStreamUrl(String videoId) {
    return _webStreamUrls[videoId];
  }

  static String getHdThumbnail(String videoId) {
    if (_artworkMap.containsKey(videoId) &&
        _artworkMap[videoId]!.isNotEmpty &&
        !_artworkMap[videoId]!.startsWith('https://i.ytimg.com/')) {
      return _artworkMap[videoId]!;
    }
    // Check downloaded songs
    for (final s in _instance._downloadedSongs) {
      if (s['id'] == videoId && (s['thumbnail']?.isNotEmpty ?? false)) {
        final t = s['thumbnail']!;
        if (!t.startsWith('https://i.ytimg.com/')) {
          _artworkMap[videoId] = t;
          return t;
        }
      }
    }
    // Check device storage songs
    final deviceSong = _instance._deviceAudioService.getSongById(videoId);
    if (deviceSong != null && (deviceSong['thumbnail']?.isNotEmpty ?? false)) {
      _artworkMap[videoId] = deviceSong['thumbnail']!;
      return deviceSong['thumbnail']!;
    }
    // Check listening history
    for (final s in PreferencesService().listeningHistory) {
      if (s['id'] == videoId && (s['thumbnail']?.isNotEmpty ?? false)) {
        final t = s['thumbnail']!;
        if (!t.startsWith('https://i.ytimg.com/')) {
          _artworkMap[videoId] = t;
          return t;
        }
      }
    }
    // Check custom playlists
    for (final p in _instance._customPlaylists) {
      final pSongs = p['songs'] as List<dynamic>? ?? [];
      for (final s in pSongs) {
        if (s is Map &&
            s['id'] == videoId &&
            (s['thumbnail']?.toString().isNotEmpty ?? false)) {
          final t = s['thumbnail'].toString();
          if (!t.startsWith('https://i.ytimg.com/')) {
            _artworkMap[videoId] = t;
            return t;
          }
        }
      }
    }
    if (_artworkMap.containsKey(videoId) && _artworkMap[videoId]!.isNotEmpty) {
      return _artworkMap[videoId]!;
    }
    return 'https://i.ytimg.com/vi/$videoId/maxresdefault.jpg';
  }

  static void registerArtwork(
    String videoId,
    String artworkUrl, {
    bool force = false,
  }) {
    if (videoId.isEmpty || artworkUrl.isEmpty) return;
    final current = _artworkMap[videoId];
    final isYtFallback =
        current == null ||
        current.isEmpty ||
        current.startsWith('https://i.ytimg.com/');
    if (force || isYtFallback || !_artworkMap.containsKey(videoId)) {
      _artworkMap[videoId] = artworkUrl;
    }
  }

  /// Background artwork and stream enrichment pass.
  ///
  /// Iterates over [songs] and for any song whose current artwork is:
  ///   (a) a known compilation/playlist cover, OR
  ///   (b) absent from _artworkMap (would fall back to a raw YouTube thumbnail), OR
  ///   (c) missing a cached direct JioSaavn 320k stream URL in _webStreamUrls
  ///
  /// …fires a lightweight JioSaavn single-track resolve to retrieve the genuine
  /// original movie/album cover and direct 320k stream URL. Updates [_artworkMap]
  /// and [_webStreamUrls], and calls [notifyListeners] so the UI refreshes without reloading the page.
  ///
  /// Rate-limited to one resolve per 80ms so the edge worker is not flooded.
  Future<void> enrichArtworkForSongs(List<Video> songs) async {
    // Collect songs that need artwork or stream enrichment
    final needsEnrich = <Video>[];
    for (final s in songs) {
      final id = s.id.value;
      final current = _artworkMap[id];
      final isCompilation =
          current != null && _compilationArtworks.contains(current);
      final isYtFallback =
          current == null ||
          current.isEmpty ||
          current.startsWith('https://i.ytimg.com/');
      final needsStream =
          _webStreamUrls[id] == null || _webStreamUrls[id]!.isEmpty;
      if (isCompilation || isYtFallback || needsStream) {
        needsEnrich.add(s);
      }
    }
    if (needsEnrich.isEmpty) return;

    debugPrint(
      '[ArtworkEnrich] Enriching artwork & streams for ${needsEnrich.length} songs...',
    );

    for (final song in needsEnrich) {
      try {
        final cleanTitle = CanonicalSongDedup.cleanTitle(song.title);
        final cleanArtist = CanonicalSongDedup.cleanArtist(song.author);
        if (cleanTitle.isEmpty) continue;

        final uri = ApiConfig.jioSingleTrackUri(
          cleanTitle,
          artist: cleanArtist,
        );
        final resp = await http.get(uri).timeout(const Duration(seconds: 4));

        if (resp.statusCode == 200) {
          final body = json.decode(resp.body);
          if (body is Map && body['match'] == true) {
            final data = body['data'] as Map<String, dynamic>?;
            final artwork = data?['artwork'] as String? ?? '';
            final album = data?['album'] as String? ?? '';
            final albumId =
                data?['album_id']?.toString() ??
                data?['albumId']?.toString() ??
                '';
            final streamUrl = data?['streamUrl'] as String? ?? '';

            if (album.isNotEmpty || albumId.isNotEmpty) {
              registerSongAlbum(
                song.id.value,
                albumTitle: album,
                albumId: albumId,
              );
            }

            final current = _artworkMap[song.id.value];
            final isYtFallback =
                current == null ||
                current.isEmpty ||
                current.startsWith('https://i.ytimg.com/');

            // Accept artwork if not compilation, or if currently stuck with a raw YouTube video thumbnail
            if (artwork.isNotEmpty &&
                (!_compilationAlbumRegex.hasMatch(album) || isYtFallback)) {
              _artworkMap[song.id.value] = artwork;
              debugPrint('[ArtworkEnrich] ✓ ${song.title} → $album (artwork)');
              notifyListeners();
            }

            // Pre-warm direct 320k JioSaavn stream URL for immediate playback
            if (streamUrl.isNotEmpty) {
              cacheWebStreamUrl(song.id.value, streamUrl);
              debugPrint(
                '[ArtworkEnrich] ✓ ${song.title} → 320k stream pre-warmed',
              );
            }
          }
        }
      } catch (_) {}

      // 80ms gap between requests to avoid hammering the edge worker
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
  }

  final List<Video> _sessionPlayedHistory = [];
  bool _isNavigatingHistory = false;
  bool _isNavigatingNext = false;
  DateTime _lastNextClickTime = DateTime.fromMillisecondsSinceEpoch(0);
  bool _isNavigatingPrev = false;
  DateTime _lastPrevClickTime = DateTime.fromMillisecondsSinceEpoch(0);

  bool _isTransitioning = false;
  bool _isFetchingNextQueue = false;

  List<Video> _preloadedTopChartsIndia = [];
  List<Video> _preloadedTrending = [];
  bool _hasPreloadedHome = false;

  List<Video> get preloadedTopChartsIndia => _preloadedTopChartsIndia;
  List<Video> get preloadedTrending => _preloadedTrending;
  bool get hasPreloadedHome => _hasPreloadedHome;

  Future<void> preloadHomeData() async {
    if (_hasPreloadedHome) return;
    try {
      final prefs = PreferencesService();
      final primaryLang = prefs.preferredLanguages.isNotEmpty
          ? prefs.preferredLanguages.first
          : 'Telugu';
      final results = await Future.wait([
        searchSongs('$primaryLang Top Hits'),
        searchSongs('$primaryLang Trending'),
      ]);
      _preloadedTopChartsIndia = results[0];
      _preloadedTrending = results[1];
      _hasPreloadedHome = true;
      notifyListeners();
    } catch (e) {
      debugPrint('[Preload] Home data preload: $e');
    }
  }

  Future<void> _initAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      await session.setActive(true);
      session.interruptionEventStream.listen((event) {
        if (event.begin) {
          switch (event.type) {
            case AudioInterruptionType.duck:
              _audioPlayer.setVolume(0.3);
              break;
            case AudioInterruptionType.pause:
            case AudioInterruptionType.unknown:
              _wasInterruptedBySystem = true;
              _audioPlayer.pause();
              break;
          }
        } else {
          switch (event.type) {
            case AudioInterruptionType.duck:
              _audioPlayer.setVolume(1.0);
              break;
            case AudioInterruptionType.pause:
              if (_wasInterruptedBySystem) {
                _wasInterruptedBySystem = false;
                _audioPlayer.play();
              }
              break;
            case AudioInterruptionType.unknown:
              break;
          }
        }
      });
    } catch (e) {
      debugPrint('[AudioSession] Error setting up session: $e');
    }
  }

  void _initAudioPlayer() {
    if (!kIsWeb && Platform.isAndroid) {
      _equalizerA = AndroidEqualizer();
      _equalizerB = AndroidEqualizer();
    }
    _playerA = AudioPlayer(
      audioPipeline: _equalizerA != null
          ? AudioPipeline(androidAudioEffects: [_equalizerA!])
          : null,
    );
    _playerB = AudioPlayer(
      audioPipeline: _equalizerB != null
          ? AudioPipeline(androidAudioEffects: [_equalizerB!])
          : null,
    );
    _activePlayer = _playerA;
    _standbyPlayer = _playerB;

    if (kIsWeb) {
      WebPlayerBridge.init();
      WebPlayerBridge.positionStream.listen((pos) {
        _positionBroadcaster.add(pos);
      });
      WebPlayerBridge.durationStream.listen((dur) {
        _durationBroadcaster.add(dur);
      });
      WebPlayerBridge.onTrackEnded.listen((_) async {
        await _handleTrackCompletion();
      });
      WebPlayerBridge.onNext.listen((_) => nextSong());
      WebPlayerBridge.onPrevious.listen((_) => previousSong());
      WebPlayerBridge.stateStream.listen((state) {
        if (state == 'playing') {
          _consecutivePlaybackFailures = 0;
        }
        notifyListeners();
      });
      WebPlayerBridge.onError.listen((code) async {
        debugPrint('[WebPlayer] Error $code encountered. Handling recovery…');
        _isLoading = false;
        _consecutivePlaybackFailures++;
        if (_consecutivePlaybackFailures >= 3) {
          debugPrint(
            '[WebPlayer] Circuit breaker tripped after $_consecutivePlaybackFailures failures. Halting auto-skip.',
          );
          _showToast('Playback error. Tap play to retry.');
          notifyListeners();
          return;
        }
        _showToast('Playback error: Skipping to next track');
        notifyListeners();
        await Future.delayed(const Duration(milliseconds: 500));
        await nextSong();
      });

      PreferencesService.onEqualizerChanged =
          (bool enabled, Map<int, double> bands) {
            WebPlayerBridge.setEqualizer(enabled, bands);
          };
    } else {
      for (final player in [_playerA, _playerB]) {
        player.positionStream.listen((pos) {
          if (identical(player, _activePlayer)) {
            _positionBroadcaster.add(pos);
            _syncWidgetPlayback();
          }
        });
        player.durationStream.listen((dur) {
          if (identical(player, _activePlayer)) {
            _durationBroadcaster.add(dur);
          }
        });
        player.playbackEventStream.listen(
          (event) {},
          onError: (Object error, StackTrace stackTrace) {
            _handlePlaybackStreamError(player, error, stackTrace);
          },
        );
        player.playerStateStream.listen(
          (state) async {
            if (identical(player, _activePlayer)) {
              notifyListeners();
              _syncWidgetPlayback();
            }
            if (state.processingState == ProcessingState.completed) {
              if (_isTransitioning) {
                return;
              }

              // Only the active player should trigger auto-advance. Standby player completing
              // simply means a previous fading-out track reached normal EOF.
              if (!identical(player, _activePlayer)) {
                return;
              }

              // If a crossfade was initiated, outgoing player reaching EOF is expected.
              // Do NOT cancel active fade or wipe incoming player that is currently resolving/buffering!
              if (_isCrossfading) {
                debugPrint(
                  '[AudioPlayer] Outgoing player reached EOF during crossfade. Standby deck will assume playback.',
                );
                return;
              }

              final currentPos = player.position;
              final currentDur = player.duration;
              if (currentDur != null &&
                  currentDur.inSeconds > 10 &&
                  (currentDur - currentPos).inSeconds > 8 &&
                  currentPos.inSeconds <
                      (currentDur.inSeconds * 0.85).round()) {
                debugPrint(
                  '[AudioPlayer] Ignoring spurious completion event at ${currentPos.inSeconds}s / ${currentDur.inSeconds}s',
                );
                return;
              }
              await _handleTrackCompletion();
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            _handlePlaybackStreamError(player, error, stackTrace);
          },
        );
      }

      PreferencesService.onEqualizerChanged =
          (bool enabled, Map<int, double> bands) {
            applyEqualizerNative(enabled: enabled, bands: bands);
          };
      if (Platform.isAndroid) {
        final prefs = PreferencesService();
        applyEqualizerNative(
          enabled: prefs.equalizerEnabled,
          bands: prefs.equalizerBands,
        );
      }
    }

    _positionCrossfadeSub?.cancel();
    _positionCrossfadeSub = positionStream.listen((pos) {
      _checkContinuousPlaybackPrewarm(pos);
      _checkCrossfadeTrigger(pos);
    });

    loadLikedSongs();
    loadCustomPlaylists();
  }

  Future<void> _handleTrackCompletion() async {
    if (_isTransitioning || _isCrossfading) return;
    _isTransitioning = true;
    try {
      if (!kIsWeb && audioHandler != null) {
        audioHandler!.notifyLoading(isLoading: true);
      }
      if (_loopMode == LoopMode.one && _currentSong != null) {
        if (!_hasRepeatedOnce) {
          _hasRepeatedOnce = true;
          debugPrint('[Playback] LoopMode.one active: repeating track once…');
          if (kIsWeb) {
            WebPlayerBridge.seek(Duration.zero);
            WebPlayerBridge.resume();
          } else {
            await _activePlayer.seek(Duration.zero);
            await _activePlayer.play();
          }
          return;
        } else {
          debugPrint(
            '[Playback] Single repeat complete. Resetting repeat mode and advancing…',
          );
          _hasRepeatedOnce = false;
          _loopMode = LoopMode.off;
          notifyListeners();
        }
      }
      debugPrint('[Playback] Track ended. Auto-advancing to next song…');
      await nextSong(isAutoAdvance: true);
    } catch (e) {
      debugPrint('[Playback] Completion error: $e');
    } finally {
      _isTransitioning = false;
    }
  }

  Future<void> applyEqualizerNative({
    required bool enabled,
    required Map<int, double> bands,
  }) async {
    if (kIsWeb || !Platform.isAndroid) return;
    for (final eq in [_equalizerA, _equalizerB]) {
      if (eq == null) continue;
      try {
        await eq.setEnabled(enabled);
        if (enabled) {
          final params = await eq.parameters.timeout(
            const Duration(seconds: 2),
          );
          for (int i = 0; i < params.bands.length; i++) {
            final gain = bands[i] ?? 0.0;
            final clampedGain = gain.clamp(
              params.minDecibels,
              params.maxDecibels,
            );
            await params.bands[i].setGain(clampedGain);
          }
        }
      } catch (e) {
        debugPrint('[AndroidEqualizer] Failed to apply: $e');
      }
    }
  }

  String? _lastFailedSongId;
  int _songRetryCount = 0;

  Future<void> _handlePlaybackStreamError(
    AudioPlayer player,
    Object error,
    StackTrace? stackTrace,
  ) async {
    debugPrint(
      '[AudioPlayer] Stream error received on player (is active: ${identical(player, _activePlayer)}): $error',
    );

    // Standby player stream errors should not disrupt active playback
    if (!identical(player, _activePlayer)) {
      try {
        await player.stop();
        await player.clearAudioSources();
      } catch (_) {}
      return;
    }

    if (_isTransitioning) {
      debugPrint('[AudioPlayer] Stream error ignored: transition in progress');
      return;
    }

    final song = _currentSong;
    if (song == null) return;

    final errString = error.toString().toLowerCase();
    final isHttpOrSourceError =
        errString.contains('httpdatasource') ||
        errString.contains('403') ||
        errString.contains('source error') ||
        errString.contains('failed to connect') ||
        errString.contains('playbackexception') ||
        errString.contains('response code') ||
        errString.contains('behindlivewindow');

    debugPrint(
      '[AudioPlayer] Stream playback failure for "${song.title}": $error (isHttpOrSource: $isHttpOrSourceError, retries: $_songRetryCount)',
    );

    // Loop-breaker: If this track has already been retried once, skip to next track rather than freezing at 0:00
    if (_lastFailedSongId == song.id.value && _songRetryCount >= 1) {
      debugPrint(
        '[AudioPlayer] Re-resolution limit reached for "${song.title}". Auto-advancing to next track…',
      );
      _lastFailedSongId = null;
      _songRetryCount = 0;
      _showToast('Playback error: Skipping ${song.title}');
      await nextSong();
      return;
    }

    _lastFailedSongId = song.id.value;
    _songRetryCount++;

    // Evict cached stream URL to force fresh stream candidate resolution
    _webStreamUrls.remove(song.id.value);

    _showToast('Stream interrupted: Reconnecting…');
    debugPrint(
      '[AudioPlayer] Re-resolving fresh stream candidates for "${song.title}"…',
    );

    _isTransitioning = true;
    try {
      await playSong(song, updateQueue: false);
    } catch (e) {
      debugPrint('[AudioPlayer] Stream re-resolution failed: $e');
      await nextSong();
    } finally {
      _isTransitioning = false;
    }
  }

  int _fadeSession = 0;

  void _cancelActiveFade() {
    _fadeSession++;
    _isCrossfading = false;
    _standbyBufferedTrackId = null;
    try {
      _standbyPlayer.stop();
      _standbyPlayer.clearAudioSources();
      _standbyPlayer.setVolume(1.0);
      _activePlayer.setVolume(1.0);
    } catch (_) {}
    if (audioHandler is DilSeAudioHandler) {
      (audioHandler as DilSeAudioHandler).bindPlayer(_activePlayer);
    }
  }

  Future<void> _setVolume(double vol) async {
    final clamped = vol.clamp(0.0, 1.0);
    if (kIsWeb) {
      WebPlayerBridge.setVolume(clamped);
    } else {
      try {
        await _activePlayer.setVolume(clamped);
      } catch (_) {}
    }
  }

  Future<void> _fadeVolume({
    required double from,
    required double to,
    required Duration duration,
  }) async {
    final session = ++_fadeSession;
    const int steps = 18;
    final int stepMs = (duration.inMilliseconds / steps).clamp(15, 120).toInt();
    try {
      for (int i = 0; i <= steps; i++) {
        if (_fadeSession != session) return;
        final double progress = i / steps;
        final double currentVol = from + (to - from) * progress;
        await _setVolume(currentVol);
        await Future.delayed(Duration(milliseconds: stepMs));
      }
    } catch (_) {}
    if (_fadeSession == session && to >= 0.9) {
      await _setVolume(1.0);
    }
  }

  Future<void> _dualDeckCrossfadeNative({
    required AudioPlayer outgoingPlayer,
    required AudioPlayer incomingPlayer,
    required Duration duration,
  }) async {
    final session = ++_fadeSession;
    _isCrossfading = true;
    const int steps = 25;
    final int stepMs = (duration.inMilliseconds / steps).clamp(20, 150).toInt();
    try {
      for (int i = 0; i <= steps; i++) {
        if (_fadeSession != session) {
          debugPrint(
            '[Crossfade] Fade session cancelled ($session != $_fadeSession)',
          );
          return;
        }
        final double progress = i / steps;
        // Equal-power crossfade curve: constant acoustic energy across transition
        final double outVol = cos(progress * 0.5 * pi);
        final double inVol = sin(progress * 0.5 * pi);
        await Future.wait([
          outgoingPlayer.setVolume(outVol.clamp(0.0, 1.0)),
          incomingPlayer.setVolume(inVol.clamp(0.0, 1.0)),
        ]);
        await Future.delayed(Duration(milliseconds: stepMs));
      }
    } catch (e) {
      debugPrint('[Crossfade] Error in native crossfade ramp: $e');
    } finally {
      _isCrossfading = false;
      if (_fadeSession == session) {
        try {
          await outgoingPlayer.stop();
          await outgoingPlayer.clearAudioSources();
          await outgoingPlayer.setVolume(1.0);
        } catch (_) {}
        try {
          await incomingPlayer.setVolume(1.0);
        } catch (_) {}
        if (audioHandler is DilSeAudioHandler) {
          (audioHandler as DilSeAudioHandler).bindPlayer(_activePlayer);
        }
        debugPrint('[Crossfade] Native crossfade completed successfully.');
      }
    }
  }

  Future<void> _startDualDeckCrossfade() async {
    final outgoingPlayer = _activePlayer;
    final incomingPlayer = _standbyPlayer;

    // If outgoing player has already reached EOF or stopped while incoming track was resolving,
    // take over directly without running an empty fade ramp against a dead player.
    if (!outgoingPlayer.playing ||
        outgoingPlayer.processingState == ProcessingState.completed) {
      _activePlayer = incomingPlayer;
      _standbyPlayer = outgoingPlayer;
      _positionBroadcaster.add(Duration.zero);
      if (incomingPlayer.duration != null) {
        _durationBroadcaster.add(incomingPlayer.duration!);
      }
      if (audioHandler is DilSeAudioHandler) {
        (audioHandler as DilSeAudioHandler).bindPlayer(_activePlayer);
      }
      try {
        await incomingPlayer.setVolume(1.0);
        await incomingPlayer.play();
      } catch (e) {
        debugPrint('[Crossfade] Error starting incoming player directly: $e');
      }
      _isCrossfading = false;
      _isLoading = false;
      notifyListeners();
      return;
    }

    try {
      await incomingPlayer.setVolume(0.0);
      await incomingPlayer.play();
    } catch (e) {
      debugPrint('[Crossfade] Error starting incoming player: $e');
      _isCrossfading = false;
      return;
    }

    // Immediately swap active deck to the incoming player so UI scrubber,
    // waveform, lyrics, and notification lock screen bind to the new song from 0:00.
    _activePlayer = incomingPlayer;
    _standbyPlayer = outgoingPlayer;

    _positionBroadcaster.add(Duration.zero);
    if (incomingPlayer.duration != null) {
      _durationBroadcaster.add(incomingPlayer.duration!);
    }

    if (audioHandler is DilSeAudioHandler) {
      (audioHandler as DilSeAudioHandler).bindPlayer(_activePlayer);
    }
    _isLoading = false;
    notifyListeners();

    final prefs = PreferencesService();
    int crossfadeSec = prefs.crossfadeSeconds;
    if (prefs.smartCrossfadeEnabled) {
      final profile = prefs.audioProfile;
      if (profile.avgTempo > 60 && profile.avgTempo < 200) {
        crossfadeSec = (16 * (60.0 / profile.avgTempo)).clamp(3.0, 9.0).round();
      }
    }

    final dur = incomingPlayer.duration;
    if (dur != null && dur.inSeconds > 0 && dur.inSeconds <= crossfadeSec * 2) {
      crossfadeSec = (dur.inSeconds ~/ 2).clamp(1, 10);
    }

    await _dualDeckCrossfadeNative(
      outgoingPlayer: outgoingPlayer,
      incomingPlayer: incomingPlayer,
      duration: Duration(seconds: crossfadeSec),
    );
  }

  Future<void> fadeInCurrentSong({
    Duration duration = const Duration(milliseconds: 900),
  }) async {
    await _fadeVolume(from: 0.0, to: 1.0, duration: duration);
  }

  Video? _getNextTrackCandidate() {
    if (_playlist.isEmpty) return null;
    if (_isShuffle && _playlist.length > 1) {
      if (_shuffleHistoryPointer + 1 < _shuffleHistory.length) {
        final nextIdx = _shuffleHistory[_shuffleHistoryPointer + 1];
        if (nextIdx >= 0 && nextIdx < _playlist.length) {
          return _playlist[nextIdx];
        }
      }
    } else if (_currentIndex + 1 < _playlist.length) {
      return _playlist[_currentIndex + 1];
    } else if (_loopMode == LoopMode.all && _playlist.isNotEmpty) {
      return _playlist[0];
    }
    return null;
  }

  void _checkContinuousPlaybackPrewarm(Duration pos) {
    if (_isCrossfading ||
        _isTransitioning ||
        _isLoading ||
        _playlist.isEmpty ||
        _currentSong == null) {
      return;
    }
    if (_loopMode == LoopMode.one) return;
    final dur = duration;
    if (dur == null || dur.inSeconds <= 15) return;

    final remaining = dur - pos;
    final nextTrack = _getNextTrackCandidate();
    if (nextTrack == null) return;

    // 1. Proactive URL resolution at T-25s to T-5s
    if (remaining <= const Duration(seconds: 25) &&
        remaining > const Duration(seconds: 3)) {
      final trackId = nextTrack.id.value;
      if (_webStreamUrls[trackId] == null || _webStreamUrls[trackId]!.isEmpty) {
        _prewarmSingleTrack(nextTrack);
      }
    }

    // 2. Proactive Audio Frame Pre-Buffering on Standby Deck at T-15s to T-2s
    if (!kIsWeb &&
        remaining <= const Duration(seconds: 15) &&
        remaining > const Duration(seconds: 2)) {
      if (_standbyBufferedTrackId != nextTrack.id.value &&
          !_isPrebufferingStandby) {
        _primeStandbyDeckForNextTrack(nextTrack);
      }
    }
  }

  void _checkCrossfadeTrigger(Duration pos) {
    if (_isCrossfading ||
        _isTransitioning ||
        _isLoading ||
        _currentSong == null ||
        !isPlaying) {
      return;
    }
    if (_loopMode == LoopMode.one) return;
    if (pos < const Duration(seconds: 5)) return;
    final prefs = PreferencesService();
    if (!prefs.crossfadeEnabled) return;

    final dur = duration;
    if (dur == null || dur.inSeconds <= 15) return;

    // Only crossfade if there is a next track in queue or one can be preloaded
    if (_playlist.isEmpty) return;
    if (!_isShuffle && _currentIndex + 1 >= _playlist.length) {
      if (_loopMode != LoopMode.all) {
        _checkAndPreloadNextQueue();
        if (_currentIndex + 1 >= _playlist.length) return;
      }
    }

    int crossfadeSec = prefs.crossfadeSeconds;
    if (prefs.smartCrossfadeEnabled) {
      // Smart Sync: Synchronize crossfade duration to 4 musical bars based on BPM
      final profile = prefs.audioProfile;
      if (profile.avgTempo > 60 && profile.avgTempo < 200) {
        final beatSec = 60.0 / profile.avgTempo;
        // 4 bars of 4/4 time = 16 beats
        crossfadeSec = (16 * beatSec).clamp(3.0, 9.0).round();
      } else if (dur.inMinutes >= 4 && crossfadeSec < 6) {
        crossfadeSec = (crossfadeSec + 2).clamp(1, 10);
      } else if (dur.inMinutes <= 2 && crossfadeSec > 4) {
        crossfadeSec = (crossfadeSec - 1).clamp(2, 6);
      }
    }

    final remaining = dur - pos;
    // Proactively pre-resolve upcoming track 5 seconds before crossfade initiates so network delay is eliminated
    if (remaining <= Duration(seconds: crossfadeSec + 5) &&
        remaining > Duration(seconds: crossfadeSec)) {
      if (_isShuffle && _shuffleHistoryPointer + 1 < _shuffleHistory.length) {
        final nextIdx = _shuffleHistory[_shuffleHistoryPointer + 1];
        if (nextIdx >= 0 && nextIdx < _playlist.length) {
          _prewarmSingleTrack(_playlist[nextIdx]);
        }
      } else if (_currentIndex + 1 < _playlist.length) {
        _prewarmSingleTrack(_playlist[_currentIndex + 1]);
      } else if (_loopMode == LoopMode.all && _playlist.isNotEmpty) {
        _prewarmSingleTrack(_playlist[0]);
      }
    }

    if (remaining <= Duration(seconds: crossfadeSec) &&
        remaining > const Duration(milliseconds: 600)) {
      _triggerCrossfade(Duration(seconds: crossfadeSec));
    }
  }

  Future<void> _triggerCrossfade(Duration crossfadeDuration) async {
    if (_isCrossfading || _isTransitioning) return;
    _isCrossfading = true;
    debugPrint(
      '[Crossfade] Starting ${crossfadeDuration.inSeconds}s crossfade merge…',
    );
    try {
      if (kIsWeb) {
        await nextSong(isCrossfade: true);
      } else {
        await nextSong(isCrossfade: true);
      }
    } catch (e) {
      debugPrint('[Crossfade] Transition error: $e');
      _cancelActiveFade();
    } finally {
      _isCrossfading = false;
    }
  }

  Future<void> _startPlaybackWithFade({
    required bool isCrossfade,
    required Future<void> Function() playAction,
  }) async {
    final prefs = PreferencesService();
    final shouldFade = isCrossfade || prefs.fadeInOnStartEnabled;

    if (!shouldFade) {
      await _setVolume(1.0);
      await playAction();
      return;
    }

    // Never mute to 0.0 because Android hardware AudioTrack can initialize muted.
    // Start from 0.3 so it is audible from the first millisecond and smoothly reaches 1.0.
    await _setVolume(0.3);
    await playAction();

    unawaited(() async {
      try {
        await _fadeVolume(
          from: 0.3,
          to: 1.0,
          duration: isCrossfade
              ? const Duration(milliseconds: 1000)
              : const Duration(milliseconds: 600),
        );
      } catch (_) {
      } finally {
        await _setVolume(1.0);
      }
    }());
  }

  Future<void> loadLikedSongs() async {
    try {
      await FavoritesRepository().load();
      _likedSongs = FavoritesRepository().legacyLikedSongs;
      _restoreLikedSongsMemoryCaches();
      notifyListeners();
    } catch (e) {
      debugPrint('Error loading liked songs: $e');
    }
  }

  void _restoreLikedSongsMemoryCaches() {
    for (final item in _likedSongs) {
      final id = item['id'] ?? '';
      final thumb = item['thumbnail'] ?? '';
      final stream = item['streamUrl'] ?? '';
      if (id.isNotEmpty) {
        if (thumb.isNotEmpty && !_artworkMap.containsKey(id)) {
          _artworkMap[id] = thumb;
        }
        if (stream.isNotEmpty && !_webStreamUrls.containsKey(id)) {
          _webStreamUrls[id] = stream;
        }
      }
    }
  }

  void toggleLike(Video song) async {
    try {
      final item = SongItem.fromVideo(
        song,
        streamUrl: _webStreamUrls[song.id.value] ?? '',
      );
      await FavoritesRepository().toggleLike(item);
      _likedSongs = FavoritesRepository().legacyLikedSongs;
      notifyListeners();
    } catch (e) {
      debugPrint('Error toggling like: $e');
    }
  }

  Future<void> removeLikedSong(String videoId) async {
    try {
      await FavoritesRepository().removeLiked(videoId);
      _likedSongs = FavoritesRepository().legacyLikedSongs;
      notifyListeners();
    } catch (e) {
      debugPrint('Error removing liked song: $e');
    }
  }

  Future<void> loadCustomPlaylists() async {
    try {
      if (kIsWeb) {
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString('custom_playlists_web');
        if (raw != null && raw.isNotEmpty) {
          final List<dynamic> jsonList = json.decode(raw);
          _customPlaylists = List<Map<String, dynamic>>.from(jsonList);
          _restorePlaylistMemoryCaches();
          notifyListeners();
        }
        return;
      }
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/custom_playlists.json');
      if (await file.exists()) {
        final content = await file.readAsString();
        final List<dynamic> jsonList = json.decode(content);
        _customPlaylists = List<Map<String, dynamic>>.from(jsonList);
        _restorePlaylistMemoryCaches();
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Error loading custom playlists: $e');
    }
  }

  void _restorePlaylistMemoryCaches() {
    for (final playlist in _customPlaylists) {
      final songs = playlist['songs'] as List<dynamic>? ?? [];
      for (final s in songs) {
        if (s is Map<String, dynamic>) {
          final id = s['id'] as String? ?? '';
          final thumb = s['thumbnail'] as String? ?? '';
          final streamUrl = s['streamUrl'] as String? ?? '';
          final lang = s['language'] as String? ?? '';
          if (id.isNotEmpty) {
            if (thumb.isNotEmpty && !_artworkMap.containsKey(id)) {
              _artworkMap[id] = thumb;
            }
            if (streamUrl.isNotEmpty && !_webStreamUrls.containsKey(id)) {
              _webStreamUrls[id] = streamUrl;
            }
            if (lang.isNotEmpty) {
              CanonicalSongDedup.registerSongLanguage(id, lang);
            }
          }
        }
      }
    }
  }

  Future<void> saveCustomPlaylists() async {
    try {
      if (kIsWeb) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          'custom_playlists_web',
          json.encode(_customPlaylists),
        );
        return;
      }
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/custom_playlists.json');
      await file.writeAsString(json.encode(_customPlaylists));
    } catch (e) {
      debugPrint('Error saving custom playlists: $e');
    }
  }

  String createPlaylist(
    String name, {
    bool isSpotify = false,
    String source = 'custom',
  }) {
    final playlistId =
        '${DateTime.now().millisecondsSinceEpoch}_${_customPlaylists.length}';
    return createPlaylistWithId(
      playlistId,
      name,
      isSpotify: isSpotify,
      source: source,
    );
  }

  String createPlaylistWithId(
    String playlistId,
    String name, {
    bool isSpotify = false,
    String source = 'custom',
  }) {
    // If playlist with this ID already exists, return existing
    final existingIndex = _customPlaylists.indexWhere(
      (p) => p['id'] == playlistId,
    );
    if (existingIndex != -1) {
      if (isSpotify) {
        _customPlaylists[existingIndex]['isSpotify'] = true;
        _customPlaylists[existingIndex]['source'] = source;
        saveCustomPlaylists();
      }
      return playlistId;
    }
    _customPlaylists.add({
      'id': playlistId,
      'name': name,
      'songs': [],
      'isSpotify': isSpotify,
      'source': source,
    });
    saveCustomPlaylists();
    notifyListeners();
    return playlistId;
  }

  void setPlaylistSource(String playlistId, {required bool isSpotify}) {
    final idx = _customPlaylists.indexWhere((p) => p['id'] == playlistId);
    if (idx != -1) {
      _customPlaylists[idx]['isSpotify'] = isSpotify;
      _customPlaylists[idx]['source'] = isSpotify ? 'spotify' : 'custom';
      saveCustomPlaylists();
      notifyListeners();
    }
  }

  void addSongToPlaylist(String playlistId, Video song) {
    addSongsToPlaylist(playlistId, [song]);
  }

  /// High-performance batch addition of songs to avoid repeated disk serialization
  void addSongsToPlaylist(
    String playlistId,
    List<Video> songs, {
    bool commit = true,
  }) {
    if (songs.isEmpty) return;
    final playlistIndex = _customPlaylists.indexWhere(
      (p) => p['id'] == playlistId,
    );
    if (playlistIndex != -1) {
      final existingSongs = List<Map<String, dynamic>>.from(
        _customPlaylists[playlistIndex]['songs'] ?? [],
      );
      final existingIds = existingSongs.map((s) => s['id'] as String).toSet();
      bool modified = false;

      for (final song in songs) {
        if (!existingIds.contains(song.id.value)) {
          existingIds.add(song.id.value);
          existingSongs.add({
            'id': song.id.value,
            'title': song.title,
            'author': song.author,
            'thumbnail': getHdThumbnail(song.id.value),
            'streamUrl': _webStreamUrls[song.id.value] ?? '',
          });
          modified = true;
        }
      }

      if (modified) {
        _customPlaylists[playlistIndex]['songs'] = existingSongs;
        if (commit) {
          saveCustomPlaylists();
          notifyListeners();
        }
      }
    }
  }

  /// Sets or updates all songs in a playlist, preserving exact order and updating storage
  void setPlaylistSongs(
    String playlistId,
    List<Video> songs, {
    bool commit = true,
  }) {
    final playlistIndex = _customPlaylists.indexWhere(
      (p) => p['id'] == playlistId,
    );
    if (playlistIndex != -1) {
      final songMaps = songs
          .map(
            (song) => {
              'id': song.id.value,
              'title': song.title,
              'author': song.author,
              'thumbnail': getHdThumbnail(song.id.value),
              'streamUrl': _webStreamUrls[song.id.value] ?? '',
            },
          )
          .toList();

      _customPlaylists[playlistIndex]['songs'] = songMaps;
      if (commit) {
        saveCustomPlaylists();
        notifyListeners();
      }
    }
  }

  Future<void> reorderPlaylistSongs(
    String playlistId,
    int oldIndex,
    int newIndex,
  ) async {
    final playlistIndex = _customPlaylists.indexWhere(
      (p) => p['id'] == playlistId,
    );
    if (playlistIndex == -1) return;

    final songs = List<Map<String, dynamic>>.from(
      _customPlaylists[playlistIndex]['songs'] ?? [],
    );
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
    if (oldIndex < 0 ||
        oldIndex >= songs.length ||
        newIndex < 0 ||
        newIndex >= songs.length) {
      return;
    }

    final item = songs.removeAt(oldIndex);
    songs.insert(newIndex, item);

    _customPlaylists[playlistIndex]['songs'] = songs;
    await saveCustomPlaylists();
    notifyListeners();
  }

  Future<void> removeSongFromPlaylist(String playlistId, String songId) async {
    final playlistIndex = _customPlaylists.indexWhere(
      (p) => p['id'] == playlistId,
    );
    if (playlistIndex == -1) return;

    final songs = List<Map<String, dynamic>>.from(
      _customPlaylists[playlistIndex]['songs'] ?? [],
    );
    songs.removeWhere((s) => s['id'] == songId);

    _customPlaylists[playlistIndex]['songs'] = songs;
    await saveCustomPlaylists();
    notifyListeners();
  }

  bool isLiked(String videoId) {
    return _likedSongs.any((s) => s['id'] == videoId);
  }

  bool isDownloaded(String videoId) {
    return _downloadedSongs.any((s) => s['id'] == videoId);
  }

  void playNext(Video song) {
    if (_playlist.isEmpty) {
      playSong(song);
      return;
    }
    // Remove duplicate instance if already in playlist (avoiding current track)
    for (int i = _playlist.length - 1; i >= 0; i--) {
      if (i != _currentIndex &&
          (_playlist[i].id.value == song.id.value ||
              CanonicalSongDedup.areDuplicateSongs(
                titleA: _playlist[i].title,
                artistA: _playlist[i].author,
                titleB: song.title,
                artistB: song.author,
              ))) {
        _playlist.removeAt(i);
        if (i < _currentIndex) _currentIndex--;
      }
    }
    final insertIndex = (_currentIndex + 1).clamp(0, _playlist.length);
    _playlist.insert(insertIndex, song);
    notifyListeners();
  }

  void addToQueue(Video song) {
    if (_playlist.isEmpty) {
      playSong(song);
      return;
    }
    // Check if duplicate already exists anywhere in queue
    final isDup = _playlist.any(
      (item) =>
          item.id.value == song.id.value ||
          CanonicalSongDedup.areDuplicateSongs(
            titleA: item.title,
            artistA: item.author,
            titleB: song.title,
            artistB: song.author,
          ),
    );
    if (isDup) {
      debugPrint(
        '[Queue] Song "${song.title}" already exists in queue. Skipping duplicate.',
      );
      return;
    }
    _playlist.add(song);
    notifyListeners();
  }

  void reorderQueue(int oldIndex, int newIndex) {
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
    if (oldIndex < 0 ||
        oldIndex >= _playlist.length ||
        newIndex < 0 ||
        newIndex >= _playlist.length) {
      return;
    }
    final currentSong = _currentSong;
    final song = _playlist.removeAt(oldIndex);
    _playlist.insert(newIndex, song);

    if (currentSong != null) {
      final newCurrent = _playlist.indexWhere((s) => s.id == currentSong.id);
      if (newCurrent != -1) _currentIndex = newCurrent;
    }
    notifyListeners();
  }

  void removeFromQueue(int index) {
    if (index < 0 || index >= _playlist.length) return;
    final currentSong = _currentSong;
    _playlist.removeAt(index);
    if (currentSong != null) {
      final newCurrent = _playlist.indexWhere((s) => s.id == currentSong.id);
      if (newCurrent != -1) {
        _currentIndex = newCurrent;
      } else if (_currentIndex >= _playlist.length) {
        _currentIndex = _playlist.isNotEmpty ? _playlist.length - 1 : 0;
      }
    }
    notifyListeners();
  }

  Future<void> renamePlaylist(String playlistId, String newName) async {
    final cleanName = newName.trim();
    if (cleanName.isEmpty) return;
    final playlistIndex = _customPlaylists.indexWhere(
      (p) => p['id'] == playlistId,
    );
    if (playlistIndex != -1) {
      _customPlaylists[playlistIndex]['name'] = cleanName;
      await saveCustomPlaylists();
      notifyListeners();
    }
  }

  Future<void> deletePlaylist(String playlistId) async {
    _customPlaylists.removeWhere((p) => p['id'] == playlistId);
    await saveCustomPlaylists();
    notifyListeners();
  }

  Future<void> playCustomPlaylist(
    String playlistId,
    int startIndex, {
    bool? enableShuffle,
  }) async {
    final playlist = _customPlaylists.firstWhere(
      (p) => p['id'] == playlistId,
      orElse: () => <String, dynamic>{},
    );
    if (playlist.isEmpty) return;

    final songs = List<Map<String, dynamic>>.from(playlist['songs'] ?? []);
    if (songs.isEmpty) return;

    for (final item in songs) {
      final id = (item['id'] as String?) ?? '';
      final thumb = (item['thumbnail'] as String?) ?? '';
      final stream = (item['streamUrl'] as String?) ?? '';
      if (id.isNotEmpty) {
        if (thumb.isNotEmpty) _artworkMap[id] = thumb;
        if (stream.isNotEmpty) _webStreamUrls[id] = stream;
      }
    }

    _playlist = songs
        .map(
          (item) => Video(
            VideoId((item['id'] as String?) ?? ''),
            (item['title'] as String?) ?? 'Unknown Title',
            (item['author'] as String?) ?? 'Unknown Artist',
            ChannelId('UC0WP5P-fwGlLyO4yOE76T8g'),
            DateTime.now(),
            '',
            null,
            '',
            null,
            ThumbnailSet((item['id'] as String?) ?? ''),
            null,
            Engagement(0, null, null),
            false,
          ),
        )
        .toList();

    _currentIndex = startIndex;
    if (_currentIndex < 0 || _currentIndex >= _playlist.length) {
      _currentIndex = 0;
    }

    if (enableShuffle != null) {
      _isShuffle = enableShuffle;
      if (!kIsWeb) {
        _activePlayer.setShuffleModeEnabled(_isShuffle);
      }
    }

    _seedPlaylistArtists = _extractArtistsFromSongs(_playlist);
    _playlistArtistRecommendationOffset = 0;

    // Proactively pre-warm upcoming tracks in background so instant rapid skips never buffer!
    _prewarmUpcomingTracks(_currentIndex, count: 4);

    await playSong(_playlist[_currentIndex], updateQueue: false);
  }

  void _prewarmUpcomingTracks(int fromIndex, {int count = 3}) {
    if (_playlist.isEmpty) return;
    for (int offset = 0; offset < count; offset++) {
      int idx = fromIndex + offset;
      if (idx >= _playlist.length) {
        if (_loopMode == LoopMode.all) {
          idx = idx % _playlist.length;
        } else {
          break;
        }
      }
      final track = _playlist[idx];
      final trackId = track.id.value;
      if (_webStreamUrls[trackId] != null &&
          _webStreamUrls[trackId]!.isNotEmpty) {
        continue;
      }
      _prewarmSingleTrack(track);
    }
  }

  Future<void> _prewarmSingleTrack(Video track) async {
    final trackId = track.id.value;
    if (_webStreamUrls[trackId] != null &&
        _webStreamUrls[trackId]!.isNotEmpty) {
      return;
    }
    try {
      final cleanT = CanonicalSongDedup.cleanTitle(track.title);
      final cleanA = CanonicalSongDedup.cleanArtist(track.author);
      final q = cleanA.isNotEmpty ? '$cleanT $cleanA' : cleanT;
      if (cleanT.isNotEmpty) {
        final jioUri = ApiConfig.jioSearchUri(q, limit: 5);
        final resp = await http.get(jioUri).timeout(const Duration(seconds: 4));
        if (resp.statusCode == 200) {
          final List<dynamic> list = json.decode(resp.body);
          for (final item in list) {
            final itemTitle = item['title'] as String? ?? '';
            final itemArtist = item['author'] as String? ?? '';
            final itemStream = item['streamUrl'] as String? ?? '';
            final itemThumb = item['thumbnail'] as String? ?? '';
            if (itemStream.isEmpty) continue;
            if (_isCoverOrKaraokeTrack(itemTitle, itemArtist)) continue;

            final isMatch = CanonicalSongDedup.areDuplicateSongs(
              titleA: track.title,
              artistA: track.author,
              titleB: itemTitle,
              artistB: itemArtist,
            );

            if (isMatch) {
              _webStreamUrls[trackId] = itemStream;
              cacheWebStreamUrl(trackId, itemStream);
              if (itemThumb.isNotEmpty) {
                final current = _artworkMap[trackId];
                final isYtFallback =
                    current == null ||
                    current.isEmpty ||
                    current.startsWith('https://i.ytimg.com/');
                if (isYtFallback) {
                  _artworkMap[trackId] = itemThumb;
                  notifyListeners();
                }
              }
              return;
            }
          }
        }
      }

      // Proactively pre-resolve native YouTube stream candidate if JioSaavn wasn't matched
      if (!kIsWeb &&
          (_webStreamUrls[trackId] == null ||
              _webStreamUrls[trackId]!.isEmpty)) {
        final candidates = await _resolveStreamCandidates(trackId);
        if (candidates.isNotEmpty) {
          _webStreamUrls[trackId] = candidates.first.url;
        }
      }
    } catch (_) {}
  }

  /// Primes and pre-buffers the incoming track directly onto the standby deck.
  /// When this track is subsequently requested, the engine can execute an instant 0ms handoff.
  Future<void> _primeStandbyDeckForNextTrack(Video nextTrack) async {
    if (kIsWeb) return;
    final trackId = nextTrack.id.value;
    if (_standbyBufferedTrackId == trackId || _isPrebufferingStandby) return;

    final token = _activePlaySessionToken;
    _isPrebufferingStandby = true;

    try {
      if (!kIsWeb) {
        final downloadedItem = _downloadedSongs.firstWhere(
          (item) => item['id'] == trackId,
          orElse: () => {},
        );
        final localItem = downloadedItem.isNotEmpty
            ? downloadedItem
            : (_deviceAudioService.getSongById(trackId) ?? {});
        if (localItem.isNotEmpty && localItem['localPath'] != null) {
          final localFile = File(localItem['localPath']!);
          if (localFile.existsSync()) {
            final mediaItem = MediaItem(
              id: trackId,
              album: localItem['album'] ?? 'DilSe',
              title: nextTrack.title,
              artist: nextTrack.author,
              artUri: Uri.tryParse(getHdThumbnail(trackId)),
              duration: nextTrack.duration,
            );
            await _standbyPlayer.setAudioSource(
              AudioSource.uri(Uri.file(localFile.path), tag: mediaItem),
              preload: true,
            );
            if (token == _activePlaySessionToken) {
              _standbyBufferedTrackId = trackId;
              debugPrint(
                '[Gapless] Deck B primed & pre-buffered for local track "${nextTrack.title}"',
              );
            }
            return;
          }
        }
      }

      if (_webStreamUrls[trackId] == null || _webStreamUrls[trackId]!.isEmpty) {
        await _prewarmSingleTrack(nextTrack);
      }
      if (token != _activePlaySessionToken) return;

      final streamUrl = _webStreamUrls[trackId];
      if (streamUrl != null && streamUrl.isNotEmpty) {
        final mediaItem = MediaItem(
          id: trackId,
          album: 'DilSe',
          title: nextTrack.title,
          artist: nextTrack.author,
          artUri: Uri.tryParse(getHdThumbnail(trackId)),
          duration: nextTrack.duration,
        );

        final AudioSource source = streamUrl.contains('googlevideo.com')
            ? AudioSource.uri(
                Uri.parse(streamUrl),
                headers: _ytHeaders,
                tag: mediaItem,
              )
            : AudioSource.uri(Uri.parse(streamUrl), tag: mediaItem);

        await _standbyPlayer.setAudioSource(source, preload: true);
        if (token == _activePlaySessionToken) {
          _standbyBufferedTrackId = trackId;
          debugPrint(
            '[Gapless] Deck B primed & pre-buffered for "${nextTrack.title}"',
          );
        }
      }
    } catch (e) {
      debugPrint('[Gapless] Standby pre-buffering silent fail: $e');
    } finally {
      _isPrebufferingStandby = false;
    }
  }

  Future<void> playLikedSong(
    Map<String, String> songData, {
    bool? enableShuffle,
  }) async {
    for (final item in _likedSongs) {
      final id = item['id'] ?? '';
      final thumb = item['thumbnail'] ?? '';
      final stream = item['streamUrl'] ?? '';
      if (id.isNotEmpty) {
        if (thumb.isNotEmpty) _artworkMap[id] = thumb;
        if (stream.isNotEmpty) _webStreamUrls[id] = stream;
      }
    }

    _playlist = _likedSongs
        .map(
          (item) => Video(
            VideoId(item['id'] ?? ''),
            item['title'] ?? 'Unknown Title',
            item['author'] ?? 'Unknown Artist',
            ChannelId('UC0WP5P-fwGlLyO4yOE76T8g'),
            DateTime.now(),
            '',
            null,
            '',
            null,
            ThumbnailSet(item['id'] ?? ''),
            null,
            Engagement(0, null, null),
            false,
          ),
        )
        .toList();

    _currentIndex = _likedSongs.indexWhere(
      (item) => item['id'] == songData['id'],
    );
    if (_currentIndex == -1) _currentIndex = 0;
    if (_playlist.isNotEmpty) {
      if (enableShuffle != null) {
        _isShuffle = enableShuffle;
        if (!kIsWeb) {
          _activePlayer.setShuffleModeEnabled(_isShuffle);
        }
      }

      _seedPlaylistArtists = _extractArtistsFromSongs(_playlist);
      _playlistArtistRecommendationOffset = 0;
      _prewarmUpcomingTracks(_currentIndex, count: 4);
      await playSong(_playlist[_currentIndex], updateQueue: false);
    }
  }

  void seekRelative(Duration offset) {
    final current = position;
    final target = current + offset;
    seek(target);
  }

  void toggleShuffle() {
    _isShuffle = !_isShuffle;
    _shuffleHistory.clear();
    _shuffleHistoryPointer = -1;
    if (_isShuffle && _currentIndex >= 0 && _currentIndex < _playlist.length) {
      _shuffleHistory.add(_currentIndex);
      _shuffleHistoryPointer = 0;
    }
    if (!kIsWeb) {
      _audioPlayer.setShuffleModeEnabled(_isShuffle);
    }
    notifyListeners();
  }

  void toggleRepeat() {
    _hasRepeatedOnce = false;
    if (_loopMode == LoopMode.off) {
      _loopMode = LoopMode.all;
    } else if (_loopMode == LoopMode.all) {
      _loopMode = LoopMode.one;
    } else {
      _loopMode = LoopMode.off;
    }
    if (!kIsWeb) {
      // Keep just_audio loop mode at off so track completion events are dispatched to Dart,
      // allowing us to repeat the track once and advance cleanly without infinite loops.
      try {
        _audioPlayer.setLoopMode(LoopMode.off);
      } catch (_) {}
    }
    notifyListeners();
    _syncWidgetPlayback();
  }

  static bool _isCoverOrKaraokeTrack(
    String title,
    String author, {
    String? query,
  }) {
    final lowerTitle = title.toLowerCase();
    final lowerAuthor = author.toLowerCase();
    final q = (query ?? '').toLowerCase();

    // If the user explicitly searched for karaoke, cover, or instrumental, allow it
    if (q.contains('karaoke') ||
        q.contains('instrumental') ||
        q.contains('tribute') ||
        q.contains('backing track') ||
        q.contains('cover')) {
      return false;
    }

    const badKeywords = [
      'karaoke',
      'originally performed',
      'in the style of',
      'tribute to',
      'tribute version',
      'tribute band',
      'cover version',
      'cover classics',
      'cover song',
      'female cover',
      'male cover',
      'acoustic cover',
      'backing track',
      'piano version',
      'guitar backing',
      'sing-along',
      'acoustic tribute',
      'tabata',
      'power music',
      'workout mix',
      'workout music',
      'workout track',
      'fitness beats',
      'gym music',
      'gym workout',
      'carnatic mix',
      'lo-fi mix',
      'lofi mix',
      'slowed + reverb',
      'slowed and reverb',
      'speed up',
      'sped up',
      'zzang',
      'luxebeats',
      'sweet strings',
      'boostereo',
      'shadow tower',
      'party hits band',
      'karaoke party',
      'the hit crew',
      'the covers',
    ];

    for (final bad in badKeywords) {
      if (lowerTitle.contains(bad) || lowerAuthor.contains(bad)) {
        return true;
      }
    }
    return false;
  }

  /// 3-Tier Source Cascade Search:
  /// Tier 1: JioSaavn (320kbps studio master audio)
  /// Tier 2: YouTube Music (Clean official releases, no video sketches)
  /// Tier 3: YouTube Standard (Safety net fallback)
  /// Guaranteed Zero Cross-Source Duplicates via CanonicalSongDedup.
  static final RegExp _compilationAlbumRegex = RegExp(
    r'(?:best of|greatest hits|top \d+|collection|compilation|party mix|mashup|jukebox|hits of|evergreen|all time hits|vol\.?\s*\d+|volume\s*\d+|chartbusters|blockbusters|divine melodies|melodies of|love hits|romantic hits|soulful melodies|top romantic|sweet melodies|popular hits|tribute to|melody hits|playlist|non[\s-]*stop|instrumental version)',
    caseSensitive: false,
  );
  static final Set<String> _compilationArtworks = {};

  List<Video> _parseJioResults(String body, {String? query}) {
    final List<Video> list = [];
    try {
      final List<dynamic> jsonList = json.decode(body);
      for (var item in jsonList) {
        final songId = item['id'] as String? ?? '';
        if (songId.isEmpty) continue;
        final rawTitle = item['title'] as String? ?? 'Unknown Title';
        final rawAuthor = item['author'] as String? ?? 'DilSe Music';
        final cleanA = CanonicalSongDedup.cleanArtist(rawAuthor);
        final author = cleanA.isNotEmpty ? cleanA : rawAuthor;
        final title = CanonicalSongDedup.sanitizeDisplayTitle(
          rawTitle,
          artist: author,
        );
        final album = item['album'] as String? ?? '';
        final durationSec = item['duration'] != null
            ? int.tryParse(item['duration'].toString())
            : null;
        final duration = durationSec != null
            ? Duration(seconds: durationSec)
            : null;
        final artwork = item['thumbnail'] as String? ?? '';
        final streamUrl = item['streamUrl'] as String? ?? '';

        if (_isCoverOrKaraokeTrack(title, author, query: query)) {
          continue;
        }

        final isCompilation =
            _compilationAlbumRegex.hasMatch(album) ||
            _compilationAlbumRegex.hasMatch(title);
        final vidString = songId.length >= 11
            ? songId.substring(0, 11)
            : songId.padRight(11, '0');

        if (artwork.isNotEmpty) {
          if (isCompilation) {
            _compilationArtworks.add(artwork);
            // Only set compilation thumbnail if we don't already have one
            if (!_artworkMap.containsKey(songId)) _artworkMap[songId] = artwork;
            if (!_artworkMap.containsKey(vidString)) {
              _artworkMap[vidString] = artwork;
            }
          } else {
            // Genuine soundtrack artwork: always overwrite or set!
            _artworkMap[songId] = artwork;
            _artworkMap[vidString] = artwork;
          }
        }
        if (streamUrl.isNotEmpty) {
          _webStreamUrls[songId] = streamUrl;
          _webStreamUrls[vidString] = streamUrl;
        }
        final lang = item['language'] as String? ?? '';
        if (lang.isNotEmpty) {
          CanonicalSongDedup.registerSongLanguage(songId, lang);
          CanonicalSongDedup.registerSongLanguage(vidString, lang);
        }
        final albumId =
            item['album_id']?.toString() ?? item['albumId']?.toString() ?? '';
        if (album.isNotEmpty || albumId.isNotEmpty) {
          registerSongAlbum(songId, albumTitle: album, albumId: albumId);
          registerSongAlbum(vidString, albumTitle: album, albumId: albumId);
        }

        final video = Video(
          VideoId(vidString),
          title,
          author,
          ChannelId('UC0WP5P-fwGlLyO4yOE76T8g'),
          DateTime.now(),
          '',
          null,
          '',
          duration,
          ThumbnailSet(vidString),
          null,
          Engagement(0, null, null),
          false,
        );

        if (CanonicalSongDedup.isGenuineSong(video)) {
          list.add(video);
        }
      }
      // Sort results to prioritize genuine movie soundtracks over compilation albums
      list.sort((a, b) {
        final aThumb = _artworkMap[a.id.value] ?? '';
        final bThumb = _artworkMap[b.id.value] ?? '';
        final aIsComp = _compilationArtworks.contains(aThumb);
        final bIsComp = _compilationArtworks.contains(bThumb);
        if (aIsComp && !bIsComp) return 1;
        if (!aIsComp && bIsComp) return -1;
        return 0;
      });
    } catch (_) {}
    return list;
  }

  /// Fetches an optimized, pure JioSaavn Studio 320kbps catalog for Daily Mix.
  /// Strictly guarantees 100% official studio tracks, 0 YouTube video noise,
  /// 0 wedding/DJ noise, and 0 duplicate tracks.
  Future<List<Video>> fetchJioDailyMix(
    DailyMixConfig config, {
    int limit = 35,
  }) async {
    final cleanQuery = config.query.trim();
    if (cleanQuery.isEmpty) return [];

    try {
      final cleanedArtist = PreferencesService.extractSingleLeadArtist(
        cleanQuery.replaceAll(
          RegExp(
            r'\b(hit\s+songs|songs|acoustic\s+chill|hits|chill|melodies)\b',
            caseSensitive: false,
          ),
          '',
        ),
      );

      final futures = <Future<List<Video>>>[];

      // 1. Direct JioSaavn catalog search
      futures.add(
        http
            .get(ApiConfig.jioSearchUri(cleanQuery, limit: limit, page: 1))
            .timeout(const Duration(seconds: 6))
            .then(
              (res) => res.statusCode == 200
                  ? _parseJioResults(res.body, query: cleanQuery)
                  : <Video>[],
            )
            .catchError((_) => <Video>[]),
      );

      // 2. Artist-specific studio search if lead artist was resolved
      if (cleanedArtist.isNotEmpty && cleanedArtist != cleanQuery) {
        futures.add(
          http
              .get(
                ApiConfig.jioSearchUri(
                  '$cleanedArtist hits',
                  limit: limit,
                  page: 1,
                ),
              )
              .timeout(const Duration(seconds: 6))
              .then(
                (res) => res.statusCode == 200
                    ? _parseJioResults(res.body, query: cleanedArtist)
                    : <Video>[],
              )
              .catchError((_) => <Video>[]),
        );
      }

      // 3. JioSaavn Recommendations endpoint for seamless track variety
      final recTarget = cleanedArtist.isNotEmpty ? cleanedArtist : cleanQuery;
      futures.add(
        http
            .get(ApiConfig.jioRecommendationsUri(recTarget, limit: limit))
            .timeout(const Duration(seconds: 6))
            .then(
              (res) => res.statusCode == 200
                  ? _parseJioResults(res.body, query: recTarget)
                  : <Video>[],
            )
            .catchError((_) => <Video>[]),
      );

      final resultsLists = await Future.wait(futures);

      // Progressive deduplication across JioSaavn streams
      final List<Video> combined = [];
      for (final list in resultsLists) {
        final genuine = list
            .where((v) => CanonicalSongDedup.isGenuineSong(v))
            .toList();
        final deduped = CanonicalSongDedup.deduplicateList(combined, genuine);
        combined.addAll(deduped);
      }

      // Fallback: If edge worker returned fewer than 10 tracks, query custom backend JioSaavn if available
      if (combined.length < 10 &&
          PreferencesService().customServerUrl.isNotEmpty) {
        try {
          final backendResp = await http
              .get(ApiConfig.jioBackendSearchUri(cleanQuery, limit: limit))
              .timeout(const Duration(seconds: 5))
              .catchError((_) => http.Response('[]', 500));
          if (backendResp.statusCode == 200) {
            final fallbackList = _parseJioResults(
              backendResp.body,
              query: cleanQuery,
            );
            final genuineFallback = fallbackList
                .where((v) => CanonicalSongDedup.isGenuineSong(v))
                .toList();
            final dedupedFallback = CanonicalSongDedup.deduplicateList(
              combined,
              genuineFallback,
            );
            combined.addAll(dedupedFallback);
          }
        } catch (_) {}
      }

      if (combined.isEmpty) {
        return [];
      }

      // Final deduplication & artist distribution balancing
      final dedupedFinal = CanonicalSongDedup.deduplicateList(combined);
      final balanced = CanonicalSongDedup.balanceArtistDistribution(
        dedupedFinal,
      );
      debugPrint(
        '[Jio Daily Mix] Generated pristine mix with ${balanced.length} 320k tracks for "${config.title}"',
      );
      final result = balanced.take(limit).toList();
      // Fire background artwork enrichment — upgrades compilation/YT covers to original album art
      unawaited(enrichArtworkForSongs(result));
      return result;
    } catch (e) {
      debugPrint('[Jio Daily Mix] Error generating mix: $e');
      return [];
    }
  }

  /// 3-Tier Multi-Engine Search with JioSaavn Studio-First Priority:
  /// Fetches an expansive, multi-dimensional catalog (80-150+ tracks) for an artist across their entire career.
  /// Fans out parallel queries across vocal tracks, melody hits, mass blockbusters, regional classics, and YTM studio releases.
  Future<List<Video>> fetchArtistDiscography(
    String artistName, {
    int page = 1,
  }) async {
    final clean = artistName.trim();
    if (clean.isEmpty) return [];

    try {
      final queries = DynamicArtistService().getArtistDiscographyQueries(
        clean,
        page: page,
      );

      // 1. Parallel fetch across all thematic/album queries on JioSaavn 320k
      final queryLimit = (page == 1) ? 50 : 30;
      final jioFutures = queries.map((q) async {
        try {
          // Subqueries generated by DynamicArtistService are already era/album/theme targeted for this page tier,
          // so fetch page 1 of each specific theme/album to get authentic primary soundtrack cuts.
          final uri = ApiConfig.jioSearchUri(q, limit: queryLimit, page: 1);
          final res = await http.get(uri).timeout(const Duration(seconds: 7));
          if (res.statusCode == 200) {
            return _parseJioResults(res.body, query: clean);
          }
        } catch (_) {}
        return <Video>[];
      }).toList();

      // 2. Parallel companion fetch from YouTube Music InnerTube studio releases
      final ytmQuery = (page == 1)
          ? '$clean songs'
          : (queries.isNotEmpty ? queries.first : '$clean hits $page');
      final ytmFuture = YouTubeMusicClient().searchSongs(ytmQuery, limit: 30);

      final jioResultsLists = await Future.wait(jioFutures);
      final rawYtm = await ytmFuture.catchError((_) => <Video>[]);
      final ytmResults = rawYtm
          .where((v) => CanonicalSongDedup.isGenuineSong(v))
          .toList();

      // 3. Progressive deduplication across streams
      final List<Video> combined = [];
      for (final list in jioResultsLists) {
        final genuineJio = list
            .where((v) => CanonicalSongDedup.isGenuineSong(v))
            .toList();
        final deduped = CanonicalSongDedup.deduplicateList(
          combined,
          genuineJio,
        );
        combined.addAll(deduped);
      }

      final dedupedYtm = CanonicalSongDedup.deduplicateList(
        combined,
        ytmResults,
      );
      combined.addAll(dedupedYtm);

      final finalDeduped = CanonicalSongDedup.deduplicateList(combined);

      debugPrint(
        '[Artist Discography] Fetched ${finalDeduped.length} unique songs for "$clean" (page: $page)',
      );
      return finalDeduped;
    } catch (e) {
      debugPrint(
        '[Artist Discography] Error fetching discography for $clean: $e',
      );
      return [];
    }
  }

  /// Universal Reverse YTM Seed Bridge:
  /// Resolves any song (even JioSaavn numeric IDs) to an 11-char YTM ID,
  /// queries Google's Radio Automix, and re-ranks candidates via TasteMatrixScorer.
  Future<List<Video>> fetchRadioTracksForSong(
    Video seed, {
    int limit = 35,
    String? targetLanguage,
  }) async {
    final lang =
        targetLanguage ?? CanonicalSongDedup.detectLanguage(seed.title);
    List<Video> rawCandidates = [];

    // 1. Resolve 11-char YouTube Video ID
    String? ytmVideoId;
    final isJioSynthetic =
        seed.id.value.endsWith('000') ||
        _webStreamUrls.containsKey(seed.id.value) ||
        !CanonicalSongDedup.isLikelyYouTubeId(seed.id.value);

    if (seed.id.value.length == 11 && !isJioSynthetic) {
      ytmVideoId = seed.id.value;
    } else {
      try {
        final cleanT = CanonicalSongDedup.cleanTitle(seed.title);
        final cleanA = CanonicalSongDedup.cleanArtist(seed.author);
        final query = '$cleanT $cleanA';
        final ytmMatch = await YouTubeMusicClient()
            .searchSongs(query, limit: 1)
            .timeout(const Duration(seconds: 4));
        if (ytmMatch.isNotEmpty && ytmMatch.first.id.value.length == 11) {
          ytmVideoId = ytmMatch.first.id.value;
        }
      } catch (e) {
        debugPrint('[RadioBridge] YTM ID lookup failed: $e');
      }
    }

    // 2. Fetch Radio Automix from YouTube Music Graph
    if (ytmVideoId != null) {
      try {
        rawCandidates = await YouTubeMusicClient()
            .fetchRadioTracks(ytmVideoId, limit: 40)
            .timeout(const Duration(seconds: 6));
      } catch (e) {
        debugPrint('[RadioBridge] Radio tracks fetch failed: $e');
      }
    }

    // 3. Fallback: Query JioSaavn / YTM search if radio graph returned empty
    if (rawCandidates.isEmpty) {
      final cleanArtist = CanonicalSongDedup.cleanArtist(seed.author);
      final fallbackQuery = cleanArtist.isNotEmpty
          ? (lang != null ? '$cleanArtist $lang hits' : '$cleanArtist hits')
          : (lang != null ? '$lang top songs' : 'Top Hits 2026');
      try {
        final jioFallback = await http
            .get(ApiConfig.jioSearchUri(fallbackQuery, limit: 25))
            .timeout(const Duration(seconds: 4))
            .then((res) => _parseJioResults(res.body))
            .catchError((_) => <Video>[]);
        rawCandidates.addAll(jioFallback);
      } catch (_) {}
    }

    // 4. Client-Side Re-Ranking via TasteMatrixScorer
    final likedTitles = likedSongs
        .map((s) => (s['title'] ?? '').toString())
        .toList();
    final scored = TasteMatrixScorer().scoreAndRankCandidates(
      rawCandidates,
      targetLanguage: lang,
      likedSongTitles: likedTitles,
      maxResults: limit,
    );
    // Fire background artwork enrichment — upgrades compilation/YT covers to original album art
    unawaited(enrichArtworkForSongs(scored));
    return scored;
  }

  /// Tier 1: JioSaavn (320kbps studio releases with pristine album covers)
  /// Tier 2: YouTube Music (Official studio releases via InnerTube)
  /// Tier 3: YouTube Standard (Safety net fallback only if Jio + YTM have < 8 results)
  /// Guaranteed Zero Cross-Source Duplicates & 100% Genuine Audio via CanonicalSongDedup.
  Future<List<Video>> searchSongs(
    String query, {
    int page = 1,
    int limit = 50,
  }) async {
    if (query.trim().isEmpty) return [];

    // Transparently expand to multi-dimensional discography if query is a verified artist
    if (DynamicArtistService().isKnownArtist(query)) {
      final discography = await fetchArtistDiscography(query, page: page);
      if (discography.isNotEmpty) return discography;
    }

    try {
      final int jioLimit = limit.clamp(10, 60);
      final int ytmLimit = (limit * 0.7).round().clamp(10, 50);

      // 1. Tier 1: JioSaavn search (highest priority for 320k studio quality)
      final String effectiveJioQuery = page > 1 ? '$query hits' : query;
      final jioFuture = http
          .get(
            ApiConfig.jioSearchUri(
              effectiveJioQuery,
              limit: jioLimit,
              page: page,
            ),
          )
          .timeout(const Duration(seconds: 8));

      // 2. Tier 2: YouTube Music Search (official releases)
      final ytmFuture = YouTubeMusicClient().searchSongs(
        query,
        limit: ytmLimit,
      );

      final jioResponse = await jioFuture.catchError(
        (_) => http.Response('[]', 500),
      );
      List<Video> jioResults = jioResponse.statusCode == 200
          ? _parseJioResults(jioResponse.body, query: query)
          : [];

      // Supplement with recommendations for artists if initial results are under 25
      if (page == 1 && jioResults.length < 25) {
        try {
          final recResp = await http
              .get(ApiConfig.jioRecommendationsUri(query, limit: jioLimit))
              .timeout(const Duration(seconds: 5))
              .catchError((_) => http.Response('[]', 500));
          if (recResp.statusCode == 200) {
            final recList = _parseJioResults(recResp.body, query: query);
            if (recList.isNotEmpty) {
              final dedupedRec = CanonicalSongDedup.deduplicateList(
                jioResults,
                recList,
              );
              jioResults = [...jioResults, ...dedupedRec];
            }
          }
        } catch (_) {}
      }

      // Deduplicate Tier 1 JioSaavn results against itself immediately
      jioResults = CanonicalSongDedup.deduplicateList(
        jioResults.where((v) => CanonicalSongDedup.isGenuineSong(v)).toList(),
      );

      // Await Tier 2 in parallel and filter genuine tracks
      final rawYtm = await ytmFuture.catchError((_) => <Video>[]);
      final ytmResults = rawYtm
          .where((v) => CanonicalSongDedup.isGenuineSong(v))
          .toList();

      // Fallback: If JioSaavn from edge worker returned fewer than 8 genuine tracks, query the custom backend if configured
      if (jioResults.length < 8 &&
          PreferencesService().customServerUrl.isNotEmpty) {
        try {
          final backendJioResp = await http
              .get(ApiConfig.jioBackendSearchUri(query, limit: 20))
              .timeout(const Duration(seconds: 4))
              .catchError((_) => http.Response('[]', 500));
          if (backendJioResp.statusCode == 200) {
            final fallbackList = _parseJioResults(
              backendJioResp.body,
              query: query,
            );
            if (fallbackList.isNotEmpty) {
              final dedupedFallback = CanonicalSongDedup.deduplicateList(
                jioResults,
                fallbackList,
              );
              jioResults = [...jioResults, ...dedupedFallback];
            }
          }
        } catch (_) {}
      }

      // Tier 3: YouTube Standard backend (safety net ONLY if JioSaavn + YTM return 0 tracks and custom backend is configured)
      final List<Video> backendResults = [];
      if (jioResults.isEmpty &&
          ytmResults.isEmpty &&
          PreferencesService().customServerUrl.isNotEmpty) {
        final backendResponse = await http
            .get(ApiConfig.searchUri(query, page: page, limit: 15))
            .timeout(const Duration(seconds: 5))
            .catchError((_) => http.Response('[]', 500));

        if (backendResponse.statusCode == 200) {
          try {
            final List<dynamic> jsonList = json.decode(backendResponse.body);
            for (var item in jsonList) {
              final videoId = item['id'] as String;
              final title = item['title'] as String? ?? 'Unknown Title';
              final author = item['author'] as String? ?? 'Unknown Artist';
              final durationSec = item['duration'] != null
                  ? int.tryParse(item['duration'].toString())
                  : null;
              final duration = durationSec != null
                  ? Duration(seconds: durationSec)
                  : null;

              final video = Video(
                VideoId(videoId),
                title,
                author,
                ChannelId('UC0WP5P-fwGlLyO4yOE76T8g'),
                DateTime.now(),
                '',
                null,
                '',
                duration,
                ThumbnailSet(videoId),
                null,
                Engagement(0, null, null),
                false,
              );

              // Strict audio validation: drop non-music, speeches, trailers, cricket clips
              if (CanonicalSongDedup.isGenuineSong(video)) {
                backendResults.add(video);
              }
            }
          } catch (_) {}
        }
      }

      // Deduplicate Tier 2 against Tier 1
      final dedupedYtm = CanonicalSongDedup.deduplicateList(
        jioResults,
        ytmResults,
      );

      // Deduplicate Tier 3 against JioSaavn + YTM
      final known = <Video>[...jioResults, ...dedupedYtm];
      final dedupedYt = CanonicalSongDedup.deduplicateList(
        known,
        backendResults,
      );

      final combined = <Video>[...jioResults, ...dedupedYtm, ...dedupedYt];
      final ranked = _rankSearchResults(combined, query);
      debugPrint(
        '[Studio Search] Returned ${ranked.length} songs (${jioResults.length} Jio + ${dedupedYtm.length} YTM + ${dedupedYt.length} YT)',
      );
      // Fire background artwork enrichment — does not block return
      unawaited(enrichArtworkForSongs(ranked));
      return ranked;
    } catch (e) {
      debugPrint('[Studio Search] Error: $e');
    }

    return [];
  }

  /// Exposes search ranking for test suites
  @visibleForTesting
  List<Video> rankSearchResults(List<Video> songs, String rawQuery) =>
      _rankSearchResults(songs, rawQuery);

  /// Spotify-grade Search Relevance & Quality Re-ranking
  List<Video> _rankSearchResults(List<Video> songs, String rawQuery) {
    if (songs.isEmpty || rawQuery.trim().isEmpty) return songs;

    // Filter genuine songs first and deduplicate pool via CanonicalSongDedup
    final cleanPool = songs
        .where((s) => CanonicalSongDedup.isGenuineSong(s))
        .toList();
    final dedupedSongs = CanonicalSongDedup.deduplicateList(cleanPool);

    final q = rawQuery.trim().toLowerCase();
    final cleanQ = CanonicalSongDedup.cleanTitle(rawQuery);
    final queryTokens = q
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();

    final scored = <MapEntry<Video, double>>[];
    final seenKeys = <String>{};

    for (int i = 0; i < dedupedSongs.length; i++) {
      final song = dedupedSongs[i];
      final title = song.title.toLowerCase();
      final cleanT = CanonicalSongDedup.cleanTitle(song.title);
      final author = song.author.toLowerCase();
      final cleanA = CanonicalSongDedup.cleanArtist(song.author);

      final dedupKey = '$cleanT|$cleanA';
      if (!seenKeys.add(dedupKey)) {
        continue;
      }

      double score = 0.0;

      // 1. Exact Title Match (e.g. "Perfect" == "perfect")
      if (cleanT == cleanQ || title == q) {
        score += 1000.0;
      } else if (cleanT.startsWith(cleanQ)) {
        score += 500.0;
      } else if (cleanT.contains(cleanQ)) {
        score += 250.0;
      }

      // 2. Token overlap score
      for (final token in queryTokens) {
        if (cleanT.contains(token) || title.contains(token)) {
          score += 100.0;
        }
      }

      // 3. Artist Match (user searched artist name e.g. "Ed Sheeran", "SPB")
      if (cleanA == cleanQ || author == q) {
        score += 600.0;
      } else if (cleanA.contains(cleanQ) || author.contains(q)) {
        score += 300.0;
      }

      // 4. Standalone Song vs Movie Tag penalty:
      // If user searched a simple standalone title like "perfect", penalize noisy tags like (From "...")
      if (cleanQ.split(' ').length <= 2) {
        if (title.contains('from "') ||
            title.contains("from '") ||
            title.contains('soundtrack')) {
          score -= 150.0;
        }
        if (title.contains('remix') ||
            title.contains('dj mix') ||
            title.contains('dsp mix')) {
          score -= 100.0;
        }
      }

      // 5. Prefer shorter, cleaner titles when query matches
      final lengthPenalty = (cleanT.length - cleanQ.length).clamp(0, 50) * 2.0;
      score -= lengthPenalty;

      // 6. Studio Quality Bonus: JioSaavn 320k studio tracks get overwhelming priority
      final bool isJioStudio =
          _artworkMap.containsKey(song.id.value) ||
          _webStreamUrls.containsKey(song.id.value);
      if (isJioStudio) {
        score += 800.0;
      }

      // 7. Video Noise Penalty: Heavily penalize YouTube video uploads and non-music clips
      final lowerTitle = song.title.toLowerCase();
      if (lowerTitle.contains('official video') ||
          lowerTitle.contains('full video') ||
          lowerTitle.contains('video song') ||
          lowerTitle.contains('4k video') ||
          lowerTitle.contains('hd video') ||
          lowerTitle.contains('status video') ||
          lowerTitle.contains('lyric video') ||
          lowerTitle.contains('dance cover') ||
          lowerTitle.contains('reaction') ||
          lowerTitle.contains('movie scene') ||
          lowerTitle.contains('comedy scene')) {
        score -= 600.0;
      }

      // 8. Preservation of source priority
      final sourceBonus = (dedupedSongs.length - i) * 1.0;
      score += sourceBonus;

      scored.add(MapEntry(song, score));
    }

    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored.map((e) => e.key).toList();
  }

  /// Structured Spotify-grade suggestions (Artist 👤, Song 🎵, History 🕒, Query 🔍)
  Future<List<SearchSuggestion>> fetchEntitySuggestions(
    String query, {
    int limit = 8,
  }) async {
    if (query.trim().isEmpty) return [];

    final suggestions = <SearchSuggestion>[];
    final qLower = query.toLowerCase().trim();

    // 1. Instant Local Search History (🕒)
    final history = PreferencesService().searchHistory;
    for (final item in history) {
      if (item.toLowerCase().contains(qLower)) {
        suggestions.add(
          SearchSuggestion(
            text: item,
            subtitle: 'Recent Search',
            type: SearchSuggestionType.history,
          ),
        );
        if (suggestions.length >= 2) break;
      }
    }

    // 2. Instant Local Top Artists (👤)
    final topArtists = PreferencesService().getTopArtists(limit: 10);
    for (final artist in topArtists) {
      if (artist.toLowerCase().contains(qLower)) {
        suggestions.add(
          SearchSuggestion(
            text: artist,
            subtitle: 'Artist',
            type: SearchSuggestionType.artist,
          ),
        );
        if (suggestions.length >= 4) break;
      }
    }

    // 3. JioSaavn Autocomplete API (clean entity categorization)
    try {
      final response = await http
          .get(ApiConfig.jioSuggestionsUri(query, limit: limit))
          .timeout(const Duration(seconds: 3));
      if (response.statusCode == 200) {
        final List<dynamic> jsonList = json.decode(response.body);
        for (var item in jsonList) {
          final text = item.toString().trim();
          if (text.isEmpty ||
              suggestions.any(
                (s) => s.text.toLowerCase() == text.toLowerCase(),
              )) {
            continue;
          }

          final isArtist = topArtists.any(
            (a) => a.toLowerCase() == text.toLowerCase(),
          );
          suggestions.add(
            SearchSuggestion(
              text: text,
              subtitle: isArtist ? 'Artist' : 'Song',
              type: isArtist
                  ? SearchSuggestionType.artist
                  : SearchSuggestionType.song,
            ),
          );
          if (suggestions.length >= limit) break;
        }
      }
    } catch (_) {}

    // 4. Fill with YouTube suggestions if still sparse
    if (suggestions.length < limit) {
      try {
        final rawStrings = await fetchSuggestions(
          query,
          limit: limit - suggestions.length,
        );
        for (final str in rawStrings) {
          if (!suggestions.any(
            (s) => s.text.toLowerCase() == str.toLowerCase(),
          )) {
            suggestions.add(
              SearchSuggestion(
                text: str,
                subtitle: 'Search',
                type: SearchSuggestionType.query,
              ),
            );
            if (suggestions.length >= limit) break;
          }
        }
      } catch (_) {}
    }

    return suggestions;
  }

  /// Live query suggestions while typing (up to [limit] suggestions)
  Future<List<String>> fetchSuggestions(String query, {int limit = 8}) async {
    if (query.trim().isEmpty) return [];

    // 1. Primary: JioSaavn Instant Edge Suggestions (both Mobile and Web)
    try {
      final response = await http
          .get(ApiConfig.jioSuggestionsUri(query, limit: limit))
          .timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        final List<dynamic> jsonList = json.decode(response.body);
        final list = jsonList.map((e) => e.toString()).toList();
        if (list.isNotEmpty) return list;
      }
    } catch (e) {
      debugPrint('jioSuggestions error: $e');
    }

    // 2. Secondary fallback
    try {
      final response = await http
          .get(ApiConfig.suggestionsUri(query, limit: limit))
          .timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        final List<dynamic> jsonList = json.decode(response.body);
        return jsonList.map((e) => e.toString()).toList();
      }
    } catch (e) {
      debugPrint('fetchSuggestions error: $e');
    }
    return [];
  }

  /// Reports track completion for collaborative filtering co-occurrence
  Future<void> reportTrackFinished(String currentId, String nextId) async {
    try {
      await http
          .post(
            ApiConfig.trackFinishedUri(),
            headers: {'Content-Type': 'application/json'},
            body: json.encode({'current_id': currentId, 'next_id': nextId}),
          )
          .timeout(const Duration(seconds: 5));
      debugPrint(
        '[Collaborative] Reported track transition: $currentId -> $nextId',
      );
    } catch (e) {
      debugPrint('reportTrackFinished error: $e');
    }
  }

  /// Fetches the next 20 songs using collaborative patterns, genre, and radio
  Future<List<Video>> fetchNextCandidates(
    String videoId, {
    int limit = 20,
    String? title,
    String? artist,
  }) async {
    try {
      final response = await http
          .get(
            ApiConfig.nextCandidatesUri(
              videoId,
              limit: limit,
              title: title,
              artist: artist,
            ),
          )
          .timeout(const Duration(seconds: 12));
      if (response.statusCode == 200) {
        final List<dynamic> jsonList = json.decode(response.body);
        final List<Video> results = [];
        for (var item in jsonList) {
          final vid = item['id'] as String;
          final title = item['title'] as String? ?? 'Unknown Title';
          final author = item['author'] as String? ?? 'Unknown Artist';
          final durationSec = item['duration'] != null
              ? int.tryParse(item['duration'].toString())
              : null;
          results.add(
            Video(
              VideoId(vid),
              title,
              author,
              ChannelId('UC0WP5P-fwGlLyO4yOE76T8g'),
              DateTime.now(),
              '',
              null,
              '',
              durationSec != null ? Duration(seconds: durationSec) : null,
              ThumbnailSet(vid),
              null,
              Engagement(0, null, null),
              false,
            ),
          );
        }
        return results;
      }
    } catch (e) {
      debugPrint('fetchNextCandidates error: $e');
    }
    return [];
  }

  Future<void> _extractPalette(String videoId) async {
    try {
      final thumbUrl = getHdThumbnail(videoId);
      final imageUrl = thumbUrl.isNotEmpty
          ? thumbUrl
          : 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg';
      final palette = await PaletteGenerator.fromImageProvider(
        NetworkImage(imageUrl),
        size: const Size(100, 100),
        maximumColorCount: 12,
      ).timeout(const Duration(seconds: 3));

      // Guard against race condition: discard if song changed while extracting
      if (_currentSong?.id.value != videoId) return;

      final dominant =
          palette.dominantColor?.color ??
          palette.vibrantColor?.color ??
          const Color(0xFF1E1E2C);
      final vibrant =
          palette.vibrantColor?.color ??
          palette.lightVibrantColor?.color ??
          dominant;
      final darkVibrant =
          palette.darkVibrantColor?.color ??
          palette.darkMutedColor?.color ??
          dominant;

      _dominantColor = dominant;
      _vibrantColor = vibrant;
      _darkVibrantColor = darkVibrant;
      AlbumColorDeriver.registerExtractedPalette(
        videoId,
        dominant,
        vibrant,
        darkVibrant,
      );
      notifyListeners();
    } catch (e) {
      debugPrint('[Palette] Extraction error: $e');
      if (_currentSong != null && _currentSong?.id.value == videoId) {
        final palette = AlbumColorDeriver.getPalette(_currentSong!);
        _dominantColor = palette.dominant;
        _vibrantColor = palette.vibrant;
        _darkVibrantColor = palette.darkVibrant;
        notifyListeners();
      }
    }
  }

  void startSleepTimer(Duration duration) {
    cancelSleepTimer();
    _sleepEndTime = DateTime.now().add(duration);
    _stopAtEndOfTrack = false;
    notifyListeners();

    _sleepCountdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final rem = sleepRemaining;
      if (rem == null || rem == Duration.zero) {
        timer.cancel();
        _stopPlayback();
      } else {
        // Smooth 5-second fade-out before stopping
        if (rem.inSeconds <= 5 && rem.inSeconds > 0) {
          final vol = (rem.inSeconds / 5.0).clamp(0.0, 1.0);
          if (!kIsWeb) {
            _audioPlayer.setVolume(vol);
          } else {
            WebPlayerBridge.setVolume(vol);
          }
        }
        notifyListeners();
      }
    });
  }

  void setStopAtEndOfTrack(bool enable) {
    cancelSleepTimer();
    _stopAtEndOfTrack = enable;
    notifyListeners();
  }

  void cancelSleepTimer() {
    _sleepEndTime = null;
    _sleepCountdownTimer?.cancel();
    _sleepCountdownTimer = null;
    _stopAtEndOfTrack = false;
    if (!kIsWeb) {
      _audioPlayer.setVolume(1.0);
    } else {
      WebPlayerBridge.setVolume(1.0);
    }
    notifyListeners();
  }

  void _stopPlayback() {
    persistPlaybackSession(force: true);
    if (kIsWeb) {
      WebPlayerBridge.pause();
      WebPlayerBridge.setVolume(1.0);
    } else {
      _audioPlayer.pause();
      _audioPlayer.setVolume(1.0);
    }
    cancelSleepTimer();
    notifyListeners();
    _syncWidgetPlayback();
  }

  Future<void> playPlaylist(
    List<Video> playlist,
    int index, {
    bool? enableShuffle,
  }) async {
    _playlist = List.from(playlist);
    _currentIndex = index;
    if (enableShuffle != null) {
      _isShuffle = enableShuffle;
      if (!kIsWeb) {
        _activePlayer.setShuffleModeEnabled(_isShuffle);
      }
    }

    _seedPlaylistArtists = _extractArtistsFromSongs(_playlist);
    _playlistArtistRecommendationOffset = 0;
    if (_currentIndex >= 0 && _currentIndex < _playlist.length) {
      await playSong(_playlist[_currentIndex], updateQueue: false);
    }
  }

  /// Starts an instant smart radio seeded by [song], resetting the queue and
  /// populating a 50-song progressive queue scored by TasteMatrixScorer.
  Future<void> startSongRadio(Video song) async {
    _playlist = [song];
    _currentIndex = 0;
    _seedPlaylistArtists = [];
    _playlistArtistRecommendationOffset = 0;
    await playSong(song, updateQueue: false);
    _generate50SongProgressiveQueue(song);
  }

  void _checkAndPreloadNextQueue() {
    // When repeat mode is on (all or one), do not append recommendations to the queue
    if (_loopMode == LoopMode.all || _loopMode == LoopMode.one) return;

    // When 5 or fewer songs remain after current playing song, silently load next recommendations
    if ((_playlist.length - (_currentIndex + 1)) <= 5 && _currentSong != null) {
      final seedSong = _playlist.isNotEmpty ? _playlist.last : _currentSong!;
      _fetchNextRecommendations(seedSong);
    }
  }

  Future<void> nextSong({
    bool isCrossfade = false,
    bool isAutoAdvance = false,
  }) async {
    final now = DateTime.now();
    if (_isNavigatingNext ||
        (!isCrossfade &&
            !isAutoAdvance &&
            now.difference(_lastNextClickTime).inMilliseconds < 150)) {
      debugPrint('[MusicService] Rapid Next click spam discarded.');
      return;
    }
    _isNavigatingNext = true;
    _lastNextClickTime = now;

    try {
      if (!isCrossfade && _isCrossfading) {
        _cancelActiveFade();
      }

      if (_stopAtEndOfTrack) {
        debugPrint(
          '[SleepTimer] Reached end of current track. Stopping playback.',
        );
        _stopPlayback();
        return;
      }

      if (_currentSong != null && _audioPlayer.position.inSeconds < 30) {
        PreferencesService().recordSongSkip(_currentSong!.author);
      }

      if (_playlist.isNotEmpty) {
        if (_isShuffle && _playlist.length > 1) {
          // If navigating forward within existing shuffle history
          if (_shuffleHistoryPointer + 1 < _shuffleHistory.length) {
            _shuffleHistoryPointer++;
            _currentIndex = _shuffleHistory[_shuffleHistoryPointer];
          } else {
            // Select next song avoiding consecutive artist repetition
            final random = Random();
            final currentArtist = _currentSong != null
                ? CanonicalSongDedup.cleanArtist(_currentSong!.author)
                : '';

            final candidateIndices = <int>[];
            for (int i = 0; i < _playlist.length; i++) {
              if (i == _currentIndex) continue;
              final artist = CanonicalSongDedup.cleanArtist(
                _playlist[i].author,
              );
              if (currentArtist.isEmpty || artist != currentArtist) {
                candidateIndices.add(i);
              }
            }

            int nextIdx;
            if (candidateIndices.isNotEmpty) {
              nextIdx =
                  candidateIndices[random.nextInt(candidateIndices.length)];
            } else {
              nextIdx =
                  (random.nextInt(_playlist.length - 1) + _currentIndex + 1) %
                  _playlist.length;
            }

            _currentIndex = nextIdx;
            _shuffleHistory.add(_currentIndex);
            _shuffleHistoryPointer = _shuffleHistory.length - 1;
          }

          final prevSong = _currentSong;
          final nextTrack = _playlist[_currentIndex];
          if (prevSong != null) {
            reportTrackFinished(prevSong.id.value, nextTrack.id.value);
          }
          await playSong(
            nextTrack,
            updateQueue: false,
            isCrossfade: isCrossfade,
          );
          _prewarmUpcomingTracks(_currentIndex + 1, count: 3);
          _checkAndPreloadNextQueue();
          return;
        } else if (_currentIndex + 1 < _playlist.length) {
          final prevSong = _currentSong;
          _currentIndex++;
          final nextTrack = _playlist[_currentIndex];
          if (prevSong != null) {
            reportTrackFinished(prevSong.id.value, nextTrack.id.value);
          }
          await playSong(
            nextTrack,
            updateQueue: false,
            isCrossfade: isCrossfade,
          );
          _prewarmUpcomingTracks(_currentIndex + 1, count: 3);
          _checkAndPreloadNextQueue();
          return;
        }
      }

      if (_loopMode == LoopMode.all && _playlist.isNotEmpty) {
        _currentIndex = 0;
        final nextTrack = _playlist[_currentIndex];
        await playSong(nextTrack, updateQueue: false, isCrossfade: isCrossfade);
        _prewarmUpcomingTracks(_currentIndex + 1, count: 3);
        _checkAndPreloadNextQueue();
        return;
      }

      if (_currentSong != null) {
        debugPrint(
          '[Queue] End of queue reached. Fetching next recommendations…',
        );
        _isLoading = true;
        notifyListeners();
        await _fetchNextRecommendations(_currentSong!);
        if (_currentIndex + 1 < _playlist.length) {
          final prevSong = _currentSong;
          _currentIndex++;
          final nextTrack = _playlist[_currentIndex];
          if (prevSong != null) {
            reportTrackFinished(prevSong.id.value, nextTrack.id.value);
          }
          await playSong(
            nextTrack,
            updateQueue: false,
            isCrossfade: isCrossfade,
          );
          _prewarmUpcomingTracks(_currentIndex + 1, count: 3);
          _checkAndPreloadNextQueue();
        } else {
          _isLoading = false;
          notifyListeners();
        }
      }
    } finally {
      _isNavigatingNext = false;
    }
  }

  Future<void> previousSong() async {
    final now = DateTime.now();
    if (_isNavigatingPrev ||
        now.difference(_lastPrevClickTime).inMilliseconds < 150) {
      debugPrint('[MusicService] Rapid Prev click spam discarded.');
      return;
    }
    _isNavigatingPrev = true;
    _lastPrevClickTime = now;

    try {
      if (_isCrossfading) {
        _cancelActiveFade();
      }

      // If played for more than 3 seconds, replay current song from beginning
      if (position.inSeconds > 3) {
        if (kIsWeb) {
          WebPlayerBridge.seek(Duration.zero);
          notifyListeners();
        } else {
          await _audioPlayer.seek(Duration.zero);
        }
        return;
      }

      // 1. If in shuffle mode and history exists, traverse back through true shuffle history
      if (_isShuffle && _shuffleHistoryPointer > 0) {
        _shuffleHistoryPointer--;
        _currentIndex = _shuffleHistory[_shuffleHistoryPointer];
        await playSong(_playlist[_currentIndex], updateQueue: false);
        _prewarmUpcomingTracks(_currentIndex + 1, count: 2);
        return;
      }

      // 2. Cross-playlist global navigation history:
      // If user played songs from different playlists, seamlessly go back to the previous song!
      if (_sessionPlayedHistory.isNotEmpty) {
        final prevSong = _sessionPlayedHistory.removeLast();
        _isNavigatingHistory = true;
        try {
          final existingIdx = _playlist.indexWhere(
            (s) => s.id.value == prevSong.id.value,
          );
          if (existingIdx != -1) {
            _currentIndex = existingIdx;
            await playSong(_playlist[_currentIndex], updateQueue: false);
          } else {
            // Song was from another playlist/album: insert into current queue right before current song
            _playlist.insert(_currentIndex, prevSong);
            await playSong(prevSong, updateQueue: false);
          }
        } finally {
          _isNavigatingHistory = false;
        }
        return;
      }

      // 3. Normal sequential playback previous
      if (_playlist.isNotEmpty && _currentIndex - 1 >= 0) {
        _currentIndex--;
        await playSong(_playlist[_currentIndex], updateQueue: false);
        _prewarmUpcomingTracks(_currentIndex + 1, count: 2);
      }
    } finally {
      _isNavigatingPrev = false;
    }
  }

  Future<void> skipToQueueIndex(int index) async {
    if (index < 0 || index >= _playlist.length) return;
    if (_currentIndex == index && isPlaying) return;
    if (_isCrossfading) {
      _isCrossfading = false;
      unawaited(_setVolume(1.0));
    }
    _currentIndex = index;
    _prewarmUpcomingTracks(_currentIndex + 1, count: 3);
    await playSong(_playlist[_currentIndex], updateQueue: false);
  }

  Future<void> playCustomPlaylistWithShuffle(String playlistId) async {
    final playlist = _customPlaylists.firstWhere(
      (p) => p['id'] == playlistId,
      orElse: () => <String, dynamic>{},
    );
    if (playlist.isEmpty) return;

    final songs = List<Map<String, dynamic>>.from(playlist['songs'] ?? []);
    if (songs.isEmpty) return;

    final randomIndex = Random().nextInt(songs.length);
    _isShuffle = true;
    if (!kIsWeb) {
      _activePlayer.setShuffleModeEnabled(true);
    }
    notifyListeners();
    await playCustomPlaylist(playlistId, randomIndex, enableShuffle: true);
  }

  // Full browser headers to avoid CDN 403s and throttling
  static const Map<String, String> _ytHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/125.0.0.0 Safari/537.36',
    'Accept': '*/*',
    'Accept-Language': 'en-US,en;q=0.9',
    'Origin': 'https://www.youtube.com',
    'Referer': 'https://www.youtube.com/',
  };

  /// Fetches the stream URL from the backend.
  /// [bustCache] forces the backend to re-extract the URL (used on retry).
  Future<String?> _fetchStreamUrl(
    String videoId, {
    bool bustCache = false,
  }) async {
    try {
      if (bustCache) {
        // Tell backend to discard its cached URL for this video
        await http
            .delete(ApiConfig.cacheInvalidateUri(videoId))
            .timeout(const Duration(seconds: 3));
      }
      final response = await http
          .get(ApiConfig.streamUrlUri(videoId))
          .timeout(const Duration(seconds: 20));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data['url'] as String?;
      }
    } catch (e) {
      debugPrint('_fetchStreamUrl error: $e');
    }
    return null;
  }

  void _reportClientLog(String stage, Map<String, dynamic> data) {
    try {
      final payload = {
        'stage': stage,
        'timestamp': DateTime.now().toIso8601String(),
        ...data,
      };
      if (_clientLogRingBuffer.length >= 25) {
        _clientLogRingBuffer.removeAt(0);
      }
      _clientLogRingBuffer.add(payload);
      http
          .post(
            ApiConfig.clientLogUri(),
            headers: {'Content-Type': 'application/json'},
            body: json.encode(payload),
          )
          .timeout(const Duration(seconds: 4))
          .catchError((_) => http.Response('', 500));
    } catch (_) {}
  }

  /// Dynamically alters JioSaavn CDN audio bitrate based on active AudioQualityPreset.
  static String adaptJioSaavnBitrate(String url, AudioQualityPreset quality) {
    if (!url.contains('saavncdn.com') && !url.contains('saavn')) return url;

    String targetSuffix;
    switch (quality) {
      case AudioQualityPreset.studioMaster:
        targetSuffix = '_320';
        break;
      case AudioQualityPreset.high:
        targetSuffix = '_160';
        break;
      case AudioQualityPreset.balanced:
        targetSuffix = '_160';
        break;
      case AudioQualityPreset.dataSaver:
        targetSuffix = '_48';
        break;
    }

    return url.replaceAllMapped(
      RegExp(r'_(320|160|96|48|12)\.(mp4|m4a|mp3)'),
      (match) => '$targetSuffix.${match.group(2)}',
    );
  }

  /// Resolves ordered stream candidates natively on the user's device,
  /// strictly adhering to the user's AudioQualityPreset and AudioFormatPreference.
  Future<List<StreamCandidate>> _resolveStreamCandidates(String videoId) async {
    StreamManifest? manifest;

    try {
      manifest = await _ytExplode.videos.streamsClient
          .getManifest(videoId)
          .timeout(const Duration(milliseconds: 3500));
    } catch (e) {
      debugPrint('[StreamResolver] StreamClient error for $videoId: $e');
      _reportClientLog('resolve_error', {
        'videoId': videoId,
        'error': e.toString(),
      });
    }

    if (manifest == null) return [];

    final quality = PreferencesService().audioQuality;
    final formatPref = PreferencesService().audioFormat;

    final List<StreamCandidate> candidates = [];

    // Separate available stream categories
    final muxed18List = manifest.muxed.where((s) => s.tag == 18).toList();
    final muxed22List = manifest.muxed.where((s) => s.tag == 22).toList();
    final otherMuxedList = manifest.muxed
        .where((s) => s.tag != 18 && s.tag != 22)
        .toList();

    // Opus audio-only streams (itag 251 @ 160kbps, 250 @ 70kbps, 249 @ 50kbps)
    final opusStreams = manifest.audioOnly
        .where(
          (s) =>
              s.container.name.toLowerCase() == 'webm' ||
              s.codec.mimeType.contains('webm') ||
              s.codec.mimeType.contains('opus'),
        )
        .toList();

    // AAC audio-only streams (itag 140 @ 128kbps, 139 @ 48kbps)
    final aacStreams = manifest.audioOnly
        .where(
          (s) =>
              s.container.name.toLowerCase() == 'mp4' ||
              s.codec.mimeType.contains('mp4') ||
              s.codec.mimeType.contains('aac') ||
              s.codec.mimeType.contains('mp4a'),
        )
        .toList();

    // Sort streams according to quality preset (bitrate orientation)
    // For data saver: sort ascending (lowest bitrate first)
    // For high / studio master: sort descending (highest bitrate first)
    if (quality == AudioQualityPreset.dataSaver) {
      opusStreams.sort(
        (a, b) => a.bitrate.bitsPerSecond.compareTo(b.bitrate.bitsPerSecond),
      );
      aacStreams.sort(
        (a, b) => a.bitrate.bitsPerSecond.compareTo(b.bitrate.bitsPerSecond),
      );
    } else {
      opusStreams.sort(
        (a, b) => b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond),
      );
      aacStreams.sort(
        (a, b) => b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond),
      );
    }

    void addCandidate(
      dynamic s,
      String type, {
      int? defaultBitrate,
      String? codec,
    }) {
      final tag = s.tag as int;
      final url = s.url.toString();
      final kbps = defaultBitrate ?? (s.bitrate.kbitPerSec as num).round();
      final detectedCodec = codec ?? (type.contains('opus') ? 'opus' : 'aac');
      if (!candidates.any((c) => c.url == url)) {
        candidates.add(
          StreamCandidate(
            url,
            tag,
            type,
            bitrateKbps: kbps,
            codec: detectedCodec,
          ),
        );
      }
    }

    if (formatPref == AudioFormatPreference.opus) {
      if (kIsWeb) {
        // Web audio HTML5 elements strictly require AAC / MP4 progressive streams first to prevent decode/CORS stalls
        for (final m in muxed18List) {
          addCandidate(
            m,
            'mp4_progressive_360p_aac',
            defaultBitrate: 128,
            codec: 'aac',
          );
        }
        for (final s in aacStreams) {
          addCandidate(s, 'mp4_audio_dash', codec: 'aac');
        }
      }
      // 1. Opus streams strictly prioritized
      for (final s in opusStreams) {
        addCandidate(s, 'audio_webm_opus', codec: 'opus');
      }
      // 2. AAC / progressive fallbacks
      if (quality == AudioQualityPreset.dataSaver) {
        for (final s in aacStreams) {
          addCandidate(s, 'mp4_audio_dash', codec: 'aac');
        }
        for (final m in muxed18List) {
          addCandidate(
            m,
            'mp4_progressive_360p_aac',
            defaultBitrate: 128,
            codec: 'aac',
          );
        }
      } else {
        for (final m in muxed18List) {
          addCandidate(
            m,
            'mp4_progressive_360p_aac',
            defaultBitrate: 128,
            codec: 'aac',
          );
        }
        for (final s in aacStreams) {
          addCandidate(s, 'mp4_audio_dash', codec: 'aac');
        }
        for (final m in muxed22List) {
          addCandidate(
            m,
            'mp4_progressive_720p_aac',
            defaultBitrate: 192,
            codec: 'aac',
          );
        }
      }
    } else if (formatPref == AudioFormatPreference.aac) {
      // 1. AAC streams strictly prioritized
      if (quality == AudioQualityPreset.dataSaver) {
        for (final s in aacStreams) {
          addCandidate(s, 'mp4_audio_dash', codec: 'aac');
        }
        for (final m in muxed18List) {
          addCandidate(
            m,
            'mp4_progressive_360p_aac',
            defaultBitrate: 128,
            codec: 'aac',
          );
        }
      } else if (quality == AudioQualityPreset.studioMaster ||
          quality == AudioQualityPreset.high) {
        for (final m in muxed22List) {
          addCandidate(
            m,
            'mp4_progressive_720p_aac',
            defaultBitrate: 192,
            codec: 'aac',
          );
        }
        for (final s in aacStreams) {
          addCandidate(s, 'mp4_audio_dash', codec: 'aac');
        }
        for (final m in muxed18List) {
          addCandidate(
            m,
            'mp4_progressive_360p_aac',
            defaultBitrate: 128,
            codec: 'aac',
          );
        }
      } else {
        // Balanced (128 kbps)
        for (final m in muxed18List) {
          addCandidate(
            m,
            'mp4_progressive_360p_aac',
            defaultBitrate: 128,
            codec: 'aac',
          );
        }
        for (final s in aacStreams) {
          addCandidate(s, 'mp4_audio_dash', codec: 'aac');
        }
      }
      // 2. Opus fallbacks
      for (final s in opusStreams) {
        addCandidate(s, 'audio_webm_opus', codec: 'opus');
      }
    } else {
      // Auto (Smart Engine) / MP3
      final bool requiresAacPriority =
          kIsWeb ||
          (!kIsWeb &&
              (defaultTargetPlatform == TargetPlatform.iOS ||
                  defaultTargetPlatform == TargetPlatform.macOS));

      if (requiresAacPriority) {
        // Web HTML5 Audio & Apple AVPlayer natively excel with AAC (.m4a/.mp4)
        if (quality == AudioQualityPreset.studioMaster ||
            quality == AudioQualityPreset.high) {
          for (final m in muxed22List) {
            addCandidate(
              m,
              'mp4_progressive_720p_aac',
              defaultBitrate: 192,
              codec: 'aac',
            );
          }
          for (final s in aacStreams) {
            addCandidate(s, 'mp4_audio_dash', codec: 'aac');
          }
          for (final m in muxed18List) {
            addCandidate(
              m,
              'mp4_progressive_360p_aac',
              defaultBitrate: 128,
              codec: 'aac',
            );
          }
        } else if (quality == AudioQualityPreset.dataSaver) {
          for (final s in aacStreams) {
            addCandidate(s, 'mp4_audio_dash', codec: 'aac');
          }
          for (final m in muxed18List) {
            addCandidate(
              m,
              'mp4_progressive_360p_aac',
              defaultBitrate: 128,
              codec: 'aac',
            );
          }
        } else {
          // Balanced (128 kbps)
          for (final m in muxed18List) {
            addCandidate(
              m,
              'mp4_progressive_360p_aac',
              defaultBitrate: 128,
              codec: 'aac',
            );
          }
          for (final s in aacStreams) {
            addCandidate(s, 'mp4_audio_dash', codec: 'aac');
          }
        }
        // Fallback to Opus only if NOT on web (web browsers choke on DASH Opus webm in <audio>)
        if (!kIsWeb) {
          for (final s in opusStreams) {
            addCandidate(s, 'audio_webm_opus', codec: 'opus');
          }
        }
      } else {
        // Android (ExoPlayer) / Desktop: Opus offers maximum compression & transparency
        if (quality == AudioQualityPreset.dataSaver) {
          // Lowest data usage first
          for (final s in opusStreams) {
            addCandidate(s, 'audio_webm_opus', codec: 'opus');
          }
          for (final s in aacStreams) {
            addCandidate(s, 'mp4_audio_dash', codec: 'aac');
          }
          for (final m in muxed18List) {
            addCandidate(
              m,
              'mp4_progressive_360p_aac',
              defaultBitrate: 128,
              codec: 'aac',
            );
          }
        } else if (quality == AudioQualityPreset.studioMaster ||
            quality == AudioQualityPreset.high) {
          // Highest acoustic fidelity first: itag 251 (160k Opus), muxed22 (192k AAC), muxed18
          for (final s in opusStreams) {
            addCandidate(s, 'audio_webm_opus', codec: 'opus');
          }
          for (final m in muxed22List) {
            addCandidate(
              m,
              'mp4_progressive_720p_aac',
              defaultBitrate: 192,
              codec: 'aac',
            );
          }
          for (final m in muxed18List) {
            addCandidate(
              m,
              'mp4_progressive_360p_aac',
              defaultBitrate: 128,
              codec: 'aac',
            );
          }
          for (final s in aacStreams) {
            addCandidate(s, 'mp4_audio_dash', codec: 'aac');
          }
        } else {
          // Balanced (128 kbps)
          for (final m in muxed18List) {
            addCandidate(
              m,
              'mp4_progressive_360p_aac',
              defaultBitrate: 128,
              codec: 'aac',
            );
          }
          for (final s in opusStreams) {
            addCandidate(s, 'audio_webm_opus', codec: 'opus');
          }
          for (final s in aacStreams) {
            addCandidate(s, 'mp4_audio_dash', codec: 'aac');
          }
        }
      }
    }

    // Safety fallback: any other muxed streams
    for (final m in otherMuxedList) {
      addCandidate(m, 'muxed_${m.container.name}');
    }

    return candidates;
  }

  Future<void> playSong(
    Video song, {
    bool updateQueue = true,
    bool isCrossfade = false,
  }) async {
    final int sessionToken = ++_activePlaySessionToken;

    _savedPosition = null;
    _savedDuration = null;
    _positionBroadcaster.add(Duration.zero);
    if (song.duration != null && song.duration! > Duration.zero) {
      _durationBroadcaster.add(song.duration);
    }

    // ⚡ Check if standby deck already has this exact song pre-buffered
    final bool isPrebufferedOnStandby =
        !kIsWeb && _standbyBufferedTrackId == song.id.value;

    if (isPrebufferedOnStandby) {
      debugPrint('[Gapless] ⚡ Instant 0ms Standby Handoff: "${song.title}"');
      _standbyBufferedTrackId = null;

      _isLoading = false;
      _isCrossfading = false;
      _hasRepeatedOnce = false;

      if (!_isNavigatingHistory &&
          _currentSong != null &&
          _currentSong!.id.value != song.id.value) {
        _sessionPlayedHistory.add(_currentSong!);
        if (_sessionPlayedHistory.length > 50) {
          _sessionPlayedHistory.removeAt(0);
        }
      }
      _currentSong = song;

      if (updateQueue) {
        final existingIndex = _playlist.indexWhere(
          (item) => item.id == song.id,
        );
        if (existingIndex != -1) {
          _currentIndex = existingIndex;
        } else {
          _playlist = [song];
          _currentIndex = 0;
          _seedPlaylistArtists = [];
          _playlistArtistRecommendationOffset = 0;
          _generate50SongProgressiveQueue(song);
        }
      }
      notifyListeners();

      final mediaItem = MediaItem(
        id: song.id.value,
        album: 'DilSe',
        title: song.title,
        artist: song.author,
        artUri: Uri.tryParse(getHdThumbnail(song.id.value)),
        duration: song.duration,
      );
      if (!kIsWeb && audioHandler != null) {
        audioHandler!.changeMediaItem(mediaItem);
        audioHandler!.notifyLoading(isLoading: false);
      }

      if (isCrossfade) {
        await _startDualDeckCrossfade();
      } else {
        final outgoingPlayer = _activePlayer;
        final incomingPlayer = _standbyPlayer;
        _activePlayer = incomingPlayer;
        _standbyPlayer = outgoingPlayer;

        if (audioHandler is DilSeAudioHandler) {
          (audioHandler as DilSeAudioHandler).bindPlayer(_activePlayer);
        }

        try {
          await outgoingPlayer.stop();
        } catch (_) {}

        unawaited(
          incomingPlayer.play().catchError((e) {
            debugPrint('[Gapless] Error starting incoming player: $e');
          }),
        );
      }

      _syncWidgetPlayback();
      persistPlaybackSession(force: true);

      _extractPalette(song.id.value);
      fetchLyrics(song);
      PreferencesService().recordSongPlay(song.author, song.title);
      PreferencesService().addToListeningHistory({
        'id': song.id.value,
        'title': song.title,
        'author': song.author,
        'thumbnail': getHdThumbnail(song.id.value),
        'playedAt': DateTime.now().toIso8601String(),
      });
      if (!kIsWeb) {
        DatabaseService().recordPlay(
          songId: song.id.value,
          title: song.title,
          artist: song.author,
          artworkUrl: getHdThumbnail(song.id.value),
          durationSeconds: song.duration?.inSeconds,
        );
      }

      _prewarmUpcomingTracks(_currentIndex + 1, count: 3);
      _preloadUpcomingTracks();
      _checkAndPreloadNextQueue();
      return;
    }

    // Normal or rapid-skip path: flush standby if it held a different track
    _standbyBufferedTrackId = null;
    if (!isCrossfade) {
      _cancelActiveFade();
      if (kIsWeb && WebPlayerBridge.isPlaying) {
        WebPlayerBridge.pause();
      } else if (!kIsWeb) {
        _standbyPlayer.stop();
        if (_activePlayer.playing) {
          try {
            await _activePlayer.stop();
          } catch (_) {}
        }
      }
      unawaited(_setVolume(1.0));
    } else {
      _isCrossfading = true;
    }

    final AudioPlayer targetPlayer = (!kIsWeb && isCrossfade)
        ? _standbyPlayer
        : _activePlayer;

    _isLoading = true;
    if (!_isNavigatingHistory &&
        _currentSong != null &&
        _currentSong!.id.value != song.id.value) {
      _sessionPlayedHistory.add(_currentSong!);
      if (_sessionPlayedHistory.length > 50) {
        _sessionPlayedHistory.removeAt(0);
      }
    }
    _currentSong = song;
    _hasRepeatedOnce = false;

    if (updateQueue) {
      _consecutivePlaybackFailures = 0;
      _lastFailedSongId = null;
      _songRetryCount = 0;
      final existingIndex = _playlist.indexWhere((item) => item.id == song.id);
      if (existingIndex != -1) {
        _currentIndex = existingIndex;
      } else {
        _playlist = [song];
        _currentIndex = 0;
        _seedPlaylistArtists = [];
        _playlistArtistRecommendationOffset = 0;
        _generate50SongProgressiveQueue(song);
      }
    }
    notifyListeners();

    final mediaItem = MediaItem(
      id: song.id.value,
      album: 'DilSe',
      title: song.title,
      artist: song.author,
      artUri: Uri.tryParse(getHdThumbnail(song.id.value)),
      duration: song.duration,
    );

    if (!kIsWeb && audioHandler != null) {
      audioHandler!.changeMediaItem(mediaItem);
      audioHandler!.notifyLoading(isLoading: true);
    }

    // Trigger palette extraction asynchronously with race-condition guard
    _extractPalette(song.id.value);

    // Pre-fetch lyrics concurrently so they are instant when opened
    fetchLyrics(song);

    // Track play count and history for personalization algorithm
    PreferencesService().recordSongPlay(song.author, song.title);
    PreferencesService().addToListeningHistory({
      'id': song.id.value,
      'title': song.title,
      'author': song.author,
      'thumbnail': getHdThumbnail(song.id.value),
      'playedAt': DateTime.now().toIso8601String(),
    });
    if (!kIsWeb) {
      DatabaseService().recordPlay(
        songId: song.id.value,
        title: song.title,
        artist: song.author,
        artworkUrl: getHdThumbnail(song.id.value),
        durationSeconds: song.duration?.inSeconds,
      );
    }

    final activeFormatPref = PreferencesService().audioFormat;
    final activeQualityPreset = PreferencesService().audioQuality;

    // Proactively check JioSaavn to upgrade track to pristine studio CDN stream
    // (Bypassed if the user explicitly prefers Opus audio format)
    if (activeFormatPref != AudioFormatPreference.opus &&
        (_webStreamUrls[song.id.value] == null ||
            _webStreamUrls[song.id.value]!.isEmpty)) {
      try {
        final cleanT = CanonicalSongDedup.cleanTitle(song.title);
        final cleanA = CanonicalSongDedup.cleanArtist(song.author);
        final q = cleanA.isNotEmpty ? '$cleanT $cleanA' : cleanT;
        if (cleanT.isNotEmpty) {
          Future<bool> tryResolveFromUri(Uri uri) async {
            final jioResp = await http
                .get(uri)
                .timeout(const Duration(milliseconds: 3000));
            if (_currentSong?.id.value != song.id.value ||
                sessionToken != _activePlaySessionToken) {
              return false;
            }
            if (jioResp.statusCode == 200) {
              final List<dynamic> list = json.decode(jioResp.body);
              for (final item in list) {
                final itemTitle = item['title'] as String? ?? '';
                final itemArtist = item['author'] as String? ?? '';
                final itemStream = item['streamUrl'] as String? ?? '';
                final itemThumb = item['thumbnail'] as String? ?? '';
                if (itemStream.isEmpty) continue;
                if (_isCoverOrKaraokeTrack(itemTitle, itemArtist)) continue;

                final isMatch = CanonicalSongDedup.areDuplicateSongs(
                  titleA: song.title,
                  artistA: song.author,
                  titleB: itemTitle,
                  artistB: itemArtist,
                );

                if (isMatch) {
                  final adaptedStream = adaptJioSaavnBitrate(
                    itemStream,
                    activeQualityPreset,
                  );
                  debugPrint(
                    '[Play] Resolved "${song.title}" to JioSaavn stream at ${activeQualityPreset.shortLabel}!',
                  );
                  _webStreamUrls[song.id.value] = adaptedStream;
                  cacheWebStreamUrl(song.id.value, adaptedStream);
                  if (itemThumb.isNotEmpty) {
                    _artworkMap[song.id.value] = itemThumb;
                    PreferencesService().addToListeningHistory({
                      'id': song.id.value,
                      'title': song.title,
                      'author': song.author,
                      'thumbnail': itemThumb,
                      'playedAt': DateTime.now().toIso8601String(),
                    });
                    notifyListeners();
                  }
                  return true;
                }
              }
            }
            return false;
          }

          // 1. Try Cloudflare Worker edge first (ultra-fast 100ms)
          bool matched = await tryResolveFromUri(
            ApiConfig.jioSearchUri(q, limit: 5),
          );

          // 2. If edge didn't match, fallback to custom backend if configured
          if (!matched &&
              _currentSong?.id.value == song.id.value &&
              sessionToken == _activePlaySessionToken &&
              PreferencesService().customServerUrl.isNotEmpty) {
            await tryResolveFromUri(ApiConfig.jioBackendSearchUri(q, limit: 5));
          }
        }
      } catch (_) {}
    }

    try {
      // 1. If this song is downloaded locally or indexed from device storage, play directly from disk (mobile only)

      if (!kIsWeb) {
        final downloadedItem = _downloadedSongs.firstWhere(
          (item) => item['id'] == song.id.value,
          orElse: () => {},
        );

        Map<String, String>? localDeviceItem;
        if (downloadedItem.isEmpty) {
          localDeviceItem = _deviceAudioService.getSongById(song.id.value);
        }

        final targetLocalPath =
            (downloadedItem.isNotEmpty && downloadedItem['localPath'] != null)
            ? downloadedItem['localPath']
            : localDeviceItem?['localPath'];

        if (targetLocalPath != null) {
          final localFile = File(targetLocalPath);
          if (await localFile.exists()) {
            debugPrint('[Play] Playing local audio file: ${localFile.path}');

            await targetPlayer.setAudioSource(
              AudioSource.uri(Uri.file(localFile.path), tag: mediaItem),
            );
            if (isCrossfade) {
              await _startDualDeckCrossfade();
            } else {
              await _startPlaybackWithFade(
                isCrossfade: false,
                playAction: () async => await targetPlayer.play(),
              );
            }

            final isDevice = localDeviceItem != null;
            _activeStreamInfo = ActiveStreamInfo(
              format: isDevice
                  ? (localDeviceItem['format'] ?? 'Local File')
                  : 'Offline Audio',
              qualityLabel: 'Original Quality',
              source: isDevice ? 'Device Storage' : 'Local Storage',

              isHd: true,
            );
            _isLoading = false;
            _consecutivePlaybackFailures = 0;
            _lastFailedSongId = null;
            _songRetryCount = 0;
            notifyListeners();
            _prewarmUpcomingTracks(_currentIndex + 1, count: 3);
            _checkAndPreloadNextQueue();
            return;
          }
        }
      }

      // 2. Web Mode (PWA / Browser):
      // Dual Engine: Cloudflare Edge Direct Stream (<audio>) + YouTube IFrame Fallback
      if (kIsWeb) {
        final directStreamUrl = _webStreamUrls[song.id.value] ?? '';
        String webVideoId = song.id.value;
        final isSyntheticId = !CanonicalSongDedup.isLikelyYouTubeId(webVideoId);

        // If direct stream URL is empty, resolve genuine YouTube ID for web fallback
        if (directStreamUrl.isEmpty) {
          try {
            final cleanT = CanonicalSongDedup.cleanTitle(song.title);
            final cleanA = CanonicalSongDedup.cleanArtist(song.author);
            final ytmQuery = cleanA.isNotEmpty ? '$cleanT $cleanA' : cleanT;
            final ytmResults = await YouTubeMusicClient()
                .searchSongs(ytmQuery, limit: 1)
                .timeout(const Duration(seconds: 4));
            if (ytmResults.isNotEmpty) {
              webVideoId = ytmResults.first.id.value;
            }
          } catch (_) {}
        } else if (isSyntheticId) {
          // If direct stream URL is present, begin playback immediately, but asynchronously
          // resolve genuine YouTube ID in background so triggerFallback() never stalls on synthetic JioSaavn IDs.
          final cleanT = CanonicalSongDedup.cleanTitle(song.title);
          final cleanA = CanonicalSongDedup.cleanArtist(song.author);
          final ytmQuery = cleanA.isNotEmpty ? '$cleanT $cleanA' : cleanT;
          YouTubeMusicClient()
              .searchSongs(ytmQuery, limit: 1)
              .timeout(const Duration(seconds: 4))
              .then((results) {
                if (results.isNotEmpty &&
                    _currentSong?.id.value == song.id.value) {
                  WebPlayerBridge.setFallbackVideoId(results.first.id.value);
                }
              })
              .catchError((_) {});
        }
        if (_currentSong?.id.value != song.id.value) return;
        debugPrint(
          '[Play][Web] Playing via Web Dual Engine: $webVideoId (directStream: $directStreamUrl, isCrossfade: $isCrossfade)',
        );
        _reportClientLog('web_stream_start', {
          'videoId': webVideoId,
          'engine': 'dual',
        });

        if (isCrossfade) {
          final prefs = PreferencesService();
          int crossfadeSec = prefs.crossfadeSeconds;
          if (prefs.smartCrossfadeEnabled) {
            final profile = prefs.audioProfile;
            if (profile.avgTempo > 60 && profile.avgTempo < 200) {
              crossfadeSec = (16 * (60.0 / profile.avgTempo))
                  .clamp(3.0, 9.0)
                  .round();
            }
          }
          debugPrint(
            '[Play][Web] Triggering Web Dual-Deck Crossfade (${crossfadeSec}s) to: $webVideoId',
          );
          WebPlayerBridge.crossfade(
            videoId: webVideoId,
            title: song.title,
            artist: song.author,
            artworkUrl: getHdThumbnail(song.id.value),
            streamUrl: directStreamUrl,
            crossfadeSeconds: crossfadeSec,
          );
        } else {
          _cancelActiveFade();
          unawaited(_setVolume(1.0));
          WebPlayerBridge.play(
            webVideoId,
            title: song.title,
            artist: song.author,
            artworkUrl: getHdThumbnail(song.id.value),
            streamUrl: directStreamUrl,
          );
        }
        final q = PreferencesService().audioQuality;
        _activeStreamInfo = ActiveStreamInfo(
          format: directStreamUrl.isNotEmpty ? 'AAC (.mp4)' : 'Web Stream',
          qualityLabel: q.label,
          source: directStreamUrl.isNotEmpty ? 'Cloudflare CDN' : 'Web Engine',
          isHd:
              q == AudioQualityPreset.studioMaster ||
              q == AudioQualityPreset.high,
        );
        _isLoading = false;
        _consecutivePlaybackFailures = 0;
        _lastFailedSongId = null;
        _songRetryCount = 0;
        notifyListeners();
        _prewarmUpcomingTracks(_currentIndex + 1, count: 3);
        _checkAndPreloadNextQueue();
        return;
      }

      bool playbackSourceSet = false;

      // 3. Mobile Native Mode (Android / iOS app):
      // Check for direct JioSaavn CDN stream first (if user format allows or if synthetic ID)!
      final isSyntheticId = !CanonicalSongDedup.isLikelyYouTubeId(
        song.id.value,
      );
      final directStreamUrl = _webStreamUrls[song.id.value] ?? '';
      final canUseDirectCdn =
          directStreamUrl.isNotEmpty &&
          (isSyntheticId || activeFormatPref != AudioFormatPreference.opus);
      if (canUseDirectCdn) {
        final adaptedStreamUrl = adaptJioSaavnBitrate(
          directStreamUrl,
          activeQualityPreset,
        );
        debugPrint(
          '[Play] Playing via Direct JioSaavn ${activeQualityPreset.shortLabel} Stream on Mobile: ${song.id.value}',
        );
        _reportClientLog('direct_stream_start', {
          'videoId': song.id.value,
          'engine': 'jiosaavn_${activeQualityPreset.shortLabel}',
        });
        try {
          if (_currentSong?.id.value != song.id.value) return;
          await targetPlayer.setAudioSource(
            AudioSource.uri(Uri.parse(adaptedStreamUrl), tag: mediaItem),
          );
          if (_currentSong?.id.value != song.id.value) return;
          if (isCrossfade) {
            await _startDualDeckCrossfade();
          } else {
            await _startPlaybackWithFade(
              isCrossfade: false,
              playAction: () async => await targetPlayer.play(),
            );
          }
          _activeStreamInfo = ActiveStreamInfo(
            format: 'AAC (.mp4)',
            qualityLabel: activeQualityPreset.label,
            source: 'JioSaavn CDN (${activeQualityPreset.shortLabel})',
            isHd:
                activeQualityPreset == AudioQualityPreset.studioMaster ||
                activeQualityPreset == AudioQualityPreset.high,
          );
          _isLoading = false;
          _consecutivePlaybackFailures = 0;
          _lastFailedSongId = null;
          _songRetryCount = 0;
          notifyListeners();
          _prewarmUpcomingTracks(_currentIndex + 1, count: 3);
          _checkAndPreloadNextQueue();
          return;
        } catch (e) {
          debugPrint(
            '[Play] Direct stream error on mobile ($e), falling back to YouTube resolver…',
          );
        }
      }

      // Direct On-Device Multi-Candidate Resolution (Format 18 progressive AAC / itag 251)
      try {
        debugPrint(
          '[Play] Resolving direct audio candidates on mobile device for ${song.id.value} (isSynthetic: $isSyntheticId)…',
        );
        String effectiveYtId = song.id.value;
        List<StreamCandidate> candidates = [];
        if (!isSyntheticId) {
          try {
            candidates = await _resolveStreamCandidates(effectiveYtId);
          } catch (_) {}
        }

        if (candidates.isEmpty && _currentSong?.id.value == song.id.value) {
          try {
            debugPrint(
              '[Play] Searching YouTube Music for real video ID of "${song.title}"…',
            );
            final cleanT = CanonicalSongDedup.cleanTitle(song.title);
            final cleanA = CanonicalSongDedup.cleanArtist(song.author);
            final ytmQuery = cleanA.isNotEmpty ? '$cleanT $cleanA' : cleanT;
            final ytmResults = await YouTubeMusicClient()
                .searchSongs(ytmQuery, limit: 3)
                .timeout(const Duration(milliseconds: 3500));
            if (_currentSong?.id.value != song.id.value) return;
            if (ytmResults.isNotEmpty) {
              effectiveYtId = ytmResults.first.id.value;
              debugPrint(
                '[Play] Found real YouTube track: $effectiveYtId ("${ytmResults.first.title}")',
              );
              candidates = await _resolveStreamCandidates(effectiveYtId);
            }
          } catch (ytmErr) {
            debugPrint('[Play] YouTube Music search fallback error: $ytmErr');
          }
        }

        // Secondary YouTubeExplode standard search fallback if InnerTube / YTM failed
        if (candidates.isEmpty && _currentSong?.id.value == song.id.value) {
          try {
            debugPrint(
              '[Play] Searching YouTube standard via YouTubeExplode for real video ID of "${song.title}"…',
            );
            final cleanT = CanonicalSongDedup.cleanTitle(song.title);
            final cleanA = CanonicalSongDedup.cleanArtist(song.author);
            final ytQuery = cleanA.isNotEmpty ? '$cleanT $cleanA' : cleanT;
            final ytResults = await _ytExplode.search
                .search(ytQuery)
                .timeout(const Duration(milliseconds: 3500));
            if (_currentSong?.id.value != song.id.value) return;
            for (final v in ytResults) {
              if (CanonicalSongDedup.isGenuineSong(v)) {
                effectiveYtId = v.id.value;
                debugPrint(
                  '[Play] Found real YouTube track via standard search: $effectiveYtId ("${v.title}")',
                );
                candidates = await _resolveStreamCandidates(effectiveYtId);
                if (candidates.isNotEmpty) break;
              }
            }
          } catch (ytErr) {
            debugPrint('[Play] YouTube standard search fallback error: $ytErr');
          }
        }

        if (_currentSong?.id.value != song.id.value) return;

        if (candidates.isNotEmpty) {
          final tempDir = await getTemporaryDirectory();

          for (final candidate in candidates) {
            if (_currentSong?.id.value != song.id.value) return;

            debugPrint(
              '[Play] Trying stream candidate (tag: ${candidate.tag}, type: ${candidate.type})…',
            );
            _reportClientLog('trying_stream_candidate', {
              'videoId': effectiveYtId,
              'tag': candidate.tag,
              'type': candidate.type,
            });

            void recordActiveCandidate(StreamCandidate c) {
              String codecName = 'AAC (.mp4)';
              if (c.type.contains('opus') ||
                  c.type.contains('webm') ||
                  c.codec == 'opus') {
                codecName = 'Opus (.webm)';
              } else if (c.type.contains('m4a') || c.tag == 140) {
                codecName = 'AAC (.m4a)';
              }

              String qLabel = '${c.bitrateKbps} kbps';
              if (c.tag == 251) {
                qLabel = '160 kbps (High Fidelity)';
              } else if (c.tag == 22) {
                qLabel = '192 kbps (HD)';
              } else if (c.tag == 249) {
                qLabel = '50 kbps (Data Saver)';
              } else if (c.tag == 250) {
                qLabel = '70 kbps (Eco)';
              } else if (c.tag == 139) {
                qLabel = '48 kbps (Data Saver)';
              } else if (c.tag == 18) {
                qLabel = '128 kbps (Balanced)';
              }

              _activeStreamInfo = ActiveStreamInfo(
                format: codecName,
                qualityLabel: qLabel,
                source: 'YouTube Direct Audio (itag ${c.tag})',
                tag: c.tag,
                isHd: c.tag == 251 || c.tag == 22,
              );
            }

            // 1. First attempt: Direct native AudioSource.uri (fastest, progressive hardware decoding)
            try {
              await targetPlayer.setAudioSource(
                AudioSource.uri(Uri.parse(candidate.url), tag: mediaItem),
                preload: true,
              );
              playbackSourceSet = true;
              recordActiveCandidate(candidate);
              _reportClientLog('playback_started_uri', {
                'videoId': effectiveYtId,
                'tag': candidate.tag,
              });
              break;
            } catch (uriError) {
              debugPrint(
                '[Play] AudioSource.uri failed ($uriError), trying LockCachingAudioSource…',
              );
              // 2. Second attempt: LockCachingAudioSource fallback
              try {
                final cacheFile = File(
                  '${tempDir.path}/track_${effectiveYtId}_${candidate.tag}.m4a',
                );
                if (await cacheFile.exists() && await cacheFile.length() == 0) {
                  await cacheFile.delete();
                }
                await targetPlayer.setAudioSource(
                  // ignore: experimental_member_use
                  LockCachingAudioSource(
                    Uri.parse(candidate.url),
                    cacheFile: cacheFile,
                    tag: mediaItem,
                  ),
                  preload: true,
                );
                playbackSourceSet = true;
                recordActiveCandidate(candidate);
                _reportClientLog('playback_started_lockcache', {
                  'videoId': effectiveYtId,
                  'tag': candidate.tag,
                });
                break;
              } catch (lockError) {
                debugPrint(
                  '[Play] Candidate tag ${candidate.tag} failed: $lockError',
                );
              }
            }
          }
        }
      } catch (directError) {
        if (_isInterrupted(directError)) {
          debugPrint('[Play] Load interrupted by newer request');
          return;
        }
        debugPrint(
          '[Play] Direct resolution error ($directError), trying fallbacks…',
        );
      }

      // 4. Fallback 1: Cloudflare Edge Worker stream
      if (!playbackSourceSet) {
        if (_currentSong?.id.value != song.id.value) return;
        try {
          final cfStreamUri = ApiConfig.cloudflareStreamUri(song.id.value);
          debugPrint(
            '[Play] Fallback 1: Setting audio source to Cloudflare edge stream: $cfStreamUri',
          );
          await targetPlayer.setAudioSource(
            AudioSource.uri(cfStreamUri, tag: mediaItem),
            preload: true,
          );
          playbackSourceSet = true;
        } catch (cfError) {
          debugPrint('[Play] Cloudflare edge stream error: $cfError');
        }
      }

      // 5. Fallback 2: Backend /stream_url (if custom backend configured)
      if (!playbackSourceSet &&
          PreferencesService().customServerUrl.isNotEmpty) {
        if (_currentSong?.id.value != song.id.value) return;
        try {
          debugPrint('[Play] Fallback 2: Requesting /stream_url from backend…');
          final backendUrl = await _fetchStreamUrl(song.id.value);
          if (_currentSong?.id.value != song.id.value) return;
          if (backendUrl != null) {
            await targetPlayer.setAudioSource(
              AudioSource.uri(
                Uri.parse(backendUrl),
                headers: _ytHeaders,
                tag: mediaItem,
              ),
              preload: true,
            );
            playbackSourceSet = true;
          }
        } catch (backendUrlError) {
          debugPrint('[Play] Backend /stream_url error: $backendUrlError');
        }
      }

      // 6. Fallback 3: Backend proxy /stream/{id}.m4a (if custom backend configured)
      if (!playbackSourceSet &&
          PreferencesService().customServerUrl.isNotEmpty) {
        if (_currentSong?.id.value != song.id.value) return;
        final proxyUri = ApiConfig.streamProxyUri(song.id.value);
        debugPrint(
          '[Play] Fallback 3: Setting audio source to proxy: $proxyUri',
        );
        try {
          await targetPlayer.setAudioSource(
            AudioSource.uri(proxyUri, tag: mediaItem),
            preload: true,
          );
          playbackSourceSet = true;
        } catch (proxyError) {
          debugPrint('[Play] Proxy error: $proxyError');
        }
      }

      if (_currentSong?.id.value != song.id.value ||
          sessionToken != _activePlaySessionToken) {
        return;
      }

      if (!playbackSourceSet) {
        _consecutivePlaybackFailures++;
        _isLoading = false;
        _isCrossfading = false;
        if (_consecutivePlaybackFailures >= 3) {
          debugPrint(
            '[Play] 3 consecutive tracks failed resolution. Halting auto-advance loop to protect pipeline.',
          );
          _consecutivePlaybackFailures = 0;
          _showToast('Playback stopped: Multiple tracks could not be loaded');
          _stopPlayback();
          return;
        }

        debugPrint(
          '[Play] Could not resolve stream for "${song.title}". Auto-advancing to next track… (failure $_consecutivePlaybackFailures/3)',
        );
        _showToast('Skipping unplayable track: ${song.title}');
        notifyListeners();
        await nextSong();
        return;
      }

      _consecutivePlaybackFailures = 0;
      _lastFailedSongId = null;
      _songRetryCount = 0;

      debugPrint('[Play] Starting playback…');
      if (!kIsWeb && isCrossfade) {
        await _startDualDeckCrossfade();
      } else {
        await _startPlaybackWithFade(
          isCrossfade: false,
          playAction: () async => await targetPlayer.play(),
        );
      }
      if (sessionToken != _activePlaySessionToken) return;
      _isLoading = false;
      notifyListeners();
      persistPlaybackSession(force: true);
      _syncWidgetPlayback();

      _reportClientLog('playback_active', {
        'videoId': song.id.value,
        'title': song.title,
      });

      _prewarmUpcomingTracks(_currentIndex + 1, count: 3);
      _preloadUpcomingTracks();
      _checkAndPreloadNextQueue();
    } catch (e, st) {
      if (_isInterrupted(e)) {
        debugPrint('[Play] Playback superseded by newer song selection');
        return;
      }
      debugPrint('[Play] Error playing song: $e\n$st');
    } finally {
      if (_currentSong?.id.value == song.id.value &&
          sessionToken == _activePlaySessionToken) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  bool _isInterrupted(dynamic e) {
    final msg = e.toString().toLowerCase();
    return msg.contains('loading interrupted') || msg.contains('interrupted');
  }

  void _preloadUpcomingTracks() {
    if (_playlist.isEmpty) return;
    final nextTracks = _playlist.skip(_currentIndex + 1).take(2);
    for (final track in nextTracks) {
      http
          .get(ApiConfig.preloadUri(track.id.value))
          .catchError((_) => http.Response('', 500));
    }
  }

  List<Video> _getLibraryRecommendationsForSeed(Video seed) {
    final libraryTracks = <Video>[];
    final seen = <String>{
      seed.id.value,
      CanonicalSongDedup.cleanTitle(seed.title),
    };
    final cleanSeedArtist = CanonicalSongDedup.cleanArtist(seed.author);
    final topAffinities = PreferencesService()
        .getTasteMatrix()
        .topArtists
        .map(CanonicalSongDedup.cleanArtist)
        .where((a) => a.isNotEmpty)
        .toSet();

    // Gather all unique songs across user's customPlaylists (the 12k imported library) and liked songs
    final allLibrarySongs = <Map<String, dynamic>>[];
    for (final pl in _customPlaylists) {
      final songs = (pl['songs'] as List<dynamic>?) ?? [];
      for (final s in songs) {
        if (s is Map<String, dynamic>) {
          allLibrarySongs.add(s);
        }
      }
    }
    for (final s in _likedSongs) {
      allLibrarySongs.add(Map<String, dynamic>.from(s));
    }

    if (allLibrarySongs.isEmpty) return [];

    Video toVideo(Map<String, dynamic> item) {
      final id = (item['id'] as String?) ?? '';
      final lang = (item['language'] as String?) ?? '';
      if (id.isNotEmpty && lang.isNotEmpty) {
        CanonicalSongDedup.registerSongLanguage(id, lang);
      }
      return Video(
        VideoId(id),
        (item['title'] as String?) ?? 'Unknown Title',
        (item['author'] as String?) ?? 'Unknown Artist',
        ChannelId('UC0WP5P-fwGlLyO4yOE76T8g'),
        DateTime.now(),
        '',
        null,
        '',
        null,
        ThumbnailSet(id),
        null,
        Engagement(0, null, null),
        false,
      );
    }

    final seedLang = CanonicalSongDedup.detectLanguage(seed.title);

    // Step A: Exact / Collaborating Artist matches from user library
    final artistMatches = <Video>[];
    for (final item in allLibrarySongs) {
      final id = (item['id'] as String?) ?? '';
      final title = (item['title'] as String?) ?? '';
      final author = (item['author'] as String?) ?? '';
      final cleanT = CanonicalSongDedup.cleanTitle(title);
      if (seen.contains(id) || seen.contains(cleanT)) continue;

      if (seedLang != null &&
          !CanonicalSongDedup.isLanguageCompatible(seedLang, title)) {
        continue;
      }

      final cleanA = CanonicalSongDedup.cleanArtist(author);
      if (cleanSeedArtist.isNotEmpty && cleanA.isNotEmpty) {
        if (cleanA == cleanSeedArtist ||
            cleanA.contains(cleanSeedArtist) ||
            cleanSeedArtist.contains(cleanA)) {
          seen.add(id);
          seen.add(cleanT);
          artistMatches.add(toVideo(item));
        }
      }
    }

    // Step B: Top User Taste Matrix Artists matches from user library
    // If seed is English, DO NOT pull Telugu/Hindi library tracks from the taste matrix
    final tasteMatches = <Video>[];
    if (seedLang != 'english') {
      for (final item in allLibrarySongs) {
        final id = (item['id'] as String?) ?? '';
        final title = (item['title'] as String?) ?? '';
        final author = (item['author'] as String?) ?? '';
        final cleanT = CanonicalSongDedup.cleanTitle(title);
        if (seen.contains(id) || seen.contains(cleanT)) continue;

        if (seedLang != null &&
            !CanonicalSongDedup.isLanguageCompatible(seedLang, title)) {
          continue;
        }

        final cleanA = CanonicalSongDedup.cleanArtist(author);
        if (topAffinities.contains(cleanA)) {
          seen.add(id);
          seen.add(cleanT);
          tasteMatches.add(toVideo(item));
        }
      }
    }

    // Step C: Other library tracks from the same playlist that contains the seed song.
    // Guard: Prevent collaborative or mixed compilation playlists from dumping discordant tracks
    // into the queue by verifying artist or user taste compatibility.
    final playlistContextMatches = <Video>[];
    for (final pl in _customPlaylists) {
      final songs = (pl['songs'] as List<dynamic>?) ?? [];
      final hasSeed = songs.any((s) => s is Map && s['id'] == seed.id.value);
      if (hasSeed) {
        for (final s in songs) {
          if (s is! Map<String, dynamic>) continue;
          final vid = toVideo(s);
          if (seedLang != null &&
              !CanonicalSongDedup.isLanguageCompatible(seedLang, vid.title)) {
            continue;
          }
          final cleanA = CanonicalSongDedup.cleanArtist(vid.author);
          final isArtistMatch =
              cleanSeedArtist.isNotEmpty &&
              cleanA.isNotEmpty &&
              (cleanA == cleanSeedArtist ||
                  cleanA.contains(cleanSeedArtist) ||
                  cleanSeedArtist.contains(cleanA));
          final isTasteMatch =
              cleanA.isNotEmpty && topAffinities.contains(cleanA);
          if (!isArtistMatch && !isTasteMatch) {
            continue;
          }
          final cleanT = CanonicalSongDedup.cleanTitle(vid.title);
          if (!seen.contains(vid.id.value) && !seen.contains(cleanT)) {
            seen.add(vid.id.value);
            seen.add(cleanT);
            playlistContextMatches.add(vid);
          }
        }
        break;
      }
    }

    // Step D: Same-language tracks from user's imported library (filtered by taste affinities)
    final languageMatches = <Video>[];
    if (seedLang != null && seedLang != 'english') {
      for (final item in allLibrarySongs) {
        final id = (item['id'] as String?) ?? '';
        final title = (item['title'] as String?) ?? '';
        final author = (item['author'] as String?) ?? '';
        final cleanT = CanonicalSongDedup.cleanTitle(title);
        if (seen.contains(id) || seen.contains(cleanT)) continue;

        if (CanonicalSongDedup.detectLanguage(title) == seedLang ||
            CanonicalSongDedup.isLanguageCompatible(seedLang, title)) {
          final cleanA = CanonicalSongDedup.cleanArtist(author);
          if (topAffinities.contains(cleanA) ||
              (cleanSeedArtist.isNotEmpty && cleanA == cleanSeedArtist)) {
            seen.add(id);
            seen.add(cleanT);
            languageMatches.add(toVideo(item));
          }
        }
      }
    }

    // Shuffle within buckets for fresh variety, then compose prioritized queue
    final random = Random();
    artistMatches.shuffle(random);
    tasteMatches.shuffle(random);
    playlistContextMatches.shuffle(random);
    languageMatches.shuffle(random);

    libraryTracks.addAll(artistMatches.take(15));
    libraryTracks.addAll(playlistContextMatches.take(15));
    libraryTracks.addAll(tasteMatches.take(15));
    libraryTracks.addAll(languageMatches.take(15));

    return libraryTracks;
  }

  List<Video> _getLibraryRecommendationsForArtists(
    List<String> artists, {
    String? targetLang,
  }) {
    if (artists.isEmpty) return [];
    final libraryTracks = <Video>[];
    final seen = <String>{};
    for (final s in _playlist) {
      seen.add(s.id.value);
      seen.add(CanonicalSongDedup.cleanTitle(s.title));
    }

    final allLibrarySongs = <Map<String, dynamic>>[];
    for (final pl in _customPlaylists) {
      final songs = (pl['songs'] as List<dynamic>?) ?? [];
      for (final s in songs) {
        if (s is Map<String, dynamic>) {
          allLibrarySongs.add(s);
        }
      }
    }
    for (final s in _likedSongs) {
      allLibrarySongs.add(Map<String, dynamic>.from(s));
    }

    if (allLibrarySongs.isEmpty) return [];

    Video toVideo(Map<String, dynamic> item) {
      final id = (item['id'] as String?) ?? '';
      return Video(
        VideoId(id),
        (item['title'] as String?) ?? 'Unknown Title',
        (item['author'] as String?) ?? 'Unknown Artist',
        ChannelId('UC0WP5P-fwGlLyO4yOE76T8g'),
        DateTime.now(),
        '',
        null,
        '',
        null,
        ThumbnailSet(id),
        null,
        Engagement(0, null, null),
        false,
      );
    }

    final artistBuckets = <String, List<Video>>{};
    for (final a in artists) {
      artistBuckets[a] = [];
    }

    final random = Random();
    final shuffledLibrary = List<Map<String, dynamic>>.from(allLibrarySongs)
      ..shuffle(random);

    for (final item in shuffledLibrary) {
      final id = (item['id'] as String?) ?? '';
      final title = (item['title'] as String?) ?? '';
      final author = (item['author'] as String?) ?? '';
      final cleanT = CanonicalSongDedup.cleanTitle(title);
      if (seen.contains(id) || seen.contains(cleanT)) continue;

      if (targetLang != null &&
          !CanonicalSongDedup.isLanguageCompatible(targetLang, title)) {
        continue;
      }

      final cleanA = CanonicalSongDedup.cleanArtist(author);
      for (final targetArtist in artists) {
        if (cleanA == targetArtist ||
            cleanA.contains(targetArtist) ||
            targetArtist.contains(cleanA)) {
          seen.add(id);
          seen.add(cleanT);
          artistBuckets[targetArtist]?.add(toVideo(item));
          break;
        }
      }
    }

    // Interleave tracks round-robin across artist buckets
    int maxBucketLen = 0;
    for (final list in artistBuckets.values) {
      if (list.length > maxBucketLen) maxBucketLen = list.length;
    }
    for (int i = 0; i < maxBucketLen; i++) {
      for (final targetArtist in artists) {
        final bucket = artistBuckets[targetArtist];
        if (bucket != null && i < bucket.length) {
          libraryTracks.add(bucket[i]);
        }
      }
    }

    return libraryTracks;
  }

  List<String> _extractArtistsFromSongs(List<Video> songs) {
    final Map<String, int> frequency = {};
    for (final song in songs) {
      final parts = song.author.split(
        RegExp(r'[,;&/]|(?:\b(?:feat\.?|ft\.?)\b)', caseSensitive: false),
      );
      for (final rawPart in parts) {
        final cleaned = CanonicalSongDedup.cleanArtist(rawPart);
        if (cleaned.isNotEmpty && cleaned.length >= 2) {
          frequency[cleaned] = (frequency[cleaned] ?? 0) + 1;
        }
      }
    }
    final sorted = frequency.keys.toList()
      ..sort((a, b) => frequency[b]!.compareTo(frequency[a]!));
    return sorted;
  }

  List<String> _getEffectivePlaylistArtists() {
    if (_seedPlaylistArtists.isNotEmpty) {
      return List<String>.from(_seedPlaylistArtists);
    }
    return _extractArtistsFromSongs(_playlist);
  }

  Future<void> _generate50SongProgressiveQueue(Video seed) async {
    if (_isGeneratingQueue) return;
    _isGeneratingQueue = true;

    try {
      debugPrint(
        '[Queue50] Generating 50-song progressive chained queue for: "${seed.title}"…',
      );
      final progressiveQueue = <Video>[seed];
      final seenKeys = <String>{CanonicalSongDedup.cleanTitle(seed.title)};

      final seedLanguage = CanonicalSongDedup.detectLanguage(seed.title);

      // Extract movie/soundtrack name if present e.g. (From "Nagabandham") or (From 'Movie')
      String? movieName;
      final movieMatch = RegExp(
        r'''from\s+["']([^"']+)["']''',
        caseSensitive: false,
      ).firstMatch(seed.title);
      if (movieMatch != null) {
        movieName = movieMatch.group(1)?.trim();
      }

      void addTracks(List<Video> tracks, {String? targetLang}) {
        for (final track in tracks) {
          if (!CanonicalSongDedup.isGenuineSong(track)) continue;
          if (targetLang != null &&
              !CanonicalSongDedup.isLanguageCompatible(
                targetLang,
                track.title,
              )) {
            continue;
          }

          bool isDup = false;
          for (final existing in progressiveQueue) {
            if (existing.id.value == track.id.value ||
                CanonicalSongDedup.areDuplicateSongs(
                  titleA: existing.title,
                  artistA: existing.author,
                  titleB: track.title,
                  artistB: track.author,
                )) {
              isDup = true;
              break;
            }
          }
          if (isDup) continue;

          final key = CanonicalSongDedup.cleanTitle(track.title);
          if (key.isNotEmpty && !seenKeys.contains(key)) {
            seenKeys.add(key);
            progressiveQueue.add(track);
            if (progressiveQueue.length >= 51) break;
          }
        }
      }

      // 1. Stage 1 (TOP PRIORITY): Pull matching tracks directly from user's 12k imported library
      final libraryMatches = _getLibraryRecommendationsForSeed(seed);
      addTracks(libraryMatches, targetLang: seedLanguage);

      // 2. Stage 2 (Primary Studio Recommendations): Query JioSaavn Recommendations & Hits
      if (progressiveQueue.length < 51) {
        final cleanArtist = CanonicalSongDedup.cleanArtist(seed.author);
        final leadArtist = PreferencesService.extractSingleLeadArtist(
          cleanArtist,
        );
        final jioRecFutures = <Future<List<Video>>>[];

        jioRecFutures.add(
          http
              .get(ApiConfig.jioRecommendationsUri(seed.title, limit: 30))
              .timeout(const Duration(seconds: 5))
              .then(
                (res) => res.statusCode == 200
                    ? _parseJioResults(res.body)
                    : <Video>[],
              )
              .catchError((_) => <Video>[]),
        );

        if (leadArtist.isNotEmpty) {
          final query = seedLanguage != null
              ? '$leadArtist $seedLanguage hits'
              : '$leadArtist hits';
          jioRecFutures.add(
            http
                .get(ApiConfig.jioSearchUri(query, limit: 25))
                .timeout(const Duration(seconds: 5))
                .then(
                  (res) => res.statusCode == 200
                      ? _parseJioResults(res.body)
                      : <Video>[],
                )
                .catchError((_) => <Video>[]),
          );
        }

        final jioRecLists = await Future.wait(jioRecFutures);
        for (final list in jioRecLists) {
          addTracks(list, targetLang: seedLanguage);
        }
      }

      // 3. Stage 3 (Secondary Discovery): Universal Reverse YTM Seed Bridge + TasteMatrixScorer
      if (progressiveQueue.length < 40) {
        final radioTracks = await fetchRadioTracksForSong(
          seed,
          limit: 35,
          targetLanguage: seedLanguage,
        );
        addTracks(radioTracks, targetLang: seedLanguage);
      }

      // 3. Stage 3 (Secondary): Movie Soundtrack Affinity if available
      if (progressiveQueue.length < 51 &&
          movieName != null &&
          movieName.isNotEmpty) {
        final movieResults = await http
            .get(ApiConfig.jioSearchUri('$movieName songs', limit: 15))
            .timeout(const Duration(seconds: 4))
            .then((res) => _parseJioResults(res.body))
            .catchError((_) => <Video>[]);
        addTracks(movieResults, targetLang: seedLanguage);
      }

      // 4. Stage 4: User Top Taste Matrix Artists if still under 30
      if (progressiveQueue.length < 30) {
        final favArtists = PreferencesService().getTopArtists();
        for (final fav in favArtists) {
          if (progressiveQueue.length >= 40) break;
          final cleanFav = CanonicalSongDedup.cleanArtist(fav);
          if (cleanFav.isEmpty) continue;
          final favQuery = seedLanguage != null
              ? '$cleanFav $seedLanguage hits'
              : '$cleanFav hits';
          final favResults = await http
              .get(ApiConfig.jioSearchUri(favQuery, limit: 10))
              .timeout(const Duration(seconds: 4))
              .then((res) => _parseJioResults(res.body))
              .catchError((_) => <Video>[]);
          addTracks(favResults, targetLang: seedLanguage);
        }
      }

      if (_currentSong?.id.value != seed.id.value) return;

      // Balance artist distribution while preserving rank
      if (progressiveQueue.length > 2) {
        final upcoming = progressiveQueue.sublist(1);
        final balancedUpcoming = CanonicalSongDedup.balanceArtistDistribution(
          upcoming,
        );
        _playlist = [seed, ...balancedUpcoming];
      } else {
        _playlist = progressiveQueue;
      }

      debugPrint(
        '[Queue50] Successfully generated progressive queue: ${_playlist.length} songs',
      );
      unawaited(enrichArtworkForSongs(_playlist));
      notifyListeners();
    } catch (e) {
      debugPrint('[Queue50] Queue generation error: $e');
    } finally {
      _isGeneratingQueue = false;
    }
  }

  Future<void> _fetchNextRecommendations(Video song) async {
    if (_isFetchingNextQueue) return;
    _isFetchingNextQueue = true;
    try {
      debugPrint(
        '[Queue] Fetching chained recommendations across playlist artists…',
      );

      // 1. Detect dominant language across the active playlist (fallback to seed song)
      final langCounts = <String, int>{};
      for (final s in _playlist) {
        final l = CanonicalSongDedup.detectLanguage(s.title);
        if (l != null) langCounts[l] = (langCounts[l] ?? 0) + 1;
      }
      final dominantLang = langCounts.isNotEmpty
          ? langCounts.entries.reduce((a, b) => a.value >= b.value ? a : b).key
          : CanonicalSongDedup.detectLanguage(song.title);

      // 2. Extract distinct artists from the active playlist
      final allPlaylistArtists = _getEffectivePlaylistArtists();
      List<Video> candidates = [];

      if (dominantLang == 'english') {
        // English track playback: query JioSaavn hits & recommendations AND YouTube Music radio
        debugPrint(
          '[Queue] Fetching English recommendations for: "${song.title}"',
        );
        final cleanArtist = CanonicalSongDedup.cleanArtist(song.author);
        final jioRecFutures = <Future<List<Video>>>[];
        if (cleanArtist.isNotEmpty) {
          jioRecFutures.add(
            http
                .get(ApiConfig.jioSearchUri('$cleanArtist hits', limit: 15))
                .timeout(const Duration(seconds: 4))
                .then((res) => _parseJioResults(res.body))
                .catchError((_) => <Video>[]),
          );
        }
        jioRecFutures.add(
          http
              .get(ApiConfig.jioRecommendationsUri(song.title, limit: 15))
              .timeout(const Duration(seconds: 4))
              .then((res) => _parseJioResults(res.body))
              .catchError((_) => <Video>[]),
        );

        final jioLists = await Future.wait(jioRecFutures);
        for (final list in jioLists) {
          candidates.addAll(list);
        }

        if (song.id.value.length == 11) {
          final radioTracks = await YouTubeMusicClient()
              .fetchRadioTracks(song.id.value, limit: 20)
              .catchError((_) => <Video>[]);
          candidates.addAll(radioTracks);
        }
        if (candidates.length < 15 && cleanArtist.isNotEmpty) {
          final artistTracks = await YouTubeMusicClient()
              .searchSongs('$cleanArtist hits', limit: 15)
              .catchError((_) => <Video>[]);
          candidates.addAll(artistTracks);
        }
        if (candidates.length < 10) {
          final popHits = await YouTubeMusicClient()
              .searchSongs('Top Pop Hits 2026', limit: 15)
              .catchError((_) => <Video>[]);
          candidates.addAll(popHits);
        }
      } else if (allPlaylistArtists.length > 1) {
        // Multi-artist playlist: Fetch popular hit songs from all/multiple artists in the playlist
        // Select up to 6 distinct artists per batch, rotating across batches so all artists get recommended
        final int batchSize = min(6, allPlaylistArtists.length);
        final selectedArtists = <String>[];
        for (int i = 0; i < batchSize; i++) {
          final idx =
              (_playlistArtistRecommendationOffset + i) %
              allPlaylistArtists.length;
          selectedArtists.add(allPlaylistArtists[idx]);
        }
        _playlistArtistRecommendationOffset =
            (_playlistArtistRecommendationOffset + batchSize) %
            allPlaylistArtists.length;

        debugPrint(
          '[Queue] Blending popular recommendations from artists: ${selectedArtists.join(', ')} (Language: $dominantLang)',
        );

        // Step A: Pull matching tracks directly from user's 12k imported library for all selected artists
        final libraryMatches = _getLibraryRecommendationsForArtists(
          selectedArtists,
          targetLang: dominantLang,
        );
        candidates.addAll(libraryMatches);

        // Step B: Query JioSaavn concurrently for popular studio hits for each selected artist
        final artistQueries = selectedArtists.map((artist) {
          final query = dominantLang != null
              ? '$artist $dominantLang hits'
              : '$artist hits';
          return http
              .get(ApiConfig.jioSearchUri(query, limit: 8))
              .timeout(const Duration(seconds: 4))
              .then((res) => _parseJioResults(res.body))
              .catchError((_) => <Video>[]);
        }).toList();

        final artistTrackLists = await Future.wait(artistQueries);

        // Round-robin interleave results so the queue contains an even mix of all playlist artists
        int maxLen = 0;
        for (final list in artistTrackLists) {
          if (list.length > maxLen) maxLen = list.length;
        }
        for (int i = 0; i < maxLen; i++) {
          for (final list in artistTrackLists) {
            if (i < list.length) {
              candidates.add(list[i]);
            }
          }
        }
      } else {
        // Single-artist or single-track playback: Universal Reverse YTM Seed Bridge + TasteMatrixScorer
        final radioMatches = await fetchRadioTracksForSong(
          song,
          limit: 20,
          targetLanguage: dominantLang,
        );
        candidates.addAll(radioMatches);

        // 2. Secondary: Library tracks from matching artist / taste matrix
        if (candidates.length < 10) {
          final libraryMatches = _getLibraryRecommendationsForSeed(song);
          candidates.addAll(libraryMatches);
        }
      }

      // Filter for genuine songs and language compatibility
      final valid = candidates
          .where(
            (c) =>
                CanonicalSongDedup.isGenuineSong(c) &&
                (dominantLang == null ||
                    CanonicalSongDedup.isLanguageCompatible(
                      dominantLang,
                      c.title,
                    )),
          )
          .toList();

      final fresh = CanonicalSongDedup.deduplicateList(_playlist, valid);
      if (fresh.isNotEmpty) {
        final balanced = CanonicalSongDedup.balanceArtistDistribution(fresh);
        final tracksToAdd = balanced.take(15).toList();
        _playlist.addAll(tracksToAdd);
        debugPrint(
          '[Queue] Appended ${tracksToAdd.length} multi-artist recommended tracks. Total in queue: ${_playlist.length}',
        );
        unawaited(enrichArtworkForSongs(tracksToAdd));
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Error fetching recommendations: $e');
    } finally {
      _isFetchingNextQueue = false;
    }
  }

  List<Map<String, String>> _downloadedSongs = [];
  bool _isDownloading = false;

  List<Map<String, String>> get downloadedSongs => _downloadedSongs;
  bool get isDownloading => _isDownloading;

  Future<void> loadDownloadedSongs() async {
    if (kIsWeb) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/downloads.json');
      if (await file.exists()) {
        final content = await file.readAsString();
        final List<dynamic> jsonList = json.decode(content);
        _downloadedSongs = jsonList
            .map((e) => Map<String, String>.from(e))
            .toList();
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Error loading downloaded songs: $e');
    }
  }

  Future<bool> downloadSong(Video song) async {
    if (kIsWeb) return false;
    _isDownloading = true;
    notifyListeners();

    try {
      final client = http.Client();
      http.StreamedResponse? response;

      // 0. Super-fast direct CDN download if JioSaavn 320k stream URL exists
      final directCdnUrl = _webStreamUrls[song.id.value];
      if (directCdnUrl != null && directCdnUrl.isNotEmpty) {
        try {
          final request = http.Request('GET', Uri.parse(directCdnUrl));
          final res = await client
              .send(request)
              .timeout(const Duration(seconds: 30));
          if (res.statusCode == 200) {
            response = res;
          }
        } catch (e) {
          debugPrint('[Download] Direct JioSaavn CDN error: $e');
        }
      }

      // 1. Primary: Direct on-device stream URL candidates
      if (response == null || response.statusCode != 200) {
        try {
          final candidates = await _resolveStreamCandidates(song.id.value);
          for (final candidate in candidates) {
            try {
              final request = http.Request('GET', Uri.parse(candidate.url));
              final res = await client
                  .send(request)
                  .timeout(const Duration(seconds: 25));
              if (res.statusCode == 200) {
                response = res;
                break;
              }
            } catch (_) {}
          }
        } catch (e) {
          debugPrint('[Download] Direct URL error: $e');
        }
      }

      // 2. Fallback 1: Backend /stream_url
      if (response == null || response.statusCode != 200) {
        try {
          final streamUrl = await _fetchStreamUrl(song.id.value);
          if (streamUrl != null) {
            final request = http.Request('GET', Uri.parse(streamUrl));
            request.headers.addAll(_ytHeaders);
            response = await client
                .send(request)
                .timeout(const Duration(seconds: 25));
          }
        } catch (e) {
          debugPrint('[Download] Backend streamUrl error: $e');
        }
      }

      // 3. Fallback 2: Cloudflare Edge Worker stream
      if (response == null || response.statusCode != 200) {
        try {
          final cfStreamUri = ApiConfig.cloudflareStreamUri(song.id.value);
          final request = http.Request('GET', cfStreamUri);
          response = await client
              .send(request)
              .timeout(const Duration(seconds: 25));
        } catch (e) {
          debugPrint('[Download] Cloudflare edge stream error: $e');
        }
      }

      // 4. Fallback 3: Backend proxy stream (if custom backend configured)
      if ((response == null || response.statusCode != 200) &&
          PreferencesService().customServerUrl.isNotEmpty) {
        try {
          final proxyUri = ApiConfig.streamProxyUri(song.id.value);
          final request = http.Request('GET', proxyUri);
          response = await client
              .send(request)
              .timeout(const Duration(seconds: 25));
        } catch (e) {
          debugPrint('[Download] Proxy error: $e');
        }
      }

      if (response != null && response.statusCode == 200) {
        final dir = await getApplicationDocumentsDirectory();
        final filePath = '${dir.path}/${song.id.value}.m4a';
        final file = File(filePath);
        final sink = file.openWrite();
        await response.stream.pipe(sink);
        await sink.close();

        final songInfo = {
          'id': song.id.value,
          'title': song.title,
          'author': song.author,
          'thumbnail': song.thumbnails.highResUrl,
          'localPath': filePath,
        };

        _downloadedSongs.removeWhere((item) => item['id'] == song.id.value);
        _downloadedSongs.add(songInfo);

        final jsonFile = File('${dir.path}/downloads.json');
        await jsonFile.writeAsString(json.encode(_downloadedSongs));

        debugPrint('Successfully downloaded song to $filePath');
        notifyListeners();
        return true;
      }
    } catch (e) {
      debugPrint('Error downloading song: $e');
    } finally {
      _isDownloading = false;
      notifyListeners();
    }
    return false;
  }

  Future<void> deleteDownloadedSong(String videoId) async {
    if (kIsWeb) return;
    try {
      final item = _downloadedSongs.firstWhere(
        (s) => s['id'] == videoId,
        orElse: () => {},
      );
      if (item.isNotEmpty && item['localPath'] != null) {
        final file = File(item['localPath']!);
        if (await file.exists()) {
          await file.delete();
        }
      }
      _downloadedSongs.removeWhere((s) => s['id'] == videoId);
      final dir = await getApplicationDocumentsDirectory();
      final jsonFile = File('${dir.path}/downloads.json');
      await jsonFile.writeAsString(json.encode(_downloadedSongs));
      notifyListeners();
    } catch (e) {
      debugPrint('Error deleting downloaded song: $e');
    }
  }

  Future<void> playDownloadedSong(Map<String, String> songData) async {
    _isLoading = true;

    for (final item in _downloadedSongs) {
      final id = item['id'];
      final thumb = item['thumbnail'];
      if (id != null && id.isNotEmpty && thumb != null && thumb.isNotEmpty) {
        _artworkMap[id] = thumb;
      }
    }

    // Load ALL downloaded songs into queue so Next and Prev work seamlessly!
    _playlist = _downloadedSongs
        .map(
          (item) => Video(
            VideoId(item['id']!),
            item['title'] ?? 'Unknown Title',
            item['author'] ?? 'Unknown Artist',
            ChannelId('UC0WP5P-fwGlLyO4yOE76T8g'),
            DateTime.now(),
            '',
            null,
            '',
            null,
            ThumbnailSet(item['id']!),
            null,
            Engagement(0, null, null),
            false,
          ),
        )
        .toList();

    _currentIndex = _downloadedSongs.indexWhere(
      (item) => item['id'] == songData['id'],
    );
    if (_currentIndex == -1) _currentIndex = 0;
    if (_playlist.isNotEmpty) {
      await playSong(_playlist[_currentIndex], updateQueue: false);
    }
  }

  Future<void> playDeviceSong(
    Map<String, String> songData, {
    List<Map<String, String>>? queue,
    int? startIndex,
  }) async {
    _isLoading = true;
    final songList = queue ?? _deviceAudioService.deviceSongs;
    if (songList.isEmpty) return;

    for (final item in songList) {
      final id = item['id'];
      final thumb = item['thumbnail'];
      if (id != null && id.isNotEmpty && thumb != null && thumb.isNotEmpty) {
        _artworkMap[id] = thumb;
      }
    }

    _playlist = songList.map((item) {
      final rawId =
          item['id'] ??
          DeviceAudioService.generateLocalId(item['localPath'] ?? '');
      VideoId safeId;
      try {
        safeId = VideoId(rawId);
      } catch (_) {
        final padded = '${rawId}___________'.substring(0, 11);
        try {
          safeId = VideoId(padded);
        } catch (_) {
          safeId = VideoId('00000000000');
        }
      }
      return Video(
        safeId,
        item['title'] ?? 'Unknown Title',
        item['author'] ?? 'Device Audio',
        ChannelId('UC0WP5P-fwGlLyO4yOE76T8g'),
        DateTime.now(),
        '',
        null,
        '',
        null,
        ThumbnailSet(safeId.value),
        null,
        Engagement(0, null, null),
        false,
      );
    }).toList();

    _currentIndex =
        startIndex ??
        songList.indexWhere((item) => item['id'] == songData['id']);

    if (_currentIndex == -1) _currentIndex = 0;
    if (_playlist.isNotEmpty) {
      await playSong(_playlist[_currentIndex], updateQueue: false);
    }
  }

  Future<void> playHistorySong(Map<String, String> songData) async {
    final history = PreferencesService().listeningHistory;
    for (final item in history) {
      final id = item['id'];
      final thumb = item['thumbnail'];
      if (id != null && id.isNotEmpty && thumb != null && thumb.isNotEmpty) {
        _artworkMap[id] = thumb;
      }
    }

    _playlist = history
        .map(
          (item) => Video(
            VideoId(item['id'] ?? ''),
            item['title'] ?? 'Unknown Title',
            item['author'] ?? 'Unknown Artist',
            ChannelId('UC0WP5P-fwGlLyO4yOE76T8g'),
            DateTime.now(),
            '',
            null,
            '',
            null,
            ThumbnailSet(item['id'] ?? ''),
            null,
            Engagement(0, null, null),
            false,
          ),
        )
        .toList();

    _currentIndex = history.indexWhere((item) => item['id'] == songData['id']);
    if (_currentIndex == -1) _currentIndex = 0;
    if (_playlist.isNotEmpty) {
      await playSong(_playlist[_currentIndex], updateQueue: false);
    }
  }

  Future<void> playMostPlayedSong(
    Map<String, dynamic> songData, {
    List<Map<String, dynamic>>? allSongs,
    int? startIndex,
    bool? enableShuffle,
  }) async {
    final list = allSongs ?? PreferencesService().mostPlayedSongs;
    if (list.isEmpty) return;

    for (final item in list) {
      final id = (item['id'] as String?) ?? '';
      final thumb = (item['thumbnail'] as String?) ?? '';
      final stream = (item['streamUrl'] as String?) ?? '';
      if (id.isNotEmpty) {
        if (thumb.isNotEmpty) _artworkMap[id] = thumb;
        if (stream.isNotEmpty) _webStreamUrls[id] = stream;
      }
    }

    VideoId safeVideoId(String rawId) {
      try {
        return VideoId(rawId);
      } catch (_) {
        final padded = '${rawId}___________'.substring(0, 11);
        try {
          return VideoId(padded);
        } catch (_) {
          return VideoId('00000000000');
        }
      }
    }

    _playlist = list
        .map(
          (item) => Video(
            safeVideoId((item['id'] as String?) ?? ''),
            (item['title'] as String?) ?? 'Unknown Title',
            (item['author'] as String?) ?? 'Unknown Artist',
            ChannelId('UC0WP5P-fwGlLyO4yOE76T8g'),
            DateTime.now(),
            '',
            null,
            '',
            null,
            ThumbnailSet((item['id'] as String?) ?? ''),
            null,
            Engagement(0, null, null),
            false,
          ),
        )
        .toList();

    if (startIndex != null &&
        startIndex >= 0 &&
        startIndex < _playlist.length) {
      _currentIndex = startIndex;
    } else {
      _currentIndex = list.indexWhere((item) => item['id'] == songData['id']);
      if (_currentIndex == -1) _currentIndex = 0;
    }

    if (_playlist.isNotEmpty) {
      if (enableShuffle != null) {
        _isShuffle = enableShuffle;
        if (!kIsWeb) {
          _activePlayer.setShuffleModeEnabled(_isShuffle);
        }
      }

      _seedPlaylistArtists = _extractArtistsFromSongs(_playlist);
      _playlistArtistRecommendationOffset = 0;
      _prewarmUpcomingTracks(_currentIndex, count: 4);
      await playSong(_playlist[_currentIndex], updateQueue: false);
    }
  }

  void toggleLikeMap(Map<String, dynamic> song) {
    final id = (song['id'] as String?) ?? '';
    if (id.isEmpty) return;
    final title = (song['title'] as String?) ?? 'Unknown';
    final author = (song['author'] as String?) ?? 'Unknown';
    VideoId safeVideoId(String rawId) {
      try {
        return VideoId(rawId);
      } catch (_) {
        final padded = '${rawId}___________'.substring(0, 11);
        try {
          return VideoId(padded);
        } catch (_) {
          return VideoId('00000000000');
        }
      }
    }

    toggleLike(
      Video(
        safeVideoId(id),
        title,
        author,
        ChannelId('UC0WP5P-fwGlLyO4yOE76T8g'),
        DateTime.now(),
        '',
        null,
        '',
        null,
        ThumbnailSet(id),
        null,
        Engagement(0, null, null),
        false,
      ),
    );
  }

  Future<int> getTotalDownloadedBytes() async {
    int total = 0;
    for (final song in _downloadedSongs) {
      if (song['localPath'] != null) {
        try {
          final file = File(song['localPath']!);
          if (await file.exists()) {
            total += await file.length();
          }
        } catch (_) {}
      }
    }
    return total;
  }

  Future<int> getDownloadedSongSize(String videoId) async {
    final s = _downloadedSongs.firstWhere(
      (item) => item['id'] == videoId,
      orElse: () => {},
    );
    if (s.isNotEmpty && s['localPath'] != null) {
      try {
        final f = File(s['localPath']!);
        if (await f.exists()) {
          return await f.length();
        }
      } catch (_) {}
    }
    return 0;
  }

  Future<void> seek(Duration position) async {
    if (_isCrossfading) {
      _cancelActiveFade();
    }
    _savedPosition = position;
    if (kIsWeb) {
      WebPlayerBridge.seek(position);
      notifyListeners();
      PreferencesService().updateLastPlaybackPosition(position.inMilliseconds);
      return;
    }
    await _audioPlayer.seek(position);
    PreferencesService().updateLastPlaybackPosition(position.inMilliseconds);
  }

  void togglePlayPause() {
    if (kIsWeb) {
      if (WebPlayerBridge.isPlaying) {
        WebPlayerBridge.pause();
        persistPlaybackSession(force: true);
      } else {
        WebPlayerBridge.resume();
      }
      notifyListeners();
      return;
    }
    if (_audioPlayer.playing) {
      _audioPlayer.pause();
      if (_isCrossfading) {
        _standbyPlayer.pause();
      }
      persistPlaybackSession(force: true);
    } else {
      // If the player has no loaded audio source or is idle/completed, re-trigger playSong to load and start track
      final pState = _audioPlayer.processingState;
      if (_currentSong != null &&
          (pState == ProcessingState.idle ||
              pState == ProcessingState.completed ||
              _audioPlayer.audioSource == null)) {
        playSong(_currentSong!, updateQueue: false);
        return;
      }
      if (_currentSong == null && _playlist.isNotEmpty) {
        final targetIndex =
            (_currentIndex >= 0 && _currentIndex < _playlist.length)
            ? _currentIndex
            : 0;
        _currentIndex = targetIndex;
        playSong(_playlist[targetIndex], updateQueue: false);
        return;
      }

      if (!_isCrossfading) {
        unawaited(_setVolume(1.0));
      }
      _audioPlayer.play();
      if (_isCrossfading) {
        _standbyPlayer.play();
      }
    }
    notifyListeners();
  }

  /// Reloads the currently playing track with the user's updated audio quality or format,
  /// smoothly resuming from the exact playback position.
  Future<void> reloadCurrentSongWithNewEngineSettings() async {
    if (_currentSong == null) return;
    final song = _currentSong!;
    final pos = position;
    final wasPlaying = isPlaying;

    // Clear cached web stream for this song to ensure fresh quality/codec is resolved
    _webStreamUrls.remove(song.id.value);

    await playSong(song, updateQueue: false);
    if (pos > Duration.zero) {
      await seek(pos);
    }
    if (!wasPlaying) {
      if (kIsWeb) {
        WebPlayerBridge.pause();
      } else {
        _audioPlayer.pause();
      }
    }
  }

  Map<String, dynamic> _videoToMap(Video video) {
    return {
      'id': video.id.value,
      'title': video.title,
      'author': video.author,
      'durationMs': video.duration?.inMilliseconds ?? 0,
      'thumbnail': MusicService.getHdThumbnail(video.id.value),
      'streamUrl': _webStreamUrls[video.id.value] ?? '',
    };
  }

  Video _mapToVideo(Map<String, dynamic> map) {
    final id = (map['id'] as String?) ?? '';
    final durationMs = (map['durationMs'] as int?) ?? 0;
    final cleanId = id.isNotEmpty ? id : '00000000000';
    final safeId = cleanId.length >= 11
        ? cleanId.substring(0, 11)
        : cleanId.padRight(11, '0');
    return Video(
      VideoId(safeId),
      (map['title'] as String?) ?? 'Unknown Title',
      (map['author'] as String?) ?? 'Unknown Artist',
      ChannelId('UC0WP5P-fwGlLyO4yOE76T8g'),
      DateTime.now(),
      '',
      null,
      '',
      durationMs > 0 ? Duration(milliseconds: durationMs) : null,
      ThumbnailSet(safeId),
      null,
      Engagement(0, null, null),
      false,
    );
  }

  Future<void> persistPlaybackSession({
    Duration? pos,
    bool force = false,
  }) async {
    final song = _currentSong;
    if (song == null) return;

    final now = DateTime.now();
    if (!force && now.difference(_lastSessionSaveTime).inMilliseconds < 1000) {
      return;
    }
    _lastSessionSaveTime = now;

    final curPos = pos ?? position;
    final curDur = duration ?? (song.duration ?? Duration.zero);

    // If near the end of track (within 2 seconds), reset position to 0 on resume
    final int posMs =
        (curDur.inMilliseconds > 0 &&
            curPos.inMilliseconds >= curDur.inMilliseconds - 2000)
        ? 0
        : curPos.inMilliseconds;
    final int durMs = curDur.inMilliseconds;

    final songMap = _videoToMap(song);
    final playlistMaps = _playlist.take(50).map(_videoToMap).toList();

    await PreferencesService().saveLastPlaybackSession(
      song: songMap,
      positionMs: posMs,
      durationMs: durMs,
      playlist: playlistMaps,
      playlistIndex: _currentIndex,
      dominantColor: _dominantColor,
      vibrantColor: _vibrantColor,
      darkVibrantColor: _darkVibrantColor,
    );
  }

  void restoreLastPlaybackSession() {
    try {
      final prefs = PreferencesService();
      if (!prefs.isInitialized) return;
      final songMap = prefs.lastPlayedSong;
      if (songMap == null || songMap.isEmpty) return;

      final restoredSong = _mapToVideo(songMap);
      if (restoredSong.id.value.isEmpty ||
          restoredSong.id.value == '00000000000') {
        return;
      }

      _currentSong = restoredSong;
      final posMs = prefs.lastPlayedPositionMs;
      final durMs = prefs.lastPlayedDurationMs;

      if (posMs > 0) {
        _savedPosition = Duration(milliseconds: posMs);
      } else {
        _savedPosition = Duration.zero;
      }

      if (durMs > 0) {
        _savedDuration = Duration(milliseconds: durMs);
      } else if (restoredSong.duration != null) {
        _savedDuration = restoredSong.duration;
      }

      final playlistMaps = prefs.lastPlayedPlaylist;
      if (playlistMaps.isNotEmpty) {
        _playlist = playlistMaps.map(_mapToVideo).toList();
        _currentIndex = prefs.lastPlayedPlaylistIndex.clamp(
          0,
          _playlist.length - 1,
        );
      } else {
        _playlist = [restoredSong];
        _currentIndex = 0;
      }

      final streamUrl = (songMap['streamUrl'] as String?) ?? '';
      if (streamUrl.isNotEmpty) {
        _webStreamUrls[restoredSong.id.value] = streamUrl;
      }
      final thumbnail = (songMap['thumbnail'] as String?) ?? '';
      if (thumbnail.isNotEmpty) {
        _artworkMap[restoredSong.id.value] = thumbnail;
      }

      final domColorInt = prefs.lastPlayedDominantColor;
      if (domColorInt != null) {
        _dominantColor = Color(domColorInt);
      }
      final vibColorInt = prefs.lastPlayedVibrantColor;
      if (vibColorInt != null) {
        _vibrantColor = Color(vibColorInt);
      }
      final darkVibColorInt = prefs.lastPlayedDarkVibrantColor;
      if (darkVibColorInt != null) {
        _darkVibrantColor = Color(darkVibColorInt);
      }

      if (_savedPosition != null) {
        _positionBroadcaster.add(_savedPosition!);
      }
      if (_savedDuration != null) {
        _durationBroadcaster.add(_savedDuration);
      }

      notifyListeners();
    } catch (e) {
      debugPrint('[MusicService] Error restoring last playback session: $e');
    }
  }

  Future<void> resumeLastPlaybackSession() async {
    final prefs = PreferencesService();
    final songMap = prefs.lastPlayedSong;
    if (songMap == null) return;
    restoreLastPlaybackSession();
    if (_currentSong != null) {
      final posMs = prefs.lastPlayedPositionMs;
      await playSong(_currentSong!, updateQueue: false);
      if (posMs > 0) {
        await seek(Duration(milliseconds: posMs));
      }
    }
  }

  @visibleForTesting
  void setPlaylistForTesting(List<Video> list, {int initialIndex = 0}) {
    _playlist = List.from(list);
    _currentIndex = initialIndex;
    if (_playlist.isNotEmpty &&
        initialIndex >= 0 &&
        initialIndex < _playlist.length) {
      _currentSong = _playlist[initialIndex];
    } else {
      _currentSong = null;
    }
  }

  @visibleForTesting
  void setIsCrossfadingForTesting(bool value) {
    _isCrossfading = value;
  }

  @visibleForTesting
  void setLoopModeForTesting(LoopMode mode) {
    _loopMode = mode;
  }

  @visibleForTesting
  int get consecutivePlaybackFailures => _consecutivePlaybackFailures;

  @visibleForTesting
  void setConsecutivePlaybackFailuresForTesting(int value) {
    _consecutivePlaybackFailures = value;
  }

  @visibleForTesting
  int get songRetryCount => _songRetryCount;

  @visibleForTesting
  void setSongRetryCountForTesting(int value) {
    _songRetryCount = value;
  }

  @visibleForTesting
  Future<void> handlePlaybackStreamErrorForTesting(
    AudioPlayer player,
    Object error,
  ) => _handlePlaybackStreamError(player, error, null);

  @visibleForTesting
  void resetForTesting() {
    _currentSong = null;
    _playlist.clear();
    _currentIndex = 0;
    _savedPosition = null;
    _savedDuration = null;
    _activePlaySessionToken = 0;
    _standbyBufferedTrackId = null;
    _isPrebufferingStandby = false;
    _lastSessionSaveTime = DateTime.fromMillisecondsSinceEpoch(0);
    _consecutivePlaybackFailures = 0;
    _lastFailedSongId = null;
    _songRetryCount = 0;
    _isNavigatingNext = false;
    _isNavigatingPrev = false;
    _lastNextClickTime = DateTime.fromMillisecondsSinceEpoch(0);
    _lastPrevClickTime = DateTime.fromMillisecondsSinceEpoch(0);
  }

  void _initWidgetBridge() {
    WidgetUpdateService().initWidgetActionHandler(
      onToggleShuffle: () => toggleShuffle(),
      onToggleRepeat: () => toggleRepeat(),
      onPlayPlaylist: (index, id, query) =>
          playPlaylistFromWidget(index, id, query),
    );
  }

  @visibleForTesting
  int get activePlaySessionToken => _activePlaySessionToken;

  @visibleForTesting
  String? get standbyBufferedTrackId => _standbyBufferedTrackId;

  @visibleForTesting
  void setStandbyBufferedTrackIdForTesting(String? id) {
    _standbyBufferedTrackId = id;
  }

  List<Map<String, String>> _getWidgetTopPlaylists() {
    final prefs = PreferencesService();
    final topArtist = prefs.mostPlayedArtist;
    final primaryArtist = topArtist.isNotEmpty ? topArtist : 'Trending Hits';

    final List<Map<String, String>> result = [
      {'id': 'daily_mix', 'title': 'Daily\nMix', 'query': primaryArtist},
      {'id': 'favorites', 'title': 'Favorites', 'query': 'favorites'},
      {'id': 'most_played', 'title': 'Most\nPlayed', 'query': 'most_played'},
      {'id': 'history', 'title': 'History\nReplay', 'query': 'history'},
    ];

    if (_customPlaylists.isNotEmpty) {
      final cp = _customPlaylists.first;
      final cpName = (cp['name'] as String?) ?? 'My Mix';
      final formattedName = cpName.length > 8 && !cpName.contains('\n')
          ? cpName.replaceAll(' ', '\n')
          : cpName;
      result.add({
        'id': 'custom_0',
        'title': formattedName,
        'query': 'custom_0',
      });
    } else {
      result.add({
        'id': 'chill_vibes',
        'title': 'Chill\nVibes',
        'query': 'Acoustic Pop Melodies',
      });
    }

    return result;
  }

  Future<void> playPlaylistFromWidget(
    int index,
    String id,
    String query,
  ) async {
    try {
      switch (id) {
        case 'favorites':
          if (_likedSongs.isNotEmpty) {
            await playLikedSong(_likedSongs.first);
          }
          break;
        case 'most_played':
          final mostPlayed = PreferencesService().mostPlayedSongs;
          if (mostPlayed.isNotEmpty) {
            await playMostPlayedSong(mostPlayed.first);
          }
          break;
        case 'history':
          final history = PreferencesService().listeningHistory;
          if (history.isNotEmpty) {
            await playHistorySong(history.first);
          }
          break;
        case 'custom_0':
          if (_customPlaylists.isNotEmpty) {
            final cp = _customPlaylists.first;
            final playlistId = (cp['id'] as String?) ?? '';
            if (playlistId.isNotEmpty) {
              await playCustomPlaylist(playlistId, 0);
            }
          }
          break;
        default:
          final tracks = await searchSongs(
            query.isNotEmpty ? query : 'Top Hits',
          );
          if (tracks.isNotEmpty) {
            await playPlaylist(tracks, 0);
          }
          break;
      }
    } catch (e) {
      debugPrint('[WidgetUpdateService] Error launching playlist: $e');
    }
  }

  void _syncWidgetPlayback() {
    if (kIsWeb) return;
    final song = _currentSong;

    int? dominantColor;
    if (song != null) {
      try {
        final palette = AlbumColorDeriver.getPalette(
          song,
          fallbackDominant: _dominantColor,
        );
        dominantColor = palette.dominant.toARGB32();
      } catch (_) {}
    }

    WidgetUpdateService().updateWidget(
      title: song != null
          ? CanonicalSongDedup.cleanTitle(song.title)
          : 'DilSe Music',
      artist: song != null
          ? CanonicalSongDedup.cleanArtist(song.author)
          : 'Tap to play',
      isPlaying: isPlaying,
      artworkPath: song != null ? _artworkMap[song.id.value] : null,
      trackId: song?.id.value,

      dominantColor: dominantColor,

      position: position,
      duration: duration,
      isShuffle: _isShuffle,
      isRepeat: _loopMode != LoopMode.off,
      topPlaylists: _getWidgetTopPlaylists(),
    );
  }
  // ────────────────────────────────────────────────────────────────────────────
  // Movie / Soundtrack Album Feature
  // ────────────────────────────────────────────────────────────────────────────

  /// Searches JioSaavn album catalog via the Cloudflare Edge Worker.
  ///
  /// Returns a list of [JioAlbum] objects. Each album has id, title, artist,
  /// artwork, year, songCount — but no songs list until [fetchAlbumTracks].
  Future<List<JioAlbum>> searchAlbums(String query, {int limit = 12}) async {
    if (query.trim().isEmpty) return [];
    try {
      final uri = ApiConfig.jioAlbumSearchUri(query.trim(), limit: limit);
      final resp = await http.get(uri).timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return [];
      final body = json.decode(resp.body);
      if (body is! List) return [];
      return body
          .whereType<Map<String, dynamic>>()
          .map(JioAlbum.fromJson)
          .where((a) => a.id.isNotEmpty && a.title.isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('[Album Search] Error: $e');
      return [];
    }
  }

  /// Fetches all songs for a JioSaavn album and returns a fully-populated
  /// [JioAlbum]. Each song's artwork and stream URL are pre-registered in
  /// [_artworkMap] and [_webStreamUrls] so playback works immediately.
  Future<JioAlbum?> fetchAlbumTracks(String albumId) async {
    if (albumId.isEmpty) return null;
    try {
      final uri = ApiConfig.jioAlbumDetailUri(albumId);
      final resp = await http.get(uri).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return null;
      final body = json.decode(resp.body);
      if (body is! Map<String, dynamic>) return null;

      final album = JioAlbum.fromJson(body);

      for (final s in album.songs) {
        final id = s['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        final thumb = s['thumbnail'] as String? ?? '';
        final stream = s['streamUrl'] as String? ?? '';
        if (thumb.isNotEmpty) _artworkMap[id] = thumb;
        if (stream.isNotEmpty) {
          _webStreamUrls[id] = stream;
          cacheWebStreamUrl(id, stream);
        }
      }

      debugPrint(
        '[Album Tracks] Loaded \${album.songs.length} songs for "\${album.title}"',
      );
      return album;
    } catch (e) {
      debugPrint('[Album Tracks] Error: $e');
      return null;
    }
  }

  /// Converts a [JioAlbum]'s songs into a queue-ready [List<Video>].
  /// Also pre-registers artwork and stream URLs.
  List<Video> albumSongsToVideos(JioAlbum album) {
    final result = <Video>[];
    for (final s in album.songs) {
      final rawId = s['id']?.toString() ?? '';
      if (rawId.isEmpty) continue;
      final vidId = rawId.length >= 11
          ? rawId.substring(0, 11)
          : rawId.padRight(11, '0');

      final rawTitle = s['title'] as String? ?? 'Unknown Title';
      final rawAuthor = s['author'] as String? ?? 'Various Artists';
      final thumb = s['thumbnail'] as String? ?? album.artwork;
      final stream = s['streamUrl'] as String? ?? '';
      final durationSec = s['duration'] as int? ?? 0;

      final title = CanonicalSongDedup.sanitizeDisplayTitle(
        rawTitle,
        artist: rawAuthor,
      );
      final cleanedAuthor = CanonicalSongDedup.cleanArtist(rawAuthor);
      final author = cleanedAuthor.isNotEmpty ? cleanedAuthor : rawAuthor;

      if (thumb.isNotEmpty) {
        _artworkMap[rawId] = thumb;
        _artworkMap[vidId] = thumb;
      }
      if (stream.isNotEmpty) {
        _webStreamUrls[rawId] = stream;
        _webStreamUrls[vidId] = stream;
        cacheWebStreamUrl(rawId, stream);
      }
      registerSongAlbum(
        rawId,
        albumTitle: album.title,
        albumId: album.id,
        album: album,
      );
      registerSongAlbum(
        vidId,
        albumTitle: album.title,
        albumId: album.id,
        album: album,
      );

      result.add(
        Video(
          VideoId(vidId),
          title,
          author,
          ChannelId('UC0WP5P-fwGlLyO4yOE76T8g'),
          DateTime.now(),
          '',
          null,
          '',
          durationSec > 0 ? Duration(seconds: durationSec) : null,
          ThumbnailSet(vidId),
          null,
          Engagement(0, null, null),
          false,
        ),
      );
    }
    return result;
  }

  /// Extracts movie or soundtrack album title from song title patterns
  /// such as (From "Movie"), [From "Movie"], "Movie - Song Video", etc.
  static String? extractMovieOrAlbumTitle(String rawTitle) {
    if (rawTitle.trim().isEmpty) return null;

    // 1. (From "Movie") or [From "Movie"] or (From 'Movie')
    final fromQuotes = RegExp(
      r'''(?:[\(\[]\s*)from\s+["']([^"']+)["'](?:\s*[\)\]])''',
      caseSensitive: false,
    );
    final m1 = fromQuotes.firstMatch(rawTitle);
    if (m1 != null) {
      final val = m1.group(1)?.trim();
      if (val != null && val.length >= 2) return val;
    }

    // 2. (From Movie Name) without quotes
    final fromNoQuotes = RegExp(
      r'''(?:[\(\[]\s*)from\s+([A-Za-z0-9\s]+?)(?:\s*[\)\]])''',
      caseSensitive: false,
    );
    final m2 = fromNoQuotes.firstMatch(rawTitle);
    if (m2 != null) {
      final val = m2.group(1)?.trim();
      if (val != null &&
          val.length >= 2 &&
          !RegExp(
            r'^(the|a|an|remix|lofi|official|full|hd)$',
            caseSensitive: false,
          ).hasMatch(val)) {
        return val;
      }
    }

    // 3. Delimited "Movie - Song Video" format
    final parts = rawTitle.split(RegExp(r'\s*[|:–—/]\s*|\s+-\s+'));
    if (parts.length >= 2) {
      final p0 = parts[0].trim();
      final p1 = parts[1].trim();
      final p0Lower = p0.toLowerCase();
      final p1Lower = p1.toLowerCase();
      final p1HasSong =
          p1Lower.contains('song') ||
          p1Lower.contains('video') ||
          p1Lower.contains('audio');
      final p0HasSong =
          p0Lower.contains('song') ||
          p0Lower.contains('video') ||
          p0Lower.contains('audio');
      if (p1HasSong && !p0HasSong && p0.length >= 2) {
        return p0;
      }
    }

    return null;
  }

  /// Multi-tier resolver to find the genuine [JioAlbum] for any given [song].
  ///
  /// Tier 1: In-memory cached JioAlbum object (instant)
  /// Tier 2: Cached JioSaavn albumId -> fetch tracks
  /// Tier 3: Cached album title or extracted movie title -> search albums catalog
  /// Tier 4: Edge single-track endpoint (/jio) -> retrieve album tag -> search albums catalog
  Future<JioAlbum?> resolveAlbumForSong(Video song) async {
    final id = song.id.value;

    // Tier 1: Direct in-memory cached JioAlbum object
    final cachedObj = getCachedAlbum(id);
    if (cachedObj != null && cachedObj.songs.isNotEmpty) {
      return cachedObj;
    }

    // Tier 2: Cached albumId
    final cachedId = getCachedAlbumId(id);
    if (cachedId != null && cachedId.isNotEmpty) {
      final loaded = await fetchAlbumTracks(cachedId);
      if (loaded != null && loaded.songs.isNotEmpty) {
        registerSongAlbum(id, album: loaded);
        return loaded;
      }
    }

    // Tier 3: Cached album title or regex-extracted movie title
    String? albumTitle = getCachedAlbumTitle(id);
    albumTitle ??= extractMovieOrAlbumTitle(song.title);

    // Tier 4: Edge single-track resolver if albumTitle is still absent
    if (albumTitle == null || albumTitle.isEmpty) {
      try {
        final cleanTitle = CanonicalSongDedup.cleanTitle(song.title);
        final cleanArtist = CanonicalSongDedup.cleanArtist(song.author);
        if (cleanTitle.isNotEmpty) {
          final uri = ApiConfig.jioSingleTrackUri(
            cleanTitle,
            artist: cleanArtist,
          );
          final resp = await http.get(uri).timeout(const Duration(seconds: 4));
          if (resp.statusCode == 200) {
            final body = json.decode(resp.body);
            if (body is Map && body['match'] == true) {
              final data = body['data'] as Map<String, dynamic>?;
              final resolvedAlbum = data?['album'] as String? ?? '';
              final resolvedAlbumId =
                  data?['album_id']?.toString() ??
                  data?['albumId']?.toString() ??
                  '';
              if (resolvedAlbum.isNotEmpty) {
                albumTitle = resolvedAlbum;
                registerSongAlbum(
                  id,
                  albumTitle: resolvedAlbum,
                  albumId: resolvedAlbumId,
                );
              }
            }
          }
        }
      } catch (_) {}
    }

    // If an album title was found, search the JioSaavn catalog for matching album
    if (albumTitle != null && albumTitle.isNotEmpty) {
      final albums = await searchAlbums(albumTitle, limit: 3);
      if (albums.isNotEmpty) {
        final searchLower = albumTitle.toLowerCase();
        final match = albums.firstWhere(
          (a) =>
              a.title.toLowerCase().contains(searchLower) ||
              searchLower.contains(a.title.toLowerCase()),
          orElse: () => albums.first,
        );
        if (match.id.isNotEmpty) {
          final loaded = await fetchAlbumTracks(match.id);
          if (loaded != null && loaded.songs.isNotEmpty) {
            registerSongAlbum(id, album: loaded);
            return loaded;
          }
        }
      }
    }

    return null;
  }
}
