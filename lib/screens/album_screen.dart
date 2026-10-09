import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../models/jio_album.dart';
import '../services/music_service.dart';
import '../widgets/mini_player.dart';
import '../widgets/animated_equalizer.dart';
import '../layouts/desktop_layout_state.dart';
import '../widgets/dilse_scrollbar.dart';

class AlbumScreen extends StatefulWidget {
  /// Provide either [album] (full) or [albumId] + [albumTitle] (for lazy load).
  final JioAlbum? album;
  final String? albumId;
  final String? albumTitle;
  final String? albumArtwork;
  final String? albumArtist;

  const AlbumScreen({
    super.key,
    this.album,
    this.albumId,
    this.albumTitle,
    this.albumArtwork,
    this.albumArtist,
  }) : assert(
         album != null || albumId != null || albumTitle != null,
         'Either album, albumId, or albumTitle must be provided',
       );

  @override
  State<AlbumScreen> createState() => _AlbumScreenState();
}

class _AlbumScreenState extends State<AlbumScreen>
    with SingleTickerProviderStateMixin {
  final MusicService _music = MusicService();
  final ScrollController _scrollController = ScrollController();
  JioAlbum? _album;
  bool _loading = true;
  String? _error;
  late AnimationController _fadeCtrl;
  late Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
    _loadAlbum();
  }

  Future<void> _loadAlbum() async {
    if (widget.album != null && widget.album!.songs.isNotEmpty) {
      setState(() {
        _album = widget.album;
        _loading = false;
      });
      _fadeCtrl.forward();
      return;
    }
    final id = widget.albumId ?? widget.album?.id ?? '';
    final title = widget.albumTitle ?? widget.album?.title ?? '';

    if (id.isEmpty && title.isEmpty) {
      setState(() {
        _error = 'Invalid album.';
        _loading = false;
      });
      return;
    }

    try {
      JioAlbum? loaded = id.isNotEmpty
          ? await _music.fetchAlbumTracks(id)
          : null;

      // Resilient Fallback: If 0 songs were found via album ID, search tracks by album title
      if ((loaded == null || loaded.songs.isEmpty) && title.isNotEmpty) {
        try {
          final albumCandidates = await _music.searchAlbums(title, limit: 3);
          if (albumCandidates.isNotEmpty) {
            final titleLower = title.toLowerCase();
            final match = albumCandidates.firstWhere(
              (a) =>
                  a.title.toLowerCase().contains(titleLower) ||
                  titleLower.contains(a.title.toLowerCase()),
              orElse: () => albumCandidates.first,
            );
            if (match.id.isNotEmpty) {
              loaded = await _music.fetchAlbumTracks(match.id);
            }
          }
        } catch (_) {}

        if (loaded == null || loaded.songs.isEmpty) {
          final fallbackTracks = await _music.searchSongs(title, limit: 25);
          if (fallbackTracks.isNotEmpty) {
            final mapped = fallbackTracks
                .map(
                  (v) => {
                    'id': v.id.value,
                    'title': v.title,
                    'author': v.author,
                    'album': title,
                    'thumbnail': v.thumbnails.highResUrl,
                    'duration': v.duration?.inSeconds ?? 0,
                    'trackNumber': 0,
                  },
                )
                .toList();

            loaded =
                (loaded ??
                        JioAlbum(
                          id: id.isNotEmpty ? id : 'search_$title',
                          title: title,
                          artist:
                              widget.albumArtist ?? widget.album?.artist ?? '',
                          artwork:
                              widget.albumArtwork ??
                              widget.album?.artwork ??
                              '',
                          year: widget.album?.year ?? '',
                          songCount: mapped.length,
                          language: widget.album?.language ?? '',
                        ))
                    .copyWith(
                      songs: mapped,
                      songCount: mapped.length,
                      artwork: (loaded?.artwork.isNotEmpty == true)
                          ? loaded!.artwork
                          : (mapped.isNotEmpty
                                ? mapped[0]['thumbnail'] as String?
                                : null),
                    );
          }
        }
      }

      if (!mounted) return;

      if (loaded == null) {
        setState(() {
          _error = 'Could not load album tracks. Please try again.';
          _loading = false;
        });
        return;
      }

      setState(() {
        _album = loaded;
        _loading = false;
      });
      _fadeCtrl.forward();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _playAll({int startIndex = 0}) {
    if (_album == null || _album!.songs.isEmpty) return;
    HapticFeedback.mediumImpact();
    final videos = _music.albumSongsToVideos(_album!);
    if (videos.isEmpty) return;
    _music.playPlaylist(videos, startIndex);
  }

  void _shuffleAll() {
    if (_album == null || _album!.songs.isEmpty) return;
    HapticFeedback.mediumImpact();
    final videos = _music.albumSongsToVideos(_album!);
    if (videos.isEmpty) return;
    final shuffled = List<Video>.from(videos)..shuffle();
    _music.playPlaylist(shuffled, 0);
  }

  void _addToQueue(int index) {
    if (_album == null) return;
    HapticFeedback.lightImpact();
    final videos = _music.albumSongsToVideos(_album!);
    if (index >= videos.length) return;
    _music.addToQueue(videos[index]);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Added "${_album!.songs[index]['title']}" to queue',
          style: const TextStyle(color: Colors.white),
        ),
        backgroundColor: const Color(0xFF1A1A2E),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  String _fmtDuration(int sec) {
    if (sec <= 0) return '';
    final m = sec ~/ 60;
    final s = sec % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _fadeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final effectiveArtwork = (_album?.artwork.isNotEmpty == true)
        ? _album!.artwork
        : (widget.albumArtwork?.isNotEmpty == true)
        ? widget.albumArtwork!
        : (_album?.songs.isNotEmpty == true &&
              _album!.songs[0]['thumbnail'] != null)
        ? _album!.songs[0]['thumbnail'] as String
        : (widget.album?.artwork.isNotEmpty == true)
        ? widget.album!.artwork
        : '';

    final title =
        _album?.title ?? widget.albumTitle ?? widget.album?.title ?? 'Album';
    final artist =
        _album?.artist ?? widget.albumArtist ?? widget.album?.artist ?? '';
    final year = _album?.year ?? widget.album?.year ?? '';

    return Scaffold(
      backgroundColor: const Color(0xFF0B0B0F),
      body: Stack(
        children: [
          DilSeScrollbar(
            controller: _scrollController,
            bottomPadding: 90.0,
            child: CustomScrollView(
              controller: _scrollController,
              slivers: [
                // Cinematic header
                SliverAppBar(
                  expandedHeight: 340,
                  pinned: true,
                  backgroundColor: const Color(0xFF0B0B0F),
                  leading: IconButton(
                    icon: const Icon(
                      Icons.arrow_back_ios_new_rounded,
                      color: Colors.white,
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
                    background: _buildHeader(
                      effectiveArtwork,
                      title,
                      artist,
                      year,
                    ),
                  ),
                ),

                // Loading / Error
                if (_loading)
                  const SliverFillRemaining(
                    child: Center(
                      child: CircularProgressIndicator(
                        color: Color(0xFF7C3AED),
                      ),
                    ),
                  )
                else if (_error != null)
                  SliverFillRemaining(
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.error_outline_rounded,
                            color: Colors.white38,
                            size: 48,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _error!,
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 14,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 16),
                          TextButton(
                            onPressed: () {
                              setState(() {
                                _loading = true;
                                _error = null;
                              });
                              _loadAlbum();
                            },
                            child: const Text(
                              'Retry',
                              style: TextStyle(color: Color(0xFF7C3AED)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                else if (_album!.songs.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.album_outlined,
                              color: Colors.white24,
                              size: 64,
                            ),
                            const SizedBox(height: 16),
                            const Text(
                              'No tracks available for this album',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'The songs for "$title" may be restricted or pending catalog release.',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.4),
                                fontSize: 13,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 24),
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF7C3AED),
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 12,
                                ),
                              ),
                              onPressed: () => Navigator.pop(context),
                              icon: const Icon(
                                Icons.arrow_back_rounded,
                                size: 18,
                              ),
                              label: const Text('Back to Search'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                else ...[
                  // Play / Shuffle buttons
                  SliverToBoxAdapter(child: _buildControls()),

                  // Song count info
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                      child: Text(
                        _album!.songs.length == 1
                            ? 'Single • 1 song${year.isNotEmpty ? ' • $year' : ''}'
                            : '${_album!.songs.length} songs'
                                  '${year.isNotEmpty ? ' • $year' : ''}'
                                  '${_album!.language.isNotEmpty ? ' • ${_album!.language[0].toUpperCase()}${_album!.language.substring(1)}' : ''}',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.45),
                          fontSize: 12,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ),
                  ),

                  // Track list
                  SliverFadeTransition(
                    opacity: _fadeAnim,
                    sliver: SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, i) => _buildTrackTile(i),
                        childCount: _album!.songs.length,
                      ),
                    ),
                  ),

                  const SliverToBoxAdapter(child: SizedBox(height: 120)),
                ],
              ],
            ),
          ),

          // Floating MiniPlayer
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: AnimatedBuilder(
              animation: _music,
              builder: (context, _) {
                if (MediaQuery.of(context).size.width >= 1024 ||
                    _music.currentSong == null) {
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

  Widget _buildHeader(
    String artwork,
    String title,
    String artist,
    String year,
  ) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Blurred background
        if (artwork.isNotEmpty)
          Image.network(
            artwork,
            fit: BoxFit.cover,
            errorBuilder: (_, e2, st) =>
                const ColoredBox(color: Color(0xFF1A1A2E)),
          ),
        BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(color: Colors.black.withValues(alpha: 0.55)),
        ),
        // Album art + info
        Positioned(
          left: 0,
          right: 0,
          bottom: 24,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Cover art
              Hero(
                tag: 'album-art-${widget.albumId ?? widget.album?.id}',
                child: Container(
                  width: 160,
                  height: 160,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.5),
                        blurRadius: 24,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: artwork.isNotEmpty
                        ? Image.network(
                            artwork,
                            fit: BoxFit.cover,
                            errorBuilder: (_, e2, st) =>
                                _buildStylizedVinylCover(
                                  title,
                                  artist,
                                  size: 160,
                                ),
                          )
                        : _buildStylizedVinylCover(title, artist, size: 160),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.5,
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (artist.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        artist,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.65),
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildControls() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      child: Row(
        children: [
          // Play All
          Expanded(
            child: GestureDetector(
              onTap: _playAll,
              child: Container(
                height: 48,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF7C3AED), Color(0xFF4F46E5)],
                  ),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF7C3AED).withValues(alpha: 0.35),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 22,
                    ),
                    SizedBox(width: 6),
                    Text(
                      'Play All',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Shuffle
          GestureDetector(
            onTap: _shuffleAll,
            child: Container(
              height: 48,
              width: 48,
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A2E),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
              ),
              child: const Icon(
                Icons.shuffle_rounded,
                color: Colors.white,
                size: 22,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrackTile(int index) {
    final s = _album!.songs[index];
    final songId = s['id']?.toString() ?? '';
    final title = s['title'] as String? ?? 'Unknown';
    final artist = s['author'] as String? ?? '';
    final dur = s['duration'] as int? ?? 0;
    final trackNum = s['trackNumber'] as int? ?? (index + 1);

    return AnimatedBuilder(
      animation: _music,
      builder: (context, _) {
        final isPlaying =
            _music.currentSong?.id.value == songId ||
            (_music.currentSong?.title == title &&
                _music.currentSong?.author == artist);

        return ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 2,
          ),
          leading: isPlaying
              ? const SizedBox(
                  width: 44,
                  height: 44,
                  child: AnimatedEqualizer(isPlaying: true),
                )
              : SizedBox(
                  width: 44,
                  height: 44,
                  child: Center(
                    child: Text(
                      '$trackNum',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.38),
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
          title: Text(
            title,
            style: TextStyle(
              color: isPlaying ? const Color(0xFF7C3AED) : Colors.white,
              fontSize: 14,
              fontWeight: isPlaying ? FontWeight.w700 : FontWeight.w500,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: artist.isNotEmpty
              ? Text(
                  artist,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.45),
                    fontSize: 12,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                )
              : null,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (dur > 0)
                Text(
                  _fmtDuration(dur),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.38),
                    fontSize: 12,
                  ),
                ),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(
                  Icons.more_vert_rounded,
                  color: Colors.white38,
                  size: 18,
                ),
                onPressed: () => _addToQueue(index),
                tooltip: 'Add to queue',
              ),
            ],
          ),
          onTap: () => _playAll(startIndex: index),
        );
      },
    );
  }

  Widget _buildStylizedVinylCover(
    String title,
    String artist, {
    double size = 160,
  }) {
    final seed = title.hashCode;
    final hue1 = (seed.abs() % 360).toDouble();
    final color1 = HSLColor.fromAHSL(1.0, hue1, 0.65, 0.22).toColor();
    final color2 = HSLColor.fromAHSL(
      1.0,
      (hue1 + 45) % 360,
      0.75,
      0.12,
    ).toColor();

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          colors: [color1, color2],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: color1.withValues(alpha: 0.35),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Subtle concentric vinyl grooves
          for (final factor in [0.85, 0.68, 0.52])
            Container(
              width: size * factor,
              height: size * factor,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.06),
                  width: 1.2,
                ),
              ),
            ),
          // Center record label
          Container(
            width: size * 0.36,
            height: size * 0.36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.black.withValues(alpha: 0.65),
              border: Border.all(
                color: const Color(0xFF7C3AED).withValues(alpha: 0.5),
                width: 1.5,
              ),
            ),
            child: Center(
              child: Text(
                title.isNotEmpty ? title[0].toUpperCase() : '♪',
                style: TextStyle(
                  color: const Color(0xFFA78BFA),
                  fontSize: size * 0.16,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
