import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'canonical_song_dedup.dart';
import 'playlist_artist_filter.dart';
import 'spotify_import_service.dart';
import 'web_player_bridge.dart';

enum ArtworkStyle { card, vinyl }

enum ScrubberStyle { waveform, classic }

enum AudioQualityPreset {
  studioMaster, // 320 kbps (Direct JioSaavn 320k CDN / max bitrate)
  high, // 160 kbps (High Fidelity Opus / 160k AAC)
  balanced, // 128 kbps (Standard balanced, Format 18 / 128k AAC)
  dataSaver, // 64 kbps (Low-bandwidth 48-64k Opus/AAC, saves data)
}

extension AudioQualityPresetExt on AudioQualityPreset {
  String get label {
    switch (this) {
      case AudioQualityPreset.studioMaster:
        return 'Studio Master (320 kbps)';
      case AudioQualityPreset.high:
        return 'High Fidelity (160 kbps)';
      case AudioQualityPreset.balanced:
        return 'Balanced (128 kbps)';
      case AudioQualityPreset.dataSaver:
        return 'Data Saver (64 kbps)';
    }
  }

  String get shortLabel {
    switch (this) {
      case AudioQualityPreset.studioMaster:
        return '320 kbps';
      case AudioQualityPreset.high:
        return '160 kbps';
      case AudioQualityPreset.balanced:
        return '128 kbps';
      case AudioQualityPreset.dataSaver:
        return '64 kbps';
    }
  }

  String get badge {
    switch (this) {
      case AudioQualityPreset.studioMaster:
        return '320K';
      case AudioQualityPreset.high:
        return '160K';
      case AudioQualityPreset.balanced:
        return '128K';
      case AudioQualityPreset.dataSaver:
        return '64K';
    }
  }

  String get description {
    switch (this) {
      case AudioQualityPreset.studioMaster:
        return 'Pristine 320 kbps direct CDN audio with maximum dynamic range. Recommended for headphones and Wi-Fi.';
      case AudioQualityPreset.high:
        return '160 kbps Opus & AAC. Crystal clear audio with fast buffering.';
      case AudioQualityPreset.balanced:
        return '128 kbps standard audio. Optimal balance between quality and data efficiency.';
      case AudioQualityPreset.dataSaver:
        return 'Compact 48-64 kbps stream. Minimizes mobile data consumption on cellular networks.';
    }
  }

  int get approxBitrate {
    switch (this) {
      case AudioQualityPreset.studioMaster:
        return 320;
      case AudioQualityPreset.high:
        return 160;
      case AudioQualityPreset.balanced:
        return 128;
      case AudioQualityPreset.dataSaver:
        return 64;
    }
  }
}

enum AudioFormatPreference {
  auto, // Smart Auto (Platform Optimal)
  opus, // Opus (WebM Audio)
  aac, // AAC (MP4 / Apple Core)
  mp3, // MP3 (Direct Audio)
}

extension AudioFormatPreferenceExt on AudioFormatPreference {
  String get label {
    switch (this) {
      case AudioFormatPreference.auto:
        return 'Auto (Smart Engine)';
      case AudioFormatPreference.opus:
        return 'Opus (WebM Audio)';
      case AudioFormatPreference.aac:
        return 'AAC (MP4 / Apple Core)';
      case AudioFormatPreference.mp3:
        return 'MP3 (Direct Audio)';
    }
  }

  String get shortLabel {
    switch (this) {
      case AudioFormatPreference.auto:
        return 'Auto';
      case AudioFormatPreference.opus:
        return 'Opus';
      case AudioFormatPreference.aac:
        return 'AAC';
      case AudioFormatPreference.mp3:
        return 'MP3';
    }
  }

  String get badge {
    switch (this) {
      case AudioFormatPreference.auto:
        return 'AUTO';
      case AudioFormatPreference.opus:
        return 'OPUS';
      case AudioFormatPreference.aac:
        return 'AAC';
      case AudioFormatPreference.mp3:
        return 'MP3';
    }
  }

  String get description {
    switch (this) {
      case AudioFormatPreference.auto:
        return 'Intelligently chooses the lowest latency and highest fidelity stream for your device.';
      case AudioFormatPreference.opus:
        return 'Modern next-gen open lossy codec. Superior acoustic clarity and rich detail per bit.';
      case AudioFormatPreference.aac:
        return 'Industry standard Advanced Audio Coding. Hardware-accelerated decoding across all devices.';
      case AudioFormatPreference.mp3:
        return 'Standard direct audio container for maximum legacy cross-platform compatibility.';
    }
  }
}

class TasteMatrix {
  final List<String> topArtists;
  final List<String> preferredLanguages;
  final Map<String, double> artistAffinities;
  final int totalPlays;
  final int totalSkips;

  const TasteMatrix({
    required this.topArtists,
    required this.preferredLanguages,
    required this.artistAffinities,
    required this.totalPlays,
    required this.totalSkips,
  });
}

class CircadianContext {
  final String title;
  final String subtitle;
  final String query;
  final String tag;
  final String emoji;

  const CircadianContext({
    required this.title,
    required this.subtitle,
    required this.query,
    required this.tag,
    required this.emoji,
  });
}

class DailyMixConfig {
  final String title;
  final String subtitle;
  final String query;

  const DailyMixConfig({
    required this.title,
    required this.subtitle,
    required this.query,
  });
}

class PreferencesService extends ChangeNotifier {
  static final PreferencesService _instance = PreferencesService._internal();
  factory PreferencesService() => _instance;

  PreferencesService._internal();

  late SharedPreferences _prefs;
  bool _isInitialized = false;

  // Settings
  bool _crossfadeEnabled = true;
  int _crossfadeSeconds = 4;
  bool _smartCrossfadeEnabled = true;
  bool _fadeInOnStartEnabled = false;
  bool _equalizerEnabled = false;
  String _equalizerPreset = 'Flat';
  Map<int, double> _equalizerBands = {0: 0.0, 1: 0.0, 2: 0.0, 3: 0.0, 4: 0.0};
  double _bassBoost = 0.0;
  double _virtualizer = 0.0;
  Color _themeColor = const Color(0xFFFA2D48); // Default DilSe Crimson
  double _cacheSizeMB = 500.0;
  String _customServerUrl = '';
  String _cloudflareWorkerUrl = '';
  ArtworkStyle _artworkStyle = ArtworkStyle.card;
  ScrubberStyle _scrubberStyle = ScrubberStyle.waveform;
  AudioQualityPreset _audioQuality = AudioQualityPreset.balanced;
  AudioFormatPreference _audioFormat = AudioFormatPreference.auto;
  String _lyricsDisplayMode = 'original'; // 'original', 'pronunciation', 'dual'
  String _userName = '';
  bool _hasPromptedName = false;
  String? _profileImagePath;

  // Search History
  List<String> _searchHistory = [];

  // Followed Artists (Independent of Daily Mix & Listening History)
  static const String _followedArtistsKey = 'followed_artists_v1';
  final Set<String> _followedArtists = {};

  // Listening History
  List<Map<String, String>> _listeningHistory = [];

