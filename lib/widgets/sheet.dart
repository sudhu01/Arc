import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'arc_icons.dart';

/// Presents an Arc-styled bottom sheet (rounded top, drag handle, title row).
Future<T?> showArcSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  String? title,
  bool full = false,
  bool scrollable = true,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    barrierColor: const Color(0x6B0A0806),
    builder: (ctx) => ArcSheetScaffold(
      title: title,
      full: full,
      scrollable: scrollable,
      child: Builder(builder: builder),
    ),
  );
}

class ArcSheetScaffold extends StatelessWidget {
  final String? title;
  final bool full;
  final bool scrollable;
  final Widget child;

  const ArcSheetScaffold({
    super.key,
    required this.child,
    this.title,
    this.full = false,
    this.scrollable = true,
  });

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final maxH = full
        ? media.size.height - media.padding.top - 10
        : media.size.height * 0.88;

    return Padding(
      // lift above the keyboard when an input is focused
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: Container(
          width: double.infinity,
          height: full ? maxH : null,
          decoration: const BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
            boxShadow: [
              BoxShadow(color: Color(0x2E000000), blurRadius: 40, offset: Offset(0, -10)),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Center(
                child: Container(
                  width: 38,
                  height: 5,
                  decoration: BoxDecoration(
                    color: AppColors.line,
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
              ),
              if (title != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 8, 18, 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          title!,
                          style: AppText.sora(
                              size: 21,
                              weight: FontWeight.w700,
                              letterSpacing: -0.21),
                        ),
                      ),
                      GestureDetector(
                        onTap: () => Navigator.of(context).maybePop(),
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: const BoxDecoration(
                            color: AppColors.surface2,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(ArcIcons.byName('x'),
                              size: 18, color: AppColors.muted),
                        ),
                      ),
                    ],
                  ),
                ),
              Flexible(
                child: scrollable
                    ? SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(18, 4, 18, 26),
                        child: child,
                      )
                    : Padding(
                        padding: const EdgeInsets.fromLTRB(18, 4, 18, 0),
                        child: child,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
