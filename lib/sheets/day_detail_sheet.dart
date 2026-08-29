import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/cardio.dart';
import '../data/arc_data.dart';
import '../data/companion_data.dart';
import '../data/models.dart';
import '../data/store.dart';
import '../notes/note_doc.dart';
import '../notes/note_spans.dart';
import '../theme/app_theme.dart';
import '../widgets/arc_icons.dart';
import '../widgets/ui.dart';
import 'sheet_actions.dart';

/// The workout as plain text for the clipboard: same exercises, sets and
/// numbers the sheet shows, in the same order, readable wherever it's pasted.
/// One set per line; a drop chain stays on its parent's line, since it was one
/// set.
String workoutAsText({
  required Session ses,
  required Exercise? Function(String) exById,
}) {
  String fmtW(double w) => w % 1 == 0 ? w.toInt().toString() : w.toString();

  final body = <String>[];

  for (final e in ses.entries) {
    final ex = exById(e.exerciseId);
    if (ex == null) continue;

    String seg(double w, int reps) =>
        ex.isBodyweight ? '$reps reps' : '${fmtW(w)} × $reps';

    body..add('')..add(ex.name);
    for (final s in e.sets) {
      if (ex.isCardio) {
        // Pace is carried here but not on the chips: pasted into a message it
        // is the number the reader wants, and there is no width to fight over.
        body.add(
            '  ${cardioSetLine(s.secs, s.dist, s.level, ex.cardio, withRate: true)}');
        continue;
      }
      body.add('  ${[
        seg(s.weight, s.reps),
        for (final d in s.drops) seg(d.weight, d.reps),
      ].join(' → ')}');
    }
  }

  final year = ArcData.parseISO(ses.date).year;
  final note = NoteDoc.decode(ses.notes).plainText.trim();
  return [
    // The name leads when there is one — it's what the person pasting this
    // called the session, and the date alone doesn't say it.
    if (ses.name != null) ses.name!,
    '${ArcData.fmtDate(ses.date, 'long')} $year',
    ...body,
    // What was written about the session belongs with it: pasted into a
    // message, the note is usually the part worth sending. Formatting doesn't
    // survive plain text, but the checklist marks do.
    if (note.isNotEmpty) ...['', 'Notes', note],
  ].join('\n');
}

class DayDetailSheet extends StatelessWidget {
  /// Day to look up in the user's own store. Null when [session] is given.
  final String? date;

  /// A session handed in directly — a companion's, which lives outside the
  /// store. Read-only: no edit or delete.
  final Session? session;

  /// Companion the [session] belongs to, used to resolve its exercise names
  /// from that companion's own library.
  final CompanionData? data;

  const DayDetailSheet({super.key, required String this.date})
      : session = null,
        data = null;

  /// Read-only view of a companion's workout.
  const DayDetailSheet.forCompanion({
    super.key,
    required Session this.session,
    required CompanionData this.data,
  }) : date = null;

