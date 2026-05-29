import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../data/models.dart';
import '../data/store.dart';
import '../theme/app_theme.dart';
import '../widgets/arc_icons.dart';
import '../widgets/ui.dart';

/// Companions hub: my shareable QR/link, a scanner to add others, the
/// companion list, and a recovery-phrase backup. Reached from the dashboard.
class CompanionSheet extends StatelessWidget {
  const CompanionSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ArcStore>();
    final id = store.identity;
    final companions = store.companions;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── My identity / QR ──────────────────────────────────────────
        ArcCard(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
          child: Column(
            children: [
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
              const SizedBox(height: 14),
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
                  Expanded(
                    child: ArcButton(
                      label: 'Copy link',
                      icon: 'copy',
                      variant: BtnVariant.soft,
                      onTap: () => _copyLink(context, store),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),

        // ── Companions list ───────────────────────────────────────────
        SectionHead(title: 'Companions'),
        if (companions.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 4, 2, 8),
            child: Text(
              'No companions yet. Scan a friend’s code to connect — '
              'their progress will sync here once your server is live.',
              style: AppText.sora(
                  size: 13.5, height: 1.4, color: AppColors.muted),
            ),
          )
        else
          ...companions.map((c) => _CompanionRow(companion: c)),

        const SizedBox(height: 18),

        // ── Backup ────────────────────────────────────────────────────
        ArcButton(
          label: 'Back up identity',
          icon: 'key',
          variant: BtnVariant.ghost,
          full: true,
          onTap: () => _showRecovery(context, store),
        ),
        const SizedBox(height: 6),
      ],
    );
  }

  static String _shortId(String id) =>
      id.length <= 16 ? id : '${id.substring(0, 8)}…${id.substring(id.length - 6)}';

  Future<void> _copyLink(BuildContext context, ArcStore store) async {
    await Clipboard.setData(ClipboardData(text: store.pairingUri));
    store.toast.value = ArcToast('Link copied', 'check', DateTime.now().millisecondsSinceEpoch);
  }

  Future<void> _scan(BuildContext context, ArcStore store) async {
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

class _CompanionRow extends StatelessWidget {
  final Companion companion;
  const _CompanionRow({required this.companion});

  @override
  Widget build(BuildContext context) {
    final store = context.read<ArcStore>();
    final (statusLabel, statusColor, statusBg) = switch (companion.status) {
      CompanionStatus.accepted => ('SYNCED', AppColors.accentStrong, AppColors.accentSoft),
      CompanionStatus.pending => ('PENDING', AppColors.muted, AppColors.surface2),
      CompanionStatus.blocked => ('BLOCKED', AppColors.danger, AppColors.dangerSoft),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: ArcCard(
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
  bool _handled = false;

  @override
  void dispose() {
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
            bottom: 48,
            left: 32,
            right: 32,
            child: Text(
              'Point at a friend’s Arc QR code',
              textAlign: TextAlign.center,
              style: AppText.sora(size: 14, color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }
}
