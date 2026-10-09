import 'artist_profile_screen.dart';
import '../services/dynamic_artist_service.dart';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' hide Playlist;
import '../services/canonical_song_dedup.dart';
import '../services/music_service.dart';
import '../services/preferences_service.dart';
import '../services/spotify_import_service.dart';
import 'spotify_import_screen.dart';
import 'custom_playlist_screen.dart';
import '../widgets/animated_equalizer.dart';
import '../widgets/playlist_action_menu.dart';
import '../widgets/dilse_scrollbar.dart';
import '../services/device_audio_service.dart';
import '../layouts/desktop_layout_state.dart';

/// Available navigation sections in the DilSe Library.
enum LibrarySection {
  playlists,
  liked,
  downloaded,
  albums,
  spotify,
  history,
  device,
  artists,
}

extension LibrarySectionExt on LibrarySection {
  String get title {
    switch (this) {
      case LibrarySection.playlists:
        return 'Playlists';
      case LibrarySection.liked:
        return 'Liked Songs';
      case LibrarySection.downloaded:
        return 'Downloaded';
      case LibrarySection.albums:
        return 'Albums';
      case LibrarySection.artists:
        return 'Artists';
      case LibrarySection.spotify:
        return 'Spotify Imports';
      case LibrarySection.history:
        return 'Listening History';
      case LibrarySection.device:
        return 'Device Audio';
    }
  }

  String get shortTitle {
    switch (this) {
      case LibrarySection.playlists:
        return 'Playlists';
      case LibrarySection.liked:
        return 'Liked';
      case LibrarySection.downloaded:
        return 'Downloaded';
      case LibrarySection.albums:
        return 'Albums';
      case LibrarySection.artists:
        return 'Artists';
      case LibrarySection.spotify:
        return 'Spotify';
      case LibrarySection.history:
        return 'History';
      case LibrarySection.device:
        return 'Device';
    }
  }

  IconData get icon {
    switch (this) {
      case LibrarySection.playlists:
        return Icons.queue_music_rounded;
      case LibrarySection.liked:
        return Icons.favorite_rounded;
      case LibrarySection.downloaded:
        return Icons.download_for_offline_rounded;
      case LibrarySection.albums:
        return Icons.album_rounded;
      case LibrarySection.artists:
        return Icons.people_alt_rounded;
      case LibrarySection.spotify:
        return Icons.sync_alt_rounded;
      case LibrarySection.history:
        return Icons.history_rounded;
      case LibrarySection.device:
        return Icons.sd_storage_rounded;
    }
  }
}

/// Lightweight representation of a soundtrack/album derived from user's library tracks.
class LibraryAlbum {
  final String title;
  final String artist;
  final String thumbnail;
  final List<Map<String, dynamic>> songs;

  const LibraryAlbum({
    required this.title,
    required this.artist,
    required this.thumbnail,
    required this.songs,
  });
}

/// Available filters for segregating playlists inside the Library Playlists section.
enum PlaylistFilter { all, personal, spotify }

