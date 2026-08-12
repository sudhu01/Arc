// The buzz at zero, when Arc is the one making it.
//
// This is only half the story: the other half is `timer_notification.dart`,
// which hands the same job to Android for the case where Arc is not running to
// do it. The two are never armed at once — see TimerController's lifecycle
// handling — so a rest ends with exactly one alarm.

import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:vibration/vibration.dart';

import 'timer_settings.dart';
import 'timer_sound.dart';

/// Three long pulses. Long enough to feel through a pocket and through the
/// padding of a gym bag, spaced enough not to read as one continuous buzz — the
/// same rhythm as the default tone's three beeps, so silent mode is the same
/// alarm with the sound taken out rather than a different signal.
const List<int> kAlarmVibration = <int>[0, 400, 180, 400, 180, 620];

/// A short double tap: what a *manual* start feels like, so starting the timer
/// by hand is confirmed without a sound in a quiet gym.
const List<int> kStartVibration = <int>[0, 18, 60, 26];

/// Plays Arc's rest alarm.
///
/// One player, reused. Creating one per alarm leaks a platform media player on
/// every set, which on a long session is a hundred of them.
class TimerAlarm {
  TimerAlarm() : _player = AudioPlayer(playerId: 'arc.rest.alarm') {
    // The alarm stream, not the media stream. This is what makes the buzz
    // audible with the ringer turned down, which is the state a phone is in on
    // a gym floor roughly always. `sonification` tells the OS this is a signal
    // rather than content, so it is never resumed or ducked as if it were
    // music; `gainTransientMayDuck` lets whatever the user is listening to
    // dip for a second rather than stop.
    unawaited(_player.setAudioContext(
      AudioContext(
        android: const AudioContextAndroid(
          contentType: AndroidContentType.sonification,
          usageType: AndroidUsageType.alarm,
          audioFocus: AndroidAudioFocus.gainTransientMayDuck,
        ),
      ),
    ));
    unawaited(_player.setReleaseMode(ReleaseMode.stop));
  }

  final AudioPlayer _player;
  bool _disposed = false;

  /// Fires the alarm for a finished rest: sound unless [settings] silences it,
  /// and the buzz either way.
  ///
  /// "Vibrate only" removes the sound, never the alarm — a user who chose it
  /// still needs to know the rest is over.
  Future<void> ring(TimerSettings settings) async {
    await Future.wait([
      if (!settings.silent) play(settings),
      buzz(kAlarmVibration),
    ]);
  }

  /// Plays the configured sound once, whatever it is. Also what the settings
  /// screen's preview uses — previewing through the real path is the only way
  /// the preview can be trusted.
  Future<void> play(TimerSettings settings) async {
    if (_disposed) return;
    try {
      final custom = settings.soundPath;
      if (custom != null && await TimerSound.exists(custom)) {
        await _player.play(DeviceFileSource(custom));
      } else {
        await _player.play(AssetSource(kDefaultSoundAsset));
      }
    } catch (e) {
      // A codec the device refuses, or a file that vanished between the check
      // and the play. The vibration still lands, so the alarm is not lost.
      debugPrint('Arc timer: alarm sound failed ($e)');
    }
  }

  /// Stops a sound already ringing — the user acknowledging it, or a new rest
  /// starting on top of the last one.
  Future<void> silence() async {
    if (_disposed) return;
    try {
      await _player.stop();
      await Vibration.cancel();
    } catch (e) {
      debugPrint('Arc timer: could not silence the alarm ($e)');
    }
  }

  /// Runs a vibration pattern, if this device has a motor at all.
  static Future<void> buzz(List<int> pattern) async {
    try {
      if (!await Vibration.hasVibrator()) return;
      await Vibration.vibrate(pattern: pattern);
    } catch (e) {
      debugPrint('Arc timer: vibration unavailable ($e)');
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await _player.dispose();
  }
}
