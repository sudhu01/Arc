import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../data/arc_data.dart';
import '../data/muscle.dart';
import '../data/store.dart';
import '../sheets/sheet_actions.dart';
import '../theme/app_theme.dart';
import 'body_server.dart';

/// The rotatable figure on the Exercises screen.
///
/// The figure carries no text of its own. Tapping a muscle opens its sheet —
/// the renderer raycasts the tap against the solid mesh and sends back a group
/// id — so the naming happens in the sheet rather than on the body.
///
/// One consequence worth knowing: nothing on this screen is reachable by a
/// screen reader, because the only thing in it is a platform view. List mode is
/// the accessible route to the same groups, and the screen offers both as peers.
///
/// It also has to be impossible for this to strand the user. If the renderer
/// doesn't report a first frame within [_bootTimeout], or the platform view
/// fails outright, [onUnavailable] fires and the screen falls back to the list.
class BodyView extends StatefulWidget {
  /// Called when the renderer cannot be shown, so the screen can switch modes.
  final VoidCallback onUnavailable;

  /// Whether the Exercises tab is the one on screen.
  ///
  /// This has to be told, not detected. The tab bar is an `IndexedStack`, which
  /// keeps every screen mounted and merely stops painting the ones it isn't
  /// showing — and a WebView is a platform view, so nothing about "stopped
  /// being painted" reaches the JavaScript inside it. Left to itself the
  /// renderer composes bloom at 60fps while the user reads the Dashboard.
  final bool visible;

  const BodyView({
    super.key,
    required this.onUnavailable,
    this.visible = true,
  });

  @override
  State<BodyView> createState() => _BodyViewState();
}

/// Generous on purpose: a cold WebView on a mid-range Android has to start a
/// renderer process and parse ~700KB of JavaScript before it can draw. Cutting
/// this shorter trades a rare slow start for a common wrong fallback.
const _bootTimeout = Duration(seconds: 8);

class _BodyViewState extends State<BodyView> {
  WebViewController? _controller;
  Timer? _bootTimer;

  bool _ready = false;
  bool _failed = false;

  Map<Muscle, double>? _pushedVolume;
  bool? _pushedDark;
  int? _pushedAccent;

  @override
  void initState() {
    super.initState();
    // Only if the tab is already open. Booting here unconditionally would put
    // WebView startup, a ~700KB JavaScript parse and the point-scatter pass
    // into the app's own cold start, for a screen the user may never open —
    // and it would spend the boot timeout while they are somewhere else.
    if (widget.visible) _boot();
  }

  @override
  void didUpdateWidget(BodyView old) {
    super.didUpdateWidget(old);
    if (widget.visible == old.visible) return;
    if (widget.visible && _controller == null && !_failed) {
      _boot();
    } else {
      _pushVisible();
    }
  }

  @override
  void dispose() {
    _bootTimer?.cancel();
    super.dispose();
  }

  Future<void> _boot() async {
    try {
      final server = await BodyServer.instance();
      if (!mounted) return;

      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(Colors.transparent)
        ..addJavaScriptChannel('ArcChannel', onMessageReceived: _onMessage)
        ..setNavigationDelegate(NavigationDelegate(
          onWebResourceError: (error) {
            // Sub-resource errors are noise; only a failed main document means
            // there is nothing to show.
            if (error.isForMainFrame ?? true) _fail();
          },
        ))
        ..loadRequest(server.origin);

      setState(() => _controller = controller);
      _bootTimer = Timer(_bootTimeout, () {
        if (!_ready) _fail();
      });
    } catch (_) {
      _fail();
    }
  }

  void _fail() {
    if (_failed || !mounted) return;
    _failed = true;
    _bootTimer?.cancel();
    widget.onUnavailable();
  }

  void _send(Map<String, Object?> msg) {
    final c = _controller;
    if (c == null || !_ready) return;
    // The payload is JSON-encoded twice on purpose: once as the message, once
    // as a JavaScript string literal, so nothing in it can escape the call.
    final arg = jsonEncode(jsonEncode(msg));
    c.runJavaScript('window.arcBody && window.arcBody.handle($arg)');
  }

  void _onMessage(JavaScriptMessage message) {
    final Object? decoded = jsonDecode(message.message);
    if (decoded is! Map) return;
    switch (decoded['t']) {
      case 'ready':
        _bootTimer?.cancel();
        if (!mounted) return;
        setState(() => _ready = true);
        _pushTheme(force: true);
        _pushVolume(force: true);
        _send({
          't': 'motion',
          'reduce': MediaQuery.maybeOf(context)?.disableAnimations ?? false,
        });
        // Last, and unconditional: the tab can have been left during the boot
        // it just finished, and this is what stops the renderer immediately
        // rather than after the user comes back and leaves again.
        _pushVisible();
        break;

      case 'tap':
        final m = Muscle.fromId(decoded['id'] as String?);
        if (m != null) _open(m);
        break;
    }
  }

