// Every controller reports, in one place, whether the rider still has to do
// something on it before its buttons work — see [BaseDevice.setupNeed]. Ride,
// the one-time setup prompt and anything else that wants to warn about an
// unfinished controller read that, never the device class.
import 'package:bike_control/bluetooth/devices/base_device.dart';
import 'package:bike_control/bluetooth/devices/sram/sram_axs.dart';
import 'package:bike_control/bluetooth/devices/zwift/constants.dart';
import 'package:bike_control/bluetooth/devices/zwift/zwift_clickv2.dart';
import 'package:bike_control/bluetooth/devices/zwift/zwift_clickv2_right_side.dart';
import 'package:bike_control/bluetooth/devices/zwift/zwift_play.dart';
import 'package:bike_control/main.dart';
import 'package:bike_control/utils/actions/base_actions.dart';
import 'package:bike_control/utils/core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prop/prop.dart' show propPrefs;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_ble/universal_ble.dart';

ZwiftClickV2 _click() => ZwiftClickV2(BleDevice(deviceId: 'need-click', name: 'Zwift Click'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    core.settings.prefs = await SharedPreferences.getInstance();
    propPrefs.initialize(core.settings.prefs);
    screenshotMode = false;
    core.actionHandler = StubActions();
  });

  group('Zwift Click V2', () {
    test('needs its setup while the unlock-mode choice is outstanding', () {
      final click = _click();
      expect(click.setupNeed, DeviceSetupNeed.setup);
      final right = ZwiftClickV2RightSide(BleDevice(deviceId: 'need-right', name: 'Zwift Click'));
      expect(right.setupNeed, DeviceSetupNeed.setup);
    });

    test('both pucks share one setup — it is a single decision', () {
      final click = _click();
      final right = ZwiftClickV2RightSide(BleDevice(deviceId: 'need-right', name: 'Zwift Click'));
      expect(click.setupPromptKey, right.setupPromptKey);
    });

    test('in unlock-with-Zwift mode, connected and locked: needs unlocking', () async {
      await core.settings.setClickV2OnboardingDone(true);
      await core.settings.setUnlockWithZwift(true);
      final click = _click()..isConnected = true;
      expect(click.setupNeed, DeviceSetupNeed.unlock);
    });

    test('unlocked within the last day: nothing to do', () async {
      await core.settings.setClickV2OnboardingDone(true);
      await core.settings.setUnlockWithZwift(true);
      final click = _click()..isConnected = true;
      propPrefs.setZwiftClickV2LastUnlock(click.scanResult.deviceId, DateTime.now());
      expect(click.setupNeed, isNull);
    });

    test('a locked controller out of reach cannot be unlocked: no need reported', () async {
      await core.settings.setClickV2OnboardingDone(true);
      await core.settings.setUnlockWithZwift(true);
      expect(_click().setupNeed, isNull);
    });
  });

  group('SRAM AXS', () {
    test('connected before its guided setup has run: needs its setup', () {
      final sram = SramAxs(BleDevice(deviceId: 'need-sram', name: 'SRAM Rival AXS'))..isConnected = true;
      expect(sram.setupNeed, DeviceSetupNeed.setup);
    });

    test('once its own shifting is disabled: nothing to do', () async {
      final sram = SramAxs(BleDevice(deviceId: 'need-sram', name: 'SRAM Rival AXS'))..isConnected = true;
      await core.settings.setSramShiftingDisabled('need-sram', true);
      expect(sram.setupNeed, isNull);
    });

    test('not connected: the guided setup cannot run, so no need is reported', () {
      final sram = SramAxs(BleDevice(deviceId: 'need-sram', name: 'SRAM Rival AXS'));
      expect(sram.setupNeed, isNull);
    });

    test('each derailleur is its own setup', () {
      final a = SramAxs(BleDevice(deviceId: 'sram-a', name: 'SRAM Rival AXS'));
      final b = SramAxs(BleDevice(deviceId: 'sram-b', name: 'SRAM Rival AXS'));
      expect(a.setupPromptKey, isNot(b.setupPromptKey));
    });
  });

  test('a controller without any setup reports none', () {
    final play = ZwiftPlay(BleDevice(name: 'Zwift Play', deviceId: 'need-play'), deviceType: ZwiftDeviceType.playLeft)
      ..isConnected = true;
    expect(play.setupNeed, isNull);
  });
}
