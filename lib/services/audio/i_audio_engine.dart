/// High-level engine status states.
enum AudioEngineStatus {
  idle,
  buffering,
  loading,
  playing,
  paused,
  completed,
  error,
}

/// Abstract contract for hardware/platform playback engines.
/// Eliminates ad-hoc platform conditionals (kIsWeb) from business logic.
abstract class IAudioEngine {
  AudioEngineStatus get status;
  Duration get position;
  Duration get duration;
  bool get isPlaying;

  Stream<AudioEngineStatus> get statusStream;
  Stream<Duration> get positionStream;
  Stream<Duration> get durationStream;
  Stream<void> get onTrackEnded;
  Stream<int> get onError;

  /// Prepare and buffer a track by stream URL.
  Future<void> load(
    String streamUrl, {
    Duration startPosition = Duration.zero,
    Map<String, dynamic>? metadata,
  });

  /// Resume playback.
  Future<void> play();

  /// Pause playback.
  Future<void> pause();

  /// Seek to duration.
  Future<void> seek(Duration position);

  /// Set volume (0.0 to 1.0).
  Future<void> setVolume(double volume);

  /// Stop playback and release deck resources.
  Future<void> stop();

  /// Free all resources.
  void dispose();
}
