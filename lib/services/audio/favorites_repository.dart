import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/song_item.dart';

/// Single source of truth for user liked songs.
/// Completely eliminates `Map<String, String>` runtime cast crashes
/// and unifies platform storage between Web and Native.
class FavoritesRepository with ChangeNotifier {
  static final FavoritesRepository _instance = FavoritesRepository._internal();
  factory FavoritesRepository() => _instance;
  FavoritesRepository._internal();

  List<SongItem> _likedSongs = [];

  List<SongItem> get likedSongs => List.unmodifiable(_likedSongs);

  /// Backwards-compatible legacy map format for older widgets.
  List<Map<String, String>> get legacyLikedSongs =>
      _likedSongs.map((s) => s.toLegacyMap()).toList();

  bool isLiked(String id) {
    if (id.isEmpty) return false;
    return _likedSongs.any((s) => s.id == id);
  }

  /// Toggle like state. Returns true if track is now liked, false if unliked.
  Future<bool> toggleLike(SongItem song) async {
    final exists = isLiked(song.id);
    if (exists) {
      _likedSongs.removeWhere((s) => s.id == song.id);
    } else {
      _likedSongs.insert(0, song);
    }
    notifyListeners();
    await save();
    return !exists;
  }

  /// Remove a song from favorites by ID.
  Future<void> removeLiked(String id) async {
    final countBefore = _likedSongs.length;
    _likedSongs.removeWhere((s) => s.id == id);
    if (_likedSongs.length != countBefore) {
      notifyListeners();
      await save();
    }
  }

  /// Load favorites from storage, safely handling corrupt, legacy, or partial JSON.
  Future<void> load() async {
    try {
      if (kIsWeb) {
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString('liked_songs_web');
        if (raw != null && raw.isNotEmpty) {
          _likedSongs = _parseSafeList(json.decode(raw));
          notifyListeners();
        }
        return;
      }

      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/liked_songs.json');
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.isNotEmpty) {
          _likedSongs = _parseSafeList(json.decode(content));
          notifyListeners();
        }
      }
    } catch (e) {
      debugPrint('[FavoritesRepository] Non-fatal load error: $e');
    }
  }

  /// Save favorites to platform storage.
  Future<void> save() async {
    try {
      final jsonString = json.encode(
        _likedSongs.map((s) => s.toJson()).toList(),
      );
      if (kIsWeb) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('liked_songs_web', jsonString);
        return;
      }

      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/liked_songs.json');
      await file.writeAsString(jsonString, flush: true);
    } catch (e) {
      debugPrint('[FavoritesRepository] Save error: $e');
    }
  }

  /// Helper to safely parse raw dynamic lists into SongItem list without throwing.
  List<SongItem> _parseSafeList(dynamic rawJson) {
    if (rawJson is! List) return [];
    final result = <SongItem>[];
    for (final item in rawJson) {
      if (item is Map) {
        try {
          result.add(SongItem.fromJson(item));
        } catch (e) {
          debugPrint('[FavoritesRepository] Skipping corrupt item: $e');
        }
      }
    }
    return result;
  }

  @visibleForTesting
  void resetForTesting() {
    _likedSongs = [];
    notifyListeners();
  }

  @visibleForTesting
  void setLikedSongsForTesting(List<SongItem> songs) {
    _likedSongs = List.from(songs);
    notifyListeners();
  }
}
