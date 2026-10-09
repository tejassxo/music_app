import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../services/music_service.dart';
import '../screens/artist_profile_screen.dart';
import '../screens/album_screen.dart';
import '../services/preferences_service.dart';

/// Converts a song Map representation into a youtube_explode Video instance
/// for seamless interop across existing song action sheets.
Video songMapToVideo(Map<String, dynamic> songMap) {
  final id = (songMap['id'] as String?) ?? '';
  final durationMs = (songMap['durationMs'] as int?) ?? 0;
  final cleanId = id.isNotEmpty ? id : '00000000000';
  final safeId = cleanId.length >= 11
      ? cleanId.substring(0, 11)
      : cleanId.padRight(11, '0');

  return Video(
    VideoId(safeId),
    (songMap['title'] as String?) ?? 'Unknown Title',
    (songMap['author'] as String?) ?? 'Unknown Artist',
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

/// Convenience method to open the options bottom sheet for a playlist song Map.
void showPlaylistSongOptionsBottomSheet(
  BuildContext context, {
  required Map<String, dynamic> songMap,
  required String playlistId,
  VoidCallback? onPlayNow,
  VoidCallback? onRemoved,
}) {
  final video = songMapToVideo(songMap);
  final thumb = (songMap['thumbnail'] as String?) ?? '';
  final songId = (songMap['id'] as String?) ?? '';
  final isLikedSongs = playlistId == 'liked_songs';

  showSongOptionsBottomSheet(
    context,
    video,
    currentPlaylistId: isLikedSongs ? null : playlistId,
    customThumbnail: thumb,
    onPlayNow: onPlayNow,
    onRemoveFromPlaylist: isLikedSongs
        ? null
        : () {
            MusicService().removeSongFromPlaylist(playlistId, songId);
            onRemoved?.call();
          },
  );
}

/// Shows an Apple Music / Spotify-inspired frosted glass options sheet for a song.
void showSongOptionsBottomSheet(
  BuildContext context,
  Video song, {
  String? currentPlaylistId,
  VoidCallback? onRemoveFromPlaylist,
  VoidCallback? onPlayNow,
  String? customThumbnail,
}) {
  HapticFeedback.lightImpact();
  final musicService = MusicService();

  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) {
      final isLiked = musicService.isLiked(song.id.value);
      final isDownloaded = musicService.isDownloaded(song.id.value);
      final hdThumbnail =
          (customThumbnail != null && customThumbnail.isNotEmpty)
          ? customThumbnail
          : MusicService.getHdThumbnail(song.id.value);

      return Container(
        padding: const EdgeInsets.only(top: 12, bottom: 28),
        decoration: BoxDecoration(
          color: const Color(0xFF14141E).withValues(alpha: 0.96),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Pill Handle
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
                      borderRadius: BorderRadius.circular(10),
                      child: Image.network(
                        hdThumbnail,
                        width: 52,
                        height: 52,
                        fit: BoxFit.cover,
                        cacheWidth: 120,
                        cacheHeight: 120,
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
                              fontSize: 15,
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
                              color: Colors.white.withValues(alpha: 0.6),
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),
              const Divider(color: Colors.white10, height: 1),
              const SizedBox(height: 6),

              // Action 0: Play immediately (when provided)
              if (onPlayNow != null)
                _buildActionTile(
                  icon: Icons.play_arrow_rounded,
                  title: 'Play',
                  subtitle: 'Play this song now',
                  onTap: () {
                    Navigator.pop(ctx);
                    onPlayNow();
                  },
                ),

              // Action 0a: View Artist Profile
              _buildActionTile(
                icon: Icons.person_rounded,
                iconColor: const Color(0xFF1DB954),
                title: 'View Artist Profile',
                subtitle: 'Explore full discography for ${song.author}',
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          ArtistProfileScreen(artistName: song.author),
                    ),
                  );
                },
              ),

              // Action 0b: Start Song Radio
              _buildActionTile(
                icon: Icons.auto_awesome_rounded,
                iconColor: const Color(0xFF6C5CE7),
                title: 'Start Song Radio',
                subtitle: '50 smart tracks based on this song',
                onTap: () {
                  Navigator.pop(ctx);
                  musicService.startSongRadio(song);
                  _showToast(context, 'Starting radio for "${song.title}"');
                },
              ),

              // Action 0c: Go to Album
              _buildActionTile(
                icon: Icons.album_rounded,
                iconColor: const Color(0xFF8E2DE2),
                title: 'Go to Album',
                subtitle:
                    MusicService.getCachedAlbumTitle(song.id.value) ??
                    MusicService.extractMovieOrAlbumTitle(song.title) ??
                    'View full album & tracks',
                onTap: () async {
                  Navigator.pop(ctx);

                  final cachedAlbum = MusicService.getCachedAlbum(
                    song.id.value,
                  );
                  if (cachedAlbum != null && cachedAlbum.songs.isNotEmpty) {
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

                  final cachedId = MusicService.getCachedAlbumId(song.id.value);
                  final cachedTitle =
                      MusicService.getCachedAlbumTitle(song.id.value) ??
                      MusicService.extractMovieOrAlbumTitle(song.title);

                  if ((cachedId != null && cachedId.isNotEmpty) ||
                      (cachedTitle != null && cachedTitle.isNotEmpty)) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => AlbumScreen(
                          albumId: cachedId ?? '',
                          albumTitle: cachedTitle ?? '',
                          albumArtwork:
                              customThumbnail ??
                              MusicService.getHdThumbnail(song.id.value),
                          albumArtist: song.author,
                        ),
                      ),
                    );
                    return;
                  }

                  final resolved = await musicService.resolveAlbumForSong(song);
                  if (context.mounted) {
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
                },
              ),

              // Action 1: Play Next
              _buildActionTile(
                icon: Icons.playlist_play_rounded,
                title: 'Play Next',
                subtitle: 'Add to the top of your queue',
                onTap: () {
                  Navigator.pop(ctx);
                  musicService.playNext(song);
                  _showToast(context, 'Playing next: "${song.title}"');
                },
              ),

              // Action 2: Add to Queue
              _buildActionTile(
                icon: Icons.queue_music_rounded,
                title: 'Add to Queue',
                subtitle: 'Play after currently queued songs',
                onTap: () {
                  Navigator.pop(ctx);
                  musicService.addToQueue(song);
                  _showToast(context, 'Added to queue: "${song.title}"');
                },
              ),

              // Action 3: Add to Playlist
              _buildActionTile(
                icon: Icons.playlist_add_rounded,
                title: 'Add to Playlist',
                subtitle: 'Save to your personal playlists',
                onTap: () {
                  Navigator.pop(ctx);
                  showAddToPlaylistSheet(context, song);
                },
              ),

              // Action 4: Like / Favorite
              _buildActionTile(
                icon: isLiked
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                iconColor: isLiked ? const Color(0xFFFA2D48) : Colors.white,
                title: isLiked ? 'Remove from Liked' : 'Like Song',
                subtitle: isLiked
                    ? 'Saved in your favorites'
                    : 'Add to your Liked collection',
                onTap: () {
                  Navigator.pop(ctx);
                  musicService.toggleLike(song);
                  _showToast(
                    context,
                    isLiked ? 'Removed from Liked' : 'Added to Liked Songs ❤️',
                  );
                },
              ),

              // Action: Remove from Playlist (when in playlist context)
              if (currentPlaylistId != null || onRemoveFromPlaylist != null)
                _buildActionTile(
                  icon: Icons.playlist_remove_rounded,
                  iconColor: Colors.redAccent,
                  title: 'Remove from Playlist',
                  subtitle: 'Remove from this playlist only',
                  onTap: () {
                    Navigator.pop(ctx);
                    if (onRemoveFromPlaylist != null) {
                      onRemoveFromPlaylist();
                    } else if (currentPlaylistId != null) {
                      musicService.removeSongFromPlaylist(
                        currentPlaylistId,
                        song.id.value,
                      );
                    }
                    _showToast(context, 'Removed from playlist');
                  },
                ),

              // Action 5: Download Offline
              _buildActionTile(
                icon: isDownloaded
                    ? Icons.download_done_rounded
                    : Icons.download_rounded,
                iconColor: isDownloaded
                    ? const Color(0xFF1DB954)
                    : Colors.white,
                title: isDownloaded ? 'Downloaded' : 'Download for Offline',
                subtitle: isDownloaded
                    ? 'Available without internet'
                    : 'Save audio file locally',
                onTap: () async {
                  Navigator.pop(ctx);
                  if (isDownloaded) {
                    _showToast(context, 'Song is already downloaded offline');
                  } else {
                    _showToast(context, 'Starting download...');
                    final success = await musicService.downloadSong(song);
                    if (context.mounted) {
                      _showToast(
                        context,
                        success ? 'Download complete!' : 'Download failed.',
                      );
                    }
                  }
                },
              ),

              // Action 6: Share Song
              _buildActionTile(
                icon: Icons.share_rounded,
                title: 'Share Song',
                subtitle: 'Copy link or song details',
                onTap: () {
                  Navigator.pop(ctx);
                  Clipboard.setData(
                    ClipboardData(
                      text: '${song.title} - ${song.author}\n${song.url}',
                    ),
                  );
                  _showToast(context, 'Song link copied to clipboard!');
                },
              ),
            ],
          ),
        ),
      );
    },
  );
}

