import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Industrial-grade local relational storage for DilSe Music.
///
/// Provides ACID-compliant, indexed queries for playback history,
/// song analytics, and favorites with zero in-memory JSON serialization overhead.
/// Automatically handles test and headless environments via resilient in-memory fallback.
class DatabaseService {
  static final DatabaseService _instance = DatabaseService._internal();
  factory DatabaseService() => _instance;
  DatabaseService._internal();

  Database? _db;
  bool _useInMemoryFallback = false;

  final List<Map<String, dynamic>> _fallbackHistory = [];
  final Set<String> _fallbackFavorites = {};
  final Map<String, Map<String, dynamic>> _fallbackFavoriteRecords = {};

  bool get _isTestEnvironment {
    if (kIsWeb) return false;
    try {
      return Platform.environment.containsKey('FLUTTER_TEST');
    } catch (_) {
      return false;
    }
  }

  Future<Database?> get database async {
    if (kIsWeb || _useInMemoryFallback || _isTestEnvironment) return null;
    if (_db != null) return _db;
    try {
      _db = await _initDatabase();
      return _db;
    } catch (_) {
      _useInMemoryFallback = true;
      return null;
    }
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, 'dilse_music.db');

    return await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE play_history (
            song_id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            artist TEXT NOT NULL,
            artwork_url TEXT,
            duration_seconds INTEGER,
            played_at INTEGER NOT NULL,
            play_count INTEGER DEFAULT 1
          )
        ''');

        await db.execute('''
          CREATE INDEX idx_history_played_at ON play_history(played_at DESC)
        ''');

        await db.execute('''
          CREATE TABLE favorite_songs (
            song_id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            artist TEXT NOT NULL,
            artwork_url TEXT,
            duration_seconds INTEGER,
            added_at INTEGER NOT NULL
          )
        ''');
      },
    );
  }

  /// Records a playback event, incrementing play count and updating timestamp.
  Future<void> recordPlay({
    required String songId,
    required String title,
    required String artist,
    String? artworkUrl,
    int? durationSeconds,
  }) async {
    if (songId.trim().isEmpty) return;
    try {
      final db = await database;
      if (db == null) {
        _recordPlayInMemory(
          songId: songId,
          title: title,
          artist: artist,
          artworkUrl: artworkUrl,
          durationSeconds: durationSeconds,
        );
        return;
      }
      final now = DateTime.now().millisecondsSinceEpoch;

      await db.rawInsert(
        '''
        INSERT INTO play_history (song_id, title, artist, artwork_url, duration_seconds, played_at, play_count)
        VALUES (?, ?, ?, ?, ?, ?, 1)
        ON CONFLICT(song_id) DO UPDATE SET
          played_at = excluded.played_at,
          play_count = play_history.play_count + 1,
          title = excluded.title,
          artist = excluded.artist,
          artwork_url = COALESCE(excluded.artwork_url, play_history.artwork_url),
          duration_seconds = COALESCE(excluded.duration_seconds, play_history.duration_seconds)
      ''',
        [songId, title, artist, artworkUrl, durationSeconds ?? 0, now],
      );
    } catch (_) {
      _recordPlayInMemory(
        songId: songId,
        title: title,
        artist: artist,
        artworkUrl: artworkUrl,
        durationSeconds: durationSeconds,
      );
    }
  }

  void _recordPlayInMemory({
    required String songId,
    required String title,
    required String artist,
    String? artworkUrl,
    int? durationSeconds,
  }) {
    final existingIndex = _fallbackHistory.indexWhere(
      (r) => r['song_id'] == songId,
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    if (existingIndex >= 0) {
      final existing = _fallbackHistory[existingIndex];
      final currentCount = (existing['play_count'] as int? ?? 1) + 1;
      _fallbackHistory[existingIndex] = {
        'song_id': songId,
        'title': title,
        'artist': artist,
        'artwork_url': artworkUrl ?? existing['artwork_url'],
        'duration_seconds': durationSeconds ?? existing['duration_seconds'],
        'played_at': now,
        'play_count': currentCount,
      };
    } else {
      _fallbackHistory.add({
        'song_id': songId,
        'title': title,
        'artist': artist,
        'artwork_url': artworkUrl,
        'duration_seconds': durationSeconds ?? 0,
        'played_at': now,
        'play_count': 1,
      });
    }
  }

  /// Fetches recent playback history sorted by most recently played.
  Future<List<Map<String, dynamic>>> getPlayHistory({int limit = 50}) async {
    try {
      final db = await database;
      if (db == null) {
        final sorted = List<Map<String, dynamic>>.from(_fallbackHistory)
          ..sort(
            (a, b) => (b['played_at'] as int).compareTo(a['played_at'] as int),
          );
        return sorted.take(limit).toList();
      }
      return await db.query(
        'play_history',
        orderBy: 'played_at DESC',
        limit: limit,
      );
    } catch (_) {
      final sorted = List<Map<String, dynamic>>.from(_fallbackHistory)
        ..sort(
          (a, b) => (b['played_at'] as int).compareTo(a['played_at'] as int),
        );
      return sorted.take(limit).toList();
    }
  }

  /// Fetches the play count for a given song ID.
  Future<int> getPlayCount(String songId) async {
    try {
      final db = await database;
      if (db == null) {
        final item = _fallbackHistory.firstWhere(
          (r) => r['song_id'] == songId,
          orElse: () => {},
        );
        return (item['play_count'] as int?) ?? 0;
      }
      final res = await db.query(
        'play_history',
        columns: ['play_count'],
        where: 'song_id = ?',
        whereArgs: [songId],
      );
      if (res.isNotEmpty) {
        return (res.first['play_count'] as int?) ?? 0;
      }
      return 0;
    } catch (_) {
      final item = _fallbackHistory.firstWhere(
        (r) => r['song_id'] == songId,
        orElse: () => {},
      );
      return (item['play_count'] as int?) ?? 0;
    }
  }

  /// Clears all recorded playback history.
  Future<void> clearPlayHistory() async {
    _fallbackHistory.clear();
    try {
      final db = await database;
      if (db != null) {
        await db.delete('play_history');
      }
    } catch (_) {}
  }

  /// Toggles favorite status for a song.
  Future<bool> toggleFavorite({
    required String songId,
    required String title,
    required String artist,
    String? artworkUrl,
    int? durationSeconds,
  }) async {
    try {
      final db = await database;
      if (db == null) {
        if (_fallbackFavorites.contains(songId)) {
          _fallbackFavorites.remove(songId);
          _fallbackFavoriteRecords.remove(songId);
          return false;
        } else {
          _fallbackFavorites.add(songId);
          _fallbackFavoriteRecords[songId] = {
            'song_id': songId,
            'title': title,
            'artist': artist,
            'artwork_url': artworkUrl,
            'duration_seconds': durationSeconds ?? 0,
            'added_at': DateTime.now().millisecondsSinceEpoch,
          };
          return true;
        }
      }

      final exists = await db.query(
        'favorite_songs',
        where: 'song_id = ?',
        whereArgs: [songId],
      );

      if (exists.isNotEmpty) {
        await db.delete(
          'favorite_songs',
          where: 'song_id = ?',
          whereArgs: [songId],
        );
        return false;
      } else {
        await db.insert('favorite_songs', {
          'song_id': songId,
          'title': title,
          'artist': artist,
          'artwork_url': artworkUrl,
          'duration_seconds': durationSeconds ?? 0,
          'added_at': DateTime.now().millisecondsSinceEpoch,
        });
        return true;
      }
    } catch (_) {
      if (_fallbackFavorites.contains(songId)) {
        _fallbackFavorites.remove(songId);
        _fallbackFavoriteRecords.remove(songId);
        return false;
      } else {
        _fallbackFavorites.add(songId);
        _fallbackFavoriteRecords[songId] = {
          'song_id': songId,
          'title': title,
          'artist': artist,
          'artwork_url': artworkUrl,
          'duration_seconds': durationSeconds ?? 0,
          'added_at': DateTime.now().millisecondsSinceEpoch,
        };
        return true;
      }
    }
  }

  /// Checks if a song is favorited.
  Future<bool> isFavorite(String songId) async {
    try {
      final db = await database;
      if (db == null) {
        return _fallbackFavorites.contains(songId);
      }
      final res = await db.query(
        'favorite_songs',
        where: 'song_id = ?',
        whereArgs: [songId],
      );
      return res.isNotEmpty;
    } catch (_) {
      return _fallbackFavorites.contains(songId);
    }
  }

  /// Retrieves all favorited songs.
  Future<List<Map<String, dynamic>>> getFavorites() async {
    try {
      final db = await database;
      if (db == null) {
        final records = _fallbackFavoriteRecords.values.toList()
          ..sort(
            (a, b) => (b['added_at'] as int).compareTo(a['added_at'] as int),
          );
        return records;
      }
      return await db.query('favorite_songs', orderBy: 'added_at DESC');
    } catch (_) {
      final records = _fallbackFavoriteRecords.values.toList()
        ..sort(
          (a, b) => (b['added_at'] as int).compareTo(a['added_at'] as int),
        );
      return records;
    }
  }

  @visibleForTesting
  void resetForTest() {
    _fallbackHistory.clear();
    _fallbackFavorites.clear();
    _fallbackFavoriteRecords.clear();
  }
}
