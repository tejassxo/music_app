import 'dart:async';
import '../web_player_bridge.dart';
import 'i_audio_engine.dart';

/// Concrete implementation of [IAudioEngine] using [WebPlayerBridge] for Flutter Web (HTML5 / JS Audio).
class WebAudioEngine implements IAudioEngine {
  final StreamController<AudioEngineStatus> _statusController =
      StreamController<AudioEngineStatus>.broadcast();

  StreamSubscription<String>? _stateSub;
  AudioEngineStatus _currentStatus = AudioEngineStatus.idle;

  WebAudioEngine() {
    WebPlayerBridge.init();
    _stateSub = WebPlayerBridge.stateStream.listen((state) {
      final newStatus = _mapState(state);
      if (newStatus != _currentStatus) {
        _currentStatus = newStatus;
        _statusController.add(_currentStatus);
      }
    });
  }

  AudioEngineStatus _mapState(String state) {
    switch (state.toLowerCase()) {
      case 'playing':
        return AudioEngineStatus.playing;
      case 'paused':
        return AudioEngineStatus.paused;
      case 'buffering':
        return AudioEngineStatus.buffering;
      case 'loading':
        return AudioEngineStatus.loading;
      case 'ended':
        return AudioEngineStatus.completed;
      default:
        return AudioEngineStatus.idle;
    }
  }

  @override
  AudioEngineStatus get status => _currentStatus;

  @override
  Duration get position => WebPlayerBridge.currentPosition;

  @override
  Duration get duration => WebPlayerBridge.currentDuration;

  @override
  bool get isPlaying => WebPlayerBridge.isPlaying;

  @override
  Stream<AudioEngineStatus> get statusStream => _statusController.stream;

  @override
  Stream<Duration> get positionStream => WebPlayerBridge.positionStream;

  @override
  Stream<Duration> get durationStream => WebPlayerBridge.durationStream;

  @override
  Stream<void> get onTrackEnded => WebPlayerBridge.onTrackEnded;

  @override
  Stream<int> get onError => WebPlayerBridge.onError;

  @override
  Future<void> load(
    String streamUrl, {
    Duration startPosition = Duration.zero,
    Map<String, dynamic>? metadata,
  }) async {
    _currentStatus = AudioEngineStatus.loading;
    _statusController.add(_currentStatus);

    final videoId = metadata?['videoId'] as String? ?? '';
    final title = metadata?['title'] as String?;
    final artist = metadata?['artist'] as String?;
    final artworkUrl = metadata?['artworkUrl'] as String?;

    WebPlayerBridge.play(
      videoId,
      title: title,
      artist: artist,
      artworkUrl: artworkUrl,
      startSeconds: startPosition.inMilliseconds / 1000.0,
      streamUrl: streamUrl,
    );
  }

  @override
  Future<void> play() async {
    WebPlayerBridge.resume();
  }

  @override
  Future<void> pause() async {
    WebPlayerBridge.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    WebPlayerBridge.seek(position);
  }

  @override
  Future<void> setVolume(double volume) async {
    WebPlayerBridge.setVolume(volume.clamp(0.0, 1.0));
  }

  @override
  Future<void> stop() async {
    WebPlayerBridge.pause();
    WebPlayerBridge.seek(Duration.zero);
    _currentStatus = AudioEngineStatus.idle;
    _statusController.add(_currentStatus);
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _statusController.close();
  }
}
