import 'dart:async';

import 'package:flutter/foundation.dart'
    show kIsWeb, ValueListenable, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../body/body_view.dart';
import '../data/models.dart';
import '../data/muscle.dart';
import '../data/store.dart';
import '../sheets/sheet_actions.dart';
import '../sheets/add_exercise_sheet.dart' show ArcTextField;
import '../theme/app_theme.dart';
import '../theme/muscle_palette.dart';
import '../widgets/arc_icons.dart';
import '../widgets/exercise_row.dart';
import '../widgets/muscle_picker.dart';
import '../widgets/sheet.dart';
import '../widgets/ui.dart';

/// Where exercises live. Two ways in, and they are peers rather than a feature
/// and its fallback:
///
/// **Body** is anatomy as navigation — spin the figure, tap what you trained.
/// It is also the only place the last fortnight's volume is visible as a shape
/// rather than a number.
///
/// **List** is the fast path: search, muscle-grouped sections, no waiting on a
/// renderer. It is what works mid-set with wet hands, and it is where the
/// screen lands by itself if the body can't start.
enum LibraryMode { body, list }

class Library extends StatefulWidget {
  /// Whether this tab is the one currently on screen. Forwarded to [BodyView],
  /// which stops its renderer when it isn't — a WebView keeps running whatever
  /// is inside it long after Flutter has stopped painting it.
  final bool visible;

  const Library({super.key, this.visible = true});

  @override
  State<Library> createState() => _LibraryState();
}

class _LibraryState extends State<Library> {
  /// Web has no WebView to host the renderer, so the mode toggle isn't offered
  /// there at all — a control that can't do its job shouldn't be on screen.
  LibraryMode _mode = kIsWeb ? LibraryMode.list : LibraryMode.body;
  String _query = '';
  bool _reviewDismissed = false;
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ArcStore>();
    final unconfirmed = store.unconfirmedMuscleCount;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Flexible so the title ellipsizes rather than shoving the
                  // controls off the row at large system text scales.
                  Flexible(
                    child: Text('Exercises',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.ui(
                            size: titleStyleSize,
                            weight: FontWeight.w700,
                            letterSpacing: -0.96)),
                  ),
                  const SizedBox(width: 8),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const _PaletteButton(),
                      const SizedBox(width: 4),
                      ArcButton(
                        label: 'New',
                        icon: 'plus',
                        size: BtnSize.sm,
                        variant: BtnVariant.soft,
                        onTap: () => Sheets.openAddExercise(context),
                      ),
                    ],
                  ),
                ],
              ),
              if (!kIsWeb) ...[
                const SizedBox(height: 16),
                Segmented(
                  options: const [
                    SegOption('body', 'Body'),
                    SegOption('list', 'List'),
                  ],
                  value: _mode == LibraryMode.body ? 'body' : 'list',
                  onChanged: (v) => setState(() => _mode =
                      v == 'body' ? LibraryMode.body : LibraryMode.list),
                ),
              ],
              if (unconfirmed > 0 && !_reviewDismissed) ...[
                const SizedBox(height: 14),
                _ReviewCard(
                  count: unconfirmed,
                  onDismiss: () => setState(() => _reviewDismissed = true),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
        Expanded(
          child: _mode == LibraryMode.body
              ? BodyView(
                  visible: widget.visible,
                  onUnavailable: () {
                    if (mounted) setState(() => _mode = LibraryMode.list);
                  },
                )
              : _ListMode(
                  store: store,
                  query: _query,
                  controller: _searchController,
                  onQuery: (v) => setState(() => _query = v),
                ),
        ),
      ],
    );
  }
}

