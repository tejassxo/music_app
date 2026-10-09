import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import '../../models/song_item.dart';
import '../canonical_song_dedup.dart';

/// Pure Dart state controller for the playback queue.
/// Completely decoupled from audio decoding hardware and platform bridges.
/// Protects against button spam race conditions via an internal navigation mutex.
class QueueController with ChangeNotifier {
  List<SongItem> _playlist = [];
  int _currentIndex = -1;

  LoopMode _loopMode = LoopMode.off;
  bool _hasRepeatedOnce = false;

  bool _isShuffle = false;
  final List<int> _shuffleHistory = [];
  int _shuffleHistoryPointer = -1;

  final List<SongItem> _sessionHistory = [];

  /// Concurrency lock preventing overlapping navigation operations (e.g. Next button spam).
  bool _isNavigating = false;
  DateTime _lastNavigatedTime = DateTime.fromMillisecondsSinceEpoch(0);
  int debounceMilliseconds = 150;

  /// Callback triggered when queue has fewer than [lowQueueThreshold] songs remaining.
  void Function(SongItem seedSong)? onLowQueue;
  int lowQueueThreshold = 3;

  List<SongItem> get playlist => List.unmodifiable(_playlist);
  int get currentIndex => _currentIndex;
  SongItem? get currentSong =>
      (_currentIndex >= 0 && _currentIndex < _playlist.length)
      ? _playlist[_currentIndex]
      : null;

  LoopMode get loopMode => _loopMode;
  bool get isShuffle => _isShuffle;
  bool get isNavigating => _isNavigating;
  bool get hasRepeatedOnce => _hasRepeatedOnce;

  bool get hasNext {
    if (_playlist.isEmpty) return false;
    if (_loopMode == LoopMode.all) return true;
    if (_isShuffle) return _playlist.length > 1;
    return _currentIndex + 1 < _playlist.length;
  }

  bool get hasPrevious {
    if (_playlist.isEmpty) return false;
    if (_isShuffle && _shuffleHistoryPointer > 0) return true;
    if (_sessionHistory.isNotEmpty) return true;
    return _currentIndex > 0;
  }

  /// Initialize or replace the queue with a new playlist.
  void setPlaylist(List<SongItem> songs, {int initialIndex = 0}) {
    _playlist = List<SongItem>.from(songs);
    _currentIndex = _playlist.isEmpty
        ? -1
        : initialIndex.clamp(0, _playlist.length - 1);
    _resetShuffleState();
    _checkLowQueue();
    notifyListeners();
  }

  /// Add a song to the very end of the playlist.
  void addTrack(SongItem song) {
    _playlist.add(song);
    if (_currentIndex == -1) {
      _currentIndex = 0;
    }
    notifyListeners();
  }

  /// Insert a song immediately after the current playing song.
  void insertNext(SongItem song) {
    if (_playlist.isEmpty || _currentIndex == -1) {
      _playlist.add(song);
      _currentIndex = 0;
    } else {
      _playlist.insert(_currentIndex + 1, song);
    }
    notifyListeners();
  }

  /// Bulk append candidate tracks (e.g. from autoplay recommender).
  void appendTracks(List<SongItem> newTracks) {
    if (newTracks.isEmpty) return;
    _playlist.addAll(newTracks);
    notifyListeners();
  }

  /// Move track position inside queue (e.g. drag & drop).
  void reorder(int oldIndex, int newIndex) {
    if (oldIndex < 0 ||
        oldIndex >= _playlist.length ||
        newIndex < 0 ||
        newIndex > _playlist.length) {
      return;
    }

    final song = _playlist.removeAt(oldIndex);
    int target = newIndex;
    if (newIndex > oldIndex) {
      target -= 1;
    }
    _playlist.insert(target, song);

    // Keep active song pointer pointing to the same track
    if (_currentIndex == oldIndex) {
      _currentIndex = target;
    } else if (oldIndex < _currentIndex && target >= _currentIndex) {
      _currentIndex -= 1;
    } else if (oldIndex > _currentIndex && target <= _currentIndex) {
      _currentIndex += 1;
    }

    _resetShuffleState();
    notifyListeners();
  }

  /// Remove a song at given index.
  void removeAt(int index) {
    if (index < 0 || index >= _playlist.length) return;

    _playlist.removeAt(index);
    if (_playlist.isEmpty) {
      _currentIndex = -1;
    } else if (index < _currentIndex) {
      _currentIndex -= 1;
    } else if (_currentIndex >= _playlist.length) {
      _currentIndex = _playlist.length - 1;
    }

    _resetShuffleState();
    notifyListeners();
  }

  /// Clear the entire queue.
  void clear() {
    _playlist.clear();
    _currentIndex = -1;
    _resetShuffleState();
    _sessionHistory.clear();
    notifyListeners();
  }

