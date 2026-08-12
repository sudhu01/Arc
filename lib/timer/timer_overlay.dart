// The rest bar, floating over whatever the phone is doing instead.
//
// This runs in a second Flutter engine inside the overlay service, started by
// the platform at the `overlayMain` entry point in lib/main.dart. That engine
// shares nothing with the app: no provider tree, no database, no theme
// controller. It is handed a deadline once and counts down from it locally,
// which is exactly what lets it stay truthful after Android has killed Arc.
//
// So the palette here is resolved from the message rather than from AppColors,
// and the layout is deliberately one row: an overlay window that grows is an
// overlay window in the way.

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';

import 'timer_settings.dart';

/// The name the app's isolate registers its action port under.
///
/// Taps on the bubble do not come back over the plugin's own channel.
/// flutter_overlay_window keeps one static handle to "the other engine", and
/// the overlay engine — which attaches second, when the app creates it — leaves
/// that handle pointing at itself. A message sent from the bubble is therefore
/// delivered straight back to the bubble, and the app never hears it.
///
/// The two engines share a process and so share a Dart VM, which is what makes
/// a named port able to carry what the channel cannot.
const String _kActionPort = 'arc.timer.overlay.actions';

/// Sends a tapped action to the app's isolate.
void _sendAction(String action) {
  final port = IsolateNameServer.lookupPortByName(_kActionPort);
  if (port != null) {
    port.send(action);
    return;
  }
  // No port registered: either Android reclaimed Arc's isolate mid-rest, or
  // this is a build where the plugin's channel does reach the app. Trying it
  // costs nothing, and TimerController reconciles from disk at the next resume
  // if nothing arrives at all.
  unawaited(FlutterOverlayWindow.shareData(action));
}

/// Height of the floating window, in logical pixels. Tall enough for the count
/// at a glance, short enough to sit above a video without covering it.
///
/// Converted to device pixels before it is handed over — see
/// [TimerOverlay._windowHeightPx].
const int _kOverlayHeight = 116;

/// What the app sends into the overlay engine.
class _OverlayState {
  const _OverlayState({
    required this.endsAt,
    required this.totalMs,
    required this.paused,
    required this.dark,
    required this.accent,
  });

  final int endsAt;

  /// The rest's full length, so the rail measures against the real thing
  /// rather than against the longest remainder this window happens to have
  /// seen.
  final int totalMs;
  final bool paused;
  final bool dark;
  final int accent;