/// The library as a searchable, muscle-sectioned list — and the one place an
/// exercise can change the group it is filed under.
///
/// Refiling is a drag: hold a lift by its rail and drop it on another group.
/// The list answers by opening up — every group Arc knows appears while a lift
/// is in the air, including the ones holding nothing, because a group with no
/// exercises in it is exactly the group you are most likely to be dragging one
/// into. The same move is available without dragging, from the same grip: a tap
/// opens the thirteen groups as pills. That route is not a concession to screen
/// readers, it is the faster one when the destination is nine sections away.
///
/// What a drop changes is deliberately narrow. It sets the group the lift is
/// *filed* under; the groups it also works are left exactly as they were. The
/// single exception is dropping a lift onto a group it already assists — that
/// group becomes its primary, and leaving it in the also-works list as well
/// would count it twice.
class _ListMode extends StatefulWidget {
  final ArcStore store;
  final String query;
  final TextEditingController controller;
  final ValueChanged<String> onQuery;

  const _ListMode({
    required this.store,
    required this.query,
    required this.controller,
    required this.onQuery,
  });

  @override
  State<_ListMode> createState() => _ListModeState();
}

class _ListModeState extends State<_ListMode>
    with SingleTickerProviderStateMixin {
  final _listKey = GlobalKey();
  final _scroll = ScrollController();

  /// Opens and closes the groups that hold nothing. One controller for all of
  /// them, so thirteen sections move as a single gesture of the list.
  late final AnimationController _reveal = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..addStatusListener((s) {
      // Dismissed is the moment the empty groups have finished folding away and
      // can leave the tree. Nothing else here needs a frame-by-frame rebuild.
      if (s == AnimationStatus.dismissed && mounted) setState(() {});
    });

  /// The lift in the air, and the group under the finger. The target is a
  /// notifier rather than plain state because the only thing that reads it is
  /// the chip riding the pointer, which lives in the drag overlay — a setState
  /// here would rebuild the whole list on every group it crosses.
  Exercise? _lift;
  final ValueNotifier<Muscle?> _target = ValueNotifier(null);

  /// The exercise that just landed, and a counter that makes the flash replay
  /// when the same lift is refiled twice running.
  String? _landed;
  int _landSeq = 0;
  Timer? _landTimer;

  /// Edge auto-scroll. A phone holds four sections at most; without this, Chest
  /// could never reach Calves.
  Timer? _edgeTimer;
  double _edgeVelocity = 0;

  @override
  void dispose() {
    _landTimer?.cancel();
    _edgeTimer?.cancel();
    _reveal.dispose();
    _target.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool get _dragging => _lift != null;

  /// Whether the groups holding nothing are on screen. True through the whole
  /// closing animation and not just while a lift is held, or they would vanish
  /// instead of folding away.
  bool get _showEveryGroup => _dragging || _reveal.value > 0;

  void _startLift(Exercise e) {
    HapticFeedback.selectionClick();
    setState(() => _lift = e);
    _openGroups(true);
  }

  void _endLift() {
    if (!mounted) return;
    _stopEdgeScroll();
    _target.value = null;
    if (_lift != null) setState(() => _lift = null);
    _openGroups(false);
  }

  /// Opening the empty groups is the list rearranging itself around what the
  /// user is doing, so it is exactly the motion someone who has asked for less
  /// of it does not want: with animations off the groups are simply there, and
  /// simply gone.
  void _openGroups(bool open) {
    if (MediaQuery.disableAnimationsOf(context)) {
      _reveal.value = open ? 1 : 0;
      if (!open) setState(() {});
      return;
    }
    open ? _reveal.forward() : _reveal.reverse();
  }

  void _enter(Muscle m) {
    if (_target.value == m) return;
    HapticFeedback.selectionClick();
    _target.value = m;
  }

  /// Refile [e] under [m].
  ///
  /// [Exercise.secondary] is carried across untouched — a lift that moves from
  /// Chest to Triceps still works the shoulders it always worked. The one entry
  /// that cannot survive the move is [m] itself: a group is either the one a
  /// lift is filed under or one it also works, never both.
  Future<void> _file(Exercise e, Muscle m) async {
    if (e.muscle == m) return;
    // Conditioning is decided by tracking, not by filing — refusing both
    // directions here is what stops a drag onto the Cardio card from creating
    // a treadmill scored in kilos, or a barbell with no weight column.
    if (e.isCardio || m == Muscle.cardio) return;
    HapticFeedback.mediumImpact();
    final promoted = e.secondary.contains(m);
    await widget.store.setExerciseMuscles(
      e.id,
      muscle: m,
      secondary: [
        for (final s in e.secondary)
          if (s != m) s,
      ],
    );
    widget.store.announce(
      '${e.name} → ${m.label}${promoted ? ', now primary' : ''}',
      'check',
    );
    if (!mounted) return;
    setState(() {
      _landed = e.id;
      _landSeq++;
    });
    _landTimer?.cancel();
    _landTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _landed = null);
    });
  }

  /// The same change without the drag, off a tap on the grip. Also the only
  /// route a screen reader or a keyboard has.
  Future<void> _pickGroup(Exercise e) async {
    HapticFeedback.selectionClick();
    await showArcSheet(
      context: context,
      title: e.name,
      builder: (ctx) => _GroupPickSheet(
        exercise: e,
        onPick: (m) {
          Navigator.of(ctx).maybePop();
          _file(e, m);
        },
      ),
    );
  }

  // ── Edge auto-scroll ──────────────────────────────────────────────
  void _edgeScroll(Offset globalPosition) {
    final box = _listKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    const zone = 92.0; // deep enough to reach with a thumb still on the lift
    const maxSpeed = 900.0; // px/s, at the very edge
    final y = box.globalToLocal(globalPosition).dy;
    final h = box.size.height;

    double v = 0;
    if (y < zone) {
      v = -maxSpeed * ((zone - y) / zone).clamp(0.0, 1.0);
    } else if (y > h - zone) {
      v = maxSpeed * ((y - (h - zone)) / zone).clamp(0.0, 1.0);
    }
    _edgeVelocity = v;

    if (v == 0) {
      _stopEdgeScroll();
    } else {
      _edgeTimer ??= Timer.periodic(
          const Duration(milliseconds: 16), (_) => _tickEdgeScroll());
    }
  }

  void _tickEdgeScroll() {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    final next = (p.pixels + _edgeVelocity * 0.016)
        .clamp(p.minScrollExtent, p.maxScrollExtent);
    if (next != p.pixels) _scroll.jumpTo(next);
  }

  void _stopEdgeScroll() {
    _edgeTimer?.cancel();
    _edgeTimer = null;
    _edgeVelocity = 0;
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;

    final trainCount = <String, int>{};
    for (final s in store.sessions) {
      for (final e in s.entries) {
        trainCount[e.exerciseId] = (trainCount[e.exerciseId] ?? 0) + 1;
      }
    }

    final q = widget.query.trim().toLowerCase();
    final matches = store.exercises.where((e) {
      if (q.isEmpty) return true;
      // Searching "chest" should find the chest lifts even when none of them
      // has the word in its name.
      return e.name.toLowerCase().contains(q) ||
          e.muscle.label.toLowerCase().contains(q);
    }).toList();

    final byMuscle = <Muscle, List<Exercise>>{};
    for (final e in matches) {
      (byMuscle[e.muscle] ??= []).add(e);
    }
    final filled = Muscle.values.where((m) => byMuscle[m] != null).toList();
    final sections = _showEveryGroup ? Muscle.values.toList() : filled;

    return ListView(
      key: _listKey,
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
      children: [
        ArcTextField(
          controller: widget.controller,
          hint: 'Search exercises',
          plain: true,
          prefix: ArcIcon('search', size: 18, color: AppColors.faint),
          onChanged: widget.onQuery,
        ),
        const SizedBox(height: 16),
        if (store.exercises.isEmpty)
          const _LibraryEmpty()
        else if (sections.isEmpty)
          _NoMatches(query: widget.query)
        else
          for (final m in sections)
            _Section(
              // Keyed by group, and load-bearing: the empty groups appear
              // *while* a lift is being held, and without a key the sections
              // they push down would each be handed the next group's contents
              // — including the row whose element is running the drag, which
              // would end the drag the instant it started.
              key: ValueKey(m),
              muscle: m,
              exercises: byMuscle[m] ?? const [],
              trainCount: trainCount,
              store: store,
              reveal: _reveal,
              lift: _lift,
              landed: _landed,
              landSeq: _landSeq,
              onEnter: () => _enter(m),
              onLeave: () {
                if (_target.value == m) _target.value = null;
              },
              onAccept: (e) => _file(e, m),
              handleFor: _handle,
            ),
      ],
    );
  }

  /// Whether picking a lift up asks for a press and hold. True on a touch
  /// screen, where the same movement is how the library scrolls.
  bool get _liftOnHold =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  /// The rail down the left of every library row: hold it to refile the lift,
  /// tap it to pick the group from a list.
  Widget _handle(Exercise e) {
    final held = _lift?.id == e.id;

    final grip = SizedBox(
      width: 44,
      height: 44,
      child: Center(
        child: ArcIcon('grip',
            size: 18, color: held ? AppColors.accentStrong : AppColors.faint),
      ),
    );

    return Semantics(
      button: true,
      label: 'Muscle group for ${e.name}',
      // Names the state and the move in one line, because a grip announces
      // neither on its own.
      hint: 'Filed under ${e.muscle.label}. Opens the groups to refile it',
      onTap: () => _pickGroup(e),
      child: ExcludeSemantics(
        child: GestureDetector(
          // Tap and hold share the grip: a finger that lets go picks from a
          // list, one that stays carries the lift. The gesture arena settles
          // which, so neither has to be the other's fallback.
          onTap: () => _pickGroup(e),
          behavior: HitTestBehavior.opaque,
          // Hold to pick the lift up on a touch screen. The rail runs down
          // the left edge of every row, and a thumb that starts a scroll there
          // has to scroll — refiling is the rarer intent and can afford to be
          // the deliberate one. A mouse has no such ambiguity and lifts on the
          // first pixel.
          child: _liftOnHold
              ? LongPressDraggable<Exercise>(
                  data: e,
                  delay: const Duration(milliseconds: 320),
                  hapticFeedbackOnStart: false, // _startLift owns the tick
                  dragAnchorStrategy: (_, _, _) => const Offset(24, 27),
                  onDragStarted: () => _startLift(e),
                  onDragUpdate: (d) => _edgeScroll(d.globalPosition),
                  onDragEnd: (_) => _endLift(),
                  feedback: _LiftChip(exercise: e, target: _target),
                  child: grip,
                )
              : Draggable<Exercise>(
                  data: e,
                  // The chip hangs off the pointer rather than sitting under
                  // it, so the finger never covers where the lift is going.
                  dragAnchorStrategy: (_, _, _) => const Offset(24, 27),
                  onDragStarted: () => _startLift(e),
                  onDragUpdate: (d) => _edgeScroll(d.globalPosition),
                  onDragEnd: (_) => _endLift(),
                  feedback: _LiftChip(exercise: e, target: _target),
                  child: grip,
                ),
        ),
      ),
    );
  }
}

