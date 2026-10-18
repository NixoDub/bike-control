import 'dart:typed_data';

import 'package:bike_control/bluetooth/devices/shimano/shimano_di2.dart';
import 'package:bike_control/utils/actions/base_actions.dart';
import 'package:bike_control/utils/core.dart';
import 'package:bike_control/utils/keymap/apps/openbikecontrol.dart';
import 'package:bike_control/utils/keymap/buttons.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prop/prop.dart' hide Set;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_ble/universal_ble.dart';

Future<void> main() async {
  final stubActions = StubActions();
  stubActions.supportedApp = OpenBikeControl();

  SharedPreferences.setMockInitialValues({});
  await core.settings.init();
  core.actionHandler = stubActions;

  group('Shimano Di2 button mode', () {
    const rightLeverDown = ShimanoPaddleEvent(ShimanoShifter.right, ShimanoPaddle.big, ShimanoPaddleState.down);
    const rightLeverHeld = ShimanoPaddleEvent(ShimanoShifter.right, ShimanoPaddle.big, ShimanoPaddleState.held);
    const rightLeverUp = ShimanoPaddleEvent(ShimanoShifter.right, ShimanoPaddle.big, ShimanoPaddleState.released);

    test('a paddle press is one click of its button; held repeats are ignored', () async {
      stubActions.cleanup();
      final instance = ShimanoDi2(BleDevice(name: 'RDR7150', deviceId: 'di2'))..registerPaddleButtons();

      instance.onPaddle(rightLeverDown);
      instance.onPaddle(rightLeverHeld);
      instance.onPaddle(rightLeverHeld);
      instance.onPaddle(rightLeverUp);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(stubActions.performedActions, [
        PerformedAction(ShimanoDi2Buttons.rightLever, isDown: true, isUp: true),
      ]);
    });

    test('the paddle buttons are known buttons, so a saved keymap keeps their labels', () {
      for (final button in ShimanoDi2Buttons.values) {
        final known = ControllerButton.values.firstWhere((b) => b.name == button.name);
        expect(known.label, button.label);
        expect(known.action, button.action);
      }
    });

    test('each paddle maps to its own button', () {
      ControllerButton of(ShimanoShifter s, ShimanoPaddle p) =>
          ShimanoDi2Buttons.of(ShimanoPaddleEvent(s, p, ShimanoPaddleState.down));
      expect(of(ShimanoShifter.left, ShimanoPaddle.big), ShimanoDi2Buttons.leftLever);
      expect(of(ShimanoShifter.left, ShimanoPaddle.small), ShimanoDi2Buttons.leftButton);
      expect(of(ShimanoShifter.right, ShimanoPaddle.big), ShimanoDi2Buttons.rightLever);
      expect(of(ShimanoShifter.right, ShimanoPaddle.small), ShimanoDi2Buttons.rightButton);
    });
  });

  group('Shimano DI2 Tests', () {
    test('Should parse Di2 values correctly', () async {
      stubActions.cleanup();
      final instance = ShimanoDi2(BleDevice(name: 'Di2', deviceId: ''));
      await instance.processCharacteristic(
        ShimanoDi2Constants.D_FLY_CHANNEL_UUID,
        Uint8List.fromList([0x21, 0x13, 0xF0, 0xF0]),
      );

      expect(stubActions.performedActions.isEmpty, true);

      await instance.processCharacteristic(
        ShimanoDi2Constants.D_FLY_CHANNEL_UUID,
        Uint8List.fromList([0x21, 0x13, 0xF0, 0xF0]),
      );
      expect(stubActions.performedActions.isEmpty, true);

      await instance.processCharacteristic(
        ShimanoDi2Constants.D_FLY_CHANNEL_UUID,
        Uint8List.fromList([0x21, 0x14, 0xF0, 0xF0]),
      );
      expect(stubActions.performedActions.isEmpty, false);
    });

    test('should transmit all events', () async {
      stubActions.cleanup();
      final instance = ShimanoDi2(BleDevice(name: 'Di2', deviceId: ''));
      await instance.processCharacteristic(
        ShimanoDi2Constants.D_FLY_CHANNEL_UUID,
        Uint8List.fromList([0x21, 0x13, 0xF0, 0xF0]),
      );

      expect(stubActions.performedActions.isEmpty, true);

      await instance.processCharacteristic(
        ShimanoDi2Constants.D_FLY_CHANNEL_UUID,
        Uint8List.fromList([0x21, 0x13, 0xF0, 0xF0]),
      );
      expect(stubActions.performedActions.isEmpty, true);

      await instance.processCharacteristic(
        ShimanoDi2Constants.D_FLY_CHANNEL_UUID,
        Uint8List.fromList([0x21, 0x14, 0xF0, 0xF0]),
      );
      final button = ControllerButton('D-Fly Channel 1');
      expect(
        stubActions.performedActions,
        equals([
          PerformedAction(button, isDown: true, isUp: true),
        ]),
      );

      await instance.processCharacteristic(
        ShimanoDi2Constants.D_FLY_CHANNEL_UUID,
        Uint8List.fromList([0x21, 0x15, 0xF0, 0xF0]),
      );
      expect(
        stubActions.performedActions,
        equals([
          PerformedAction(button, isDown: true, isUp: true),
          PerformedAction(button, isDown: true, isUp: true),
        ]),
      );
    });
  });
}
