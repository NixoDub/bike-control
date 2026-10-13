// A controller that still needs its setup — a Zwift Click V2 waiting for its
// unlock-mode choice, a locked one, a SRAM AXS before its guided setup — is on
// Ride with a warning that leads into that setup, and a one-time setup opens by
// itself when such a controller turns up after the onboarding.
//
// Read off [BaseDevice.setupNeed], never the device class: the same card and
// the same prompt for every kind of controller.
import 'package:bike_control/bluetooth/devices/base_device.dart';
import 'package:bike_control/bluetooth/devices/sram/sram_axs.dart';
import 'package:bike_control/bluetooth/devices/sram/sram_setup_sheet.dart' show SramGuidedSheet;
import 'package:bike_control/bluetooth/devices/zwift/constants.dart';
import 'package:bike_control/bluetooth/devices/zwift/zwift_clickv2.dart';
import 'package:bike_control/bluetooth/devices/zwift/zwift_play.dart';
import 'package:bike_control/gen/l10n.dart';
import 'package:bike_control/main.dart' show OtherLocalizationsDelegate, screenshotMode;
import 'package:bike_control/pages/click_v2_onboarding.dart';
import 'package:bike_control/pages/home/home_page.dart';
import 'package:bike_control/utils/core.dart';
import 'package:bike_control/utils/device_setup_prompt.dart';
import 'package:bike_control/utils/keymap/apps/my_whoosh.dart';
import 'package:bike_control/widgets/home/your_buttons.dart' show ControllerButtonsCard;
import 'package:bike_control/widgets/ui/app_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prop/prop.dart' show propPrefs;
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:universal_ble/universal_ble.dart';

import '../../widget_snapshot.dart';

ZwiftPlay _connectedPlay() {
  final play = ZwiftPlay(BleDevice(name: 'Zwift Play', deviceId: 'setup-play'), deviceType: ZwiftDeviceType.playLeft)
    ..isConnected = true;
  core.connection.devices.add(play);
  return play;
}

/// A Click V2 the scanner found and the app holds back for its unlock-mode
/// choice: listed, never connected.
ZwiftClickV2 _heldBackClick() => ZwiftClickV2(BleDevice(name: 'Zwift Click', deviceId: 'setup-click'));

SramAxs _connectedSram() => SramAxs(BleDevice(deviceId: 'setup-sram', name: 'SRAM Rival AXS'))..isConnected = true;

Finder _warning(BaseDevice device) => find.byKey(ValueKey('ride-setup-warning-${device.uniqueId}'));

