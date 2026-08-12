// Where the alarm sound comes from, in both of the places it has to come from.
//
// Arc plays the alarm itself while it is alive, and hands it to Android when it
// is not. Those are two different consumers with two different rules:
//
//   in-process   audioplayers, given a file path or a bundled asset
//   out-of-process  a notification channel, which the OS plays — and the OS
//                   cannot read a path inside Arc's private storage
//
// So a custom sound is copied into `<app files>/timer_sound/`, addressed as a
// content:// URI through Arc's own FileProvider, and read permission on that
// URI is granted to the system UI (see MainActivity). The default needs none of
// this: it ships as a raw resource, which the OS can always reach.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The asset audioplayers plays in-process for Arc's own tone. Byte-identical
/// to `res/raw/arc_rest.wav`; both are written by `tool/make_rest_tone.mjs`.
const String kDefaultSoundAsset = 'sound/arc_rest.wav';

/// The raw resource the notification channel names for the same tone. No
/// extension — Android resource names never carry one.
const String kDefaultSoundResource = 'arc_rest';

/// Must match `android:authorities` on the provider in AndroidManifest.xml,
/// which is `${applicationId}.timerprovider` for the id fixed in
/// `android/app/build.gradle.kts`.
const String _authority = 'com.arc.arc.timerprovider';

/// Matches the `name` of the `<files-path>` entry in `res/xml/timer_sound_paths.xml`
/// and the directory it points at. FileProvider composes its URIs as
/// `content://<authority>/<name>/<path under root>`, so the two have to agree.
const String _soundDir = 'timer_sound';

const MethodChannel _channel = MethodChannel('arc/timer_sound');

/// The custom-alarm file: choosing one, addressing it, and throwing it away.
class TimerSound {
  TimerSound._();

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Copies [source] into Arc's storage and returns the stored path, or null if
  /// the copy failed.
  ///
  /// A copy rather than a reference because the document the picker handed over
  /// is a temporary grant: it can be revoked, moved, or deleted the moment the
  /// picker closes, and an alarm that stops working next week because a file
  /// was tidied is worse than no custom alarm at all.
  ///
  /// The stored name carries a fingerprint of the source, so picking a
  /// different file always produces a different path. That is what lets
  /// [TimerNotifier] tell "the sound changed" from "the sound is the same" —
  /// an Android channel's sound is fixed at creation, so a change means
  /// rebuilding the channel, and doing that on every save would reset the
  /// user's own channel tweaks for nothing.
  static Future<String?> store(String sourcePath, String displayName) async {
    if (!_supported) return null;
    try {
      final src = File(sourcePath);
      final bytes = await src.readAsBytes();
      final dir = Directory(p.join((await _root()).path, _soundDir));
      await dir.create(recursive: true);

      // Fingerprint, not the user's filename: names arrive with spaces,
      // emoji and non-ASCII that a content URI would have to escape, and two
      // different files are routinely both called "alarm.mp3".
      final stamp = Object.hash(displayName, bytes.length,
              bytes.length < 2048 ? Object.hashAll(bytes) : bytes[bytes.length ~/ 2])
          .toUnsigned(32)
          .toRadixString(16);
      final ext = _extension(sourcePath, displayName);
      final dest = File(p.join(dir.path, 'alarm_$stamp$ext'));

      await _clear(dir, keep: dest.path);
      if (!await dest.exists()) await dest.writeAsBytes(bytes, flush: true);
      await _grant(uriFor(dest.path));
      return dest.path;
    } catch (e) {
      debugPrint('Arc timer: could not store the chosen sound ($e)');
      return null;
    }
  }

  /// The content:// URI the notification channel can name for [path].
  static String uriFor(String path) =>
      'content://$_authority/$_soundDir/${p.basename(path)}';

  /// Re-issues the system UI's read permission on the stored sound.
  ///
  /// Called at launch as well as at pick time: URI grants do not survive a
  /// reboot, and the first alarm after one is exactly the one nobody is
  /// watching Arc for.
  static Future<void> refreshGrant(String? path) async {
    if (path == null || !_supported) return;
    await _grant(uriFor(path));
  }

  /// Drops the stored sound and its directory. Returning to Arc's own tone.
  static Future<void> discard() async {
    if (!_supported) return;
    try {
      final dir = Directory(p.join((await _root()).path, _soundDir));
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      debugPrint('Arc timer: could not discard the stored sound ($e)');
    }
  }

  /// Whether [path] still names a file Arc can play. A stored sound can go
  /// missing when the OS clears app data partially or a restore skips it.
  static Future<bool> exists(String? path) async {
    if (path == null) return false;
    try {
      return File(path).exists();
    } catch (_) {
      return false;
    }
  }

  /// `getApplicationSupportDirectory` is Android's `getFilesDir()`, which is
  /// what `<files-path>` in the provider config is rooted at. The documents
  /// directory is *not* — path_provider maps that to `app_flutter/`, a sibling
  /// the provider cannot see.
  static Future<Directory> _root() => getApplicationSupportDirectory();

  static Future<void> _grant(String uri) async {
    try {
      await _channel.invokeMethod<bool>('grantSoundUri', {'uri': uri});
    } on PlatformException catch (e) {
      // The sound still plays in-app; only the killed-process case degrades to
      // the system default, and that is worth a log rather than a failure.
      debugPrint('Arc timer: sound URI not granted ($e)');
    } on MissingPluginException {
      // Hot-restarted onto an engine that predates the channel.
      debugPrint('Arc timer: sound URI grant unavailable');
    }
  }

  /// Removes every stored sound except [keep] — one custom alarm at a time, so
  /// replacing one does not quietly leave the old file behind forever.
  static Future<void> _clear(Directory dir, {required String keep}) async {
    await for (final entity in dir.list()) {
      if (entity is File && entity.path != keep) {
        try {
          await entity.delete();
        } catch (_) {
          // Held open by the media player mid-preview; it will be replaced on
          // the next pick anyway.
        }
      }
    }
  }

  /// Prefers the extension the user's own filename carries, since that is what
  /// the source of truth for the format is; falls back to the temp file's.
  static String _extension(String sourcePath, String displayName) {
    for (final candidate in [p.extension(displayName), p.extension(sourcePath)]) {
      if (candidate.length > 1 && candidate.length <= 5) {
        return candidate.toLowerCase();
      }
    }
    return '.mp3';
  }
}
