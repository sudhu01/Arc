/// The document behind a workout note: plain text plus the formatting laid over
/// it. Pure data — no Flutter, no theme — so the model can be decoded on the
/// data layer's side of the app and rendered on the other
/// (`note_spans.dart` turns one of these into spans).
///
/// ## Why runs and not a tree
///
/// A note is one flat string with inline marks over ranges of it. That is what
/// a `TextField` edits and what a `TextEditingController` has to hand back, so
/// modelling it as anything richer would mean translating on every keystroke.
///
/// ## Where checklists live
///
/// In the text. A checklist line starts with [checkEmpty] or [checkDone]
/// followed by a space, and nothing else records it. That single decision
/// removes the hardest part of a hand-written editor: there are no block
/// anchors to remap when a line is split, merged or deleted — the marks move
/// with the characters around them, for free, through the same edit path as
/// everything else. It also survives the clipboard and any future reader.
///
/// The editor draws those two characters as a real checkbox (see
/// `note_spans.dart`); they are storage, never the affordance on screen.
library;

import 'dart:convert';

/// Inline formatting, one bit per mark. Zero is unformatted text, which is what
/// lets a plain note carry no run table at all.
class NoteAttr {
  NoteAttr._();

  static const bold = 1 << 0;
  static const italic = 1 << 1;
  static const underline = 1 << 2;
  static const highlight = 1 << 3;

  /// Size is not a flag but a level, held in the two bits above the marks.
  /// Normal is 0 so that "no formatting" stays `attrs == 0` at every size the
  /// user never touched.
  static const _sizeShift = 4;
  static const _sizeMask = 3 << _sizeShift;

  /// Steps, smallest first. The stored code is the index into this list; the
  /// order the A+/A− buttons walk is [sizeOrder].
  static const _sizeCodes = [2, 0, 1, 3]; // small, normal, large, x-large

  static const minSizeStep = 0;
  static const maxSizeStep = 3;

  /// Where a run's size sits on the small → x-large ladder, 0..3.
  static int sizeStep(int attrs) =>
      _sizeCodes.indexOf((attrs & _sizeMask) >> _sizeShift);

  static int withSizeStep(int attrs, int step) {
    final s = step.clamp(minSizeStep, maxSizeStep);
    return (attrs & ~_sizeMask) | (_sizeCodes[s] << _sizeShift);
  }

  /// True when this run carries nothing but a size — used to decide whether a
  /// mark is "on" for the toolbar's active state.
  static bool has(int attrs, int flag) => attrs & flag != 0;
}

/// The two characters that mark a checklist line, each followed by one space.
const String checkEmpty = '☐';
const String checkDone = '☑';

/// A stretch of text carrying one set of marks. Half-open: `[start, end)`.
class NoteRun {
  final int start;
  final int end;
  final int attrs;

  const NoteRun(this.start, this.end, this.attrs);

  int get length => end - start;
}

class NoteDoc {
  final String text;

  /// Sorted, non-overlapping, merged, and never carrying `attrs == 0`. Every
  /// constructor and mutation goes through [_compress], so anything reading a
  /// doc may assume all four.
  final List<NoteRun> runs;

  const NoteDoc._(this.text, this.runs);

  static const empty = NoteDoc._('', []);

  factory NoteDoc(String text, [List<NoteRun> runs = const []]) {
    if (runs.isEmpty) return NoteDoc._(text, const []);
    return NoteDoc._(text, _compress(_expand(text.length, runs)));
  }

  bool get isEmpty => text.trim().isEmpty;

  /// The marks in force at a caret [offset]. Left-biased: typing at the end of
  /// a bold word continues it, which is what every editor does and what anyone
  /// typing expects.
  int attrsAt(int offset) {
    final at = offset.clamp(0, text.length);
    final probe = at > 0 ? at - 1 : at;
    for (final r in runs) {
      if (probe >= r.start && probe < r.end) return r.attrs;
    }
    return 0;
  }

  /// The marks common to `[start, end)` — a flag is reported only when every
  /// character in the range carries it, so "bold" lights up for a fully bold
  /// selection and not for one that merely touches bold text.
  int attrsOver(int start, int end) {
    if (end <= start) return attrsAt(start);
    final a = _expand(text.length, runs);
    var acc = a[start];
    for (var i = start + 1; i < end && i < a.length; i++) {
      acc &= a[i];
    }
    return acc;
  }

  /// The marks on every character, in order. What a renderer wants: walking
  /// [runs] per character would be quadratic, and this is one allocation.
  List<int> attrsPerChar() => _expand(text.length, runs);

  /// Rewrite the marks across `[start, end)`. [f] is handed each character's
  /// current attrs and returns its new ones.
  NoteDoc mapAttrs(int start, int end, int Function(int) f) {
    if (end <= start) return this;
    final a = _expand(text.length, runs);
    for (var i = start; i < end && i < a.length; i++) {
      a[i] = f(a[i]);
    }
    return NoteDoc._(text, _compress(a));
  }

