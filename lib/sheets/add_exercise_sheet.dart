import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/arc_data.dart';
import '../data/store.dart';
import '../theme/app_theme.dart';
import '../widgets/ui.dart';

const _lblStyleSize = 12.5;

Widget _label(String text) => Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 8),
      child: Text(
        text.toUpperCase(),
        style: AppText.sora(
          size: _lblStyleSize,
          weight: FontWeight.w700,
          color: AppColors.muted,
          letterSpacing: 0.5,
        ),
      ),
    );

/// Shared form to create a new exercise.
class AddExerciseForm extends StatefulWidget {
  final void Function(String name, String group, String unit) onCreate;
  final VoidCallback? onCancel;
  final String submitLabel;

  const AddExerciseForm({
    super.key,
    required this.onCreate,
    this.onCancel,
    this.submitLabel = 'Add exercise',
  });

  @override
  State<AddExerciseForm> createState() => _AddExerciseFormState();
}

class _AddExerciseFormState extends State<AddExerciseForm> {
  final _controller = TextEditingController();
  String _group = 'Push';
  String _unit = 'kg';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final valid = _controller.text.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _label('Exercise name'),
        ArcTextField(
          controller: _controller,
          hint: 'e.g. Front Squat',
          autofocus: true,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 18),
        _label('Muscle group'),
        Segmented.simple(
          options: ArcData.groups,
          value: _group,
          onChanged: (v) => setState(() => _group = v),
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
                    ? () => widget.onCreate(
                        _controller.text.trim(), _group, _unit)
                    : null,
              ),
            ),
          ],
        ),
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
  final Widget? prefix;
  final bool plain;

  const ArcTextField({
    super.key,
    required this.controller,
    required this.hint,
    this.autofocus = false,
    this.onChanged,
    this.prefix,
    this.plain = false,
  });

  @override
  State<ArcTextField> createState() => _ArcTextFieldState();
}

class _ArcTextFieldState extends State<ArcTextField> {
  final _focus = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() => _focused = _focus.hasFocus));
  }

  @override
  void dispose() {
    _focus.dispose();
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
      padding: EdgeInsets.symmetric(horizontal: widget.prefix != null ? 14 : 16),
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
              cursorColor: AppColors.accentStrong,
              style: AppText.sora(size: 16.5, weight: FontWeight.w500),
              decoration: InputDecoration(
                isCollapsed: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
                border: InputBorder.none,
                hintText: widget.hint,
                hintStyle: AppText.sora(
                    size: 16.5, weight: FontWeight.w500, color: AppColors.faint),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// App-level "New Exercise" sheet (launched from the Library tab).
class AddExerciseSheet extends StatelessWidget {
  const AddExerciseSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.read<ArcStore>();
    return AddExerciseForm(
      onCreate: (name, group, unit) async {
        await store.addExercise(name: name, group: group, unit: unit);
        if (context.mounted) Navigator.of(context).maybePop();
      },
    );
  }
}
