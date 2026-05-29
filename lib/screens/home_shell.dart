import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/store.dart';
import '../sheets/sheet_actions.dart';
import '../theme/app_theme.dart';
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

  void _setTab(int t) => setState(() => _tab = t);

  @override
  Widget build(BuildContext context) {
    final safeBottom = MediaQuery.of(context).padding.bottom;
    final navHeight = 76 + safeBottom;

    final screens = [
      Dashboard(onNavTab: _setTab),
      const Records(),
      const CalendarScreen(),
      const Library(),
    ];

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(
        children: [
          // screen content
          Positioned.fill(
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: EdgeInsets.only(top: 6, bottom: navHeight + 8),
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
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [AppColors.bg, Color(0x00F4F5F7)],
                  ),
                ),
              ),
            ),
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
            border: Border.all(color: AppColors.surface, width: 4),
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
          decoration: const BoxDecoration(
            color: Color(0xD9FFFFFF), // white @ ~85%
            border: Border(top: BorderSide(color: AppColors.line)),
          ),
          child: Row(
            children: items.map((it) {
              if (it == null) return const Expanded(child: SizedBox.shrink());
              final active = tab == it.index;
              return Expanded(
                child: GestureDetector(
                  onTap: () => onTab(it.index),
                  behavior: HitTestBehavior.opaque,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        ArcIcons.byName(it.icon,
                            filled: active && it.icon == 'home'),
                        size: 22,
                        color: active ? AppColors.accentStrong : AppColors.navMuted,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        it.label,
                        style: AppText.sora(
                          size: 10,
                          height: 1.1,
                          weight: active ? FontWeight.w700 : FontWeight.w600,
                          color:
                              active ? AppColors.accentStrong : AppColors.navMuted,
                        ),
                      ),
                    ],
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
                  style: AppText.sora(
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
