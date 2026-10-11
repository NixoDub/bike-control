// The resistance self-test on its own page, opened from the "Check and
// calibrate" row in the virtual shifting settings, the support intake and the
// setup guide. The page hosts the self-test flow itself; the card's own frame
// and title give way to the page's.
import 'dart:async';

import 'package:bike_control/bluetooth/devices/proxy/proxy_device.dart';
import 'package:bike_control/gen/l10n.dart';
import 'package:bike_control/pages/proxy_device_details/self_test_card.dart';
import 'package:bike_control/pages/proxy_device_details/self_test_page.dart';
import 'package:bike_control/services/trainer_self_test/self_test_engine.dart';
import 'package:bike_control/services/trainer_self_test/self_test_result.dart';
import 'package:bike_control/utils/actions/base_actions.dart';
import 'package:bike_control/utils/core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_ble/universal_ble.dart';

import '../../services/trainer_self_test/fake_self_test_harness.dart';

const _wakelockChannels = [
  'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
  'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.isEnabled',
];

void _mockWakelock(bool install) {
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final channel in _wakelockChannels) {
    messenger.setMockMessageHandler(
      channel,
      install ? (_) async => const StandardMessageCodec().encodeMessage(<Object?>[null]) : null,
    );
  }
}

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  await AppLocalizations.load(const Locale('en'));
  final l = AppLocalizations.current;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    core.settings.prefs = await SharedPreferences.getInstance();
    await core.shiftingConfigs.init();
    core.actionHandler = StubActions();
    _mockWakelock(true);
  });

  tearDown(() => _mockWakelock(false));

  var count = 0;
  ProxyDevice trainer() {
    final name = 'KICKR CORE page ${count++}';
    return ProxyDevice(BleDevice(deviceId: name, name: name))..isConnected = true;
  }

  /// A trainer that never answers: the run ends on "No data", which is enough
  /// to see the whole flow (start, running, verdict, stored result) on the page.
  SelfTestEngine silentEngine() => SelfTestEngine(
    harness: FakeSelfTestHarness(),
    sleep: (_) => Future<void>.delayed(Duration.zero),
    now: () => DateTime(2026, 10, 11),
  );

  Future<void> pumpPage(WidgetTester tester, ProxyDevice device) async {
    await tester.pumpWidget(
      ShadcnApp(
        localizationsDelegates: const [AppLocalizations.delegate],
        supportedLocales: AppLocalizations.delegate.supportedLocales,
        home: SelfTestPage(device: device, engineFactory: silentEngine),
      ),
    );
    await tester.pump();
  }

  testWidgets('hosts the self-test under the page title, without the card frame', (tester) async {
    await pumpPage(tester, trainer());

    expect(find.byType(SelfTestCard), findsOneWidget);
    expect(find.text(l.selfTestTitle), findsOneWidget, reason: 'the page title, not a second card title');
    expect(find.text(l.selfTestStart), findsOneWidget);
    final card = tester.widget<SelfTestCard>(find.byType(SelfTestCard));
    expect(card.framed, isFalse);
    expect(card.onShowOverlaySettings, isNotNull, reason: 'the overlay CTA still has somewhere to go');
  });

  testWidgets('runs the whole flow and stores the verdict for the settings row', (tester) async {
    final device = trainer();
    await pumpPage(tester, device);

    await tester.tap(find.text(l.selfTestStart));
    await tester.pumpAndSettle();

    expect(find.text(l.selfTestVerdictNoDataTitle), findsOneWidget);
    final stored = SelfTestResult.tryParse(core.settings.getSelfTestResultJson(device.trainerKey));
    expect(stored?.verdict, SelfTestVerdict.noData);
  });

  testWidgets('a rebuild of the page keeps the run going', (tester) async {
    final device = trainer();
    final state = <String>[];
    await tester.pumpWidget(
      ShadcnApp(
        localizationsDelegates: const [AppLocalizations.delegate],
        supportedLocales: AppLocalizations.delegate.supportedLocales,
        home: StatefulBuilder(
          builder: (context, setState) {
            state.add('built');
            return SelfTestPage(
              key: const ValueKey('page'),
              device: device,
              // Never finishes on its own: each tick waits for the next pump.
              engineFactory: () => SelfTestEngine(
                harness: FakeSelfTestHarness(),
                sleep: (_) => Completer<void>().future,
                now: () => DateTime(2026, 10, 11),
              ),
            );
          },
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text(l.selfTestStart));
    await tester.pump();
    expect(find.text(l.selfTestCancel), findsOneWidget, reason: 'the run is on');

    // Something above the page rebuilds it.
    (tester.element(find.byType(StatefulBuilder)) as StatefulElement).markNeedsBuild();
    await tester.pump();
    expect(state.length, greaterThan(1));
    expect(find.text(l.selfTestCancel), findsOneWidget, reason: 'still the same run, not back to the start');
  });
}
