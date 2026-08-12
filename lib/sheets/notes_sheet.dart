import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../data/arc_data.dart';
import '../data/models.dart';
import '../data/store.dart';
import '../notes/note_controller.dart';
import '../notes/note_doc.dart';
import '../notes/note_glyphs.dart';
import '../notes/note_spans.dart';
import '../theme/app_theme.dart';
import '../widgets/arc_icons.dart';

/// What the user wrote about one workout.
///
/// Opened over the day sheet, full height, because writing is the whole task
/// while it is on screen — the workout underneath is context, not something to
/// keep half-visible.
///
/// There is no save button. The note commits when the sheet leaves and on a
/// pause in typing; a note is not a form, and asking someone to confirm their
/// own sentence is a step that exists only to reassure the app.
class NotesSheet extends StatefulWidget {
  final Session session;

  /// A companion's workout. Reads, does not write: no toolbar, no history, and
  /// the checkboxes are theirs to tick, not ours.
  final bool readOnly;

  const NotesSheet({super.key, required this.session, this.readOnly = false});

  @override
  State<NotesSheet> createState() => _NotesSheetState();
}

class _NotesSheetState extends State<NotesSheet> {
  static const _limit = 5000;

  late final NoteDoc _initial = NoteDoc.decode(widget.session.notes);
  late final RichNoteController _c = RichNoteController(_initial);
  final _focus = FocusNode();
  final _toolbarKey = GlobalKey();

  late final ArcStore _store;
  Timer? _debounce;
  String? _saved;