  /// Opens a group's sheet, and tells the renderer to focus it while that sheet
  /// is up. Nothing here needs a rebuild — the selection lives in the scene.
  Future<void> _open(Muscle m) async {
    HapticFeedback.selectionClick();
    _send({'t': 'select', 'id': m.id});
    _send({'t': 'sheet', 'fraction': 0.55});

    await Sheets.openMuscle(context, m);

    if (!mounted) return;
    _send({'t': 'select', 'id': null});
    _send({'t': 'sheet', 'fraction': 0.0});
  }

  /// Tells the renderer whether to keep drawing. Sent on every change and once
  /// on `ready`, so the scene never has to guess its starting state.
  void _pushVisible() => _send({'t': 'active', 'value': widget.visible});

  void _pushTheme({bool force = false}) {
    final accent = AppColors.accent.toARGB32();
    if (!force && _pushedDark == ArcTheme.isDark && _pushedAccent == accent) {
      return;
    }
    _pushedDark = ArcTheme.isDark;
    _pushedAccent = accent;
    _send({
      't': 'theme',
      'field': _hex(AppColors.bodyField),
      'accent': _hex(AppColors.accent),
      'ink': _hex(AppColors.bodyInk),
      // Dark accumulates light on a dark ground; light accumulates ink on a
      // pale one. Same figure, same edges, opposite polarity — an additive
      // glow simply does not exist on paper.
      'polarity': ArcTheme.isDark ? 1 : 0,
    });
  }

  void _pushVolume({bool force = false}) {
    final store = context.read<ArcStore>();
    final v = ArcData.muscleVolume(store.sessions, store.exById);
    if (!force && _pushedVolume != null && _sameVolume(_pushedVolume!, v)) {
      return;
    }
    _pushedVolume = v;
    _send({
      't': 'volume',
      'v': {for (final e in v.entries) e.key.id: e.value},
    });
  }

  static bool _sameVolume(Map<Muscle, double> a, Map<Muscle, double> b) {
    for (final m in Muscle.values) {
      if (((a[m] ?? 0) - (b[m] ?? 0)).abs() > 0.001) return false;
    }
    return true;
  }

  static String _hex(Color c) =>
      '#${c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}';

  @override
  Widget build(BuildContext context) {
    // Watched so a logged workout relights the body without a tab round-trip.
    context.watch<ArcStore>();
    if (_ready) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _pushTheme();
        _pushVolume();
      });
    }

    final controller = _controller;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (controller != null)
          ExcludeSemantics(
            child: WebViewWidget(controller: controller),
          ),

        // Holds the frame until the renderer has one of its own. Crossfading
        // out of a silhouette that matches the figure's stance reads as the
        // body arriving, not as a loader being replaced.
        IgnorePointer(
          child: AnimatedOpacity(
            opacity: _ready ? 0 : 1,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOut,
            child: const _BodyPoster(),
          ),
        ),

      ],
    );
  }
}

/// The still figure shown until the renderer draws. Same stance, same weight —
/// so the handover is a change of material, not a change of subject.
class _BodyPoster extends StatelessWidget {
  const _BodyPoster();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: 220,
        height: 400,
        child: CustomPaint(painter: _PosterPainter(AppColors.accent)),
      ),
    );
  }
}

class _PosterPainter extends CustomPainter {
  final Color color;
  const _PosterPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    // Soft rather than sharp: the renderer hands back a cloud with no hard
    // edge anywhere, and a crisp silhouette would pop when the two crossfade.
    final p = Paint()
      ..color = color.withValues(alpha: 0.16)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9);

    // Laid out in the renderer's own coordinates — feet at 0, crown at 1.8 —
    // and mapped in here, so the poster and the figure that replaces it stand
    // in the same place.
    final w = size.width;
    final h = size.height;
    double fx(double x) => (0.5 + x / 0.72) * w;
    double fy(double y) => (1 - y / 1.8) * h;

    void blob(double x, double y, double rx, double ry, {bool mirror = false}) {
      for (final s in mirror ? const [1.0, -1.0] : const [1.0]) {
        canvas.drawOval(
          Rect.fromCenter(
            center: Offset(fx(x * s), fy(y)),
            width: (rx / 0.36) * w,
            height: (ry / 0.9) * h,
          ),
          p,
        );
      }
    }

    blob(0, 1.668, 0.086, 0.132); // head
    blob(0, 1.500, 0.058, 0.055); // neck
    blob(0, 1.360, 0.170, 0.130); // chest
    blob(0, 1.060, 0.155, 0.170); // waist and hips
    blob(0.228, 1.290, 0.052, 0.120, mirror: true); // upper arm
    blob(0.315, 1.120, 0.042, 0.100, mirror: true); // forearm
    blob(0.095, 0.715, 0.090, 0.230, mirror: true); // thigh
    blob(0.105, 0.285, 0.062, 0.220, mirror: true); // shin
  }

  @override
  bool shouldRepaint(_PosterPainter old) => old.color != color;
}
