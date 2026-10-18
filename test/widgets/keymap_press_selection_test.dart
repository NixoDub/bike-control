import 'package:bike_control/bluetooth/devices/shimano/shimano_di2.dart';
import 'package:bike_control/bluetooth/messages/notification.dart';
import 'package:bike_control/utils/actions/base_actions.dart';
import 'package:bike_control/utils/core.dart';
import 'package:bike_control/utils/keymap/buttons.dart';
import 'package:bike_control/utils/keymap/keymap.dart';
import 'package:bike_control/widgets/keymap_explanation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

/// Pressing a button on the Controller settings screen opens its entry for the
/// gesture that actually ran — not always the single click.
void main() {
  core.actionHandler = StubActions();
  final device = ShimanoDi2(BleDevice(name: 'RDR7150', deviceId: 'di2'));
  const button = ShimanoDi2Buttons.leftLever;
  final keymap = Keymap(keyPairs: []);

  test('a resolved gesture selects that trigger', () {
    for (final trigger in ButtonTrigger.values) {
      final n = GestureNotification(device: device, button: button, trigger: trigger);
      expect(pressSelection(n, keymap), (button: button, trigger: trigger));
    }
  });

  test('a bare press no longer selects anything; the gesture that follows does', () {
    expect(pressSelection(ButtonNotification(buttonsClicked: [button], device: device), keymap), isNull);
  });
}
