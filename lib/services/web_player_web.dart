import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:web/web.dart' as web;
import 'api_config.dart';

/// Modern Web implementation for Flutter Web using dart:js_interop & package:web.
/// Controls the invisible YouTube IFrame player and Web MediaSession API.
class WebPlayerBridge {
  static bool get isSupported => true;
  static bool _isPlaying = false;
  static Duration _currentPosition = Duration.zero;
  static Duration _currentDuration = Duration.zero;

  static final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();
  static final StreamController<Duration> _durationController =
      StreamController<Duration>.broadcast();
  static final StreamController<String> _stateController =
      StreamController<String>.broadcast();
  static final StreamController<void> _endedController =
      StreamController<void>.broadcast();
  static final StreamController<void> _nextController =
      StreamController<void>.broadcast();
  static final StreamController<void> _prevController =
      StreamController<void>.broadcast();
  static final StreamController<int> _errorController =
      StreamController<int>.broadcast();

  static bool get isPlaying => _isPlaying;
  static Duration get currentPosition => _currentPosition;
  static Duration get currentDuration => _currentDuration;

  static Stream<Duration> get positionStream => _positionController.stream;
  static Stream<Duration> get durationStream => _durationController.stream;
  static Stream<String> get stateStream => _stateController.stream;
  static Stream<void> get onTrackEnded => _endedController.stream;
  static Stream<void> get onNext => _nextController.stream;
  static Stream<void> get onPrevious => _prevController.stream;
  static Stream<int> get onError => _errorController.stream;

  static bool _initialized = false;

  static void init() {
    if (_initialized) return;
    _initialized = true;

    web.window.addEventListener(
      'dilse_time_update',
      (web.Event event) {
        try {
          final customEvent = event as web.CustomEvent;
          final detail = customEvent.detail;
          if (detail != null) {
            final jsObj = detail as JSObject;
            final posVal = jsObj.getProperty('position'.toJS);
            final durVal = jsObj.getProperty('duration'.toJS);
            final pos = (posVal as JSNumber?)?.toDartDouble ?? 0.0;
            final dur = (durVal as JSNumber?)?.toDartDouble ?? 0.0;
            _currentPosition = Duration(milliseconds: (pos * 1000).toInt());
            _currentDuration = Duration(milliseconds: (dur * 1000).toInt());
            _positionController.add(_currentPosition);
            _durationController.add(_currentDuration);
          }
        } catch (_) {}
      }.toJS,
    );

    web.window.addEventListener(
      'dilse_state_change',
      (web.Event event) {
        try {
          final customEvent = event as web.CustomEvent;
          final detail = customEvent.detail;
          if (detail != null) {
            final jsObj = detail as JSObject;
            final stateVal = jsObj.getProperty('state'.toJS);
            final state = (stateVal as JSString?)?.toDart ?? 'unknown';
            if (state == 'playing') {
              _isPlaying = true;
            } else if (state == 'paused' ||
                state == 'ended' ||
                state == 'idle') {
              _isPlaying = false;
            }
            _stateController.add(state);
          }
        } catch (_) {}
      }.toJS,
    );

    web.window.addEventListener(
      'dilse_ended',
      ((web.Event _) {
        _isPlaying = false;
        _endedController.add(null);
      }).toJS,
    );

    web.window.addEventListener(
      'dilse_remote_next',
      ((web.Event _) {
        _nextController.add(null);
      }).toJS,
    );

    web.window.addEventListener(
      'dilse_remote_prev',
      ((web.Event _) {
        _prevController.add(null);
      }).toJS,
    );

    web.window.addEventListener(
      'dilse_remote_play',
      ((web.Event _) {
        _isPlaying = true;
        _stateController.add('playing');
      }).toJS,
    );

    web.window.addEventListener(
      'dilse_remote_pause',
      ((web.Event _) {
        _isPlaying = false;
        _stateController.add('paused');
      }).toJS,
    );

    web.window.addEventListener(
      'dilse_error',
      ((web.Event event) {
        try {
          final customEvent = event as web.CustomEvent;
          final detail = customEvent.detail;
          int code = 0;
          if (detail != null) {
            final jsObj = detail as JSObject;
            final codeVal = jsObj.getProperty('code'.toJS);
            code = (codeVal as JSNumber?)?.toDartInt ?? 0;
          }
          _isPlaying = false;
          _errorController.add(code);
        } catch (_) {}
      }).toJS,
    );
  }

