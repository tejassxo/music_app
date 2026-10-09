import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../layouts/desktop_layout_state.dart';
import '../services/music_service.dart';
import '../services/preferences_service.dart';
import '../services/canonical_song_dedup.dart';
import '../widgets/shimmer_loading.dart';
import '../widgets/song_options_bottom_sheet.dart';
import '../widgets/animated_equalizer.dart';
import '../widgets/bug_report_button.dart';
import 'profile_screen.dart';
import 'album_screen.dart';
import 'dilse_capsule_screen.dart';
import '../models/jio_album.dart';
import '../models/song_item.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with AutomaticKeepAliveClientMixin {
  final MusicService _musicService = MusicService();
  final PreferencesService _prefs = PreferencesService();

  @override
  bool get wantKeepAlive => true;

  List<Video> _topChartsIndia = [];
  List<Video> _trendingNow = [];
  List<Video> _newReleases = [];
  List<Video> _personalizedMixes = [];
  List<Video> _circadianMix = [];
  List<Video> _dailyMix1 = [];
  List<Video> _dailyMix2 = [];
  List<JioAlbum> _trendingAlbums = [];
  CircadianContext? _circadianContext;
  List<DailyMixConfig> _dailyMixConfigs = [];
  bool _isLoadingCharts = true;
  String? _loadingPlaylistId;

  int _selectedMoodIndex = 0;
  List<Video> _moodSongs = [];
  bool _isLoadingMood = false;
  final Map<int, List<Video>> _cachedMoodSongs = {};

  List<Map<String, String>> get _moods {
    final primaryLang = _prefs.preferredLanguages.isNotEmpty
        ? _prefs.preferredLanguages.first
        : 'Telugu';
    return [
      {
        'label': 'All Hits',
        'query': '$primaryLang Top Hits',
        'desc': 'All trending and personalized hits curated for you',
      },
      {
        'label': 'Energetic',
        'query': '$primaryLang Fast Hits',
        'desc': 'High-tempo power anthems to fuel your energy',
      },
      {
        'label': 'Chill & Relax',
        'query': '$primaryLang Melodies',
        'desc': 'Mellow acoustic melodies to unwind and relax',
      },
      {
        'label': 'Focus & Code',
        'query': 'Lofi Instrumental Chill Beats',
        'desc': 'Smooth non-distracting instrumental beats for flow state',
      },
      {
        'label': 'Workout',
        'query': '$primaryLang Mass Hits',
        'desc': 'Adrenaline-pumping tracks to power your training session',
      },
      {
        'label': 'Sleep',
        'query': '$primaryLang Slow Melodies',
        'desc': 'Peaceful, dreamy soundscapes for deep and restful sleep',
      },
      {
        'label': 'Party Hits',
        'query': '$primaryLang Party Hits',
        'desc': 'Dancefloor crowd-pleasers and club anthems',
      },
    ];
  }

  @override
  void initState() {
    super.initState();
    _prefs.addListener(_onPrefsChanged);
    _musicService.addListener(_onPrefsChanged);
    // Instant zero-wait display if background preload completed during splash
    if (_musicService.hasPreloadedHome &&
        _musicService.preloadedTopChartsIndia.isNotEmpty) {
      _topChartsIndia = List.from(_musicService.preloadedTopChartsIndia);
      _trendingNow = List.from(_musicService.preloadedTrending);
      _isLoadingCharts = false;
    }
    _loadHomeFeeds();
  }

  @override
  void dispose() {
    _musicService.removeListener(_onPrefsChanged);
    _prefs.removeListener(_onPrefsChanged);
    super.dispose();
  }

  void _onPrefsChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  String _getGreeting() {
    return _prefs.getTimeOfDayGreeting();
  }

  /// Fetches an optimized, pure JioSaavn Studio 320kbps catalog for Daily Mix.
  /// Strictly guarantees 100% official studio tracks, 0 YouTube video noise,
  /// 0 wedding/DJ noise, and 0 duplicate tracks.
  Future<List<Video>> _loadRichDailyMix(DailyMixConfig config) async {
    try {
      final jioMix = await _musicService.fetchJioDailyMix(config, limit: 35);
      if (jioMix.isNotEmpty) return jioMix;
      return await _musicService.searchSongs(config.query, limit: 35);
    } catch (_) {
      return await _musicService.searchSongs(config.query, limit: 35);
    }
  }

  Future<void> _loadHomeFeeds() async {
    _circadianContext = _prefs.getCircadianContext();
    _dailyMixConfigs = _prefs.getDailyMixConfigs();

    // 1. Silent Instant Cache Hydration (< 6 hours) with strict deduplication & noise filtering
    final cachedCircadian = CanonicalSongDedup.deduplicateList(
      _deserializeCachedVideos(
        _prefs.getCachedHomeFeed('circadian'),
      ).where((v) => CanonicalSongDedup.isGenuineSong(v)).toList(),
    );
    final cachedMix1 = CanonicalSongDedup.deduplicateList(
      _deserializeCachedVideos(
        _prefs.getCachedHomeFeed('daily_mix_1'),
      ).where((v) => CanonicalSongDedup.isGenuineSong(v)).toList(),
    );
    final cachedMix2 = CanonicalSongDedup.deduplicateList(
      _deserializeCachedVideos(
        _prefs.getCachedHomeFeed('daily_mix_2'),
      ).where((v) => CanonicalSongDedup.isGenuineSong(v)).toList(),
    );
    final cachedCharts = CanonicalSongDedup.deduplicateList(
      _deserializeCachedVideos(
        _prefs.getCachedHomeFeed('charts'),
      ).where((v) => CanonicalSongDedup.isGenuineSong(v)).toList(),
    );
    final cachedTrending = CanonicalSongDedup.deduplicateList(
      _deserializeCachedVideos(
        _prefs.getCachedHomeFeed('trending'),
      ).where((v) => CanonicalSongDedup.isGenuineSong(v)).toList(),
    );
    final cachedNewReleases = CanonicalSongDedup.deduplicateList(
      _deserializeCachedVideos(
        _prefs.getCachedHomeFeed('new_releases'),
      ).where((v) => CanonicalSongDedup.isGenuineSong(v)).toList(),
    );
    final cachedPersonalized = CanonicalSongDedup.deduplicateList(
      _deserializeCachedVideos(
        _prefs.getCachedHomeFeed('personalized'),
      ).where((v) => CanonicalSongDedup.isGenuineSong(v)).toList(),
    );
    final cachedAlbumsJson = _prefs.getCachedHomeFeed('albums');
    List<JioAlbum> cachedAlbums = [];
    if (cachedAlbumsJson != null && cachedAlbumsJson.isNotEmpty) {
      try {
        final decoded = json.decode(cachedAlbumsJson) as List<dynamic>;
        cachedAlbums = decoded
            .whereType<Map<String, dynamic>>()
            .map(JioAlbum.fromJson)
            .where((a) => a.id.isNotEmpty && a.title.isNotEmpty)
            .toList();
      } catch (_) {}
    }

    bool hadCache = false;
    if (cachedCircadian.isNotEmpty ||
        cachedMix1.isNotEmpty ||
        cachedCharts.isNotEmpty ||
        cachedAlbums.isNotEmpty) {
      hadCache = true;
      if (mounted) {
        setState(() {
          if (cachedCircadian.isNotEmpty) _circadianMix = cachedCircadian;
          if (cachedMix1.isNotEmpty) _dailyMix1 = cachedMix1;
          if (cachedMix2.isNotEmpty) _dailyMix2 = cachedMix2;
          if (cachedCharts.isNotEmpty) _topChartsIndia = cachedCharts;
          if (cachedTrending.isNotEmpty) _trendingNow = cachedTrending;
          if (cachedNewReleases.isNotEmpty) _newReleases = cachedNewReleases;
          if (cachedPersonalized.isNotEmpty) {
            _personalizedMixes = cachedPersonalized;
          }
          if (cachedAlbums.isNotEmpty) _trendingAlbums = cachedAlbums;
          _isLoadingCharts = false;
        });
      }
    }

    // 2. Background Refresh / Initial Load
    try {
      final primaryLang = _prefs.preferredLanguages.isNotEmpty
          ? _prefs.preferredLanguages.first
          : 'Telugu';
      final futureCircadian = _musicService.searchSongs(
        _circadianContext!.query,
      );
      final futureMix1 = _loadRichDailyMix(_dailyMixConfigs[0]);
      final futureMix2 = _loadRichDailyMix(_dailyMixConfigs[1]);
      final futureCharts =
          _musicService.hasPreloadedHome &&
              _musicService.preloadedTopChartsIndia.isNotEmpty
          ? Future.value(_musicService.preloadedTopChartsIndia)
          : _musicService.searchSongs('$primaryLang Top Hits');
      final futureTrending =
          _musicService.hasPreloadedHome &&
              _musicService.preloadedTrending.isNotEmpty
          ? Future.value(_musicService.preloadedTrending)
          : _musicService.searchSongs('$primaryLang Trending');
      final futureNewReleases = _musicService.searchSongs(
        '$primaryLang Latest Songs',
      );
      final futurePersonalized = _dailyMixConfigs.length > 2
          ? _loadRichDailyMix(_dailyMixConfigs[2])
          : _musicService.searchSongs('$primaryLang Mix');
      final futureAlbums = _musicService.searchAlbums(
        '$primaryLang Soundtracks',
        limit: 12,
      );

      final results = await Future.wait<dynamic>([
        futureCircadian,
        futureMix1,
        futureMix2,
        futureCharts,
        futureTrending,
        futureNewReleases,
        futurePersonalized,
        futureAlbums,
      ]);

      final circadian = CanonicalSongDedup.deduplicateList(
        results[0] as List<Video>,
      );
      final mix1 = CanonicalSongDedup.deduplicateList(
        results[1] as List<Video>,
      );
      final mix2 = CanonicalSongDedup.deduplicateList(
        results[2] as List<Video>,
      );
      final charts = CanonicalSongDedup.deduplicateList(
        results[3] as List<Video>,
      );
      final trending = CanonicalSongDedup.deduplicateList(
        results[4] as List<Video>,
      );
      final newReleases = CanonicalSongDedup.deduplicateList(
        results[5] as List<Video>,
      );
      final personalized = CanonicalSongDedup.deduplicateList(
        results[6] as List<Video>,
      );
      var albums = (results[7] as List<dynamic>).whereType<JioAlbum>().toList();
      if (albums.length < 3) {
        final fallbackAlbums = await _musicService.searchAlbums(
          primaryLang,
          limit: 12,
        );
        if (fallbackAlbums.isNotEmpty) {
          albums = fallbackAlbums;
        }
      }

      _prefs.cacheHomeFeed('circadian', _serializeVideos(circadian));
      _prefs.cacheHomeFeed('daily_mix_1', _serializeVideos(mix1));
      _prefs.cacheHomeFeed('daily_mix_2', _serializeVideos(mix2));
      _prefs.cacheHomeFeed('charts', _serializeVideos(charts));
      _prefs.cacheHomeFeed('trending', _serializeVideos(trending));
      _prefs.cacheHomeFeed('new_releases', _serializeVideos(newReleases));
      _prefs.cacheHomeFeed('personalized', _serializeVideos(personalized));
      if (albums.isNotEmpty) {
        _prefs.cacheHomeFeed(
          'albums',
          json.encode(albums.map((a) => a.toJson()).toList()),
        );
      }

      if (mounted) {
        setState(() {
          _circadianMix = circadian;
          _dailyMix1 = mix1;
          _dailyMix2 = mix2;
          _topChartsIndia = charts;
          _trendingNow = trending;
          _newReleases = newReleases;
          _personalizedMixes = personalized;
          if (albums.isNotEmpty) _trendingAlbums = albums;
          _isLoadingCharts = false;
        });
      }
    } catch (e) {
      if (mounted && !hadCache) {
        setState(() {
          _isLoadingCharts = false;
        });
      }
    }
  }

  String _serializeVideos(List<Video> videos) {
    final list = videos
        .map(
          (v) => {
            'id': v.id.value,
            'title': v.title,
            'author': v.author,
            'durationMs': v.duration?.inMilliseconds ?? 0,
            'streamUrl': MusicService.getCachedWebStreamUrl(v.id.value) ?? '',
            'thumbnail': MusicService.getHdThumbnail(v.id.value),
          },
        )
        .toList();
    return json.encode(list);
  }

  List<Video> _deserializeCachedVideos(String? jsonStr) {
    if (jsonStr == null || jsonStr.isEmpty) return [];
    try {
      final List<dynamic> list = json.decode(jsonStr);
      return list.map((m) {
        final id = m['id'] as String;
        final streamUrl = m['streamUrl'] as String?;
        if (streamUrl != null && streamUrl.isNotEmpty) {
          MusicService.cacheWebStreamUrl(id, streamUrl);
        }
        return Video(
          VideoId(id),
          m['title'] as String,
          m['author'] as String,
          ChannelId('UC0WP5P-fwGlLyO4yOE76T8g'),
          DateTime.now(),
          '',
          null,
          '',
          Duration(milliseconds: (m['durationMs'] as num?)?.toInt() ?? 0),
          ThumbnailSet(id),
          null,
          Engagement(0, null, null),
          false,
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _onMoodSelected(int index) async {
    if (_selectedMoodIndex == index) return;
    HapticFeedback.lightImpact();
    setState(() {
      _selectedMoodIndex = index;
    });

    if (index == 0) return;

    // Instant zero-wait cache response if previously loaded
    if (_cachedMoodSongs.containsKey(index) &&
        _cachedMoodSongs[index]!.isNotEmpty) {
      setState(() {
        _moodSongs = _cachedMoodSongs[index]!;
        _isLoadingMood = false;
      });
      return;
    }

    setState(() {
      _isLoadingMood = true;
    });

    try {
      final rawSongs = await _musicService.searchSongs(_moods[index]['query']!);
      // Filter out long mixes (>10 min) and short clips (<45s) to guarantee real songs
      final songs = rawSongs.where((v) {
        if (v.duration == null) return true;
        return v.duration!.inSeconds >= 45 && v.duration!.inMinutes <= 10;
      }).toList();

      if (mounted && _selectedMoodIndex == index) {
        _cachedMoodSongs[index] = songs;
        setState(() {
          _moodSongs = songs;
          _isLoadingMood = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLoadingMood = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return Scaffold(
      backgroundColor: const Color(0xFF0B0B0F),
      body: SafeArea(
        bottom: false,
        child: CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            // Personalized Top Greeting & Avatar
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(
                  left: 20,
                  right: 20,
                  top: 18,
                  bottom: 12,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${_getGreeting().toUpperCase()},',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.5),
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.2,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            _prefs.userName,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 26,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.6,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    if (!kIsWeb || MediaQuery.of(context).size.width < 1024)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            icon: Container(
                              padding: const EdgeInsets.all(7),
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [
                                    Color(0xFFE040FB),
                                    Color(0xFF1DB954),
                                  ],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(
                                      0xFFE040FB,
                                    ).withValues(alpha: 0.35),
                                    blurRadius: 8,
                                  ),
                                ],
                              ),
                              child: const Icon(
                                Icons.auto_awesome_rounded,
                                color: Colors.white,
                                size: 16,
                              ),
                            ),
                            tooltip: 'DilSe Capsule',
                            onPressed: () {
                              HapticFeedback.mediumImpact();
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) =>
                                      const DilSeCapsuleScreen(),
                                ),
                              );
                            },
                          ),
                          const SizedBox(width: 8),
                          const BugReportButton(),
                          const SizedBox(width: 8),
                          GestureDetector(
                            onTap: () {
                              HapticFeedback.lightImpact();
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => const ProfileScreen(),
                                ),
                              );
                            },
                            child: Container(
                              padding: const EdgeInsets.all(2.5),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.18),
                                  width: 1.5,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.35),
                                    blurRadius: 10,
                                  ),
                                ],
                              ),
                              child: const CircleAvatar(
                                backgroundColor: Color(0xFF1E1E28),
                                radius: 20,
                                child: Icon(
                                  Icons.person_rounded,
                                  color: Colors.white,
                                  size: 22,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),

            // Smart Playback Quick Resume Banner
            _buildQuickResumeBanner(),

            // Horizontal Mood & Activity Filter Chips
            SliverToBoxAdapter(
              child: SizedBox(
                height: 46,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _moods.length,
                  itemBuilder: (context, index) {
                    final isSelected = _selectedMoodIndex == index;

                    return GestureDetector(
                      onTap: () => _onMoodSelected(index),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 240),
                        margin: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 4,
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? Colors.white.withValues(alpha: 0.16)
                              : const Color(0xFF161622),
                          borderRadius: BorderRadius.circular(100),
                          border: Border.all(
                            color: isSelected
                                ? Colors.white.withValues(alpha: 0.30)
                                : Colors.white.withValues(alpha: 0.08),
                            width: 1,
                          ),
                          boxShadow: isSelected
                              ? [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.25),
                                    blurRadius: 8,
                                    offset: const Offset(0, 2),
                                  ),
                                ]
                              : null,
                        ),
                        child: Center(
                          child: Text(
                            _moods[index]['label']!,
                            style: TextStyle(
                              color: isSelected
                                  ? Colors.white
                                  : Colors.white.withValues(alpha: 0.75),
                              fontSize: 13,
                              fontWeight: isSelected
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),

            const SliverToBoxAdapter(child: SizedBox(height: 12)),

            // Loading state with Shimmer Skeletons
            if (_isLoadingCharts)
              const SliverToBoxAdapter(
                child: Column(
                  children: [
                    ShimmerBillboard(),
                    SizedBox(height: 20),
                    ShimmerCardRow(),
                    SizedBox(height: 20),
                    ShimmerSongRow(),
                  ],
                ),
              )
            else
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 160),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Dedicated Vibe Radio Hub vs Default Full Home Feed
                      if (_selectedMoodIndex != 0)
                        _buildVibeRadioView(_selectedMoodIndex)
                      else ...[
                        // Circadian Time-of-Day Contextual Shelf
                        if (_circadianMix.isNotEmpty &&
                            _circadianContext != null) ...[
                          _buildSectionHeader(
                            _circadianContext!.title.toUpperCase(),
                            _circadianContext!.subtitle,
                          ),
                          _buildHorizontalChartCards(_circadianMix),
                          const SizedBox(height: 24),
                        ],

                        // Multi-Seed Daily Mix 1 (Top Artist & Friends - Multi-Row Sliding List)
                        if (_dailyMix1.isNotEmpty &&
                            _dailyMixConfigs.isNotEmpty) ...[
                          _buildSectionHeader(
                            _dailyMixConfigs[0].title.toUpperCase(),
                            _dailyMixConfigs[0].subtitle,
                          ),
                          _buildSlidingSongGrid(_dailyMix1),
                          const SizedBox(height: 24),
                        ],

                        // BLOCKBUSTER SOUNDTRACKS & ALBUMS
                        if (_trendingAlbums.isNotEmpty) ...[
                          _buildAlbumsSection(),
                          const SizedBox(height: 24),
                        ],

                        // Multi-Seed Daily Mix 2 (Top Artist Melodies - Multi-Row Sliding List)
                        if (_dailyMix2.isNotEmpty &&
                            _dailyMixConfigs.length > 1) ...[
                          _buildSectionHeader(
                            _dailyMixConfigs[1].title.toUpperCase(),
                            _dailyMixConfigs[1].subtitle,
                          ),
                          _buildSlidingSongGrid(_dailyMix2),
                          const SizedBox(height: 24),
                        ],

                        // FEATURED PLAYLISTS & TRENDS (Spotify-Style Curated Mixes)
                        _buildSectionHeader(
                          'FEATURED PLAYLISTS',
                          'Trending & Curated Mixes',
                        ),
                        _buildCuratedPlaylistsSection(),
                        const SizedBox(height: 24),

                        // TOP CHARTS: INDIA
                        _buildSectionHeader(
                          'TOP CHARTS: INDIA',
                          'Updated Daily',
                        ),
                        _buildHorizontalChartCards(_topChartsIndia),
                        const SizedBox(height: 24),

                        // MADE FOR YOU (Daily Mix Style Multi-Row Sliding Grid)
                        if (_personalizedMixes.isNotEmpty) ...[
                          _buildSectionHeader(
                            'MADE FOR YOU',
                            'Curated Mix for your taste',
                          ),
                          _buildSlidingSongGrid(_personalizedMixes),
                          const SizedBox(height: 24),
                        ],

                        // NEW RELEASES
                        _buildSectionHeader('NEW RELEASES', 'Fresh Music'),
                        _buildHorizontalChartCards(_newReleases),
                        const SizedBox(height: 24),

                        // TRENDING NOW
                        _buildSectionHeader('TRENDING NOW', 'Global Pick'),
                        _buildHorizontalChartCards(_trendingNow),
                        const SizedBox(height: 24),

                        // YOUR FAVORITES
                        if (_musicService.likedSongs.isNotEmpty) ...[
                          _buildSectionHeader('YOUR FAVORITES', 'Liked Tracks'),
                          _buildLikedSongsList(),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickResumeBanner() {
    final songMap = _prefs.lastPlayedSong;
    if (songMap == null || _musicService.currentSong != null) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }

    final title = (songMap['title'] as String?) ?? 'Last Played';
    final author = (songMap['author'] as String?) ?? 'Unknown Artist';
    final thumbnail = (songMap['thumbnail'] as String?) ?? '';
    final posMs = _prefs.lastPlayedPositionMs;
    final durMs = _prefs.lastPlayedDurationMs;
    final progress = (durMs > 0) ? (posMs / durMs).clamp(0.0, 1.0) : 0.0;

    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                const Color(0xFF1E1E2C).withValues(alpha: 0.95),
                const Color(0xFF13131E).withValues(alpha: 0.95),
              ],
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.10),
              width: 1.0,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 14,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () {
                HapticFeedback.mediumImpact();
                _musicService.resumeLastPlaybackSession();
              },
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: thumbnail.isNotEmpty
                              ? Image.network(
                                  thumbnail,
                                  width: 48,
                                  height: 48,
                                  fit: BoxFit.cover,
                                  cacheWidth: 120,
                                  cacheHeight: 120,
                                  errorBuilder: (_, _, _) => Container(
                                    width: 48,
                                    height: 48,
                                    color: const Color(0xFF262636),
                                    child: const Icon(
                                      Icons.music_note,
                                      color: Colors.white54,
                                    ),
                                  ),
                                )
                              : Container(
                                  width: 48,
                                  height: 48,
                                  color: const Color(0xFF262636),
                                  child: const Icon(
                                    Icons.music_note,
                                    color: Colors.white54,
                                  ),
                                ),
                        ),
                        if (progress > 0)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: ClipRRect(
                              borderRadius: const BorderRadius.only(
                                bottomLeft: Radius.circular(10),
                                bottomRight: Radius.circular(10),
                              ),
                              child: LinearProgressIndicator(
                                value: progress,
                                minHeight: 3,
                                backgroundColor: Colors.black45,
                                valueColor: const AlwaysStoppedAnimation<Color>(
                                  Color(0xFFFA2D48),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.history_rounded,
                                size: 13,
                                color: Colors.white.withValues(alpha: 0.5),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                'JUMP BACK IN',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.5),
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 1.0,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            author,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.65),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.play_circle_fill_rounded,
                        color: Colors.white,
                        size: 36,
                      ),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 40,
                        minHeight: 40,
                      ),
                      onPressed: () {
                        HapticFeedback.mediumImpact();
                        _musicService.resumeLastPlaybackSession();
                      },
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.close_rounded,
                        color: Colors.white38,
                        size: 18,
                      ),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      onPressed: () {
                        HapticFeedback.lightImpact();
                        _prefs.clearLastPlaybackSession();
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVibeRadioView(int moodIndex) {
    final mood = _moods[moodIndex];
    final label = mood['label'] ?? '';
    final desc = mood['desc'] ?? 'Curated for this vibe';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Vibe Hero Card
        Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(horizontal: 16),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFF161622),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.12),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 18,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white12,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text(
                      'VIBE RADIO',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.0,
                      ),
                    ),
                  ),
                  const Spacer(),
                  if (!_isLoadingMood && _moodSongs.isNotEmpty)
                    Text(
                      '${_moodSongs.length} Tracks',
                      style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                desc,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 13.5,
                ),
              ),
              const SizedBox(height: 18),
              if (!_isLoadingMood && _moodSongs.isNotEmpty)
                Row(
                  children: [
                    ElevatedButton.icon(
                      icon: const Icon(Icons.play_arrow_rounded, size: 22),
                      label: const Text(
                        'Play Vibe Radio',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 11,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        elevation: 0,
                      ),
                      onPressed: () {
                        HapticFeedback.lightImpact();
                        _musicService.playPlaylist(_moodSongs, 0);
                      },
                    ),
                    const SizedBox(width: 10),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.shuffle_rounded, size: 18),
                      label: const Text(
                        'Shuffle',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: BorderSide(
                          color: Colors.white.withValues(alpha: 0.25),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 11,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: () {
                        HapticFeedback.lightImpact();
                        final shuffled = List<Video>.from(_moodSongs)
                          ..shuffle();
                        _musicService.playPlaylist(shuffled, 0);
                      },
                    ),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: 24),

        if (_isLoadingMood) ...[
          const ShimmerCardRow(),
          const SizedBox(height: 20),
          const ShimmerSongRow(),
        ] else if (_moodSongs.isEmpty) ...[
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Column(
                children: [
                  const Icon(
                    Icons.music_off_rounded,
                    size: 48,
                    color: Colors.white38,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'No tracks found for $label',
                    style: const TextStyle(color: Colors.white70, fontSize: 15),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => _onMoodSelected(0),
                    child: const Text('Return to All Hits'),
                  ),
                ],
              ),
            ),
          ),
        ] else ...[
          _buildSectionHeader('HIGHLIGHTS', 'Top Picks for $label'),
          _buildHorizontalChartCards(_moodSongs),
          const SizedBox(height: 22),
          _buildSectionHeader('VIBE TRACKLIST', '${_moodSongs.length} Songs'),
          _buildVerticalSongList(_moodSongs, isVibe: true),
        ],
      ],
    );
  }

  Widget _buildAlbumsSection() {
    if (_trendingAlbums.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(
          'BLOCKBUSTER SOUNDTRACKS',
          'Full Movie & Studio Albums',
        ),
        SizedBox(
          height: 220,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            itemCount: _trendingAlbums.length,
            itemBuilder: (context, index) {
              final album = _trendingAlbums[index];
              final isSingle = album.songCount <= 1;

              return GestureDetector(
                onTap: () {
                  HapticFeedback.lightImpact();
                  if (kIsWeb && MediaQuery.of(context).size.width >= 1024) {
                    DesktopLayoutState.openAlbum(
                      album: album,
                      albumId: album.id,
                      albumTitle: album.title,
                      albumArtwork: album.artwork,
                      albumArtist: album.artist,
                    );
                  } else {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => AlbumScreen(
                          album: album,
                          albumId: album.id,
                          albumTitle: album.title,
                          albumArtwork: album.artwork,
                          albumArtist: album.artist,
                        ),
                      ),
                    );
                  }
                },
                child: Container(
                  width: 152,
                  margin: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 152,
                        height: 152,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.45),
                              blurRadius: 12,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              if (album.artwork.isNotEmpty)
                                Image.network(
                                  album.artwork,
                                  fit: BoxFit.cover,
                                  cacheWidth: 320,
                                  cacheHeight: 320,
                                  errorBuilder: (_, _, _) =>
                                      _buildAlbumFallbackCover(album),
                                )
                              else
                                _buildAlbumFallbackCover(album),
                              // Song count pill badge
                              Positioned(
                                top: 8,
                                right: 8,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.75),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: isSingle
                                          ? Colors.white24
                                          : const Color(
                                              0xFF7C3AED,
                                            ).withValues(alpha: 0.6),
                                      width: 1,
                                    ),
                                  ),
                                  child: Text(
                                    isSingle
                                        ? 'Single'
                                        : '${album.songCount} Songs',
                                    style: TextStyle(
                                      color: isSingle
                                          ? Colors.white70
                                          : const Color(0xFFA78BFA),
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.2,
                                    ),
                                  ),
                                ),
                              ),
                              // Vinyl disc icon overlay
                              Positioned(
                                bottom: 8,
                                right: 8,
                                child: Container(
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).primaryColor,
                                    shape: BoxShape.circle,
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withValues(
                                          alpha: 0.4,
                                        ),
                                        blurRadius: 6,
                                      ),
                                    ],
                                  ),
                                  child: const Icon(
                                    Icons.album_rounded,
                                    color: Colors.black,
                                    size: 16,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        album.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        album.artist.isNotEmpty
                            ? album.artist
                            : (album.year.isNotEmpty
                                  ? album.year
                                  : 'Soundtrack'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.55),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildAlbumFallbackCover(JioAlbum album) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF1F1B2C), Color(0xFF120E1E)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.album_rounded, color: Color(0xFFA78BFA), size: 40),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                album.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18.0, vertical: 6.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            subtitle.toUpperCase(),
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45),
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHorizontalChartCards(List<Video> videos) {
    if (videos.isEmpty) return const SizedBox.shrink();

    return SizedBox(
      height: 215,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        itemCount: videos.length,
        itemBuilder: (context, index) {
          final song = videos[index];
          final hdThumbnail = MusicService.getHdThumbnail(song.id.value);

          return GestureDetector(
            onTap: () {
              HapticFeedback.lightImpact();
              _musicService.playPlaylist(videos, index);
            },
            child: Container(
              width: 152,
              margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 152,
                    height: 152,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.4),
                          blurRadius: 12,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.network(
                            hdThumbnail,
                            fit: BoxFit.cover,
                            cacheWidth: 320,
                            cacheHeight: 320,
                            errorBuilder: (_, _, _) => Image.network(
                              song.thumbnails.highResUrl,
                              fit: BoxFit.cover,
                              cacheWidth: 320,
                              cacheHeight: 320,
                            ),
                          ),
                          Positioned(
                            bottom: 8,
                            right: 8,
                            child: Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.6),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.2),
                                  width: 1,
                                ),
                              ),
                              child: const Icon(
                                Icons.play_arrow_rounded,
                                color: Colors.white,
                                size: 20,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    song.author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Multi-Row Sliding List for Daily Mixes:
  /// Arranges songs into horizontal columns where each column has 4 songs (4 rows),
  /// sliding smoothly horizontally to showcase large collections (40-50+ tracks) neatly.
  Widget _buildSlidingSongGrid(List<Video> videos) {
    if (videos.isEmpty) return const SizedBox.shrink();

    const int rowsPerColumn = 4;
    final int columnCount = (videos.length / rowsPerColumn).ceil();
    final currentSongId = _musicService.currentSong?.id.value;
    final isPlaying = _musicService.isPlaying;

    return SizedBox(
      height: 236,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        itemCount: columnCount,
        itemBuilder: (context, colIndex) {
          final startIndex = colIndex * rowsPerColumn;
          final endIndex = (startIndex + rowsPerColumn).clamp(0, videos.length);
          final columnVideos = videos.sublist(startIndex, endIndex);
          final screenWidth = MediaQuery.of(context).size.width;
          final columnWidth = (screenWidth * 0.84).clamp(300.0, 360.0);

          return Container(
            width: columnWidth,
            margin: const EdgeInsets.symmetric(horizontal: 5),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: List.generate(columnVideos.length, (rowIdx) {
                final globalIndex = startIndex + rowIdx;
                final song = columnVideos[rowIdx];
                final isCurrent = currentSongId == song.id.value;
                final hdThumbnail = MusicService.getHdThumbnail(song.id.value);

                return Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () {
                      HapticFeedback.lightImpact();
                      _musicService.playPlaylist(videos, globalIndex);
                    },
                    onLongPress: () {
                      HapticFeedback.mediumImpact();
                      showSongOptionsBottomSheet(context, song);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 5,
                      ),
                      child: Row(
                        children: [
                          // 44x44 Album Artwork
                          ClipRRect(
                            borderRadius: BorderRadius.circular(9),
                            child: SizedBox(
                              width: 44,
                              height: 44,
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  Image.network(
                                    hdThumbnail,
                                    fit: BoxFit.cover,
                                    cacheWidth: 120,
                                    cacheHeight: 120,
                                    errorBuilder: (_, _, _) => Image.network(
                                      song.thumbnails.lowResUrl,
                                      fit: BoxFit.cover,
                                      cacheWidth: 120,
                                      cacheHeight: 120,
                                    ),
                                  ),
                                  if (isCurrent)
                                    Container(
                                      color: Colors.black54,
                                      child: Center(
                                        child: AnimatedEqualizer(
                                          isPlaying: isPlaying,
                                          size: 20,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          // Title & Artist
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  song.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontWeight: isCurrent
                                        ? FontWeight.w700
                                        : FontWeight.w600,
                                    fontSize: 13.5,
                                    letterSpacing: -0.2,
                                    color: isCurrent
                                        ? Colors.white
                                        : Colors.white.withValues(alpha: 0.92),
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  song.author,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.white.withValues(alpha: 0.55),
                                    fontWeight: FontWeight.w400,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          // Subtle translucent play button
                          IconButton(
                            icon: Icon(
                              isCurrent && isPlaying
                                  ? Icons.pause_circle_filled_rounded
                                  : Icons.play_circle_outline_rounded,
                              color: isCurrent ? Colors.white : Colors.white38,
                              size: 22,
                            ),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 32,
                              minHeight: 32,
                            ),
                            onPressed: () {
                              HapticFeedback.lightImpact();
                              if (isCurrent) {
                                _musicService.togglePlayPause();
                              } else {
                                _musicService.playPlaylist(videos, globalIndex);
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ),
          );
        },
      ),
    );
  }

  Widget _buildVerticalSongList(List<Video> videos, {bool isVibe = false}) {
    if (videos.isEmpty) return const SizedBox.shrink();

    final displayList = (!isVibe && videos.length > 6)
        ? videos.sublist(0, 6)
        : videos;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: displayList.asMap().entries.map((entry) {
          final index = entry.key;
          final song = entry.value;
          final hdThumbnail = MusicService.getHdThumbnail(song.id.value);

          return Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF14141D),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.05),
                width: 1,
              ),
            ),
            child: Material(
              color: Colors.transparent,
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 2,
                ),
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.network(
                    hdThumbnail,
                    width: 50,
                    height: 50,
                    fit: BoxFit.cover,
                    cacheWidth: 120,
                    cacheHeight: 120,
                    errorBuilder: (_, _, _) => Image.network(
                      song.thumbnails.lowResUrl,
                      width: 50,
                      height: 50,
                      fit: BoxFit.cover,
                      cacheWidth: 120,
                      cacheHeight: 120,
                    ),
                  ),
                ),
                title: Text(
                  song.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    letterSpacing: -0.2,
                  ),
                ),
                subtitle: Text(
                  song.author,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 12,
                  ),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(
                        Icons.more_vert_rounded,
                        color: Colors.white38,
                        size: 20,
                      ),
                      onPressed: () {
                        showSongOptionsBottomSheet(context, song);
                      },
                    ),
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.10),
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child:
                            (_musicService.currentSong?.id.value ==
                                    song.id.value &&
                                _musicService.isPlaying)
                            ? const AnimatedEqualizer(isPlaying: true, size: 16)
                            : const Icon(
                                Icons.play_arrow_rounded,
                                color: Colors.white,
                                size: 22,
                              ),
                      ),
                    ),
                  ],
                ),
                onTap: () {
                  HapticFeedback.lightImpact();
                  _musicService.playPlaylist(displayList, index);
                },
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildLikedSongsList() {
    final liked = _musicService.likedSongs;
    final displayList = liked.length > 5 ? liked.sublist(0, 5) : liked;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: displayList.map((song) {
          return Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF14141D),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.05),
                width: 1,
              ),
            ),
            child: Material(
              color: Colors.transparent,
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 2,
                ),
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.network(
                    song['thumbnail'] ??
                        MusicService.getHdThumbnail(song['id'] ?? ''),
                    width: 50,
                    height: 50,
                    fit: BoxFit.cover,
                    cacheWidth: 120,
                    cacheHeight: 120,
                    errorBuilder: (context, error, stackTrace) => Container(
                      width: 50,
                      height: 50,
                      color: Colors.white10,
                      child: const Icon(
                        Icons.music_note_rounded,
                        color: Colors.white38,
                      ),
                    ),
                  ),
                ),
                title: Text(
                  song['title'] ?? 'Unknown Track',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    letterSpacing: -0.2,
                  ),
                ),
                subtitle: Text(
                  song['author'] ?? 'Unknown Artist',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 12,
                  ),
                ),
                trailing: const Icon(
                  Icons.favorite_rounded,
                  color: Color(0xFFFA2D48),
                  size: 22,
                ),
                onTap: () {
                  HapticFeedback.lightImpact();
                  final songId = song['id'] ?? '';
                  if (songId.isEmpty) return;
                  final video = SongItem.fromJson(song).toVideo();
                  _musicService.playSong(video);
                },
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  List<CuratedPlaylist> _getCuratedPlaylists() {
    final artist = _prefs.mostPlayedArtist.isNotEmpty
        ? _prefs.mostPlayedArtist
        : 'Top Artists';
    return [
      const CuratedPlaylist(
        id: 'global_top_50',
        title: 'Top 50 - Global',
        subtitle: 'The hottest chartbusters worldwide',
        query: 'Global Top Hits',
        gradientColors: [Color(0xFF6B11FF), Color(0xFF2B0A80)],
        icon: Icons.public_rounded,
        tag: 'GLOBAL TRENDS',
      ),
      const CuratedPlaylist(
        id: 'trending_telugu',
        title: 'Trending Telugu',
        subtitle: 'Tollywood viral hits & chartbusters',
        query: 'Telugu Top Hits',
        gradientColors: [Color(0xFFFF3366), Color(0xFF990033)],
        icon: Icons.trending_up_rounded,
        tag: 'REGIONAL HITS',
      ),
      const CuratedPlaylist(
        id: 'bollywood_romance',
        title: 'Bollywood Romance',
        subtitle: 'Heartfelt melodies with Arijit & Pritam',
        query: 'Hindi Romantic Hits',
        gradientColors: [Color(0xFFFF5E3A), Color(0xFFFF2A68)],
        icon: Icons.favorite_rounded,
        tag: 'ROMANCE',
      ),
      const CuratedPlaylist(
        id: '90s_nostalgia',
        title: '90s Nostalgia Rewind',
        subtitle: 'Golden evergreen classics & melodies',
        query: 'Hindi 90s Classics',
        gradientColors: [Color(0xFF00B4DB), Color(0xFF0083B0)],
        icon: Icons.history_rounded,
        tag: 'RETRO CLASSICS',
      ),
      const CuratedPlaylist(
        id: 'telugu_2000s',
        title: 'Telugu 2000s Golden Era',
        subtitle: 'DSP, Harris Jayaraj & Mani Sharma hits',
        query: 'Telugu 2000s Hits',
        gradientColors: [Color(0xFFF7971E), Color(0xFFFF7000)],
        icon: Icons.album_rounded,
        tag: 'GOLDEN ERA',
      ),
      const CuratedPlaylist(
        id: 'acoustic_chill',
        title: 'Acoustic & Coffee Chill',
        subtitle: 'Soothing acoustic indie melodies',
        query: 'Acoustic Pop Melodies',
        gradientColors: [Color(0xFF11998E), Color(0xFF38EF7D)],
        icon: Icons.coffee_rounded,
        tag: 'CHILL MIX',
      ),
      CuratedPlaylist(
        id: 'daily_mix_1',
        title: 'Daily Mix 1',
        subtitle: 'Personalized mix featuring $artist',
        query: artist,
        gradientColors: const [Color(0xFF8E2DE2), Color(0xFF4A00E0)],
        icon: Icons.auto_awesome_rounded,
        tag: 'MADE FOR YOU',
      ),
    ];
  }

  Widget _buildCuratedPlaylistsSection() {
    final playlists = _getCuratedPlaylists();
    return SizedBox(
      height: 195,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        itemCount: playlists.length,
        itemBuilder: (context, index) {
          final p = playlists[index];
          final isLoading = _loadingPlaylistId == p.id;

          return GestureDetector(
            onTap: () => _playCuratedPlaylist(p),
            child: Container(
              width: 190,
              margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF161622),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.10),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 12,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Flexible(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3.5,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.25),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            p.tag,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.8,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Icon(
                        p.icon,
                        color: Colors.white.withValues(alpha: 0.85),
                        size: 22,
                      ),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.3,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        p.subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.8),
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          height: 1.25,
                        ),
                      ),
                    ],
                  ),
                  Align(
                    alignment: Alignment.bottomRight,
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black38,
                            blurRadius: 8,
                            offset: Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Center(
                        child: isLoading
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.2,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    Colors.black,
                                  ),
                                ),
                              )
                            : const Icon(
                                Icons.play_arrow_rounded,
                                color: Colors.black,
                                size: 24,
                              ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _playCuratedPlaylist(CuratedPlaylist playlist) async {
    if (_loadingPlaylistId != null) return;
    HapticFeedback.lightImpact();
    setState(() {
      _loadingPlaylistId = playlist.id;
    });

    try {
      final tracks = await _musicService.searchSongs(playlist.query);
      if (!mounted) return;
      if (tracks.isNotEmpty) {
        await _musicService.playPlaylist(tracks, 0);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Playing ${playlist.title} (${tracks.length} tracks)',
            ),
            duration: const Duration(seconds: 2),
            backgroundColor: const Color(0xFF1E1E28),
          ),
        );
      }
    } catch (e) {
      debugPrint('Error playing curated playlist: $e');
    } finally {
      if (mounted) {
        setState(() {
          _loadingPlaylistId = null;
        });
      }
    }
  }
}

class CuratedPlaylist {
  final String id;
  final String title;
  final String subtitle;
  final String query;
  final List<Color> gradientColors;
  final IconData icon;
  final String tag;

  const CuratedPlaylist({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.query,
    required this.gradientColors,
    required this.icon,
    required this.tag,
  });
}