  // Listening Preferences & Play Counts (Local Private Taste Matrix)
  final Map<String, int> _artistPlayCounts = {};
  final Map<String, int> _artistSkipCounts = {};
  // Real-time On-Device Playback Stream Counts (Tracks actual listening sessions)
  final Map<String, int> _realPlaybackCounts = {};
  // Real-time Most Played Tracks (Top 100 on-device playback streams)
  final Map<String, Map<String, dynamic>> _mostPlayedSongs = {};
  int _topArtistPlayCount = 0;
  List<String> _preferredLanguages = [
    'Hindi',
    'Telugu',
    'Tamil',
    'Punjabi',
    'English',
  ];
  String _mostPlayedArtist = '';
  UserAudioProfile _audioProfile = const UserAudioProfile();

  bool get isInitialized => _isInitialized;
  bool get crossfadeEnabled => _crossfadeEnabled;
  int get crossfadeSeconds => _crossfadeSeconds;
  bool get smartCrossfadeEnabled => _smartCrossfadeEnabled;
  bool get fadeInOnStartEnabled => _fadeInOnStartEnabled;
  bool get equalizerEnabled => _equalizerEnabled;
  String get equalizerPreset => _equalizerPreset;
  Map<int, double> get equalizerBands => Map.unmodifiable(_equalizerBands);
  double get bassBoost => _bassBoost;
  double get virtualizer => _virtualizer;
  Color get themeColor => _themeColor;

  /// Returns a WCAG AA-compliant legible accent color on dark surfaces (#0B0B0F).
  /// If the current theme color's luminance is below 0.18, it is brightened in HSL space
  /// so scrubbers, active indicators, and icons remain crisp and accessible.
  Color get legibleThemeColor => ensureLegibleColor(_themeColor);

  /// Helper to ensure any accent color provides sufficient contrast on dark backgrounds.
  static Color ensureLegibleColor(Color color, {double minLuminance = 0.18}) {
    if (color.computeLuminance() >= minLuminance) return color;

    final hsl = HSLColor.fromColor(color);
    double lightness = (hsl.lightness + 0.35).clamp(0.48, 0.95);
    var candidate = hsl.withLightness(lightness).toColor();

    while (candidate.computeLuminance() < minLuminance && lightness < 0.95) {
      lightness = (lightness + 0.05).clamp(0.0, 0.95);
      candidate = hsl.withLightness(lightness).toColor();
    }
    return candidate;
  }

  double get cacheSizeMB => _cacheSizeMB;
  String get customServerUrl => _customServerUrl;
  String get cloudflareWorkerUrl => _cloudflareWorkerUrl;
  ArtworkStyle get artworkStyle => _artworkStyle;
  ScrubberStyle get scrubberStyle => _scrubberStyle;
  AudioQualityPreset get audioQuality => _audioQuality;
  AudioFormatPreference get audioFormat => _audioFormat;
  String get lyricsDisplayMode => _lyricsDisplayMode;
  String get userName => _userName.isEmpty ? 'Friend' : _userName;
  bool get hasCustomName => _userName.isNotEmpty;
  bool get hasPromptedName => _hasPromptedName;
  String? get profileImagePath => _profileImagePath;
  List<String> get searchHistory => _searchHistory;
  List<Map<String, String>> get listeningHistory => _listeningHistory;
  List<String> get followedArtists => _followedArtists.toList(growable: false);
  List<String> get preferredLanguages => _preferredLanguages;
  String get mostPlayedArtist => _mostPlayedArtist;
  int get topArtistPlayCount => _topArtistPlayCount;
  Map<String, int> get realPlaybackCounts =>
      Map.unmodifiable(_realPlaybackCounts);

  /// Top 100 Most Played Tracks on this device, sorted descending by stream count
  List<Map<String, dynamic>> get mostPlayedSongs {
    final list = _mostPlayedSongs.values
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    list.sort((a, b) {
      final countA = (a['playCount'] as num?)?.toInt() ?? 0;
      final countB = (b['playCount'] as num?)?.toInt() ?? 0;
      if (countB != countA) {
        return countB.compareTo(countA);
      }
      final dateA = (a['lastPlayedAt'] as String?) ?? '';
      final dateB = (b['lastPlayedAt'] as String?) ?? '';
      return dateB.compareTo(dateA);
    });
    return list.take(100).toList();
  }

  UserAudioProfile get audioProfile => _audioProfile;
  int get totalPlays {
    final realTotal = _realPlaybackCounts.values.fold(0, (a, b) => a + b);
    if (realTotal > 0) return realTotal;
    if (_listeningHistory.isNotEmpty) return _listeningHistory.length;
    return _artistPlayCounts.values.fold(0, (a, b) => a + b);
  }

  int get totalSkips => _artistSkipCounts.values.fold(0, (a, b) => a + b);

