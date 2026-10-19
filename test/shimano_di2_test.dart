import 'dart:async';
import 'dart:typed_data';

import 'package:bike_control/bluetooth/devices/base_device.dart' show DeviceSetupNeed;
import 'package:bike_control/bluetooth/devices/shimano/shimano_ble_transport.dart';
import 'package:bike_control/bluetooth/devices/shimano/shimano_di2.dart';
import 'package:bike_control/gen/l10n.dart';
import 'package:bike_control/utils/actions/base_actions.dart';
import 'package:bike_control/utils/core.dart';
import 'package:bike_control/utils/keymap/apps/openbikecontrol.dart';
import 'package:bike_control/utils/keymap/buttons.dart';
import 'package:flutter/widgets.dart' show Locale;
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

  group('Shimano Di2 button mode setup', () {
    test('a stored passkey the Di2 rejects on connect switches button mode off, so setup asks again', () async {
      final instance = ShimanoDi2(BleDevice(name: 'RDR7150', deviceId: 'di2-passkey'));
      await core.settings.setShimanoButtonMode('di2-passkey', true);

      await instance.autoEnterButtonMode(() async => throw ShimanoPasskeyRejectedException(0x01));

      expect(core.settings.getShimanoButtonMode('di2-passkey'), isFalse);
    });

    test('a Di2 that does not answer on connect keeps button mode on for the next connect', () async {
      final instance = ShimanoDi2(BleDevice(name: 'RDR7150', deviceId: 'di2-asleep'));
      await core.settings.setShimanoButtonMode('di2-asleep', true);

      await instance.autoEnterButtonMode(() async => throw TimeoutException('asleep'));

      expect(core.settings.getShimanoButtonMode('di2-asleep'), isTrue);
    });

    test('button mode fails as unresponsive when the Di2 answers none of its steps', () async {
      final instance = ShimanoDi2(BleDevice(name: 'RDR7150', deviceId: 'di2-silent'));

      await expectLater(instance.startButtonSession(_FakeShimanoTransport(fail: true)), throwsA(isA<TimeoutException>()));
      expect(instance.availableButtons, isEmpty);
    });

    test('button mode registers the paddles when the Di2 answers', () async {
      final instance = ShimanoDi2(BleDevice(name: 'RDR7150', deviceId: 'di2-awake'));

      await instance.startButtonSession(_FakeShimanoTransport(fail: false));

      expect(instance.availableButtons.map((b) => b.name), containsAll(ShimanoDi2Buttons.values.map((b) => b.name)));
    });
  });

  group('Shimano Di2 bond on Windows', () {
    // What WinRT throws when the 18FF CCCD is written over an unbonded link
    // (E_BLUETOOTH_ATT_INSUFFICIENT_AUTHENTICATION), as seen on an RD-R7150.
    final insufficientAuthentication = ShimanoTransportException(
      'subscribe',
      ShimanoDi2Config.authControlChar,
      UniversalBleException(
        code: UniversalBleErrorCode.failed,
        message: 'SetNotifiable exception: Das Attribut muss vor dem Lesen oder Schreiben zunächst '
            'authentifiziert werden.',
        details: 'hr=-2140864507',
      ),
    );

    late List<String> calls;
    setUp(() => calls = []);
    tearDown(() => ShimanoDi2.bond = const ShimanoDi2Bond());

    ShimanoDi2 di2(String id, {Object? subscribeError}) => ShimanoDi2(BleDevice(name: 'RDR7150', deviceId: id))
      ..debugUseConfigTransport(_RecordingShimanoTransport(calls, subscribeError: subscribeError));

    test('an unpaired Di2 is paired before the first config step', () async {
      ShimanoDi2.bond = _FakeBond(calls, paired: false);
      final instance = di2('di2-unpaired', subscribeError: TimeoutException('stop after the first step'));

      await expectLater(instance.enterButtonMode(passkey: '000000'), throwsA(isA<TimeoutException>()));

      expect(calls, ['isPaired', 'pair', 'subscribe ${ShimanoDi2Config.authControlChar}']);
    });

    test('a paired Di2 is not paired again', () async {
      ShimanoDi2.bond = _FakeBond(calls, paired: true);
      final instance = di2('di2-paired', subscribeError: TimeoutException('stop after the first step'));

      await expectLater(instance.enterButtonMode(passkey: '000000'), throwsA(isA<TimeoutException>()));

      expect(calls, ['isPaired', 'subscribe ${ShimanoDi2Config.authControlChar}']);
    });

    test('a refused pairing fails as pairing required, before touching the config service', () async {
      ShimanoDi2.bond = _FakeBond(calls, paired: false, pairError: PairingException('Failed'));
      final instance = di2('di2-refused');

      await expectLater(
        instance.enterButtonMode(passkey: '000000'),
        throwsA(isA<ShimanoDi2PairingRequiredException>().having((e) => e.cause, 'cause', isA<PairingException>())),
      );
      expect(calls, ['isPaired', 'pair']);
    });

    test('insufficient authentication despite a bond (lost on the Di2) fails as pairing required', () async {
      ShimanoDi2.bond = _FakeBond(calls, paired: true);
      final instance = di2('di2-stale', subscribeError: insufficientAuthentication);

      await expectLater(
        instance.enterButtonMode(passkey: '000000'),
        throwsA(isA<ShimanoDi2PairingRequiredException>().having((e) => e.cause, 'cause', insufficientAuthentication)),
      );
    });

    test('off Windows nothing is paired and errors pass through unchanged', () async {
      ShimanoDi2.bond = _FakeBond(calls, paired: false, isRequired: false);
      final instance = di2('di2-android', subscribeError: insufficientAuthentication);

      await expectLater(instance.enterButtonMode(passkey: '000000'), throwsA(same(insufficientAuthentication)));
      expect(calls, ['subscribe ${ShimanoDi2Config.authControlChar}']);
    });

    test('re-entry on reconnect never starts pairing, and a missing bond keeps button mode on', () async {
      ShimanoDi2.bond = _FakeBond(calls, paired: false);
      final instance = di2('di2-reconnect');
      await core.settings.setShimanoButtonMode('di2-reconnect', true);

      await instance.reenterButtonMode();

      expect(calls, ['isPaired']);
      expect(core.settings.getShimanoButtonMode('di2-reconnect'), isTrue);
    });

    test('a lost bond found on reconnect keeps button mode on', () async {
      ShimanoDi2.bond = _FakeBond(calls, paired: true);
      final instance = di2('di2-reconnect-stale', subscribeError: insufficientAuthentication);
      await core.settings.setShimanoButtonMode('di2-reconnect-stale', true);

      await instance.reenterButtonMode();

      expect(core.settings.getShimanoButtonMode('di2-reconnect-stale'), isTrue);
    });
  });

  group('Shimano Di2 D-Fly fallback', () {
    ShimanoDi2 connectedDi2(String id) => ShimanoDi2(BleDevice(name: 'RDR7150', deviceId: id))
      ..debugUseConfigTransport(ShimanoBleTransport(id, const []))
      ..isConnected = true;

    test('a Di2 with the config service asks for button mode setup until the rider decides', () {
      final instance = connectedDi2('di2-undecided');

      expect(instance.setupNeed, DeviceSetupNeed.setup);
    });

    test('choosing D-Fly channels ends the setup request and points at the D-Fly buttons', () async {
      final l = await AppLocalizations.load(const Locale('en'));
      final instance = connectedDi2('di2-dfly-choice');

      await instance.useDflyChannels();

      expect(instance.isDflyChosen, isTrue);
      expect(instance.setupNeed, isNull);
      expect(instance.buttonExplanation, l.shimanoDflyExplanation);
      expect(instance.isButtonModeEnabled, isFalse);
    });

    test('the home chain lists the button mode step until the rider decides, and drops it for D-Fly', () async {
      final instance = connectedDi2('di2-chain');
      expect(instance.buttonModeSetupDone, isFalse);

      await instance.useDflyChannels();

      expect(instance.buttonModeSetupDone, isNull);
    });

    test('a Di2 without the config service has no button mode step', () {
      final instance = ShimanoDi2(BleDevice(name: 'Di2', deviceId: 'di2-no-config'));

      expect(instance.buttonModeSetupDone, isNull);
    });
  });

  group('Shimano Di2 settings hint before any button is known', () {
    test('a Di2 with button mode asks for the one-time setup, not a D-Fly button', () async {
      final l = await AppLocalizations.load(const Locale('en'));
      final instance = ShimanoDi2(BleDevice(name: 'RDR7150', deviceId: 'di2-hint'))
        ..debugUseConfigTransport(ShimanoBleTransport('di2-hint', const []));

      expect(instance.buttonExplanation, l.chainStepShimanoSetupHint);
    });

    test('a Di2 without the config service still points at its D-Fly buttons', () async {
      final l = await AppLocalizations.load(const Locale('en'));
      final instance = ShimanoDi2(BleDevice(name: 'Di2', deviceId: 'di2-dfly'));

      expect(instance.buttonExplanation, l.shimanoDflyExplanation);
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

class _FakeBond implements ShimanoDi2Bond {
  _FakeBond(this.calls, {required this.paired, this.pairError, this.isRequired = true});
  final List<String> calls;
  bool paired;
  final Object? pairError;

  @override
  final bool isRequired;

  @override
  Future<bool> isPaired(String deviceId) async {
    calls.add('isPaired');
    return paired;
  }

  @override
  Future<void> pair(String deviceId) async {
    calls.add('pair');
    if (pairError != null) throw pairError!;
    paired = true;
  }
}

/// Records every GATT step into the shared [calls] log; the first subscribe
/// throws [subscribeError] when set.
class _RecordingShimanoTransport extends ShimanoBleTransport {
  _RecordingShimanoTransport(this.calls, {this.subscribeError}) : super('di2', const []);
  final List<String> calls;
  final Object? subscribeError;

  @override
  Future<void> subscribe(String characteristic) async {
    calls.add('subscribe $characteristic');
    if (subscribeError != null) throw subscribeError!;
  }

  @override
  Future<void> write(String characteristic, Uint8List data, {bool withoutResponse = false}) async =>
      calls.add('write $characteristic');

  @override
  Future<Uint8List> read(String characteristic) async {
    calls.add('read $characteristic');
    return Uint8List(0);
  }

  @override
  Stream<Uint8List> notifications(String characteristic) => const Stream.empty();
}

class _FakeShimanoTransport implements ShimanoTransport {
  _FakeShimanoTransport({required this.fail});
  final bool fail;

  Future<T> _answer<T>(T value) async {
    if (fail) throw TimeoutException('no answer');
    return value;
  }

  @override
  Future<void> subscribe(String characteristic) => _answer(null);

  @override
  Future<void> write(String characteristic, Uint8List data, {bool withoutResponse = false}) => _answer(null);

  @override
  Future<Uint8List> read(String characteristic) => _answer(Uint8List(0));

  @override
  Stream<Uint8List> notifications(String characteristic) => const Stream.empty();
}
