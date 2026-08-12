import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LengthLimitingTextInputFormatter;
import 'package:provider/provider.dart';
import '../data/arc_data.dart';
import '../data/muscle.dart';
import '../data/store.dart';
import '../theme/app_theme.dart';
import '../timer/timer_controller.dart';
import '../widgets/arc_icons.dart';
import '../widgets/ui.dart';
import 'add_exercise_sheet.dart';

class LogSheet extends StatefulWidget {
  final String? date;
  final String? prefillExId;
  const LogSheet({super.key, this.date, this.prefillExId});

  @override
  State<LogSheet> createState() => _LogSheetState();
}

class _LogSheetState extends State<LogSheet> {
  late ArcStore store;
  String _view = 'log'; // log | pick | new
  late String _draftDate;
  List<DraftEntry> _entries = [];
  final _searchController = TextEditingController();
  String _query = '';

  /// What the user is calling this workout. Empty means unnamed — the derived
  /// title stands in, and the field shows it as its placeholder.
  final _nameController = TextEditingController();
  final _nameFocus = FocusNode();

  /// Mirrors "the name field has text in it", so typing only rebuilds the sheet
  /// on the one keystroke that flips it rather than on every letter.
  bool _named = false;

  @override
  void initState() {
    super.initState();
    store = context.read<ArcStore>();
    final d = widget.date ?? ArcData.iso(ArcData.today);
    _draftDate = d;
    final existing = store.sessionForDate(d);
    if (existing != null) {
      _nameController.text = existing.name ?? '';
      _named = _nameController.text.isNotEmpty;
      _entries = existing.entries
          .map((e) => DraftEntry(
                id: ArcData.uid('ent'),
                exerciseId: e.exerciseId,
                sets: e.sets
                    .map((s) => DraftSet(
                          weight: s.weight,
                          reps: s.reps,
                          id: ArcData.uid('set'),
                          // Carried through, or re-saving an edited workout
                          // would write the set back without its drops.
                          drops: s.drops
                              .map((d) => DraftDrop(
                                  weight: d.weight,
                                  reps: d.reps,
                                  id: ArcData.uid('drp')))
                              .toList(),
                        ))
                    .toList(),
              ))
          .toList();
    } else if (widget.prefillExId != null) {
      _entries = [
        DraftEntry(
          id: ArcData.uid('ent'),
          exerciseId: widget.prefillExId!,
          sets: [_makeSet(widget.prefillExId!)],
        )
      ];
      // Straight into the first lift from a record row — same beginning as
      // adding one by hand, so it announces the same way.
      _maybeAnnounceStart();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _nameController.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  DraftSet _makeSet(String exId) {
    final best = store.bestSetFor(exId);
    final ex = store.exById(exId)!;
    return DraftSet(
      weight: ex.unit == 'bw' ? 0 : (best?.weight ?? 45),
      reps: best?.reps ?? 8,
      id: ArcData.uid('set'),
    );
  }

  void _addEntry(String exId) {
    setState(() {
      _entries = [
        ..._entries,
        DraftEntry(
            id: ArcData.uid('ent'), exerciseId: exId, sets: [_makeSet(exId)]),
      ];
      _view = 'log';
      _query = '';
      _searchController.clear();
    });
    // The exercise arrives carrying its first set, which is a logged set like
    // any other — without this the opening set of every lift is the one that
    // gets no rest.
    _startRest();
    _maybeAnnounceStart();
  }

  /// The moment an empty sheet gains its first lift is the moment the workout
  /// actually starts — everything before it is intent, and everything after is
  /// the same workout continuing. That single transition is what companions
  /// hear about, and it carries the name the workout has *right now*: what the
  /// user typed, or the title Arc infers from the lift they just picked.
  ///
  /// Fire-and-forget by design. Nothing about announcing a workout to other
  /// people may make logging it wait, and [ArcStore.announceWorkoutStart] holds
  /// the guards that keep it to once a day and to today only.
  void _maybeAnnounceStart() {
    if (_entries.length != 1) return;
    final typed = _nameController.text.trim();
    unawaited(store.announceWorkoutStart(
      date: _draftDate,
      name: typed.isNotEmpty
          ? typed
          : ArcData.inferTitle(_entries.map((e) => e.exerciseId), store.exById),
    ));
  }

  int get _totalSets => _entries.fold(0, (a, e) => a + e.sets.length);

  Future<void> _save() async {
    await store.saveSession(_draftDate, _entries,
        name: _nameController.text);
    if (mounted) Navigator.of(context).maybePop();
  }

  String get _title => _view == 'pick'
      ? 'Add Exercise'
      : _view == 'new'
          ? 'New Exercise'
          : 'Log Workout';

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.max,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // header
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 6),
          child: Row(
            children: [
              Expanded(
                child: Text(_title,
                    style: AppText.ui(
                        size: 21, weight: FontWeight.w700, letterSpacing: -0.21)),
              ),
              GestureDetector(
                onTap: () => Navigator.of(context).maybePop(),
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                      color: AppColors.surface2, shape: BoxShape.circle),
                  child: Icon(ArcIcons.byName('x'),
                      size: 18, color: AppColors.muted),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: switch (_view) {
            'pick' => _buildPick(),
            'new' => _buildNew(),
            _ => _buildLog(),
          },
        ),
      ],
    );
  }

  // ── LOG view ──────────────────────────────────────────────────────
  Widget _buildLog() {
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(top: 12, bottom: 16),
            children: [
              _sessionHeader(),
              const SizedBox(height: 16),
              if (_entries.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 10),
                  child: Column(
                    children: [
                      ArcIcon('dumbbell', size: 36, color: AppColors.faint),
                      const SizedBox(height: 10),
                      Text('No exercises yet. Add your first one.',
                          style:
                              AppText.ui(size: 14.5, color: AppColors.muted)),
                    ],
                  ),
                ),
              for (final e in _entries) ...[
                _entryCard(e),
                const SizedBox(height: 16),
              ],
              ArcButton(
                label: 'Add exercise',
                icon: 'plus',
                variant: BtnVariant.soft,
                full: true,
                onTap: () => setState(() => _view = 'pick'),
              ),
            ],
          ),
        ),
        // sticky footer
        Container(
          padding: const EdgeInsets.only(top: 6, bottom: 22),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                AppColors.surface.withValues(alpha: 0),
                AppColors.surface,
              ],
              stops: [0, 0.3],
            ),
          ),
          child: ArcButton(
            label: 'Save workout'
                '${_totalSets > 0 ? ' · $_totalSets set${_totalSets == 1 ? '' : 's'}' : ''}',
            icon: 'check',
            size: BtnSize.lg,
            full: true,
            disabled: _entries.isEmpty,
            onTap: _entries.isEmpty ? null : _save,
          ),
        ),
      ],
    );
  }

  /// When and what: the two facts that identify a workout, held in one block
  /// so they read as the session's header rather than as two more controls
  /// stacked above the sets.
  Widget _sessionHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: AppRadii.rMd,
      ),
      child: Column(
        children: [
          _dateRow(),
          const SizedBox(height: 8),
          _nameField(),
        ],
      ),
    );
  }

  /// Optional name for the workout, sitting on the same raised white surface as
  /// the date arrows either side of it, so it reads as part of the instrument.
  ///
  /// Left empty it shows the title Arc will derive from the exercises below —
  /// the placeholder is the actual default, not a prompt, so nobody has to save
  /// once to find out what their workout gets called.
  Widget _nameField() {
    final inferred =
        ArcData.inferTitle(_entries.map((e) => e.exerciseId), store.exById);
    final instant = MediaQuery.disableAnimationsOf(context);

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadii.rSm,
        boxShadow: AppShadows.sm,
      ),
      padding: const EdgeInsets.only(left: 12),
      child: Row(
        children: [
          ArcIcon('pencil',
              size: 16, color: _named ? AppColors.muted : AppColors.faint),
          const SizedBox(width: 9),
          Expanded(
            child: Semantics(
              label: 'Workout name',
              hint: _named
                  ? null
                  : 'Optional. Unnamed, this workout is called $inferred',
              child: TextField(
                controller: _nameController,
                focusNode: _nameFocus,
                maxLines: 1,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _nameFocus.unfocus(),
                // Without this the keyboard stays up and the name is left
                // half-typed behind whatever the next tap lands on.
                onTapOutside: (_) => _nameFocus.unfocus(),
                onChanged: (v) {
                  final has = v.trim().isNotEmpty;
                  if (has != _named) setState(() => _named = has);
                },
                inputFormatters: [LengthLimitingTextInputFormatter(40)],
                cursorColor: AppColors.accentStrong,
                style: AppText.ui(
                    size: 15.5, weight: FontWeight.w700, letterSpacing: -0.15),
                decoration: InputDecoration(
                  isCollapsed: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 13),
                  border: InputBorder.none,
                  hintText: inferred,
                  // Muted, not faint: this placeholder states a fact about the
                  // workout, so it has to be as readable as the value it stands
                  // in for. Weight carries the difference instead.
                  hintStyle: AppText.ui(
                      size: 15.5,
                      weight: FontWeight.w500,
                      color: AppColors.muted),
                ),
              ),
            ),
          ),
          AnimatedSwitcher(
            duration: Duration(milliseconds: instant ? 0 : 150),
            switchInCurve: Curves.easeOutQuart,
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: ScaleTransition(
                  scale: Tween(begin: 0.72, end: 1.0).animate(anim),
                  child: child),
            ),
            child: _named
                ? Semantics(
                    key: const ValueKey('clear'),
                    button: true,
                    label: 'Clear workout name',
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        _nameController.clear();
                        setState(() => _named = false);
                      },
                      child: SizedBox(
                        width: 44,
                        height: 44,
                        child: Icon(ArcIcons.byName('x'),
                            size: 16, color: AppColors.muted),
                      ),
                    ),
                  )
                : const SizedBox(key: ValueKey('empty'), width: 12, height: 44),
          ),
        ],
      ),
    );
  }

  Widget _dateRow() {
    final atToday = _draftDate.compareTo(ArcData.iso(ArcData.today)) >= 0;
    Widget navBtn(String icon, String label, VoidCallback onTap,
            {bool dim = false}) =>
        Opacity(
          opacity: dim ? 0.3 : 1,
          child: Semantics(
            button: true,
            enabled: !dim,
            label: label,
            child: GestureDetector(
              onTap: dim ? null : onTap,
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: AppRadii.rSm,
                  boxShadow: AppShadows.sm,
                ),
                child:
                    Icon(ArcIcons.byName(icon), size: 20, color: AppColors.ink),
              ),
            ),
          ),
        );

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        navBtn('chevL', 'Previous day', () {
          setState(() => _draftDate =
              ArcData.iso(ArcData.addDays(ArcData.parseISO(_draftDate), -1)));
        }),
        // Scales down rather than colliding with the arrows at large system
        // text sizes, the way the steppers below it do.
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Column(
              children: [
                Text(ArcData.fmtDate(_draftDate, 'long'),
                    style: AppText.ui(size: 16.5, weight: FontWeight.w700)),
                Text(ArcData.relDate(_draftDate),
                    style: AppText.ui(
                        size: 12,
                        weight: FontWeight.w600,
                        color: AppColors.muted)),
              ],
            ),
          ),
        ),
        navBtn('chevR', 'Next day', () {
          final n = ArcData.addDays(ArcData.parseISO(_draftDate), 1);
          if (!n.isAfter(ArcData.today)) {
            setState(() => _draftDate = ArcData.iso(n));
          }
        }, dim: atToday),
      ],
    );
  }

  // ── Set + drop-tier geometry ──────────────────────────────────────
  // A tier row is dimensionally identical to the set it hangs off, so weights
  // and reps stay in the same two columns and the whole entry reads as one
  // instrument. The gutter keeps its old total width (was 22 + 8) so adding
  // drop sets costs the steppers nothing.
  static const double _rowH = 46; // ArcStepper's fixed height
  static const double _gutterW = 26;
  static const double _gutterGap = 4;
  static const double _railX = (_gutterW - 1) / 2;

  /// Index of the set that `Add drop` attaches to, per entry. Defaults to the
  /// last set: the one you just finished is the one you drop.
  final Map<String, int> _dropTarget = {};

  /// The tier that should animate in. Only ever the one just added.
  String? _revealDropId;

  int _targetIndex(DraftEntry e) =>
      (_dropTarget[e.id] ?? e.sets.length - 1).clamp(0, e.sets.length - 1);

  /// Starts the rest the moment a set is recorded.
  ///
  /// A set row is added *after* the set is done — it arrives prefilled with what
  /// you just lifted — so this is the real "I have finished a set" moment, and
  /// catching it here is what makes the rest timer cost the log flow nothing.
  /// Silent when the user has turned auto-start off.
  ///
  /// Today only. Filling in Tuesday's session on Thursday evening is editing a
  /// record, not resting between sets, and a two-minute alarm for it would be
  /// the timer talking over the user.
  void _startRest() {
    if (_draftDate != ArcData.iso(ArcData.today)) return;
    context.read<TimerController>().autoStart();
  }

  void _addSet(DraftEntry e) {
    _startRest();
    setState(() {
      // e.sets can legitimately be empty — every set in the entry can be
      // deleted without deleting the entry itself.
      e.sets.add(e.sets.isEmpty
          ? _makeSet(e.exerciseId)
          : DraftSet(
              weight: e.sets.last.weight,
              reps: e.sets.last.reps,
              id: ArcData.uid('set')));
      _dropTarget.remove(e.id); // the new set becomes the drop target
    });
  }

  /// A drop lands at 80% of the tier above it, snapped to the 2.5 kg the
  /// stepper moves in, with reps carried down. The user corrects what actually
  /// happened rather than dialling a tier up from zero.
  double _dropWeight(double from) {
    if (from <= 0) return 0;
    final snapped = (from * 0.8 / 2.5).round() * 2.5;
    return snapped < 2.5 ? 2.5 : snapped;
  }

  void _addDrop(DraftEntry e) {
    // A drop tier is a set too — you rack, strip the weight and go again, with
    // the same rest owed at the end of it.
    _startRest();
    final s = e.sets[_targetIndex(e)];
    final from = s.drops.isEmpty
        ? (weight: s.weight, reps: s.reps)
        : (weight: s.drops.last.weight, reps: s.drops.last.reps);
    final d = DraftDrop(
        weight: _dropWeight(from.weight), reps: from.reps, id: ArcData.uid('drp'));
    setState(() {
      s.drops.add(d);
      _revealDropId = d.id;
    });
  }

  Widget _entryCard(DraftEntry e) {
    final ex = store.exById(e.exerciseId)!;
    final isBw = ex.unit == 'bw';
    return Container(
      padding: const EdgeInsets.all(14),
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
              MuscleDot(ex.muscle),
              const SizedBox(width: 8),
              Expanded(
                child: Text(ex.name,
                    style: AppText.ui(size: 16.5, weight: FontWeight.w700)),
              ),
              GestureDetector(
                onTap: () =>
                    setState(() => _entries.removeWhere((x) => x.id == e.id)),
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                      color: AppColors.surface2, shape: BoxShape.circle),
                  child: Icon(ArcIcons.byName('x'),
                      size: 16, color: AppColors.muted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // column headers — inset to exactly the stepper columns below
          Padding(
            padding: const EdgeInsets.only(
                left: _gutterW + _gutterGap, right: 34, bottom: 6),
            child: Row(
              children: [
                if (!isBw) ...[
                  Expanded(child: Center(child: _colHeader('WEIGHT'))),
                  const SizedBox(width: 8),
                ],
                Expanded(child: Center(child: _colHeader('REPS'))),
              ],
            ),
          ),
          for (var i = 0; i < e.sets.length; i++) ...[
            _setGroup(e, i, isBw),
            if (i != e.sets.length - 1) const SizedBox(height: 8),
          ],
          SizedBox(height: e.sets.isEmpty ? 0 : 10),
          _addControls(e, isBw),
        ],
      ),
    );
  }

  Widget _colHeader(String label) => Text(label,
      style: AppText.ui(
          size: 11,
          weight: FontWeight.w700,
          color: AppColors.faint,
          letterSpacing: 0.5));

  /// A set and its drop tiers. One unit: the set keeps the only ordinal, the
  /// tiers hang off it on a connector, and deleting the set takes them with it.
  Widget _setGroup(DraftEntry e, int i, bool isBw) {
    final s = e.sets[i];
    final selectable = e.sets.length > 1;
    final isTarget = selectable && _targetIndex(e) == i;

    return Column(
      key: ValueKey(s.id),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _stepperRow(
          gutter: _ordinalGutter(e, i, isTarget: isTarget, selectable: selectable),
          isBw: isBw,
          weight: s.weight,
          reps: s.reps,
          onWeight: (v) => setState(() => s.weight = v),
          onReps: (v) => setState(() => s.reps = v),
          onDelete: () => setState(() {
            e.sets.removeAt(i);
            _dropTarget.remove(e.id);
          }),
          deleteLabel: s.drops.isEmpty
              ? 'Remove set ${i + 1}'
              : 'Remove set ${i + 1} and its ${s.drops.length} drops',
        ),
        for (var d = 0; d < s.drops.length; d++)
          _TierReveal(
            key: ValueKey(s.drops[d].id),
            animate: s.drops[d].id == _revealDropId,
            child: _stepperRow(
              gutter: _tierGutter(
                  isLast: d == s.drops.length - 1,
                  label: 'Drop ${d + 1} of set ${i + 1}'),
              isBw: isBw,
              weight: s.drops[d].weight,
              reps: s.drops[d].reps,
              onWeight: (v) => setState(() => s.drops[d].weight = v),
              onReps: (v) => setState(() => s.drops[d].reps = v),
              onDelete: () => setState(() => s.drops.removeAt(d)),
              deleteLabel: 'Remove drop ${d + 1} of set ${i + 1}',
            ),
          ),
      ],
    );
  }

  /// One row of the weight/reps grid. Identical geometry for a set and for a
  /// drop tier — only the gutter differs.
  Widget _stepperRow({
    required Widget gutter,
    required bool isBw,
    required double weight,
    required int reps,
    required ValueChanged<double> onWeight,
    required ValueChanged<int> onReps,
    required VoidCallback onDelete,
    required String deleteLabel,
  }) {
    return SizedBox(
      height: _rowH,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          gutter,
          const SizedBox(width: _gutterGap),
          if (!isBw) ...[
            Expanded(
              child: ArcStepper(
                value: weight,
                step: 2.5,
                suffix: 'kg',
                editable: true,
                decimals: 1,
                onChanged: (v) => onWeight(v.toDouble()),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: ArcStepper(
              value: reps,
              step: 1,
              min: 1,
              suffix: 'reps',
              onChanged: (v) => onReps(v.toInt()),
            ),
          ),
          Semantics(
            button: true,
            label: deleteLabel,
            child: GestureDetector(
              onTap: onDelete,
              behavior: HitTestBehavior.opaque,
              // 34 wide (unchanged, so the steppers keep their width) but now
              // the full row height, which finally gets it near a 44dp target.
              child: SizedBox(
                width: 34,
                child: Icon(Icons.delete_outline_rounded,
                    size: 17, color: AppColors.faint),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The set number, doubling as the picker for which set `Add drop` lands on.
  Widget _ordinalGutter(DraftEntry e, int i,
      {required bool isTarget, required bool selectable}) {
    final s = e.sets[i];
    return SizedBox(
      width: _gutterW,
      child: Stack(
        children: [
          if (s.drops.isNotEmpty)
            Positioned(
              left: _railX,
              top: _rowH / 2 + 12,
              bottom: 0,
              width: 1,
              child: ColoredBox(color: AppColors.line),
            ),
          Positioned.fill(
            child: Semantics(
              button: selectable,
              selected: isTarget,
              label: s.drops.isEmpty
                  ? 'Set ${i + 1}'
                  : 'Set ${i + 1}, ${s.drops.length} '
                      '${s.drops.length == 1 ? 'drop' : 'drops'}',
              hint: selectable ? 'Send the next drop to this set' : null,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap:
                    selectable ? () => setState(() => _dropTarget[e.id] = i) : null,
                child: Center(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    curve: Curves.easeOutQuart,
                    width: 24,
                    height: 24,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: isTarget ? AppColors.accentSoft : Colors.transparent,
                      shape: BoxShape.circle,
                    ),
                    // Scales down rather than clipping at large system text
                    // sizes, matching how ArcStepper renders its own numerals
                    // inside a fixed-height control.
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text('${i + 1}',
                          style: AppText.mono(
                              size: 13,
                              weight: FontWeight.w600,
                              color: isTarget
                                  ? AppColors.accentStrong
                                  : AppColors.faint)),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Connector for a drop tier: rail down from the set above, elbow into the
  /// row. 1px and neutral — structure, not an accent stripe.
  Widget _tierGutter({required bool isLast, required String label}) {
    return Semantics(
      label: label,
      child: SizedBox(
        width: _gutterW,
        child: Stack(
          children: [
            Positioned(
              left: _railX,
              top: 0,
              height: isLast ? _rowH / 2 : _rowH,
              width: 1,
              child: ColoredBox(color: AppColors.line),
            ),
            Positioned(
              left: _railX,
              top: _rowH / 2,
              width: 7,
              height: 1,
              child: ColoredBox(color: AppColors.line),
            ),
          ],
        ),
      ),
    );
  }

  /// `Add set` alone, or split with `Add drop` once there's a set to drop.
  /// Bodyweight exercises never get the split: there is no weight to drop.
  ///
  /// `Add drop` names no set. Which set it lands on is already stated by the
  /// accented ordinal in the gutter, and the suffix that repeated it was the
  /// one label too long to fit half a phone-width control.
  Widget _addControls(DraftEntry e, bool isBw) {
    final canDrop = !isBw && e.sets.isNotEmpty;
    // Two labels side by side stop fitting well before the layout breaks, so
    // the control stacks rather than shrinking both to ellipses.
    final stacked =
        canDrop && MediaQuery.textScalerOf(context).scale(13.5) > 19;

    Widget half(String icon, String label, String hint, VoidCallback onTap) =>
        Semantics(
          button: true,
          hint: hint,
          child: GestureDetector(
            onTap: onTap,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ArcIcon(icon, size: 16, color: AppColors.accentStrong),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.ui(
                            size: 13.5,
                            weight: FontWeight.w600,
                            color: AppColors.accentStrong)),
                  ),
                ],
              ),
            ),
          ),
        );

    final addSet = half('plus', 'Add set', 'Adds a new working set', () => _addSet(e));
    final addDrop = canDrop
        ? half('chevD', 'Add drop', 'Adds a drop tier to set ${_targetIndex(e) + 1}',
            () => _addDrop(e))
        : null;
    final divider = ColoredBox(color: AppColors.line, child: const SizedBox());

    return Container(
      decoration: BoxDecoration(
        borderRadius: AppRadii.rMd,
        border: Border.all(color: AppColors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: addDrop == null
          ? addSet
          : stacked
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    addSet,
                    SizedBox(height: 1, child: divider),
                    addDrop,
                  ],
                )
              : IntrinsicHeight(
                  child: Row(
                    children: [
                      Expanded(child: addSet),
                      SizedBox(width: 1, child: divider),
                      Expanded(child: addDrop),
                    ],
                  ),
                ),
    );
  }

  // ── PICK view ─────────────────────────────────────────────────────
  Widget _buildPick() {
    final used = _entries.map((e) => e.exerciseId).toSet();
    final filtered = store.exercises
        .where((e) => e.name.toLowerCase().contains(_query.toLowerCase()))
        .toList();
    final byGroup = <Muscle, List>{};
    for (final e in filtered) {
      (byGroup[e.muscle] ??= []).add(e);
    }

    return ListView(
      padding: const EdgeInsets.only(top: 12, bottom: 26),
      children: [
        ArcTextField(
          controller: _searchController,
          hint: 'Search exercises',
          autofocus: true,
          plain: true,
          prefix: ArcIcon('search', size: 18, color: AppColors.faint),
          onChanged: (v) => setState(() => _query = v),
        ),
        const SizedBox(height: 14),
        ArcButton(
          label: 'Create new exercise',
          icon: 'plus',
          variant: BtnVariant.ghost,
          full: true,
          onTap: () => setState(() => _view = 'new'),
        ),
        const SizedBox(height: 14),
        for (final g in Muscle.values.where((g) => byGroup[g] != null)) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 4, 2, 8),
            child: Row(
              children: [
                MuscleDot(g),
                const SizedBox(width: 7),
                Text(g.label.toUpperCase(),
                    style: AppText.ui(
                        size: 12.5,
                        weight: FontWeight.w700,
                        color: AppColors.muted,
                        letterSpacing: 0.5)),
              ],
            ),
          ),
          ClipRRect(
            borderRadius: AppRadii.rMd,
            child: Column(
              children: [
                for (var i = 0; i < byGroup[g]!.length; i++) ...[
                  _pickRow(byGroup[g]![i], used.contains(byGroup[g]![i].id)),
                  if (i != byGroup[g]!.length - 1)
                    Container(height: 1, color: AppColors.line),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
        ],
        ArcButton(
          label: 'Done',
          variant: BtnVariant.quiet,
          full: true,
          onTap: () => setState(() => _view = 'log'),
        ),
      ],
    );
  }

  Widget _pickRow(dynamic ex, bool isUsed) {
    return GestureDetector(
      onTap: () => _addEntry(ex.id),
      behavior: HitTestBehavior.opaque,
      child: Container(
        color: AppColors.surface,
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
        child: Row(
          children: [
            Expanded(
              child: Opacity(
                opacity: isUsed ? 0.4 : 1,
                child: Text(ex.name,
                    style: AppText.ui(size: 15.5, weight: FontWeight.w600)),
              ),
            ),
            Icon(
              ArcIcons.byName(isUsed ? 'check' : 'plus'),
              size: 18,
              color: isUsed ? AppColors.accentStrong : AppColors.faint,
            ),
          ],
        ),
      ),
    );
  }

  // ── NEW view ──────────────────────────────────────────────────────
  Widget _buildNew() {
    return ListView(
      padding: const EdgeInsets.only(top: 12, bottom: 26),
      children: [
        AddExerciseForm(
          submitLabel: 'Create & add',
          onCancel: () => setState(() => _view = 'pick'),
          onCreate: (name, muscle, secondary, unit) async {
            final id = await store.addExercise(
                name: name, muscle: muscle, secondary: secondary, unit: unit);
            if (mounted) _addEntry(id);
          },
        ),
      ],
    );
  }
}

/// Expands a freshly added drop tier into place instead of snapping it in, so
/// the eye follows the chain growing off the set it belongs to. Tiers already
/// on screen (a reopened workout) mount at rest — the log sheet loads into a
/// task, it doesn't play an entrance.
class _TierReveal extends StatefulWidget {
  final Widget child;
  final bool animate;

  const _TierReveal({super.key, required this.child, required this.animate});

  @override
  State<_TierReveal> createState() => _TierRevealState();
}

class _TierRevealState extends State<_TierReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
    value: widget.animate ? 0 : 1,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _c.value = 1;
    } else if (!_c.isAnimating && _c.value == 0) {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = CurvedAnimation(parent: _c, curve: Curves.easeOutQuart);
    return SizeTransition(
      sizeFactor: curve,
      axisAlignment: -1,
      child: FadeTransition(opacity: curve, child: widget.child),
    );
  }
}
