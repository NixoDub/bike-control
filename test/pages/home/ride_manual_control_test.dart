// Ride → Your buttons without a controller: besides connecting one, the card
// offers to control the trainer app by hand — the button simulator, as the
// trainer page offers it — whenever a trainer app other than BikeControl is
// picked.
import 'package:bike_control/gen/l10n.dart';
import 'package:bike_control/main.dart' show debugKeepsTrainerAppNamesInScreenshotMode;
import 'package:bike_control/pages/button_simulator.dart';
import 'package:bike_control/pages/home/home_page.dart';
import 'package:bike_control/utils/core.dart';
import 'package:bike_control/utils/keymap/apps/bike_control.dart';
import 'package:bike_control/utils/keymap/apps/my_whoosh.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../../widget_snapshot.dart';

Future<void> _pumpRide(WidgetTester tester) async {
  tester.view.physicalSize = const Size(430, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ShadcnApp(
      localizationsDelegates: [
        ...ShadcnLocalizations.localizationsDelegates,
        AppLocalizations.delegate,
      ],
      supportedLocales: const [Locale('en')],
      home: Scaffold(
        child: SingleChildScrollView(
          child: HomePage(isMobile: true, onUpdate: () {}, showHelpRow: false),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> main() async {
  await ensureSnapshotHarness();
  debugKeepsTrainerAppNamesInScreenshotMode = true;
  late AppLocalizations l;

  setUp(() {
    l = AppLocalizations.current;
    core.connection.devices.clear();
  });

  tearDown(() => core.settings.setTrainerApp(MyWhoosh()));

  Finder inCard(Finder finder) =>
      find.descendant(of: find.byKey(const ValueKey('ride-no-controller')), matching: finder);

  testWidgets('with a trainer app: control it manually opens the button simulator', (tester) async {
    core.settings.setTrainerApp(MyWhoosh());
    await _pumpRide(tester);

    final manual = inCard(find.text(l.manualyControllingButton('MyWhoosh')));
    expect(manual, findsOneWidget);
    // Connecting a controller stays the thing to do.
    expect(inCard(find.text(l.connect)), findsOneWidget);

    await tester.ensureVisible(manual);
    await tester.tap(manual);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(ButtonSimulator), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('with BikeControl as the trainer app: nothing to control by hand', (tester) async {
    core.settings.setTrainerApp(BikeControl());
    await _pumpRide(tester);

    expect(find.byKey(const ValueKey('ride-no-controller')), findsWidgets);
    expect(inCard(find.textContaining('BikeControl')), findsNothing);
    expect(find.byKey(const ValueKey('ride-manual-control')), findsNothing);
  });
}