  @override
  void initState() {
    super.initState();
    _saved = widget.session.notes;
    if (widget.readOnly) return;
    _store = context.read<ArcStore>();
    _c.addListener(_onEdited);
    // A blank note wants the keyboard; one already written wants to be read
    // first. Opening a month-old note under a keyboard hides the half of it
    // that was worth opening it for.
    if (_initial.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    // `_c` is lazy: a read-only note never builds a controller, so there is
    // nothing to tear down on that path either.
    if (!widget.readOnly) {
      _c.removeListener(_onEdited);
      // Every exit runs through here — back arrow, system back, drag-dismiss,
      // a tap on the scrim — so this is the one place the write has to happen.
      unawaited(_persist(_c.doc));
      _c.dispose();
    }
    _focus.dispose();
    super.dispose();
  }

  void _onEdited() {
    // The toolbar's lit buttons and the history arrows both read controller
    // state, so they follow the caret as well as the text.
    if (mounted) setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 900), () {
      unawaited(_persist(_c.doc));
    });
  }

  Future<void> _persist(NoteDoc doc) async {
    final encoded = doc.isEmpty ? null : doc.encode();
    if (encoded == _saved) return;
    _saved = encoded;
    await _store.setSessionNotes(widget.session.date, encoded);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final keyboardUp = media.viewInsets.bottom > 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(),
        const SizedBox(height: 12),
        _titleBlock(),
        const SizedBox(height: 13),
        Container(height: 1, color: AppColors.line),
        Expanded(child: widget.readOnly ? _reader() : _editor()),
        if (!widget.readOnly) _toolbar(),
        // The sheet's own bottom padding is zero so the toolbar can sit against
        // the keyboard. With the keyboard down, the gesture bar needs clearing.
        SizedBox(height: keyboardUp ? 10 : 10 + media.padding.bottom),
      ],
    );
  }

  // ── Header ──────────────────────────────────────────────────────────

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          _circleButton(
            icon: 'back',
            label: 'Back to workout',
            onTap: () => Navigator.of(context).maybePop(),
          ),
          const Spacer(),
          if (!widget.readOnly) ...[
            _circleButton(
              icon: 'undo',
              label: 'Undo',
              enabled: _c.canUndo,
              onTap: _c.undo,
            ),
            const SizedBox(width: 3),
            _circleButton(
              icon: 'redo',
              label: 'Redo',
              enabled: _c.canRedo,
              onTap: _c.redo,
            ),
          ],
        ],
      ),
    );
  }

  /// The 34px circle the sheet's own close button uses, so the note's chrome
  /// belongs to the same set of controls as everything it opened from.
  Widget _circleButton({
    required String icon,
    required String label,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    return Semantics(
      button: true,
      label: label,
      enabled: enabled,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled
            ? () {
                HapticFeedback.selectionClick();
                onTap();
              }
            : null,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: enabled
                    ? AppColors.surface2
                    : AppColors.surface2.withValues(alpha: 0.5),
                shape: BoxShape.circle,
              ),
              child: ArcIcon(icon,
                  size: 18,
                  color: enabled ? AppColors.muted : AppColors.faint),
            ),
          ),
        ),
      ),
    );
  }

  Widget _titleBlock() {
    final year = ArcData.parseISO(widget.session.date).year;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Notes',
          style: AppText.ui(
              size: 30,
              weight: FontWeight.w700,
              height: 1.06,
              letterSpacing: -0.6),
        ),
        const SizedBox(height: 7),
        Row(
          children: [
            // Both halves flex: at 200% text scale a fixed date would push the
            // rule and the workout name straight off the edge.
            Flexible(
              child: Text(
                '${ArcData.fmtDate(widget.session.date, 'long')} $year',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.ui(
                    size: 13, weight: FontWeight.w500, color: AppColors.muted),
              ),
            ),
            Container(
              width: 1,
              height: 11,
              margin: const EdgeInsets.symmetric(horizontal: 10),
              color: AppColors.line,
            ),
            // The one thing on this line that isn't a timestamp: which workout
            // this note belongs to. It carries the weight to match.
            Flexible(
              child: Text(
                widget.session.displayTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.ui(size: 13, weight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ── Body ────────────────────────────────────────────────────────────

  Widget _editor() {
    final base = noteStyle(0);
    return TextSelectionTheme(
      data: TextSelectionThemeData(
        cursorColor: AppColors.accentStrong,
        selectionColor: AppColors.accent.withValues(alpha: 0.32),
        selectionHandleColor: AppColors.accentStrong,
      ),
      child: TextField(
        controller: _c,
        focusNode: _focus,
        maxLines: null,
        expands: true,
        textAlignVertical: TextAlignVertical.top,
        keyboardType: TextInputType.multiline,
        textCapitalization: TextCapitalization.sentences,
        cursorColor: AppColors.accentStrong,
        cursorWidth: 2.2,
        cursorRadius: const Radius.circular(2),
        style: base,
        inputFormatters: [LengthLimitingTextInputFormatter(_limit)],
        // The default drops focus on any tap outside the field, which would
        // include every button on the formatting bar — the keyboard would
        // close under the finger that pressed Bold. Taps on the bar are part
        // of writing; everything else still puts the keyboard away.
        onTapOutside: (event) {
          if (_hitsToolbar(event.position)) return;
          _focus.unfocus();
        },
        scrollPadding: const EdgeInsets.only(bottom: 96),
        decoration: InputDecoration(
          isCollapsed: true,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.only(top: 16, bottom: 24),
          hintText: 'Start writing',
          hintStyle: base.copyWith(color: AppColors.faint),
        ),
      ),
    );
  }

  bool _hitsToolbar(Offset global) {
    final box = _toolbarKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return false;
    return (box.localToGlobal(Offset.zero) & box.size).contains(global);
  }

  Widget _reader() {
    if (_initial.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ArcIcon('note', size: 34, color: AppColors.faint),
            const SizedBox(height: 12),
            Text('Nothing written here.',
                style: AppText.ui(size: 14.5, color: AppColors.muted)),
          ],
        ),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: 16, bottom: 24),
      child: SelectableText.rich(
        TextSpan(children: noteSpans(_initial)),
        selectionColor: AppColors.accent.withValues(alpha: 0.32),
      ),
    );
  }

  // ── Formatting bar ──────────────────────────────────────────────────

  Widget _toolbar() {
    final attrs = _c.activeAttrs;
    return Container(
      key: _toolbarKey,
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: AppRadii.rMd,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _tool(
            label: 'Checklist',
            active: _c.isCheckLine,
            onTap: _c.cycleCheck,
            builder: (color) => ArcIcon('checkbox',
                size: 21, color: color, filled: _c.isCheckLine),
          ),
          _tool(
            label: 'Highlight',
            active: NoteAttr.has(attrs, NoteAttr.highlight),
            onTap: () => _c.toggleMark(NoteAttr.highlight),
            builder: (color) => HighlighterGlyph(size: 21, color: color),
          ),
          _tool(
            label: 'Bigger text',
            enabled: _c.canGrow,
            onTap: () => _c.stepSize(1),
            builder: (color) => ArcIcon('textUp', size: 22, color: color),
          ),
          _tool(
            label: 'Smaller text',
            enabled: _c.canShrink,
            onTap: () => _c.stepSize(-1),
            builder: (color) => ArcIcon('textDown', size: 22, color: color),
          ),
          _tool(
            label: 'Bold',
            active: NoteAttr.has(attrs, NoteAttr.bold),
            onTap: () => _c.toggleMark(NoteAttr.bold),
            builder: (color) => ArcIcon('bold', size: 22, color: color),
          ),
          _tool(
            label: 'Italic',
            active: NoteAttr.has(attrs, NoteAttr.italic),
            onTap: () => _c.toggleMark(NoteAttr.italic),
            builder: (color) => ArcIcon('italic', size: 22, color: color),
          ),
          _tool(
            label: 'Underline',
            active: NoteAttr.has(attrs, NoteAttr.underline),
            onTap: () => _c.toggleMark(NoteAttr.underline),
            builder: (color) => ArcIcon('underline', size: 22, color: color),
          ),
        ],
      ),
    );
  }

  /// One control on the bar. [builder] takes the glyph colour so the drawn
  /// highlighter and the registry glyphs light up identically.
  Widget _tool({
    required String label,
    required Widget Function(Color) builder,
    required VoidCallback onTap,
    bool active = false,
    bool enabled = true,
  }) {
    final color = !enabled
        ? AppColors.faint.withValues(alpha: 0.45)
        : active
            ? AppColors.accentStrong
            : AppColors.muted;

    return Expanded(
      child: Semantics(
        button: true,
        toggled: active,
        enabled: enabled,
        label: label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled
              ? () {
                  HapticFeedback.selectionClick();
                  onTap();
                }
              : null,
          child: SizedBox(
            height: 44,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 130),
                curve: Curves.easeOutQuart,
                width: 40,
                height: 34,
                decoration: BoxDecoration(
                  color: active ? AppColors.accentSoft : Colors.transparent,
                  borderRadius: AppRadii.rSm,
                ),
                child: Center(child: builder(color)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
