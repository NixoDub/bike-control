import 'dart:typed_data';

import 'package:bike_control/bluetooth/devices/stages/stages_smart_bike.dart';
import 'package:bike_control/utils/actions/base_actions.dart';
import 'package:bike_control/utils/core.dart';
import 'package:bike_control/utils/keymap/buttons.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

/// Records what the decoder hands to the shared press/release handling,
/// instead of running it.
class _RecordingBike extends StagesSmartBike {
  _RecordingBike() : super(BleDevice(deviceId: 'sb20', name: 'Stages Bike 0017'));

  final calls = <List<ControllerButton>>[];

  @override
  Future<void> handleButtonsClicked(List<ControllerButton>? buttonsClicked, {bool longPress = false}) async {
    calls.add(List.of(buttonsClicked ?? const []));
  }
}

Uint8List frame(int type, int mask) => Uint8List.fromList([
  type,
  0x00,
  mask & 0xff,
  (mask >> 8) & 0xff,
  if (type == 0x03) ...[mask & 0xff, (mask >> 8) & 0xff],
]);

void main() {
  core.actionHandler = StubActions();
  const char = StagesSmartBikeConstants.BUTTON_CHARACTERISTIC_UUID;

  const buttonsByBit = {
    0x0001: StagesSmartBikeButtons.leftUp,
    0x0002: StagesSmartBikeButtons.leftDown,
    0x0004: StagesSmartBikeButtons.leftThird,
    0x0008: StagesSmartBikeButtons.rightUp,
    0x0010: StagesSmartBikeButtons.rightDown,
    0x0020: StagesSmartBikeButtons.rightThird,
  };

  group('StagesButtonFrame.parse', () {
    test('a held frame names its button', () {
      for (final entry in buttonsByBit.entries) {
        final parsed = StagesButtonFrame.parse(frame(0x01, entry.key))!;
        expect(parsed.isRelease, isFalse);
        expect(parsed.buttons, [entry.value]);
      }
    });

    test('04 and 08 are releases', () {
      expect(StagesButtonFrame.parse(frame(0x04, 0x0008))!.isRelease, isTrue);
      expect(StagesButtonFrame.parse(frame(0x08, 0x0008))!.isRelease, isTrue);
    });

    test('the mid-press commit frame is ignored', () {
      expect(StagesButtonFrame.parse(frame(0x03, 0x0008)), isNull);
    });

    test('several bits are several buttons', () {
      expect(StagesButtonFrame.parse(frame(0x01, 0x0009))!.buttons, [
        StagesSmartBikeButtons.leftUp,
        StagesSmartBikeButtons.rightUp,
      ]);
    });

    test('garbage is ignored, never thrown on', () {
      for (final bytes in [
        <int>[],
        [0x01],
        [0x01, 0x00, 0x08],
        [0x02, 0x00, 0x08, 0x00],
        [0xff, 0xff, 0xff, 0xff],
        [0x00, 0x00, 0x00, 0x00],
      ]) {
        expect(StagesButtonFrame.parse(Uint8List.fromList(bytes)), isNull, reason: '$bytes');
      }
    });

    test('a held frame with no known bit holds nothing', () {
      expect(StagesButtonFrame.parse(frame(0x01, 0x0040))!.buttons, isEmpty);
    });
  });

  group('StagesSmartBike button notifications', () {
    test('every button: press, then release', () async {
      for (final entry in buttonsByBit.entries) {
        final bike = _RecordingBike();
        await bike.processCharacteristic(char, frame(0x01, entry.key));
        await bike.processCharacteristic(char, frame(0x04, entry.key));
        expect(bike.calls, [
          [entry.value],
          <ControllerButton>[],
        ], reason: entry.value.name);
      }
    });

    test('the held stream presses once, not once per notification', () async {
      final bike = _RecordingBike();
      for (var i = 0; i < 15; i++) {
        await bike.processCharacteristic(char, frame(0x01, 0x0010));
      }
      await bike.processCharacteristic(char, frame(0x03, 0x0010));
      for (var i = 0; i < 5; i++) {
        await bike.processCharacteristic(char, frame(0x01, 0x0010));
      }
      await bike.processCharacteristic(char, frame(0x08, 0x0010));
      expect(bike.calls, [
        [StagesSmartBikeButtons.rightDown],
        <ControllerButton>[],
      ]);
    });

    test('a second press after a release presses again', () async {
      final bike = _RecordingBike();
      for (var press = 0; press < 2; press++) {
        await bike.processCharacteristic(char, frame(0x01, 0x0008));
        await bike.processCharacteristic(char, frame(0x01, 0x0008));
        await bike.processCharacteristic(char, frame(0x04, 0x0008));
      }
      expect(bike.calls, [
        [StagesSmartBikeButtons.rightUp],
        <ControllerButton>[],
        [StagesSmartBikeButtons.rightUp],
        <ControllerButton>[],
      ]);
    });

    test('a release with nothing held is not reported', () async {
      final bike = _RecordingBike();
      await bike.processCharacteristic(char, frame(0x04, 0x0008));
      await bike.processCharacteristic(char, frame(0x08, 0x0008));
      expect(bike.calls, isEmpty);
    });

    test('a changing held set is reported each time it changes', () async {
      final bike = _RecordingBike();
      await bike.processCharacteristic(char, frame(0x01, 0x0001));
      await bike.processCharacteristic(char, frame(0x01, 0x0009));
      await bike.processCharacteristic(char, frame(0x01, 0x0009));
      await bike.processCharacteristic(char, frame(0x04, 0x0009));
      expect(bike.calls, [
        [StagesSmartBikeButtons.leftUp],
        [StagesSmartBikeButtons.leftUp, StagesSmartBikeButtons.rightUp],
        <ControllerButton>[],
      ]);
    });

    test('garbage and the commit frame alone press nothing', () async {
      final bike = _RecordingBike();
      await bike.processCharacteristic(char, Uint8List.fromList([0x01]));
      await bike.processCharacteristic(char, Uint8List(0));
      await bike.processCharacteristic(char, frame(0x03, 0x0008));
      await bike.processCharacteristic(char, Uint8List.fromList([0x7f, 0x00, 0x08, 0x00]));
      expect(bike.calls, isEmpty);
    });

    test('the characteristic UUID is matched regardless of case', () async {
      final bike = _RecordingBike();
      await bike.processCharacteristic(char.toUpperCase(), frame(0x01, 0x0008));
      expect(bike.calls, [
        [StagesSmartBikeButtons.rightUp],
      ]);
    });
  });

  test('default actions', () {
    expect(StagesSmartBikeButtons.rightUp.action, InGameAction.shiftUp);
    expect(StagesSmartBikeButtons.rightDown.action, InGameAction.shiftDown);
    expect(StagesSmartBikeButtons.leftUp.action, InGameAction.shiftUp);
    expect(StagesSmartBikeButtons.leftDown.action, InGameAction.shiftDown);
    expect(StagesSmartBikeButtons.leftThird.action, InGameAction.navigateLeft);
    expect(StagesSmartBikeButtons.rightThird.action, InGameAction.navigateRight);
  });

  test('button names are unique across every known controller', () {
    final names = StagesSmartBikeButtons.values.map((b) => b.name).toSet();
    expect(names, hasLength(StagesSmartBikeButtons.values.length));
    final others = ControllerButton.values.where((b) => !StagesSmartBikeButtons.values.contains(b)).map((b) => b.name);
    expect(names.intersection(others.toSet()), isEmpty);
    expect(ControllerButton.values, containsAll(StagesSmartBikeButtons.values));
  });
}
