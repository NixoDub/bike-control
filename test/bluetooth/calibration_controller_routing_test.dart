// While the shifting calibrator runs, a controller's long press and chords
// answer it instead of reaching the trainer app; short presses still shift.
// Once it ends, the controller behaves exactly as before.
import 'package:bike_control/bluetooth/devices/base_device.dart';
import 'package:bike_control/gen/l10n.dart';
import 'package:bike_control/services/vs_calibration/calibration_controller_input.dart';
import 'package:bike_control/services/vs_calibration/vs_calibration_session.dart';
import 'package:bike_control/utils/actions/base_actions.dart';
import 'package:bike_control/utils/core.dart';
import 'package:bike_control/utils/keymap/apps/custom_app.dart';
import 'package:bike_control/utils/keymap/buttons.dart';
import 'package:bike_control/utils/keymap/keymap.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> main() async {
  const plus = ControllerButton('calPlus');
  const minus = ControllerButton('calMinus');

  await AppLocalizations.load(const Locale('en'));

  final devices = <BaseDevice>[];
  late List<CalibrationRating> answers;

  CustomApp twoShifters() {
    final app = CustomApp(profileName: 'Two shifters');
    for (final (button, action) in [(plus, InGameAction.shiftUp), (minus, InGameAction.shiftDown)]) {
      app.keymap.addKeyPair(
        KeyPair(
          buttons: [button],
          physicalKey: null,
          logicalKey: null,
          trigger: ButtonTrigger.singleClick,
          inGameAction: action,
        ),
      );
    }
    return app;
  }

  _Shifters device() {
    final d = _Shifters();
    devices.add(d);
    return d;
  }

  setUp(() {
    answers = [];
    core.actionHandler = StubActions();
    core.actionHandler.init(twoShifters());
    BaseDevice.inputInterceptor = CalibrationControllerInput(
      onAnswer: answers.add,
      currentGear: () => 12,
      restoreGear: (_) {},
    );
  });

  tearDown(() async {
    BaseDevice.inputInterceptor = null;
    for (final d in devices) {
      await d.disconnect();
    }
    devices.clear();
  });

  StubActions stub() => core.actionHandler as StubActions;

  test('a short press still reaches the shift action', () async {
    final d = device();
    await d.handleButtonsClicked([plus]);
    await d.handleButtonsClicked([]);
    expect(stub().performedActions.map((a) => (a.button.name, a.trigger)), [(plus.name, ButtonTrigger.singleClick)]);
    expect(answers, isEmpty);
  });

  test('holding shift down answers too heavy and forwards nothing', () async {
    final d = device();
    await d.handleButtonsClicked([minus]);
    await Future<void>.delayed(const Duration(milliseconds: 650));
    await d.handleButtonsClicked([]);
    expect(answers, [CalibrationRating.tooHeavy]);
    expect(stub().performedActions, isEmpty);
  });

  test('both shifters together answer about right and shift nothing', () async {
    final d = device();
    await d.handleButtonsClicked([plus, minus]);
    await d.handleButtonsClicked([]);
    expect(answers, [CalibrationRating.aboutRight]);
    expect(stub().performedActions, isEmpty);
  });

  test('after the calibrator ends, a hold is an ordinary press again', () async {
    BaseDevice.inputInterceptor = null;
    final d = device();
    await d.handleButtonsClicked([minus]);
    await Future<void>.delayed(const Duration(milliseconds: 650));
    await d.handleButtonsClicked([]);
    expect(answers, isEmpty);
    expect(stub().performedActions.map((a) => (a.button.name, a.trigger)), [(minus.name, ButtonTrigger.singleClick)]);
  });
}

class _Shifters extends BaseDevice {
  _Shifters()
    : super(
        'Shifters',
        uniqueId: 'calibration-shifters',
        availableButtons: const [ControllerButton('calPlus'), ControllerButton('calMinus')],
        icon: Icons.gamepad,
      );

  @override
  Future<void> connect() async {}
}
