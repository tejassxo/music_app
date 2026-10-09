import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../services/music_service.dart';
import '../services/dynamic_artist_service.dart';
import '../services/canonical_song_dedup.dart';
import '../services/preferences_service.dart';
import '../widgets/responsive_wrapper.dart';
import '../widgets/animated_equalizer.dart';
import '../widgets/song_options_bottom_sheet.dart';
import '../widgets/shimmer_loading.dart';
import '../widgets/mini_player.dart';
import '../widgets/dilse_scrollbar.dart';
import '../layouts/desktop_layout_state.dart';

/// Dedicated Artist Profile & Discography Screen with deep multi-language,
/// movie range, and filmography filters.
class ArtistProfileScreen extends StatefulWidget {
  final ArtistItem? artist;
  final String artistName;

  const ArtistProfileScreen({super.key, this.artist, required this.artistName});

  @override
  State<ArtistProfileScreen> createState() => _ArtistProfileScreenState();
}

class _ArtistProfileScreenState extends State<ArtistProfileScreen> {
  final MusicService _musicService = MusicService();
  final DynamicArtistService _artistService = DynamicArtistService();
  final PreferencesService _prefs = PreferencesService();
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();

  late final String _canonicalName;
  late final ArtistItem? _artistItem;
  late final List<String> _languages;
  late final List<String> _filmography;
  late final String _bioText;

  final List<String> _eraOptions = const [
    'All Eras',
    '2020–2025',
    '2010–2019',
    '2000–2009',
    'Classics',
  ];

  List<Video> _allSongs = [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  int _currentPage = 1;

  // Active Filter State
  String _selectedLanguage = 'All';
  String? _selectedMovie;
  String _selectedEra = 'All Eras';
  String _inArtistQuery = '';

  @override
  void initState() {
    super.initState();
    final matched = _artistService.findArtist(widget.artistName);
    _artistItem = widget.artist ?? matched;
    _canonicalName = _artistItem?.name ?? widget.artistName.trim();

    _languages = ['All', ..._artistService.getArtistLanguages(_canonicalName)];
    _filmography = _artistService.getFilmography(_canonicalName);
    _bioText = _artistService.getArtistBio(_canonicalName);

    _searchController.addListener(() {
      setState(() {
        _inArtistQuery = _searchController.text.trim().toLowerCase();
      });
    });

    _scrollController.addListener(_onScroll);
    _musicService.addListener(_onMusicServiceChanged);
    _prefs.addListener(_onPrefsChanged);

    _loadInitialDiscography();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    _musicService.removeListener(_onMusicServiceChanged);
    _prefs.removeListener(_onPrefsChanged);
    super.dispose();
  }

  void _onMusicServiceChanged() {
    if (mounted) setState(() {});
  }

  void _onPrefsChanged() {
    if (mounted) setState(() {});
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 250) {
      _loadMoreDiscography();
    }
  }

