import 'package:accessibility/accessibility.dart';
import 'package:bike_control/bluetooth/devices/gamepad/gamepad_device.dart';
import 'package:bike_control/bluetooth/devices/hid/hid_device.dart';
import 'package:bike_control/gen/l10n.dart';
import 'package:bike_control/utils/actions/android.dart';
import 'package:bike_control/utils/core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A Bluetooth HID keyboard or media remote can also be listed by Android as
  // a gamepad. Keys from it arrive through the accessibility service under the
  // same device name as that gamepad.
  const source = 'Remote Keyboard';

  late AndroidActions actions;
  late GamepadDevice gamepad;

  setUp(() async {
    await AppLocalizations.load(const Locale('en'));
    SharedPreferences.setMockInitialValues({});
    core.settings.prefs = await SharedPreferences.getInstance();
    actions = AndroidActions();
    core.actionHandler = actions;
    core.connection.devices.clear();
    gamepad = GamepadDevice(source, id: 'pad-1');
    core.connection.devices.add(gamepad);
  });

  tearDown(() => core.connection.devices.clear());

  AKeyEvent key(String hidKey, {required bool down}) =>
      AKeyEvent(source: source, hidKey: hidKey, keyDown: down, keyUp: !down);

  test('a key the gamepad mapping does not know reaches the HID path', () async {
    actions.handleHidKey(key('KEYCODE_VOLUME_UP', down: true));
    actions.handleHidKey(key('KEYCODE_VOLUME_UP', down: false));
    await pumpEventQueue();

    final hid = core.connection.devices.whereType<HidDevice>().where((d) => d.name == source).toList();
    expect(hid, hasLength(1), reason: 'an unmapped key from a gamepad-listed device must not be dropped');
    expect(hid.single.availableButtons.map((b) => b.name), contains('KEYCODE_VOLUME_UP'));
    expect(gamepad.availableButtons, isEmpty);
  });

  test('a mapped gamepad button still goes to the gamepad device', () async {
    actions.handleHidKey(key('KEYCODE_BUTTON_A', down: true));
    actions.handleHidKey(key('KEYCODE_BUTTON_A', down: false));
    await pumpEventQueue();

    expect(gamepad.availableButtons.map((b) => b.name), contains('a'));
    expect(core.connection.devices.whereType<HidDevice>(), isEmpty);
  });
}
