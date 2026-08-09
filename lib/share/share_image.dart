import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'workout_card.dart';

/// Turns a laid-out [ShareWorkoutCard] into a JPEG and hands it to the system
/// share sheet.
///
/// The card is captured from a `RepaintBoundary` that keeps its own fixed
/// 360 × 450 layout however it's displayed, so the export is 1080 × 1350
/// whatever phone it was made on.
class ShareImage {
  ShareImage._();

  static const _quality = 92;

  /// Rasterizes the boundary behind [key] and opens the share sheet.
  ///
  /// Throws on failure rather than swallowing it — the caller surfaces the
  /// problem, since a share button that silently does nothing is worse than one
  /// that says it couldn't.
  static Future<void> shareCard({
    required GlobalKey key,
    required String date,
    String? title,
  }) async {
    final bytes = await encodeCard(key);
    final file = await _write(bytes, date);

    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: 'image/jpeg')],
        // Named for the receiving app's preview, not as a caption — the card
        // already carries everything the workout has to say.
        fileNameOverrides: [_fileName(date)],
        subject: title,
      ),
    );
  }

  /// The card as JPEG bytes. Split out so it can be exercised without a share
  /// sheet in reach.
  static Future<Uint8List> encodeCard(GlobalKey key) async {
    final boundary =
        key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) {
      throw StateError('The workout card is not on screen to capture.');
    }

    final image = await boundary.toImage(
      pixelRatio: ShareWorkoutCard.pixelRatio,
    );
    try {
      // Raw RGBA rather than PNG: `image` can take the pixels straight, so
      // nothing is spent compressing a bitmap that's about to be re-encoded.
      final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (raw == null) throw StateError('Could not read the captured card.');

      final decoded = img.Image.fromBytes(
        width: image.width,
        height: image.height,
        bytes: raw.buffer,
        numChannels: 4,
      );
      return img.encodeJpg(decoded, quality: _quality);
    } finally {
      image.dispose();
    }
  }

  static String _fileName(String date) => 'arc-workout-$date.jpg';

  /// Writes to a dedicated temp folder, cleared first so shares don't pile up
  /// in the app's cache over time.
  static Future<File> _write(Uint8List bytes, String date) async {
    final dir = Directory('${(await getTemporaryDirectory()).path}/arc-share');
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    await dir.create(recursive: true);

    final file = File('${dir.path}/${_fileName(date)}');
    await file.writeAsBytes(bytes);
    return file;
  }
}
