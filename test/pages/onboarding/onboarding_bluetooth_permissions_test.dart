// Turning on Bluetooth in the onboarding connection step must ask for the
// Bluetooth permissions first, like the tile in Trainer Connections does. On
// Android advertising needs its own permission; without it BikeControl reads as
// on but never shows up in the trainer app.
import 'package:bike_control/gen/l10n.dart';
import 'package:bike_control/main.dart' show OtherLocalizationsDelegate;
import 'package:bike_control/pages/onboarding/onboarding_methods.dart';
import 'package:bike_control/utils/core.dart';
import 'package:bike_control/utils/keymap/apps/biketerra.dart';
import 'package:bike_control/utils/requirements/platform.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../../widget_snapshot.dart';

class _FakeAdvertise extends PlatformRequirement {
  _FakeAdvertise() : super('Fake advertise permission', icon: LucideIcons.bluetooth);
  bool granted = false;

  @override
  Future<bool> getStatus() async => status = granted;

  @override
  Future<void> call(BuildContext context, VoidCallback onUpdate) async {}
}

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(ensureSnapshotAppState);

  testWidgets('a missing Bluetooth permission is asked for, and declining leaves the method off', (tester) async {
    core.settings.setObpBleEnabled(false);
    final requirement = _FakeAdvertise();
    late BuildContext ctx;
    await tester.pumpWidget(
      ShadcnApp(
        localizationsDelegates: [
          ...ShadcnLocalizations.localizationsDelegates,
          const OtherLocalizationsDelegate(),
          AppLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.delegate.supportedLocales,
        home: Scaffold(child: Builder(builder: (c) => SizedBox.expand(child: Builder(builder: (c2) {
          ctx = c2;
          return const SizedBox();
        })))),
      ),
    );

    var done = false;
    setOnboardingMethodEnabled(ctx, OnboardingMethod.bluetooth, Biketerra(), true,
            onUpdate: () {}, bluetoothRequirements: [requirement])
        .then((_) => done = true);
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('Fake advertise permission'), findsWidgets, reason: 'the permission sheet is shown');

    closeSheet(tester.element(find.text('Fake advertise permission').first));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    expect(done, isTrue);
    expect(core.settings.getObpBleEnabled(), isFalse, reason: 'not granted — must not read as on');
    expect(core.obpBluetoothEmulator.isStarted.value, isFalse);
  });
}