  Future<void> init() async {
    if (_isInitialized) return;
    _prefs = await SharedPreferences.getInstance();

    final hasUserSetCrossfade = _prefs.getBool('crossfade_user_set') ?? false;
    if (!hasUserSetCrossfade) {
      _crossfadeEnabled = true;
      _crossfadeSeconds = 4;
      await _prefs.setBool('crossfade', true);
      await _prefs.setInt('crossfadeSeconds', 4);
    } else {
      _crossfadeEnabled = _prefs.getBool('crossfade') ?? true;
      _crossfadeSeconds = _prefs.getInt('crossfadeSeconds') ?? 4;
    }
    _smartCrossfadeEnabled = _prefs.getBool('smartCrossfade') ?? true;
    _fadeInOnStartEnabled = _prefs.getBool('fadeInOnStart') ?? false;
    _equalizerEnabled = _prefs.getBool('equalizerEnabled') ?? false;
    _equalizerPreset = _prefs.getString('equalizerPreset') ?? 'Flat';
    _bassBoost = _prefs.getDouble('bassBoost') ?? 0.0;
    _virtualizer = _prefs.getDouble('virtualizer') ?? 0.0;
    final bandsJson = _prefs.getString('equalizerBandsJson');
    if (bandsJson != null && bandsJson.isNotEmpty) {
      try {
        final Map<String, dynamic> decoded = json.decode(bandsJson);
        final map = <int, double>{};
        decoded.forEach((k, v) => map[int.parse(k)] = (v as num).toDouble());
        _equalizerBands = map;
      } catch (_) {}
    }

    int colorValue = _prefs.getInt('themeColor') ?? 0xFFFA2D48;
    _themeColor = Color(colorValue);
    _cacheSizeMB = _prefs.getDouble('cacheSizeMB') ?? 500.0;
    _customServerUrl = _prefs.getString('customServerUrl') ?? '';
    _cloudflareWorkerUrl = _prefs.getString('cloudflareWorkerUrl') ?? '';
    _searchHistory = _prefs.getStringList('searchHistory') ?? [];
    _mostPlayedArtist = _prefs.getString('mostPlayedArtist') ?? '';
    _userName = _prefs.getString('userName') ?? '';
    _hasPromptedName = _prefs.getBool('hasPromptedName') ?? false;
    _profileImagePath = _prefs.getString('profileImagePath');
    final styleStr = _prefs.getString('artworkStyle') ?? 'card';
    _artworkStyle = styleStr == 'vinyl'
        ? ArtworkStyle.vinyl
        : ArtworkStyle.card;
    final scrubStr = _prefs.getString('scrubberStyle') ?? 'waveform';
    _scrubberStyle = scrubStr == 'classic'
        ? ScrubberStyle.classic
        : ScrubberStyle.waveform;
    final qualityStr = _prefs.getString('audioQualityPreset') ?? 'balanced';
    _audioQuality = AudioQualityPreset.values.firstWhere(
      (e) => e.name == qualityStr,
      orElse: () => AudioQualityPreset.balanced,
    );
    final formatStr = _prefs.getString('audioFormatPreference') ?? 'auto';
    _audioFormat = AudioFormatPreference.values.firstWhere(
      (e) => e.name == formatStr,
      orElse: () => AudioFormatPreference.auto,
    );
    _lyricsDisplayMode = _prefs.getString('lyricsDisplayMode') ?? 'original';

    final historyJson = _prefs.getString('listeningHistoryJson');
    if (historyJson != null && historyJson.isNotEmpty) {
      try {
        final List<dynamic> decoded = json.decode(historyJson);
        _listeningHistory = decoded
            .map((e) => Map<String, String>.from(e))
            .toList();
      } catch (_) {
        _listeningHistory = [];
      }
    }

    final followedList = _prefs.getStringList(_followedArtistsKey) ?? [];
    _followedArtists
      ..clear()
      ..addAll(followedList);

    final playsJson = _prefs.getString('artistPlayCountsJson');
    if (playsJson != null && playsJson.isNotEmpty) {
      try {
        final Map<String, dynamic> decoded = json.decode(playsJson);
        decoded.forEach((k, v) => _artistPlayCounts[k] = (v as num).toInt());
      } catch (_) {}
    }

    final realPlaysJson = _prefs.getString('realPlaybackCountsJson');
    if (realPlaysJson != null && realPlaysJson.isNotEmpty) {
      try {
        final Map<String, dynamic> decoded = json.decode(realPlaysJson);
        decoded.forEach((k, v) => _realPlaybackCounts[k] = (v as num).toInt());
      } catch (_) {}
    }

    // Auto-heal & decompose legacy composite keys e.g. "S.P. Balasubramaniam, Srinivas D., Khatija Rahman"
    _sanitizeArtistCountMap(_artistPlayCounts);
    _sanitizeArtistCountMap(_realPlaybackCounts);

    // If realPlaybackCounts is empty, seed from listening history
    if (_realPlaybackCounts.isEmpty && _listeningHistory.isNotEmpty) {
      _rebuildRealPlaybackCountsFromHistory();
      _sanitizeArtistCountMap(_realPlaybackCounts);
    }

    _recalculateTopArtist();

    final mostPlayedJson = _prefs.getString('mostPlayedSongsJson');
    if (mostPlayedJson != null && mostPlayedJson.isNotEmpty) {
      try {
        final Map<String, dynamic> decoded = json.decode(mostPlayedJson);
        decoded.forEach((k, v) {
          if (v is Map) {
            _mostPlayedSongs[k] = Map<String, dynamic>.from(v);
          }
        });
      } catch (_) {}
    }

    // If _mostPlayedSongs is empty, backfill from _listeningHistory
    if (_mostPlayedSongs.isEmpty && _listeningHistory.isNotEmpty) {
      for (final song in _listeningHistory) {
        final id = song['id'];
        if (id != null && id.isNotEmpty) {
          final existing = _mostPlayedSongs[id];
          if (existing != null) {
            existing['playCount'] = ((existing['playCount'] as int?) ?? 1) + 1;
          } else {
            _mostPlayedSongs[id] = {
              'id': id,
              'title': song['title'] ?? 'Unknown Track',
              'author': song['author'] ?? 'Unknown Artist',
              'thumbnail': song['thumbnail'] ?? '',
              'playCount': 1,
              'lastPlayedAt':
                  song['playedAt'] ?? DateTime.now().toIso8601String(),
            };
          }
        }
      }
    }

    final skipsJson = _prefs.getString('artistSkipCountsJson');
    if (skipsJson != null && skipsJson.isNotEmpty) {
      try {
        final Map<String, dynamic> decoded = json.decode(skipsJson);
        decoded.forEach((k, v) => _artistSkipCounts[k] = (v as num).toInt());
      } catch (_) {}
    }

    final langs = _prefs.getStringList('preferredLanguages');
    if (langs != null && langs.isNotEmpty) {
      _preferredLanguages = langs;
    }

    final profileJson = _prefs.getString('userAudioProfileJson');
    if (profileJson != null && profileJson.isNotEmpty) {
      try {
        _audioProfile = UserAudioProfile.fromJson(json.decode(profileJson));
      } catch (_) {}
    }

    final savedSpotifyIds = _prefs.getStringList(
      'spotify_imported_playlist_ids',
    );
    if (savedSpotifyIds != null) {
      _spotifyImportedPlaylistIds = savedSpotifyIds.toSet();
    }

    final savedManualIds = _prefs.getStringList('manual_created_playlist_ids');
    if (savedManualIds != null) {
      _manualCreatedPlaylistIds = savedManualIds.toSet();
    }

    _isInitialized = true;
    WebPlayerBridge.setEqualizer(_equalizerEnabled, _equalizerBands);
    notifyListeners();
  }

  /// Canonicalizes artist names with popular Indian/global aliases and proper formatting
  static String _canonicalizeArtistName(String raw) {
    final clean = PlaylistArtistFilter.normalize(raw);
    if (clean == 'dsp' || clean == 'devi sri prasad') return 'Devi Sri Prasad';
    if (clean == 'anirudh' || clean == 'anirudh ravichander') {
      return 'Anirudh Ravichander';
    }
    if (clean == 'sid' || clean == 'sid sriram') return 'Sid Sriram';
    if (clean == 'arijit' || clean == 'arijit singh') return 'Arijit Singh';
    if (clean == 'arr' ||
        clean == 'ar rahman' ||
        clean == 'a r rahman' ||
        clean == 'rahman') {
      return 'A.R. Rahman';
    }
    if (clean == 'shreya' || clean == 'shreya ghoshal') return 'Shreya Ghoshal';
    if (clean == 'thaman' || clean == 'thaman s' || clean == 's thaman') {
      return 'Thaman S';
    }
    if (clean == 'spb' ||
        clean.contains('balasubra') ||
        clean == 's p balasubrahmanyam' ||
        clean == 's p balasubramaniam' ||
        clean == 'balasubrahmanyam' ||
        clean == 'balasubramaniam') {
      return 'S.P. Balasubrahmanyam';
    }
    if (clean == 'keeravani' ||
        clean == 'm m keeravani' ||
        clean == 'keeravaani') {
      return 'M.M. Keeravaani';
    }
    if (clean == 'pritam' || clean == 'pritam chakraborty') return 'Pritam';
    if (clean == 'yuvan' || clean == 'yuvan shankar raja') {
      return 'Yuvan Shankar Raja';
    }
    if (clean == 'santhosh' || clean == 'santhosh narayanan') {
      return 'Santhosh Narayanan';
    }
    if (clean == 'harris' || clean == 'harris jayaraj') return 'Harris Jayaraj';
    if (clean == 'shilpa' || clean == 'shilpa rao') return 'Shilpa Rao';
    if (clean == 'jonita' || clean == 'jonita gandhi') return 'Jonita Gandhi';
    if (clean == 'ilayaraja' || clean == 'ilaiyaraaja') return 'Ilaiyaraaja';

    final words = raw.trim().split(RegExp(r'\s+'));
    return words
        .map((w) {
          if (w.isEmpty) return '';
          return '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}';
        })
        .join(' ');
  }