/// One muscle group in the list: its header, and the lifts filed under it —
/// which together are the target a dragged lift lands on.
class _Section extends StatelessWidget {
  final Muscle muscle;
  final List<Exercise> exercises;
  final Map<String, int> trainCount;
  final ArcStore store;
  final Animation<double> reveal;
  final Exercise? lift;
  final String? landed;
  final int landSeq;
  final VoidCallback onEnter;
  final VoidCallback onLeave;
  final ValueChanged<Exercise> onAccept;
  final Widget Function(Exercise) handleFor;

  const _Section({
    super.key,
    required this.muscle,
    required this.exercises,
    required this.trainCount,
    required this.store,
    required this.reveal,
    required this.lift,
    required this.landed,
    required this.landSeq,
    required this.onEnter,
    required this.onLeave,
    required this.onAccept,
    required this.handleFor,
  });

  @override
  Widget build(BuildContext context) {
    final section = DragTarget<Exercise>(
      onWillAcceptWithDetails: (d) {
        // The group a lift already sits in is not a destination. Refusing it
        // here is what keeps the section it came from dark under the finger.
        if (d.data.muscle == muscle) return false;
        onEnter();
        return true;
      },
      onLeave: (_) => onLeave(),
      onAcceptWithDetails: (d) => onAccept(d.data),
      builder: (context, candidate, _) {
        final hot = candidate.isNotEmpty;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SectionHeader(
              muscle: muscle,
              count: exercises.length,
              highlighted: hot,
              onTap: () => Sheets.openMuscle(context, muscle),
            ),
            if (exercises.isEmpty)
              _EmptyGroupSlot(muscle: muscle, highlighted: hot)
            else
              ExerciseGroupCard(
                highlighted: hot,
                rows: [
                  for (final e in exercises)
                    _LandFlash(
                      // Only the row that landed takes a new key. Keying every
                      // row on the counter would remount the whole library to
                      // light one line of it.
                      key: e.id == landed
                          ? ValueKey('land-${e.id}-$landSeq')
                          : ValueKey('row-${e.id}'),
                      flash: e.id == landed,
                      child: ExerciseRow(
                        exercise: e,
                        trained: trainCount[e.id] ?? 0,
                        best: store.records[e.id]?.best,
                        showMuscle: false,
                        handle: handleFor(e),
                        lifted: lift?.id == e.id,
                      ),
                    ),
                ],
              ),
            const SizedBox(height: 18),
          ],
        );
      },
    );

    // A group holding nothing exists only while a lift is in the air. It opens
    // with the rest of them and folds away on release.
    if (exercises.isNotEmpty) return section;
    return AnimatedBuilder(
      animation: reveal,
      builder: (context, child) {
        final t = Curves.easeOutQuart.transform(reveal.value);
        if (t == 0) return const SizedBox.shrink();
        return ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: t,
            child: Opacity(opacity: t, child: child),
          ),
        );
      },
      child: section,
    );
  }
}

