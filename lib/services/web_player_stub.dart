import 'dart:async';

/// Stub implementation for non-web platforms (Android, iOS mobile, desktop).
/// Ensures zero web dependencies are compiled into mobile native builds.
class WebPlayerBridge {
  static bool get isSupported => false;
  static bool get isPlaying => false;
  static Duration get currentPosition => Duration.zero;
  static Duration get currentDuration => Duration.zero;

  static Stream<Duration> get positionStream => const Stream.empty();
  static Stream<Duration> get durationStream => const Stream.empty();
  static Stream<String> get stateStream => const Stream.empty();
  static Stream<void> get onTrackEnded => const Stream.empty();
  static Stream<void> get onNext => const Stream.empty();
  static Stream<void> get onPrevious => const Stream.empty();
  static Stream<int> get onError => const Stream.empty();

  static void init() {}

  static void play(
    String videoId, {
    String? title,
    String? artist,
    String? artworkUrl,
    double startSeconds = 0,
    String? streamUrl,
  }) {}

  static void pause() {}

  static void resume() {}

  static void seek(Duration position) {}

  static void setVolume(double volume) {}

  static void crossfade({
    required String videoId,
    String? title,
    String? artist,
    String? artworkUrl,
    String? streamUrl,
    int crossfadeSeconds = 4,
  }) {}

  static void setEqualizer(bool enabled, Map<int, double> bands) {}

  static void setFallbackVideoId(String realYtId) {}
}
