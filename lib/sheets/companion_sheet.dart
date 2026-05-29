import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../data/identity/pairing.dart';
import '../data/models.dart';
import '../data/store.dart';
import '../theme/app_theme.dart';
import '../widgets/arc_icons.dart';
import '../widgets/sheet.dart';
import '../widgets/ui.dart';
import 'companion_progress_sheet.dart';

/// Companions hub: my shareable QR/link, a scanner to add others, the
/// companion list, and a recovery-phrase backup. Reached from the dashboard.
class CompanionSheet extends StatelessWidget {
  const CompanionSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ArcStore>();
    final id = store.identity;
    final companions = store.companions;

    // Incoming pending requests get an accept/block row; everything else
    // (accepted, my outgoing-pending, blocked) shows in the companion list.
    bool isRequest(Companion c) =>
        c.status == CompanionStatus.pending && c.incoming;
    final requests = companions.where(isRequest).toList();
    final others = companions.where((c) => !isRequest(c)).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── My identity / QR ──────────────────────────────────────────
        // Content laid directly on the sheet; only the QR keeps its own frame.
        Column(
          children: [
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: AppRadii.rMd,
                border: Border.all(color: AppColors.line),
              ),
              child: QrImageView(
                data: store.pairingUri,
                size: 196,
                backgroundColor: Colors.white,
                eyeStyle: const QrEyeStyle(
                  eyeShape: QrEyeShape.square,
                  color: AppColors.ink,
                ),
                dataModuleStyle: const QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square,
                  color: AppColors.ink,
                ),
              ),
            ),
            const SizedBox(height: 14),
            GestureDetector(
              onTap: () => _editName(context, store, id.displayName),
              behavior: HitTestBehavior.opaque,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    id.displayName?.isNotEmpty == true
                        ? id.displayName!
                        : 'Set your name',
                    style: AppText.sora(size: 18, weight: FontWeight.w700),
                  ),
                  const SizedBox(width: 6),
                  const ArcIcon('pencil', size: 15, color: AppColors.muted),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _shortId(id.publicId),
              style: AppText.mono(size: 12.5, color: AppColors.muted),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: ArcButton(
                    label: 'Scan code',
                    icon: 'scan',
                    onTap: () => _scan(context, store),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(child: _CopyLinkButton(store: store)),
              ],
            ),
          ],
        ),
        const SizedBox(height: 16),

        // ── Sync ───────────────────────────────────────────────────────
        ArcButton(
          label: store.syncing ? 'Syncing…' : 'Sync now',
          icon: 'refresh',
          variant: BtnVariant.soft,
          full: true,
          disabled: store.syncing,
          onTap: () => store.syncNow(),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 7, bottom: 2),
          child: Text(
            store.syncError != null
                ? 'Sync failed: ${store.syncError}'
                : store.lastSyncedAt != null
                    ? 'Last synced ${_clock(store.lastSyncedAt!)} · ${_host(store.serverUrl)}'
                    : 'Syncs with ${_host(store.serverUrl)}',
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: AppText.sora(
              size: 11.5,
              height: 1.35,
              color: store.syncError != null ? AppColors.danger : AppColors.faint,
            ),
          ),
        ),
        const SizedBox(height: 16),

        // ── Incoming requests ──────────────────────────────────────────
        if (requests.isNotEmpty) ...[
          SectionHead(title: 'Requests'),
          ...requests.map((c) => _RequestRow(companion: c)),
          const SizedBox(height: 8),
        ],

        // ── Companions list ────────────────────────────────────────────
        SectionHead(title: 'Companions'),
        if (others.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 4, 2, 8),
            child: Text(
              'No companions yet. Scan a friend’s code to connect — '
              'their workouts sync here once you’ve both accepted.',
              style: AppText.sora(
                  size: 13.5, height: 1.4, color: AppColors.muted),
            ),
          )
        else
          ...others.map((c) => _CompanionRow(companion: c)),

        const SizedBox(height: 18),

        // ── Backup + restore + server ───────────────────────────────────
        ArcButton(
          label: 'Back up identity',
          icon: 'key',
          variant: BtnVariant.ghost,
          full: true,
          onTap: () => _showRecovery(context, store),
        ),
        const SizedBox(height: 8),
        ArcButton(
          label: store.restoring ? 'Restoring…' : 'Restore account',
          icon: 'restore',
          variant: BtnVariant.ghost,
          full: true,
          disabled: store.restoring,
          onTap: () => _restoreAccount(context, store),
        ),
        const SizedBox(height: 10),
        GestureDetector(
          onTap: () => _editServer(context, store),
          behavior: HitTestBehavior.opaque,
          child: Text(
            'Sync server · ${_host(store.serverUrl)}',
            textAlign: TextAlign.center,
            style: AppText.sora(size: 12, color: AppColors.muted),
          ),
        ),
        const SizedBox(height: 6),
      ],
    );
  }

  static String _host(String url) =>
      url.replaceFirst(RegExp(r'^https?://'), '');

  static String _clock(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  Future<void> _editServer(BuildContext context, ArcStore store) async {
    final controller = TextEditingController(text: store.serverUrl);
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Sync server',
            style: AppText.sora(size: 18, weight: FontWeight.w700)),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'https://your-server'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (url != null && url.isNotEmpty) {
      await store.setServerUrl(url);
    }
  }

  /// Restore a backed-up account on a fresh install: paste the 24-word phrase,
  /// then [ArcStore.restoreAccount] re-keys the identity and pulls my own data
  /// back from the relay. Success is announced by a toast from the store.
  Future<void> _restoreAccount(BuildContext context, ArcStore store) async {
    if (store.restoring) return;
    final controller = TextEditingController();
    final phrase = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Restore account',
            style: AppText.sora(size: 18, weight: FontWeight.w700)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Enter your 24-word recovery phrase to bring back your identity and '
              'pull your workouts down from the sync server. This replaces the '
              'data currently on this device.',
              style: AppText.sora(size: 13, height: 1.4, color: AppColors.muted),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: controller,
              autofocus: true,
              minLines: 3,
              maxLines: 4,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.multiline,
              decoration: const InputDecoration(hintText: 'word1 word2 word3 …'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (phrase == null || phrase.isEmpty) return;
    try {
      await store.restoreAccount(phrase);
    } on FormatException {
      store.toast.value = ArcToast('Invalid recovery phrase', 'trash',
          DateTime.now().millisecondsSinceEpoch);
    } catch (_) {
      store.toast.value = ArcToast('Restore failed — check your sync server',
          'trash', DateTime.now().millisecondsSinceEpoch);
    }
  }

  static String _shortId(String id) =>
      id.length <= 16 ? id : '${id.substring(0, 8)}…${id.substring(id.length - 6)}';

  Future<void> _scan(BuildContext context, ArcStore store) async {
    // Ask for camera access up front — before opening the scanner screen —
    // so the user isn't dropped onto a black camera view that then prompts.
    final status = await Permission.camera.request();
    if (!context.mounted) return;
    if (!status.isGranted) {
      store.toast.value = ArcToast(
        status.isPermanentlyDenied
            ? 'Camera blocked — enable it in Settings to scan'
            : 'Camera permission is needed to scan codes',
        'trash',
        DateTime.now().millisecondsSinceEpoch,
      );
      return;
    }
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const ScannerPage(), fullscreenDialog: true),
    );
    if (raw == null) return;
    await store.addCompanionFromScan(raw);
  }

  Future<void> _editName(
      BuildContext context, ArcStore store, String? current) async {
    final controller = TextEditingController(text: current ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Your name', style: AppText.sora(size: 18, weight: FontWeight.w700)),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'Shown to companions'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      await store.setDisplayName(name);
    }
  }

  Future<void> _showRecovery(BuildContext context, ArcStore store) async {
    final phrase = await store.identityService.recoveryPhrase();
    if (!context.mounted) return;
    final words = phrase.split(' ');
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Recovery phrase',
            style: AppText.sora(size: 18, weight: FontWeight.w700)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'These 24 words restore your identity on a new device. '
              'Anyone who has them controls your account — never share them.',
              style: AppText.sora(size: 13, height: 1.4, color: AppColors.muted),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surface2,
                borderRadius: AppRadii.rMd,
              ),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (var i = 0; i < words.length; i++)
                    Text('${i + 1}. ${words[i]}',
                        style: AppText.mono(size: 12.5)),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: phrase));
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: const Text('Copy'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }
}

