import 'dart:math' show max, min;

import 'package:flutter/material.dart';
import 'note_doc.dart';
import 'note_spans.dart';

/// A [TextEditingController] that edits a [NoteDoc] instead of a bare string.
///
/// The field still edits one flat string — that is all a platform text input
/// can do — so this class's whole job is keeping the run table honest as those
/// characters move. Every change arrives through [value]; the diff there is the
/// single point where formatting is carried across an edit, which is why there
/// is no other path that writes [doc].
class RichNoteController extends TextEditingController {
  RichNoteController(NoteDoc initial)
      : _doc = initial,
        super(text: initial.text);

  NoteDoc _doc;
  NoteDoc get doc => _doc;

  /// Marks staged by the toolbar at a bare caret, waiting for the next
  /// character. Held with the offset they were staged at: move the caret and
  /// they are gone, which is what "I pressed B, then changed my mind and
  /// tapped elsewhere" should mean.
  int? _pendingAttrs;
  int _pendingOffset = -1;

  bool _applying = false;

  final List<_Snap> _undo = [];
  final List<_Snap> _redo = [];
  static const _undoLimit = 60;
  int _lastRecordMs = 0;
  bool _lastWasInsert = false;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  // ── What the toolbar reads ──────────────────────────────────────────

  /// The marks in force right now: staged ones at a bare caret, the marks
  /// common to a selection otherwise. Drives which toolbar buttons light up.
  int get activeAttrs {
    final sel = selection;
    if (!sel.isValid) return _pendingAttrs ?? 0;
    if (sel.isCollapsed) return _pendingAttrs ?? _doc.attrsAt(sel.baseOffset);
    return _doc.attrsOver(min(sel.start, sel.end), max(sel.start, sel.end));
  }

  /// Read from one end of the selection rather than from [activeAttrs], whose
  /// size bits are an intersection and mean nothing across mixed sizes.
  int get sizeStep {
    final sel = selection;
    final at = sel.isValid ? min(sel.start, sel.end) : 0;
    return NoteAttr.sizeStep(_pendingAttrs ?? _doc.attrsAt(at));
  }

  bool get isCheckLine =>
      selection.isValid && _doc.checkMarkAt(selection.baseOffset) != null;

  // ── Formatting ──────────────────────────────────────────────────────

  /// Turn one mark on or off over the selection, or stage it at a bare caret.
  void toggleMark(int flag) {
    final sel = selection;
    if (!sel.isValid) return;

    if (sel.isCollapsed) {
      final current = _pendingAttrs ?? _doc.attrsAt(sel.baseOffset);
      _pendingAttrs = current ^ flag;
      _pendingOffset = sel.baseOffset;
      notifyListeners();
      return;
    }

    final s = min(sel.start, sel.end);
    final e = max(sel.start, sel.end);
    final on = NoteAttr.has(_doc.attrsOver(s, e), flag);
    _record(force: true);
    _apply(
      _doc.mapAttrs(s, e, (a) => on ? a & ~flag : a | flag),
      sel,
    );
  }

  /// Step the size of the selection, or of the next thing typed. [delta] is
  /// +1 for A⁺ and -1 for A⁻; the whole selection lands on one size rather
  /// than each run moving independently, because "make this bigger" is one
  /// instruction and a selection that came back with three sizes would be
  /// surprising.
  void stepSize(int delta) {
    final sel = selection;
    if (!sel.isValid) return;
    final target =
        (sizeStep + delta).clamp(NoteAttr.minSizeStep, NoteAttr.maxSizeStep);
    if (target == sizeStep) return;

    if (sel.isCollapsed) {
      _pendingAttrs =
          NoteAttr.withSizeStep(_pendingAttrs ?? _doc.attrsAt(sel.baseOffset), target);
      _pendingOffset = sel.baseOffset;
      notifyListeners();
      return;
    }

    final s = min(sel.start, sel.end);
    final e = max(sel.start, sel.end);
    _record(force: true);
    _apply(_doc.mapAttrs(s, e, (a) => NoteAttr.withSizeStep(a, target)), sel);
  }

  bool get canGrow => sizeStep < NoteAttr.maxSizeStep;
  bool get canShrink => sizeStep > NoteAttr.minSizeStep;

  /// The toolbar's checklist button: walks the caret's line through
  /// none → unchecked → checked → none.
  void cycleCheck() {
    final sel = selection;
    if (!sel.isValid) return;
    _record(force: true);
    final (next, shift) = _doc.cycleCheck(sel.baseOffset);
    _apply(
      next,
      TextSelection.collapsed(
        offset: (sel.baseOffset + shift).clamp(0, next.text.length),
      ),
    );
  }

  /// A tap on a drawn box. Text length does not change, so the caret is left
  /// exactly where the writer had it.
  void toggleCheckAt(int markOffset) {
    _record(force: true);
    _apply(_doc.toggleCheckAt(markOffset), selection);
  }

  // ── Undo / redo ─────────────────────────────────────────────────────