  /// Resolves genuine artist names from song metadata, stripping channel/record label noise
  static List<String> _resolveCanonicalArtists(
    String rawAuthor,
    String rawTitle,
  ) {
    final artists = PlaylistArtistFilter.extractArtistsFromSong({
      'author': rawAuthor,
      'title': rawTitle,
    });
    if (artists.isNotEmpty) {
      return artists.map((a) => _canonicalizeArtistName(a)).toSet().toList();
    }
    final cleaned = CanonicalSongDedup.cleanArtist(rawAuthor);
    if (cleaned.isNotEmpty) {
      return [_canonicalizeArtistName(cleaned)];
    }
    if (rawAuthor.trim().isNotEmpty) {
      return [_canonicalizeArtistName(rawAuthor.trim())];
    }
    return [];
  }

  void _sanitizeArtistCountMap(Map<String, int> map) {
    if (map.isEmpty) return;
    final entries = Map<String, int>.from(map);
    map.clear();
    for (final entry in entries.entries) {
      final key = entry.key.trim();
      final count = entry.value;
      if (key.isEmpty || count <= 0) continue;

      final resolved = _resolveCanonicalArtists(key, '');
      if (resolved.isNotEmpty) {
        for (final a in resolved) {
          final norm = PlaylistArtistFilter.normalize(a);
          if (norm.isNotEmpty &&
              norm != 'aditya music' &&
              norm != 'tseries' &&
              norm != 't-series' &&
              norm != 'sony music' &&
              norm != 'zee music') {
            map[a] = (map[a] ?? 0) + count;
          }
        }
      } else {
        final norm = PlaylistArtistFilter.normalize(key);
        if (norm.isNotEmpty &&
            norm != 'aditya music' &&
            norm != 'tseries' &&
            norm != 't-series' &&
            norm != 'sony music' &&
            norm != 'zee music') {
          final canon = _canonicalizeArtistName(key);
          map[canon] = (map[canon] ?? 0) + count;
        }
      }
    }
  }

  static String extractSingleLeadArtist(String raw) {
    if (raw.trim().isEmpty) return '';
    final resolved = _resolveCanonicalArtists(raw, '');
    if (resolved.isNotEmpty) {
      return resolved.first;
    }
    final parts = raw.split(
      RegExp(
        r'[,;&/|]|(?:\s+feat\.?\s+)|\s+ft\.?\s+|\s+with\s+|\s+and\s+',
        caseSensitive: false,
      ),
    );
    for (final p in parts) {
      final trimmed = p.trim();
      final norm = PlaylistArtistFilter.normalize(trimmed);
      if (norm.isNotEmpty &&
          norm != 'aditya music' &&
          norm != 'tseries' &&
          norm != 't-series' &&
          norm != 'sony music' &&
          norm != 'zee music' &&
          trimmed.length >= 2) {
        return _canonicalizeArtistName(trimmed);
      }
    }
    return _canonicalizeArtistName(raw.trim());
  }

  void _rebuildRealPlaybackCountsFromHistory() {
    for (final track in _listeningHistory) {
      final author = track['author'] ?? '';
      final title = track['title'] ?? '';
      final artists = _resolveCanonicalArtists(author, title);
      for (int i = 0; i < artists.length; i++) {
        final a = artists[i];
        final inc = (i == 0) ? 2 : 1;
        _realPlaybackCounts[a] = (_realPlaybackCounts[a] ?? 0) + inc;
      }
    }
  }

  void _recalculateTopArtist() {
    String topArtist = '';
    int maxCount = 0;

    // 1. Primary: Real playback streams on this device
    _realPlaybackCounts.forEach((artist, count) {
      if (count > maxCount) {
        maxCount = count;
        topArtist = artist;
      }
    });

    // 2. Fallback: Taste matrix (if no on-device plays yet)
    if (maxCount == 0) {
      _artistPlayCounts.forEach((artist, count) {
        final norm = PlaylistArtistFilter.normalize(artist);
        if (norm == 'aditya music' ||
            norm == 'tseries' ||
            norm == 't-series' ||
            norm == 'sony music' ||
            norm == 'zee music') {
          return;
        }
        if (count > maxCount) {
          maxCount = count;
          topArtist = _canonicalizeArtistName(artist);
        }
      });
    }

    _topArtistPlayCount = maxCount;
    _mostPlayedArtist = topArtist;
  }

  /// Returns user's top played artists sorted descending by stream count
  List<MapEntry<String, int>> getTopPlayedArtists({int limit = 5}) {
    if (_realPlaybackCounts.isNotEmpty) {
      final sorted = _realPlaybackCounts.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      return sorted.take(limit).toList();
    }
    final sorted =
        _artistPlayCounts.entries
            .where((e) {
              final norm = PlaylistArtistFilter.normalize(e.key);
              return norm != 'aditya music' &&
                  norm != 'tseries' &&
                  norm != 't-series' &&
                  norm != 'sony music';
            })
            .map((e) => MapEntry(_canonicalizeArtistName(e.key), e.value))
            .toList()
          ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.take(limit).toList();
  }

  /// Checks whether an artist is in the user's followed list.
  bool isArtistFollowed(String artistName) {
    final norm = PlaylistArtistFilter.normalize(artistName);
    if (norm.isEmpty) return false;
    return _followedArtists.any(
      (a) => PlaylistArtistFilter.normalize(a) == norm,
    );
  }

  /// Toggles the following status for an artist.
  /// NOTE: Followed artists are strictly isolated and do NOT influence Daily Mix synthesis.
  Future<bool> toggleFollowArtist(String artistName) async {
    final clean = artistName.trim();
    if (clean.isEmpty) return false;
    final norm = PlaylistArtistFilter.normalize(clean);
    final existing = _followedArtists.firstWhere(
      (a) => PlaylistArtistFilter.normalize(a) == norm,
      orElse: () => '',
    );

    bool nowFollowed;
    if (existing.isNotEmpty) {
      _followedArtists.remove(existing);
      nowFollowed = false;
    } else {
      _followedArtists.add(clean);
      nowFollowed = true;
    }

    if (_isInitialized) {
      await _prefs.setStringList(
        _followedArtistsKey,
        _followedArtists.toList(growable: false),
      );
    }
    notifyListeners();
    return nowFollowed;
  }

  Future<void> recordSongPlay(String rawAuthor, String rawTitle) async {
    if (!_isInitialized) return;
    if (rawAuthor.trim().isEmpty && rawTitle.trim().isEmpty) return;

    final artists = _resolveCanonicalArtists(rawAuthor, rawTitle);
    if (artists.isEmpty) return;

    for (int i = 0; i < artists.length; i++) {
      final a = artists[i];
      final increment = (i == 0) ? 2 : 1;
      _realPlaybackCounts[a] = (_realPlaybackCounts[a] ?? 0) + increment;
      _artistPlayCounts[a] = (_artistPlayCounts[a] ?? 0) + increment;
    }

    _recalculateTopArtist();

    await _prefs.setString(
      'realPlaybackCountsJson',
      json.encode(_realPlaybackCounts),
    );
    await _prefs.setString(
      'artistPlayCountsJson',
      json.encode(_artistPlayCounts),
    );
    if (_mostPlayedArtist.isNotEmpty) {
      await _prefs.setString('mostPlayedArtist', _mostPlayedArtist);
    }
    notifyListeners();
  }

