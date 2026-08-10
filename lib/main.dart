import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'data/db/app_database.dart';
import 'data/identity/identity_service.dart';
import 'data/store.dart';
import 'data/sync/sync_service.dart';
import 'screens/home_shell.dart';
import 'theme/app_theme.dart';
import 'theme/muscle_palette.dart';
import 'theme/muscle_palette_controller.dart';
import 'theme/theme_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Open the SQLite backend, ensure a device identity exists, then load the
  // store from disk (seeding on first launch).
  final db = await AppDatabase.open();
  final identity = IdentityService();
  await identity.ensure(db);
  final sync = SyncService(db: db, identity: identity);
  final store = ArcStore(db: db, identity: identity, sync: sync);
  await store.init();

  // Restore the saved theme before the first frame so a dark install never
  // flashes light on launch — and the saved group colours with it, so a
  // recoloured library never flashes Arc's defaults either.
  final theme = ThemeController(db);
  final palette = MusclePaletteController(db);
  await theme.load();
  await palette.load();
  SystemChrome.setSystemUIOverlayStyle(ArcTheme.overlayStyle);

  // Sync on launch (background): push anything left dirty from a previous
  // session and pull companions' latest. Failures surface via a toast.
  unawaited(store.autoSync());

  runApp(ArcAppRoot(store: store, theme: theme, palette: palette));
}

class ArcAppRoot extends StatelessWidget {
  const ArcAppRoot({
    super.key,
    required this.store,
    required this.theme,
    required this.palette,
  });

  final ArcStore store;
  final ThemeController theme;
  final MusclePaletteController palette;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: store),
        ChangeNotifierProvider.value(value: theme),
        ChangeNotifierProvider.value(value: palette),
      ],
      child: Consumer2<ThemeController, MusclePaletteController>(
        builder: (context, theme, palette, _) {
          SystemChrome.setSystemUIOverlayStyle(ArcTheme.overlayStyle);
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
            home: HomeShell(
              key: ValueKey(
                  '${theme.isDark}:${theme.accentHue}:${MusclePalette.signature}'),
            ),
          );
        },
      ),
    );
  }
}
