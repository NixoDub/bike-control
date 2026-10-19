import 'package:bike_control/bluetooth/devices/smart_bike/smart_bike_trainer.dart';
import 'package:bike_control/bluetooth/messages/notification.dart';
import 'package:bike_control/utils/core.dart';
import 'package:bike_control/utils/keymap/buttons.dart';
import 'package:dartx/dartx.dart';
import 'package:flutter/foundation.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:universal_ble/universal_ble.dart';

import '../bluetooth_device.dart';

/// A Stages smart bike (SB20): one peripheral that is both a smart trainer
/// and the host of its own shift buttons. Classified by name as this
/// controller, so its buttons drive BikeControl; its trainer services are
/// listed a second time as a [SmartBikeTrainer] over the same link.
class StagesSmartBike extends BluetoothDevice with SmartBikeHost {
  StagesSmartBike(super.scanResult) : super(availableButtons: StagesSmartBikeButtons.values, isBeta: true);

  /// The buttons the bike reports as held right now.
  Set<ControllerButton> _held = const {};

  @override
  Set<String> get controllerServiceUuids => {
    StagesSmartBikeConstants.BUTTON_SERVICE_UUID,
    StagesSmartBikeConstants.API_SERVICE_UUID,
  };

  @override
  Set<String> get controllerCharacteristicUuids => {StagesSmartBikeConstants.BUTTON_CHARACTERISTIC_UUID};

  @override
  Future<void> handleServices(List<BleService> services) async {
    final service = services.firstOrNullWhere(
      (e) => e.uuid.toLowerCase() == StagesSmartBikeConstants.BUTTON_SERVICE_UUID,
    );
    final characteristic = service?.characteristics.firstOrNullWhere(
      (e) => e.uuid.toLowerCase() == StagesSmartBikeConstants.BUTTON_CHARACTERISTIC_UUID,
    );

    if (characteristic != null) {
      await UniversalBle.subscribeNotifications(device.deviceId, service!.uuid, characteristic.uuid);
    }

    await attachTrainer(services);

    if (characteristic == null) {
      final missing = service == null
          ? 'Service not found: ${StagesSmartBikeConstants.BUTTON_SERVICE_UUID}'
          : 'Characteristic not found: ${StagesSmartBikeConstants.BUTTON_CHARACTERISTIC_UUID}';
      // Nothing to offer without the buttons unless the bike is a trainer.
      if (trainer == null) throw Exception(missing);
      core.connection.signalNotification(LogNotification('$this: $missing — trainer only'));
    }
  }

  @override
  Future<void> processCharacteristic(String characteristic, Uint8List bytes) async {
    if (!isControllerCharacteristic(characteristic)) {
      return forwardToTrainer(characteristic, bytes);
    }
    final frame = StagesButtonFrame.parse(bytes);
    if (frame == null) return;

    final held = frame.isRelease ? const <ControllerButton>{} : frame.buttons.toSet();
    // The bike streams the held frame for as long as a button is down; only a
    // change of what is held is a press or a release. Long press and repeat
    // are timed by the shared button handling, not by this stream.
    if (held.length == _held.length && held.containsAll(_held)) return;
    _held = held;
    await handleButtonsClicked(held.isEmpty ? [] : frame.buttons);
  }

  @override
  Future<void> disconnect() {
    _held = const {};
    return super.disconnect();
  }
}

/// One frame from the button characteristic: `<type> 00 <bitmask u16 LE>`,
/// the bitmask one bit per button. Type 0x01 is streamed while held, 0x03 is
/// sent once mid-press (and carries the bitmask twice), 0x04 / 0x08 end the
/// press.
class StagesButtonFrame {
  const StagesButtonFrame._({required this.isRelease, required this.buttons});

  final bool isRelease;

  /// The buttons a held frame names, in bit order; empty for a release.
  final List<ControllerButton> buttons;

  static const _held = 0x01;
  static const _releases = {0x04, 0x08};

  /// The frame [bytes] carry, or null when they carry nothing to act on: the
  /// mid-press commit, an unknown type, or too short to read.
  static StagesButtonFrame? parse(Uint8List bytes) {
    if (bytes.length < 4) return null;
    final type = bytes[0];
    if (_releases.contains(type)) return const StagesButtonFrame._(isRelease: true, buttons: []);
    if (type != _held) return null;
    final mask = bytes[2] | (bytes[3] << 8);
    return StagesButtonFrame._(
      isRelease: false,
      buttons: [
        for (final entry in StagesSmartBikeConstants.bitToButton.entries)
          if (mask & entry.key != 0) entry.value,
      ],
    );
  }
}

class StagesSmartBikeConstants {
  static const String BUTTON_SERVICE_UUID = '0c46be5f-9c22-48ff-ae0e-c6eae1a2f4e5';
  static const String BUTTON_CHARACTERISTIC_UUID = '0c46be60-9c22-48ff-ae0e-c6eae1a2f4e5';

  /// The bike's own API (telemetry and settings). BikeControl never
  /// subscribes or writes to it, and the trainer role does not mirror it.
  static const String API_SERVICE_UUID = '0c46beaf-9c22-48ff-ae0e-c6eae1a2f4e5';

  /// The advertised name is `Stages Bike <4 digits>`.
  static bool matchesName(String name) => name.toUpperCase().startsWith('STAGES BIKE');

  static const Map<int, ControllerButton> bitToButton = {
    0x0001: StagesSmartBikeButtons.leftUp,
    0x0002: StagesSmartBikeButtons.leftDown,
    0x0004: StagesSmartBikeButtons.leftThird,
    0x0008: StagesSmartBikeButtons.rightUp,
    0x0010: StagesSmartBikeButtons.rightDown,
    0x0020: StagesSmartBikeButtons.rightThird,
  };
}

class StagesSmartBikeButtons {
  static const ControllerButton leftUp = ControllerButton(
    'stagesLeftUp',
    action: InGameAction.shiftUp,
    icon: LucideIcons.plus,
    color: Colors.black,
  );
  static const ControllerButton leftDown = ControllerButton(
    'stagesLeftDown',
    action: InGameAction.shiftDown,
    icon: LucideIcons.minus,
    color: Colors.black,
  );
  static const ControllerButton leftThird = ControllerButton(
    'stagesLeftThird',
    action: InGameAction.navigateLeft,
    icon: LucideIcons.chevronLeft,
    color: Colors.black,
  );
  static const ControllerButton rightUp = ControllerButton(
    'stagesRightUp',
    action: InGameAction.shiftUp,
    icon: LucideIcons.plus,
    color: Colors.black,
  );
  static const ControllerButton rightDown = ControllerButton(
    'stagesRightDown',
    action: InGameAction.shiftDown,
    icon: LucideIcons.minus,
    color: Colors.black,
  );
  static const ControllerButton rightThird = ControllerButton(
    'stagesRightThird',
    action: InGameAction.navigateRight,
    icon: LucideIcons.chevronRight,
    color: Colors.black,
  );

  static const List<ControllerButton> values = [
    leftUp,
    leftDown,
    leftThird,
    rightUp,
    rightDown,
    rightThird,
  ];
}
