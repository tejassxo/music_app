import 'package:fuzzy/fuzzy.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// Typo-tolerant in-memory search engine powered by Bitap fuzzy matching.
///
/// Resolves phonetic slips, spelling errors, and partial tokens across
/// in-memory song catalogs, custom playlists, and local files.
class FuzzySearchService {
  FuzzySearchService._();

  /// Searches a list of [Video] items with typo-tolerance.
  static List<Video> searchSongs(
    List<Video> songs,
    String query, {
    int limit = 40,
    double threshold = 0.45,
  }) {
    final cleanQ = query.trim();
    if (cleanQ.isEmpty) return songs;
    if (songs.isEmpty) return [];

    final fuse = Fuzzy<Video>(
      songs,
      options: FuzzyOptions<Video>(
        keys: [
          WeightedKey<Video>(
            name: 'title',
            getter: (song) => song.title,
            weight: 0.7,
          ),
          WeightedKey<Video>(
            name: 'author',
            getter: (song) => song.author,
            weight: 0.3,
          ),
        ],
        threshold: threshold,
        findAllMatches: false,
      ),
    );

    final results = fuse.search(cleanQ);
    return results
        .take(limit)
        .map((result) => result.item)
        .toList(growable: false);
  }

  /// Searches a list of Map-based track dictionaries.
  static List<Map<String, dynamic>> searchTrackMaps(
    List<Map<String, dynamic>> tracks,
    String query, {
    int limit = 40,
    double threshold = 0.45,
  }) {
    final cleanQ = query.trim();
    if (cleanQ.isEmpty) return tracks;
    if (tracks.isEmpty) return [];

    final fuse = Fuzzy<Map<String, dynamic>>(
      tracks,
      options: FuzzyOptions<Map<String, dynamic>>(
        keys: [
          WeightedKey<Map<String, dynamic>>(
            name: 'title',
            getter: (t) => (t['title'] as String?) ?? '',
            weight: 0.7,
          ),
          WeightedKey<Map<String, dynamic>>(
            name: 'artist',
            getter: (t) => (t['artist'] as String?) ?? '',
            weight: 0.3,
          ),
        ],
        threshold: threshold,
        findAllMatches: false,
      ),
    );

    final results = fuse.search(cleanQ);
    return results
        .take(limit)
        .map((result) => result.item)
        .toList(growable: false);
  }
}