/// Where a group's exercises would be, for a group that has none. Only ever on
/// screen mid-drag, so it says what letting go would do rather than apologising
/// for being empty.
class _EmptyGroupSlot extends StatelessWidget {
  final Muscle muscle;
  final bool highlighted;

  const _EmptyGroupSlot({required this.muscle, required this.highlighted});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      height: 58,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: highlighted ? AppColors.accentSoft : Colors.transparent,
        borderRadius: AppRadii.rLg,
        border: Border.all(
            color: highlighted ? AppColors.accentLine : AppColors.line),
      ),
      child: Text(
        highlighted ? 'File it under ${muscle.label}' : 'Nothing filed here',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppText.ui(
          size: 13,
          weight: FontWeight.w600,
          color: highlighted ? AppColors.accentStrong : AppColors.faint,
        ),
      ),
    );
  }
}

/// The lift as it travels: its name, and the colour of wherever it is headed.
///
/// The dot is the tell. It carries the destination group's colour rather than
/// the lift's own, so the answer to "what happens if I let go here" is on the
/// thing under the thumb instead of somewhere behind it.
class _LiftChip extends StatelessWidget {
  final Exercise exercise;
  final ValueListenable<Muscle?> target;

  const _LiftChip({required this.exercise, required this.target});

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: ValueListenableBuilder<Muscle?>(
        valueListenable: target,
        builder: (context, to, _) {
          final destination = to ?? exercise.muscle;
          return Container(
            constraints: const BoxConstraints(maxWidth: 268),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: AppRadii.rMd,
              border: Border.all(
                  color: to == null ? AppColors.line : AppColors.accentLine),
              boxShadow: AppShadows.lift,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TweenAnimationBuilder<Color?>(
                  duration: const Duration(milliseconds: 160),
                  tween: ColorTween(end: MusclePalette.of(destination)),
                  builder: (context, color, _) => Container(
                    width: 10,
                    height: 10,
                    decoration:
                        BoxDecoration(color: color, shape: BoxShape.circle),
                  ),
                ),
                const SizedBox(width: 11),
                Flexible(
                  child: Text(exercise.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.ui(size: 15, weight: FontWeight.w700)),
                ),
                if (to != null) ...[
                  const SizedBox(width: 10),
                  Text('→ ${to.label}',
                      maxLines: 1,
                      style: AppText.ui(
                          size: 12.5,
                          weight: FontWeight.w700,
                          color: AppColors.accentStrong)),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Marks where a refiled lift landed. The toast says what happened, this says
/// where — two halves of one question, because the group a lift moved to is
/// rarely the part of the list you were looking at.
class _LandFlash extends StatefulWidget {
  final Widget child;
  final bool flash;

  const _LandFlash({super.key, required this.child, required this.flash});

  @override
  State<_LandFlash> createState() => _LandFlashState();
}

class _LandFlashState extends State<_LandFlash>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
    value: widget.flash ? 0 : 1,
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
    if (!widget.flash) return widget.child;
    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: FadeTransition(
              opacity: Tween(begin: 1.0, end: 0.0).animate(
                  CurvedAnimation(parent: _c, curve: Curves.easeInQuart)),
              child: ColoredBox(color: AppColors.accentSoft),
            ),
          ),
        ),
      ],
    );
  }
}