  Future<void> recordSongSkip(String artist) async {
    if (!_isInitialized) return;
    if (artist.trim().isEmpty) return;

    final count = (_artistSkipCounts[artist] ?? 0) + 1;
    _artistSkipCounts[artist] = count;
    await _prefs.setString(
      'artistSkipCountsJson',
      json.encode(_artistSkipCounts),
    );
    notifyListeners();
  }

  Future<void> setPreferredLanguages(List<String> langs) async {
    if (!_isInitialized) return;
    _preferredLanguages = List.from(langs);
    await _prefs.setStringList('preferredLanguages', _preferredLanguages);
    notifyListeners();
  }

  Future<void> setLyricsDisplayMode(String mode) async {
    _lyricsDisplayMode = mode;
    if (_isInitialized) {
      await _prefs.setString('lyricsDisplayMode', mode);
    }
    notifyListeners();
  }

  /// Builds the 100% private local "Taste Matrix" inspired by ListenBrainz/Troi
  TasteMatrix getTasteMatrix() {
    final affinities = <String, double>{};
    final allArtists = {..._artistPlayCounts.keys, ..._artistSkipCounts.keys};

    for (final rawArtist in allArtists) {
      final plays = _artistPlayCounts[rawArtist] ?? 0;
      final skips = _artistSkipCounts[rawArtist] ?? 0;
      final netAffinity = (plays * 2.0) - (skips * 1.0);

      // Decompose any composite artist string so individual artists get scored
      final resolved = _resolveCanonicalArtists(rawArtist, '');
      final targets = resolved.isNotEmpty
          ? resolved
          : [_canonicalizeArtistName(rawArtist)];

      for (final a in targets) {
        final norm = PlaylistArtistFilter.normalize(a);
        if (norm.isEmpty ||
            norm == 'aditya music' ||
            norm == 'tseries' ||
            norm == 't-series' ||
            norm == 'sony music' ||
            norm == 'zee music' ||
            a.length < 2) {
          continue;
        }
        affinities[a] = (affinities[a] ?? 0) + netAffinity;
      }
    }

    final sorted = affinities.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    List<String> top = sorted.take(5).map((e) => e.key).toList();
    if (top.isEmpty) {
      top = [
        'Arijit Singh',
        'Anirudh Ravichander',
        'Pritam',
        'Sid Sriram',
        'Shreya Ghoshal',
      ];
    }

    return TasteMatrix(
      topArtists: top,
      preferredLanguages: List.unmodifiable(_preferredLanguages),
      artistAffinities: affinities,
      totalPlays: _artistPlayCounts.values.fold(0, (a, b) => a + b),
      totalSkips: _artistSkipCounts.values.fold(0, (a, b) => a + b),
    );
  }

  /// Returns user's top played artists based on on-device playback history
  List<String> getTopArtists({int limit = 5}) {
    final matrix = getTasteMatrix();
    return matrix.topArtists.take(limit).toList();
  }

  /// Circadian Time-of-Day Contextualizer:
  /// Morning (acoustic/ambient), Afternoon (upbeat/tempo), Evening (trending/hits), Late Night (lo-fi/slowed)
  CircadianContext getCircadianContext() {
    final hour = DateTime.now().hour;
    final primaryLang = _preferredLanguages.isNotEmpty
        ? _preferredLanguages.first
        : 'Telugu';

    if (hour >= 5 && hour < 12) {
      return CircadianContext(
        title: 'Morning Melodies',
        subtitle: 'Soft acoustic & ambient vibes to start your day',
        query: '$primaryLang Melodies',
        tag: 'MORNING',
        emoji: '🌅',
      );
    }
    if (hour >= 12 && hour < 17) {
      return CircadianContext(
        title: 'Afternoon Energy',
        subtitle: 'High-tempo beats and chartbusters to keep you grooving',
        query: '$primaryLang Fast Hits',
        tag: 'AFTERNOON',
        emoji: '⚡',
      );
    }
    if (hour >= 17 && hour < 22) {
      return CircadianContext(
        title: 'Evening Chill',
        subtitle: 'Trending relaxing tracks and chill evening vibes',
        query: '$primaryLang Top Hits',
        tag: 'EVENING',
        emoji: '🌆',
      );
    }
    return CircadianContext(
      title: 'Late Night Vibes',
      subtitle: 'Dreamy lo-fi and slowed melodies for quiet hours',
      query: '$primaryLang Slow Melodies',
      tag: 'LATE NIGHT',
      emoji: '🌙',
    );
  }

  String getTimeOfDayGreeting() {
    return getCircadianContext().title;
  }

  /// Multi-Seed Daily Mix Synthesizer (Inspired by Spotube)
  static void Function(bool enabled, Map<int, double> bands)?
  onEqualizerChanged;

  List<DailyMixConfig> getDailyMixConfigs() {
    final top = getTopArtists(limit: 10);
    final primaryLang = _preferredLanguages.isNotEmpty
        ? _preferredLanguages.first
        : 'Telugu';

    // Curated iconic artist fallbacks by language
    final List<String> languageDefaults;
    switch (primaryLang.toLowerCase()) {
      case 'tamil':
        languageDefaults = [
          'Anirudh Ravichander',
          'A.R. Rahman',
          'Yuvan Shankar Raja',
        ];
        break;
      case 'hindi':
        languageDefaults = ['Arijit Singh', 'Pritam', 'Shreya Ghoshal'];
        break;
      case 'punjabi':
        languageDefaults = ['Diljit Dosanjh', 'B Praak', 'Karan Aujla'];
        break;
      case 'malayalam':
        languageDefaults = ['K.S. Chithra', 'Sushin Shyam', 'K.J. Yesudas'];
        break;
      case 'kannada':
        languageDefaults = ['Sanjith Hegde', 'Vijay Prakash', 'Arjun Janya'];
        break;
      case 'english':
        languageDefaults = ['The Weeknd', 'Taylor Swift', 'Ed Sheeran'];
        break;
      case 'telugu':
      default:
        languageDefaults = [
          'Sid Sriram',
          'Anirudh Ravichander',
          'Devi Sri Prasad',
        ];
        break;
    }

    final validArtists = <String>[];
    for (final raw in top) {
      final a = extractSingleLeadArtist(raw);
      if (a.isEmpty || a.length < 3) continue;
      final lower = a.toLowerCase();
      // Blacklist non-artist phrases, title fragments, or noise words
      if (lower.contains('ravi varma') ||
          lower.contains('remix') ||
          lower.contains('mashup') ||
          lower.contains('melody') ||
          lower.contains('instrumental') ||
          lower.contains('theme') ||
          lower.contains('songs') ||
          lower.contains('hits') ||
          lower.contains('music') ||
          lower.contains('audio') ||
          lower.contains('channel') ||
          lower.contains('unknown')) {
        continue;
      }
      if (!validArtists.contains(a)) {
        validArtists.add(a);
      }
    }

    for (final def in languageDefaults) {
      if (!validArtists.contains(def)) {
        validArtists.add(def);
      }
    }

    final artist1 = validArtists[0];
    final artist2 = validArtists.length > 1
        ? validArtists[1]
        : languageDefaults[1];

    return [
      DailyMixConfig(
        title: 'Daily Mix 1',
        subtitle: '$artist1 & Friends',
        query: '$artist1 hit songs',
      ),
      DailyMixConfig(
        title: 'Daily Mix 2',
        subtitle: '$artist2 Melodies',
        query: '$artist2 songs',
      ),
      DailyMixConfig(
        title: 'Made For You',
        subtitle: 'Personalized Blend',
        query: '$primaryLang $artist1 hit songs',
      ),
    ];
  }