  static void play(
    String videoId, {
    String? title,
    String? artist,
    String? artworkUrl,
    double startSeconds = 0,
    String? streamUrl,
  }) {
    init();
    _isPlaying = true;
    _stateController.add('buffering');

    final globalWindow = web.window as JSObject;

    // Set configured backend base URL and worker base URL
    final apiBase = ApiConfig.baseUrl;
    globalWindow.setProperty('dilseApiBaseUrl'.toJS, apiBase.toJS);

    final workerBase = ApiConfig.cloudflareWorkerUrl;
    globalWindow.setProperty('dilseWorkerBaseUrl'.toJS, workerBase.toJS);

    // Set direct stream URL if provided
    globalWindow.setProperty(
      'dilseCurrentStreamUrl'.toJS,
      (streamUrl ?? '').toJS,
    );

    // Update MediaSession
    if (globalWindow.hasProperty('dilseSetMetadata'.toJS).toDart) {
      globalWindow.callMethod(
        'dilseSetMetadata'.toJS,
        (title ?? 'DilSe Song').toJS,
        (artist ?? 'DilSe Music').toJS,
        (artworkUrl ?? '').toJS,
      );
    }

    if (globalWindow.hasProperty('dilsePlay'.toJS).toDart) {
      globalWindow.callMethod(
        'dilsePlay'.toJS,
        videoId.toJS,
        startSeconds.toJS,
        (title ?? '').toJS,
        (artist ?? '').toJS,
      );
    }
  }

  static void pause() {
    _isPlaying = false;
    _stateController.add('paused');
    final globalWindow = web.window as JSObject;
    if (globalWindow.hasProperty('dilsePause'.toJS).toDart) {
      globalWindow.callMethod('dilsePause'.toJS);
    }
  }

  static void resume() {
    _isPlaying = true;
    _stateController.add('playing');
    final globalWindow = web.window as JSObject;
    if (globalWindow.hasProperty('dilseResume'.toJS).toDart) {
      globalWindow.callMethod('dilseResume'.toJS);
    }
  }

  static void seek(Duration position) {
    _currentPosition = position;
    _positionController.add(position);
    final seconds = position.inMilliseconds / 1000.0;
    final globalWindow = web.window as JSObject;
    if (globalWindow.hasProperty('dilseSeek'.toJS).toDart) {
      globalWindow.callMethod('dilseSeek'.toJS, seconds.toJS);
    }
  }

  static void setVolume(double volume) {
    final normalized = (volume > 1.0 ? volume / 100.0 : volume).clamp(0.0, 1.0);
    final globalWindow = web.window as JSObject;
    if (globalWindow.hasProperty('dilseSetVolume'.toJS).toDart) {
      globalWindow.callMethod('dilseSetVolume'.toJS, (normalized * 100).toJS);
    }
  }

  static void crossfade({
    required String videoId,
    String? title,
    String? artist,
    String? artworkUrl,
    String? streamUrl,
    int crossfadeSeconds = 4,
  }) {
    init();
    _isPlaying = true;
    _stateController.add('playing');

    final globalWindow = web.window as JSObject;

    final apiBase = ApiConfig.baseUrl;
    globalWindow.setProperty('dilseApiBaseUrl'.toJS, apiBase.toJS);

    final workerBase = ApiConfig.cloudflareWorkerUrl;
    globalWindow.setProperty('dilseWorkerBaseUrl'.toJS, workerBase.toJS);

    globalWindow.setProperty(
      'dilseCurrentStreamUrl'.toJS,
      (streamUrl ?? '').toJS,
    );
    globalWindow.setProperty(
      'dilseCrossfadeSeconds'.toJS,
      crossfadeSeconds.toJS,
    );

    if (globalWindow.hasProperty('dilseSetMetadata'.toJS).toDart) {
      globalWindow.callMethod(
        'dilseSetMetadata'.toJS,
        (title ?? 'DilSe Song').toJS,
        (artist ?? 'DilSe Music').toJS,
        (artworkUrl ?? '').toJS,
      );
    }

    if (globalWindow.hasProperty('dilseCrossfade'.toJS).toDart) {
      globalWindow.callMethod(
        'dilseCrossfade'.toJS,
        videoId.toJS,
        (title ?? '').toJS,
        (artist ?? '').toJS,
        (artworkUrl ?? '').toJS,
      );
    } else {
      play(
        videoId,
        title: title,
        artist: artist,
        artworkUrl: artworkUrl,
        streamUrl: streamUrl,
      );
    }
  }

  static void setEqualizer(bool enabled, Map<int, double> bands) {
    final globalWindow = web.window as JSObject;
    if (globalWindow.hasProperty('dilseSetEqualizer'.toJS).toDart) {
      final mapForJson = bands.map((k, v) => MapEntry(k.toString(), v));
      final bandsJson = json.encode(mapForJson);
      globalWindow.callMethod(
        'dilseSetEqualizer'.toJS,
        enabled.toJS,
        bandsJson.toJS,
      );
    }
  }

  static void setFallbackVideoId(String realYtId) {
    final globalWindow = web.window as JSObject;
    if (globalWindow.hasProperty('dilseSetFallbackVideoId'.toJS).toDart) {
      globalWindow.callMethod('dilseSetFallbackVideoId'.toJS, realYtId.toJS);
    }
  }
}