  void undo() {
    if (_undo.isEmpty) return;
    final snap = _undo.removeLast();
    _redo.add(_Snap(_doc, selection));
    _lastRecordMs = 0;
    _apply(snap.doc, snap.sel, record: false);
  }

  void redo() {
    if (_redo.isEmpty) return;
    final snap = _redo.removeLast();
    _undo.add(_Snap(_doc, selection));
    _lastRecordMs = 0;
    _apply(snap.doc, snap.sel, record: false);
  }

  /// Snapshot the state *before* a change.
  ///
  /// Consecutive typing inside [_coalesceMs] collapses into one entry, so undo
  /// takes back a word rather than a keystroke — and a run of insertions never
  /// merges with a run of deletions, which is the boundary people actually
  /// expect the undo to stop at.
  static const _coalesceMs = 600;

  void _record({bool force = false, bool isInsert = false}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final coalesce = !force &&
        _undo.isNotEmpty &&
        isInsert == _lastWasInsert &&
        now - _lastRecordMs < _coalesceMs;
    _lastRecordMs = now;
    _lastWasInsert = isInsert;
    if (coalesce) return;

    _undo.add(_Snap(_doc, selection));
    if (_undo.length > _undoLimit) _undo.removeAt(0);
    _redo.clear();
  }

  // ── The edit path ───────────────────────────────────────────────────

  @override
  set value(TextEditingValue newValue) {
    if (_applying || newValue.text == _doc.text) {
      if (!_applying) _dropStalePending(newValue.selection);
      super.value = newValue;
      return;
    }

    final (start, end, insert) = _diff(_doc.text, newValue.text);
    final staged = _pendingOffset == start ? _pendingAttrs : null;

    _record(isInsert: insert.isNotEmpty && end == start);
    var next = _doc.replaced(start, end, insert, insertAttrs: staged);
    var sel = newValue.selection;

    // Enter on a checklist line carries the list on — and an Enter on an empty
    // one ends it. Without both, a checklist is a one-line novelty: every item
    // after the first would have to be added from the toolbar, and there would
    // be no way out of the list except backspacing over the mark.
    if (insert == '\n' && end == start && start > 0) {
      final prev = next.lineStart(start);
      if (next.checkMarkAt(prev) != null) {
        final body = next.text.substring(min(prev + 2, start), start);
        if (body.trim().isEmpty) {
          final drop = min(2, start - prev);
          next = next.replaced(prev, prev + drop, '');
          sel = TextSelection.collapsed(
              offset: (sel.baseOffset - drop).clamp(0, next.text.length));
        } else {
          next = next.replaced(start + 1, start + 1, '$checkEmpty ',
              insertAttrs: next.attrsAt(prev + 1));
          sel = TextSelection.collapsed(
              offset: (sel.baseOffset + 2).clamp(0, next.text.length));
        }
      }
    }

    if (staged != null) {
      _pendingOffset = start + insert.length;
    } else {
      _clearPending();
    }

    _doc = next;
    _applying = true;
    super.value = TextEditingValue(
      text: next.text,
      selection: _clamp(sel, next.text.length),
      composing: TextRange.empty,
    );
    _applying = false;
    _dropStalePending(selection);
  }

  void _apply(NoteDoc next, TextSelection sel, {bool record = false}) {
    if (record) _record(force: true);
    _doc = next;
    _clearPending();
    _applying = true;
    super.value = TextEditingValue(
      text: next.text,
      selection: _clamp(sel, next.text.length),
      composing: TextRange.empty,
    );
    _applying = false;
  }

  void _clearPending() {
    _pendingAttrs = null;
    _pendingOffset = -1;
  }

  void _dropStalePending(TextSelection sel) {
    if (_pendingAttrs == null) return;
    if (!sel.isCollapsed || sel.baseOffset != _pendingOffset) _clearPending();
  }

  static TextSelection _clamp(TextSelection sel, int length) {
    if (!sel.isValid) return TextSelection.collapsed(offset: length);
    return TextSelection(
      baseOffset: sel.baseOffset.clamp(0, length),
      extentOffset: sel.extentOffset.clamp(0, length),
      affinity: sel.affinity,
      isDirectional: sel.isDirectional,
    );
  }

  /// The smallest replacement that turns [a] into [b]: common prefix, common
  /// suffix, and whatever is left between them. Enough for a text field, where
  /// every change is one contiguous edit.
  static (int, int, String) _diff(String a, String b) {
    final shortest = min(a.length, b.length);
    var p = 0;
    while (p < shortest && a.codeUnitAt(p) == b.codeUnitAt(p)) {
      p++;
    }
    var s = 0;
    while (s < shortest - p &&
        a.codeUnitAt(a.length - 1 - s) == b.codeUnitAt(b.length - 1 - s)) {
      s++;
    }
    return (p, a.length - s, b.substring(p, b.length - s));
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    return TextSpan(
      style: style,
      children: noteSpans(_doc, onToggleCheck: toggleCheckAt),
    );
  }
}

class _Snap {
  final NoteDoc doc;
  final TextSelection sel;

  const _Snap(this.doc, this.sel);
}
