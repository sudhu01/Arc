import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/store.dart';
import '../sheets/sheet_actions.dart';
import '../theme/app_theme.dart';
import '../timer/timer_bar.dart';
import '../timer/timer_controller.dart';
import '../widgets/arc_icons.dart';
import 'dashboard.dart';
import 'records.dart';
import 'calendar.dart';
import 'library.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  /// Guards against a second timer screen stacking on the first when the shade
  /// and the floating bar are both tapped, or when one is tapped twice.
  bool _timerOpen = false;
  ValueNotifier<int>? _openRequests;

  void _setTab(int t) => setState(() => _tab = t);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The countdown in the shade and the bubble over other apps both point
    // here, and neither has a navigator of its own.
    final requests = context.read<TimerController>().openRequests;
    if (identical(requests, _openRequests)) return;
    _openRequests?.removeListener(_openTimer);
    _openRequests = requests..addListener(_openTimer);
  }

  @override
  void dispose() {
    _openRequests?.removeListener(_openTimer);
    super.dispose();
  }

  Future<void> _openTimer() async {
    if (_timerOpen || !mounted) return;
    _timerOpen = true;
    try {
      await openTimer(context);
    } finally {
      _timerOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final safeBottom = MediaQuery.of(context).padding.bottom;
    final safeTop = MediaQuery.of(context).padding.top;
    final navHeight = 76 + safeBottom;
    final timerActive = context.select<TimerController, bool>((t) => t.isActive);

    final screens = [
      Dashboard(onNavTab: _setTab),
      const Records(),
      const CalendarScreen(),
      Library(visible: _tab == 3),
    ];

    return Scaffold(
      backgroundColor: AppColors.bg,
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          Positioned.fill(
            child: SafeArea(
              bottom: false,
              child: AnimatedPadding(
                duration: Duration(
                    milliseconds:
                        MediaQuery.disableAnimationsOf(context) ? 0 : 320),
                curve: Curves.easeOutQuart,
                padding: EdgeInsets.only(
                  top: timerActive ? TimerBar.height + 14 : 6,
                  bottom: navHeight + 8,
                ),
                child: IndexedStack(
                  index: _tab,
                  children: screens,
                ),
              ),
            ),
          ),

          // top scrim under status bar
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: MediaQuery.of(context).padding.top + 8,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      AppColors.bg,
                      AppColors.bg.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: safeTop + 6,
            left: 0,
            right: 0,
            child: TimerBar(onOpen: _openTimer),
          ),

          // toast
          Positioned(
            left: 0,
            right: 0,
            bottom: navHeight + 16,
            child: Center(child: _ToastPill(notifier: context.read<ArcStore>().toast)),
          ),

          // bottom nav
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _BottomNav(
              tab: _tab,
              height: navHeight,
              safeBottom: safeBottom,
              onTab: _setTab,
            ),
          ),

          // raised FAB
          Positioned(
            left: 0,
            right: 0,
            bottom: navHeight - 28,
            child: Center(
              child: _Fab(onTap: () => Sheets.openLog(context)),
            ),
          ),
        ],
      ),
    );
  }
}

class _Fab extends StatefulWidget {
  final VoidCallback onTap;
  const _Fab({required this.onTap});

  @override
  State<_Fab> createState() => _FabState();
}

class _FabState extends State<_Fab> {
  bool _down = false;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      child: AnimatedScale(
        scale: _down ? 0.92 : 1,
        duration: const Duration(milliseconds: 110),
        child: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: AppColors.accent,
            borderRadius: BorderRadius.circular(20),
            // The design cuts the FAB out of the nav bar itself, so the ring
            // is nav-bg rather than surface (identical in light, not in dark).
            border: Border.all(color: AppColors.navBg, width: 4),
            boxShadow: AppShadows.accent,
          ),
          child: Icon(ArcIcons.byName('plus'), size: 26, color: AppColors.accentInk),
        ),
      ),
    );
  }
}

class _BottomNav extends StatelessWidget {
  final int tab;
  final double height;
  final double safeBottom;
  final ValueChanged<int> onTab;

