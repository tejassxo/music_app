import 'package:flutter/foundation.dart';
import 'i_audio_engine.dart';
import 'mobile_audio_engine.dart';
import 'web_audio_engine.dart';

/// Factory providing the appropriate platform [IAudioEngine] instance.
class AudioEngineFactory {
  static IAudioEngine createEngine() {
    if (kIsWeb) {
      return WebAudioEngine();
    } else {
      return MobileAudioEngine();
    }
  }
}
