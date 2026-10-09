import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'i_audio_engine.dart';

/// Concrete implementation of [IAudioEngine] using `just_audio` for native platforms (Android, iOS, desktop).
class MobileAudioEngine implements IAudioEngine {
  final AudioPlayer _player;
  final bool _ownsPlayer;

  final StreamController<AudioEngineStatus> _statusController =
      StreamController<AudioEngineStatus>.broadcast();
  final StreamController<void> _endedController =
      StreamController<void>.broadcast();
  final StreamController<int> _errorController =
      StreamController<int>.broadcast();

  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<PlaybackEvent>? _eventSub;

  AudioEngineStatus _currentStatus = AudioEngineStatus.idle;

  MobileAudioEngine([AudioPlayer? player])
    : _player = player ?? AudioPlayer(),
      _ownsPlayer = player == null {
    _initListeners();
  }

  void _initListeners() {
    _stateSub = _player.playerStateStream.listen((state) {
      final newStatus = _mapState(state);
      if (newStatus != _currentStatus) {
        _currentStatus = newStatus;
        _statusController.add(_currentStatus);
      }

      if (state.processingState == ProcessingState.completed) {
        // Spurious completion protection
        final curPos = _player.position;
        final curDur = _player.duration;
        if (curDur != null &&
            curDur.inSeconds > 10 &&
            (curDur - curPos).inSeconds > 8 &&
            curPos.inSeconds < (curDur.inSeconds * 0.85).round()) {
          debugPrint(
            '[MobileAudioEngine] Ignoring spurious completion event at ${curPos.inSeconds}s / ${curDur.inSeconds}s',
          );
          return;
        }
        _endedController.add(null);
      }
    });

    _eventSub = _player.playbackEventStream.listen(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('[MobileAudioEngine] Playback error: $error');
        _currentStatus = AudioEngineStatus.error;
        _statusController.add(AudioEngineStatus.error);
        _errorController.add(-1);
      },
    );
  }

  AudioEngineStatus _mapState(PlayerState state) {
    if (state.processingState == ProcessingState.loading) {
      return AudioEngineStatus.loading;
    }
    if (state.processingState == ProcessingState.buffering) {
      return AudioEngineStatus.buffering;
    }
    if (state.processingState == ProcessingState.completed) {
      return AudioEngineStatus.completed;
    }
    if (state.processingState == ProcessingState.idle) {
      return AudioEngineStatus.idle;
    }
    return state.playing ? AudioEngineStatus.playing : AudioEngineStatus.paused;
  }

  @override
  AudioEngineStatus get status => _currentStatus;

  @override
  Duration get position => _player.position;

  @override
  Duration get duration => _player.duration ?? Duration.zero;

  @override
  bool get isPlaying => _player.playing;

  @override
  Stream<AudioEngineStatus> get statusStream => _statusController.stream;

  @override
  Stream<Duration> get positionStream => _player.positionStream;

  @override
  Stream<Duration> get durationStream =>
      _player.durationStream.map((d) => d ?? Duration.zero);

  @override
  Stream<void> get onTrackEnded => _endedController.stream;

  @override
  Stream<int> get onError => _errorController.stream;

  @override
  Future<void> load(
    String streamUrl, {
    Duration startPosition = Duration.zero,
    Map<String, dynamic>? metadata,
  }) async {
    _currentStatus = AudioEngineStatus.loading;
    _statusController.add(_currentStatus);

    final uri = Uri.parse(streamUrl);
    await _player.setAudioSource(
      AudioSource.uri(uri),
      initialPosition: startPosition > Duration.zero ? startPosition : null,
    );
  }

  @override
  Future<void> play() async {
    await _player.play();
  }

  @override
  Future<void> pause() async {
    await _player.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    await _player.seek(position);
  }

  @override
  Future<void> setVolume(double volume) async {
    await _player.setVolume(volume.clamp(0.0, 1.0));
  }

  @override
  Future<void> stop() async {
    await _player.stop();
    _currentStatus = AudioEngineStatus.idle;
    _statusController.add(_currentStatus);
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _eventSub?.cancel();
    _statusController.close();
    _endedController.close();
    _errorController.close();
    if (_ownsPlayer) {
      _player.dispose();
    }
  }
}