  /// Advance to the next track with mutex locking against button spam.
  Future<SongItem?> nextTrack({
    bool isAutoAdvance = false,
    bool force = false,
  }) async {
    final now = DateTime.now();
    if (_isNavigating ||
        (!force &&
            !isAutoAdvance &&
            now.difference(_lastNavigatedTime).inMilliseconds <
                debounceMilliseconds)) {
      debugPrint(
        '[QueueController] Navigation in progress or debounced: discarding spam request.',
      );
      return currentSong;
    }

    _isNavigating = true;
    _lastNavigatedTime = now;
    try {
      if (_playlist.isEmpty) return null;

      // Handle LoopMode.one single repeat logic
      if (isAutoAdvance && _loopMode == LoopMode.one && currentSong != null) {
        if (!_hasRepeatedOnce) {
          _hasRepeatedOnce = true;
          debugPrint('[QueueController] LoopMode.one repeat once.');
          return currentSong;
        } else {
          _hasRepeatedOnce = false;
          _loopMode = LoopMode.off;
        }
      }

      final prevSong = currentSong;
      if (prevSong != null) {
        _sessionHistory.add(prevSong);
      }

      // 1. Shuffle traversal
      if (_isShuffle && _playlist.length > 1) {
        if (_shuffleHistoryPointer + 1 < _shuffleHistory.length) {
          _shuffleHistoryPointer++;
          _currentIndex = _shuffleHistory[_shuffleHistoryPointer];
        } else {
          _currentIndex = _calculateNextShuffleIndex();
          _shuffleHistory.add(_currentIndex);
          _shuffleHistoryPointer = _shuffleHistory.length - 1;
        }
      }
      // 2. Linear traversal
      else if (_currentIndex + 1 < _playlist.length) {
        _currentIndex++;
      }
      // 3. Loop all
      else if (_loopMode == LoopMode.all && _playlist.isNotEmpty) {
        _currentIndex = 0;
      }
      // 4. End of queue reached
      else {
        _checkLowQueue();
        return null;
      }

      _checkLowQueue();
      notifyListeners();
      return currentSong;
    } finally {
      _isNavigating = false;
    }
  }

  /// Step backward in queue or history with mutex locking.
  Future<SongItem?> previousTrack({bool force = false}) async {
    final now = DateTime.now();
    if (_isNavigating ||
        (!force &&
            now.difference(_lastNavigatedTime).inMilliseconds <
                debounceMilliseconds)) {
      debugPrint(
        '[QueueController] Navigation in progress or debounced: discarding spam request.',
      );
      return currentSong;
    }

    _isNavigating = true;
    _lastNavigatedTime = now;
    try {
      if (_playlist.isEmpty) return null;

      // 1. Reverse traversal through true shuffle history
      if (_isShuffle && _shuffleHistoryPointer > 0) {
        _shuffleHistoryPointer--;
        _currentIndex = _shuffleHistory[_shuffleHistoryPointer];
        notifyListeners();
        return currentSong;
      }

      // 2. Session cross-playlist history fallback
      if (_sessionHistory.isNotEmpty) {
        final prevSong = _sessionHistory.removeLast();
        final existingIdx = _playlist.indexWhere((s) => s.id == prevSong.id);
        if (existingIdx != -1) {
          _currentIndex = existingIdx;
        } else {
          _playlist.insert(max(0, _currentIndex), prevSong);
        }
        notifyListeners();
        return currentSong;
      }

      // 3. Standard linear previous
      if (_currentIndex > 0) {
        _currentIndex--;
        notifyListeners();
        return currentSong;
      }

      return currentSong;
    } finally {
      _isNavigating = false;
    }
  }

  /// Set the active playing index directly.
  void setIndex(int index) {
    if (index >= 0 && index < _playlist.length) {
      _currentIndex = index;
      _checkLowQueue();
      notifyListeners();
    }
  }

  void toggleShuffle() {
    _isShuffle = !_isShuffle;
    _resetShuffleState();
    notifyListeners();
  }

  void setShuffle(bool enabled) {
    if (_isShuffle != enabled) {
      _isShuffle = enabled;
      _resetShuffleState();
      notifyListeners();
    }
  }

  void toggleLoopMode() {
    switch (_loopMode) {
      case LoopMode.off:
        _loopMode = LoopMode.all;
        break;
      case LoopMode.all:
        _loopMode = LoopMode.one;
        _hasRepeatedOnce = false;
        break;
      case LoopMode.one:
        _loopMode = LoopMode.off;
        _hasRepeatedOnce = false;
        break;
    }
    notifyListeners();
  }

  void setLoopMode(LoopMode mode) {
    _loopMode = mode;
    _hasRepeatedOnce = false;
    notifyListeners();
  }

  // --- Internal Helper Algorithms ---

  int _calculateNextShuffleIndex() {
    final random = Random();
    final currentArtist = currentSong != null
        ? CanonicalSongDedup.cleanArtist(currentSong!.author)
        : '';

    final candidateIndices = <int>[];
    for (int i = 0; i < _playlist.length; i++) {
      if (i == _currentIndex) continue;
      final artist = CanonicalSongDedup.cleanArtist(_playlist[i].author);
      if (currentArtist.isEmpty || artist != currentArtist) {
        candidateIndices.add(i);
      }
    }

    if (candidateIndices.isNotEmpty) {
      return candidateIndices[random.nextInt(candidateIndices.length)];
    }
    return (random.nextInt(_playlist.length - 1) + _currentIndex + 1) %
        _playlist.length;
  }

  void _resetShuffleState() {
    _shuffleHistory.clear();
    if (_currentIndex != -1) {
      _shuffleHistory.add(_currentIndex);
      _shuffleHistoryPointer = 0;
    } else {
      _shuffleHistoryPointer = -1;
    }
  }

  void _checkLowQueue() {
    if (_playlist.isEmpty || _currentIndex == -1) return;
    final remaining = _playlist.length - (_currentIndex + 1);
    if (remaining <= lowQueueThreshold && currentSong != null) {
      onLowQueue?.call(currentSong!);
    }
  }
}
