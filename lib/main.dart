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
  // flashes light on launch.
  final theme = ThemeController(db);
  await theme.load();
  SystemChrome.setSystemUIOverlayStyle(ArcTheme.overlayStyle);

  // Sync on launch (background): push anything left dirty from a previous
  // session and pull companions' latest. Failures surface via a toast.
  unawaited(store.autoSync());

  runApp(ArcAppRoot(store: store, theme: theme));
}

class ArcAppRoot extends StatelessWidget {
  const ArcAppRoot({super.key, required this.store, required this.theme});

  final ArcStore store;
  final ThemeController theme;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: store),
        ChangeNotifierProvider.value(value: theme),
      ],
      child: Consumer<ThemeController>(
        builder: (context, theme, _) {
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
            home: HomeShell(key: ValueKey(theme.isDark)),
          );
        },
      ),
    );
  }
}