  /// Splice [insert] over `[start, end)`, carrying the marks around the cut.
  ///
  /// Inserted characters take [insertAttrs] when given — that is the toolbar
  /// having staged a mark at a bare caret — and otherwise inherit from the
  /// character to the left, falling back to the one on the right at the very
  /// start of the note.
  NoteDoc replaced(int start, int end, String insert, {int? insertAttrs}) {
    final a = _expand(text.length, runs);
    final inherit = insertAttrs ??
        (start > 0 && start - 1 < a.length
            ? a[start - 1]
            : (end < a.length ? a[end] : 0));
    final next = <int>[
      ...a.sublist(0, start.clamp(0, a.length)),
      ...List<int>.filled(insert.length, inherit),
      ...a.sublist(end.clamp(0, a.length)),
    ];
    final nextText =
        text.substring(0, start) + insert + text.substring(end.clamp(0, text.length));
    return NoteDoc._(nextText, _compress(next));
  }

  // ── Checklists ──────────────────────────────────────────────────────

  /// Start of the line containing [offset].
  int lineStart(int offset) {
    final at = offset.clamp(0, text.length);
    final nl = text.lastIndexOf('\n', at > 0 ? at - 1 : 0);
    return nl < 0 ? 0 : nl + 1;
  }

  /// The mark this line carries, or null when it is not a checklist line.
  String? checkMarkAt(int offset) {
    final s = lineStart(offset);
    if (s >= text.length) return null;
    final c = text[s];
    return (c == checkEmpty || c == checkDone) ? c : null;
  }

  /// Walks the caret's line through none → unchecked → checked → none. The
  /// third state is a deliberate exit: a checklist you cannot leave is a trap,
  /// and there is no other control that would undo it.
  (NoteDoc, int) cycleCheck(int offset) {
    final s = lineStart(offset);
    final mark = checkMarkAt(offset);
    if (mark == null) {
      return (replaced(s, s, '$checkEmpty ', insertAttrs: attrsAt(s)), 2);
    }
    if (mark == checkEmpty) {
      return (_setMarkAt(s, checkDone), 0);
    }
    // The mark and its trailing space go together — they were inserted as one.
    final drop = (s + 1 < text.length && text[s + 1] == ' ') ? 2 : 1;
    return (replaced(s, s + drop, ''), -drop);
  }

  /// Flip one checklist line's box, addressed by the mark's own offset. This is
  /// the path a tap on a rendered checkbox takes.
  NoteDoc toggleCheckAt(int markOffset) {
    if (markOffset < 0 || markOffset >= text.length) return this;
    final c = text[markOffset];
    if (c != checkEmpty && c != checkDone) return this;
    return _setMarkAt(markOffset, c == checkEmpty ? checkDone : checkEmpty);
  }

  NoteDoc _setMarkAt(int offset, String mark) {
    // Replacing one character with one character leaves every run where it is.
    return NoteDoc._(
      text.replaceRange(offset, offset + 1, mark),
      runs,
    );
  }

  // ── Codec ───────────────────────────────────────────────────────────

  /// `{"t":"…","r":[[start,end,attrs],…]}` — `r` omitted entirely when the note
  /// carries no formatting, so a plain note costs nine bytes of envelope. This
  /// string is what the `sessions.notes` column and the sync payload hold.
  String encode() => jsonEncode({
        't': text,
        if (runs.isNotEmpty)
          'r': [
            for (final r in runs) [r.start, r.end, r.attrs]
          ],
      });

  /// Anything that is not a well-formed envelope is read as plain text rather
  /// than thrown away — a note is the user's own words, and losing them to a
  /// parse error is the one outcome worth writing defensive code for.
  static NoteDoc decode(String? raw) {
    if (raw == null || raw.isEmpty) return empty;
    try {
      final v = jsonDecode(raw);
      if (v is Map && v['t'] is String) {
        final rs = <NoteRun>[];
        for (final e in (v['r'] as List?) ?? const []) {
          if (e is List && e.length >= 3) {
            rs.add(NoteRun(
                (e[0] as num).toInt(), (e[1] as num).toInt(), (e[2] as num).toInt()));
          }
        }
        return NoteDoc(v['t'] as String, rs);
      }
    } catch (_) {
      // falls through to plain text
    }
    return NoteDoc(raw);
  }

  /// The note as it reads outside Arc — the clipboard, mostly. The box marks
  /// stay: they carry the checklist that formatting cannot.
  String get plainText => text;

  // ── Run algebra ─────────────────────────────────────────────────────
  //
  // Every mutation expands the run table to one int per character, edits that,
  // and compresses back. At a 5000-character cap that is a 5000-element list
  // per keystroke — nothing next to laying out the text — and it makes the
  // hard cases (a selection that starts mid-run and ends mid-another, a
  // deletion that swallows a run whole) fall out instead of needing their own
  // branches.

  static List<int> _expand(int length, List<NoteRun> runs) {
    final a = List<int>.filled(length, 0);
    for (final r in runs) {
      final s = r.start.clamp(0, length);
      final e = r.end.clamp(0, length);
      for (var i = s; i < e; i++) {
        // Marks accumulate, but size is a level and cannot: two overlapping
        // runs OR'd together would land on a third size neither asked for.
        // Only [decode] can hand us an overlap, and last one wins.
        a[i] = ((a[i] | r.attrs) & ~NoteAttr._sizeMask) |
            (r.attrs & NoteAttr._sizeMask);
      }
    }
    return a;
  }

  static List<NoteRun> _compress(List<int> perChar) {
    final out = <NoteRun>[];
    var i = 0;
    while (i < perChar.length) {
      final v = perChar[i];
      var j = i + 1;
      while (j < perChar.length && perChar[j] == v) {
        j++;
      }
      if (v != 0) out.add(NoteRun(i, j, v));
      i = j;
    }
    return out;
  }
}