/// The thirteen groups, for refiling one lift without dragging it.
class _GroupPickSheet extends StatelessWidget {
  final Exercise exercise;
  final ValueChanged<Muscle> onPick;

  const _GroupPickSheet({required this.exercise, required this.onPick});

  @override
  Widget build(BuildContext context) {
    // Conditioning is not a filing decision — it follows from how the exercise
    // is tracked, and a treadmill filed under Chest would be a state no other
    // screen knows how to draw. So the sheet says so rather than offering
    // thirteen wrong answers.
    if (exercise.isCardio) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(2, 2, 2, 12),
        child: Text(
          '${exercise.name} is tracked as cardio, so it lives under '
          'Conditioning. Change its tracking to file it under a muscle group.',
          style: AppText.ui(size: 13.5, height: 1.45, color: AppColors.muted),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        MusclePicker(
            selected: {exercise.muscle},
            onTap: onPick,
            muscles: Muscle.trainable),
        const SizedBox(height: 8),
      ],
    );
  }
}

/// Opens the group-colour picker.
///
/// It wears the palette instead of a paint-tin glyph: four dots in the four
/// region colours, which are summarised live from the user's own thirteen. So
/// the control shows the setting it opens — the same trick the Appearance
/// button plays by drawing itself in the active accent — and after a recolour
/// this button is the first thing that proves it took.
class _PaletteButton extends StatelessWidget {
  const _PaletteButton();

