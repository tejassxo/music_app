import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:just_audio/just_audio.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../services/music_service.dart';
import '../services/preferences_service.dart';
import '../services/album_color_deriver.dart';
import '../widgets/vinyl_record_player.dart';
import '../widgets/waveform_scrubber.dart';
import '../widgets/song_options_bottom_sheet.dart';
import '../widgets/equalizer_bottom_sheet.dart';
import '../widgets/animated_lyrics.dart';
import '../widgets/bug_report_button.dart';
import '../services/bug_report_service.dart';
import '../services/screen_wake_service.dart';
import '../widgets/responsive_wrapper.dart';
import 'album_screen.dart';
import 'artist_profile_screen.dart';
import '../services/dynamic_artist_service.dart';
import '../services/canonical_song_dedup.dart';

enum LandscapeActiveTab { none, lyrics, queue, more }

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  final MusicService _musicService = MusicService();
  final PreferencesService _prefs = PreferencesService();

  late PageController _pageController;
  int _activePageIndex = 0;
  bool _isUserDraggingPage = false;
  bool _showLyrics = false;
  LandscapeActiveTab _landscapeTab = LandscapeActiveTab.none;

  @override
  void initState() {
    super.initState();
    _musicService.addListener(_onStateChanged);
    _prefs.addListener(_onStateChanged);

    final initialPage = _musicService.playlist.isNotEmpty
        ? _musicService.currentIndex.clamp(0, _musicService.playlist.length - 1)
        : 0;
    _activePageIndex = initialPage;
    _pageController = PageController(
      initialPage: initialPage,
      viewportFraction: 0.82,
    );
    _pageController.addListener(_onPageScrolled);
  }

  @override
  void dispose() {
    ScreenWakeService.disableWakeLock('lyrics_screen');
    _pageController.removeListener(_onPageScrolled);
    _pageController.dispose();
    _musicService.removeListener(_onStateChanged);
    _prefs.removeListener(_onStateChanged);
    super.dispose();
  }

  void _onPageScrolled() {
    if (_pageController.hasClients &&
        _pageController.position.hasContentDimensions) {
      final page =
          (_pageController.page ?? _musicService.currentIndex.toDouble())
              .round();
      if (page != _activePageIndex && page >= 0) {
        setState(() {
          _activePageIndex = page;
        });
      }
    }
  }

  void _onStateChanged() {
    if (!mounted) return;
    if (_pageController.hasClients &&
        _pageController.position.hasContentDimensions) {
      final currentPage =
          _pageController.page?.round() ?? _musicService.currentIndex;
      if (currentPage != _musicService.currentIndex && !_isUserDraggingPage) {
        if (_showLyrics) {
          // In lyrics mode, silently sync carousel in the background with zero lag
          _pageController.jumpToPage(_musicService.currentIndex);
        } else {
          _pageController.animateToPage(
            _musicService.currentIndex,
            duration: const Duration(milliseconds: 380),
            curve: Curves.easeOutCubic,
          );
        }
      }
    }
    if (!_isUserDraggingPage && _musicService.playlist.isNotEmpty) {
      _activePageIndex = _musicService.currentIndex.clamp(
        0,
        _musicService.playlist.length - 1,
      );
    }
    setState(() {});
  }

  String _formatDuration(Duration? duration) {
    if (duration == null) return '0:00';
    final nonNegative = duration.isNegative ? Duration.zero : duration;
    final hours = nonNegative.inHours;
    final minutes = nonNegative.inMinutes.remainder(60);
    final seconds = (nonNegative.inSeconds.remainder(
      60,
    )).toString().padLeft(2, '0');
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:$seconds';
    }
    return '$minutes:$seconds';
  }

  void _toggleLyrics(Video song) {
    HapticFeedback.lightImpact();
    setState(() {
      _showLyrics = !_showLyrics;
    });
    if (_showLyrics) {
      ScreenWakeService.enableWakeLock('lyrics_screen');
      _musicService.fetchLyrics(song);
    } else {
      ScreenWakeService.disableWakeLock('lyrics_screen');
      // Ensure PageView is locked to the current song index immediately upon dismissal
      if (_pageController.hasClients &&
          _pageController.page?.round() != _musicService.currentIndex) {
        _pageController.jumpToPage(_musicService.currentIndex);
      }
    }
  }

  void _setLandscapeTab(LandscapeActiveTab tab) {
    HapticFeedback.lightImpact();
    setState(() {
      if (_landscapeTab == tab) {
        _landscapeTab = LandscapeActiveTab.none;
      } else {
        _landscapeTab = tab;
      }
      if (_landscapeTab == LandscapeActiveTab.lyrics) {
        _showLyrics = true;
      } else if (tab == LandscapeActiveTab.lyrics &&
          _landscapeTab == LandscapeActiveTab.none) {
        _showLyrics = false;
      }
    });

    final song = _musicService.currentSong;
    if (_landscapeTab == LandscapeActiveTab.lyrics) {
      ScreenWakeService.enableWakeLock('lyrics_screen');
      if (song != null) {
        _musicService.fetchLyrics(song);
      }
    } else if (!_showLyrics) {
      ScreenWakeService.disableWakeLock('lyrics_screen');
    }
  }

  void _showQueueSheet(BuildContext context) {
    HapticFeedback.lightImpact();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final playlist = _musicService.playlist;
            final currentIndex = _musicService.currentIndex;

            return Container(
              height: MediaQuery.of(context).size.height * 0.78,
              decoration: BoxDecoration(
                color: const Color(0xFF14141E).withValues(alpha: 0.96),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              ),
              child: Column(
                children: [
                  const SizedBox(height: 12),
                  Container(
                    width: 38,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white30,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 14,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Up Next',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                letterSpacing: -0.3,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Drag ☰ on the left to change priority',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.5),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white12,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '${playlist.length} Tracks',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(color: Colors.white12, height: 1),
                  Expanded(
                    child: playlist.isEmpty
                        ? const Center(
                            child: Text(
                              'Queue is empty',
                              style: TextStyle(color: Colors.white54),
                            ),
                          )
                        : ReorderableListView.builder(
                            buildDefaultDragHandles: false,
                            padding: const EdgeInsets.symmetric(
                              vertical: 8,
                              horizontal: 14,
                            ),
                            itemCount: playlist.length,
                            // ignore: deprecated_member_use
                            onReorder: (oldIndex, newIndex) {
                              HapticFeedback.selectionClick();
                              _musicService.reorderQueue(oldIndex, newIndex);
                              setSheetState(() {});
                            },
                            itemBuilder: (context, index) {
                              final song = playlist[index];
                              final isCurrent = index == currentIndex;
                              final hdThumbnail = MusicService.getHdThumbnail(
                                song.id.value,
                              );

                              return Container(
                                key: ValueKey('${song.id.value}_$index'),
                                margin: const EdgeInsets.symmetric(vertical: 4),
                                decoration: BoxDecoration(
                                  color: isCurrent
                                      ? Theme.of(
                                          context,
                                        ).primaryColor.withValues(alpha: 0.16)
                                      : const Color(0xFF1B1B26),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: isCurrent
                                        ? Theme.of(
                                            context,
                                          ).primaryColor.withValues(alpha: 0.45)
                                        : Colors.white.withValues(alpha: 0.07),
                                    width: 1,
                                  ),
                                ),
                                child: Material(
                                  color: Colors.transparent,
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(14),
                                    onTap: () {
                                      Navigator.pop(context);
                                      _musicService.playPlaylist(
                                        playlist,
                                        index,
                                      );
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                        vertical: 6,
                                      ),
                                      child: Row(
                                        children: [
                                          // Far left 3-line handle for priority reordering
                                          ReorderableDragStartListener(
                                            index: index,
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 10,
                                                    vertical: 12,
                                                  ),
                                              child: const Icon(
                                                Icons.menu_rounded,
                                                color: Colors.white60,
                                                size: 20,
                                              ),
                                            ),
                                          ),
                                          ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            child: Image.network(
                                              hdThumbnail,
                                              width: 44,
                                              height: 44,
                                              cacheWidth: 100,
                                              cacheHeight: 100,
                                              fit: BoxFit.cover,
                                              errorBuilder: (_, _, _) =>
                                                  Image.network(
                                                    song.thumbnails.lowResUrl,
                                                    width: 44,
                                                    height: 44,
                                                    cacheWidth: 100,
                                                    cacheHeight: 100,
                                                    fit: BoxFit.cover,
                                                  ),
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Text(
                                                  song.title,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    color: isCurrent
                                                        ? Theme.of(
                                                            context,
                                                          ).primaryColor
                                                        : Colors.white,
                                                    fontWeight: isCurrent
                                                        ? FontWeight.bold
                                                        : FontWeight.w600,
                                                    fontSize: 13.5,
                                                  ),
                                                ),
                                                const SizedBox(height: 2),
                                                Text(
                                                  song.author,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    color: isCurrent
                                                        ? Theme.of(context)
                                                              .primaryColor
                                                              .withValues(
                                                                alpha: 0.8,
                                                              )
                                                        : Colors.white54,
                                                    fontSize: 12,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          if (isCurrent)
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                right: 6,
                                              ),
                                              child: Icon(
                                                Icons.equalizer_rounded,
                                                color: Theme.of(
                                                  context,
                                                ).primaryColor,
                                                size: 22,
                                              ),
                                            ),
                                          IconButton(
                                            icon: const Icon(
                                              Icons.more_vert_rounded,
                                              color: Colors.white38,
                                              size: 18,
                                            ),
                                            padding: EdgeInsets.zero,
                                            constraints: const BoxConstraints(
                                              minWidth: 32,
                                              minHeight: 32,
                                            ),
                                            onPressed: () {
                                              showSongOptionsBottomSheet(
                                                context,
                                                song,
                                              );
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
                                              minWidth: 32,
                                              minHeight: 32,
                                            ),
                                            onPressed: () {
                                              HapticFeedback.lightImpact();
                                              _musicService.removeFromQueue(
                                                index,
                                              );
                                              setSheetState(() {});
                                            },
                                          ),
                                          const SizedBox(width: 4),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showSleepTimerSheet(BuildContext context) {
    HapticFeedback.lightImpact();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: BoxDecoration(
            color: const Color(0xFF14141E).withValues(alpha: 0.96),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 38,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.white30,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Sleep Timer',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (_musicService.isSleepTimerActive)
                    TextButton(
                      onPressed: () {
                        _musicService.cancelSleepTimer();
                        Navigator.pop(context);
                      },
                      child: const Text(
                        'Turn Off',
                        style: TextStyle(color: Colors.redAccent),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              _buildSleepOption(
                context,
                '15 minutes',
                const Duration(minutes: 15),
              ),
              _buildSleepOption(
                context,
                '30 minutes',
                const Duration(minutes: 30),
              ),
              _buildSleepOption(
                context,
                '45 minutes',
                const Duration(minutes: 45),
              ),
              _buildSleepOption(context, '1 hour', const Duration(hours: 1)),
              ListTile(
                leading: const Icon(
                  Icons.music_off_outlined,
                  color: Colors.white70,
                ),
                title: const Text(
                  'End of current track',
                  style: TextStyle(color: Colors.white),
                ),
                trailing: _musicService.stopAtEndOfTrack
                    ? const Icon(Icons.check, color: Color(0xFF1DB954))
                    : null,
                onTap: () {
                  _musicService.setStopAtEndOfTrack(true);
                  Navigator.pop(context);
                },
              ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSleepOption(
    BuildContext context,
    String label,
    Duration duration,
  ) {
    final isSelected =
        _musicService.sleepRemaining != null &&
        (_musicService.sleepRemaining!.inMinutes - duration.inMinutes).abs() <
            1;

    return ListTile(
      leading: const Icon(Icons.timer_outlined, color: Colors.white70),
      title: Text(label, style: const TextStyle(color: Colors.white)),
      trailing: isSelected
          ? const Icon(Icons.check, color: Color(0xFF1DB954))
          : null,
      onTap: () {
        _musicService.startSleepTimer(duration);
        Navigator.pop(context);
      },
    );
  }

  Future<void> _navigateToAlbum(Video song) async {
    HapticFeedback.lightImpact();

    // 1. Direct in-memory cached JioAlbum
    final cachedAlbum = MusicService.getCachedAlbum(song.id.value);
    if (cachedAlbum != null && cachedAlbum.songs.isNotEmpty) {
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => AlbumScreen(
            album: cachedAlbum,
            albumId: cachedAlbum.id,
            albumTitle: cachedAlbum.title,
            albumArtwork: cachedAlbum.artwork,
            albumArtist: cachedAlbum.artist,
          ),
        ),
      );
      return;
    }

    // 2. Cached album ID or title, or extracted movie title
    final cachedId = MusicService.getCachedAlbumId(song.id.value);
    final cachedTitle =
        MusicService.getCachedAlbumTitle(song.id.value) ??
        MusicService.extractMovieOrAlbumTitle(song.title);

    if ((cachedId != null && cachedId.isNotEmpty) ||
        (cachedTitle != null && cachedTitle.isNotEmpty)) {
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => AlbumScreen(
            albumId: cachedId ?? '',
            albumTitle: cachedTitle ?? '',
            albumArtwork: MusicService.getHdThumbnail(song.id.value),
            albumArtist: song.author,
          ),
        ),
      );
      return;
    }

    // 3. On-demand resolution for tracks without pre-cached album tags
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Finding album for this track...'),
        duration: Duration(milliseconds: 1500),
      ),
    );

    final resolved = await _musicService.resolveAlbumForSong(song);
    if (!mounted) return;

    if (resolved != null && resolved.songs.isNotEmpty) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => AlbumScreen(
            album: resolved,
            albumId: resolved.id,
            albumTitle: resolved.title,
            albumArtwork: resolved.artwork,
            albumArtist: resolved.artist,
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('No album found for "${song.title}".'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  String _resolveArtistName(Video song) {
    final direct = song.author.trim();

    // 1. Direct match with curated artist catalog or aliases
    if (direct.isNotEmpty && direct.toLowerCase() != 'unknown artist') {
      final directMatch = DynamicArtistService().findArtist(direct);
      if (directMatch != null) return directMatch.name;
    }

    // 2. Extract artist candidate from song title / context keywords
    final ctx = CanonicalSongDedup.extractSongContext(song.title, song.author);
    final ctxArtist = (ctx['artist'] as String?)?.trim() ?? '';
    if (ctxArtist.isNotEmpty) {
      final ctxMatch = DynamicArtistService().findArtist(ctxArtist);
      if (ctxMatch != null) return ctxMatch.name;

      final lowerAuthor = direct.toLowerCase();
      // If author is a channel or record label, prefer the extracted artist from title
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

  void _navigateToArtist(Video song) {
    HapticFeedback.lightImpact();
    final artistName = _resolveArtistName(song);
    final artistItem = DynamicArtistService().findArtist(artistName);

    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ArtistProfileScreen(
          artist: artistItem,
          artistName: artistItem?.name ?? artistName,
        ),
      ),
    );
  }

  void _showCurrentSongActionsSheet(BuildContext context, Video song) {
    HapticFeedback.lightImpact();
    final hdThumbnail = MusicService.getHdThumbnail(song.id.value);

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final isLiked = _musicService.likedSongs.any(
              (s) => s['id'] == song.id.value,
            );
            final isDownloaded = _musicService.downloadedSongs.any(
              (s) => s['id'] == song.id.value,
            );

            return Container(
              padding: const EdgeInsets.only(top: 14, bottom: 28),
              decoration: BoxDecoration(
                color: const Color(0xFF14141E).withValues(alpha: 0.96),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              ),
              child: SafeArea(
                top: false,
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Drag pill
                      Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Song Header Info
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Row(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: Image.network(
                                hdThumbnail,
                                width: 52,
                                height: 52,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => Container(
                                  width: 52,
                                  height: 52,
                                  color: const Color(0xFF1E1E28),
                                  child: const Icon(
                                    Icons.music_note,
                                    color: Colors.white54,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    song.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 15.5,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: -0.2,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    song.author,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: Colors.white.withValues(
                                        alpha: 0.65,
                                      ),
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 14),
                      const Divider(color: Colors.white10, height: 1),
                      const SizedBox(height: 8),

                      // 1. Sleep Timer
                      _buildSongActionTile(
                        icon: Icons.bedtime_rounded,
                        iconColor: _musicService.isSleepTimerActive
                            ? Theme.of(context).primaryColor
                            : Colors.white,
                        title: 'Sleep Timer',
                        subtitle: _musicService.isSleepTimerActive
                            ? 'Active (${_musicService.sleepTimerLabel})'
                            : 'Set auto-stop timer',
                        trailing: _musicService.isSleepTimerActive
                            ? Icon(
                                Icons.check_circle_rounded,
                                color: Theme.of(context).primaryColor,
                                size: 20,
                              )
                            : const Icon(
                                Icons.chevron_right_rounded,
                                color: Colors.white30,
                                size: 20,
                              ),
                        onTap: () {
                          Navigator.pop(ctx);
                          _showSleepTimerSheet(context);
                        },
                      ),

                      // 2. Add to Playlist
                      _buildSongActionTile(
                        icon: Icons.playlist_add_rounded,
                        title: 'Add to Playlist',
                        subtitle: 'Save to your custom playlists',
                        trailing: const Icon(
                          Icons.chevron_right_rounded,
                          color: Colors.white30,
                          size: 20,
                        ),
                        onTap: () {
                          Navigator.pop(ctx);
                          showAddToPlaylistSheet(context, song);
                        },
                      ),

                      // 2b. View Artist
                      _buildSongActionTile(
                        icon: Icons.person_rounded,
                        iconColor: const Color(0xFF1DB954),
                        title: 'View Artist',
                        subtitle:
                            'Explore full discography for ${_resolveArtistName(song)}',
                        trailing: const Icon(
                          Icons.chevron_right_rounded,
                          color: Colors.white30,
                          size: 20,
                        ),
                        onTap: () {
                          Navigator.pop(ctx);
                          _navigateToArtist(song);
                        },
                      ),

                      // 2c. Go to Album
                      _buildSongActionTile(
                        icon: Icons.album_rounded,
                        iconColor: const Color(0xFF8E2DE2),
                        title: 'Go to Album',
                        subtitle:
                            MusicService.getCachedAlbumTitle(song.id.value) ??
                            MusicService.extractMovieOrAlbumTitle(song.title) ??
                            'View full album & tracks',
                        trailing: const Icon(
                          Icons.chevron_right_rounded,
                          color: Colors.white30,
                          size: 20,
                        ),
                        onTap: () {
                          Navigator.pop(ctx);
                          _navigateToAlbum(song);
                        },
                      ),

                      // 3. Like Song
                      _buildSongActionTile(
                        icon: isLiked
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        iconColor: isLiked
                            ? const Color(0xFFFA2D48)
                            : Colors.white,
                        title: isLiked ? 'Liked Song' : 'Like Song',
                        subtitle: isLiked
                            ? 'Saved in your favorites ❤️'
                            : 'Save to Liked Songs',
                        trailing: isLiked
                            ? const Icon(
                                Icons.check_rounded,
                                color: Color(0xFFFA2D48),
                                size: 20,
                              )
                            : null,
                        onTap: () {
                          HapticFeedback.lightImpact();
                          _musicService.toggleLike(song);
                          setSheetState(() {});
                          setState(() {});
                        },
                      ),

                      // 4. Download
                      _buildSongActionTile(
                        icon: isDownloaded
                            ? Icons.download_done_rounded
                            : Icons.download_for_offline_rounded,
                        iconColor: isDownloaded
                            ? const Color(0xFF1DB954)
                            : Colors.white,
                        title: isDownloaded ? 'Downloaded' : 'Download',
                        subtitle: isDownloaded
                            ? 'Available offline'
                            : 'Save audio file locally',
                        trailing: _musicService.isDownloading
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : (isDownloaded
                                  ? const Icon(
                                      Icons.check_rounded,
                                      color: Color(0xFF1DB954),
                                      size: 20,
                                    )
                                  : null),
                        onTap: () async {
                          if (isDownloaded) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Song is already downloaded offline',
                                ),
                              ),
                            );
                            return;
                          }
                          Navigator.pop(ctx);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Starting download...'),
                            ),
                          );
                          final success = await _musicService.downloadSong(
                            song,
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  success
                                      ? 'Saved to Offline Library!'
                                      : 'Download failed.',
                                ),
                              ),
                            );
                          }
                        },
                      ),

                      // 5. Share
                      _buildSongActionTile(
                        icon: Icons.share_rounded,
                        title: 'Share',
                        subtitle: 'Copy link or song details',
                        trailing: const Icon(
                          Icons.copy_rounded,
                          color: Colors.white30,
                          size: 18,
                        ),
                        onTap: () {
                          Navigator.pop(ctx);
                          Clipboard.setData(
                            ClipboardData(
                              text:
                                  '${song.title} - ${song.author}\n${song.url}',
                            ),
                          );
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Song link copied to clipboard!'),
                            ),
                          );
                        },
                      ),

                      // 6. Report a Bug (Music player options at last)
                      _buildSongActionTile(
                        icon: Icons.bug_report_rounded,
                        iconColor: Colors.redAccent,
                        title: 'Report a Bug',
                        subtitle: 'Found an issue with playback or app?',
                        trailing: const Icon(
                          Icons.chevron_right_rounded,
                          color: Colors.white30,
                          size: 20,
                        ),
                        onTap: () {
                          Navigator.pop(ctx);
                          _reportBug(context, song: song);
                        },
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildSongActionTile({
    required IconData icon,
    Color iconColor = Colors.white,
    required String title,
    required String subtitle,
    Widget? trailing,
    required VoidCallback onTap,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: iconColor, size: 22),
      ),
      title: Text(
        title,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
          fontSize: 14.5,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.55),
          fontSize: 12,
        ),
      ),
      trailing: trailing,
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
    );
  }

  Future<void> _reportBug(BuildContext context, {Video? song}) async {
    final osInfo = kIsWeb ? 'Web Browser' : defaultTargetPlatform.name;

    final songDetails = song != null
        ? '\n\n--- Current Playing Song ---\n'
              'Title: ${song.title}\n'
              'Artist: ${song.author}\n'
              'Song ID: ${song.id.value}\n'
              'URL: ${song.url}'
        : '';

    final subject = Uri.encodeComponent('Bug Report: DilSe Music App');
    final body = Uri.encodeComponent(
      'Please describe the bug or issue you encountered:\n\n\n\n'
      '--- Diagnostic Info ---\n'
      'App: DilSe Music v3.4.0\n'
      'Platform: $osInfo'
      '$songDetails',
    );

    final emailLaunchUri = Uri.parse(
      'mailto:charanteja.kondakalla030206@gmail.com,balaamoghraj@gmail.com?subject=$subject&body=$body',
    );

    try {
      if (await canLaunchUrl(emailLaunchUri)) {
        await launchUrl(emailLaunchUri);
      } else {
        await Clipboard.setData(
          const ClipboardData(
            text:
                'charanteja.kondakalla030206@gmail.com, balaamoghraj@gmail.com',
          ),
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Support emails copied to clipboard (charanteja & balaamoghraj)',
              ),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error opening email: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  Widget _buildBarPillButton({
    required BuildContext context,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool isActive = false,
    Color? activeColor,
    int? badgeCount,
  }) {
    final effectiveColor = activeColor ?? Theme.of(context).primaryColor;
    final screenWidth = MediaQuery.of(context).size.width;
    final isCompact = screenWidth < 360;
    final pillPaddingH = isCompact ? 10.0 : 16.0;
    final pillPaddingV = isCompact ? 7.0 : 9.0;
    final pillIconSize = isCompact ? 18.0 : 20.0;
    final pillFontSize = isCompact ? 12.0 : 13.0;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          HapticFeedback.lightImpact();
          onTap();
        },
        borderRadius: BorderRadius.circular(22),
        splashColor: effectiveColor.withValues(alpha: 0.2),
        highlightColor: Colors.white.withValues(alpha: 0.08),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          padding: EdgeInsets.symmetric(
            horizontal: pillPaddingH,
            vertical: pillPaddingV,
          ),
          decoration: BoxDecoration(
            color: isActive
                ? effectiveColor.withValues(alpha: 0.24)
                : Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: isActive
                  ? effectiveColor.withValues(alpha: 0.5)
                  : Colors.white.withValues(alpha: 0.12),
              width: 1.0,
            ),
            boxShadow: isActive
                ? [
                    BoxShadow(
                      color: effectiveColor.withValues(alpha: 0.35),
                      blurRadius: 14,
                      spreadRadius: 1,
                    ),
                  ]
                : [],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(
                    icon,
                    size: pillIconSize,
                    color: isActive
                        ? effectiveColor
                        : Colors.white.withValues(alpha: 0.9),
                  ),
                  if (badgeCount != null && badgeCount > 0)
                    Positioned(
                      top: -6,
                      right: -10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: effectiveColor,
                          borderRadius: BorderRadius.circular(8),
                          boxShadow: [
                            BoxShadow(
                              color: effectiveColor.withValues(alpha: 0.5),
                              blurRadius: 6,
                            ),
                          ],
                        ),
                        child: Text(
                          '$badgeCount',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              SizedBox(width: isCompact ? 6 : 8),
              Text(
                label,
                style: TextStyle(
                  color: isActive
                      ? Colors.white
                      : Colors.white.withValues(alpha: 0.85),
                  fontSize: pillFontSize,
                  fontWeight: isActive ? FontWeight.w700 : FontWeight.w600,
                  letterSpacing: -0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final song = _musicService.currentSong;
    final isPlaying = _musicService.isPlaying;
    final processingState = _musicService.audioPlayer.processingState;
    final isBuffering =
        !kIsWeb &&
        (processingState == ProcessingState.buffering ||
            processingState == ProcessingState.loading);
    final isLoading = !isPlaying && (_musicService.isLoading || isBuffering);
    final isLiked =
        song != null &&
        _musicService.likedSongs.any((s) => s['id'] == song.id.value);
    final artworkStyle = _prefs.artworkStyle;

    if (song == null) {
      return const Scaffold(
        backgroundColor: Color(0xFF0B0B0F),
        body: Center(
          child: Text('No song active', style: TextStyle(color: Colors.white)),
        ),
      );
    }

    final playlist = _musicService.playlist.isNotEmpty
        ? _musicService.playlist
        : [song];
    final activeIndex = _activePageIndex.clamp(0, playlist.length - 1);
    final shownSong = playlist[activeIndex];
    final isCurrentSong = shownSong.id.value == song.id.value;

    final palette = AlbumColorDeriver.getPalette(
      shownSong,
      fallbackDominant: isCurrentSong ? _musicService.dominantColor : null,
      fallbackVibrant: isCurrentSong ? _musicService.vibrantColor : null,
      fallbackDarkVibrant: isCurrentSong
          ? _musicService.darkVibrantColor
          : null,
    );
    final dominantColor = palette.dominant;
    final vibrantColor = palette.vibrant;
    final darkVibrantColor = palette.darkVibrant;

    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    if (isLandscape) {
      return _buildLandscapeLayout(
        context: context,
        song: shownSong,
        isPlaying: isPlaying,
        isLoading: isLoading,
        isLiked: isLiked,
        dominantColor: dominantColor,
        vibrantColor: vibrantColor,
        darkVibrantColor: darkVibrantColor,
        artworkStyle: artworkStyle,
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0B0B0F),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragEnd: (details) {
          if (details.primaryVelocity == null) return;
          if (details.primaryVelocity! < -300) {
            HapticFeedback.lightImpact();
            _showQueueSheet(context);
          } else if (details.primaryVelocity! > 300) {
            HapticFeedback.lightImpact();
            Navigator.pop(context);
          }
        },
        child: Stack(
          children: [
            // 1. Dynamic Adaptive Ambient Background (Static glass styling, GPU-accelerated gradient with zero blur passes)
            Positioned.fill(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeOutCubic,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color.alphaBlend(
                        vibrantColor.withValues(alpha: 0.32),
                        const Color(0xFF0C0C12),
                      ),
                      Color.alphaBlend(
                        dominantColor.withValues(alpha: 0.18),
                        const Color(0xFF08080C),
                      ),
                      Color.alphaBlend(
                        darkVibrantColor.withValues(alpha: 0.20),
                        const Color(0xFF07070A),
                      ),
                    ],
                    stops: const [0.0, 0.52, 1.0],
                  ),
                ),
              ),
            ),

            // Soft Central Ambient Aura directly behind the album artwork
            Positioned(
              top: 80,
              left: 0,
              right: 0,
              height: 480,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeOutCubic,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      vibrantColor.withValues(alpha: 0.28),
                      dominantColor.withValues(alpha: 0.12),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.55, 1.0],
                  ),
                ),
              ),
            ),

            // Top subtle corner ambient highlight
            Positioned(
              top: -60,
              right: -60,
              width: 240,
              height: 240,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeOutCubic,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      dominantColor.withValues(alpha: 0.22),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),

            // 2. Main Player Content
            ResponsiveWrapper(
              maxWidth: 680,
              child: SafeArea(
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: (MediaQuery.of(context).size.width * 0.05)
                        .clamp(12.0, 24.0),
                    vertical: 10,
                  ),
                  child: Column(
                    children: [
                      // Top Grabber & Header Actions
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          IconButton(
                            icon: const Icon(
                              Icons.keyboard_arrow_down_rounded,
                              color: Colors.white70,
                              size: 34,
                            ),
                            onPressed: () {
                              HapticFeedback.lightImpact();
                              Navigator.pop(context);
                            },
                          ),
                          GestureDetector(
                            onTap: () => _showQueueSheet(context),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 8,
                              ),
                              color: Colors.transparent,
                              child: Container(
                                width: 40,
                                height: 5,
                                decoration: BoxDecoration(
                                  color: Colors.white24,
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                            ),
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const BugReportButton(size: 34),
                              const SizedBox(width: 4),
                              IconButton(
                                icon: const Icon(
                                  Icons.tune_rounded,
                                  color: Colors.white,
                                  size: 24,
                                ),
                                tooltip: 'Audio Equalizer',
                                onPressed: () {
                                  HapticFeedback.lightImpact();
                                  EqualizerBottomSheet.show(context);
                                },
                              ),
                            ],
                          ),
                        ],
                      ),

                      const SizedBox(height: 8),

                      // Center Content: Parallel Synced Album Carousel & Lyrics Stack
                      Expanded(
                        flex: 10,
                        child: Center(
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final carouselSize = math.min(
                                constraints.maxWidth * 0.88,
                                constraints.maxHeight * 0.95,
                              );
                              final playlist = _musicService.playlist.isNotEmpty
                                  ? _musicService.playlist
                                  : [song];

                              return Stack(
                                alignment: Alignment.center,
                                children: [
                                  // Layer 1: Swipe Album Carousel (Always kept alive & synced to music)
                                  IgnorePointer(
                                    ignoring: _showLyrics,
                                    child: AnimatedOpacity(
                                      duration: const Duration(
                                        milliseconds: 250,
                                      ),
                                      opacity: _showLyrics ? 0.0 : 1.0,
                                      child: NotificationListener<ScrollNotification>(
                                        onNotification: (notification) {
                                          if (notification
                                              is ScrollStartNotification) {
                                            _isUserDraggingPage = true;
                                          } else if (notification
                                              is ScrollEndNotification) {
                                            _isUserDraggingPage = false;
                                          }
                                          return false;
                                        },
                                        child: PageView.builder(
                                          controller: _pageController,
                                          itemCount: playlist.length,
                                          onPageChanged: (index) {
                                            if (_activePageIndex != index) {
                                              setState(() {
                                                _activePageIndex = index;
                                              });
                                            }
                                            if (_isUserDraggingPage &&
                                                index !=
                                                    _musicService
                                                        .currentIndex) {
                                              HapticFeedback.selectionClick();
                                              _musicService.skipToQueueIndex(
                                                index,
                                              );
                                            }
                                          },
                                          physics:
                                              const BouncingScrollPhysics(),
                                          itemBuilder: (context, index) {
                                            final track = playlist[index];
                                            final isCurrent =
                                                index ==
                                                _musicService.currentIndex;
                                            final trackHdThumbnail =
                                                MusicService.getHdThumbnail(
                                                  track.id.value,
                                                );

                                            return AnimatedBuilder(
                                              animation: _pageController,
                                              builder: (context, child) {
                                                double page = _musicService
                                                    .currentIndex
                                                    .toDouble();
                                                if (_pageController
                                                        .hasClients &&
                                                    _pageController
                                                        .position
                                                        .hasContentDimensions) {
                                                  page =
                                                      _pageController.page ??
                                                      _musicService.currentIndex
                                                          .toDouble();
                                                }
                                                final double diff =
                                                    (page - index).abs();
                                                final double scale =
                                                    (1.0 - (diff * 0.12)).clamp(
                                                      0.85,
                                                      1.0,
                                                    );
                                                final double opacity =
                                                    (1.0 - (diff * 0.45)).clamp(
                                                      0.40,
                                                      1.0,
                                                    );

                                                return Transform.scale(
                                                  scale: scale,
                                                  child: Opacity(
                                                    opacity: opacity,
                                                    child: child,
                                                  ),
                                                );
                                              },
                                              child: Center(
                                                child:
                                                    artworkStyle ==
                                                        ArtworkStyle.vinyl
                                                    ? VinylRecordPlayer(
                                                        key: ValueKey(
                                                          'vinyl_${track.id.value}',
                                                        ),
                                                        imageUrl:
                                                            trackHdThumbnail,
                                                        isPlaying:
                                                            isCurrent &&
                                                            isPlaying,
                                                        dominantColor: isCurrent
                                                            ? dominantColor
                                                            : const Color(
                                                                0xFF1E1E2C,
                                                              ),
                                                        vibrantColor: isCurrent
                                                            ? vibrantColor
                                                            : const Color(
                                                                0xFFFA2D48,
                                                              ),
                                                        size:
                                                            carouselSize * 0.94,
                                                      )
                                                    : Container(
                                                        width: carouselSize,
                                                        height: carouselSize,
                                                        decoration: BoxDecoration(
                                                          borderRadius:
                                                              BorderRadius.circular(
                                                                26,
                                                              ),
                                                          boxShadow: [
                                                            BoxShadow(
                                                              color:
                                                                  (isCurrent
                                                                          ? dominantColor
                                                                          : Colors.black)
                                                                      .withValues(
                                                                        alpha:
                                                                            0.60,
                                                                      ),
                                                              blurRadius: 36,
                                                              spreadRadius: 6,
                                                              offset:
                                                                  const Offset(
                                                                    0,
                                                                    16,
                                                                  ),
                                                            ),
                                                            BoxShadow(
                                                              color:
                                                                  (isCurrent
                                                                          ? vibrantColor
                                                                          : Colors.black)
                                                                      .withValues(
                                                                        alpha:
                                                                            0.35,
                                                                      ),
                                                              blurRadius: 48,
                                                              spreadRadius: 8,
                                                              offset:
                                                                  const Offset(
                                                                    0,
                                                                    8,
                                                                  ),
                                                            ),
                                                          ],
                                                        ),
                                                        child: isCurrent
                                                            ? Hero(
                                                                tag:
                                                                    'player_artwork_${track.id.value}',
                                                                child: ClipRRect(
                                                                  borderRadius:
                                                                      BorderRadius.circular(
                                                                        26,
                                                                      ),
                                                                  child: Image.network(
                                                                    trackHdThumbnail,
                                                                    fit: BoxFit
                                                                        .cover,
                                                                    errorBuilder: (_, _, _) => Image.network(
                                                                      track
                                                                          .thumbnails
                                                                          .highResUrl,
                                                                      fit: BoxFit
                                                                          .cover,
                                                                      errorBuilder: (_, _, _) => Container(
                                                                        color: const Color(
                                                                          0xFF222230,
                                                                        ),
                                                                        child: const Icon(
                                                                          Icons
                                                                              .music_note,
                                                                          color:
                                                                              Colors.white54,
                                                                          size:
                                                                              64,
                                                                        ),
                                                                      ),
                                                                    ),
                                                                  ),
                                                                ),
                                                              )
                                                            : ClipRRect(
                                                                borderRadius:
                                                                    BorderRadius.circular(
                                                                      26,
                                                                    ),
                                                                child: Image.network(
                                                                  trackHdThumbnail,
                                                                  fit: BoxFit
                                                                      .cover,
                                                                  errorBuilder: (_, _, _) => Image.network(
                                                                    track
                                                                        .thumbnails
                                                                        .highResUrl,
                                                                    fit: BoxFit
                                                                        .cover,
                                                                    errorBuilder: (_, _, _) => Container(
                                                                      color: const Color(
                                                                        0xFF222230,
                                                                      ),
                                                                      child: const Icon(
                                                                        Icons
                                                                            .music_note,
                                                                        color: Colors
                                                                            .white54,
                                                                        size:
                                                                            64,
                                                                      ),
                                                                    ),
                                                                  ),
                                                                ),
                                                              ),
                                                      ),
                                              ),
                                            );
                                          },
                                        ),
                                      ),
                                    ),
                                  ),

                                  // Layer 2: Synced / Animated Lyrics Overlay (Parallel Layer)
                                  IgnorePointer(
                                    ignoring: !_showLyrics,
                                    child: AnimatedOpacity(
                                      duration: const Duration(
                                        milliseconds: 250,
                                      ),
                                      opacity: _showLyrics ? 1.0 : 0.0,
                                      child: Container(
                                        width: double.infinity,
                                        height: constraints.maxHeight,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 20,
                                          vertical: 16,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.black.withValues(
                                            alpha: 0.35,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            24,
                                          ),
                                          border: Border.all(
                                            color: Colors.white10,
                                          ),
                                        ),
                                        child: _musicService.isFetchingLyrics
                                            ? Center(
                                                child:
                                                    CircularProgressIndicator(
                                                      color: Theme.of(
                                                        context,
                                                      ).primaryColor,
                                                    ),
                                              )
                                            : AnimatedLyrics(
                                                key: ValueKey(
                                                  'lyrics_${song.id.value}',
                                                ),
                                                rawLyrics:
                                                    _musicService
                                                        .cachedLyrics ??
                                                    '',
                                                pronunciationLyrics: _musicService
                                                    .cachedPronunciationLyrics,
                                                songLanguage: _musicService
                                                    .currentSongLanguage,
                                                songTitle: song.title,
                                                songArtist: song.author,
                                                positionStream: _musicService
                                                    .positionStream,
                                                onSeek: (targetPosition) {
                                                  _musicService.seek(
                                                    targetPosition,
                                                  );
                                                },
                                              ),
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                      ),

                      const SizedBox(height: 12),

                      // Track Info & Like Button
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Hero(
                                  tag: 'player_title_${song.id.value}',
                                  child: Material(
                                    color: Colors.transparent,
                                    child: Text(
                                      song.title,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 22,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: -0.5,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        song.author,
                                        style: TextStyle(
                                          color: Colors.white.withValues(
                                            alpha: 0.7,
                                          ),
                                          fontSize: 16,
                                          fontWeight: FontWeight.w500,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withValues(
                                            alpha: 0.12,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                          border: Border.all(
                                            color: Colors.white.withValues(
                                              alpha: 0.15,
                                            ),
                                            width: 0.5,
                                          ),
                                        ),
                                        child: Text(
                                          _musicService
                                              .activeStreamInfo
                                              .displayTag,
                                          style: const TextStyle(
                                            color: Colors.white70,
                                            fontSize: 9.5,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: 0.4,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: Icon(
                              isLiked
                                  ? Icons.favorite_rounded
                                  : Icons.favorite_border_rounded,
                              color: isLiked
                                  ? const Color(0xFFFA2D48)
                                  : Colors.white70,
                              size: 30,
                            ),
                            onPressed: () {
                              HapticFeedback.lightImpact();
                              _musicService.toggleLike(song);
                            },
                          ),
                        ],
                      ),

                      const SizedBox(height: 12),

                      // Apple Music Style Shorter Scrubber (with generous horizontal padding)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: RepaintBoundary(
                          child: StreamBuilder<Duration?>(
                            stream: _musicService.durationStream,
                            initialData: _musicService.duration,
                            builder: (context, durSnapshot) {
                              return StreamBuilder<Duration>(
                                stream: _musicService.positionStream,
                                initialData: _musicService.position,
                                builder: (context, snapshot) {
                                  final position =
                                      snapshot.data ?? _musicService.position;
                                  final duration =
                                      durSnapshot.data ??
                                      _musicService.duration ??
                                      (song.duration ?? Duration.zero);

                                  if (_prefs.scrubberStyle ==
                                      ScrubberStyle.classic) {
                                    return _buildClassicScrubber(
                                      context,
                                      position,
                                      duration,
                                      vibrantColor,
                                    );
                                  }

                                  return WaveformScrubber(
                                    position: position,
                                    duration: duration,
                                    songId: song.id.value,
                                    accentColor: vibrantColor,
                                    onSeek: (newPos) {
                                      _musicService.seek(newPos);
                                    },
                                  );
                                },
                              );
                            },
                          ),
                        ),
                      ),

                      const SizedBox(height: 8),

                      // Unified Responsive Playback Controls: Shuffle, -10s, Prev, Play/Pause, Next, +10s, Repeat
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 2,
                          vertical: 4,
                        ),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final availableWidth = constraints.maxWidth;
                            final bool isCompact = availableWidth < 360;
                            final bool isUltraCompact = availableWidth < 325;

                            final double playSize = isUltraCompact
                                ? 58.0
                                : (isCompact ? 64.0 : 72.0);
                            final double playIconSize = isUltraCompact
                                ? 34.0
                                : (isCompact ? 38.0 : 42.0);
                            final double skipIconSize = isUltraCompact
                                ? 30.0
                                : (isCompact ? 34.0 : 38.0);
                            final double skipBtnSize = isUltraCompact
                                ? 38.0
                                : (isCompact ? 42.0 : 46.0);
                            final double subIconSize = isUltraCompact
                                ? 19.0
                                : 22.0;
                            final double subBtnSize = isUltraCompact
                                ? 34.0
                                : 38.0;
                            final double skip10IconSize = isUltraCompact
                                ? 15.0
                                : (isCompact ? 17.0 : 19.0);
                            final double skip10PadH = isUltraCompact
                                ? 5.0
                                : (isCompact ? 6.0 : 8.0);
                            final double skip10PadV = isUltraCompact
                                ? 4.0
                                : (isCompact ? 5.0 : 6.0);

                            // Min intrinsic width ensuring all 7 items lay out comfortably without collision
                            final double minRequiredWidth =
                                (subBtnSize * 2) +
                                (((skip10IconSize + (skip10PadH * 2) + 2)) *
                                    2) +
                                (skipBtnSize * 2) +
                                playSize +
                                20.0;

                            return FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.center,
                              child: SizedBox(
                                width: math.max(
                                  availableWidth,
                                  minRequiredWidth,
                                ),
                                child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    IconButton(
                                      padding: EdgeInsets.zero,
                                      constraints: BoxConstraints(
                                        minWidth: subBtnSize,
                                        minHeight: subBtnSize,
                                      ),
                                      visualDensity: VisualDensity.compact,
                                      icon: Icon(
                                        Icons.shuffle_rounded,
                                        color: _musicService.isShuffle
                                            ? const Color(0xFF1DB954)
                                            : Colors.white54,
                                        size: subIconSize,
                                      ),
                                      onPressed: () {
                                        HapticFeedback.selectionClick();
                                        _musicService.toggleShuffle();
                                      },
                                    ),
                                    Material(
                                      color: Colors.transparent,
                                      child: InkWell(
                                        borderRadius: BorderRadius.circular(20),
                                        onTap: () {
                                          HapticFeedback.lightImpact();
                                          _musicService.seekRelative(
                                            const Duration(seconds: -10),
                                          );
                                        },
                                        child: Container(
                                          padding: EdgeInsets.symmetric(
                                            horizontal: skip10PadH,
                                            vertical: skip10PadV,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.white.withValues(
                                              alpha: 0.08,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              20,
                                            ),
                                            border: Border.all(
                                              color: Colors.white.withValues(
                                                alpha: 0.12,
                                              ),
                                            ),
                                          ),
                                          child: Icon(
                                            Icons.replay_10_rounded,
                                            color: Colors.white,
                                            size: skip10IconSize,
                                          ),
                                        ),
                                      ),
                                    ),
                                    // Modern Frosted Capsule Action Button - Previous
                                    Material(
                                      color: Colors.transparent,
                                      child: InkWell(
                                        customBorder: const CircleBorder(),
                                        onTap: () {
                                          HapticFeedback.mediumImpact();
                                          _musicService.previousSong();
                                        },
                                        child: Container(
                                          width: skipBtnSize,
                                          height: skipBtnSize,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: Colors.white.withValues(
                                              alpha: 0.10,
                                            ),
                                            border: Border.all(
                                              color: Colors.white.withValues(
                                                alpha: 0.16,
                                              ),
                                              width: 1.2,
                                            ),
                                            boxShadow: [
                                              BoxShadow(
                                                color: Colors.black.withValues(
                                                  alpha: 0.2,
                                                ),
                                                blurRadius: 8,
                                                offset: const Offset(0, 2),
                                              ),
                                            ],
                                          ),
                                          child: Center(
                                            child: Icon(
                                              Icons.skip_previous_rounded,
                                              color: Colors.white,
                                              size: skipIconSize * 0.76,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    // Modern Elevated Play/Pause Button with Multi-layered Glow & Smooth Morph
                                    Material(
                                      color: Colors.transparent,
                                      child: InkWell(
                                        customBorder: const CircleBorder(),
                                        onTap: () {
                                          HapticFeedback.mediumImpact();
                                          _musicService.togglePlayPause();
                                        },
                                        child: Container(
                                          width: playSize,
                                          height: playSize,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            gradient: const LinearGradient(
                                              begin: Alignment.topLeft,
                                              end: Alignment.bottomRight,
                                              colors: [
                                                Color(0xFFFFFFFF),
                                                Color(0xFFEFF2F6),
                                              ],
                                            ),
                                            border: Border.all(
                                              color: Colors.white.withValues(
                                                alpha: 0.90,
                                              ),
                                              width: 1.5,
                                            ),
                                            boxShadow: [
                                              BoxShadow(
                                                color: Colors.black.withValues(
                                                  alpha: 0.40,
                                                ),
                                                blurRadius: isUltraCompact
                                                    ? 16
                                                    : 22,
                                                spreadRadius: 1,
                                                offset: const Offset(0, 6),
                                              ),
                                            ],
                                          ),
                                          child: isLoading
                                              ? Center(
                                                  child: SizedBox(
                                                    width: playSize * 0.42,
                                                    height: playSize * 0.42,
                                                    child: const CircularProgressIndicator(
                                                      valueColor:
                                                          AlwaysStoppedAnimation<
                                                            Color
                                                          >(Color(0xFF0F141C)),
                                                      strokeWidth: 3,
                                                    ),
                                                  ),
                                                )
                                              : Center(
                                                  child: AnimatedSwitcher(
                                                    duration: const Duration(
                                                      milliseconds: 220,
                                                    ),
                                                    transitionBuilder:
                                                        (
                                                          child,
                                                          animation,
                                                        ) => ScaleTransition(
                                                          scale: animation,
                                                          child: FadeTransition(
                                                            opacity: animation,
                                                            child: child,
                                                          ),
                                                        ),
                                                    child: Icon(
                                                      isPlaying
                                                          ? Icons.pause_rounded
                                                          : Icons
                                                                .play_arrow_rounded,
                                                      key: ValueKey<bool>(
                                                        isPlaying,
                                                      ),
                                                      color: const Color(
                                                        0xFF0F141C,
                                                      ),
                                                      size: playIconSize,
                                                    ),
                                                  ),
                                                ),
                                        ),
                                      ),
                                    ),
                                    // Modern Frosted Capsule Action Button - Next
                                    Material(
                                      color: Colors.transparent,
                                      child: InkWell(
                                        customBorder: const CircleBorder(),
                                        onTap: () {
                                          HapticFeedback.mediumImpact();
                                          _musicService.nextSong();
                                        },
                                        child: Container(
                                          width: skipBtnSize,
                                          height: skipBtnSize,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: Colors.white.withValues(
                                              alpha: 0.10,
                                            ),
                                            border: Border.all(
                                              color: Colors.white.withValues(
                                                alpha: 0.16,
                                              ),
                                              width: 1.2,
                                            ),
                                            boxShadow: [
                                              BoxShadow(
                                                color: Colors.black.withValues(
                                                  alpha: 0.2,
                                                ),
                                                blurRadius: 8,
                                                offset: const Offset(0, 2),
                                              ),
                                            ],
                                          ),
                                          child: Center(
                                            child: Icon(
                                              Icons.skip_next_rounded,
                                              color: Colors.white,
                                              size: skipIconSize * 0.76,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    Material(
                                      color: Colors.transparent,
                                      child: InkWell(
                                        borderRadius: BorderRadius.circular(20),
                                        onTap: () {
                                          HapticFeedback.lightImpact();
                                          _musicService.seekRelative(
                                            const Duration(seconds: 10),
                                          );
                                        },
                                        child: Container(
                                          padding: EdgeInsets.symmetric(
                                            horizontal: skip10PadH,
                                            vertical: skip10PadV,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.white.withValues(
                                              alpha: 0.08,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              20,
                                            ),
                                            border: Border.all(
                                              color: Colors.white.withValues(
                                                alpha: 0.12,
                                              ),
                                            ),
                                          ),
                                          child: Icon(
                                            Icons.forward_10_rounded,
                                            color: Colors.white,
                                            size: skip10IconSize,
                                          ),
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      padding: EdgeInsets.zero,
                                      constraints: BoxConstraints(
                                        minWidth: subBtnSize,
                                        minHeight: subBtnSize,
                                      ),
                                      visualDensity: VisualDensity.compact,
                                      icon: Icon(
                                        _musicService.loopMode == LoopMode.one
                                            ? Icons.repeat_one_rounded
                                            : Icons.repeat_rounded,
                                        color:
                                            _musicService.loopMode !=
                                                LoopMode.off
                                            ? const Color(0xFF1DB954)
                                            : Colors.white54,
                                        size: subIconSize,
                                      ),
                                      onPressed: () {
                                        HapticFeedback.selectionClick();
                                        _musicService.toggleRepeat();
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),

                      const SizedBox(height: 8),

                      // Bottom Screen Options: 3 Main Static Glass Pill Buttons (Low-end static glass)
                      Container(
                        margin: const EdgeInsets.only(top: 4, bottom: 2),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(
                            0xFF14141E,
                          ).withValues(alpha: 0.90),
                          borderRadius: BorderRadius.circular(30),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.08),
                            width: 1.0,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.35),
                              blurRadius: 16,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.center,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              // 1. Lyrics
                              _buildBarPillButton(
                                context: context,
                                icon: _showLyrics
                                    ? Icons.lyrics_rounded
                                    : Icons.lyrics_outlined,
                                label: 'Lyrics',
                                isActive: _showLyrics,
                                activeColor: vibrantColor,
                                onTap: () => _toggleLyrics(song),
                              ),

                              // 2. Queue (Up Next)
                              _buildBarPillButton(
                                context: context,
                                icon: Icons.queue_music_rounded,
                                label: 'Queue',
                                badgeCount: _musicService.playlist.length,
                                isActive: false,
                                activeColor: vibrantColor,
                                onTap: () => _showQueueSheet(context),
                              ),

                              // 3. Three Lines (More Options Layer)
                              _buildBarPillButton(
                                context: context,
                                icon: Icons.segment_rounded,
                                label: 'More',
                                isActive: false,
                                activeColor: vibrantColor,
                                onTap: () =>
                                    _showCurrentSongActionsSheet(context, song),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildClassicScrubber(
    BuildContext context,
    Duration position,
    Duration duration,
    Color accentColor,
  ) {
    final bool hasValidDuration = duration.inMilliseconds > 0;
    final maxMs = hasValidDuration ? duration.inMilliseconds.toDouble() : 1.0;
    final curMs = hasValidDuration
        ? position.inMilliseconds.clamp(0, duration.inMilliseconds).toDouble()
        : 0.0;
    final remaining = hasValidDuration && duration > position
        ? duration - position
        : Duration.zero;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3.5,
              activeTrackColor: accentColor,
              inactiveTrackColor: Colors.white24,
              thumbColor: hasValidDuration ? Colors.white : Colors.white38,
              overlayColor: accentColor.withValues(alpha: 0.2),
              thumbShape: RoundSliderThumbShape(
                enabledThumbRadius: hasValidDuration ? 6 : 4,
                elevation: hasValidDuration ? 3 : 0,
              ),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              value: curMs,
              min: 0,
              max: maxMs,
              onChanged: hasValidDuration
                  ? (val) {
                      HapticFeedback.selectionClick();
                      _musicService.seek(Duration(milliseconds: val.toInt()));
                    }
                  : null,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _formatDuration(position),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  hasValidDuration ? '-${_formatDuration(remaining)}' : '--:--',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLandscapeLayout({
    required BuildContext context,
    required Video song,
    required bool isPlaying,
    required bool isLoading,
    required bool isLiked,
    required Color dominantColor,
    required Color vibrantColor,
    required Color darkVibrantColor,
    required ArtworkStyle artworkStyle,
  }) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0B0F),
      body: Stack(
        children: [
          // 1. Dynamic Adaptive Ambient Background (Static glass styling, GPU-accelerated gradient with zero blur passes)
          Positioned.fill(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 400),
              curve: Curves.easeOutCubic,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color.alphaBlend(
                      vibrantColor.withValues(alpha: 0.30),
                      const Color(0xFF0C0C12),
                    ),
                    Color.alphaBlend(
                      dominantColor.withValues(alpha: 0.18),
                      const Color(0xFF08080C),
                    ),
                    Color.alphaBlend(
                      darkVibrantColor.withValues(alpha: 0.20),
                      const Color(0xFF07070A),
                    ),
                  ],
                  stops: const [0.0, 0.52, 1.0],
                ),
              ),
            ),
          ),

          // 2. Main Horizontal Player Body
          SafeArea(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 280),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              child: _landscapeTab == LandscapeActiveTab.none
                  ? _buildLandscapeNormalView(
                      key: const ValueKey('landscape_normal'),
                      context: context,
                      song: song,
                      isPlaying: isPlaying,
                      isLoading: isLoading,
                      isLiked: isLiked,
                      dominantColor: dominantColor,
                      vibrantColor: vibrantColor,
                      artworkStyle: artworkStyle,
                    )
                  : _buildLandscapeExpandedView(
                      key: ValueKey('landscape_expanded_${_landscapeTab.name}'),
                      context: context,
                      song: song,
                      isPlaying: isPlaying,
                      isLoading: isLoading,
                      dominantColor: dominantColor,
                      vibrantColor: vibrantColor,
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLandscapeNormalView({
    Key? key,
    required BuildContext context,
    required Video song,
    required bool isPlaying,
    required bool isLoading,
    required bool isLiked,
    required Color dominantColor,
    required Color vibrantColor,
    required ArtworkStyle artworkStyle,
  }) {
    return Column(
      key: key,
      children: [
        // Slim Top Header Row
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: const Icon(
                  Icons.keyboard_arrow_down_rounded,
                  color: Colors.white70,
                  size: 28,
                ),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                onPressed: () {
                  HapticFeedback.lightImpact();
                  Navigator.pop(context);
                },
              ),
              Text(
                'NOW PLAYING',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2.0,
                ),
              ),
              IconButton(
                icon: Icon(
                  isLiked
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  color: isLiked ? const Color(0xFFFA2D48) : Colors.white70,
                  size: 24,
                ),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                onPressed: () {
                  HapticFeedback.lightImpact();
                  _musicService.toggleLike(song);
                  setState(() {});
                },
              ),
            ],
          ),
        ),

        // Main Horizontal Area: Album Cover on left, Title/Controls/Scrubber on right
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                // Left: Album Cover with vinyl & swipe gesture support
                LayoutBuilder(
                  builder: (context, constraints) {
                    final double coverSize = (constraints.maxHeight - 16).clamp(
                      130.0,
                      240.0,
                    );
                    final hdThumbnail = MusicService.getHdThumbnail(
                      song.id.value,
                    );

                    return GestureDetector(
                      onHorizontalDragEnd: (details) {
                        if (details.primaryVelocity == null) return;
                        if (details.primaryVelocity! < -250) {
                          HapticFeedback.mediumImpact();
                          _musicService.nextSong();
                        } else if (details.primaryVelocity! > 250) {
                          HapticFeedback.mediumImpact();
                          _musicService.previousSong();
                        }
                      },
                      child: artworkStyle == ArtworkStyle.vinyl
                          ? SizedBox(
                              width: coverSize + 36,
                              height: coverSize,
                              child: VinylRecordPlayer(
                                isPlaying: isPlaying,
                                imageUrl: hdThumbnail,
                                dominantColor: dominantColor,
                                vibrantColor: vibrantColor,
                                size: coverSize,
                              ),
                            )
                          : Container(
                              width: coverSize,
                              height: coverSize,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(22),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.18),
                                  width: 1.0,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: dominantColor.withValues(
                                      alpha: 0.55,
                                    ),
                                    blurRadius: 32,
                                    spreadRadius: 3,
                                    offset: const Offset(0, 10),
                                  ),
                                  BoxShadow(
                                    color: vibrantColor.withValues(alpha: 0.35),
                                    blurRadius: 40,
                                    spreadRadius: 4,
                                    offset: const Offset(0, 6),
                                  ),
                                ],
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(21),
                                child: Image.network(
                                  hdThumbnail,
                                  fit: BoxFit.cover,
                                  cacheWidth: 600,
                                  cacheHeight: 600,
                                  errorBuilder: (_, _, _) => Image.network(
                                    song.thumbnails.highResUrl,
                                    fit: BoxFit.cover,
                                    cacheWidth: 600,
                                    cacheHeight: 600,
                                    errorBuilder: (_, _, _) => Container(
                                      color: const Color(0xFF222230),
                                      child: const Icon(
                                        Icons.music_note,
                                        color: Colors.white54,
                                        size: 50,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                    );
                  },
                ),

                const SizedBox(width: 24),

                // Right: Song Title, Artist, Play Controls (1..5), Scrubber
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // Centered Song Title
                      Text(
                        song.title,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          letterSpacing: -0.3,
                        ),
                      ),
                      const SizedBox(height: 3),
                      // Centered Artist Name
                      Text(
                        song.author,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.65),
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 12),
                      // Play Controls in exact widget order: 1. Shuffle 2. Prev 3. Play/Pause 4. Next 5. Repeat
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _buildLandscapeShuffleButton(vibrantColor),
                          const SizedBox(width: 10),
                          _buildLandscapeCircleButton(
                            icon: Icons.skip_previous_rounded,
                            size: 42,
                            iconSize: 26,
                            onTap: () {
                              HapticFeedback.mediumImpact();
                              _musicService.previousSong();
                            },
                          ),
                          const SizedBox(width: 14),
                          _buildLandscapePlayPauseButton(
                            isPlaying: isPlaying,
                            isLoading: isLoading,
                            vibrantColor: vibrantColor,
                            size: 56,
                            iconSize: 34,
                          ),
                          const SizedBox(width: 14),
                          _buildLandscapeCircleButton(
                            icon: Icons.skip_next_rounded,
                            size: 42,
                            iconSize: 26,
                            onTap: () {
                              HapticFeedback.mediumImpact();
                              _musicService.nextSong();
                            },
                          ),
                          const SizedBox(width: 10),
                          _buildLandscapeRepeatButton(vibrantColor),
                        ],
                      ),
                      const SizedBox(height: 10),
                      // Responsive Scrubber on the right side of album cover
                      _buildLandscapeScrubber(context, song, vibrantColor),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        // Bottom Center Dock: Lyrics, Queue, More
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildBarPillButton(
                context: context,
                icon: Icons.lyrics_rounded,
                label: 'Lyrics',
                isActive: false,
                activeColor: vibrantColor,
                onTap: () => _setLandscapeTab(LandscapeActiveTab.lyrics),
              ),
              const SizedBox(width: 14),
              _buildBarPillButton(
                context: context,
                icon: Icons.queue_music_rounded,
                label: 'Queue',
                badgeCount: _musicService.playlist.length,
                isActive: false,
                activeColor: vibrantColor,
                onTap: () => _setLandscapeTab(LandscapeActiveTab.queue),
              ),
              const SizedBox(width: 14),
              _buildBarPillButton(
                context: context,
                icon: Icons.segment_rounded,
                label: 'More',
                isActive: false,
                activeColor: vibrantColor,
                onTap: () => _setLandscapeTab(LandscapeActiveTab.more),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildLandscapeExpandedView({
    Key? key,
    required BuildContext context,
    required Video song,
    required bool isPlaying,
    required bool isLoading,
    required Color dominantColor,
    required Color vibrantColor,
  }) {
    return Column(
      key: key,
      children: [
        // Upper Main Panel Row
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                // Left Shrunk Panel: Cover thumbnail, Title, Artist, Chip
                SizedBox(
                  width: 120,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Shrunk Album Cover
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.16),
                            width: 1.0,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: dominantColor.withValues(alpha: 0.45),
                              blurRadius: 18,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(15),
                          child: Image.network(
                            MusicService.getHdThumbnail(song.id.value),
                            fit: BoxFit.cover,
                            cacheWidth: 200,
                            cacheHeight: 200,
                            errorBuilder: (_, _, _) => Container(
                              color: const Color(0xFF222230),
                              child: const Icon(
                                Icons.music_note,
                                color: Colors.white54,
                                size: 28,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        song.title,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        song.author,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.6),
                          fontSize: 10,
                        ),
                      ),
                      const SizedBox(height: 6),
                      // Active Panel Indicator Chip
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: vibrantColor.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: vibrantColor.withValues(alpha: 0.45),
                            width: 1,
                          ),
                        ),
                        child: Text(
                          _landscapeTab == LandscapeActiveTab.lyrics
                              ? 'LYRICS'
                              : (_landscapeTab == LandscapeActiveTab.queue
                                    ? 'UP NEXT'
                                    : 'MORE'),
                          style: TextStyle(
                            color: vibrantColor,
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.8,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                // Right Expanded Panel Container
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF13131D).withValues(alpha: 0.88),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.08),
                        width: 1.0,
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: _buildLandscapeExpandedTabContent(
                        context,
                        song,
                        vibrantColor,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        // Bottom Compact Fixed Bar with slim scrubber and play controls
        _buildLandscapeCompactBottomBar(
          context,
          song,
          isPlaying,
          isLoading,
          vibrantColor,
        ),
      ],
    );
  }

  Widget _buildLandscapeExpandedTabContent(
    BuildContext context,
    Video song,
    Color vibrantColor,
  ) {
    if (_landscapeTab == LandscapeActiveTab.lyrics) {
      if (_musicService.isFetchingLyrics) {
        return Center(child: CircularProgressIndicator(color: vibrantColor));
      }
      final lyricsText = (_musicService.cachedLyrics ?? '').trim();
      if (lyricsText.isEmpty) {
        return const Center(
          child: Text(
            'No lyrics available for this track',
            style: TextStyle(color: Colors.white54, fontSize: 13),
          ),
        );
      }
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: AnimatedLyrics(
          key: ValueKey('lyrics_landscape_${song.id.value}'),
          rawLyrics: lyricsText,
          pronunciationLyrics: _musicService.cachedPronunciationLyrics,
          songLanguage: _musicService.currentSongLanguage,
          songTitle: song.title,
          songArtist: song.author,
          positionStream: _musicService.positionStream,
          onSeek: (pos) => _musicService.seek(pos),
        ),
      );
    }

    if (_landscapeTab == LandscapeActiveTab.queue) {
      final playlist = _musicService.playlist;
      final currentIndex = _musicService.currentIndex;

      if (playlist.isEmpty) {
        return const Center(
          child: Text(
            'Queue is empty',
            style: TextStyle(color: Colors.white54),
          ),
        );
      }

      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Up Next',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white12,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${playlist.length} Tracks',
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
          const Divider(color: Colors.white12, height: 1),
          Expanded(
            child: ReorderableListView.builder(
              buildDefaultDragHandles: false,
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 10),
              itemCount: playlist.length,
              // ignore: deprecated_member_use
              onReorder: (oldIndex, newIndex) {
                HapticFeedback.selectionClick();
                _musicService.reorderQueue(oldIndex, newIndex);
                setState(() {});
              },
              itemBuilder: (context, index) {
                final track = playlist[index];
                final isCurrent = index == currentIndex;
                final hdThumbnail = MusicService.getHdThumbnail(track.id.value);

                return Material(
                  key: ValueKey('landscape_queue_${track.id.value}_$index'),
                  color: isCurrent
                      ? Colors.white.withValues(alpha: 0.08)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () {
                      _musicService.playPlaylist(playlist, index);
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 4,
                      ),
                      child: Row(
                        children: [
                          ReorderableDragStartListener(
                            index: index,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 8,
                              ),
                              child: const Icon(
                                Icons.drag_handle_rounded,
                                color: Colors.white30,
                                size: 20,
                              ),
                            ),
                          ),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: Image.network(
                              hdThumbnail,
                              width: 36,
                              height: 36,
                              fit: BoxFit.cover,
                              cacheWidth: 100,
                              cacheHeight: 100,
                              errorBuilder: (_, _, _) => Container(
                                width: 36,
                                height: 36,
                                color: const Color(0xFF222230),
                                child: const Icon(
                                  Icons.music_note,
                                  color: Colors.white38,
                                  size: 18,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  track.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: isCurrent
                                        ? Colors.white
                                        : Colors.white.withValues(alpha: 0.9),
                                    fontSize: 12.5,
                                    fontWeight: isCurrent
                                        ? FontWeight.bold
                                        : FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(height: 1),
                                Text(
                                  track.author,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: isCurrent
                                        ? vibrantColor
                                        : Colors.white54,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (isCurrent)
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: Icon(
                                Icons.equalizer_rounded,
                                color: vibrantColor,
                                size: 18,
                              ),
                            ),
                          IconButton(
                            icon: const Icon(
                              Icons.close_rounded,
                              color: Colors.white38,
                              size: 16,
                            ),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 28,
                              minHeight: 28,
                            ),
                            onPressed: () {
                              HapticFeedback.lightImpact();
                              _musicService.removeFromQueue(index);
                              setState(() {});
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      );
    }

    if (_landscapeTab == LandscapeActiveTab.more) {
      return _buildLandscapeMoreOptions(context, song, vibrantColor);
    }

    return const SizedBox.shrink();
  }

  Widget _buildLandscapeMoreOptions(
    BuildContext context,
    Video song,
    Color vibrantColor,
  ) {
    final isLiked = _musicService.likedSongs.any(
      (s) => s['id'] == song.id.value,
    );
    final isDownloaded = _musicService.downloadedSongs.any(
      (s) => s['id'] == song.id.value,
    );

    return Padding(
      padding: const EdgeInsets.all(10),
      child: GridView.count(
        crossAxisCount: 2,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 2.8,
        children: [
          _buildLandscapeMoreCard(
            icon: Icons.equalizer_rounded,
            title: 'Equalizer',
            subtitle: 'Presets & Custom EQ',
            iconColor: vibrantColor,
            onTap: () => EqualizerBottomSheet.show(context),
          ),
          _buildLandscapeMoreCard(
            icon: Icons.bedtime_rounded,
            title: 'Sleep Timer',
            subtitle: _musicService.isSleepTimerActive
                ? _musicService.sleepTimerLabel
                : 'Set auto-stop timer',
            iconColor: _musicService.isSleepTimerActive
                ? const Color(0xFF1DB954)
                : Colors.white70,
            onTap: () => _showSleepTimerSheet(context),
          ),
          _buildLandscapeMoreCard(
            icon: isLiked
                ? Icons.favorite_rounded
                : Icons.favorite_border_rounded,
            title: isLiked ? 'Liked' : 'Like Song',
            subtitle: isLiked ? 'In Favorites ❤️' : 'Save to Favorites',
            iconColor: isLiked ? const Color(0xFFFA2D48) : Colors.white70,
            onTap: () {
              HapticFeedback.lightImpact();
              _musicService.toggleLike(song);
              setState(() {});
            },
          ),
          _buildLandscapeMoreCard(
            icon: isDownloaded
                ? Icons.download_done_rounded
                : Icons.download_rounded,
            title: isDownloaded ? 'Downloaded' : 'Download',
            subtitle: isDownloaded ? 'Available offline' : 'Save offline',
            iconColor: isDownloaded ? const Color(0xFF1DB954) : Colors.white70,
            onTap: () async {
              if (isDownloaded) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Song is already downloaded offline'),
                  ),
                );
                return;
              }
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Starting download...')),
              );
              final success = await _musicService.downloadSong(song);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      success
                          ? 'Saved to Offline Library!'
                          : 'Download failed.',
                    ),
                  ),
                );
              }
              setState(() {});
            },
          ),
          _buildLandscapeMoreCard(
            icon: Icons.playlist_add_rounded,
            title: 'Add to Playlist',
            subtitle: 'Save to custom playlist',
            iconColor: Colors.amberAccent,
            onTap: () => showAddToPlaylistSheet(context, song),
          ),
          _buildLandscapeMoreCard(
            icon: Icons.person_rounded,
            title: 'View Artist',
            subtitle: _resolveArtistName(song),
            iconColor: const Color(0xFF1DB954),
            onTap: () => _navigateToArtist(song),
          ),
          _buildLandscapeMoreCard(
            icon: Icons.album_rounded,
            title: 'Go to Album',
            subtitle:
                MusicService.getCachedAlbumTitle(song.id.value) ??
                MusicService.extractMovieOrAlbumTitle(song.title) ??
                'View full album',
            iconColor: const Color(0xFF8E2DE2),
            onTap: () => _navigateToAlbum(song),
          ),
          _buildLandscapeMoreCard(
            icon: Icons.bug_report_rounded,
            title: 'Report a Bug',
            subtitle: 'Help improve Dilse',
            iconColor: Colors.deepOrangeAccent,
            onTap: () => BugReportService.instance.triggerReport(context),
          ),
        ],
      ),
    );
  }

  Widget _buildLandscapeCompactBottomBar(
    BuildContext context,
    Video song,
    bool isPlaying,
    bool isLoading,
    Color vibrantColor,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xE6101018),
        border: Border(
          top: BorderSide(
            color: Colors.white.withValues(alpha: 0.08),
            width: 1.0,
          ),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildLandscapeMiniScrubber(vibrantColor),
          const SizedBox(height: 2),
          Row(
            children: [
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                icon: Icon(
                  Icons.shuffle_rounded,
                  color: _musicService.isShuffle
                      ? const Color(0xFF1DB954)
                      : Colors.white54,
                  size: 18,
                ),
                onPressed: () {
                  HapticFeedback.selectionClick();
                  _musicService.toggleShuffle();
                  setState(() {});
                },
              ),
              const SizedBox(width: 4),
              _buildLandscapeCircleButton(
                icon: Icons.skip_previous_rounded,
                size: 32,
                iconSize: 18,
                onTap: () {
                  HapticFeedback.mediumImpact();
                  _musicService.previousSong();
                },
              ),
              const SizedBox(width: 8),
              _buildLandscapePlayPauseButton(
                isPlaying: isPlaying,
                isLoading: isLoading,
                vibrantColor: vibrantColor,
                size: 40,
                iconSize: 22,
              ),
              const SizedBox(width: 8),
              _buildLandscapeCircleButton(
                icon: Icons.skip_next_rounded,
                size: 32,
                iconSize: 18,
                onTap: () {
                  HapticFeedback.mediumImpact();
                  _musicService.nextSong();
                },
              ),
              const SizedBox(width: 4),
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                icon: Icon(
                  _musicService.loopMode == LoopMode.one
                      ? Icons.repeat_one_rounded
                      : Icons.repeat_rounded,
                  color: _musicService.loopMode != LoopMode.off
                      ? const Color(0xFF1DB954)
                      : Colors.white54,
                  size: 18,
                ),
                onPressed: () {
                  HapticFeedback.selectionClick();
                  _musicService.toggleRepeat();
                  setState(() {});
                },
              ),
              const Spacer(),
              _buildMiniPillButton(
                icon: Icons.lyrics_rounded,
                label: 'Lyrics',
                isActive: _landscapeTab == LandscapeActiveTab.lyrics,
                activeColor: vibrantColor,
                onTap: () => _setLandscapeTab(LandscapeActiveTab.lyrics),
              ),
              const SizedBox(width: 6),
              _buildMiniPillButton(
                icon: Icons.queue_music_rounded,
                label: 'Queue',
                isActive: _landscapeTab == LandscapeActiveTab.queue,
                activeColor: vibrantColor,
                onTap: () => _setLandscapeTab(LandscapeActiveTab.queue),
              ),
              const SizedBox(width: 6),
              _buildMiniPillButton(
                icon: Icons.segment_rounded,
                label: 'More',
                isActive: _landscapeTab == LandscapeActiveTab.more,
                activeColor: vibrantColor,
                onTap: () => _setLandscapeTab(LandscapeActiveTab.more),
              ),
              const SizedBox(width: 6),
              IconButton(
                icon: const Icon(
                  Icons.keyboard_arrow_down_rounded,
                  color: Colors.white70,
                  size: 26,
                ),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                tooltip: 'Collapse',
                onPressed: () => _setLandscapeTab(LandscapeActiveTab.none),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLandscapeScrubber(
    BuildContext context,
    Video song,
    Color accentColor,
  ) {
    return StreamBuilder<Duration?>(
      stream: _musicService.durationStream,
      initialData: _musicService.duration,
      builder: (context, durSnapshot) {
        return StreamBuilder<Duration>(
          stream: _musicService.positionStream,
          initialData: _musicService.position,
          builder: (context, snapshot) {
            final position = snapshot.data ?? _musicService.position;
            final duration =
                durSnapshot.data ??
                _musicService.duration ??
                (song.duration ?? Duration.zero);
            final bool hasValidDuration = duration.inMilliseconds > 0;
            final maxMs = hasValidDuration
                ? duration.inMilliseconds.toDouble()
                : 1.0;
            final curMs = hasValidDuration
                ? position.inMilliseconds
                      .clamp(0, duration.inMilliseconds)
                      .toDouble()
                : 0.0;

            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  Text(
                    _formatDuration(position),
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.65),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3.5,
                        activeTrackColor: accentColor,
                        inactiveTrackColor: Colors.white24,
                        thumbColor: hasValidDuration
                            ? Colors.white
                            : Colors.white38,
                        overlayColor: accentColor.withValues(alpha: 0.2),
                        thumbShape: RoundSliderThumbShape(
                          enabledThumbRadius: hasValidDuration ? 6 : 4,
                          elevation: hasValidDuration ? 3 : 0,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 14,
                        ),
                      ),
                      child: Slider(
                        value: curMs,
                        min: 0,
                        max: maxMs,
                        onChanged: hasValidDuration
                            ? (val) {
                                HapticFeedback.selectionClick();
                                _musicService.seek(
                                  Duration(milliseconds: val.toInt()),
                                );
                              }
                            : null,
                      ),
                    ),
                  ),
                  Text(
                    hasValidDuration ? _formatDuration(duration) : '--:--',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.65),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildLandscapeMiniScrubber(Color accentColor) {
    final song = _musicService.currentSong;
    return StreamBuilder<Duration?>(
      stream: _musicService.durationStream,
      initialData: _musicService.duration,
      builder: (context, durSnapshot) {
        return StreamBuilder<Duration>(
          stream: _musicService.positionStream,
          initialData: _musicService.position,
          builder: (context, snapshot) {
            final position = snapshot.data ?? _musicService.position;
            final duration =
                durSnapshot.data ??
                _musicService.duration ??
                (song?.duration ?? Duration.zero);
            final bool hasValidDuration = duration.inMilliseconds > 0;
            final maxMs = hasValidDuration
                ? duration.inMilliseconds.toDouble()
                : 1.0;
            final curMs = hasValidDuration
                ? position.inMilliseconds
                      .clamp(0, duration.inMilliseconds)
                      .toDouble()
                : 0.0;

            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  Text(
                    _formatDuration(position),
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 2.2,
                        activeTrackColor: accentColor,
                        inactiveTrackColor: Colors.white24,
                        thumbColor: hasValidDuration
                            ? Colors.white
                            : Colors.white38,
                        overlayColor: accentColor.withValues(alpha: 0.2),
                        thumbShape: RoundSliderThumbShape(
                          enabledThumbRadius: hasValidDuration ? 4 : 3,
                          elevation: hasValidDuration ? 2 : 0,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 10,
                        ),
                      ),
                      child: Slider(
                        value: curMs,
                        min: 0,
                        max: maxMs,
                        onChanged: hasValidDuration
                            ? (val) {
                                HapticFeedback.selectionClick();
                                _musicService.seek(
                                  Duration(milliseconds: val.toInt()),
                                );
                              }
                            : null,
                      ),
                    ),
                  ),
                  Text(
                    hasValidDuration ? _formatDuration(duration) : '--:--',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildLandscapeCircleButton({
    required IconData icon,
    required double size,
    required double iconSize,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: 0.10),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.16),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.2),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Center(
            child: Icon(icon, color: Colors.white, size: iconSize),
          ),
        ),
      ),
    );
  }

  Widget _buildLandscapePlayPauseButton({
    required bool isPlaying,
    required bool isLoading,
    required Color vibrantColor,
    required double size,
    required double iconSize,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () {
          HapticFeedback.mediumImpact();
          _musicService.togglePlayPause();
        },
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFFFFFFF), Color(0xFFEFF2F6)],
            ),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.90),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: vibrantColor.withValues(alpha: 0.50),
                blurRadius: 18,
                spreadRadius: 2,
                offset: const Offset(0, 3),
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: isLoading
              ? Center(
                  child: SizedBox(
                    width: size * 0.44,
                    height: size * 0.44,
                    child: const CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(
                        Color(0xFF0F141C),
                      ),
                      strokeWidth: 2.5,
                    ),
                  ),
                )
              : Center(
                  child: Icon(
                    isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    color: const Color(0xFF0F141C),
                    size: iconSize,
                  ),
                ),
        ),
      ),
    );
  }

  Widget _buildLandscapeShuffleButton(Color vibrantColor) {
    return IconButton(
      icon: Icon(
        Icons.shuffle_rounded,
        color: _musicService.isShuffle
            ? const Color(0xFF1DB954)
            : Colors.white54,
        size: 22,
      ),
      onPressed: () {
        HapticFeedback.selectionClick();
        _musicService.toggleShuffle();
        setState(() {});
      },
    );
  }

  Widget _buildLandscapeRepeatButton(Color vibrantColor) {
    return IconButton(
      icon: Icon(
        _musicService.loopMode == LoopMode.one
            ? Icons.repeat_one_rounded
            : Icons.repeat_rounded,
        color: _musicService.loopMode != LoopMode.off
            ? const Color(0xFF1DB954)
            : Colors.white54,
        size: 22,
      ),
      onPressed: () {
        HapticFeedback.selectionClick();
        _musicService.toggleRepeat();
        setState(() {});
      },
    );
  }

  Widget _buildMiniPillButton({
    required IconData icon,
    required String label,
    required bool isActive,
    required Color activeColor,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          HapticFeedback.lightImpact();
          onTap();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: isActive
                ? activeColor.withValues(alpha: 0.28)
                : Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isActive
                  ? activeColor.withValues(alpha: 0.6)
                  : Colors.white.withValues(alpha: 0.12),
              width: 1.0,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 14,
                color: isActive ? activeColor : Colors.white70,
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  color: isActive ? Colors.white : Colors.white70,
                  fontSize: 11,
                  fontWeight: isActive ? FontWeight.bold : FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLandscapeMoreCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color iconColor,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          HapticFeedback.lightImpact();
          onTap();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: iconColor, size: 19),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12.5,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 9.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
