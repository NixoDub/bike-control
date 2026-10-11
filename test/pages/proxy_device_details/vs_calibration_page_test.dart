// The virtual shifting calibrator: the rider pedals, the page puts three grades
// on the trainer, and their "too heavy / about right / too light" tunes the
// difficulty of every virtual gear on this trainer.
import 'package:bike_control/bluetooth/devices/base_device.dart';
import 'package:bike_control/bluetooth/devices/gamepad/gamepad_device.dart';
import 'package:bike_control/bluetooth/devices/proxy/proxy_device.dart';
import 'package:bike_control/gen/l10n.dart';
import 'package:bike_control/main.dart' show OtherLocalizationsDelegate, installLoggerErrorListener, navigatorKey;
import 'package:bike_control/pages/proxy_device_details/vs_calibration_page.dart';
import 'package:bike_control/services/vs_calibration/calibration_controller_input.dart';
import 'package:bike_control/services/vs_calibration/vs_calibration_session.dart';
import 'package:bike_control/utils/actions/base_actions.dart';
import 'package:bike_control/utils/core.dart';
import 'package:bike_control/utils/keymap/buttons.dart';
import 'package:bike_control/utils/keymap/keymap.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:prop/emulators/definitions/fitness_bike_definition.dart';
import 'package:prop/transports/trainer_transport.dart';
import 'package:prop/utils/constants.dart';
import 'package:prop/utils/shared.dart' show Logger;
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:universal_ble/universal_ble.dart';

