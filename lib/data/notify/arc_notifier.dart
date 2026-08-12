// How a companion's moment looks in the Android shade.
//
// Everything Arc puts on screen elsewhere is built from its own tokens, and the
// shade is no exception: the rising-curve mark, the accent the user actually
// chose, and two channels named in Arc's factual voice rather than "Alerts" and
// "Misc". The one concession to the platform is structure — this is the OS's
// surface, and its conventions (channels, groups, expandable text, tap-to-open)
// are affordances, not chrome to be redesigned.

import 'dart:convert';
import 'dart:ui' show Color, PlatformDispatcher, Brightness;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../db/app_database.dart';
import '../../theme/accent.dart';
import '../../theme/app_theme.dart';
import 'companion_event.dart';

/// Payload carried on a notification tap: which companion it was about, so Arc
/// can open straight to their progress instead of its own front door.
class AlertTap {
  final String companionId;
  const AlertTap(this.companionId);

  String encode() => jsonEncode({'companion': companionId});

  static AlertTap? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw);
      if (m is! Map) return null;
      final id = m['companion'];
      return id is String && id.isNotEmpty ? AlertTap(id) : null;
    } catch (_) {
      return null;
    }
  }
}

/// Presents companion moments as Android notifications.
///
/// Constructed in two places that never share memory — the app isolate and the
/// background worker's — so it holds no state beyond the plugin handle and is
/// safe to build twice.
class ArcNotifier {
  ArcNotifier({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  /// Android settings groups a channel group into one collapsible block, so
  /// Arc's two switches sit together rather than loose among the system's.
  static const _groupId = 'arc.companions';
  static const _groupName = 'Companions';

  /// Every companion alert shares this key, so the shade stacks them into one
  /// Arc entry instead of a column of near-identical lines.
  static const _bundleKey = 'arc.companions.bundle';
  static const _summaryId = 1;

  static const _workoutChannel = AndroidNotificationChannel(
    'arc.companion.workouts',
    'Companion workouts',
    description: 'When a companion starts a workout.',
    // A training partner walking into the gym is worth a sound, not a
    // full-screen interruption — this makes noise without seizing the screen.
    importance: Importance.defaultImportance,
    groupId: _groupId,
  );

  static const _recordChannel = AndroidNotificationChannel(
    'arc.companion.records',
    'Companion records',
    description: 'When a companion sets a new personal record.',
    // The peak moment in the whole product. It earns the peek.
    importance: Importance.high,
    groupId: _groupId,
  );

  /// The status-bar mark: Arc's rising curve with the record marked at its head
  /// (`android/app/src/main/res/drawable/ic_stat_arc.xml`). Android silhouettes
  /// small icons, so it is drawn as white-on-transparent and tinted at runtime.
  static const _smallIcon = 'ic_stat_arc';

  bool _ready = false;

  /// Whether this build runs somewhere companion alerts exist at all.
  ///
  /// Arc also builds for web, where the plugin needs its own initialisation
  /// settings and there is no background worker to feed it. Rather than
  /// half-support it, every entry point below no-ops off Android — the events
  /// still publish and sync, they simply are not announced.
  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Registers channels and the tap handler. Idempotent, and safe to call
  /// before the user has granted anything — creating a channel is not a prompt.
  /// [onResponse] receives every response this one does not recognise as a
  /// companion tap. The plugin allows exactly one handler per process, and the
  /// rest timer's notifications need one too — so the two share this, rather
  /// than the second `initialize` call silently replacing the first.
  ///
  /// [onBackgroundResponse] must be a top-level function with a
  /// `vm:entry-point` pragma: it runs in an isolate spawned for a tap that
  /// arrived with Arc in the background.
  Future<void> init({
    void Function(AlertTap tap)? onTap,
    void Function(NotificationResponse response)? onResponse,
    DidReceiveBackgroundNotificationResponseCallback? onBackgroundResponse,
  }) async {
    if (_ready || !_supported) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings(_smallIcon),
      ),
      onDidReceiveNotificationResponse: (response) {
        final tap = AlertTap.decode(response.payload);
        if (tap != null) {
          onTap?.call(tap);
        } else {
          onResponse?.call(response);
        }
      },
      onDidReceiveBackgroundNotificationResponse: onBackgroundResponse,
    );
    final android = _android;
    if (android != null) {
      await android.createNotificationChannelGroup(
        const AndroidNotificationChannelGroup(_groupId, _groupName,
            description: 'Workouts and records from the people you train with.'),
      );
      await android.createNotificationChannel(_workoutChannel);
      await android.createNotificationChannel(_recordChannel);
    }
    _ready = true;
  }

