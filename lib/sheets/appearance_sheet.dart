import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../theme/accent.dart';
import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';
import '../widgets/hue_slider.dart';
import '../widgets/ui.dart';

const _lblSize = 11.5;

Widget _label(String text) => Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 8),
      child: Text(
        text.toUpperCase(),
        style: AppText.ui(
          size: _lblSize,
          weight: FontWeight.w700,
          color: AppColors.muted,
          letterSpacing: 0.5,
        ),
      ),
    );

/// Light/dark plus the accent hue, in one overlay.
///
/// Changes commit live and persist on their own — no Save, no Cancel. This is a
/// preference, not a form, and the whole point is watching the app repaint
/// underneath while the slider moves.
class AppearanceSheet extends StatelessWidget {
  const AppearanceSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeController>();
    final dark = theme.isDark;
    final hue = theme.accentHue;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _label('Theme'),
        Segmented(
          options: const [SegOption('light', 'Light'), SegOption('dark', 'Dark')],
          value: dark ? 'dark' : 'light',
          onChanged: (v) {
            HapticFeedback.selectionClick();
            theme.setDark(v == 'dark');
          },
        ),
        const SizedBox(height: 24),

        // Label and readout share a line — the slider's thumb already shows the
        // colour, so a separate swatch here would just repeat it.
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(child: _label('Accent')),
            Text(
              AccentRamp.nameFor(hue),
              style: AppText.ui(size: 14, weight: FontWeight.w700),
            ),
            const SizedBox(width: 7),
            Text(
              '$hue°',
              style: AppText.mono(
                  size: 13, weight: FontWeight.w600, color: AppColors.muted),
            ),
          ],
        ),
        HueSlider(
          hue: hue,
          dark: dark,
          onChanged: theme.setAccentHue,
        ),

        // Reset sits with the control it undoes rather than in the sheet's
        // title row, where at 200% text it squeezed the title into breaking
        // mid-word ("Appear / ance"). Its row is always present — the sheet is
        // bottom-anchored, so a control appearing here mid-drag would push the
        // track up under the user's finger and make the hue jump.
        const Align(
          alignment: Alignment.centerRight,
          child: AppearanceResetAction(),
        ),
      ],
    );
  }
}

/// Returns the active theme to Arc's shipped accent. Appears only once there's
/// something to undo, so the default state carries no spare chrome.
class AppearanceResetAction extends StatelessWidget {
  const AppearanceResetAction({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeController>();

    final pill = Container(
      // 44 tall minimum per PRODUCT's touch-target floor; the pill itself is
      // smaller, and the constraint supplies the rest of the target.
      constraints: const BoxConstraints(minHeight: 44),
      alignment: Alignment.centerRight,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: AppColors.surface2,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          'Reset',
          style: AppText.ui(
              size: 13, weight: FontWeight.w600, color: AppColors.muted),
        ),
      ),
    );

    // Reserved rather than measured: `maintainSize` keeps the hidden state
    // exactly as tall as the shown one at every text scale, which a hard-coded
    // height could not (at 200% the pill outgrows 44 and crowds the section
    // below).
    if (theme.isAccentDefault) {
      return Visibility(
        visible: false,
        maintainSize: true,
        maintainAnimation: true,
        maintainState: true,
        child: pill,
      );
    }

    return Semantics(
      button: true,
      label: 'Reset accent to default',
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          theme.resetAccent();
        },
        behavior: HitTestBehavior.opaque,
        child: pill,
      ),
    );
  }
}