/// Copies the pairing link, flipping to a "Copied" + tick confirmation for a
/// couple of seconds before reverting.
class _CopyLinkButton extends StatefulWidget {
  final ArcStore store;
  const _CopyLinkButton({required this.store});

  @override
  State<_CopyLinkButton> createState() => _CopyLinkButtonState();
}

class _CopyLinkButtonState extends State<_CopyLinkButton> {
  bool _copied = false;
  Timer? _revert;

  @override
  void dispose() {
    _revert?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.store.pairingUri));
    if (!mounted) return;
    setState(() => _copied = true);
    _revert?.cancel();
    _revert = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return ArcButton(
      label: _copied ? 'Copied' : 'Copy link',
      icon: _copied ? 'check' : 'copy',
      variant: BtnVariant.soft,
      onTap: _copy,
    );
  }
}

/// An incoming pairing request — accept (start syncing) or block.
class _RequestRow extends StatelessWidget {
  final Companion companion;
  const _RequestRow({required this.companion});

  @override
  Widget build(BuildContext context) {
    final store = context.read<ArcStore>();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: ArcCard(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${companion.displayName} wants to connect',
                    style: AppText.sora(size: 14.5, weight: FontWeight.w600),
                  ),
                ),
                const Tag('Request'),
              ],
            ),
            const SizedBox(height: 4),
            Text(CompanionSheet._shortId(companion.publicId),
                style: AppText.mono(size: 11.5, color: AppColors.muted)),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ArcButton(
                    label: 'Accept',
                    icon: 'check',
                    size: BtnSize.sm,
                    onTap: () => store.acceptCompanion(companion.publicId),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ArcButton(
                    label: 'Block',
                    variant: BtnVariant.danger,
                    size: BtnSize.sm,
                    onTap: () => store.blockCompanion(companion.publicId),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CompanionRow extends StatelessWidget {
  final Companion companion;
  const _CompanionRow({required this.companion});

  @override
  Widget build(BuildContext context) {
    final store = context.read<ArcStore>();
    final accepted = companion.status == CompanionStatus.accepted;
    final (statusLabel, statusColor, statusBg) = switch (companion.status) {
      CompanionStatus.accepted => ('SYNCED', AppColors.accentStrong, AppColors.accentSoft),
      CompanionStatus.pending => ('PENDING', AppColors.muted, AppColors.surface2),
      CompanionStatus.blocked => ('BLOCKED', AppColors.danger, AppColors.dangerSoft),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: ArcCard(
        // Accepted companions open their (read-only) progress.
        onTap: accepted ? () => _openProgress(context) : null,
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: const BoxDecoration(
                color: AppColors.surface2,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Text(
                _initials(companion.displayName),
                style: AppText.sora(size: 14, weight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(companion.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.sora(size: 15, weight: FontWeight.w600)),
                  const SizedBox(height: 3),
                  Text(CompanionSheet._shortId(companion.publicId),
                      style: AppText.mono(size: 11.5, color: AppColors.muted)),
                ],
              ),
            ),
            Tag(statusLabel, color: statusColor, background: statusBg),
            IconButton(
              icon: const ArcIcon('trash', size: 18, color: AppColors.muted),
              onPressed: () => store.removeCompanion(companion.publicId),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openProgress(BuildContext context) async {
    final store = context.read<ArcStore>();
    final data = await store.loadCompanionData(companion.publicId);
    if (data == null || !context.mounted) return;
    await showArcSheet(
      context: context,
      full: true,
      title: companion.displayName,
      builder: (_) => CompanionProgressSheet(data: data),
    );
  }

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) return parts.first.characters.first.toUpperCase();
    return (parts.first.characters.first + parts.last.characters.first)
        .toUpperCase();
  }
}

/// Full-screen QR scanner. Pops with the first decoded string, or null.
class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key});

  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  final _controller = MobileScannerController();
  final _picker = ImagePicker();
  bool _handled = false;
  bool _picking = false;
  // Keep the preview hidden behind an opaque cover until the camera is truly
  // running, so the brief garbage/stale texture frame on Android startup
  // (notably MIUI) never shows.
  bool _ready = false;
  bool _settleScheduled = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onCameraState);
    // Absolute fallback: never sit behind the cover if 'isRunning' never lands.
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted && !_ready) setState(() => _ready = true);
    });
  }

  void _onCameraState() {
    if (_ready) return;
    final s = _controller.value;
    if (s.error != null) {
      // Reveal immediately so the camera error UI is visible.
      setState(() => _ready = true);
      return;
    }
    if (s.isRunning && !_settleScheduled) {
      _settleScheduled = true;
      // Give the texture a beat to render a real frame before fading the cover.
      Future.delayed(const Duration(milliseconds: 240), () {
        if (mounted) setState(() => _ready = true);
      });
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onCameraState);
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    final code = capture.barcodes.isNotEmpty
        ? capture.barcodes.first.rawValue
        : null;
    if (code == null || code.isEmpty) return;
    _handled = true;
    Navigator.of(context).pop(code);
  }

  /// Pick a picture from the gallery and scan it for an Arc QR code. Asks for
  /// gallery/media access first; reports unreadable or non-Arc images via a
  /// toast and stays on the scanner so the user can try another picture.
  Future<void> _pickAndScan() async {
    if (_picking || _handled) return;
    setState(() => _picking = true);
    try {
      if (!await _ensurePhotoPermission()) {
        _notify('Gallery access is needed to upload a picture');
        return;
      }
      final file = await _picker.pickImage(source: ImageSource.gallery);
      if (file == null) return; // user cancelled the picker
      final result = await _controller.analyzeImage(file.path);
      final code = (result != null && result.barcodes.isNotEmpty)
          ? result.barcodes.first.rawValue
          : null;
      if (code == null || code.isEmpty) {
        _notify('No QR code found in that picture');
        return;
      }
      if (PairingPayload.tryParse(code) == null) {
        _notify('That isn’t a valid Arc QR code');
        return;
      }
      if (!mounted) return;
      _handled = true;
      Navigator.of(context).pop(code);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// Request gallery/media read access (READ_MEDIA_IMAGES on Android 13+,
  /// falling back to legacy storage on older devices).
  Future<bool> _ensurePhotoPermission() async {
    final photos = await Permission.photos.request();
    if (photos.isGranted || photos.isLimited) return true;
    if (defaultTargetPlatform == TargetPlatform.android) {
      final storage = await Permission.storage.request();
      return storage.isGranted;
    }
    return false;
  }

  /// A dark pill snackbar, matching the app's toast, shown above the scanner.
  void _notify(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.toastBg,
        duration: const Duration(milliseconds: 2300),
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ArcIcon('x', size: 18, color: AppColors.toastInk),
            const SizedBox(width: 9),
            Flexible(
              child: Text(
                msg,
                style: AppText.sora(
                    size: 14.5,
                    weight: FontWeight.w600,
                    color: AppColors.toastInk),
              ),
            ),
          ],
        ),
      ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text('Scan companion code',
            style: AppText.sora(size: 17, weight: FontWeight.w600, color: Colors.white)),
      ),
      body: Stack(
        alignment: Alignment.center,
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          // Opaque cover that hides the garbage startup frame, then fades out.
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _ready ? 0 : 1,
                duration: const Duration(milliseconds: 280),
                child: Container(
                  color: Colors.black,
                  alignment: Alignment.center,
                  child: const SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      valueColor: AlwaysStoppedAnimation(Colors.white24),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Framing reticle.
          Container(
            width: 240,
            height: 240,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: AppColors.accent, width: 3),
            ),
          ),
          Positioned(
            bottom: 40,
            left: 24,
            right: 24,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Point at a friend’s Arc QR code',
                  textAlign: TextAlign.center,
                  style: AppText.sora(size: 14, color: Colors.white70),
                ),
                const SizedBox(height: 16),
                ArcButton(
                  label: _picking ? 'Scanning picture…' : 'Upload from gallery',
                  icon: 'image',
                  variant: BtnVariant.soft,
                  full: true,
                  disabled: _picking,
                  onTap: _pickAndScan,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