Finder get _anyWarning => find.byWidgetPredicate(
  (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('ride-setup-warning-'),
);

Future<void> _pumpRide(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ShadcnApp(
      localizationsDelegates: [
        ...ShadcnLocalizations.localizationsDelegates,
        const OtherLocalizationsDelegate(),
        AppLocalizations.delegate,
      ],
      supportedLocales: const [Locale('en')],
      theme: BkTheme.build(Brightness.dark),
      home: Scaffold(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: HomePage(isMobile: true, onUpdate: () {}),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

/// Not pumpAndSettle: the Click V2 explainer's contours loop for as long as
/// it is on screen.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

Future<void> main() async {
  await ensureSnapshotHarness();

  setUp(() async {
    screenshotMode = false;
    propPrefs.initialize(core.settings.prefs);
    await core.settings.setClickV2OnboardingDone(false);
    await core.settings.setUnlockWithZwift(false);
    await core.settings.setSramShiftingDisabled('setup-sram', false);
    core.appConnectionLatch.reset();
    core.settings.setTrainerApp(MyWhoosh());
    core.settings.setKeyMap(MyWhoosh());
    core.actionHandler.init(MyWhoosh());
    DeviceSetupPrompt.debugReset();
  });

  tearDown(() {
    core.connection.devices.clear();
    DeviceSetupPrompt.debugReset();
  });

  group('Ride shows a controller that needs its setup', () {
    testWidgets('a Click V2 found after the onboarding, held back for its setup, is on Ride with a warning', (
      tester,
    ) async {
      _connectedPlay();
      final click = _heldBackClick();
      core.connection.devices.add(click);
      // Offered already: this test is about the card, not the prompt.
      DeviceSetupPrompt.markOffered(click);
      await _pumpRide(tester);

      expect(find.byKey(ValueKey('ride-buttons-${click.uniqueId}')), findsOneWidget);
      expect(_warning(click), findsOneWidget);
      // Offered once already (here, or by the onboarding): not again.
      expect(find.byType(ClickV2OnboardingPage), findsNothing);

      await tester.ensureVisible(_warning(click));
      await tester.tap(_warning(click));
      await _settle(tester);
      expect(find.byType(ClickV2OnboardingPage), findsOneWidget);
    });

    testWidgets('a Click V2 connected but locked by Zwift carries the warning', (tester) async {
      await core.settings.setClickV2OnboardingDone(true);
      await core.settings.setUnlockWithZwift(true);
      final click = _heldBackClick()..isConnected = true;
      core.connection.devices.add(click);
      await _pumpRide(tester);

      expect(find.byType(ControllerButtonsCard), findsOneWidget);
      expect(_warning(click), findsOneWidget);
    });

    testWidgets('a SRAM AXS before its guided setup carries the warning', (tester) async {
      final sram = _connectedSram();
      core.connection.devices.add(sram);
      DeviceSetupPrompt.markOffered(sram);
      await _pumpRide(tester);

      expect(find.byKey(ValueKey('ride-buttons-${sram.uniqueId}')), findsOneWidget);
      expect(_warning(sram), findsOneWidget);
    });

    testWidgets('a controller with nothing left to set up has no warning', (tester) async {
      _connectedPlay();
      final sram = _connectedSram();
      await core.settings.setSramShiftingDisabled('setup-sram', true);
      core.connection.devices.add(sram);
      await _pumpRide(tester);

      expect(find.byType(ControllerButtonsCard), findsNWidgets(2));
      expect(_anyWarning, findsNothing);
    });
  });

  group('the one-time setup opens by itself', () {
    testWidgets('when a Click V2 turns up after the onboarding — and only once', (tester) async {
      _connectedPlay();
      await _pumpRide(tester);
      expect(find.byType(ClickV2OnboardingPage), findsNothing);

      // Discovered by the scan: added and queued, but held back from
      // connecting — that has to reach Ride all the same.
      final click = _heldBackClick();
      core.connection.addDevices([click]);
      await _settle(tester);
      expect(find.byType(ClickV2OnboardingPage), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('click-onboarding-close')));
      await _settle(tester);
      expect(find.byType(ClickV2OnboardingPage), findsNothing);

      // Closed: not again, whatever happens next.
      core.connection.signalChange(click);
      await _settle(tester);
      expect(find.byType(ClickV2OnboardingPage), findsNothing);
      // The way back in stays on Ride.
      expect(_warning(click), findsOneWidget);
    });

    testWidgets('when a SRAM AXS that needs its guided setup connects', (tester) async {
      _connectedPlay();
      await _pumpRide(tester);

      final sram = _connectedSram();
      core.connection.devices.add(sram);
      core.connection.signalChange(sram);
      await _settle(tester);
      expect(find.byType(SramGuidedSheet), findsOneWidget);
    });

    testWidgets('not for a recurring unlock', (tester) async {
      await core.settings.setClickV2OnboardingDone(true);
      await core.settings.setUnlockWithZwift(true);
      await _pumpRide(tester);

      final click = _heldBackClick()..isConnected = true;
      core.connection.devices.add(click);
      core.connection.signalChange(click);
      await _settle(tester);
      expect(find.byType(ClickV2OnboardingPage), findsNothing);
      expect(_warning(click), findsOneWidget);
    });

    testWidgets('not while another screen (the onboarding) is on top of Ride', (tester) async {
      _connectedPlay();
      await _pumpRide(tester);
      final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
      unawaitedPush(navigator);
      await _settle(tester);

      final click = _heldBackClick();
      core.connection.devices.add(click);
      core.connection.signalChange(click);
      await _settle(tester);
      expect(find.byType(ClickV2OnboardingPage), findsNothing);
      expect(DeviceSetupPrompt.wasOffered(click), isFalse);
    });
  });
}

/// Stands in for the onboarding: a full-screen route over Ride.
void unawaitedPush(NavigatorState navigator) {
  navigator.push(PageRouteBuilder<void>(pageBuilder: (_, _, _) => const Scaffold(child: Text('onboarding'))));
}