  @override
  Widget build(BuildContext context) {
    final store = session == null ? context.watch<ArcStore>() : null;
    final ses = session ?? store!.sessionForDate(date!);
    Exercise? exById(String id) =>
        data != null ? data!.exById(id) : store!.exById(id);

    String fmtW(double w) => w % 1 == 0 ? w.toInt().toString() : w.toString();

    // Tapping a logged exercise opens the same est. 1RM + history overlay the
    // Records screen uses — the companion's own records when this is their
    // workout. Null (so the card stays inert) when the exercise has no scored
    // set behind it, since that overlay would come up blank.
    final records = data != null ? data!.records : store!.records;
    VoidCallback? openRecord(String exerciseId) {
      final rec = records[exerciseId];
      if (rec == null || rec.best == null) return null;
      return () => data != null
          ? Sheets.openCompanionPR(context, rec)
          : Sheets.openPR(context, exerciseId);
    }

    void edit() {
      Navigator.of(context).maybePop();
      Future.delayed(const Duration(milliseconds: 180), () {
        if (context.mounted) Sheets.openLog(context, date: date);
      });
    }

    if (ses == null) {
      // rest day empty state
      return Padding(
        padding: const EdgeInsets.fromLTRB(0, 20, 0, 8),
        child: Column(
          children: [
            ArcIcon('dumbbell', size: 40, color: AppColors.faint),
            const SizedBox(height: 14),
            Text('Rest day',
                style: AppText.ui(size: 17, weight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text('No workout logged for this day.',
                style: AppText.ui(size: 14, color: AppColors.muted)),
            const SizedBox(height: 18),
            ArcButton(
                label: 'Log a workout', icon: 'plus', full: true, onTap: edit),
          ],
        ),
      );
    }

    // Conditioning is counted in minutes, not sets — a twenty-minute treadmill
    // block is not "one set", and folding it in would make a run look like the
    // lightest thing in the workout.
    final totalSets = ArcData.strengthSets([ses], exById);
    final cardioSecs = ArcData.cardioSeconds([ses], exById);

    Future<void> delete() async {
      final ok = await showArcConfirm(
        context: context,
        title: 'Delete workout?',
        message:
            "This removes ${ses.displayTitle} and all its sets from your "
            "history. This can't be undone.",
        confirmLabel: 'Delete',
      );
      if (!ok || !context.mounted) return;
      await context.read<ArcStore>().deleteSession(date!);
      if (context.mounted) Navigator.of(context).maybePop();
    }

    final group = ArcData.sessionGroup(ses, exById);
    final muscles = ArcData.sessionMuscles(ses, exById);
    // The group is spelled out only when the title stops carrying it — a
    // workout called "Chest & Arms" would otherwise state its group in the dot
    // alone, which is exactly what red/green vision can't read.
    final meta = [
      if (ses.name != null) group,
      if (totalSets > 0) '$totalSets ${totalSets == 1 ? 'set' : 'sets'}',
      if (cardioSecs > 0) '${(cardioSecs / 60).round()} min',
    ].join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 7),
              child: MuscleDots(
                  muscles: muscles,
                  fallbackRegion: muscles.isEmpty ? group : null,
                  size: 7),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ses.displayTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.ui(
                        size: 17.5,
                        weight: FontWeight.w700,
                        height: 1.25,
                        letterSpacing: -0.25),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    meta,
                    style: AppText.ui(
                        size: 13,
                        weight: FontWeight.w500,
                        color: AppColors.muted),
                  ),
                ],
              ),
            ),
            // Beside the name, below the share and copy pair on the title row.
            // A companion sees it only when there is something to read — a
            // control that opens an empty page they cannot write on is noise.
            if (session == null || ses.notes != null)
              SheetIconButton(
                icon: 'note',
                active: ses.notes != null,
                semanticLabel: ses.notes != null
                    ? 'Read the note on this workout'
                    : 'Add a note to this workout',
                onTap: () => Sheets.openNotes(context,
                    ses: ses, readOnly: session != null),
              ),
          ],
        ),
        if (ses.notes != null) ...[
          const SizedBox(height: 13),
          _NotePreview(
            doc: NoteDoc.decode(ses.notes),
            onTap: () => Sheets.openNotes(context,
                ses: ses, readOnly: session != null),
          ),
        ],
        const SizedBox(height: 16),
        for (final e in ses.entries)
          if (exById(e.exerciseId) case final ex?) ...[
            _EntryCard(
              exercise: ex,
              sets: e.sets,
              fmtW: fmtW,
              onTap: openRecord(e.exerciseId),
            ),
            const SizedBox(height: 14),
          ],
        if (session == null)
          Row(
            children: [
              Expanded(
                child: ArcButton(
                    label: 'Edit workout',
                    icon: 'pencil',
                    variant: BtnVariant.ghost,
                    full: true,
                    onTap: edit),
              ),
              const SizedBox(width: 10),
              ArcButton(
                  label: 'Delete',
                  icon: 'trash',
                  variant: BtnVariant.danger,
                  onTap: delete),
            ],
          ),
      ],
    );
  }
}