class _SilentTransport implements TrainerTransport {
  @override
  String get id => 'silent';
  @override
  void Function()? onDisconnected;
  @override
  Future<void> connect() async {}
  @override
  Future<List<BleService>> discoverServices() async => const [];
  @override
  Future<Uint8List> read(String service, String characteristic) async => Uint8List(0);
  @override
  Future<void> write(String s, String c, Uint8List b, {bool withoutResponse = false}) async {}
  @override
  Future<void> subscribe(String s, String c, {required bool indicate}) async {}
  @override
  Stream<({String characteristic, Uint8List value})> get notifications => const Stream.empty();
  @override
  Future<void> disconnect() async {}
}

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

  setUpAll(() async {
    await initializeDateFormatting();
    installLoggerErrorListener();
    Logger.onRecordError = (message, error, _) => debugPrint('recordError($message): $error');
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://127.0.0.1:9',
      anonKey: 'vs-calibration-page-anon-key',
      debug: false,
      authOptions: const FlutterAuthClientOptions(
        localStorage: EmptyLocalStorage(),
        detectSessionInUri: false,
        autoRefreshToken: false,
      ),
    );
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    core.settings.prefs = await SharedPreferences.getInstance();
    await core.shiftingConfigs.init();
    core.actionHandler = StubActions();
    _mockWakelock(true);
  });

  tearDown(() => _mockWakelock(false));

  var trainerCount = 0;

  /// A connected FTMS trainer with no trainer app attached. A fresh name per
  /// call: core.shiftingConfigs outlives the prefs reset between tests.
  ProxyDevice trainer({bool zwiftHub = false}) {
    final services = [
      BleService(FitnessBikeDefinition.FITNESS_MACHINE_SERVICE_UUID, [
        BleCharacteristic(FitnessBikeDefinition.FITNESS_MACHINE_CONTROL_POINT_UUID, [
          CharacteristicProperty.write,
          CharacteristicProperty.indicate,
        ], []),
      ]),
      if (zwiftHub)
        BleService(FtmsMdnsConstants.ZWIFT_PLAY_SERVICE_UUID, [
          BleCharacteristic(FtmsMdnsConstants.ZWIFT_SYNC_RX_CHARACTERISTIC_UUID, [CharacteristicProperty.write], []),
        ]),
    ];
    final name = 'KICKR CORE ${trainerCount++}';
    final device = ProxyDevice(
      BleDevice(deviceId: name, name: name, services: services.map((s) => s.uuid).toList()),
    )..services = services;
    final def = FitnessBikeDefinition(
      connectedDevice: device.scanResult,
      connectedDeviceServices: services,
      data: ValueNotifier(''),
      transport: _SilentTransport(),
    );
    device.debugAttachFitnessBike(def);
    device.isConnected = true;
    return device;
  }

  Future<void> pumpPage(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ShadcnApp(
        debugShowCheckedModeBanner: false,
        navigatorKey: navigatorKey,
        localizationsDelegates: [
          ...ShadcnLocalizations.localizationsDelegates,
          const OtherLocalizationsDelegate(),
          AppLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.delegate.supportedLocales,
        home: home,
      ),
    );
    await tester.pump();
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(ValueKey(key)));
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pump();
  }

  Future<void> tearDownPage(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  }

  testWidgets('a full run tunes, applies and stores the difficulty', (tester) async {
    final device = trainer();
    final def = device.fitnessBike!;
    await pumpPage(tester, VsCalibrationPage(device: device));

    await tapKey(tester, 'vs-cal-start');
    expect(def.trainerMode.value, TrainerMode.simModeVirtualShifting);
    expect(def.simGrade.value, 0, reason: 'the flat comes first');

    await tapKey(tester, 'vs-cal-too-heavy');
    expect(def.difficultyPct.value, 80, reason: 'the change is on the trainer right away');

    await tapKey(tester, 'vs-cal-about-right');
    expect(def.simGrade.value, 300);
    await tapKey(tester, 'vs-cal-about-right');
    expect(def.simGrade.value, 600);
    await tapKey(tester, 'vs-cal-about-right');

    expect(find.byKey(const ValueKey('vs-cal-result')), findsOneWidget);
    expect(core.shiftingConfigs.activeFor(device.trainerKey).difficultyPct, 80);

    await tapKey(tester, 'stepper-plus');
    expect(def.difficultyPct.value, 85);
    expect(core.shiftingConfigs.activeFor(device.trainerKey).difficultyPct, 85);

    await tapKey(tester, 'vs-cal-reset');
    expect(def.difficultyPct.value, 100);
    expect(core.shiftingConfigs.activeFor(device.trainerKey).difficultyPct, 100);

    await tearDownPage(tester);
  });

  testWidgets('stopping mid-run puts the old difficulty back and stores nothing', (tester) async {
    final device = trainer();
    final def = device.fitnessBike!;
    await pumpPage(tester, VsCalibrationPage(device: device));

    await tapKey(tester, 'vs-cal-start');
    await tapKey(tester, 'vs-cal-too-heavy');
    expect(def.difficultyPct.value, 80);

    await tapKey(tester, 'vs-cal-stop');
    expect(def.difficultyPct.value, 100);
    expect(core.shiftingConfigs.storedActiveFor(device.trainerKey), isNull);
    expect(find.byKey(const ValueKey('vs-cal-start')), findsOneWidget);

    await tearDownPage(tester);
  });

  testWidgets('leaving the page mid-run puts the old difficulty back', (tester) async {
    final device = trainer();
    final def = device.fitnessBike!;
    await pumpPage(tester, VsCalibrationPage(device: device));
    await tapKey(tester, 'vs-cal-start');
    await tapKey(tester, 'vs-cal-too-light');
    expect(def.difficultyPct.value, 120);

    await tearDownPage(tester);
    expect(def.difficultyPct.value, 100);
  });

  testWidgets('will not start while a trainer app holds the trainer', (tester) async {
    final device = trainer()..debugSetTrainerAppConnected(true);
    final def = device.fitnessBike!;
    await pumpPage(tester, VsCalibrationPage(device: device));

    await tapKey(tester, 'vs-cal-start');
    expect(find.byKey(const ValueKey('vs-cal-refusal')), findsOneWidget);
    expect(find.byKey(const ValueKey('vs-cal-too-heavy')), findsNothing);
    expect(def.trainerMode.value, isNot(TrainerMode.simModeVirtualShifting));

    await tearDownPage(tester);
  });

  testWidgets('a trainer app connecting mid-run ends the run', (tester) async {
    final device = trainer();
    final def = device.fitnessBike!;
    await pumpPage(tester, VsCalibrationPage(device: device));
    await tapKey(tester, 'vs-cal-start');
    await tapKey(tester, 'vs-cal-too-heavy');

    device.debugSetTrainerAppConnected(true);
    await tester.pump();
    expect(find.byKey(const ValueKey('vs-cal-refusal')), findsOneWidget);
    expect(def.difficultyPct.value, 100);

    await tearDownPage(tester);
  });

  group('every way a run ends hands the trainer back as it was', () {
    // An ERG target set before the run: the run must not leave the trainer in
    // virtual shifting, however it ends.
    Future<(ProxyDevice, FitnessBikeDefinition)> ergRun(WidgetTester tester) async {
      final device = trainer();
      final def = device.fitnessBike!..setManualErgPower(180);
      await pumpPage(tester, VsCalibrationPage(device: device));
      await tapKey(tester, 'vs-cal-start');
      await tapKey(tester, 'vs-cal-too-heavy');
      expect(def.trainerMode.value, TrainerMode.simModeVirtualShifting);
      return (device, def);
    }

    void expectErgBack(FitnessBikeDefinition def) {
      expect(def.trainerMode.value, TrainerMode.ergMode);
      expect(def.ergTargetPower.value, 180);
    }

    testWidgets('finishing', (tester) async {
      final (_, def) = await ergRun(tester);
      for (var i = 0; i < 3; i++) {
        await tapKey(tester, 'vs-cal-about-right');
      }
      expect(find.byKey(const ValueKey('vs-cal-result')), findsOneWidget);
      expectErgBack(def);
      expect(def.difficultyPct.value, 80, reason: 'the result itself is kept');
      await tearDownPage(tester);
    });

    testWidgets('stopping', (tester) async {
      final (_, def) = await ergRun(tester);
      await tapKey(tester, 'vs-cal-stop');
      expectErgBack(def);
      await tearDownPage(tester);
    });

    testWidgets('leaving the page', (tester) async {
      final (_, def) = await ergRun(tester);
      await tearDownPage(tester);
      expectErgBack(def);
    });

    testWidgets('a trainer app connecting', (tester) async {
      final (device, def) = await ergRun(tester);
      device.debugSetTrainerAppConnected(true);
      await tester.pump();
      expectErgBack(def);
      await tearDownPage(tester);
    });

    testWidgets('virtual shifting keeps the grade it had', (tester) async {
      final device = trainer();
      final def = device.fitnessBike!
        ..setVirtualShiftingMode(VirtualShiftingMode.trackResistance)
        ..setCalibrationGrade(250);
      await pumpPage(tester, VsCalibrationPage(device: device));
      await tapKey(tester, 'vs-cal-start');
      for (var i = 0; i < 3; i++) {
        await tapKey(tester, 'vs-cal-about-right');
      }
      expect(def.trainerMode.value, TrainerMode.simModeVirtualShifting);
      expect(def.virtualShiftingMode.value, VirtualShiftingMode.trackResistance);
      expect(def.simGrade.value, 250);
      await tearDownPage(tester);
    });
  });

  group('the rider\'s controller', () {
    const minus = ControllerButton('calMinus');

    Future<FitnessBikeDefinition> started(WidgetTester tester, ProxyDevice device) async {
      await pumpPage(tester, VsCalibrationPage(device: device));
      await tapKey(tester, 'vs-cal-start');
      return device.fitnessBike!;
    }

    testWidgets('answers while a run is on, with feedback for screen readers', (tester) async {
      final device = trainer();
      final def = await started(tester, device);
      final input = BaseDevice.inputInterceptor;
      expect(input, isNotNull);

      input!.intercept(minus, InGameAction.shiftDown, ButtonTrigger.longPress, isKeyDown: true);
      await tester.pump();
      expect(def.difficultyPct.value, 80);
      expect(
        tester.takeAnnouncements().map((a) => a.message),
        contains(AppLocalizations.current.vsCalibrateControllerAnswered(AppLocalizations.current.vsCalibrateTooHeavy)),
      );
      expect(find.byKey(const ValueKey('vs-cal-controller-flash')), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('vs-cal-controller-flash')), findsNothing);

      await tearDownPage(tester);
    });

    testWidgets('both shifters walk through to the result', (tester) async {
      final device = trainer();
      await started(tester, device);
      for (var i = 0; i < VsCalibrationSession.grades001Pct.length; i++) {
        // The answer debounce runs on the wall clock: let it pass for real.
        if (i > 0) await tester.runAsync(() => Future<void>.delayed(CalibrationControllerInput.answerDebounce));
        BaseDevice.inputInterceptor!.interceptChord(
          const [ControllerButton('calPlus'), minus],
          const [InGameAction.shiftUp, InGameAction.shiftDown],
        );
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.byKey(const ValueKey('vs-cal-result')), findsOneWidget);
      expect(BaseDevice.inputInterceptor, isNull, reason: 'finishing hands the controller back');
      await tearDownPage(tester);
    });

    testWidgets('stopping hands the controller back', (tester) async {
      await started(tester, trainer());
      await tapKey(tester, 'vs-cal-stop');
      expect(BaseDevice.inputInterceptor, isNull);
      await tearDownPage(tester);
    });

    testWidgets('leaving the page hands the controller back', (tester) async {
      await started(tester, trainer());
      await tearDownPage(tester);
      expect(BaseDevice.inputInterceptor, isNull);
    });

    testWidgets('a trainer app connecting hands the controller back', (tester) async {
      final device = trainer();
      await started(tester, device);
      device.debugSetTrainerAppConnected(true);
      await tester.pump();
      expect(BaseDevice.inputInterceptor, isNull);
      await tearDownPage(tester);
    });

    testWidgets('the controller scheme is shown next to the answers when a controller is connected', (tester) async {
      final controller = GamepadDevice('Pad', id: 'calibration-pad')..isConnected = true;
      core.connection.devices.add(controller);
      addTearDown(() => core.connection.devices.remove(controller));
      await started(tester, trainer());
      expect(find.byKey(const ValueKey('vs-cal-controller-hints')), findsOneWidget);
      await tearDownPage(tester);
    });

    testWidgets('and left out without one', (tester) async {
      await started(tester, trainer());
      expect(find.byKey(const ValueKey('vs-cal-controller-hints')), findsNothing);
      await tearDownPage(tester);
    });
  });

  testWidgets('the on-screen shift buttons move the gear, for mouse and keyboard riders', (tester) async {
    final device = trainer();
    final def = device.fitnessBike!;
    await pumpPage(tester, VsCalibrationPage(device: device));
    await tapKey(tester, 'vs-cal-start');

    final before = def.currentGear.value;
    await tapKey(tester, 'vs-cal-shift-up');
    expect(def.currentGear.value, before + 1);
    await tapKey(tester, 'vs-cal-shift-down');
    await tapKey(tester, 'vs-cal-shift-down');
    expect(def.currentGear.value, before - 1);

    await tearDownPage(tester);
  });

  testWidgets('the rating buttons can be reached and pressed from the keyboard', (tester) async {
    final device = trainer();
    final def = device.fitnessBike!;
    await pumpPage(tester, VsCalibrationPage(device: device));
    await tapKey(tester, 'vs-cal-start');

    // Tab until "Too heavy" has focus, then press it with Enter.
    for (var i = 0; i < 20; i++) {
      final focused = FocusManager.instance.primaryFocus?.context;
      final onTooHeavy = focused != null &&
          find
              .ancestor(of: find.byWidget(focused.widget), matching: find.byKey(const ValueKey('vs-cal-too-heavy')))
              .evaluate()
              .isNotEmpty;
      if (onTooHeavy) break;
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(def.difficultyPct.value, 80);

    await tearDownPage(tester);
  });

  testWidgets('a trainer that shifts in its own firmware is not offered a calibration', (tester) async {
    final device = trainer(zwiftHub: true);
    expect(device.fitnessBike!.controlProtocol, TrainerControlProtocol.zwiftHub);
    await pumpPage(tester, VsCalibrationPage(device: device));

    expect(find.byKey(const ValueKey('vs-cal-firmware')), findsOneWidget);
    expect(find.byKey(const ValueKey('vs-cal-start')), findsNothing);

    await tearDownPage(tester);
  });
}