  /// Ingests Exportify / Spotify tracks directly into local Taste Matrix & Audio Profile
  Future<void> importExportifyTasteData(List<ExportifyTrack> tracks) async {
    if (!_isInitialized || tracks.isEmpty) return;

    double totalDance = 0;
    double totalEnergy = 0;
    double totalValence = 0;
    double totalTempo = 0;
    double totalAcoustic = 0;
    int featureCount = 0;

    final langScores = <String, int>{};

    for (final track in tracks) {
      final artists = track.artistName
          .split(
            RegExp(
              r'[,;&/|]|(?:\s+feat\.?\s+)|\s+ft\.?\s+',
              caseSensitive: false,
            ),
          )
          .map((a) => a.trim())
          .where((a) => a.isNotEmpty && a.length > 1);

      for (final artist in artists) {
        _artistPlayCounts[artist] = (_artistPlayCounts[artist] ?? 0) + 3;
      }

      final detected = CanonicalSongDedup.detectLanguage(
        '${track.trackName} ${track.artistName}',
      );
      if (detected != null) {
        langScores[detected] = (langScores[detected] ?? 0) + 1;
      }

      if (track.energy > 0 || track.valence > 0) {
        totalDance += track.danceability;
        totalEnergy += track.energy;
        totalValence += track.valence;
        totalTempo += track.tempo;
        totalAcoustic += track.acousticness;
        featureCount++;
      }
    }

    if (featureCount > 0) {
      _audioProfile = UserAudioProfile(
        avgDanceability: totalDance / featureCount,
        avgEnergy: totalEnergy / featureCount,
        avgValence: totalValence / featureCount,
        avgTempo: totalTempo / featureCount,
        avgAcousticness: totalAcoustic / featureCount,
        tracksAnalyzed: featureCount,
      );
      await _prefs.setString(
        'userAudioProfileJson',
        json.encode(_audioProfile.toJson()),
      );
    }

    if (langScores.isNotEmpty) {
      final sortedLangs = langScores.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final topDetected = sortedLangs.take(3).map((e) => e.key).toList();
      for (final l in topDetected) {
        if (!_preferredLanguages.contains(l)) {
          _preferredLanguages.insert(0, l);
        } else {
          _preferredLanguages.remove(l);
          _preferredLanguages.insert(0, l);
        }
      }
      await _prefs.setStringList('preferredLanguages', _preferredLanguages);
    }

    await _prefs.setString(
      'artistPlayCountsJson',
      json.encode(_artistPlayCounts),
    );

    String topArtist = _mostPlayedArtist;
    int maxCount = 0;
    _artistPlayCounts.forEach((key, val) {
      if (val > maxCount) {
        maxCount = val;
        topArtist = key;
      }
    });
    if (topArtist.isNotEmpty) {
      _mostPlayedArtist = topArtist;
      await _prefs.setString('mostPlayedArtist', _mostPlayedArtist);
    }

    notifyListeners();
  }

  /// Generates dynamic personalized search seeds for the Home Screen
  List<String> getPersonalizedMixSeeds() {
    final mixes = getDailyMixConfigs();
    final vibe = getCircadianContext();
    return [mixes[0].query, mixes[1].query, vibe.query];
  }