Widget _buildActionTile({
  required IconData icon,
  Color iconColor = Colors.white,
  required String title,
  required String subtitle,
  required VoidCallback onTap,
}) {
  return Material(
    color: Colors.transparent,
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(10),
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
          color: Colors.white.withValues(alpha: 0.5),
          fontSize: 12,
        ),
      ),
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
    ),
  );
}

void showAddToPlaylistSheet(BuildContext context, Video song) {
  final musicService = MusicService();
  final playlists = musicService.customPlaylists;

  showModalBottomSheet(
    context: context,
    backgroundColor: const Color(0xFF14141E),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) {
      return Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Add to Playlist',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('New'),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _showNewPlaylistPrompt(context, song);
                    },
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white10),
            if (playlists.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24.0),
                child: Center(
                  child: Text(
                    'No playlists yet. Tap "New" above to create one!',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              )
            else
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: playlists.length,
                itemBuilder: (context, index) {
                  final p = playlists[index];
                  final pId = (p['id'] as String?) ?? '';
                  final pName = (p['name'] as String?) ?? 'Playlist';
                  final pTracks = List<dynamic>.from(p['songs'] ?? []);

                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 4,
                    ),
                    leading: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E1E28),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(
                        Icons.featured_play_list_rounded,
                        color: Color(0xFF1DB954),
                        size: 22,
                      ),
                    ),
                    title: Text(
                      pName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      '${pTracks.length} tracks',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                    onTap: () {
                      musicService.addSongToPlaylist(pId, song);
                      Navigator.pop(ctx);
                      _showToast(context, 'Added "${song.title}" to $pName');
                    },
                  );
                },
              ),
          ],
        ),
      );
    },
  );
}

void _showNewPlaylistPrompt(BuildContext context, Video song) {
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
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: Theme.of(context).primaryColor,
            foregroundColor: Colors.white,
          ),
          onPressed: () {
            final name = controller.text.trim();
            if (name.isNotEmpty) {
              final newId = MusicService().createPlaylist(
                name,
                isSpotify: false,
                source: 'custom',
              );
              PreferencesService().registerManualPlaylistId(newId);
              PreferencesService().unregisterSpotifyPlaylistId(newId);
              MusicService().addSongToPlaylist(newId, song);
              Navigator.pop(ctx);
              _showToast(context, 'Created "$name" and added song!');
            }
          },
          child: const Text('Create & Add'),
        ),
      ],
    ),
  );
}

void _showToast(BuildContext context, String message) {
  ScaffoldMessenger.of(context).hideCurrentSnackBar();
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        message,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      backgroundColor: const Color(0xFF222230),
      duration: const Duration(seconds: 2),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}
