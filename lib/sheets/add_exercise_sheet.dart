import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/cardio.dart';
import '../data/muscle.dart';
import '../data/muscle_map.dart';
import '../data/store.dart';
import '../theme/app_theme.dart';
import '../widgets/arc_icons.dart';
import '../widgets/muscle_picker.dart';
import '../widgets/ui.dart';

const _lblStyleSize = 12.5;

Widget _label(String text, {Widget? trailing}) => Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 8),
      child: Row(
        children: [
          Text(
            text.toUpperCase(),
            style: AppText.ui(
              size: _lblStyleSize,
              weight: FontWeight.w700,
              color: AppColors.muted,
              letterSpacing: 0.5,
            ),
          ),
          if (trailing != null) ...[const Spacer(), trailing],
        ],
      ),
    );

/// Shared form to create a new exercise.
class AddExerciseForm extends StatefulWidget {
  final void Function(String name, Muscle muscle, List<Muscle> secondary,
      String unit, CardioKind? cardioKind) onCreate;
  final VoidCallback? onCancel;
  final String submitLabel;

  /// Group to start on. Null means "follow the name" — the dictionary picks as
  /// the user types, which is the path most exercises take. A non-null value
  /// comes from context the user already expressed (adding from inside the
  /// Chest sheet) and pins the choice immediately.
  final Muscle? initialMuscle;

  const AddExerciseForm({
    super.key,
    required this.onCreate,
    this.onCancel,
    this.submitLabel = 'Add exercise',
    this.initialMuscle,
  });

  @override
  State<AddExerciseForm> createState() => _AddExerciseFormState();
}

class _AddExerciseFormState extends State<AddExerciseForm> {
  final _controller = TextEditingController();
  late Muscle _muscle = widget.initialMuscle ?? Muscle.chest;
  List<Muscle> _secondary = const [];
  String _unit = 'kg';
  CardioKind _cardioKind = CardioKind.run;

  /// Until the user touches a picker, the name drives the groups. The moment
  /// they do, it stops — nothing is more irritating than a control that undoes
  /// your choice because you kept typing.
  late bool _followName = widget.initialMuscle == null;

  /// The same rule for the tracking control: "Treadmill" selects Cardio and Run
  /// on its own, and stops doing so the instant the user picks either by hand.
  bool _followNameUnit = true;

  bool _secondaryOpen = false;

  bool get _isCardio => _unit == 'cardio';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onNameChanged(String value) {
    setState(() {
      // The tracking guess runs on its own flag: a user who picked Bodyweight
      // by hand and then finished typing "Pull-Up" should keep Bodyweight, but
      // should still get the group the dictionary reads off the name.
      if (_followNameUnit) {
        final kind = MuscleMap.cardioGuess(value);
        if (kind != null) {
          _unit = 'cardio';
          _cardioKind = kind;
          // Holds the invariant even when the user pinned a group first: there
          // is no such thing as a treadmill filed under Chest.
          _muscle = Muscle.cardio;
          _secondary = const [];
        } else if (_unit == 'cardio') {
          // The name stopped reading as cardio — "Bike" edited to "Bike Squat".
          _unit = 'kg';
        }
      }
      if (!_followName) return;
      final guess = MuscleMap.guess(value);
      if (guess == null) return;
      _muscle = guess.primary;
      _secondary = guess.secondary;
    });
  }

  void _pickUnit(String v) {
    setState(() {
      _followNameUnit = false;
      _unit = v;
      // Conditioning is never a body part, and nothing else can be filed under
      // it. Both directions are handled here so the group can never disagree
      // with the tracking, whichever the user changed.
      if (v == 'cardio') {
        _muscle = Muscle.cardio;
        _secondary = const [];
        _followName = false;
      } else if (_muscle == Muscle.cardio) {
        _muscle = MuscleMap.guess(_controller.text)?.primary ?? Muscle.chest;
      }
    });
  }

  void _pickPrimary(Muscle m) {
    setState(() {
      _followName = false;
      _muscle = m;
      // A group can't be its own assistant.
      _secondary = _secondary.where((s) => s != m).toList();
    });
  }

  void _toggleSecondary(Muscle m) {
    setState(() {
      _followName = false;
      _secondary = _secondary.contains(m)
          ? (_secondary.where((s) => s != m).toList())
          : [..._secondary, m];
    });
  }

