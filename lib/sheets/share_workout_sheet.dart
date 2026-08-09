import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../share/share_image.dart';
import '../share/workout_card.dart';
import '../theme/app_theme.dart';
import '../widgets/arc_icons.dart';
import '../widgets/ui.dart';

/// Shows the graphic before it leaves the app, then shares it.
///
/// The preview isn't decoration: what gets posted is a picture of the user's
/// training, and they should see it before it's in someone else's chat. It's
/// also the honest way to render — the card is captured from the boundary shown
/// here, so what's previewed is exactly what's shared.
class ShareWorkoutSheet extends StatefulWidget {
  const ShareWorkoutSheet({
    super.key,
    required this.session,
    required this.exById,
  });

  final Session session;
  final Exercise? Function(String) exById;

  @override
  State<ShareWorkoutSheet> createState() => _ShareWorkoutSheetState();
}

class _ShareWorkoutSheetState extends State<ShareWorkoutSheet> {
  final _cardKey = GlobalKey();
  var _busy = false;

  Future<void> _share() async {
    if (_busy) return;
    setState(() => _busy = true);
    HapticFeedback.selectionClick();
    try {
      await ShareImage.shareCard(
        key: _cardKey,
        date: widget.session.date,
        title: widget.session.displayTitle,
      );
    } catch (_) {
      _notify("Couldn't create the image.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The app's dark pill toast, same as the pairing scanner's.
  void _notify(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.toastBg,
        duration: const Duration(milliseconds: 2300),
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ArcIcon('x', size: 18, color: AppColors.toastInk),
            const SizedBox(width: 9),
            Flexible(
              child: Text(
                msg,
                style: AppText.ui(
                    size: 14.5,
                    weight: FontWeight.w600,
                    color: AppColors.toastInk),
              ),
            ),
          ],
        ),
      ));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // The boundary keeps its own fixed 360 × 450 layout whatever this
        // scales it to on screen, so the capture is 1080 × 1350 on every phone.
        ConstrainedBox(
          constraints:
              BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.5),
          child: FittedBox(
            fit: BoxFit.contain,
            child: RepaintBoundary(
              key: _cardKey,
              child: ShareWorkoutCard(
                session: widget.session,
                exById: widget.exById,
              ),
            ),
          ),
        ),
        const SizedBox(height: 18),
        ArcButton(
          label: _busy ? 'Preparing…' : 'Share',
          icon: 'share',
          full: true,
          disabled: _busy,
          onTap: _share,
        ),
      ],
    );
  }
}