  Future<void> _loadInitialDiscography() async {
    setState(() {
      _isLoading = true;
      _currentPage = 1;
      _hasMore = true;
    });

    try {
      final songs = await _musicService.fetchArtistDiscography(
        _canonicalName,
        page: 1,
      );
      if (mounted) {
        setState(() {
          _allSongs = songs;
          _isLoading = false;
          _hasMore = songs.isNotEmpty;
        });

        // Immediately prefetch page 2 in background so the profile unlocks 150-200+ songs right away
        if (songs.isNotEmpty) {
          _prefetchPage2();
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _prefetchPage2() async {
    if (!mounted || _isLoadingMore || _currentPage >= 2) return;
    try {
      final batch = await _musicService.fetchArtistDiscography(
        _canonicalName,
        page: 2,
      );
      if (mounted && batch.isNotEmpty) {
        setState(() {
          _currentPage = 2;
          final uniqueNew = CanonicalSongDedup.deduplicateList(
            _allSongs,
            batch,
          );
          _allSongs.addAll(uniqueNew);
          _hasMore = true;
        });
      }
    } catch (_) {}
  }

  Future<void> _loadMoreDiscography() async {
    if (_isLoadingMore || !_hasMore || _isLoading) return;

    setState(() {
      _isLoadingMore = true;
    });

    try {
      final nextPage = _currentPage + 1;
      final batch = await _musicService.fetchArtistDiscography(
        _canonicalName,
        page: nextPage,
      );

      if (mounted) {
        setState(() {
          _isLoadingMore = false;
          _currentPage = nextPage;
          if (batch.isNotEmpty) {
            final uniqueNew = CanonicalSongDedup.deduplicateList(
              _allSongs,
              batch,
            );
            _allSongs.addAll(uniqueNew);
          }
          // Exhaust up to 10 deep query tiers; stop if empty past album tiers
          _hasMore = nextPage < 10 && (batch.isNotEmpty || nextPage <= 4);
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLoadingMore = false;
        });
      }
    }
  }

  /// Evaluates whether a song matches the active movie range / era filter
  bool _matchesEra(Video song, String era) {
    if (era == 'All Eras') return true;

    final lower = song.title.toLowerCase();

    // Check year in title if present
    final yearMatch = RegExp(r'\b(19\d{2}|20\d{2})\b').firstMatch(lower);
    if (yearMatch != null) {
      final year = int.tryParse(yearMatch.group(1) ?? '');
      if (year != null) {
        if (era == '2020–2025') return year >= 2020 && year <= 2025;
        if (era == '2010–2019') return year >= 2010 && year <= 2019;
        if (era == '2000–2009') return year >= 2000 && year <= 2009;
        if (era == 'Classics') return year < 2000;
      }
    }

    // Secondary semantic checks
    if (era == 'Classics') {
      return lower.contains('classic') ||
          lower.contains('old') ||
          lower.contains('retro') ||
          lower.contains('golden');
    }

    return true;
  }

  /// Client-side filtered songs based on Language, Movie, Era, and In-Artist Search
  List<Video> get _filteredSongs {
    return _allSongs.where((song) {
      final title = song.title.toLowerCase();
      final author = song.author.toLowerCase();

      // 1. Language Filter
      if (_selectedLanguage != 'All') {
        final lang = _selectedLanguage.toLowerCase();
        final matchesLang =
            title.contains(lang) ||
            author.contains(lang) ||
            (_artistItem != null && _artistItem.language.toLowerCase() == lang);
        if (!matchesLang) return false;
      }

      // 2. Movie Filter
      if (_selectedMovie != null && _selectedMovie!.isNotEmpty) {
        final movie = _selectedMovie!.toLowerCase();
        if (!title.contains(movie)) return false;
      }

      // 3. Era / Movie Range Filter
      if (!_matchesEra(song, _selectedEra)) {
        return false;
      }

      // 4. In-Artist Live Search Query
      if (_inArtistQuery.isNotEmpty) {
        final matchesQuery =
            title.contains(_inArtistQuery) || author.contains(_inArtistQuery);
        if (!matchesQuery) return false;
      }

      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final themeColor = Theme.of(context).primaryColor;
    final isFollowed = _prefs.isArtistFollowed(_canonicalName);
    final filtered = _filteredSongs;

    return Scaffold(
      backgroundColor: const Color(0xFF0B0B0F),
      body: Stack(
        children: [
          ResponsiveWrapper(
            maxWidth: 860,
            child: DilSeScrollbar(
              controller: _scrollController,
              bottomPadding: 90.0,
              child: CustomScrollView(
                controller: _scrollController,
                slivers: [
                  // 1. Hero AppBar with Artist Avatar & Back Action
                  SliverAppBar(
                    backgroundColor: const Color(0xFF0B0B0F),
                    expandedHeight: 310.0,
                    pinned: true,
                    elevation: 0,
                    leading: IconButton(
                      icon: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.5),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.arrow_back_ios_new_rounded,
                          color: Colors.white,
                          size: 18,
                        ),
                      ),
                      onPressed: () {
                        if (Navigator.canPop(context)) {
                          Navigator.pop(context);
                        } else {
                          DesktopLayoutState.closeDetailView();
                        }
                      },
                    ),
                    flexibleSpace: FlexibleSpaceBar(
                      background: Stack(
                        fit: StackFit.expand,
                        children: [
                          // Ambient gradient background derived from artist portrait
                          Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  themeColor.withValues(alpha: 0.35),
                                  const Color(0xFF141420),
                                  const Color(0xFF0B0B0F),
                                ],
                              ),
                            ),
                          ),
                          SafeArea(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const SizedBox(height: 12),
                                // High-Resolution Artist Circle Avatar
                                Container(
                                  width: 104,
                                  height: 104,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.white.withValues(
                                        alpha: 0.25,
                                      ),
                                      width: 2,
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: themeColor.withValues(
                                          alpha: 0.4,
                                        ),
                                        blurRadius: 28,
                                        offset: const Offset(0, 8),
                                      ),
                                    ],
                                  ),
                                  child: ClipOval(
                                    child:
                                        _artistItem != null &&
                                            _artistItem.imageUrl.isNotEmpty
                                        ? Image.network(
                                            _artistItem.imageUrl,
                                            fit: BoxFit.cover,
                                            cacheWidth: 240,
                                            cacheHeight: 240,
                                            errorBuilder: (_, _, _) =>
                                                _buildAvatarFallback(),
                                          )
                                        : _buildAvatarFallback(),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                // Artist Canonical Name
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 24,
                                  ),
                                  child: Text(
                                    _canonicalName,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 22,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: -0.4,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                // Squircle Follow Button
                                _FollowButton(
                                  key: const ValueKey(
                                    'artist_profile_follow_button',
                                  ),
                                  isFollowed: isFollowed,
                                  themeColor: themeColor,
                                  onTap: () {
                                    HapticFeedback.mediumImpact();
                                    _prefs.toggleFollowArtist(_canonicalName);
                                  },
                                ),
                                const SizedBox(height: 6),
                                // Tagline & Badge
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                  ),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (_artistItem != null &&
                                          _artistItem.badge.isNotEmpty) ...[
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: themeColor.withValues(
                                              alpha: 0.2,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              6,
                                            ),
                                            border: Border.all(
                                              color: themeColor.withValues(
                                                alpha: 0.5,
                                              ),
                                              width: 0.8,
                                            ),
                                          ),
                                          child: Text(
                                            _artistItem.badge,
                                            style: TextStyle(
                                              color: themeColor,
                                              fontSize: 10,
                                              fontWeight: FontWeight.w700,
                                              letterSpacing: 0.5,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                      ],
                                      Flexible(
                                        child: Text(
                                          _artistItem?.genre ??
                                              'Official Discography',
                                          style: TextStyle(
                                            color: Colors.white.withValues(
                                              alpha: 0.65,
                                            ),
                                            fontSize: 12,
                                            fontWeight: FontWeight.w500,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // 2. Action Deck: Play All & Shuffle Buttons
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: Row(
                        children: [
                          // Play All Primary Button
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: filtered.isEmpty
                                  ? null
                                  : () {
                                      HapticFeedback.mediumImpact();
                                      _musicService.playPlaylist(filtered, 0);
                                    },
                              icon: const Icon(
                                Icons.play_arrow_rounded,
                                size: 24,
                              ),
                              label: Text(
                                'Play All (${filtered.length})',
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: themeColor,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                elevation: 4,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          // Shuffle Button
                          ElevatedButton.icon(
                            onPressed: filtered.isEmpty
                                ? null
                                : () {
                                    HapticFeedback.mediumImpact();
                                    final shuffled = List<Video>.from(filtered)
                                      ..shuffle();
                                    _musicService.playPlaylist(shuffled, 0);
                                  },
                            icon: const Icon(Icons.shuffle_rounded, size: 20),
                            label: const Text(
                              'Shuffle',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF1E1E2C),
                              foregroundColor: Colors.white70,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 12,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                                side: BorderSide(
                                  color: Colors.white.withValues(alpha: 0.12),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          // Smart Artist Radio Button
                          ElevatedButton.icon(
                            onPressed: filtered.isEmpty
                                ? null
                                : () async {
                                    HapticFeedback.mediumImpact();
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          'Starting ${widget.artistName} Smart Radio…',
                                        ),
                                        duration: const Duration(seconds: 2),
                                        backgroundColor: themeColor.withValues(
                                          alpha: 0.9,
                                        ),
                                      ),
                                    );
                                    final topSong = filtered.first;
                                    final radioTracks = await _musicService
                                        .fetchRadioTracksForSong(
                                          topSong,
                                          limit: 40,
                                        );
                                    if (radioTracks.isNotEmpty) {
                                      _musicService.playPlaylist([
                                        topSong,
                                        ...radioTracks,
                                      ], 0);
                                    } else {
                                      _musicService.playPlaylist(filtered, 0);
                                    }
                                  },
                            icon: const Icon(
                              Icons.auto_awesome_rounded,
                              size: 18,
                            ),
                            label: const Text(
                              'Radio',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF1E1E2C),
                              foregroundColor: themeColor,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 12,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                                side: BorderSide(
                                  color: themeColor.withValues(alpha: 0.45),
                                  width: 1.2,
                                ),
                              ),
                              elevation: 2,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // 3. In-Artist Live Search Bar
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                      child: Container(
                        height: 42,
                        decoration: BoxDecoration(
                          color: const Color(0xFF161622),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.08),
                          ),
                        ),
                        child: TextField(
                          controller: _searchController,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13.5,
                          ),
                          decoration: InputDecoration(
                            hintText:
                                'Search within $_canonicalName\'s tracks...',
                            hintStyle: TextStyle(
                              color: Colors.white.withValues(alpha: 0.35),
                              fontSize: 13,
                            ),
                            prefixIcon: const Icon(
                              Icons.search_rounded,
                              color: Colors.white54,
                              size: 20,
                            ),
                            suffixIcon: _inArtistQuery.isNotEmpty
                                ? IconButton(
                                    icon: const Icon(
                                      Icons.clear_rounded,
                                      color: Colors.white54,
                                      size: 16,
                                    ),
                                    onPressed: () {
                                      _searchController.clear();
                                    },
                                  )
                                : null,
                            border: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 11,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                  // 4. Language Filter Strip
                  SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Text(
                            'LANGUAGE',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.45),
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.8,
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        SizedBox(
                          height: 34,
                          child: ListView.builder(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            itemCount: _languages.length,
                            itemBuilder: (context, index) {
                              final lang = _languages[index];
                              final isSelected = _selectedLanguage == lang;
                              return Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ChoiceChip(
                                  label: Text(lang),
                                  selected: isSelected,
                                  onSelected: (val) {
                                    HapticFeedback.selectionClick();
                                    setState(() {
                                      _selectedLanguage = lang;
                                    });
                                  },
                                  selectedColor: themeColor,
                                  backgroundColor: const Color(0xFF171724),
                                  labelStyle: TextStyle(
                                    color: isSelected
                                        ? Colors.white
                                        : Colors.white70,
                                    fontSize: 12,
                                    fontWeight: isSelected
                                        ? FontWeight.bold
                                        : FontWeight.w500,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                    side: BorderSide(
                                      color: isSelected
                                          ? themeColor
                                          : Colors.white.withValues(
                                              alpha: 0.08,
                                            ),
                                    ),
                                  ),
                                  showCheckmark: false,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 14),
                      ],
                    ),
                  ),

                  // 5. Movie & Era Range Filter Strip
                  SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'MOVIE & ERA RANGE',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.45),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.8,
                                ),
                              ),
                              if (_selectedMovie != null)
                                GestureDetector(
                                  onTap: () {
                                    setState(() {
                                      _selectedMovie = null;
                                    });
                                  },
                                  child: Text(
                                    'Clear Movie',
                                    style: TextStyle(
                                      color: themeColor,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 6),
                        // Era Chips Row
                        SizedBox(
                          height: 32,
                          child: ListView.builder(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            itemCount: _eraOptions.length,
                            itemBuilder: (context, index) {
                              final era = _eraOptions[index];
                              final isSelected = _selectedEra == era;
                              return Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ChoiceChip(
                                  label: Text(era),
                                  selected: isSelected,
                                  onSelected: (val) {
                                    HapticFeedback.selectionClick();
                                    setState(() {
                                      _selectedEra = era;
                                    });
                                  },
                                  selectedColor: const Color(0xFF26263C),
                                  backgroundColor: const Color(0xFF14141E),
                                  labelStyle: TextStyle(
                                    color: isSelected
                                        ? themeColor
                                        : Colors.white60,
                                    fontSize: 11.5,
                                    fontWeight: isSelected
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                    side: BorderSide(
                                      color: isSelected
                                          ? themeColor.withValues(alpha: 0.6)
                                          : Colors.white.withValues(
                                              alpha: 0.06,
                                            ),
                                    ),
                                  ),
                                  showCheckmark: false,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 8),
                        // Movie Chips Row (from curated filmography)
                        if (_filmography.isNotEmpty) ...[
                          SizedBox(
                            height: 32,
                            child: ListView.builder(
                              scrollDirection: Axis.horizontal,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              itemCount: _filmography.length + 1,
                              itemBuilder: (context, index) {
                                if (index == 0) {
                                  final isAll = _selectedMovie == null;
                                  return Padding(
                                    padding: const EdgeInsets.only(right: 8),
                                    child: ChoiceChip(
                                      label: const Text('All Movies'),
                                      selected: isAll,
                                      onSelected: (_) {
                                        HapticFeedback.selectionClick();
                                        setState(() {
                                          _selectedMovie = null;
                                        });
                                      },
                                      selectedColor: const Color(0xFF26263C),
                                      backgroundColor: const Color(0xFF14141E),
                                      labelStyle: TextStyle(
                                        color: isAll
                                            ? themeColor
                                            : Colors.white60,
                                        fontSize: 11.5,
                                        fontWeight: isAll
                                            ? FontWeight.w700
                                            : FontWeight.w500,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(14),
                                        side: BorderSide(
                                          color: isAll
                                              ? themeColor.withValues(
                                                  alpha: 0.6,
                                                )
                                              : Colors.white.withValues(
                                                  alpha: 0.06,
                                                ),
                                        ),
                                      ),
                                      showCheckmark: false,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                      ),
                                    ),
                                  );
                                }

                                final movie = _filmography[index - 1];
                                final isSelected = _selectedMovie == movie;
                                return Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: ChoiceChip(
                                    label: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(
                                          Icons.movie_outlined,
                                          size: 13,
                                          color: Colors.white54,
                                        ),
                                        const SizedBox(width: 4),
                                        Text(movie),
                                      ],
                                    ),
                                    selected: isSelected,
                                    onSelected: (_) {
                                      HapticFeedback.selectionClick();
                                      setState(() {
                                        _selectedMovie = isSelected
                                            ? null
                                            : movie;
                                      });
                                    },
                                    selectedColor: themeColor.withValues(
                                      alpha: 0.25,
                                    ),
                                    backgroundColor: const Color(0xFF14141E),
                                    labelStyle: TextStyle(
                                      color: isSelected
                                          ? Colors.white
                                          : Colors.white70,
                                      fontSize: 11.5,
                                      fontWeight: isSelected
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                      side: BorderSide(
                                        color: isSelected
                                            ? themeColor
                                            : Colors.white.withValues(
                                                alpha: 0.08,
                                              ),
                                      ),
                                    ),
                                    showCheckmark: false,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                      ],
                    ),
                  ),

                  // 6. Header Status Row
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
                      child: Row(
                        children: [
                          Text(
                            '${filtered.length} Tracks',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.2,
                            ),
                          ),
                          if (_selectedMovie != null) ...[
                            const SizedBox(width: 6),
                            Text(
                              '• $_selectedMovie',
                              style: TextStyle(
                                color: themeColor,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                          const Spacer(),
                          if (_isLoadingMore)
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Color(0xFF1DB954),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),

                  // 7. Song List Virtualized Slivers
                  if (_isLoading)
                    SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, index) => const ShimmerSongRow(),
                        childCount: 8,
                      ),
                    )
                  else if (filtered.isEmpty) ...[
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 32,
                          vertical: 48,
                        ),
                        child: Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.filter_alt_off_rounded,
                                size: 48,
                                color: Colors.white.withValues(alpha: 0.3),
                              ),
                              const SizedBox(height: 12),
                              const Text(
                                'No songs match the selected filters',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextButton(
                                onPressed: () {
                                  setState(() {
                                    _selectedLanguage = 'All';
                                    _selectedMovie = null;
                                    _selectedEra = 'All Eras';
                                    _searchController.clear();
                                  });
                                },
                                child: const Text('Reset All Filters'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (_bioText.isNotEmpty)
                      SliverToBoxAdapter(
                        child: _AboutArtistSection(
                          artistName: _canonicalName,
                          artistItem: _artistItem,
                          bioText: _bioText,
                          themeColor: themeColor,
                          soundtracksCount: _filmography.length,
                          totalLoadedCount: _allSongs.length,
                        ),
                      ),
                  ] else ...[
                    SliverList(
                      delegate: SliverChildBuilderDelegate((context, index) {
                        final song = filtered[index];
                        final isCurrentSong =
                            _musicService.currentSong?.id.value ==
                            song.id.value;
                        final hdThumbnail = MusicService.getHdThumbnail(
                          song.id.value,
                        );

                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
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
                            style: TextStyle(
                              color: isCurrentSong ? themeColor : Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                          subtitle: Text(
                            song.author,
                            maxLines: 1,
                            style: TextStyle(
                              color: isCurrentSong
                                  ? themeColor.withValues(alpha: 0.8)
                                  : Colors.grey[400],
                              fontSize: 12,
                            ),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (isCurrentSong)
                                Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: AnimatedEqualizer(
                                    isPlaying: _musicService.isPlaying,
                                    barCount: 3,
                                    color: themeColor,
                                    size: 16,
                                  ),
                                ),
                              IconButton(
                                icon: const Icon(
                                  Icons.more_horiz,
                                  color: Colors.white54,
                                ),
                                onPressed: () =>
                                    showSongOptionsBottomSheet(context, song),
                              ),
                            ],
                          ),
                          onTap: () {
                            HapticFeedback.lightImpact();
                            _musicService.playPlaylist(filtered, index);
                          },
                        );
                      }, childCount: filtered.length),
                    ),
                    // 8. About Artist Section (Rich 6–7 lines biography)
                    if (_bioText.isNotEmpty)
                      SliverToBoxAdapter(
                        child: _AboutArtistSection(
                          artistName: _canonicalName,
                          artistItem: _artistItem,
                          bioText: _bioText,
                          themeColor: themeColor,
                          soundtracksCount: _filmography.length,
                          totalLoadedCount: _allSongs.length,
                        ),
                      ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 20, bottom: 160),
                        child: Center(
                          child: _isLoadingMore
                              ? Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.5,
                                        valueColor:
                                            AlwaysStoppedAnimation<Color>(
                                              themeColor,
                                            ),
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    const Text(
                                      'Loading more tracks from discography...',
                                      style: TextStyle(
                                        color: Colors.white60,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                )
                              : _hasMore
                              ? OutlinedButton.icon(
                                  onPressed: _loadMoreDiscography,
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: themeColor,
                                    side: BorderSide(
                                      color: themeColor.withValues(alpha: 0.5),
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 22,
                                      vertical: 12,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(24),
                                    ),
                                  ),
                                  icon: const Icon(
                                    Icons.expand_more_rounded,
                                    size: 18,
                                  ),
                                  label: Text(
                                    'Load More Tracks (${_allSongs.length} loaded)',
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                )
                              : Text(
                                  filtered.length >= 30
                                      ? '• Complete Discography Loaded (${filtered.length} songs) •'
                                      : '',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.35),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          // Floating MiniPlayer visible over artist content when a song is playing (mobile only)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: AnimatedBuilder(
              animation: MusicService(),
              builder: (context, _) {
                if (MediaQuery.of(context).size.width >= 1024 ||
                    MusicService().currentSong == null) {
                  return const SizedBox.shrink();
                }
                return const MiniPlayer();
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatarFallback() {
    return Container(
      color: const Color(0xFF1E1E2C),
      child: const Icon(Icons.person_rounded, size: 52, color: Colors.white54),
    );
  }
}

/// Dedicated "About Artist" section presenting a rich 6–7 line editorial biography,
/// verified badges, and quick-attribute chips when scrolling down the profile.
class _AboutArtistSection extends StatelessWidget {
  final String artistName;
  final ArtistItem? artistItem;
  final String bioText;
  final Color themeColor;
  final int soundtracksCount;
  final int totalLoadedCount;

  const _AboutArtistSection({
    required this.artistName,
    required this.artistItem,
    required this.bioText,
    required this.themeColor,
    required this.soundtracksCount,
    required this.totalLoadedCount,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF13131F),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.09),
            width: 1,
          ),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              themeColor.withValues(alpha: 0.12),
              const Color(0xFF141422),
              const Color(0xFF0F0F18),
            ],
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header Row: Avatar, Title & Verified Badge
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: themeColor.withValues(alpha: 0.5),
                      width: 1.5,
                    ),
                  ),
                  child: ClipOval(
                    child: artistItem != null && artistItem!.imageUrl.isNotEmpty
                        ? Image.network(
                            artistItem!.imageUrl,
                            fit: BoxFit.cover,
                            cacheWidth: 90,
                            cacheHeight: 90,
                            errorBuilder: (_, _, _) => Icon(
                              Icons.person_rounded,
                              color: themeColor,
                              size: 22,
                            ),
                          )
                        : Icon(
                            Icons.person_rounded,
                            color: themeColor,
                            size: 22,
                          ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'ABOUT THE ARTIST',
                        style: TextStyle(
                          color: themeColor,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.1,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        artistName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.3,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.12),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.verified_rounded, size: 14, color: themeColor),
                      const SizedBox(width: 4),
                      const Text(
                        'Verified',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Editorial Bio: 6-7 lines
            Text(
              bioText,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.88),
                fontSize: 13.5,
                height: 1.6,
                letterSpacing: 0.15,
              ),
            ),
            const SizedBox(height: 16),
            // Metadata chips
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                if (artistItem?.genre != null && artistItem!.genre.isNotEmpty)
                  _buildChip(
                    icon: Icons.music_note_rounded,
                    label: artistItem!.genre,
                    color: themeColor,
                  ),
                if (artistItem?.language != null &&
                    artistItem!.language.isNotEmpty)
                  _buildChip(
                    icon: Icons.language_rounded,
                    label: '${artistItem!.language} Repertoire',
                    color: Colors.white70,
                  ),
                if (soundtracksCount > 0)
                  _buildChip(
                    icon: Icons.movie_outlined,
                    label: '$soundtracksCount Soundtracks',
                    color: Colors.white70,
                  ),
                if (totalLoadedCount > 0)
                  _buildChip(
                    icon: Icons.queue_music_rounded,
                    label: '$totalLoadedCount+ Tracks on DilSe',
                    color: Colors.white70,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChip({
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.8),
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Squircle Follow Button with smooth morphing animation between 'Follow' and 'Followed'.
class _FollowButton extends StatelessWidget {
  final bool isFollowed;
  final VoidCallback onTap;
  final Color themeColor;

  const _FollowButton({
    super.key,
    required this.isFollowed,
    required this.onTap,
    required this.themeColor,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        splashColor: themeColor.withValues(alpha: 0.25),
        highlightColor: themeColor.withValues(alpha: 0.12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeInOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
          decoration: BoxDecoration(
            color: isFollowed
                ? themeColor
                : Colors.white.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isFollowed
                  ? themeColor
                  : Colors.white.withValues(alpha: 0.28),
              width: 1.2,
            ),
            boxShadow: isFollowed
                ? [
                    BoxShadow(
                      color: themeColor.withValues(alpha: 0.45),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : const [],
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 240),
            switchInCurve: Curves.easeOutBack,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, animation) {
              return FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween<double>(
                    begin: 0.85,
                    end: 1.0,
                  ).animate(animation),
                  child: child,
                ),
              );
            },
            child: Row(
              key: ValueKey<bool>(isFollowed),
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isFollowed ? Icons.check_rounded : Icons.add_rounded,
                  color: Colors.white,
                  size: 15,
                ),
                const SizedBox(width: 6),
                Text(
                  isFollowed ? 'Followed' : 'Follow',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