/// The first two lines of the note, in the note's own formatting.
///
/// The icon alone would make a note something you have to remember is there;
/// on a companion's workout it would hide the only part of the session they
/// didn't already log themselves. Two lines is enough to recognise a note and
/// not enough to compete with the sets below it.
class _NotePreview extends StatelessWidget {
  final NoteDoc doc;
  final VoidCallback onTap;

  const _NotePreview({required this.doc, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return PressScale(
      onTap: onTap,
      scale: 0.985,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 11, 11, 12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: AppRadii.rMd,
          border: Border.all(color: AppColors.line),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text.rich(
                // Scaled down as one ramp, so a note that leads with a big line
                // still previews with its own hierarchy instead of flattening.
                TextSpan(children: noteSpans(doc, scale: 0.82)),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: ArcIcon('chevR', size: 17, color: AppColors.faint),
            ),
          ],
        ),
      ),
    );
  }
}

class _EntryCard extends StatelessWidget {
  final dynamic exercise;
  final List sets;
  final String Function(double) fmtW;

  /// Opens this exercise's est. 1RM + history. Null leaves the card inert —
  /// and drops the chevron, so the card never advertises a tap it won't take.
  final VoidCallback? onTap;

  const _EntryCard({
    required this.exercise,
    required this.sets,
    required this.fmtW,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isBw = exercise.isBodyweight;
    final card = Container(
      padding: const EdgeInsets.fromLTRB(15, 13, 15, 13),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadii.rMd,
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              MuscleDot(exercise.muscle),
              const SizedBox(width: 8),
              Expanded(
                child: Text(exercise.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.ui(size: 16, weight: FontWeight.w600)),
              ),
              if (onTap != null)
                ArcIcon('chevR', size: 17, color: AppColors.faint),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [for (final s in sets) _setChip(s, isBw)],
          ),
        ],
      ),
    );
    if (onTap == null) return card;
    return PressScale(onTap: onTap, scale: 0.985, child: card);
  }

  /// One set, drops included. A drop chain is one chip because it was one set:
  /// chip count always equals set count. The parent stays in `ink` since it's
  /// the segment that scores; the tiers read back in `muted`.
  Widget _setChip(dynamic s, bool isBw) {
    String seg(double weight, int reps) =>
        isBw ? '$reps reps' : '${fmtW(weight)} × $reps';

    // A cardio block has no drops and no second segment — the whole block is
    // one string, in the same chip the sets wear so a mixed day reads as one
    // list rather than two.
    if (exercise.isCardio) {
      final kind = exercise.cardio;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.surface2,
          borderRadius: AppRadii.rSm,
        ),
        child: Semantics(
          label: spokenCardioSet(
              s.secs as int?, s.dist as double?, s.level as double?, kind),
          excludeSemantics: true,
          child: Text(
            cardioSetLine(
                s.secs as int?, s.dist as double?, s.level as double?, kind),
            style: AppText.mono(size: 13.5, weight: FontWeight.w600),
          ),
        ),
      );
    }

    final drops = (s.drops as List?) ?? const [];
    final main = seg(s.weight as double, s.reps as int);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: AppRadii.rSm,
      ),
      child: Semantics(
        label: drops.isEmpty
            ? main
            : '$main, then ${drops.map((d) => seg(d.weight as double, d.reps as int)).join(', ')}',
        excludeSemantics: true,
        // Wraps internally rather than overflowing, so a long chain at large
        // text scale breaks onto a second line inside its own chip.
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 5,
          runSpacing: 2,
          children: [
            Text(main, style: AppText.mono(size: 13.5, weight: FontWeight.w600)),
            for (final d in drops)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(ArcIcons.byName('chevR'), size: 12, color: AppColors.faint),
                  const SizedBox(width: 3),
                  Text(seg(d.weight as double, d.reps as int),
                      style: AppText.mono(
                          size: 13.5,
                          weight: FontWeight.w600,
                          color: AppColors.muted)),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
