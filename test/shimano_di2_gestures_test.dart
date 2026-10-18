import 'package:bike_control/bluetooth/devices/shimano/shimano_di2.dart';
import 'package:bike_control/bluetooth/messages/notification.dart';
import 'package:bike_control/gen/l10n.dart';
import 'package:bike_control/utils/actions/base_actions.dart';
import 'package:bike_control/utils/core.dart';
import 'package:bike_control/utils/keymap/apps/custom_app.dart';
import 'package:bike_control/utils/keymap/buttons.dart';
import 'package:bike_control/utils/keymap/keymap.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prop/prop.dart' hide Set;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_ble/universal_ble.dart';

/// Gestures on a Di2 paddle in button mode, fed exactly as the shifter reports
/// them: down, a `held` repeat every ~100 ms while pressed, released.
Future<void> main() async {
  await AppLocalizations.load(const Locale('en'));
  SharedPreferences.setMockInitialValues({});
  await core.settings.init();

  const deviceId = 'di2';
  final lever = ShimanoDi2Buttons.leftLever.copyWith(sourceDeviceId: deviceId);

  ShimanoPaddleEvent ev(ShimanoPaddleState s) => ShimanoPaddleEvent(ShimanoShifter.left, ShimanoPaddle.big, s);

  late StubActions stub;
  late ShimanoDi2 di2;

  setUp(() {
    stub = StubActions();
    core.actionHandler = stub;
    final app = CustomApp(profileName: 'Di2');
    for (final (trigger, action) in [
      (ButtonTrigger.singleClick, InGameAction.shiftDown),
      (ButtonTrigger.doubleClick, InGameAction.steerLeft),
      (ButtonTrigger.longPress, InGameAction.shiftUp),
    ]) {
      app.keymap.addKeyPair(
        KeyPair(buttons: [lever], physicalKey: null, logicalKey: null, trigger: trigger, inGameAction: action),
      );
    }
    core.actionHandler.init(app);
    di2 = ShimanoDi2(BleDevice(name: 'RDR7150', deviceId: deviceId))..registerPaddleButtons();
  });

  tearDown(() => di2.disconnect());

  Future<void> press({required Duration hold}) async {
    di2.onPaddle(ev(ShimanoPaddleState.down));
    final end = DateTime.now().add(hold);
    while (DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      di2.onPaddle(ev(ShimanoPaddleState.held));
    }
    di2.onPaddle(ev(ShimanoPaddleState.released));
  }

  List<ButtonTrigger?> triggers() => stub.performedActions.map((a) => a.trigger).toList();

  test('a long hold runs the long-press action', () async {
    await press(hold: const Duration(milliseconds: 1500));
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(triggers(), contains(ButtonTrigger.longPress));
    expect(triggers(), isNot(contains(ButtonTrigger.singleClick)));
  });

  test('two quick presses run the double-click action', () async {
    await press(hold: const Duration(milliseconds: 80));
    await Future<void>.delayed(const Duration(milliseconds: 80));
    await press(hold: const Duration(milliseconds: 80));
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(triggers(), contains(ButtonTrigger.doubleClick));
  });

  test('one short press runs the single-click action', () async {
    await press(hold: const Duration(milliseconds: 80));
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(triggers(), [ButtonTrigger.singleClick]);
  });

  test('announces the gesture that actually ran, so the UI can show its action', () async {
    final gestures = <ButtonTrigger>[];
    final sub = di2.actionStream.listen((n) {
      if (n is GestureNotification) gestures.add(n.trigger);
    });
    await press(hold: const Duration(milliseconds: 1500));
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await sub.cancel();
    expect(gestures, [ButtonTrigger.longPress]);
  });
}