extension PlaylistFilterExt on PlaylistFilter {
  String get label {
    switch (this) {
      case PlaylistFilter.all:
        return 'All';
      case PlaylistFilter.personal:
        return 'Created by You';
      case PlaylistFilter.spotify:
        return 'Spotify Imports';
    }
  }
}

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen>
    with AutomaticKeepAliveClientMixin {
  final MusicService _musicService = MusicService();
  final PreferencesService _prefs = PreferencesService();
  final SpotifyImportService _spotifyService = SpotifyImportService();

  late final ValueNotifier<LibrarySection> _selectedSection;
  final ValueNotifier<LibraryAlbum?> _selectedAlbum =
      ValueNotifier<LibraryAlbum?>(null);
  final ValueNotifier<PlaylistFilter> _playlistFilter =
      ValueNotifier<PlaylistFilter>(PlaylistFilter.all);

  @override
  bool get wantKeepAlive => true;

  final Map<String, int> _songFileSizes = {};
  int _lastDownloadedCount = -1;

  List<LibraryAlbum>? _cachedAlbums;
  int _lastLibraryFingerprint = -1;

  @override
  void initState() {
    super.initState();
    _selectedSection = ValueNotifier<LibrarySection>(LibrarySection.playlists);
    _musicService.addListener(_onStateChanged);
    _prefs.addListener(_onStateChanged);
    _spotifyService.addListener(_onStateChanged);
    _lastDownloadedCount = _musicService.downloadedSongs.length;
    _calculateStorageUsage();
  }

  @override
  void dispose() {
    _musicService.removeListener(_onStateChanged);
    _prefs.removeListener(_onStateChanged);
    _spotifyService.removeListener(_onStateChanged);
    _selectedSection.dispose();
    _selectedAlbum.dispose();
    _playlistFilter.dispose();
    super.dispose();
  }

  void _onStateChanged() {
    if (mounted) {
      final currentCount = _musicService.downloadedSongs.length;
      if (currentCount != _lastDownloadedCount) {
        _lastDownloadedCount = currentCount;
        _calculateStorageUsage();
      }
      _cachedAlbums = null;
      setState(() {});
    }
  }

  Future<void> _calculateStorageUsage() async {
    if (kIsWeb) return;
    final downloaded = _musicService.downloadedSongs;
    for (final s in downloaded) {
      final path = s['localPath'];
      final id = s['id'] ?? '';
      if (path != null && id.isNotEmpty) {
        try {
          final f = File(path);
          if (await f.exists()) {
            final len = await f.length();
            _songFileSizes[id] = len;
          }
        } catch (_) {}
      }
    }
    if (mounted) {
      setState(() {});
    }
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 MB';
    final mb = bytes / (1024 * 1024);
    if (mb < 1.0) {
      final kb = bytes / 1024;
      return '${kb.toStringAsFixed(0)} KB';
    }
    return '${mb.toStringAsFixed(1)} MB';
  }

  int _getSectionCount(LibrarySection section) {
    switch (section) {
      case LibrarySection.playlists:
        return _musicService.customPlaylists.length;
      case LibrarySection.liked:
        return _musicService.likedSongs.length;
      case LibrarySection.downloaded:
        return _musicService.downloadedSongs.length;
      case LibrarySection.albums:
        return _getDerivedAlbums().length;
      case LibrarySection.artists:
        return _prefs.followedArtists.length;
      case LibrarySection.device:
        return DeviceAudioService().deviceSongs.length;
      case LibrarySection.spotify:
        return _getSpotifyPlaylists().length;
      case LibrarySection.history:
        return _prefs.listeningHistory.length;
    }
  }

  bool _isSpotifyPlaylist(Map<String, dynamic> playlist) {
    final id = (playlist['id'] as String?) ?? '';
    if (id.isEmpty) return false;

    // 1. Explicit playlist metadata stored on disk/JSON
    if (playlist['isSpotify'] == true || playlist['source'] == 'spotify') {
      return true;
    }
    if (playlist['isSpotify'] == false || playlist['source'] == 'custom') {
      if (_prefs.isManualCreatedPlaylist(id)) return false;
    }

    // 2. Preferences persistent registry
    if (_prefs.isSpotifyImportedPlaylist(id)) return true;
    if (_prefs.isManualCreatedPlaylist(id)) return false;

    // 3. SpotifyImportService runtime tracking
    if (_spotifyService.lastImportedPlaylists.any((p) => p['id'] == id)) {
      return true;
    }
    if (_spotifyService.lastImportedPlaylistId == id) {
      return true;
    }
    final name = ((playlist['name'] as String?) ?? '').trim();
    final lowerName = name.toLowerCase();
    if (_spotifyService.lastImportedPlaylistName != null &&
        _spotifyService.lastImportedPlaylistName!.trim().toLowerCase() ==
            lowerName) {
      return true;
    }
    if (_spotifyService.currentPlaylistName.trim().isNotEmpty &&
        _spotifyService.currentPlaylistName.trim().toLowerCase() == lowerName) {
      return true;
    }

    // 4. Keyword heuristics
    if (lowerName.contains('spotify') ||
        lowerName.contains('exportify') ||
        lowerName == 'forever young') {
      return true;
    }

    // 5. Intelligent segregation for imported playlists:
    // If a playlist has NOT been explicitly registered as created by the user,
    // and contains imported tracks or the user has imported Spotify data,
    // it belongs to Spotify Imports!
    if (!_prefs.isManualCreatedPlaylist(id)) {
      final songs = playlist['songs'] as List<dynamic>? ?? [];
      if (songs.isNotEmpty) {
        return true;
      }
    }

    return false;
  }

  List<Map<String, dynamic>> _getSpotifyPlaylists() {
    return _musicService.customPlaylists.where(_isSpotifyPlaylist).toList();
  }

  List<LibraryAlbum> _getDerivedAlbums() {
    final currentFingerprint =
        _musicService.likedSongs.length +
        _musicService.downloadedSongs.length +
        _musicService.customPlaylists.length +
        _prefs.listeningHistory.length;

    if (_cachedAlbums != null &&
        _lastLibraryFingerprint == currentFingerprint) {
      return _cachedAlbums!;
    }

    final Map<String, List<Map<String, dynamic>>> albumSongMap = {};
    final Map<String, String> albumArtworkMap = {};
    final Map<String, String> albumArtistMap = {};

    void processSong(Map<String, dynamic> song) {
      final title = (song['title'] as String? ?? '').trim();
      if (title.isEmpty) return;

      String album = (song['album'] as String? ?? '').trim();
      if (album.isEmpty || album.toLowerCase() == 'dilse') {
        final fromMatch = RegExp(
          r'(?:from\s+["“]([^"”]+)["”]|from\s+([A-Za-z0-9\s]+))',
          caseSensitive: false,
        ).firstMatch(title);
        if (fromMatch != null) {
          album = (fromMatch.group(1) ?? fromMatch.group(2) ?? '').trim();
        }
      }

      if (album.isEmpty || album.toLowerCase() == 'dilse') {
        final ctx = CanonicalSongDedup.extractSongContext(
          title,
          song['author'] ?? '',
        );
        final contextKeywords = ctx['contextKeywords'] as List<String>? ?? [];
        if (contextKeywords.isNotEmpty) {
          album = contextKeywords.first;
        }
      }

      if (album.isEmpty || album.toLowerCase() == 'dilse') {
        return;
      }

      final key = album.toLowerCase();
      albumSongMap.putIfAbsent(key, () => []);

      final songId = song['id']?.toString() ?? '';
      if (!albumSongMap[key]!.any(
        (s) => (s['id']?.toString() ?? '') == songId,
      )) {
        albumSongMap[key]!.add(song);
      }

      final thumb = (song['thumbnail'] as String? ?? '').trim();
      if (thumb.isNotEmpty && !albumArtworkMap.containsKey(key)) {
        albumArtworkMap[key] = thumb;
      }

      final artist = (song['author'] as String? ?? '').trim();
      if (artist.isNotEmpty && !albumArtistMap.containsKey(key)) {
        albumArtistMap[key] = artist;
      }
    }

    for (final s in _musicService.likedSongs) {
      processSong(s);
    }
    for (final s in _musicService.downloadedSongs) {
      processSong(s);
    }
    for (final p in _musicService.customPlaylists) {
      final songs = p['songs'] as List<dynamic>? ?? [];
      for (final s in songs) {
        if (s is Map) {
          processSong(Map<String, dynamic>.from(s));
        }
      }
    }
    for (final s in _prefs.listeningHistory) {
      processSong(s);
    }

    final List<LibraryAlbum> derived = [];
    albumSongMap.forEach((key, songs) {
      if (songs.isNotEmpty) {
        final rawAlbum = (songs.first['album'] as String? ?? '').trim();
        final displayTitle =
            rawAlbum.isNotEmpty && rawAlbum.toLowerCase() != 'dilse'
            ? rawAlbum
            : (songs.first['title']?.toString() ?? key);

        derived.add(
          LibraryAlbum(
            title: displayTitle,
            artist: albumArtistMap[key] ?? 'Soundtrack',
            thumbnail:
                albumArtworkMap[key] ??
                (songs.first['thumbnail']?.toString() ?? ''),
            songs: songs,
          ),
        );
      }
    });

    derived.sort((a, b) {
      final countComp = b.songs.length.compareTo(a.songs.length);
      if (countComp != 0) return countComp;
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });

    _cachedAlbums = derived;
    _lastLibraryFingerprint = currentFingerprint;
    return derived;
  }

  void _playAlbum(
    LibraryAlbum album, {
    int startIndex = 0,
    bool shuffle = false,
  }) {
    if (album.songs.isEmpty) return;

    final videos = album.songs.map((item) {
      final rawId = (item['id'] as String?) ?? '';
      VideoId videoId;
      try {
        videoId = VideoId(rawId);
      } catch (_) {
        final padded = '${rawId}___________'.substring(0, 11);
        videoId = VideoId(padded);
      }
      return Video(
        videoId,
        (item['title'] as String?) ?? 'Unknown Title',
        (item['author'] as String?) ?? album.artist,
        ChannelId('UC0WP5P-fwGlLyO4yOE76T8g'),
        DateTime.now(),
        '',
        null,
        '',
        null,
        ThumbnailSet(rawId),
        null,
        Engagement(0, null, null),
        false,
      );
    }).toList();

    if (shuffle) {
      _musicService.toggleShuffle();
    }
    _musicService.playPlaylist(videos, startIndex);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return Scaffold(
      backgroundColor: const Color(0xFF0B0B0F),
      body: SafeArea(
        bottom: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= 650;
            if (isWide) {
              return _buildWideLayout(context, constraints);
            }
            return _buildMobileLayout(context);
          },
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // DESKTOP / WIDE LAYOUT (Sidebar + Panel)
  // ---------------------------------------------------------------------------

  Widget _buildWideLayout(BuildContext context, BoxConstraints constraints) {
    const double sidebarWidth = 240.0;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Left Sidebar: Structured Information Architecture
        SizedBox(width: sidebarWidth, child: _buildDesktopSidebar(context)),

        // 1px Subtle Obsidian Divider
        Container(width: 1, color: Colors.white.withValues(alpha: 0.07)),

        // Right Main Content Panel: Selected Section Display
        Expanded(
          child: ValueListenableBuilder<LibrarySection>(
            valueListenable: _selectedSection,
            builder: (context, section, _) {
              return ValueListenableBuilder<LibraryAlbum?>(
                valueListenable: _selectedAlbum,
                builder: (context, selectedAlbum, _) {
                  if (section == LibrarySection.albums &&
                      selectedAlbum != null) {
                    return _buildAlbumDetailView(selectedAlbum);
                  }
                  return _buildContentPanel(context, section, isWide: true);
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildDesktopSidebar(BuildContext context) {
    return Container(
      color: const Color(0xFF0F0F16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Sidebar Header: Title + Add Playlist Control
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 12, 14),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Your Library',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 19,
                      color: Colors.white,
                      letterSpacing: -0.6,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(
                    Icons.add_rounded,
                    color: Colors.white70,
                    size: 20,
                  ),
                  tooltip: 'Create New Playlist',
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.white.withValues(alpha: 0.08),
                    padding: const EdgeInsets.all(6),
                    minimumSize: const Size(30, 30),
                  ),
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    _showCreatePlaylistDialog();
                  },
                ),
              ],
            ),
          ),

          const SizedBox(height: 6),

          // Sidebar Navigation Items
          Expanded(
            child: ValueListenableBuilder<LibrarySection>(
              valueListenable: _selectedSection,
              builder: (context, activeSection, _) {
                return ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  children: LibrarySection.values.map((section) {
                    final isSelected = activeSection == section;
                    final count = _getSectionCount(section);

                    return Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () {
                            HapticFeedback.selectionClick();
                            if (_selectedAlbum.value != null) {
                              _selectedAlbum.value = null;
                            }
                            _selectedSection.value = section;
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? Colors.white.withValues(alpha: 0.10)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isSelected
                                    ? Colors.white.withValues(alpha: 0.16)
                                    : Colors.transparent,
                                width: 1,
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  section.icon,
                                  size: 19,
                                  color: isSelected
                                      ? Colors.white
                                      : Colors.white60,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    section.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: isSelected
                                          ? Colors.white
                                          : Colors.white70,
                                      fontWeight: isSelected
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                      fontSize: 13.5,
                                      letterSpacing: -0.2,
                                    ),
                                  ),
                                ),
                                if (count > 0)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 7,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: isSelected
                                          ? Colors.white.withValues(alpha: 0.18)
                                          : Colors.white.withValues(
                                              alpha: 0.06,
                                            ),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      '$count',
                                      style: TextStyle(
                                        color: isSelected
                                            ? Colors.white
                                            : Colors.white54,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // MOBILE / COMPACT LAYOUT (Horizontal Tabs + Fluid Panel)
  // ---------------------------------------------------------------------------

  Widget _buildMobileLayout(BuildContext context) {
    return Column(
      children: [
        // Compact App Bar with Title & Add Playlist Control (Green import button removed)
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 14, 8),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Your Library',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 26,
                    color: Colors.white,
                    letterSpacing: -0.8,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(
                  Icons.add_rounded,
                  color: Colors.white,
                  size: 22,
                ),
                tooltip: 'Create New Playlist',
                style: IconButton.styleFrom(
                  backgroundColor: Colors.white.withValues(alpha: 0.10),
                  padding: const EdgeInsets.all(8),
                  minimumSize: const Size(36, 36),
                ),
                onPressed: () {
                  HapticFeedback.lightImpact();
                  _showCreatePlaylistDialog();
                },
              ),
            ],
          ),
        ),

        // Responsive Horizontal Pill Tabs
        SizedBox(
          height: 44,
          child: ValueListenableBuilder<LibrarySection>(
            valueListenable: _selectedSection,
            builder: (context, activeSection, _) {
              return ListView(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                children: LibrarySection.values.map((section) {
                  final isSelected = activeSection == section;
                  final count = _getSectionCount(section);

                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: () {
                        HapticFeedback.selectionClick();
                        if (_selectedAlbum.value != null) {
                          _selectedAlbum.value = null;
                        }
                        _selectedSection.value = section;
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? Colors.white.withValues(alpha: 0.15)
                              : Colors.white.withValues(alpha: 0.04),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: isSelected
                                ? Colors.white.withValues(alpha: 0.25)
                                : Colors.white.withValues(alpha: 0.06),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              section.icon,
                              size: 15,
                              color: isSelected ? Colors.white : Colors.white60,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              section.shortTitle,
                              style: TextStyle(
                                color: isSelected
                                    ? Colors.white
                                    : Colors.white70,
                                fontWeight: isSelected
                                    ? FontWeight.w700
                                    : FontWeight.w600,
                                fontSize: 13,
                                letterSpacing: -0.2,
                              ),
                            ),
                            if (count > 0) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 1.5,
                                ),
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? Colors.white.withValues(alpha: 0.20)
                                      : Colors.white.withValues(alpha: 0.08),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  '$count',
                                  style: TextStyle(
                                    color: isSelected
                                        ? Colors.white
                                        : Colors.white60,
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ),

        const SizedBox(height: 6),

        // Main Panel: Content for the Active Section
        Expanded(
          child: ValueListenableBuilder<LibrarySection>(
            valueListenable: _selectedSection,
            builder: (context, section, _) {
              return ValueListenableBuilder<LibraryAlbum?>(
                valueListenable: _selectedAlbum,
                builder: (context, selectedAlbum, _) {
                  if (section == LibrarySection.albums &&
                      selectedAlbum != null) {
                    return _buildAlbumDetailView(selectedAlbum);
                  }
                  return _buildContentPanel(context, section, isWide: false);
                },
              );
            },
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // SECTION CONTENT ROUTER
  // ---------------------------------------------------------------------------

  Widget _buildContentPanel(
    BuildContext context,
    LibrarySection section, {
    required bool isWide,
  }) {
    switch (section) {
      case LibrarySection.playlists:
        return _buildPlaylistsSection(isWide: isWide);
      case LibrarySection.liked:
        return _buildLikedSection();
      case LibrarySection.downloaded:
        return _buildDownloadedSection();
      case LibrarySection.albums:
        return _buildAlbumsSection(isWide: isWide);
      case LibrarySection.artists:
        return _buildFollowedArtistsSection();
      case LibrarySection.device:
        return _buildDeviceSection();
      case LibrarySection.spotify:
        return _buildSpotifyImportsSection(isWide: isWide);
      case LibrarySection.history:
        return _buildHistorySection();
    }
  }

  // ---------------------------------------------------------------------------
  // SECTION 1: PLAYLISTS
  // ---------------------------------------------------------------------------

  Widget _buildPlaylistFilterPills({
    required int allCount,
    required int personalCount,
    required int spotifyCount,
  }) {
    return ValueListenableBuilder<PlaylistFilter>(
      valueListenable: _playlistFilter,
      builder: (context, activeFilter, _) {
        final filters = [
          (PlaylistFilter.all, 'All', allCount),
          (PlaylistFilter.personal, 'Created by You', personalCount),
          (PlaylistFilter.spotify, 'Spotify Imports', spotifyCount),
        ];

        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: filters.map((item) {
              final (filter, label, count) = item;
              final isSelected = activeFilter == filter;

              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: InkWell(
                  key: ValueKey('filter_pill_${filter.name}'),
                  borderRadius: BorderRadius.circular(20),
                  onTap: () {
                    HapticFeedback.selectionClick();
                    _playlistFilter.value = filter;
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? (filter == PlaylistFilter.spotify
                                ? const Color(
                                    0xFF1DB954,
                                  ).withValues(alpha: 0.22)
                                : Colors.white.withValues(alpha: 0.16))
                          : Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: isSelected
                            ? (filter == PlaylistFilter.spotify
                                  ? const Color(0xFF1DB954)
                                  : Colors.white)
                            : Colors.white.withValues(alpha: 0.08),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (filter == PlaylistFilter.spotify) ...[
                          Icon(
                            Icons.sync_alt_rounded,
                            size: 13,
                            color: isSelected
                                ? const Color(0xFF1DB954)
                                : Colors.white60,
                          ),
                          const SizedBox(width: 5),
                        ],
                        Text(
                          label,
                          style: TextStyle(
                            color: isSelected ? Colors.white : Colors.white70,
                            fontSize: 12.5,
                            fontWeight: isSelected
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? (filter == PlaylistFilter.spotify
                                      ? const Color(0xFF1DB954)
                                      : Colors.white.withValues(alpha: 0.24))
                                : Colors.white.withValues(alpha: 0.07),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '$count',
                            style: TextStyle(
                              color: isSelected
                                  ? (filter == PlaylistFilter.spotify
                                        ? Colors.black
                                        : Colors.white)
                                  : Colors.white54,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        );
      },
    );
  }

  Widget _buildPlaylistsSection({required bool isWide}) {
    final allPlaylists = _musicService.customPlaylists;

    if (allPlaylists.isEmpty) {
      return _buildEmptyState(
        icon: Icons.featured_play_list_outlined,
        title: 'No playlists yet',
        subtitle:
            'Create your own playlists or import playlists from Spotify to build your collection.',
        action: ElevatedButton.icon(
          icon: const Icon(Icons.add_rounded, size: 18),
          label: const Text('New Playlist'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: Colors.black,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          onPressed: () {
            HapticFeedback.lightImpact();
            _showCreatePlaylistDialog();
          },
        ),
      );
    }

    final spotifyPlaylists = allPlaylists.where(_isSpotifyPlaylist).toList();
    final personalPlaylists = allPlaylists
        .where((p) => !_isSpotifyPlaylist(p))
        .toList();

    return ValueListenableBuilder<PlaylistFilter>(
      valueListenable: _playlistFilter,
      builder: (context, activeFilter, _) {
        final List<Map<String, dynamic>> displayedPlaylists;
        switch (activeFilter) {
          case PlaylistFilter.all:
            displayedPlaylists = allPlaylists;
            break;
          case PlaylistFilter.personal:
            displayedPlaylists = personalPlaylists;
            break;
          case PlaylistFilter.spotify:
            displayedPlaylists = spotifyPlaylists;
            break;
        }

        final itemCount = displayedPlaylists.isEmpty
            ? 3
            : displayedPlaylists.length + 2;

        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 160, top: 10),
          itemCount: itemCount,
          itemBuilder: (context, index) {
            if (index == 0) {
              return Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(
                      child: Text(
                        '${displayedPlaylists.length} ${activeFilter.label} Playlists',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      icon: const Icon(
                        Icons.add_rounded,
                        size: 17,
                        color: Colors.white70,
                      ),
                      label: const Text(
                        'New Playlist',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      onPressed: _showCreatePlaylistDialog,
                    ),
                  ],
                ),
              );
            }

            if (index == 1) {
              return _buildPlaylistFilterPills(
                allCount: allPlaylists.length,
                personalCount: personalPlaylists.length,
                spotifyCount: spotifyPlaylists.length,
              );
            }

            if (displayedPlaylists.isEmpty) {
              return Padding(
                padding: const EdgeInsets.only(top: 40),
                child: _buildEmptyState(
                  icon: activeFilter == PlaylistFilter.spotify
                      ? Icons.sync_alt_rounded
                      : Icons.playlist_add_rounded,
                  title: activeFilter == PlaylistFilter.spotify
                      ? 'No Spotify imports yet'
                      : 'No personal playlists yet',
                  subtitle: activeFilter == PlaylistFilter.spotify
                      ? 'Import public Spotify playlists or Exportify CSV archives into DilSe.'
                      : 'Tap "+ New Playlist" to start creating your own custom mix.',
                  action: activeFilter == PlaylistFilter.spotify
                      ? ElevatedButton.icon(
                          icon: const Icon(Icons.sync_rounded, size: 16),
                          label: const Text('Import from Spotify'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF1DB954),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          onPressed: () {
                            _selectedSection.value = LibrarySection.spotify;
                          },
                        )
                      : null,
                ),
              );
            }

            final playlist = displayedPlaylists[index - 2];
            final name = (playlist['name'] as String?) ?? 'Unknown Playlist';
            final songs = List<Map<String, dynamic>>.from(
              playlist['songs'] ?? [],
            );
            final id = (playlist['id'] as String?) ?? '';
            final firstThumbnail = songs.isNotEmpty
                ? songs.first['thumbnail'] as String?
                : null;
            final isSpotify = _isSpotifyPlaylist(playlist);

            return ListTile(
              key: ValueKey('playlist_row_$id'),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 4,
              ),
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: isSpotify
                        ? const Color(0xFF1DB954).withValues(alpha: 0.16)
                        : _prefs.themeColor.withValues(alpha: 0.16),
                    border: Border.all(
                      color: isSpotify
                          ? const Color(0xFF1DB954).withValues(alpha: 0.35)
                          : Colors.white.withValues(alpha: 0.08),
                      width: 1,
                    ),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: firstThumbnail != null && firstThumbnail.isNotEmpty
                      ? Image.network(
                          firstThumbnail,
                          fit: BoxFit.cover,
                          cacheWidth: 120,
                          cacheHeight: 120,
                          errorBuilder: (_, _, _) => Icon(
                            Icons.queue_music_rounded,
                            color: isSpotify
                                ? const Color(0xFF1DB954)
                                : _prefs.themeColor.withValues(alpha: 0.85),
                            size: 26,
                          ),
                        )
                      : Icon(
                          Icons.queue_music_rounded,
                          color: isSpotify
                              ? const Color(0xFF1DB954)
                              : _prefs.themeColor.withValues(alpha: 0.85),
                          size: 26,
                        ),
                ),
              ),
              title: Row(
                children: [
                  Flexible(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        fontSize: 15,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ),
                  if (isSpotify) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1.5,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1DB954).withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: const Color(0xFF1DB954).withValues(alpha: 0.3),
                          width: 0.8,
                        ),
                      ),
                      child: const Text(
                        'Spotify',
                        style: TextStyle(
                          color: Color(0xFF1DB954),
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              subtitle: Text(
                isSpotify
                    ? '${songs.length} tracks • Spotify Ingested'
                    : '${songs.length} tracks • Personal',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6),
                  fontSize: 13,
                ),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    key: ValueKey('playlist_play_$id'),
                    icon: const Icon(
                      Icons.play_circle_fill_rounded,
                      color: Colors.white,
                      size: 36,
                    ),
                    tooltip: 'Play playlist',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 40,
                      minHeight: 40,
                    ),
                    onPressed: songs.isEmpty
                        ? null
                        : () {
                            HapticFeedback.lightImpact();
                            _musicService.playCustomPlaylist(id, 0);
                          },
                  ),
                  const SizedBox(width: 4),
                  PlaylistActionMenu(
                    key: ValueKey('playlist_more_$id'),
                    playlistId: id,
                    playlistName: name,
                    isSpotifyImport: isSpotify,
                    onRename: () => _showRenamePlaylistDialog(id, name),
                    onDelete: () => _showDeletePlaylistDialog(id, name),
                    onToggleSource: () {
                      final nowSpotify = _isSpotifyPlaylist(playlist);
                      if (nowSpotify) {
                        _prefs.unregisterSpotifyPlaylistId(id);
                        _prefs.registerManualPlaylistId(id);
                        _musicService.setPlaylistSource(id, isSpotify: false);
                      } else {
                        _prefs.unregisterManualPlaylistId(id);
                        _prefs.registerSpotifyPlaylistId(id);
                        _musicService.setPlaylistSource(id, isSpotify: true);
                      }
                      setState(() {});
                    },
                  ),
                ],
              ),
              onTap: () {
                HapticFeedback.lightImpact();
                if (kIsWeb && MediaQuery.of(context).size.width >= 1024) {
                  DesktopLayoutState.openPlaylist(id);
                } else {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => CustomPlaylistScreen(playlistId: id),
                    ),
                  );
                }
              },
            );
          },
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // SECTION 2: LIKED SONGS
  // ---------------------------------------------------------------------------

  Widget _buildLikedSection() {
    final liked = _musicService.likedSongs;

    if (liked.isEmpty) {
      return _buildEmptyState(
        icon: Icons.favorite_border_rounded,
        title: 'No liked songs yet',
        subtitle:
            'Tap the heart icon while playing any song to save it in your favorites collection.',
      );
    }

    return DilSeScrollbar(
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 160, top: 10),
        itemCount: liked.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return _buildActionHeader(
              count: liked.length,
              onPlayAll: () {
                HapticFeedback.lightImpact();
                _musicService.playLikedSong(liked.first);
              },
              onShuffle: () {
                HapticFeedback.lightImpact();
                _musicService.toggleShuffle();
                _musicService.playLikedSong(liked.first);
              },
            );
          }

          final song = liked[index - 1];
          final songId = song['id'] ?? '';
          final isCurrent = _musicService.currentSong?.id.value == songId;

          return ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 4,
            ),
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 52,
                height: 52,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.network(
                      song['thumbnail'] ?? '',
                      fit: BoxFit.cover,
                      cacheWidth: 120,
                      cacheHeight: 120,
                      errorBuilder: (_, _, _) => Container(
                        color: const Color(0xFF1E1E28),
                        child: const Icon(
                          Icons.music_note,
                          color: Colors.white54,
                        ),
                      ),
                    ),
                    if (isCurrent)
                      Container(
                        color: Colors.black54,
                        child: Center(
                          child: AnimatedEqualizer(
                            isPlaying: _musicService.isPlaying,
                            size: 22,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            title: Text(
              song['title'] ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: Colors.white,
                fontSize: 14.5,
                letterSpacing: -0.2,
              ),
            ),
            subtitle: Text(
              song['author'] ?? '',
              maxLines: 1,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: 12.5,
              ),
            ),
            trailing: IconButton(
              icon: const Icon(
                Icons.favorite_rounded,
                color: Color(0xFFFA2D48),
                size: 22,
              ),
              onPressed: () {
                HapticFeedback.selectionClick();
                _musicService.removeLikedSong(song['id'] ?? '');
              },
            ),
            onTap: () {
              HapticFeedback.lightImpact();
              _musicService.playLikedSong(song);
            },
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // SECTION 3: DOWNLOADED (OFFLINE)
  // ---------------------------------------------------------------------------

  Widget _buildDownloadedSection() {
    final downloaded = _musicService.downloadedSongs;

    if (downloaded.isEmpty) {
      return _buildEmptyState(
        icon: Icons.download_for_offline_outlined,
        title: 'No downloaded songs yet',
        subtitle:
            'Tap the download icon while playing any song to listen offline without internet.',
      );
    }

    return DilSeScrollbar(
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 160, top: 10),
        itemCount: downloaded.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return _buildActionHeader(
              count: downloaded.length,
              onPlayAll: () {
                HapticFeedback.lightImpact();
                _musicService.playDownloadedSong(downloaded.first);
              },
              onShuffle: () {
                HapticFeedback.lightImpact();
                _musicService.toggleShuffle();
                _musicService.playDownloadedSong(downloaded.first);
              },
            );
          }

          final song = downloaded[index - 1];
          final songId = song['id'] ?? '';
          final sizeBytes = _songFileSizes[songId] ?? 0;
          final sizeFormatted = _formatBytes(sizeBytes);
          final isCurrent = _musicService.currentSong?.id.value == songId;

          return ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 4,
            ),
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 52,
                height: 52,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.network(
                      song['thumbnail'] ?? '',
                      cacheWidth: 120,
                      cacheHeight: 120,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        color: const Color(0xFF1E1E28),
                        child: const Icon(
                          Icons.music_note,
                          color: Colors.white54,
                        ),
                      ),
                    ),
                    if (isCurrent)
                      Container(
                        color: Colors.black54,
                        child: Center(
                          child: AnimatedEqualizer(
                            isPlaying: _musicService.isPlaying,
                            size: 22,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            title: Text(
              song['title'] ?? 'Unknown',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: Colors.white,
                fontSize: 14.5,
                letterSpacing: -0.2,
              ),
            ),
            subtitle: Row(
              children: [
                Flexible(
                  child: Text(
                    song['author'] ?? 'Unknown Artist',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6),
                      fontSize: 12.5,
                    ),
                  ),
                ),
                if (sizeBytes > 0) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1.5,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white12,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      sizeFormatted,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.offline_pin_rounded,
                  color: Color(0xFF1DB954),
                  size: 20,
                ),
                IconButton(
                  icon: const Icon(
                    Icons.delete_outline_rounded,
                    color: Colors.white38,
                    size: 20,
                  ),
                  onPressed: () async {
                    HapticFeedback.mediumImpact();
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        backgroundColor: const Color(0xFF1E1E28),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        title: const Text(
                          'Delete Download?',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        content: Text(
                          'Remove "${song['title']}" from offline storage?',
                          style: const TextStyle(color: Colors.white70),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('Cancel'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text(
                              'Delete',
                              style: TextStyle(
                                color: Colors.redAccent,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                    if (confirm == true) {
                      await _musicService.deleteDownloadedSong(song['id']!);
                    }
                  },
                ),
              ],
            ),
            onTap: () {
              HapticFeedback.lightImpact();
              _musicService.playDownloadedSong(song);
            },
          );
        },
      ),
    );
  }

  Widget _buildAudioBadge(String format) {
    return Container(
      color: const Color(0xFF242436),
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.music_note_rounded, size: 20, color: Colors.white70),
          const SizedBox(height: 2),
          Text(
            format,
            style: const TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w800,
              color: Colors.white54,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceSection() {
    final deviceService = DeviceAudioService();
    return AnimatedBuilder(
      animation: deviceService,
      builder: (context, _) {
        final songs = deviceService.deviceSongs;
        final isScanning = deviceService.isScanning;

        if (isScanning) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CircularProgressIndicator(
                    strokeWidth: 2.5,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      Color(0xFFFA2D48),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    deviceService.scanStatusMessage.isNotEmpty
                        ? deviceService.scanStatusMessage
                        : 'Scanning device storage...',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        if (songs.isEmpty) {
          return Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.06),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.sd_storage_rounded,
                      size: 36,
                      color: Colors.white54,
                    ),
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'No on-device music found',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Play local audio files (.mp3, .m4a, .flac, .wav, .opus) directly from your device storage with zero streaming data.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      ElevatedButton.icon(
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('Scan Storage'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 12,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: () {
                          HapticFeedback.lightImpact();
                          deviceService.scanDeviceStorage();
                        },
                      ),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.folder_open_rounded, size: 18),
                        label: const Text('Pick Folder'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: BorderSide(
                            color: Colors.white.withValues(alpha: 0.25),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 12,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: () {
                          HapticFeedback.lightImpact();
                          deviceService.pickDirectory();
                        },
                      ),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.file_upload_rounded, size: 18),
                        label: const Text('Add Files'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: BorderSide(
                            color: Colors.white.withValues(alpha: 0.25),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 12,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: () {
                          HapticFeedback.lightImpact();
                          deviceService.pickAudioFiles();
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        }

        return DilSeScrollbar(
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 160, top: 10),
            itemCount: songs.length + 2,
            itemBuilder: (context, index) {
              if (index == 0) {
                return _buildActionHeader(
                  count: songs.length,
                  onPlayAll: () {
                    HapticFeedback.lightImpact();
                    _musicService.playDeviceSong(songs.first);
                  },
                  onShuffle: () {
                    HapticFeedback.lightImpact();
                    _musicService.toggleShuffle();
                    _musicService.playDeviceSong(songs.first);
                  },
                );
              }

              if (index == 1) {
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      ActionChip(
                        avatar: const Icon(Icons.refresh_rounded, size: 14),
                        label: const Text(
                          'Rescan',
                          style: TextStyle(fontSize: 12),
                        ),
                        onPressed: () => deviceService.scanDeviceStorage(),
                        backgroundColor: Colors.white.withValues(alpha: 0.08),
                        side: BorderSide.none,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ActionChip(
                        avatar: const Icon(Icons.folder_open_rounded, size: 14),
                        label: const Text(
                          'Folder',
                          style: TextStyle(fontSize: 12),
                        ),
                        onPressed: () => deviceService.pickDirectory(),
                        backgroundColor: Colors.white.withValues(alpha: 0.08),
                        side: BorderSide.none,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ActionChip(
                        avatar: const Icon(Icons.file_upload_rounded, size: 14),
                        label: const Text(
                          'Add Files',
                          style: TextStyle(fontSize: 12),
                        ),
                        onPressed: () => deviceService.pickAudioFiles(),
                        backgroundColor: Colors.white.withValues(alpha: 0.08),
                        side: BorderSide.none,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ],
                  ),
                );
              }

              final song = songs[index - 2];
              final songId = song['id'] ?? '';
              final isCurrent = _musicService.currentSong?.id.value == songId;
              final format = song['format'] ?? 'AUDIO';
              final rawSize = int.tryParse(song['fileSize'] ?? '0') ?? 0;
              final sizeFormatted = _formatBytes(rawSize);

              return ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    width: 52,
                    height: 52,
                    color: const Color(0xFF1E1E28),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (song['thumbnail'] != null &&
                            song['thumbnail']!.isNotEmpty)
                          (song['thumbnail']!.startsWith('file://')
                              ? Image.file(
                                  File(
                                    song['thumbnail']!.replaceFirst(
                                      'file://',
                                      '',
                                    ),
                                  ),
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) =>
                                      _buildAudioBadge(format),
                                )
                              : Image.network(
                                  song['thumbnail']!,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) =>
                                      _buildAudioBadge(format),
                                ))
                        else
                          _buildAudioBadge(format),
                        if (isCurrent)
                          Container(
                            color: Colors.black54,
                            child: Center(
                              child: AnimatedEqualizer(
                                isPlaying: _musicService.isPlaying,
                                color: Theme.of(context).primaryColor,
                                size: 20,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                title: Text(
                  song['title'] ?? 'Unknown Title',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isCurrent
                        ? Theme.of(context).primaryColor
                        : Colors.white,
                    fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
                    fontSize: 15,
                  ),
                ),
                subtitle: Text(
                  '${song['author'] ?? 'Device Audio'} • $format • $sizeFormatted',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                trailing: IconButton(
                  icon: const Icon(
                    Icons.delete_outline_rounded,
                    color: Colors.white38,
                    size: 20,
                  ),
                  tooltip: 'Remove from device index',
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    final id = song['id'];
                    if (id != null) {
                      deviceService.removeSong(id);
                    }
                  },
                ),
                onTap: () {
                  HapticFeedback.lightImpact();
                  _musicService.playDeviceSong(
                    song,
                    queue: songs,
                    startIndex: index - 2,
                  );
                },
              );
            },
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // SECTION 4: ALBUMS (Soundtracks & Catalogs)
  // ---------------------------------------------------------------------------

  Widget _buildAlbumsSection({required bool isWide}) {
    final albums = _getDerivedAlbums();

    if (albums.isEmpty) {
      return _buildEmptyState(
        icon: Icons.album_outlined,
        title: 'No albums found in your library',
        subtitle:
            'Songs saved in your favorites, playlists, or offline storage with album metadata will automatically organize here.',
      );
    }

    if (isWide) {
      return GridView.builder(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 160),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 220,
          crossAxisSpacing: 14,
          mainAxisSpacing: 14,
          childAspectRatio: 0.76,
        ),
        itemCount: albums.length,
        itemBuilder: (context, index) {
          final album = albums[index];
          return _buildAlbumCard(album);
        },
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 160, top: 10),
      itemCount: albums.length,
      itemBuilder: (context, index) {
        final album = albums[index];
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 52,
              height: 52,
              child: album.thumbnail.isNotEmpty
                  ? Image.network(
                      album.thumbnail,
                      fit: BoxFit.cover,
                      cacheWidth: 120,
                      cacheHeight: 120,
                      errorBuilder: (_, _, _) => Container(
                        color: const Color(0xFF1E1E28),
                        child: const Icon(
                          Icons.album_rounded,
                          color: Colors.white54,
                        ),
                      ),
                    )
                  : Container(
                      color: const Color(0xFF1E1E28),
                      child: const Icon(
                        Icons.album_rounded,
                        color: Colors.white54,
                      ),
                    ),
            ),
          ),
          title: Text(
            album.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              color: Colors.white,
              fontSize: 14.5,
              letterSpacing: -0.2,
            ),
          ),
          subtitle: Text(
            '${album.artist} • ${album.songs.length} tracks',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 12.5,
            ),
          ),
          trailing: IconButton(
            icon: const Icon(
              Icons.play_circle_fill_rounded,
              color: Colors.white,
              size: 32,
            ),
            onPressed: () {
              HapticFeedback.lightImpact();
              _playAlbum(album);
            },
          ),
          onTap: () {
            HapticFeedback.lightImpact();
            _selectedAlbum.value = album;
          },
        );
      },
    );
  }

  Widget _buildAlbumCard(LibraryAlbum album) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () {
        HapticFeedback.lightImpact();
        _selectedAlbum.value = album;
      },
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF161622),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.06),
            width: 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    album.thumbnail.isNotEmpty
                        ? Image.network(
                            album.thumbnail,
                            fit: BoxFit.cover,
                            cacheWidth: 260,
                            cacheHeight: 260,
                            errorBuilder: (_, _, _) => Container(
                              color: const Color(0xFF222230),
                              child: const Icon(
                                Icons.album_rounded,
                                color: Colors.white38,
                                size: 40,
                              ),
                            ),
                          )
                        : Container(
                            color: const Color(0xFF222230),
                            child: const Icon(
                              Icons.album_rounded,
                              color: Colors.white38,
                              size: 40,
                            ),
                          ),
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: GestureDetector(
                        onTap: () {
                          HapticFeedback.lightImpact();
                          _playAlbum(album);
                        },
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black45,
                                blurRadius: 8,
                                offset: Offset(0, 3),
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.play_arrow_rounded,
                            color: Colors.black,
                            size: 20,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              album.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 13.5,
                letterSpacing: -0.2,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '${album.artist} • ${album.songs.length} tracks',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.55),
                fontSize: 11.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAlbumDetailView(LibraryAlbum album) {
    return Column(
      children: [
        // Album Detail Top Header
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 16, 6),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                tooltip: 'Back to Albums',
                onPressed: () {
                  HapticFeedback.lightImpact();
                  _selectedAlbum.value = null;
                },
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  album.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 18,
                    letterSpacing: -0.4,
                  ),
                ),
              ),
            ],
          ),
        ),

        // Action Header (Play All, Shuffle)
        _buildActionHeader(
          count: album.songs.length,
          onPlayAll: () {
            HapticFeedback.lightImpact();
            _playAlbum(album, startIndex: 0);
          },
          onShuffle: () {
            HapticFeedback.lightImpact();
            _playAlbum(album, startIndex: 0, shuffle: true);
          },
        ),

        // Album Tracklist
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 160, top: 4),
            itemCount: album.songs.length,
            itemBuilder: (context, index) {
              final song = album.songs[index];
              final songId = (song['id'] as String?) ?? '';
              final isCurrent = _musicService.currentSong?.id.value == songId;

              return ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                leading: Text(
                  '${index + 1}',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.45),
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                title: Text(
                  (song['title'] as String?) ?? 'Unknown Track',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: isCurrent ? _prefs.themeColor : Colors.white,
                    fontSize: 14.5,
                    letterSpacing: -0.2,
                  ),
                ),
                subtitle: Text(
                  (song['author'] as String?) ?? album.artist,
                  maxLines: 1,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 12.5,
                  ),
                ),
                trailing: isCurrent
                    ? AnimatedEqualizer(
                        isPlaying: _musicService.isPlaying,
                        size: 20,
                      )
                    : const Icon(
                        Icons.play_circle_fill_rounded,
                        color: Colors.white30,
                        size: 24,
                      ),
                onTap: () {
                  HapticFeedback.lightImpact();
                  _playAlbum(album, startIndex: index);
                },
              );
            },
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // SECTION 5: SPOTIFY IMPORTS
  // ---------------------------------------------------------------------------

  Widget _buildSpotifyImportsSection({required bool isWide}) {
    final spotifyPlaylists = _getSpotifyPlaylists();
    final isImporting = _spotifyService.isImporting;

    return Column(
      children: [
        // Live Real-Time Background Import Banner if actively importing
        if (isImporting)
          Container(
            margin: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF161622),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: const Color(0xFF1DB954).withValues(alpha: 0.5),
                width: 1,
              ),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    value: _spotifyService.overallProgress > 0
                        ? _spotifyService.overallProgress
                        : null,
                    strokeWidth: 2.6,
                    color: const Color(0xFF1DB954),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _spotifyService.currentPlaylistName.isNotEmpty
                            ? 'Importing "${_spotifyService.currentPlaylistName}"'
                            : 'Importing Spotify Content...',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      if (_spotifyService.currentTrackName.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          _spotifyService.currentTrackName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.65),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),

        // Section Actions Bar: Import New Shortcut & Playlist Count
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  '${spotifyPlaylists.length} Imported Playlists',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.sync_rounded, size: 16),
                label: const Text('Import from Spotify / CSV'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: BorderSide(color: Colors.white.withValues(alpha: 0.22)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                ),
                onPressed: () {
                  HapticFeedback.lightImpact();
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const SpotifyImportScreen(),
                    ),
                  );
                },
              ),
            ],
          ),
        ),

        // Playlists List or Empty State
        Expanded(
          child: spotifyPlaylists.isEmpty
              ? _buildEmptyState(
                  icon: Icons.sync_alt_rounded,
                  title: 'No Spotify playlists imported yet',
                  subtitle:
                      'Transfer public Spotify playlist links, your library, or Exportify CSV/ZIP archives into DilSe with high-fidelity studio matching.',
                  action: ElevatedButton.icon(
                    icon: const Icon(Icons.download_rounded, size: 18),
                    label: const Text('Import from Spotify / Exportify'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                    ),
                    onPressed: () {
                      HapticFeedback.lightImpact();
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const SpotifyImportScreen(),
                        ),
                      );
                    },
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 160, top: 4),
                  itemCount: spotifyPlaylists.length,
                  itemBuilder: (context, index) {
                    final playlist = spotifyPlaylists[index];
                    final name =
                        (playlist['name'] as String?) ?? 'Unknown Playlist';
                    final songs = List<Map<String, dynamic>>.from(
                      playlist['songs'] ?? [],
                    );
                    final id = (playlist['id'] as String?) ?? '';
                    final firstThumbnail = songs.isNotEmpty
                        ? songs.first['thumbnail'] as String?
                        : null;

                    return ListTile(
                      key: ValueKey('spotify_playlist_row_$id'),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            color: const Color(0xFF161622),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.08),
                              width: 1,
                            ),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child:
                              firstThumbnail != null &&
                                  firstThumbnail.isNotEmpty
                              ? Image.network(
                                  firstThumbnail,
                                  fit: BoxFit.cover,
                                  cacheWidth: 120,
                                  cacheHeight: 120,
                                  errorBuilder: (_, _, _) => const Icon(
                                    Icons.queue_music_rounded,
                                    color: Colors.white60,
                                    size: 26,
                                  ),
                                )
                              : const Icon(
                                  Icons.queue_music_rounded,
                                  color: Colors.white60,
                                  size: 26,
                                ),
                        ),
                      ),
                      title: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          fontSize: 15,
                          letterSpacing: -0.2,
                        ),
                      ),
                      subtitle: Text(
                        '${songs.length} tracks • Spotify Ingested',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.6),
                          fontSize: 13,
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            key: ValueKey('spotify_playlist_play_$id'),
                            icon: const Icon(
                              Icons.play_circle_fill_rounded,
                              color: Colors.white,
                              size: 36,
                            ),
                            tooltip: 'Play playlist',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 40,
                              minHeight: 40,
                            ),
                            onPressed: songs.isEmpty
                                ? null
                                : () {
                                    HapticFeedback.lightImpact();
                                    _musicService.playCustomPlaylist(id, 0);
                                  },
                          ),
                          const SizedBox(width: 4),
                          PlaylistActionMenu(
                            key: ValueKey('spotify_playlist_more_$id'),
                            playlistId: id,
                            playlistName: name,
                            isSpotifyImport: true,
                            onRename: () => _showRenamePlaylistDialog(id, name),
                            onDelete: () => _showDeletePlaylistDialog(id, name),
                            onToggleSource: () {
                              final nowSpotify = _isSpotifyPlaylist(playlist);
                              if (nowSpotify) {
                                _prefs.unregisterSpotifyPlaylistId(id);
                                _prefs.registerManualPlaylistId(id);
                                _musicService.setPlaylistSource(
                                  id,
                                  isSpotify: false,
                                );
                              } else {
                                _prefs.unregisterManualPlaylistId(id);
                                _prefs.registerSpotifyPlaylistId(id);
                                _musicService.setPlaylistSource(
                                  id,
                                  isSpotify: true,
                                );
                              }
                              setState(() {});
                            },
                          ),
                        ],
                      ),
                      onTap: () {
                        HapticFeedback.lightImpact();
                        if (kIsWeb &&
                            MediaQuery.of(context).size.width >= 1024) {
                          DesktopLayoutState.openPlaylist(id);
                        } else {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  CustomPlaylistScreen(playlistId: id),
                            ),
                          );
                        }
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // SECTION 6: LISTENING HISTORY
  // ---------------------------------------------------------------------------

  Widget _buildHistorySection() {
    final history = _prefs.listeningHistory;

    if (history.isEmpty) {
      return _buildEmptyState(
        icon: Icons.history_toggle_off_rounded,
        title: 'No listening history yet',
        subtitle:
            'Songs you stream will automatically appear here for quick replay.',
      );
    }

    return DilSeScrollbar(
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 160, top: 10),
        itemCount: history.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Text(
                      '${history.length} Recently Played',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    icon: const Icon(
                      Icons.delete_sweep_rounded,
                      size: 16,
                      color: Colors.white54,
                    ),
                    label: const Text(
                      'Clear',
                      style: TextStyle(color: Colors.white54, fontSize: 13),
                    ),
                    onPressed: () {
                      HapticFeedback.lightImpact();
                      _prefs.clearListeningHistory();
                    },
                  ),
                ],
              ),
            );
          }

          final song = history[index - 1];
          final songId = song['id'] ?? '';
          final isCurrent = _musicService.currentSong?.id.value == songId;

          return ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 4,
            ),
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 52,
                height: 52,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.network(
                      song['thumbnail'] ?? '',
                      fit: BoxFit.cover,
                      cacheWidth: 120,
                      cacheHeight: 120,
                      errorBuilder: (_, _, _) => Container(
                        color: const Color(0xFF1E1E28),
                        child: const Icon(
                          Icons.music_note,
                          color: Colors.white54,
                        ),
                      ),
                    ),
                    if (isCurrent)
                      Container(
                        color: Colors.black54,
                        child: Center(
                          child: AnimatedEqualizer(
                            isPlaying: _musicService.isPlaying,
                            size: 22,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            title: Text(
              song['title'] ?? 'Unknown Track',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: Colors.white,
                fontSize: 14.5,
                letterSpacing: -0.2,
              ),
            ),
            subtitle: Text(
              song['author'] ?? 'Unknown Artist',
              maxLines: 1,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: 12.5,
              ),
            ),
            trailing: const Icon(
              Icons.play_circle_fill_rounded,
              color: Colors.white38,
              size: 24,
            ),
            onTap: () {
              HapticFeedback.lightImpact();
              _musicService.playHistorySong(song);
            },
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // REUSABLE ACTION HEADER & EMPTY STATES
  // ---------------------------------------------------------------------------

  Widget _buildActionHeader({
    required int count,
    required VoidCallback onPlayAll,
    required VoidCallback onShuffle,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: ElevatedButton.icon(
              icon: const Icon(
                Icons.play_arrow_rounded,
                color: Colors.black,
                size: 20,
              ),
              label: Text(
                'Play All ($count)',
                style: const TextStyle(
                  color: Colors.black,
                  fontWeight: FontWeight.w700,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: onPlayAll,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(
                Icons.shuffle_rounded,
                color: Colors.white70,
                size: 18,
              ),
              label: const Text(
                'Shuffle',
                style: TextStyle(
                  color: Colors.white70,
                  fontWeight: FontWeight.w600,
                ),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: onShuffle,
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // SECTION: FOLLOWED ARTISTS
  // ---------------------------------------------------------------------------

  Widget _buildFollowedArtistsSection() {
    final followedArtists = _prefs.followedArtists;
    if (followedArtists.isEmpty) {
      return _buildEmptyState(
        icon: Icons.people_outline_rounded,
        title: 'No followed artists yet',
        subtitle: 'Follow your favorite artists from their profile screens.',
      );
    }

    return DilSeScrollbar(
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 160, top: 10),
        itemCount: followedArtists.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                '${followedArtists.length} ${followedArtists.length == 1 ? 'Followed Artist' : 'Followed Artists'}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  letterSpacing: -0.2,
                ),
              ),
            );
          }

          final artistName = followedArtists[index - 1];
          final artistItem = DynamicArtistService().findArtist(artistName);

          return ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 4,
            ),
            leading: Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.18),
                  width: 1.2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: ClipOval(
                child: artistItem != null && artistItem.imageUrl.isNotEmpty
                    ? Image.network(
                        artistItem.imageUrl,
                        fit: BoxFit.cover,
                        cacheWidth: 120,
                        cacheHeight: 120,
                        errorBuilder: (_, _, _) =>
                            _buildArtistAvatarFallback(artistName),
                      )
                    : _buildArtistAvatarFallback(artistName),
              ),
            ),
            title: Text(
              artistItem?.name ?? artistName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: Colors.white,
                fontSize: 15,
                letterSpacing: -0.2,
              ),
            ),
            subtitle: Text(
              artistItem?.genre ?? 'Followed Artist',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.55),
                fontSize: 12.5,
              ),
            ),
            trailing: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.15),
                  width: 0.8,
                ),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check_rounded, size: 12, color: Colors.white70),
                  SizedBox(width: 4),
                  Text(
                    'Following',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            onTap: () {
              HapticFeedback.lightImpact();
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ArtistProfileScreen(
                    artist: artistItem,
                    artistName: artistItem?.name ?? artistName,
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildArtistAvatarFallback(String name) {
    final initial = name.trim().isNotEmpty ? name.trim()[0].toUpperCase() : 'A';
    return Container(
      color: const Color(0xFF1E1E28),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 18,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String subtitle,
    Widget? action,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                color: const Color(0xFF161622),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white12, width: 1),
              ),
              child: Icon(icon, size: 48, color: Colors.white54),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.55),
                fontSize: 13,
                height: 1.4,
              ),
              textAlign: TextAlign.center,
            ),
            if (action != null) ...[const SizedBox(height: 18), action],
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // PLAYLIST DIALOGS
  // ---------------------------------------------------------------------------

  void _showCreatePlaylistDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E28),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Create New Playlist',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'Playlist name',
            hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.4)),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(
                color: Colors.white.withValues(alpha: 0.2),
              ),
            ),
            focusedBorder: const UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.white70),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Colors.white54),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                final newId = _musicService.createPlaylist(
                  name,
                  isSpotify: false,
                  source: 'custom',
                );
                _prefs.registerManualPlaylistId(newId);
                _prefs.unregisterSpotifyPlaylistId(newId);
                Navigator.pop(ctx);
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  void _showRenamePlaylistDialog(String id, String currentName) {
    PlaylistActionMenu.showRenameDialog(
      context,
      playlistId: id,
      currentName: currentName,
      onRenamed: (_) {
        if (mounted) setState(() {});
      },
    );
  }

  void _showDeletePlaylistDialog(String id, String name) {
    PlaylistActionMenu.showDeleteDialog(
      context,
      playlistId: id,
      playlistName: name,
      onDeleted: () {
        if (mounted) setState(() {});
      },
    );
  }
}
