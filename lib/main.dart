import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'data/db/app_database.dart';
import 'data/identity/identity_service.dart';
import 'data/store.dart';
import 'screens/home_shell.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    statusBarBrightness: Brightness.light,
  ));

  // Open the SQLite backend, ensure a device identity exists, then load the
  // store from disk (seeding on first launch).
  final db = await AppDatabase.open();
  final identity = IdentityService();
  await identity.ensure(db);
  final store = ArcStore(db: db, identity: identity);
  await store.init();

  runApp(ArcAppRoot(store: store));
}

class ArcAppRoot extends StatelessWidget {
  const ArcAppRoot({super.key, required this.store});

  final ArcStore store;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: store,
      child: MaterialApp(
        title: 'Arc',
        debugShowCheckedModeBanner: false,
        theme: buildArcTheme(),
        home: const HomeShell(),
      ),
    );
  }
}