  @override
  Widget build(BuildContext context) {
    const dot = 7.0;
    const gap = 3.0;

    Widget swatch(String region) => Container(
          width: dot,
          height: dot,
          decoration: BoxDecoration(
            color: AppColors.group(region),
            shape: BoxShape.circle,
          ),
        );

    void open() {
      HapticFeedback.selectionClick();
      Sheets.openMuscleColors(context);
    }

    return Semantics(
      button: true,
      label: 'Group colors',
      // ExcludeSemantics below drops the gesture detector's own action, so
      // without this the button announces as one that cannot be pressed.
      onTap: open,
      child: ExcludeSemantics(
        child: Tooltip(
          message: 'Group colors',
          child: PressScale(
            onTap: open,
            borderRadius: AppRadii.rMd,
            // The square matches the height of the New button beside it; the
            // 44px box around it is the tap target PRODUCT requires, which the
            // 34px visual can't supply on its own.
            child: SizedBox(
              width: 44,
              height: 44,
              child: Center(
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: AppColors.surface2,
                    borderRadius: AppRadii.rMd,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          swatch(MuscleRegion.push),
                          const SizedBox(width: gap),
                          swatch(MuscleRegion.pull),
                        ],
                      ),
                      const SizedBox(height: gap),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          swatch(MuscleRegion.legs),
                          const SizedBox(width: gap),
                          swatch(MuscleRegion.core),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
class _SectionHeader extends StatelessWidget {
  final Muscle muscle;
  final int count;
  final VoidCallback onTap;

  /// True while a dragged lift is over this group. The header answers in the
  /// accent — the one colour in Arc that means "this is the live one".
  final bool highlighted;

  const _SectionHeader({
    required this.muscle,
    required this.count,
    required this.onTap,
    this.highlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '${muscle.label}, $count exercises',
      // ExcludeSemantics drops the child's tap action, so the node needs its
      // own or it announces as a button and does nothing. This is also the
      // route a screen reader takes to the groups on the body's far side,
      // which it has no way to spin into view.
      onTap: onTap,
      child: ExcludeSemantics(
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.only(left: 2, right: 2),
            child: Row(
              children: [
                MuscleDot(muscle),
                const SizedBox(width: 8),
                Text(muscle.label.toUpperCase(),
                    style: AppText.ui(
                        size: 12.5,
                        weight: FontWeight.w700,
                        color: highlighted
                            ? AppColors.accentStrong
                            : AppColors.muted,
                        letterSpacing: 0.5)),
                const SizedBox(width: 8),
                Text('$count',
                    style: AppText.mono(
                        size: 12.5,
                        weight: FontWeight.w600,
                        color: highlighted
                            ? AppColors.accentStrong
                            : AppColors.faint)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Offers the bulk re-sort after an upgrade. Dismissable, and gone for good
/// once every group is settled — an upgrade notice that outlives the upgrade is
/// just clutter.
class _ReviewCard extends StatelessWidget {
  final int count;
  final VoidCallback onDismiss;

  const _ReviewCard({required this.count, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      decoration: BoxDecoration(
        color: AppColors.accentSoft,
        borderRadius: AppRadii.rMd,
        border: Border.all(color: AppColors.accentLine),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$count exercise${count == 1 ? '' : 's'} '
                  '${count == 1 ? 'needs' : 'need'} a muscle group',
                  style: AppText.ui(size: 14.5, weight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  'Arc guessed from the names. Check its work.',
                  style: AppText.ui(
                      size: 12.5,
                      weight: FontWeight.w500,
                      color: AppColors.muted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          ArcButton(
            label: 'Sort',
            size: BtnSize.sm,
            onTap: () => Sheets.openMuscleReview(context),
          ),
          const SizedBox(width: 4),
          SheetIconButton(
            icon: 'x',
            semanticLabel: 'Dismiss',
            onTap: onDismiss,
          ),
        ],
      ),
    );
  }
}

class _LibraryEmpty extends StatelessWidget {
  const _LibraryEmpty();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 30, 24, 32),
      decoration: BoxDecoration(
        borderRadius: AppRadii.rLg,
        border: Border.all(color: AppColors.cardLine),
      ),
      child: Column(
        children: [
          Text('No exercises yet.',
              style: AppText.ui(size: 16.5, weight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
            'Add the lifts you actually do. Arc files each one under a muscle '
            'group and starts tracking its estimated 1RM from the first set.',
            textAlign: TextAlign.center,
            style: AppText.ui(
                size: 13.5,
                height: 1.5,
                weight: FontWeight.w500,
                color: AppColors.faint),
          ),
          const SizedBox(height: 18),
          ArcButton(
            label: 'Add your first exercise',
            icon: 'plus',
            onTap: () => Sheets.openAddExercise(context),
          ),
        ],
      ),
    );
  }
}

class _NoMatches extends StatelessWidget {
  final String query;
  const _NoMatches({required this.query});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 34),
      child: Column(
        children: [
          Text('Nothing matches "${query.trim()}".',
              textAlign: TextAlign.center,
              style: AppText.ui(size: 15, weight: FontWeight.w600)),
          const SizedBox(height: 14),
          ArcButton(
            label: 'Create "${query.trim()}"',
            icon: 'plus',
            variant: BtnVariant.soft,
            size: BtnSize.sm,
            onTap: () => Sheets.openAddExercise(context),
          ),
        ],
      ),
    );
  }
}
