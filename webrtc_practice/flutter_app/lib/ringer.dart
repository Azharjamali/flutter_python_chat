import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:vibration/vibration.dart';

/// Plays the phone's default call ringtone and vibrates while ringing.
class Ringer {
  final FlutterRingtonePlayer _player = FlutterRingtonePlayer();
  bool _playing = false;

  Future<void> start() async {
    if (_playing) return;
    _playing = true;

    await _player.playRingtone(looping: true, volume: 1.0);

    if (await Vibration.hasVibrator()) {
      if (await Vibration.hasCustomVibrationsSupport()) {
        await Vibration.vibrate(pattern: [0, 800, 400, 800], repeat: 0);
      } else {
        await Vibration.vibrate(duration: 800);
      }
    }
  }

  Future<void> stop() async {
    if (!_playing) return;
    _playing = false;
    await _player.stop();
    await Vibration.cancel();
  }

  Future<void> dispose() async {
    await stop();
  }
}
