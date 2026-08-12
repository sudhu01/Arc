import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'data/db/app_database.dart';
import 'data/identity/identity_service.dart';
import 'data/notify/arc_notifier.dart';
import 'data/notify/background_worker.dart';
import 'data/notify/push_transport.dart';
import 'data/store.dart';
import 'data/sync/sync_service.dart';
import 'screens/home_shell.dart';
import 'sheets/sheet_actions.dart';
import 'theme/app_theme.dart';
import 'theme/muscle_palette.dart';
import 'theme/muscle_palette_controller.dart';
import 'theme/theme_controller.dart';
import 'timer/timer_background.dart';
import 'timer/timer_controller.dart';
import 'timer/timer_notification.dart';
import 'timer/timer_overlay.dart';

/// Entry point for the floating rest bar's own Flutter engine.
///
/// The platform starts this by name — `OverlayService` looks up "overlayMain"
/// in the default entry-point library, which is this file — so it must stay
/// top-level, keep the pragma, and keep the name. Nothing from `main` above has
/// run when this executes: it is a second engine in the same process, with its
/// own everything.
@pragma('vm:entry-point')
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TimerOverlayApp());
}

/// Where a notification tap lands before there is a widget tree to receive it.
///
/// A tap can arrive at three different times — during `main`, from a cold
/// launch; while the shell is alive; or between the two, in the half-second
/// before the first frame — and all three funnel here. `_AlertRouting` drains
/// it as soon as there is a Navigator to open a sheet on.
final ValueNotifier<AlertTap?> _pendingTap = ValueNotifier(null);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Open the SQLite backend, ensure a device identity exists, then load the
  // store from disk (seeding on first launch).
  final db = await AppDatabase.open();
  final identity = IdentityService();
  await identity.ensure(db);
  final sync = SyncService(db: db, identity: identity);

  // Notification channels are registered before the store so the very first
  // sync below already has somewhere to post what it pulls. Creating a channel
  // is not a permission prompt — that is asked for later, at pairing.
  // One notification handler serves the whole app: the plugin allows a single
  // registration per process, so the companion alerts and the rest timer share
  // it. `arcTimerBackgroundAction` is the other half — the shade's Pause and
  // Reset buttons have to work with Arc closed, which is the only state they
  // exist for.
  final notifier = ArcNotifier();
  final timer = TimerController(db);
  await notifier.init(
    onTap: (tap) => _pendingTap.value = tap,
    onResponse: (response) {
      final action = decodeTimerAction(response);
      if (action != null) timer.handleAction(action);
    },
    onBackgroundResponse: arcTimerBackgroundAction,
  );
  _pendingTap.value = await notifier.launchTap();

  final store = ArcStore(db: db, identity: identity, sync: sync, notifier: notifier);
  await store.init();

  // Before the first frame, so a relaunch mid-rest shows the bar already
  // counting rather than snapping into place a beat later.
  await timer.load();

  // Restore the saved theme before the first frame so a dark install never
  // flashes light on launch — and the saved group colours with it, so a
  // recoloured library never flashes Arc's defaults either.
  final theme = ThemeController(db);
  final palette = MusclePaletteController(db);
  await theme.load();
  await palette.load();
  SystemChrome.setSystemUIOverlayStyle(ArcTheme.overlayStyle);

  // Sync on launch (background): push anything left dirty from a previous
  // session and pull companions' latest. Failures surface via a toast. A
  // successful pass also delivers any companion moments waiting on the relay.
  unawaited(store.autoSync());

  // Delivery while Arc is closed. Registered once, kept by the OS across
  // launches — see `background_worker.dart` for what the fifteen-minute floor
  // buys and what an FCM transport would buy on top of it.
  unawaited(registerCompanionPolling());

  // The relay can only wake this device if something hands it an address.
  // `PollingOnlyTransport` never does, which is why the poll above is the
  // shipped delivery path; swapping in `packages/arc_fcm` is what turns this
  // line live. See docs/push-notifications.md.
  unawaited(_attachPushTransport(store, const PollingOnlyTransport()));

  runApp(ArcAppRoot(
      store: store, theme: theme, palette: palette, timer: timer));
}