  static _OverlayState? decode(dynamic raw) {
    try {
      final map = raw is String ? jsonDecode(raw) : raw;
      if (map is! Map) return null;
      final endsAt = map['endsAt'];
      if (endsAt is! int) return null;
      final total = map['totalMs'];
      return _OverlayState(
        endsAt: endsAt,
        totalMs: total is int && total > 0
            ? total
            : TimerSettings.defaultDuration.inMilliseconds,
        paused: map['paused'] == true,
        dark: map['dark'] == true,
        accent: map['accent'] is int ? map['accent'] as int : 0xFFC6F432,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Drives the floating window from the app side.
///
/// Every entry point is a no-op where the window cannot exist — off Android,
/// and for anyone who has not turned it on — so call sites never have to ask.
class TimerOverlay {
  TimerOverlay._();

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Accent and brightness are read at show time and baked into the message:
  /// the overlay engine has no access to Arc's theme, and a bubble in Arc's
  /// light palette floating over a dark launcher looks like someone else's app.
  static int _accent = 0xFFC6F432;
  static bool _dark = false;

  /// Tells the overlay which colours to wear. Called by the app whenever the
  /// theme or accent changes.
  static void adoptTheme({required bool dark, required int accent}) {
    _dark = dark;
    _accent = accent;
  }

  /// Whether the user has granted "Display over other apps".
  static Future<bool> hasPermission() async {
    if (!_supported) return false;
    try {
      return await FlutterOverlayWindow.isPermissionGranted();
    } catch (_) {
      return false;
    }
  }

  /// Asks for the grant, sending the user to the system screen. Only ever
  /// called from the switch the user just tapped.
  static Future<bool> ensurePermission() async {
    if (!_supported) return false;
    if (await hasPermission()) return true;
    try {
      await FlutterOverlayWindow.requestPermission();
      return hasPermission();
    } catch (e) {
      debugPrint('Arc timer: overlay permission request failed ($e)');
      return false;
    }
  }

  /// The window's height in the units Android actually measures it in.
  ///
  /// `showOverlay` looks like it speaks logical pixels — everything else in
  /// Flutter does — but the plugin passes the number straight into
  /// `WindowManager.LayoutParams`, which is raw device pixels, and converts
  /// nothing. Unconverted, 116 becomes 39dp on a 3x phone: a window shorter
  /// than the bar inside it, so the bar lays out past its own window and not a
  /// pixel of it is ever drawn.
  ///
  /// The status bar inset is added rather than ignored because the bar wears a
  /// [SafeArea]; a window sized without it clips the bar by exactly that much.
  static int _windowHeightPx() {
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    // No view to measure — headless, or between engines. Three is the density
    // of the phones this window is for, and too tall merely wastes a strip of
    // screen where too short shows nothing at all.
    if (view == null) return _kOverlayHeight * 3;
    return (_kOverlayHeight * view.devicePixelRatio).round() +
        view.viewPadding.top.round();
  }

  /// Puts the bubble on screen counting down to [endsAt], or updates the one
  /// already there.
  static Future<void> show({
    required int endsAt,
    required Duration total,
    required bool paused,
    required bool enabled,
  }) async {
    if (!_supported || !enabled) return;
    try {
      if (!await hasPermission()) return;
      final opened = !await FlutterOverlayWindow.isActive();
      if (opened) {
        await FlutterOverlayWindow.showOverlay(
          height: _windowHeightPx(),
          width: WindowSize.matchParent,
          alignment: OverlayAlignment.topCenter,
          // Pinned, rather than left to the plugin's default. That default
          // offsets the window up by the status bar height and then converts
          // that pixel value a second time as though it were dp, which puts a
          // window this short entirely above the top of the screen.
          startPosition: const OverlayPosition(0, 0),
          flag: OverlayFlag.defaultFlag,
          visibility: NotificationVisibility.visibilitySecret,
          positionGravity: PositionGravity.none,
          enableDrag: true,
          overlayTitle: 'Rest timer',
          overlayContent: 'Counting down',
        );
      }
      final payload = jsonEncode({
        'endsAt': endsAt,
        'totalMs': total.inMilliseconds,
        'paused': paused,
        'dark': _dark,
        'accent': _accent,
      });
      await FlutterOverlayWindow.shareData(payload);
      // The overlay engine boots with the app, so its listener is normally up
      // long before this. But nothing retries a message that arrives first:
      // the window would sit there blank for the whole rest, which looks
      // exactly like the bubble never appearing. One repeat closes that.
      if (opened) {
        Timer(const Duration(milliseconds: 300), () async {
          try {
            await FlutterOverlayWindow.shareData(payload);
          } catch (_) {
            // The window was closed in the meantime. Nothing to say.
          }
        });
      }
    } catch (e) {
      debugPrint('Arc timer: could not show the floating bar ($e)');
    }
  }

  static Future<void> hide() async {
    if (!_supported) return;
    try {
      if (await FlutterOverlayWindow.isActive()) {
        await FlutterOverlayWindow.closeOverlay();
      }
    } catch (e) {
      debugPrint('Arc timer: could not close the floating bar ($e)');
    }
  }

  /// Actions tapped on the bubble, arriving back in the app's isolate.
  ///
  /// Opened once and kept for the life of the process — see [_kActionPort] for
  /// why this is a port rather than the plugin's channel.
  static Stream<dynamic> get actions => _actions ??= _openPort();

  static Stream<dynamic>? _actions;

  static Stream<dynamic> _openPort() {
    if (!_supported) return const Stream.empty();
    // A name can only be registered once, and a hot restart leaves the old
    // mapping behind pointing at an isolate that no longer exists.
    IsolateNameServer.removePortNameMapping(_kActionPort);
    final port = ReceivePort();
    IsolateNameServer.registerPortWithName(port.sendPort, _kActionPort);
    return port.asBroadcastStream();
  }
}

/// The widget tree the overlay engine runs. Entered from `overlayMain`.
class TimerOverlayApp extends StatelessWidget {
  const TimerOverlayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Material(color: Colors.transparent, child: _FloatingRestBar()),
    );
  }
}

class _FloatingRestBar extends StatefulWidget {
  const _FloatingRestBar();

  @override
  State<_FloatingRestBar> createState() => _FloatingRestBarState();
}

class _FloatingRestBarState extends State<_FloatingRestBar> {
  _OverlayState? _state;
  Timer? _ticker;
  StreamSubscription<dynamic>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = FlutterOverlayWindow.overlayListener.listen((event) {
      final next = _OverlayState.decode(event);
      if (next != null && mounted) setState(() => _state = next);
    });
    // Its own clock. The app that handed over the deadline may already be dead
    // by the next second, which is the whole reason this window exists.
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  Duration get _left {
    final s = _state;
    if (s == null) return Duration.zero;
    final ms = s.endsAt - DateTime.now().millisecondsSinceEpoch;
    return Duration(milliseconds: ms < 0 ? 0 : ms);
  }

  @override
  Widget build(BuildContext context) {
    final s = _state;
    if (s == null) return const SizedBox.shrink();

    final accent = Color(s.accent);
    final surface = s.dark ? const Color(0xFF16181C) : const Color(0xFFFFFFFF);
    final ink = s.dark ? const Color(0xFFF2F4F7) : const Color(0xFF14171C);
    final muted = s.dark ? const Color(0xFF8B929E) : const Color(0xFF6B7280);
    final rail = s.dark ? const Color(0xFF2A2E35) : const Color(0xFFE8EAEE);

    final left = _left;
    final over = left == Duration.zero;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
        child: GestureDetector(
          onTap: () => _sendAction('open'),
          child: Container(
            height: 58,
            decoration: BoxDecoration(
              color: surface,
              borderRadius: BorderRadius.circular(18),
              boxShadow: const [
                BoxShadow(
                    color: Color(0x3A000000),
                    blurRadius: 24,
                    offset: Offset(0, 8)),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Stack(
                // Centred, not the Stack's top-left default: the row is 44
                // tall inside a 58 bar, and left to itself it sits seven
                // pixels high with the slack pooling under it.
                alignment: Alignment.center,
                children: [
                  Row(
                    children: [
                      // Clear of the corner radius. Same lead-in as the bar
                      // inside Arc, which is the point of this window.
                      const SizedBox(width: 18),
                      Text(
                        over ? 'REST OVER' : (s.paused ? 'PAUSED' : 'REST'),
                        style: TextStyle(
                          fontFamily: 'Sora',
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          color: muted,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        formatRest(left),
                        style: TextStyle(
                          fontFamily: 'Space Grotesk',
                          fontSize: 26,
                          height: 1,
                          fontWeight: FontWeight.w600,
                          color: over || left.inSeconds < 10 ? accent : ink,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      // Matches the bar inside Arc exactly; the two windows
                      // are meant to be the same object seen twice.
                      const SizedBox(width: 10),
                      // A finished rest has nothing left to pause, so the
                      // control becomes the one thing there is to do with it:
                      // acknowledge it. Same swap, same glyph and same accent
                      // as the bar inside Arc — the two windows are meant to be
                      // the same object seen twice, and that has to hold at the
                      // end of the rest as much as during it.
                      if (over)
                        _OverlayButton(
                          icon: Icons.check_rounded,
                          label: 'Dismiss the finished rest',
                          color: accent,
                          onTap: () => _sendAction('reset'),
                        )
                      else
                        _OverlayButton(
                          icon: s.paused
                              ? Icons.play_arrow_rounded
                              : Icons.pause_rounded,
                          label: s.paused ? 'Resume rest' : 'Pause rest',
                          color: ink,
                          onTap: () =>
                              _sendAction(s.paused ? 'resume' : 'pause'),
                        ),
                      _OverlayButton(
                        icon: Icons.replay_rounded,
                        label: 'Reset rest',
                        color: muted,
                        onTap: () => _sendAction('reset'),
                      ),
                      const SizedBox(width: 6),
                    ],
                  ),
                  // The drain. Same instrument as the bar inside Arc, so the
                  // countdown reads the same whichever one you are looking at.
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _DrainRail(
                      progress:
                          (1 - left.inMilliseconds / s.totalMs).clamp(0.0, 1.0),
                      accent: accent,
                      track: rail,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

}

class _DrainRail extends StatelessWidget {
  const _DrainRail({
    required this.progress,
    required this.accent,
    required this.track,
  });

  final double progress;
  final Color accent;
  final Color track;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 3,
      child: Stack(
        children: [
          Positioned.fill(child: ColoredBox(color: track)),
          FractionallySizedBox(
            widthFactor: (1 - progress).clamp(0.0, 1.0),
            child: ColoredBox(color: accent),
          ),
        ],
      ),
    );
  }
}

class _OverlayButton extends StatelessWidget {
  const _OverlayButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(icon, size: 21, color: color),
        ),
      ),
    );
  }
}
