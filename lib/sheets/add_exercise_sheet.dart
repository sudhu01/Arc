import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
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
  final void Function(
      String name, Muscle muscle, List<Muscle> secondary, String unit) onCreate;
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

  /// Until the user touches a picker, the name drives the groups. The moment
  /// they do, it stops — nothing is more irritating than a control that undoes
  /// your choice because you kept typing.
  late bool _followName = widget.initialMuscle == null;

  bool _secondaryOpen = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onNameChanged(String value) {
    setState(() {
      if (!_followName) return;
      final guess = MuscleMap.guess(value);
      if (guess == null) return;
      _muscle = guess.primary;
      _secondary = guess.secondary;
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

  @override
  Widget build(BuildContext context) {
    final valid = _controller.text.trim().isNotEmpty;
    final matched = _followName && MuscleMap.guess(_controller.text) != null;

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
        MusclePicker(selected: {_muscle}, onTap: _pickPrimary),
        const SizedBox(height: 18),
        _SecondaryField(
          secondary: _secondary,
          primary: _muscle,
          open: _secondaryOpen,
          onToggleOpen: () => setState(() => _secondaryOpen = !_secondaryOpen),
          onToggleMuscle: _toggleSecondary,
        ),
        const SizedBox(height: 18),
        _label('Tracking'),
        Segmented(
          options: const [
            SegOption('kg', 'Weight (kg)'),
            SegOption('bw', 'Bodyweight'),
          ],
          value: _unit,
          onChanged: (v) => setState(() => _unit = v),
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
                    ? () => widget.onCreate(_controller.text.trim(), _muscle,
                        _secondary, _unit)
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
      onCreate: (name, muscle, secondary, unit) async {
        await store.addExercise(
            name: name, muscle: muscle, secondary: secondary, unit: unit);
        if (context.mounted) Navigator.of(context).maybePop();
      },
    );
  }
}