/// Registers this device's push address with the relay and turns every nudge
/// into the same delivery pass a poll would have run.
Future<void> _attachPushTransport(ArcStore store, PushTransport transport) async {
  final token = await transport.deviceToken();
  if (token != null) await store.registerPushToken(token);
  transport.wakeSignals.listen((_) => store.deliverCompanionAlerts());
}

class ArcAppRoot extends StatelessWidget {
  const ArcAppRoot({
    super.key,
    required this.store,
    required this.theme,
    required this.palette,
    required this.timer,
  });

  final ArcStore store;
  final ThemeController theme;
  final MusclePaletteController palette;
  final TimerController timer;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: store),
        ChangeNotifierProvider.value(value: theme),
        ChangeNotifierProvider.value(value: palette),
        ChangeNotifierProvider.value(value: timer),
      ],
      child: Consumer2<ThemeController, MusclePaletteController>(
        builder: (context, theme, palette, _) {
          SystemChrome.setSystemUIOverlayStyle(ArcTheme.overlayStyle);
          // The floating bar runs in an engine with no access to any of this,
          // so it is told the palette here, where a theme or accent change is
          // already being handled.
          TimerOverlay.adoptTheme(
              dark: theme.isDark, accent: AppColors.accent.toARGB32());
          return MaterialApp(
            title: 'Arc',
            debugShowCheckedModeBanner: false,
            theme: buildArcTheme(),
            // Screens read their colors from `AppColors` statics rather than
            // an inherited theme, and most of the tree is built from `const`
            // widgets that would otherwise short-circuit the rebuild. Keying
            // on the palette forces the whole shell to be rebuilt with the
            // new tokens.
            //
            // The accent hue joins the key so dragging the picker repaints the
            // live app behind the sheet. That means a full shell rebuild per
            // drag frame: the hue is quantized to whole degrees to bound it at
            // 360, and the dashboard's list carries a `PageStorageKey` so the
            // recreated tree restores its scroll offset instead of jumping to
            // the top under the user.
            //
            // The group hues join it for the same reason and at the same cost.
            // They fold to one int rather than thirteen so the key stays a
            // short string — the shell rebuilds when any group moves, which is
            // what puts a recoloured dot on every row behind the sheet.
            home: _AlertRouting(
              child: HomeShell(
                key: ValueKey(
                    '${theme.isDark}:${theme.accentHue}:${MusclePalette.signature}'),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Keeps companion moments arriving while Arc is on screen, and takes a tapped
/// notification where it was pointing.
///
/// The background worker owns delivery when the app is closed; this owns it
/// when the app is open, where its fifteen-minute floor would feel broken —
/// you should not learn that your training partner started an hour ago while
/// staring at their profile.
class _AlertRouting extends StatefulWidget {
  const _AlertRouting({required this.child});

  final Widget child;

  @override
  State<_AlertRouting> createState() => _AlertRoutingState();
}

class _AlertRoutingState extends State<_AlertRouting>
    with WidgetsBindingObserver {
  /// Frequent enough that a companion's set feels live, rare enough to be
  /// invisible on a battery: one authenticated GET that returns an empty list
  /// almost every time.
  static const _foregroundPoll = Duration(minutes: 4);

  Timer? _poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pendingTap.addListener(_drainTap);
    _startPolling();
    // A tap that arrived before this tree existed is still waiting.
    WidgetsBinding.instance.addPostFrameCallback((_) => _drainTap());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pendingTap.removeListener(_drainTap);
    _poll?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startPolling();
      // Coming back to Arc is the single most likely moment to have missed
      // something, so it costs a pass rather than waiting out the interval.
      unawaited(context.read<ArcStore>().deliverCompanionAlerts());
    } else {
      _poll?.cancel();
      _poll = null;
    }
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(_foregroundPoll, (_) {
      if (mounted) unawaited(context.read<ArcStore>().deliverCompanionAlerts());
    });
  }

  Future<void> _drainTap() async {
    final tap = _pendingTap.value;
    if (tap == null || !mounted) return;
    _pendingTap.value = null;
    await Sheets.openCompanionProgress(context, tap.companionId);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
