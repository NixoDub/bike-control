import 'package:bike_control/gen/l10n.dart';
import 'package:bike_control/main.dart' show OtherLocalizationsDelegate;
import 'package:bike_control/utils/core.dart';
import 'package:bike_control/widgets/ignored_devices_dialog.dart';
import 'package:bike_control/widgets/ignored_devices_nearby_hint.dart';
import 'package:bike_control/widgets/ui/app_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../widget_snapshot.dart';

Future<void> _pumpHint(WidgetTester tester) async {
  await tester.pumpWidget(
    ShadcnApp(
      localizationsDelegates: [
        ...ShadcnLocalizations.localizationsDelegates,
        const OtherLocalizationsDelegate(),
        AppLocalizations.delegate,
      ],
      supportedLocales: const [Locale('en')],
      theme: BkTheme.build(Brightness.dark),
      home: const Scaffold(child: Center(child: IgnoredDevicesNearbyHint())),
    ),
  );
  await tester.pump();
}

Future<void> main() async {
  await ensureSnapshotHarness();
  late AppLocalizations l;

  setUp(() {
    l = AppLocalizations.current;
    core.connection.ignoredDevicesNearby.value = const {};
  });

  tearDown(() => core.connection.ignoredDevicesNearby.value = const {});

  testWidgets('renders nothing while no ignored device is nearby', (tester) async {
    await _pumpHint(tester);

    expect(find.text(l.ignoredDevicesNearby), findsNothing);
    expect(find.text(l.manageAction), findsNothing);
  });

  testWidgets('appears as soon as the scan sees an ignored device, and goes again', (tester) async {
    await _pumpHint(tester);

    core.connection.ignoredDevicesNearby.value = {'some-click'};
    await tester.pump();
    expect(find.text(l.ignoredDevicesNearby), findsOneWidget);
    expect(find.text(l.manageAction), findsOneWidget);

    core.connection.ignoredDevicesNearby.value = const {};
    await tester.pump();
    expect(find.text(l.ignoredDevicesNearby), findsNothing);
  });

  testWidgets('Manage opens the ignored devices dialog', (tester) async {
    await core.settings.addIgnoredDevice('some-click', 'Zwift Click');
    addTearDown(() => core.settings.removeIgnoredDevice('some-click'));
    core.connection.ignoredDevicesNearby.value = {'some-click'};
    await _pumpHint(tester);

    await tester.tap(find.text(l.manageAction));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(IgnoredDevicesDialog), findsOneWidget);
  });
}
