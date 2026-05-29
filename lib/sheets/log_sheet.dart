import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/arc_data.dart';
import '../data/store.dart';
import '../theme/app_theme.dart';
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

  @override
  void initState() {
    super.initState();
    store = context.read<ArcStore>();
    final d = widget.date ?? ArcData.iso(ArcData.today);
    _draftDate = d;
    final existing = store.sessionForDate(d);
    if (existing != null) {
      _entries = existing.entries
          .map((e) => DraftEntry(
                id: ArcData.uid('ent'),
                exerciseId: e.exerciseId,
                sets: e.sets
                    .map((s) => DraftSet(
                        weight: s.weight, reps: s.reps, id: ArcData.uid('set')))
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
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  DraftSet _makeSet(String exId) {
    final last = store.lastSetFor(exId);
    final ex = store.exById(exId)!;
    return DraftSet(
      weight: ex.unit == 'bw' ? 0 : (last?.weight ?? 45),
      reps: last?.reps ?? 8,
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
  }

  int get _totalSets => _entries.fold(0, (a, e) => a + e.sets.length);

  Future<void> _save() async {
    await store.saveSession(_draftDate, _entries);
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
                    style: AppText.sora(
                        size: 21, weight: FontWeight.w700, letterSpacing: -0.21)),
              ),
              GestureDetector(
                onTap: () => Navigator.of(context).maybePop(),
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: const BoxDecoration(
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
              _dateSelector(),
              const SizedBox(height: 16),
              if (_entries.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 10),
                  child: Column(
                    children: [
                      const ArcIcon('dumbbell', size: 36, color: AppColors.faint),
                      const SizedBox(height: 10),
                      Text('No exercises yet. Add your first one.',
                          style:
                              AppText.sora(size: 14.5, color: AppColors.muted)),
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
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x00FFFFFF), AppColors.surface],
              stops: [0, 0.3],
            ),
          ),
          child: ArcButton(
            label:
                'Save workout${_totalSets > 0 ? ' · $_totalSets sets' : ''}',
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

  Widget _dateSelector() {
    final atToday = _draftDate.compareTo(ArcData.iso(ArcData.today)) >= 0;
    Widget navBtn(String icon, VoidCallback onTap, {bool dim = false}) =>
        Opacity(
          opacity: dim ? 0.3 : 1,
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
              child: Icon(ArcIcons.byName(icon), size: 20, color: AppColors.ink),
            ),
          ),
        );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: const BoxDecoration(
        color: AppColors.surface2,
        borderRadius: AppRadii.rMd,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          navBtn('chevL', () {
            setState(() => _draftDate =
                ArcData.iso(ArcData.addDays(ArcData.parseISO(_draftDate), -1)));
          }),
          Column(
            children: [
              Text(ArcData.fmtDate(_draftDate, 'long'),
                  style: AppText.sora(size: 16.5, weight: FontWeight.w700)),
              Text(ArcData.relDate(_draftDate),
                  style: AppText.sora(
                      size: 12, weight: FontWeight.w600, color: AppColors.muted)),
            ],
          ),
          navBtn('chevR', () {
            final n = ArcData.addDays(ArcData.parseISO(_draftDate), 1);
            if (!n.isAfter(ArcData.today)) {
              setState(() => _draftDate = ArcData.iso(n));
            }
          }, dim: atToday),
        ],
      ),
    );
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
              GroupDot(ex.group),
              const SizedBox(width: 8),
              Expanded(
                child: Text(ex.name,
                    style: AppText.sora(size: 16.5, weight: FontWeight.w700)),
              ),
              GestureDetector(
                onTap: () =>
                    setState(() => _entries.removeWhere((x) => x.id == e.id)),
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: const BoxDecoration(
                      color: AppColors.surface2, shape: BoxShape.circle),
                  child: Icon(ArcIcons.byName('x'),
                      size: 16, color: AppColors.muted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // column headers
          Padding(
            padding: const EdgeInsets.only(left: 22, right: 34, bottom: 6),
            child: Row(
              children: [
                if (!isBw)
                  Expanded(
                    child: Center(
                      child: Text('WEIGHT',
                          style: AppText.sora(
                              size: 11,
                              weight: FontWeight.w700,
                              color: AppColors.faint,
                              letterSpacing: 0.5)),
                    ),
                  ),
                Expanded(
                  child: Center(
                    child: Text('REPS',
                        style: AppText.sora(
                            size: 11,
                            weight: FontWeight.w700,
                            color: AppColors.faint,
                            letterSpacing: 0.5)),
                  ),
                ),
              ],
            ),
          ),
          for (var i = 0; i < e.sets.length; i++) ...[
            _setRow(e, i, isBw),
            if (i != e.sets.length - 1) const SizedBox(height: 8),
          ],
          const SizedBox(height: 10),
          // add set
          GestureDetector(
            onTap: () => setState(() => e.sets.add(_makeSet(e.exerciseId))),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 9),
              decoration: BoxDecoration(
                borderRadius: AppRadii.rMd,
                border: Border.all(
                    color: AppColors.line, style: BorderStyle.solid),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const ArcIcon('plus', size: 16, color: AppColors.accentStrong),
                  const SizedBox(width: 6),
                  Text('Add set',
                      style: AppText.sora(
                          size: 13.5,
                          weight: FontWeight.w600,
                          color: AppColors.accentStrong)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _setRow(DraftEntry e, int i, bool isBw) {
    final s = e.sets[i];
    return Row(
      children: [
        SizedBox(
          width: 22,
          child: Center(
            child: Text('${i + 1}',
                style: AppText.mono(
                    size: 13, weight: FontWeight.w600, color: AppColors.faint)),
          ),
        ),
        const SizedBox(width: 8),
        if (!isBw) ...[
          Expanded(
            child: ArcStepper(
              value: s.weight,
              step: 5,
              suffix: 'kg',
              onChanged: (v) => setState(() => s.weight = v.toDouble()),
            ),
          ),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: ArcStepper(
            value: s.reps,
            step: 1,
            min: 1,
            suffix: 'reps',
            onChanged: (v) => setState(() => s.reps = v.toInt()),
          ),
        ),
        GestureDetector(
          onTap: () => setState(() => e.sets.removeAt(i)),
          child: const SizedBox(
            width: 34,
            height: 34,
            child: Icon(Icons.delete_outline_rounded,
                size: 17, color: AppColors.faint),
          ),
        ),
      ],
    );
  }

  // ── PICK view ─────────────────────────────────────────────────────
  Widget _buildPick() {
    final used = _entries.map((e) => e.exerciseId).toSet();
    final filtered = store.exercises
        .where((e) => e.name.toLowerCase().contains(_query.toLowerCase()))
        .toList();
    final byGroup = <String, List>{};
    for (final e in filtered) {
      (byGroup[e.group] ??= []).add(e);
    }

    return ListView(
      padding: const EdgeInsets.only(top: 12, bottom: 26),
      children: [
        ArcTextField(
          controller: _searchController,
          hint: 'Search exercises',
          autofocus: true,
          plain: true,
          prefix: const ArcIcon('search', size: 18, color: AppColors.faint),
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
        for (final g in ArcData.groups.where((g) => byGroup[g] != null)) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 4, 2, 8),
            child: Row(
              children: [
                GroupDot(g),
                const SizedBox(width: 7),
                Text(g.toUpperCase(),
                    style: AppText.sora(
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
                    style: AppText.sora(size: 15.5, weight: FontWeight.w600)),
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
          onCreate: (name, group, unit) async {
            final id =
                await store.addExercise(name: name, group: group, unit: unit);
            if (mounted) _addEntry(id);
          },
        ),
      ],
    );
  }
}
