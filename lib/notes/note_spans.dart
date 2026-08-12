import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'note_doc.dart';
import 'note_glyphs.dart';

/// Turns a [NoteDoc] into spans. One builder for all three places a note is
/// read — the editor, the preview on the workout overlay, and a companion's
/// read-only view — so a note cannot look like three different notes.
///
/// Every colour and face is resolved here at build time, never cached: the app
/// rebuilds its whole shell on a theme or accent change (`lib/main.dart`), and
/// anything holding a `const` colour would come back wearing the old palette.

/// The four steps A⁻ / A⁺ walk. Normal is the second: one step down, two up,
/// so the buttons do something more than once in the direction people use.
const List<double> noteSizeSteps = [14.5, 16.5, 20, 24];

/// The reading size of a run, before any [noteSpans] scale.
double noteFontSize(int attrs) =>
    noteSizeSteps[NoteAttr.sizeStep(attrs).clamp(0, noteSizeSteps.length - 1)];

/// The style one set of marks resolves to.
TextStyle noteStyle(int attrs, {double scale = 1}) {
  final step = NoteAttr.sizeStep(attrs);
  final size = noteFontSize(attrs) * scale;
  final bold = NoteAttr.has(attrs, NoteAttr.bold);

  return AppText.ui(
    size: size,
    weight: bold ? FontWeight.w700 : FontWeight.w400,
    // Prose, not a data row: notes are read in sentences and want the air.
    // The two big steps tighten up, the way a heading does.
    height: step >= 2 ? 1.32 : 1.52,
    letterSpacing: step >= 3
        ? -0.5
        : step == 2
            ? -0.3
            : -0.05,
  ).copyWith(
    fontStyle:
        NoteAttr.has(attrs, NoteAttr.italic) ? FontStyle.italic : FontStyle.normal,
    decoration: NoteAttr.has(attrs, NoteAttr.underline)
        ? TextDecoration.underline
        : TextDecoration.none,
    // Sora's own stroke, not a hairline: an underline thinner than the letters
    // it sits under reads as an artefact.
    decorationThickness: 1.4,
    decorationColor: AppColors.ink.withValues(alpha: 0.55),
    backgroundColor:
        NoteAttr.has(attrs, NoteAttr.highlight) ? AppColors.highlight : null,
  );
}

/// [onToggleCheck] receives the offset of the mark that was tapped; null leaves
/// the boxes inert, which is what a companion gets.
///
/// [scale] shrinks the whole ramp for the preview on the workout overlay, so a
/// note previewed there keeps its own hierarchy instead of flattening.
List<InlineSpan> noteSpans(
  NoteDoc doc, {
  double scale = 1,
  void Function(int markOffset)? onToggleCheck,
}) {
  final text = doc.text;
  if (text.isEmpty) return const [];

  final attrs = doc.attrsPerChar();

  // Offsets of the marks that lead a line. A box character anywhere else is
  // just a character the user typed, and is left alone.
  final marks = <int>{};
  for (var i = 0; i < text.length; i++) {
    if (i == 0 || text[i - 1] == '\n') {
      final c = text[i];
      if (c == checkEmpty || c == checkDone) marks.add(i);
    }
  }

  final spans = <InlineSpan>[];
  var i = 0;
  while (i < text.length) {
    if (marks.contains(i)) {
      final size = noteFontSize(attrs[i]) * scale;
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        // A WidgetSpan occupies exactly one character position, which is why
        // the mark can be one character: every offset behind it — the caret,
        // the selection, the run table — stays where it was.
        child: Padding(
          padding: EdgeInsets.only(right: size * 0.06),
          child: NoteCheckbox(
            checked: text[i] == checkDone,
            fontSize: size,
            onTap: onToggleCheck == null ? null : () => onToggleCheck(i),
          ),
        ),
      ));
      i++;
      continue;
    }

    final a = attrs[i];
    var j = i + 1;
    while (j < text.length && attrs[j] == a && !marks.contains(j)) {
      j++;
    }
    spans.add(TextSpan(text: text.substring(i, j), style: noteStyle(a, scale: scale)));
    i = j;
  }
  return spans;
}
