// The Where tile says how the trainer app will find BikeControl. An app that
// only connects over Bluetooth (Biketerra) must not be told it finds
// BikeControl over Wi-Fi.
import 'package:bike_control/pages/onboarding/onboarding_methods.dart';
import 'package:bike_control/utils/host_platform.dart';
import 'package:bike_control/utils/keymap/apps/biketerra.dart';
import 'package:bike_control/utils/keymap/apps/rouvy.dart';
import 'package:bike_control/utils/requirements/multi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../widget_snapshot.dart';

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(ensureSnapshotAppState);
  tearDown(() => debugHostPlatformOverride = null);

  test('a Bluetooth-only app on another device is reached over Bluetooth', () {
    debugHostPlatformOverride = TargetPlatform.android;
    expect(onboardingWhereMethod(Target.otherDevice, Biketerra()), OnboardingMethod.bluetooth);
  });

  test('an app with a network method on another device is reached over the network', () {
    debugHostPlatformOverride = TargetPlatform.android;
    expect(onboardingWhereMethod(Target.otherDevice, Rouvy()), OnboardingMethod.network);
  });

  test('this device uses Local where it exists', () {
    debugHostPlatformOverride = TargetPlatform.android;
    expect(onboardingWhereMethod(Target.thisDevice, Biketerra()), OnboardingMethod.local);
  });
}