  const _BottomNav({
    required this.tab,
    required this.height,
    required this.safeBottom,
    required this.onTab,
  });

  @override
  Widget build(BuildContext context) {
    // slot -> (icon, label, tabIndex) ; null = FAB gap
    final items = [
      (icon: 'home', label: 'Home', index: 0),
      (icon: 'trophy', label: 'Records', index: 1),
      null,
      (icon: 'calendar', label: 'History', index: 2),
      (icon: 'dumbbell', label: 'Exercises', index: 3),
    ];

    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          height: height,
          padding: EdgeInsets.only(top: 8, bottom: 18 + safeBottom),
          decoration: BoxDecoration(
            color: AppColors.navBg,
            border: Border(top: BorderSide(color: AppColors.navLine)),
          ),
          child: Row(
            children: items.map((it) {
              if (it == null) return const Expanded(child: SizedBox.shrink());
              final active = tab == it.index;
              final ink = active ? AppColors.accentStrong : AppColors.navMuted;
              return Expanded(
                // One node per tab, announced as a button that is or is not
                // the current one. `excludeSemantics` drops the label Text so
                // it is not read twice, which also drops the detector's own tap
                // action — so the action is declared here instead.
                child: Semantics(
                  label: it.label,
                  button: true,
                  selected: active,
                  excludeSemantics: true,
                  onTap: () => onTab(it.index),
                  child: GestureDetector(
                    onTap: () => onTab(it.index),
                    behavior: HitTestBehavior.opaque,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Every tab marks current the same way: the glyph
                        // fills. Home and Records have a solid twin in the
                        // Material font, the dumbbell is solid already, and the
                        // calendar is drawn (see ArcCalendarGlyph) because the
                        // font ships no filled calendar to swap to.
                        ArcIcon(it.icon, size: 22, filled: active, color: ink),
                        const SizedBox(height: 3),
                        Text(
                          it.label,
                          style: AppText.ui(
                            size: 10,
                            height: 1.1,
                            weight: active ? FontWeight.w700 : FontWeight.w600,
                            color: ink,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }
}

class _ToastPill extends StatefulWidget {
  final ValueNotifier<ArcToast?> notifier;
  const _ToastPill({required this.notifier});

  @override
  State<_ToastPill> createState() => _ToastPillState();
}

class _ToastPillState extends State<_ToastPill> {
  ArcToast? _current;
  bool _shown = false;
  Timer? _timer;
  int _lastSeq = -1;

  @override
  void initState() {
    super.initState();
    widget.notifier.addListener(_onToast);
  }

  @override
  void dispose() {
    widget.notifier.removeListener(_onToast);
    _timer?.cancel();
    super.dispose();
  }

  void _onToast() {
    final t = widget.notifier.value;
    if (t == null || t.seq == _lastSeq) return;
    _lastSeq = t.seq;
    _timer?.cancel();
    setState(() {
      _current = t;
      _shown = true;
    });
    _timer = Timer(const Duration(milliseconds: 2300), () {
      if (mounted) setState(() => _shown = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = _current;
    if (t == null) return const SizedBox.shrink();
    final isMedal = t.icon == 'medal';
    return IgnorePointer(
      child: AnimatedSlide(
        offset: Offset(0, _shown ? 0 : 0.4),
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
        child: AnimatedOpacity(
          opacity: _shown ? 1 : 0,
          duration: const Duration(milliseconds: 250),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
            decoration: BoxDecoration(
              color: AppColors.toastBg,
              borderRadius: BorderRadius.circular(999),
              boxShadow: const [
                BoxShadow(
                    color: Color(0x47000000),
                    blurRadius: 28,
                    offset: Offset(0, 8)),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  ArcIcons.byName(t.icon),
                  size: 18,
                  color: isMedal ? AppColors.accent : AppColors.toastInk,
                ),
                const SizedBox(width: 9),
                Text(
                  t.msg,
                  style: AppText.ui(
                      size: 14.5,
                      weight: FontWeight.w600,
                      color: AppColors.toastInk),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
