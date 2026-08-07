# Arc

A lightweight Flutter app for **Android** and **Web** that lets tracks you track yours and your friends' gym progress.
Very simple to own and use. Just clone this repo:
```bash
git clone https://github.com/sudhu01/Arc .
``` 
and run the *Go* server (refer to instructions in the server README) on your machine. You would need a reachable public endpoint for your server, I use **[Ngrok](https://ngrok.com/)** for that.

## Features

- **Dashboard** — greeting + date, week stats (workouts / total sets),
  an interactive **strength-progress** chart (Bench / Back / Deadlift), a
  horizontally-scrolling **Personal Records** rail, and recent workouts.
- **Records** — all lifts ranked by estimated 1RM, filterable by muscle group,
  each with a sparkline and a tap-through detail sheet.
- **History** — a month calendar with workout days dotted by muscle group
  (Push / Pull / Legs), today ringed in volt, and monthly workout/set stats.
- **Exercises** — the exercise library (including a set of core exercises
  shipped by default) with per-exercise training counts and bests; add your
  own.
- **Log workout** — a full sheet with a date picker, custom workout naming
  (or an auto-derived title from the exercises logged), per-set weight/rep
  steppers including drop sets, add/remove sets and exercises, search, and
  inline new-exercise creation. Workouts can be duplicated via **copy
  workout**. Saving detects **new PRs** and surfaces a toast.
- **PR detail** — hero 1RM, trend chart, top weight / sessions / total reps, and
  a full progression log.
- **Companions** — pair with other users by QR code or shareable link, then
  see their training in a companion view alongside your own. Pairing is
  mutual-accept; either side can block or remove the relationship.
- **Appearance** — light/dark mode and a hue picker for the accent color,
  with sane contrast-safe bounds derived per hue.
- **Sync** — an identity keypair backed by a recovery phrase, with changes
  pushed/pulled to a companion-sync server so paired devices stay in sync.


## Architecture

```
lib/
  main.dart                    App root + ChangeNotifierProvider
  theme/
    app_theme.dart             Surge palette (OKLCH→sRGB), radii, shadows, Sora type
    accent.dart                Per-hue accent token derivation (contrast-checked)
    oklch.dart                 OKLCH↔sRGB color conversion
    theme_controller.dart      Light/dark + accent hue state, persisted to the DB
  data/
    models.dart                Exercise, WorkoutSet, Entry, Session, records, Companion
    arc_data.dart               Seed data, metrics, date helpers (port of arc-data.js)
    store.dart                  ArcStore (ChangeNotifier) + toast channel
    db/app_database.dart        SQLite schema/access (sqflite) + settings table
    identity/
      identity_service.dart     Ed25519 keypair, recovery phrase (bip39)
      pairing.dart               QR / link pairing flow
    sync/
      sync_api.dart              HTTP client for the sync server
      sync_service.dart          Push/pull changes, cursor management
  widgets/
    arc_icons.dart              Icon-name → Material rounded glyph mapping
    ui.dart                     Card, StatTile, Segmented, ArcStepper, ArcButton, Tag…
    charts.dart                 LineChart, ProgressChart, Spark, Bars (CustomPainter)
    hue_slider.dart             Accent hue picker control
    sheet.dart                  Arc-styled bottom-sheet scaffold
  screens/                     Dashboard, Records, Calendar, Library, HomeShell
  sheets/                      PR detail, Day detail, Log workout, Add exercise,
                                Companion hub + progress, Appearance
assets/fonts/                  Bundled variable fonts (offline; wght axis driven directly)

server/                        Go sync relay (see server/README.md)
```

State is held in a single `ArcStore` (provided above `MaterialApp`, so modal
sheets can read it). Charts are hand-painted; there are no charting
dependencies. Companion sync is opt-in: identity and pairing live locally
until a companion relay (see [`server/`](server/README.md)) is configured.

## Running

```bash
flutter pub get

# Web
flutter run -d chrome

# Android (device/emulator attached)
flutter run -d android

# Builds
flutter build web
flutter build apk (--release OR --split-per-abi)
```

To exercise companion sync, also run the relay in `server/` — see
[`server/README.md`](server/README.md).

## Tooling

- `flutter analyze` — clean.
- `flutter test` — boots the app to the dashboard (smoke test).

## Design source

Built from **Claude Design** and tweaked with the *Impeccable* skill.
