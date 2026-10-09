import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// Canonical, immutable model representing a song across all platforms.
/// Replaces ad-hoc `Map<String, String>` serialization and raw Video dependencies.
class SongItem {
  final String id;
  final String title;
  final String author;
  final String thumbnailUrl;
  final String streamUrl;
  final Duration duration;
  final String album;
  final String source;

  const SongItem({
    required this.id,
    required this.title,
    required this.author,
    this.thumbnailUrl = '',
    this.streamUrl = '',
    this.duration = Duration.zero,
    this.album = 'DilSe',
    this.source = 'auto',
  });

  /// Resilient factory that gracefully handles heterogeneous/legacy JSON types.
  factory SongItem.fromJson(Map<dynamic, dynamic> json) {
    Duration parsedDuration = Duration.zero;
    final rawDuration = json['duration'] ?? json['durationSeconds'];
    if (rawDuration is num) {
      parsedDuration = Duration(seconds: rawDuration.toInt());
    } else if (rawDuration is String) {
      final parsed = int.tryParse(rawDuration);
      if (parsed != null) {
        parsedDuration = Duration(seconds: parsed);
      }
    }

    final rawId = json['id']?.toString() ?? '';
    final rawThumb = (json['thumbnail'] ?? json['thumbnailUrl'] ?? '')
        .toString();

    return SongItem(
      id: rawId,
      title: (json['title'] ?? 'Unknown Title').toString(),
      author: (json['author'] ?? json['artist'] ?? 'Unknown Artist').toString(),
      thumbnailUrl: rawThumb.isNotEmpty
          ? rawThumb
          : 'https://img.youtube.com/vi/$rawId/hqdefault.jpg',
      streamUrl: (json['streamUrl'] ?? '').toString(),
      duration: parsedDuration,
      album: (json['album'] ?? 'DilSe').toString(),
      source: (json['source'] ?? 'auto').toString(),
    );
  }

  /// Construct from a YouTubeExplode [Video] object.
  factory SongItem.fromVideo(
    Video video, {
    String? streamUrl,
    String? album,
    String? source,
  }) {
    String thumb = '';
    try {
      thumb = video.thumbnails.highResUrl;
    } catch (_) {
      thumb = 'https://img.youtube.com/vi/${video.id.value}/hqdefault.jpg';
    }

    return SongItem(
      id: video.id.value,
      title: video.title,
      author: video.author,
      thumbnailUrl: thumb,
      streamUrl: streamUrl ?? '',
      duration: video.duration ?? Duration.zero,
      album: album ?? 'DilSe',
      source: source ?? 'youtube',
    );
  }

  /// Convert to [Video] object for seamless interop with legacy services.
  Video toVideo() {
    VideoId safeVideoId(String rawId) {
      try {
        return VideoId(rawId);
      } catch (_) {
        final sanitized = rawId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
        final padded = sanitized.padRight(11, '0').substring(0, 11);
        try {
          return VideoId(padded);
        } catch (_) {
          return VideoId('00000000000');
        }
      }
    }

    return Video(
      safeVideoId(id),
      title,
      author,
      ChannelId('UC0000000000000000000000'),
      DateTime.now(),
      '',
      null,
      '',
      duration,
      ThumbnailSet(id),
      null,
      Engagement(0, null, null),
      false,
    );
  }

  /// Standard serialized Map representation.
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'author': author,
      'thumbnail': thumbnailUrl,
      'streamUrl': streamUrl,
      'duration': duration.inSeconds,
      'album': album,
      'source': source,
    };
  }

  /// Legacy `Map<String, String>` format for backwards compatibility.
  Map<String, String> toLegacyMap() {
    return {
      'id': id,
      'title': title,
      'author': author,
      'thumbnail': thumbnailUrl,
      'streamUrl': streamUrl,
    };
  }

  SongItem copyWith({
    String? id,
    String? title,
    String? author,
    String? thumbnailUrl,
    String? streamUrl,
    Duration? duration,
    String? album,
    String? source,
  }) {
    return SongItem(
      id: id ?? this.id,
      title: title ?? this.title,
      author: author ?? this.author,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      streamUrl: streamUrl ?? this.streamUrl,
      duration: duration ?? this.duration,
      album: album ?? this.album,
      source: source ?? this.source,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SongItem && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'SongItem(id: $id, title: "$title", author: "$author")';
}