  /// The tap that launched Arc from cold, if it was one.
  ///
  /// A notification tapped while the app is dead never reaches
  /// `onDidReceiveNotificationResponse` — the process starts *because* of it,
  /// and the payload is waiting here instead. Without this, the one tap most
  /// likely to happen (phone locked, alert on the lock screen) is the one that
  /// would drop you on the dashboard.
  Future<AlertTap?> launchTap() async {
    if (!_supported) return null;
    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details?.didNotificationLaunchApp != true) return null;
      return AlertTap.decode(details!.notificationResponse?.payload);
    } catch (e) {
      debugPrint('Arc notify: launch details unavailable ($e)');
      return null;
    }
  }

  AndroidFlutterLocalNotificationsPlugin? get _android => _supported
      ? _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      : null;

  /// Whether the OS will currently let Arc post anything.
  Future<bool> get enabled async =>
      await _android?.areNotificationsEnabled() ?? false;

  /// Asks for POST_NOTIFICATIONS (Android 13+). Called from the moment that
  /// makes it make sense — pairing with a companion — never at cold launch,
  /// where a prompt with no context is the one a user denies forever.
  Future<bool> requestPermission() async =>
      await _android?.requestNotificationsPermission() ?? false;

  /// Posts [event] as [who] did it. Returns false when nothing was shown.
  Future<bool> show(CompanionEvent event, String who, {Color? accent}) async {
    if (!await enabled) return false;
    final copy = AlertCopy.of(event, who);
    final channel = event.kind == EventKind.personalRecord
        ? _recordChannel
        : _workoutChannel;

    final details = AndroidNotificationDetails(
      channel.id,
      channel.name,
      channelDescription: channel.description,
      importance: channel.importance,
      priority: channel.importance == Importance.high
          ? Priority.high
          : Priority.defaultPriority,
      icon: _smallIcon,
      color: accent,
      // Android truncates the collapsed body to one line; expanding shows the
      // sentence whole, exactly as written.
      styleInformation: BigTextStyleInformation(
        copy.full,
        contentTitle: copy.title,
      ),
      // What a screen reader announces as it arrives.
      ticker: copy.full,
      groupKey: _bundleKey,
      // The stack's summary is silent; only the arriving alert makes a sound.
      groupAlertBehavior: GroupAlertBehavior.children,
      category: AndroidNotificationCategory.social,
      // The event id is what the ledger dedupes on, so tagging by it means even
      // a double-post would replace rather than stack.
      tag: event.id,
      when: event.createdAt,
      // A moment already carries how long it stays true; the shade entry gets
      // the remainder of exactly that. "Alice has started a workout" clearing
      // itself once the session it describes is over is the difference between
      // an alert and a stale line you scroll past tomorrow morning.
      timeoutAfter: _remainingLife(event),
    );

    await _plugin.show(
      id: _idFor(event.id),
      title: copy.title,
      body: copy.body,
      notificationDetails: NotificationDetails(android: details),
      payload: AlertTap(event.ownerId).encode(),
    );
    await _refreshSummary(channel, accent);
    return true;
  }

  /// Keeps the stack's header truthful: Android only collapses a group once a
  /// summary exists, and the summary has to be rebuilt as members arrive.
  ///
  /// Below two members there is nothing to summarise, and a lone summary would
  /// show as a second, empty Arc line — so it is cancelled instead.
  ///
  /// [channel] is whichever one the arriving alert used, never a fixed choice:
  /// a summary posted to a channel the user has muted is a summary Android
  /// silently drops, which would take the whole stack's header with it.
  Future<void> _refreshSummary(
      AndroidNotificationChannel channel, Color? accent) async {
    final android = _android;
    if (android == null) return;
    try {
      final active = await _plugin.getActiveNotifications();
      final lines = [
        for (final n in active)
          if (n.id != _summaryId && n.groupKey == _bundleKey)
            '${n.title ?? ''}${(n.body ?? '').isEmpty ? '' : ' · ${n.body}'}',
      ];
      if (lines.length < 2) {
        await _plugin.cancel(id: _summaryId);
        return;
      }
      await _plugin.show(
        id: _summaryId,
        title: 'Companions',
        body: '${lines.length} updates',
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            channel.id,
            channel.name,
            channelDescription: channel.description,
            icon: _smallIcon,
            color: accent,
            groupKey: _bundleKey,
            setAsGroupSummary: true,
            groupAlertBehavior: GroupAlertBehavior.children,
            styleInformation: InboxStyleInformation(
              lines,
              contentTitle: 'Companions',
              summaryText: '${lines.length} updates',
            ),
          ),
        ),
      );
    } catch (e) {
      // Reading active notifications is unsupported before Android 6 and can
      // throw on some OEM builds. The alerts themselves are already posted;
      // losing the summary is cosmetic.
      debugPrint('Arc notify: summary skipped ($e)');
    }
  }

  /// Milliseconds of [event]'s freshness window still to run, or null when the
  /// kind is one worth keeping until the user clears it. Never zero or
  /// negative: Android reads that as "already expired" and the alert would be
  /// dismissed the instant it appeared.
  static int? _remainingLife(CompanionEvent event) {
    if (event.kind != EventKind.workoutStarted) return null;
    final left = eventFreshness(event.kind).inMilliseconds -
        (DateTime.now().millisecondsSinceEpoch - event.createdAt);
    return left > 0 ? left : null;
  }

  /// A stable 31-bit id per event, so the same moment can never occupy two
  /// slots in the shade. Android notification ids are ints; event ids are not.
  static int _idFor(String eventId) {
    // FNV-1a, masked positive and clear of the summary's reserved id.
    var hash = 0x811c9dc5;
    for (final unit in eventId.codeUnits) {
      hash = (hash ^ unit) * 0x01000193 & 0x7fffffff;
    }
    return hash <= _summaryId ? _summaryId + 1 : hash;
  }
}

/// The accent to tint the shade's mark with: the user's own hue, rendered for
/// the surface it will actually land on.
///
/// The shade follows the *system* theme, not Arc's, so a phone in dark mode gets
/// the dark palette's accent even while Arc itself is running light — otherwise
/// Surge's deep volt would sit on near-black at a whisper of contrast. The hue
/// is always the user's; only the rendition follows the surface.
Future<Color> notificationAccent(AppDatabase db) async {
  final shadeIsDark =
      PlatformDispatcher.instance.platformBrightness == Brightness.dark;
  final key = shadeIsDark ? 'accent_hue_dark' : 'accent_hue_light';
  final stored = int.tryParse(await db.getSetting(key) ?? '');
  final hue = (stored != null && stored >= 0 && stored <= 359)
      ? stored
      : AccentRamp.defaultHue(dark: shadeIsDark);
  final base = shadeIsDark ? ArcPalette.midnight : ArcPalette.surge;
  // `accentLine` is the token already solved for exactly this problem: the
  // accent pitched dark enough to hold an edge as a thin mark on a light
  // ground, and left bright on a dark one.
  return base.withAccentHue(hue).accentLine;
}