  /// Caches home feed data with timestamp TTL (6 hours)
  Future<void> cacheHomeFeed(String key, String jsonData) async {
    if (!_isInitialized) return;
    await _prefs.setString('home_cache_$key', jsonData);
    await _prefs.setInt(
      'home_cache_time_$key',
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Retrieves cached home feed data if less than 6 hours old
  String? getCachedHomeFeed(String key) {
    if (!_isInitialized) return null;
    final timestamp = _prefs.getInt('home_cache_time_$key');
    if (timestamp == null) return null;

    final age = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(timestamp),
    );
    if (age.inHours >= 6) return null; // Stale

    return _prefs.getString('home_cache_$key');
  }

  Future<void> setCrossfade(bool value) async {
    if (!_isInitialized) return;
    _crossfadeEnabled = value;
    await _prefs.setBool('crossfade', value);
    await _prefs.setBool('crossfade_user_set', true);
    notifyListeners();
  }

  Future<void> setCrossfadeSeconds(int seconds) async {
    if (!_isInitialized) return;
    _crossfadeSeconds = seconds.clamp(1, 12);
    await _prefs.setInt('crossfadeSeconds', _crossfadeSeconds);
    await _prefs.setBool('crossfade_user_set', true);
    notifyListeners();
  }

  Future<void> setSmartCrossfade(bool value) async {
    if (!_isInitialized) return;
    _smartCrossfadeEnabled = value;
    await _prefs.setBool('smartCrossfade', value);
    notifyListeners();
  }

  Future<void> setFadeInOnStart(bool value) async {
    if (!_isInitialized) return;
    _fadeInOnStartEnabled = value;
    await _prefs.setBool('fadeInOnStart', value);
    notifyListeners();
  }

  Future<void> setEqualizerEnabled(bool value) async {
    if (!_isInitialized) return;
    _equalizerEnabled = value;
    await _prefs.setBool('equalizerEnabled', value);
    WebPlayerBridge.setEqualizer(_equalizerEnabled, _equalizerBands);
    onEqualizerChanged?.call(_equalizerEnabled, _equalizerBands);
    notifyListeners();
  }

  Future<void> setEqualizerPreset(String preset, Map<int, double> bands) async {
    if (!_isInitialized) return;
    _equalizerPreset = preset;
    _equalizerBands = Map<int, double>.from(bands);
    await _prefs.setString('equalizerPreset', preset);
    final mapForJson = _equalizerBands.map((k, v) => MapEntry(k.toString(), v));
    await _prefs.setString('equalizerBandsJson', json.encode(mapForJson));
    WebPlayerBridge.setEqualizer(_equalizerEnabled, _equalizerBands);
    onEqualizerChanged?.call(_equalizerEnabled, _equalizerBands);
    notifyListeners();
  }

  Future<void> setEqualizerBand(int bandIndex, double gainDb) async {
    if (!_isInitialized) return;
    _equalizerBands[bandIndex] = gainDb.clamp(-12.0, 12.0);
    _equalizerPreset = 'Custom';
    await _prefs.setString('equalizerPreset', 'Custom');
    final mapForJson = _equalizerBands.map((k, v) => MapEntry(k.toString(), v));
    await _prefs.setString('equalizerBandsJson', json.encode(mapForJson));
    WebPlayerBridge.setEqualizer(_equalizerEnabled, _equalizerBands);
    onEqualizerChanged?.call(_equalizerEnabled, _equalizerBands);
    notifyListeners();
  }

  Future<void> setBassBoost(double value) async {
    if (!_isInitialized) return;
    _bassBoost = value.clamp(0.0, 1.0);
    await _prefs.setDouble('bassBoost', _bassBoost);
    notifyListeners();
  }

  Future<void> setVirtualizer(double value) async {
    if (!_isInitialized) return;
    _virtualizer = value.clamp(0.0, 1.0);
    await _prefs.setDouble('virtualizer', _virtualizer);
    notifyListeners();
  }

  Future<void> setThemeColor(Color color) async {
    if (!_isInitialized) return;
    _themeColor = color;
    await _prefs.setInt('themeColor', color.toARGB32());
    notifyListeners();
  }

  Future<void> setCacheSize(double sizeMB) async {
    if (!_isInitialized) return;
    _cacheSizeMB = sizeMB;
    await _prefs.setDouble('cacheSizeMB', sizeMB);
    notifyListeners();
  }

  Future<void> setCustomServerUrl(String url) async {
    if (!_isInitialized) return;
    _customServerUrl = url.trim();
    await _prefs.setString('customServerUrl', _customServerUrl);
    notifyListeners();
  }

  Future<void> setCloudflareWorkerUrl(String url) async {
    if (!_isInitialized) return;
    _cloudflareWorkerUrl = url.trim();
    await _prefs.setString('cloudflareWorkerUrl', _cloudflareWorkerUrl);
    notifyListeners();
  }

  Future<void> addToSearchHistory(String query) async {
    if (!_isInitialized) return;
    if (query.trim().isEmpty) return;
    _searchHistory.remove(query);
    _searchHistory.insert(0, query);
    if (_searchHistory.length > 10) {
      _searchHistory = _searchHistory.sublist(0, 10);
    }
    await _prefs.setStringList('searchHistory', _searchHistory);
    notifyListeners();
  }

  Future<void> removeFromSearchHistory(String query) async {
    if (!_isInitialized) return;
    _searchHistory.remove(query);
    await _prefs.setStringList('searchHistory', _searchHistory);
    notifyListeners();
  }

  Future<void> clearSearchHistory() async {
    if (!_isInitialized) return;
    _searchHistory.clear();
    await _prefs.setStringList('searchHistory', _searchHistory);
    notifyListeners();
  }

  Future<void> addToListeningHistory(Map<String, String> song) async {
    if (!_isInitialized) return;
    final id = song['id'];
    if (id == null || id.isEmpty) return;
    _listeningHistory.removeWhere((item) => item['id'] == id);
    _listeningHistory.insert(0, song);
    if (_listeningHistory.length > 50) {
      _listeningHistory = _listeningHistory.sublist(0, 50);
    }
    await _prefs.setString(
      'listeningHistoryJson',
      json.encode(_listeningHistory),
    );

    // Record in real-time Most Played tracks
    _recordSongInMostPlayed(song);
    await _prefs.setString(
      'mostPlayedSongsJson',
      json.encode(_mostPlayedSongs),
    );

    notifyListeners();
  }

  void _recordSongInMostPlayed(Map<String, String> song) {
    final id = song['id'] ?? '';
    if (id.isEmpty) return;
    final title = song['title'] ?? 'Unknown Track';
    final author = song['author'] ?? 'Unknown Artist';
    final thumbnail = song['thumbnail'] ?? '';

    // Check if key already exists by ID
    String targetKey = id;
    if (!_mostPlayedSongs.containsKey(id)) {
      final normTitle = CanonicalSongDedup.cleanTitle(title);
      final normAuthor = CanonicalSongDedup.cleanArtist(author);
      if (normTitle.isNotEmpty) {
        for (final entry in _mostPlayedSongs.entries) {
          final existingTitle = CanonicalSongDedup.cleanTitle(
            (entry.value['title'] as String?) ?? '',
          );
          final existingAuthor = CanonicalSongDedup.cleanArtist(
            (entry.value['author'] as String?) ?? '',
          );
          if (normTitle == existingTitle) {
            if (normAuthor.isEmpty ||
                existingAuthor.isEmpty ||
                normAuthor == existingAuthor ||
                normAuthor.contains(existingAuthor) ||
                existingAuthor.contains(normAuthor)) {
              targetKey = entry.key;
              break;
            }
          }
        }
      }
    }

    final existing = _mostPlayedSongs[targetKey];
    if (existing != null) {
      final currentCount = (existing['playCount'] as num?)?.toInt() ?? 0;
      existing['playCount'] = currentCount + 1;
      existing['lastPlayedAt'] = DateTime.now().toIso8601String();
      if (((existing['thumbnail'] as String?)?.isEmpty ?? true) &&
          thumbnail.isNotEmpty) {
        existing['thumbnail'] = thumbnail;
      }
    } else {
      _mostPlayedSongs[targetKey] = {
        'id': id,
        'title': title,
        'author': author,
        'thumbnail': thumbnail,
        'playCount': 1,
        'lastPlayedAt': DateTime.now().toIso8601String(),
      };
    }
  }

  /// Manually record a song playback stream into Most Played
  Future<void> recordSongPlayback(Map<String, String> song) async {
    if (!_isInitialized) return;
    _recordSongInMostPlayed(song);
    await _prefs.setString(
      'mostPlayedSongsJson',
      json.encode(_mostPlayedSongs),
    );
    notifyListeners();
  }

  /// Clears the real-time most played songs collection
  Future<void> clearMostPlayedSongs() async {
    if (!_isInitialized) return;
    _mostPlayedSongs.clear();
    await _prefs.remove('mostPlayedSongsJson');
    notifyListeners();
  }

  Future<void> clearListeningHistory() async {
    if (!_isInitialized) return;
    _listeningHistory.clear();
    await _prefs.remove('listeningHistoryJson');
    notifyListeners();
  }

  Future<void> setUserName(String name) async {
    if (!_isInitialized) return;
    _userName = name.trim();
    _hasPromptedName = true;
    await _prefs.setString('userName', _userName);
    await _prefs.setBool('hasPromptedName', true);
    notifyListeners();
  }

  Future<void> setProfileImagePath(String? path) async {
    _profileImagePath = path;
    if (_isInitialized) {
      if (path == null || path.isEmpty) {
        await _prefs.remove('profileImagePath');
      } else {
        await _prefs.setString('profileImagePath', path);
      }
    }
    notifyListeners();
  }

  Future<void> setArtworkStyle(ArtworkStyle style) async {
    if (!_isInitialized) return;
    _artworkStyle = style;
    await _prefs.setString('artworkStyle', style.name);
    notifyListeners();
  }

  Future<void> toggleArtworkStyle() async {
    final next = _artworkStyle == ArtworkStyle.card
        ? ArtworkStyle.vinyl
        : ArtworkStyle.card;
    await setArtworkStyle(next);
  }

  Future<void> setScrubberStyle(ScrubberStyle style) async {
    if (!_isInitialized) return;
    _scrubberStyle = style;
    await _prefs.setString('scrubberStyle', style.name);
    notifyListeners();
  }

  Future<void> setAudioQuality(AudioQualityPreset quality) async {
    _audioQuality = quality;
    if (_isInitialized) {
      await _prefs.setString('audioQualityPreset', quality.name);
    }
    notifyListeners();
  }

  Future<void> setAudioFormat(AudioFormatPreference format) async {
    _audioFormat = format;
    if (_isInitialized) {
      await _prefs.setString('audioFormatPreference', format.name);
    }
    notifyListeners();
  }

  Map<String, dynamic>? get lastPlayedSong {
    if (!_isInitialized) return null;
    final raw = _prefs.getString('last_played_song_json');
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = json.decode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }

  int get lastPlayedPositionMs {
    if (!_isInitialized) return 0;
    return _prefs.getInt('last_played_position_ms') ?? 0;
  }

  int get lastPlayedDurationMs {
    if (!_isInitialized) return 0;
    return _prefs.getInt('last_played_duration_ms') ?? 0;
  }

  List<Map<String, dynamic>> get lastPlayedPlaylist {
    if (!_isInitialized) return [];
    final raw = _prefs.getString('last_played_playlist_json');
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = json.decode(raw);
      if (list is List) {
        return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      }
    } catch (_) {}
    return [];
  }