  /// One line saying what this kind will actually ask for, so the third
  /// measure is never a surprise the first time the log sheet draws it.
  static String _kindNote(CardioKind k) => switch (k) {
        CardioKind.run =>
          'Treadmill, running, sprints. Time, distance and incline.',
        CardioKind.machine =>
          'Elliptical, bike, rower. Time, distance and resistance.',
        CardioKind.climb => 'Stairs and stepmills. Time, floors and level.',
        CardioKind.open => 'Jump rope, swimming, rucking. Time and distance.',
      };

  @override
  Widget build(BuildContext context) {
    final valid = _controller.text.trim().isNotEmpty;
    final matched = _followName &&
        !_isCardio &&
        MuscleMap.guess(_controller.text) != null;
    final cardioMatched =
        _followNameUnit && MuscleMap.cardioGuess(_controller.text) != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _label('Exercise name'),
        ArcTextField(
          controller: _controller,
          hint: 'e.g. Front Squat',
          autofocus: true,
          onChanged: _onNameChanged,
        ),
        const SizedBox(height: 18),
        // Conditioning replaces the group question rather than answering it —
        // the group is settled the moment the tracking is, and a wall of
        // thirteen body parts above a treadmill is a question with no right
        // answer. What a treadmill *does* need asking is which machine it is,
        // so that slot carries the machine instead.
        if (_isCardio) ...[
          _label(
            'Machine',
            trailing: cardioMatched
                ? Text('set from the name',
                    style: AppText.ui(
                        size: 11.5,
                        weight: FontWeight.w500,
                        color: AppColors.faint))
                : null,
          ),
          Segmented(
            options: [
              for (final k in CardioKind.values) SegOption(k.id, k.label),
            ],
            value: _cardioKind.id,
            onChanged: (v) => setState(() {
              _followNameUnit = false;
              _cardioKind = CardioKind.fromId(v) ?? CardioKind.run;
            }),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Text(
              _kindNote(_cardioKind),
              style: AppText.ui(
                  size: 12.5, height: 1.4, color: AppColors.muted),
            ),
          ),
        ] else ...[
          _label(
            'Muscle group',
            trailing: matched
                ? Text('set from the name',
                    style: AppText.ui(
                        size: 11.5,
                        weight: FontWeight.w500,
                        color: AppColors.faint))
                : null,
          ),
          MusclePicker(
              selected: {_muscle},
              onTap: _pickPrimary,
              muscles: Muscle.trainable),
          const SizedBox(height: 18),
          _SecondaryField(
            secondary: _secondary,
            primary: _muscle,
            open: _secondaryOpen,
            onToggleOpen: () => setState(() => _secondaryOpen = !_secondaryOpen),
            onToggleMuscle: _toggleSecondary,
          ),
        ],
        const SizedBox(height: 18),
        _label('Tracking'),
        Segmented(
          // Labels shortened from "Weight (kg)" to fit three segments: the
          // control ellipsises rather than wrapping, and "Weight" loses nothing
          // the kg suffix on the stepper does not already say.
          options: const [
            SegOption('kg', 'Weight'),
            SegOption('bw', 'Bodyweight'),
            SegOption('cardio', 'Cardio'),
          ],
          value: _unit,
          onChanged: _pickUnit,
        ),
        const SizedBox(height: 22),
        Row(
          children: [
            if (widget.onCancel != null) ...[
              Expanded(
                child: ArcButton(
                  label: 'Cancel',
                  variant: BtnVariant.ghost,
                  full: true,
                  onTap: widget.onCancel,
                ),
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              flex: 2,
              child: ArcButton(
                label: widget.submitLabel,
                icon: 'check',
                full: true,
                disabled: !valid,
                onTap: valid
                    ? () => widget.onCreate(
                          _controller.text.trim(),
                          _muscle,
                          _secondary,
                          _unit,
                          _isCardio ? _cardioKind : null,
                        )
                    : null,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Secondary groups, collapsed to a summary line by default.
///
/// They matter — they're what makes the body's volume map honest about a bench
/// press working triceps — but they are never required, and the dictionary has
/// usually filled them in already. So they read as a stated fact you can open,
/// not a second wall of thirteen pills between the user and Add.
class _SecondaryField extends StatelessWidget {
  final List<Muscle> secondary;
  final Muscle primary;
  final bool open;
  final VoidCallback onToggleOpen;
  final ValueChanged<Muscle> onToggleMuscle;

  const _SecondaryField({
    required this.secondary,
    required this.primary,
    required this.open,
    required this.onToggleOpen,
    required this.onToggleMuscle,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          expanded: open,
          label: 'Also works: ${secondarySummary(secondary)}',
          // ExcludeSemantics drops the child's tap action; without this the
          // disclosure announces as a button that cannot be opened.
          onTap: onToggleOpen,
          child: ExcludeSemantics(
            child: GestureDetector(
              onTap: onToggleOpen,
              behavior: HitTestBehavior.opaque,
              child: Container(
                constraints: const BoxConstraints(minHeight: 44),
                alignment: Alignment.centerLeft,
                child: Row(
                  children: [
                    Text('ALSO WORKS',
                        style: AppText.ui(
                            size: _lblStyleSize,
                            weight: FontWeight.w700,
                            color: AppColors.muted,
                            letterSpacing: 0.5)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        secondarySummary(secondary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.ui(
                          size: 13.5,
                          weight: FontWeight.w500,
                          color: secondary.isEmpty
                              ? AppColors.faint
                              : AppColors.ink,
                        ),
                      ),
                    ),
                    AnimatedRotation(
                      turns: open ? 0.5 : 0,
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      child: Icon(ArcIcons.byName('chevD'),
                          size: 18, color: AppColors.faint),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (open) ...[
          const SizedBox(height: 10),
          MusclePicker(
            selected: secondary.toSet(),
            onTap: onToggleMuscle,
            disabled: {primary},
            muscles: Muscle.trainable,
          ),
        ],
      ],
    );
  }
}

/// Styled text input matching the design.
class ArcTextField extends StatefulWidget {
  final TextEditingController controller;
  final String hint;
  final bool autofocus;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final Widget? prefix;
  final Widget? suffix;
  final bool plain;
  final TextInputType? keyboardType;
  final bool autocorrect;
  /// Supply one to control focus from outside; otherwise an internal node is used.
  final FocusNode? focusNode;

  const ArcTextField({
    super.key,
    required this.controller,
    required this.hint,
    this.focusNode,
    this.autofocus = false,
    this.onChanged,
    this.onSubmitted,
    this.prefix,
    this.suffix,
    this.plain = false,
    this.keyboardType,
    this.autocorrect = true,
  });

  @override
  State<ArcTextField> createState() => _ArcTextFieldState();
}

class _ArcTextFieldState extends State<ArcTextField> {
  late final FocusNode _focus = widget.focusNode ?? FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  void _onFocus() {
    if (mounted) setState(() => _focused = _focus.hasFocus);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    if (widget.focusNode == null) _focus.dispose(); // only ours to dispose
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: AppRadii.rMd,
        border: Border.all(
          color: _focused && !widget.plain ? AppColors.accent : AppColors.line,
        ),
      ),
      padding: EdgeInsets.only(
        left: widget.prefix != null ? 14 : 16,
        right: widget.suffix != null ? 8 : 16,
      ),
      child: Row(
        children: [
          if (widget.prefix != null) ...[
            widget.prefix!,
            const SizedBox(width: 10),
          ],
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: _focus,
              autofocus: widget.autofocus,
              onChanged: widget.onChanged,
              onSubmitted: widget.onSubmitted,
              keyboardType: widget.keyboardType,
              autocorrect: widget.autocorrect,
              enableSuggestions: widget.autocorrect,
              textInputAction:
                  widget.onSubmitted != null ? TextInputAction.done : null,
              cursorColor: AppColors.accentStrong,
              style: AppText.ui(size: 16.5, weight: FontWeight.w500),
              decoration: InputDecoration(
                isCollapsed: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
                border: InputBorder.none,
                hintText: widget.hint,
                hintStyle: AppText.ui(
                    size: 16.5, weight: FontWeight.w500, color: AppColors.faint),
              ),
            ),
          ),
          if (widget.suffix != null) widget.suffix!,
        ],
      ),
    );
  }
}

/// App-level "New Exercise" sheet. [initialMuscle] pins the group when the user
/// already said which one they meant — adding from inside the Chest sheet, or
/// from a muscle they just tapped on the body. Null leaves it to the name.
class AddExerciseSheet extends StatelessWidget {
  final Muscle? initialMuscle;
  const AddExerciseSheet({super.key, this.initialMuscle});

  @override
  Widget build(BuildContext context) {
    final store = context.read<ArcStore>();
    return AddExerciseForm(
      initialMuscle: initialMuscle,
      onCreate: (name, muscle, secondary, unit, cardioKind) async {
        await store.addExercise(
            name: name,
            muscle: muscle,
            secondary: secondary,
            unit: unit,
            cardioKind: cardioKind);
        if (context.mounted) Navigator.of(context).maybePop();
      },
    );
  }
}