  int get lastPlayedPlaylistIndex {
    if (!_isInitialized) return 0;
    return _prefs.getInt('last_played_playlist_index') ?? 0;
  }

  int? get lastPlayedDominantColor {
    if (!_isInitialized) return null;
    return _prefs.getInt('last_played_dominant_color');
  }

  int? get lastPlayedVibrantColor {
    if (!_isInitialized) return null;
    return _prefs.getInt('last_played_vibrant_color');
  }

  int? get lastPlayedDarkVibrantColor {
    if (!_isInitialized) return null;
    return _prefs.getInt('last_played_dark_vibrant_color');
  }

  Future<void> saveLastPlaybackSession({
    required Map<String, dynamic> song,
    required int positionMs,
    required int durationMs,
    List<Map<String, dynamic>>? playlist,
    int? playlistIndex,
    Color? dominantColor,
    Color? vibrantColor,
    Color? darkVibrantColor,
  }) async {
    if (!_isInitialized) return;
    await _prefs.setString('last_played_song_json', json.encode(song));
    await _prefs.setInt('last_played_position_ms', positionMs);
    await _prefs.setInt('last_played_duration_ms', durationMs);
    if (playlist != null && playlist.isNotEmpty) {
      await _prefs.setString(
        'last_played_playlist_json',
        json.encode(playlist),
      );
    }
    if (playlistIndex != null) {
      await _prefs.setInt('last_played_playlist_index', playlistIndex);
    }
    if (dominantColor != null) {
      await _prefs.setInt(
        'last_played_dominant_color',
        dominantColor.toARGB32(),
      );
    }
    if (vibrantColor != null) {
      await _prefs.setInt('last_played_vibrant_color', vibrantColor.toARGB32());
    }
    if (darkVibrantColor != null) {
      await _prefs.setInt(
        'last_played_dark_vibrant_color',
        darkVibrantColor.toARGB32(),
      );
    }
    notifyListeners();
  }

  Future<void> updateLastPlaybackPosition(
    int positionMs, {
    int? durationMs,
  }) async {
    if (!_isInitialized) return;
    await _prefs.setInt('last_played_position_ms', positionMs);
    if (durationMs != null && durationMs > 0) {
      await _prefs.setInt('last_played_duration_ms', durationMs);
    }
  }

  Future<void> clearLastPlaybackSession() async {
    if (!_isInitialized) return;
    await _prefs.remove('last_played_song_json');
    await _prefs.remove('last_played_position_ms');
    await _prefs.remove('last_played_duration_ms');
    await _prefs.remove('last_played_playlist_json');
    await _prefs.remove('last_played_playlist_index');
    await _prefs.remove('last_played_dominant_color');
    await _prefs.remove('last_played_vibrant_color');
    await _prefs.remove('last_played_dark_vibrant_color');
    notifyListeners();
  }

  Set<String> _spotifyImportedPlaylistIds = {};
  Set<String> _manualCreatedPlaylistIds = {};

  Set<String> get spotifyImportedPlaylistIds =>
      Set.unmodifiable(_spotifyImportedPlaylistIds);
  Set<String> get manualCreatedPlaylistIds =>
      Set.unmodifiable(_manualCreatedPlaylistIds);

  bool isSpotifyImportedPlaylist(String id) =>
      _spotifyImportedPlaylistIds.contains(id);

  bool isManualCreatedPlaylist(String id) =>
      _manualCreatedPlaylistIds.contains(id);

  Future<void> registerSpotifyPlaylistId(String id) async {
    if (id.isEmpty) return;
    _spotifyImportedPlaylistIds.add(id);
    _manualCreatedPlaylistIds.remove(id);
    if (_isInitialized) {
      await _prefs.setStringList(
        'spotify_imported_playlist_ids',
        _spotifyImportedPlaylistIds.toList(),
      );
      await _prefs.setStringList(
        'manual_created_playlist_ids',
        _manualCreatedPlaylistIds.toList(),
      );
    }
    notifyListeners();
  }

  Future<void> unregisterSpotifyPlaylistId(String id) async {
    if (id.isEmpty) return;
    _spotifyImportedPlaylistIds.remove(id);
    if (_isInitialized) {
      await _prefs.setStringList(
        'spotify_imported_playlist_ids',
        _spotifyImportedPlaylistIds.toList(),
      );
    }
    notifyListeners();
  }

  Future<void> registerManualPlaylistId(String id) async {
    if (id.isEmpty) return;
    _manualCreatedPlaylistIds.add(id);
    _spotifyImportedPlaylistIds.remove(id);
    if (_isInitialized) {
      await _prefs.setStringList(
        'manual_created_playlist_ids',
        _manualCreatedPlaylistIds.toList(),
      );
      await _prefs.setStringList(
        'spotify_imported_playlist_ids',
        _spotifyImportedPlaylistIds.toList(),
      );
    }
    notifyListeners();
  }

  Future<void> unregisterManualPlaylistId(String id) async {
    if (id.isEmpty) return;
    _manualCreatedPlaylistIds.remove(id);
    if (_isInitialized) {
      await _prefs.setStringList(
        'manual_created_playlist_ids',
        _manualCreatedPlaylistIds.toList(),
      );
    }
    notifyListeners();
  }

  Future<void> toggleSpotifyPlaylistId(String id) async {
    if (_spotifyImportedPlaylistIds.contains(id)) {
      await unregisterSpotifyPlaylistId(id);
      await registerManualPlaylistId(id);
    } else {
      await unregisterManualPlaylistId(id);
      await registerSpotifyPlaylistId(id);
    }
  }

  @visibleForTesting
  void resetForTesting() {
    _isInitialized = false;
    _audioQuality = AudioQualityPreset.balanced;
    _audioFormat = AudioFormatPreference.auto;
    _realPlaybackCounts.clear();
    _artistPlayCounts.clear();
    _artistSkipCounts.clear();
    _listeningHistory.clear();
    _searchHistory.clear();
    _mostPlayedSongs.clear();
    _mostPlayedArtist = '';
    _topArtistPlayCount = 0;
    _profileImagePath = null;
    _spotifyImportedPlaylistIds.clear();
    _manualCreatedPlaylistIds.clear();
  }
}
