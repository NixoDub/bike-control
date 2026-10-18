import 'dart:async';
import 'dart:typed_data';

import 'package:bike_control/bluetooth/messages/notification.dart';
import 'package:bike_control/main.dart' show recordError;
import 'package:bike_control/utils/core.dart';
import 'package:bike_control/utils/keymap/buttons.dart';
import 'package:bike_control/widgets/controller/controller_layout.dart';
import 'package:bike_control/widgets/ui/type_scale.dart';
import 'package:dartx/dartx.dart';
import 'package:flutter/material.dart';
import 'package:prop/prop.dart' hide Set;
import 'package:universal_ble/universal_ble.dart';

import '../base_device.dart' show DeviceSetupNeed;
import '../bluetooth_device.dart';
import 'shimano_ble_transport.dart';
import 'shimano_setup_sheet.dart';

class ShimanoDi2 extends BluetoothDevice {
  ShimanoDi2(super.scanResult) : super(availableButtons: [], buttonPrefix: 'D-Fly Channel ');

  /// Config seam (18FF E-TUBE service), present on wireless units such as the
  /// RD-R7150. Null when the unit only exposes the 18EF runtime D-FLY service.
  ShimanoBleTransport? _configTransport;

  String get _serialKey => device.deviceId;

  bool get hasConfigService => _configTransport != null;

  @override
  Future<void> handleServices(List<BleService> services) async {
    final service = services.firstWhere(
      (e) => e.uuid.toLowerCase() == ShimanoDi2Constants.SERVICE_UUID.toLowerCase(),
      orElse: () => throw Exception('Service not found: ${ShimanoDi2Constants.SERVICE_UUID}'),
    );
    final characteristic = service.characteristics.firstWhere(
      (e) => e.uuid.toLowerCase() == ShimanoDi2Constants.D_FLY_CHANNEL_UUID.toLowerCase(),
      orElse: () => throw Exception('Characteristic not found: ${ShimanoDi2Constants.D_FLY_CHANNEL_UUID}'),
    );

    await UniversalBle.subscribeIndications(device.deviceId, service.uuid, characteristic.uuid);

    // The 18FF E-TUBE config service (SERVICE_UUID_ALTERNATIVE) unlocks button
    // mode: the paddles become BikeControl buttons without changing any Di2
    // setting. Its GATT dance runs through [ShimanoConfig] over this transport;
    // notifications are routed back from [processCharacteristic].
    final hasConfig = services.any(
      (e) => e.uuid.toLowerCase() == ShimanoDi2Constants.SERVICE_UUID_ALTERNATIVE.toLowerCase(),
    );
    _configTransport = hasConfig ? ShimanoBleTransport(device.deviceId, services) : null;

    // Once the rider has opted in, re-enter button mode on every (re)connect.
    // This also releases a derailleur left in PC-connect mode by an earlier,
    // interrupted session.
    if (hasConfig && isButtonModeEnabled) {
      unawaited(_enterButtonModeLogged());
    }
  }

  final _lastButtons = <int, ({int value, _Di2State type})>{};
  bool _isInitialized = false;

  @override
  String get buttonExplanation => 'Click a D-Fly button to configure them.';

  @override
  Future<void> processCharacteristic(String characteristic, Uint8List bytes) async {
    Logger.info('Received data from $characteristic: ${bytesToReadableHex(bytes)}');

    // Route the config service's notifications/indications (incl. the paddle
    // presses in button mode) to the config transport.
    final lower = characteristic.toLowerCase();
    if (_configTransport != null &&
        (lower == ShimanoDi2Config.pceResponseChar ||
            lower == ShimanoDi2Config.authControlChar ||
            lower == ShimanoDi2Config.pceAuxNotify1 ||
            lower == ShimanoDi2Config.pceAuxNotify2)) {
      _configTransport!.onNotification(lower, bytes);
      return;
    }

    if (characteristic.toLowerCase() == ShimanoDi2Constants.D_FLY_CHANNEL_UUID) {
      final channels = bytes.sublist(1);

      // On first data reception, just initialize the state without triggering buttons
      if (!_isInitialized) {
        channels.forEachIndexed((int value, int index) {
          final readableIndex = index + 1;
          _lastButtons[index] = (value: value, type: _Di2State.released);

          getOrAddButton(
            'D-Fly Channel $readableIndex',
            () => ControllerButton('D-Fly Channel $readableIndex', sourceDeviceId: device.deviceId),
          );
        });
        _isInitialized = true;
        return Future.value();
      }

      var actualChange = false;
      channels.forEachIndexed((int value, int index) {
        final didChange = _lastButtons[index]?.value != value;

        final readableIndex = index + 1;

        if (didChange) {
          if ((value & 0x10) != 0) {
            if (_lastButtons[index]?.type == _Di2State.longPress || _lastButtons[index]?.type == _Di2State.keep) {
              // short press is triggered after long press, until it's released later on
              _lastButtons[index] = (value: value, type: _Di2State.keep);
              Logger.info('Button $readableIndex still long pressed');
            } else {
              _lastButtons[index] = (value: value, type: _Di2State.shortPress);
              actualChange = true;
              Logger.info('Button $readableIndex short pressed');
            }
          } else if ((value & 0x20) != 0) {
            _lastButtons[index] = (value: value, type: _Di2State.longPress);
            actualChange = true;
            Logger.info('Button $readableIndex long pressed');
          } else if ((value & 0x40) != 0) {
            _lastButtons[index] = (value: value, type: _Di2State.doublePress);
            actualChange = true;
            Logger.info('Button $readableIndex double pressed');
          } else {
            _lastButtons[index] = (value: value, type: _Di2State.released);
            actualChange = true;
            Logger.info('Button $readableIndex released');
          }
        }
      });

      if (actualChange) {
        final Map<_Di2State, List<ControllerButton>> mapped = _lastButtons.entries.groupBy((e) => e.value.type).map((
          key,
          value,
        ) {
          final buttons = value
              .map((entry) => availableButtons.firstWhere((button) => button.name == 'D-Fly Channel ${entry.key + 1}'))
              .toList();
          return MapEntry(key, buttons);
        });

        final shortPress = [...?mapped[_Di2State.shortPress], ...?mapped[_Di2State.doublePress]];
        if (shortPress.isNotEmpty) {
          Logger.debug('Short Press Buttons to trigger: ${shortPress.map((b) => b.name).join(', ')}');
          handleButtonsClicked(shortPress);
          handleButtonsClicked([]);
          _resetButtonsForState([_Di2State.shortPress]);
        }

        final longPress = mapped[_Di2State.longPress] ?? [];
        if (longPress.isNotEmpty) {
          Logger.debug('Long Press Buttons to trigger: ${longPress.map((b) => b.name).join(', ')}');
          handleButtonsClicked(longPress);
        }

        final released = mapped[_Di2State.released] ?? [];
        final keepPress = mapped[_Di2State.longPress] ?? [];

        if (released.isNotEmpty && keepPress.isEmpty) {
          Logger.debug('Releasing all Buttons');
          handleButtonsClicked([]);
        }

        final doublePress = mapped[_Di2State.doublePress] ?? [];
        if (doublePress.isNotEmpty) {
          Logger.debug('Buttons to still trigger: ${doublePress.map((b) => b.name).join(', ')}');
          handleButtonsClicked(doublePress);
          handleButtonsClicked([]);
          _resetButtonsForState([_Di2State.doublePress]);
        }
      }
    }
  }

  void _resetButtonsForState(List<_Di2State> list) {
    _lastButtons.forEach((key, value) {
      if (list.contains(value.type)) {
        _lastButtons[key] = (value: value.value, type: _Di2State.released);
      }
    });
  }

  // ── Button mode (18FF config service) ─────────────────────────────────────

  /// Whether the rider opted in to button mode for this Di2.
  bool get isButtonModeEnabled => core.settings.getShimanoButtonMode(_serialKey);

  ShimanoButtonSession? _buttonSession;
  final Set<ControllerButton> _pressed = {};

  /// A GATT/handshake timeout means the Di2 didn't answer (asleep / out of
  /// range) — the sheet then prompts the rider to wake it and retry.
  bool _isUnresponsive(Object error) {
    if (error is TimeoutException) return true;
    if (error is ShimanoPasskeyRejectedException) return false;
    if (error is ShimanoAuthException) return error.message.contains('TimeoutException');
    return false;
  }

  /// Authenticate with [passkey] and put the Di2 into button mode: while the
  /// link is up the derailleur stops shifting itself and every paddle press
  /// arrives here as a button. Nothing on the Di2 is changed — once the link
  /// drops it shifts normally again.
  Future<void> enterButtonMode({required String passkey}) async {
    final t = _configTransport;
    if (t == null) return;
    await ShimanoConfig.authenticate(t, passkey: passkey);
    await _buttonSession?.close();
    _buttonSession = await ShimanoConfig.enterButtonMode(
      t,
      onPaddle: onPaddle,
      onStepError: (step, e, st) => unawaited(recordError(e, st, context: 'ShimanoDi2: button mode step $step')),
    );
    registerPaddleButtons();
  }

  @visibleForTesting
  void registerPaddleButtons() {
    for (final button in ShimanoDi2Buttons.values) {
      getOrAddButton(button.name, () => button.copyWith(sourceDeviceId: device.deviceId));
    }
  }

  /// One-time opt-in from the setup sheet: enter button mode with [passkey]
  /// and remember both, so every later connect re-enters it automatically.
  Future<void> setupButtonMode({required String passkey}) async {
    try {
      // A wrong passkey makes the RD drop the link, and BikeControl reconnects
      // it as a new device object — a retry from the still-open sheet must run
      // on that one, not on this disconnected instance.
      final target = await _liveInstance();
      await target.enterButtonMode(passkey: passkey);
      await core.settings.setShimanoPasskey(_serialKey, passkey);
      await core.settings.setShimanoButtonMode(_serialKey, true);
      core.connection.signalChange(target);
    } catch (e, st) {
      actionStreamInternal.add(LogNotification('ShimanoDi2 button mode setup failed: $e'));
      await recordError(e, st, context: 'ShimanoDi2: button mode setup');
      rethrow;
    }
  }

  /// The connected [ShimanoDi2] for this Di2: this instance, or the one a
  /// reconnect replaced it with. Waits briefly for a reconnect to finish; a
  /// [TimeoutException] means the Di2 didn't come back (asleep / out of range).
  Future<ShimanoDi2> _liveInstance({Duration timeout = const Duration(seconds: 20)}) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final live = core.connection.controllerDevices
              .whereType<ShimanoDi2>()
              .firstOrNullWhere((d) => d.device.deviceId == device.deviceId) ??
          this;
      if (live.isConnected && live.hasConfigService) return live;
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('Di2 did not reconnect', timeout);
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  Future<void> _enterButtonModeLogged() async {
    try {
      await enterButtonMode(passkey: core.settings.getShimanoPasskey(_serialKey));
      core.connection.signalChange(this);
    } catch (e, st) {
      actionStreamInternal.add(LogNotification('ShimanoDi2 could not enter button mode: $e'));
      await recordError(e, st, context: 'ShimanoDi2: enter button mode');
    }
  }

  /// Opt out: forget the choice and drop the link, which is what returns the
  /// Di2 to normal shifting. The next connect leaves it shifting by itself.
  Future<void> turnOffButtonMode() async {
    await core.settings.setShimanoButtonMode(_serialKey, false);
    await _buttonSession?.close();
    _buttonSession = null;
    await disconnect();
    core.connection.signalChange(this);
  }

  @visibleForTesting
  void onPaddle(ShimanoPaddleEvent event) {
    final button = availableButtons.firstOrNullWhere((b) => b.name == ShimanoDi2Buttons.of(event).name);
    if (button == null) return;
    switch (event.state) {
      case ShimanoPaddleState.down:
        if (!_pressed.add(button)) return;
      case ShimanoPaddleState.released:
        if (!_pressed.remove(button)) return;
      case ShimanoPaddleState.held:
        // Repeats while pressed; long-press timing is handled by BaseDevice.
        return;
    }
    unawaited(handleButtonsClicked(_pressed.toList()));
  }

  @override
  Future<void> disconnect() async {
    await _buttonSession?.close();
    _buttonSession = null;
    _pressed.clear();
    await super.disconnect();
  }

  /// Until button mode is on, the Di2 shifts itself and reports nothing — so
  /// the ride card has no buttons to show. Surface that as a required one-time
  /// setup (dimmed card + prompt) rather than a blank card.
  @override
  DeviceSetupNeed? get setupNeed =>
      isConnected && hasConfigService && !isButtonModeEnabled ? DeviceSetupNeed.setup : null;

  @override
  Future<void> openSetup(BuildContext context) async {
    if (setupNeed == DeviceSetupNeed.setup) await _showSetup(context);
  }

  Future<void> _showSetup(BuildContext context) => showShimanoSetup(
        context,
        initialPasskey: core.settings.getShimanoPasskey(_serialKey),
        operation: (passkey) => setupButtonMode(passkey: passkey),
        isUnresponsive: _isUnresponsive,
        isPasskeyRejected: (e) => e is ShimanoPasskeyRejectedException,
      );

  @override
  ControllerLayout? get controllerLayout =>
      hasConfigService && isButtonModeEnabled ? ShimanoDi2Buttons.layout : null;

  @override
  List<Widget> showAdditionalInformation(BuildContext context) {
    if (hasConfigService) {
      return [
        shimanoSetupPanel(
          context,
          active: isButtonModeEnabled,
          onSetup: () => unawaited(_showSetup(context)),
          onTurnOff: () => unawaited(turnOffButtonMode()),
        ),
      ];
    }
    return [
      Text(
        'Make sure to set your Di2 buttons to D-Fly channels in the Shimano E-TUBE app.',
        style: context.typography.xSmall.copyWith(color: Colors.grey),
      ),
    ];
  }
}

/// The two paddles of each wireless Di2 shifter in button mode, named with the
/// same L1/L2/R1/R2 code their chip shows on the contour. Default
/// actions follow Di2's own shifting: right lever → larger cog (easier), right
/// button → smaller cog (harder); left lever → big ring (harder), left button
/// → small ring (easier).
class ShimanoDi2Buttons {
  ShimanoDi2Buttons._();

  static const leftLever = ControllerButton('Di2 L1 (Lever)', label: 'L1', action: InGameAction.shiftUp);
  static const leftButton = ControllerButton('Di2 L2 (Button)', label: 'L2', action: InGameAction.shiftDown);
  static const rightLever = ControllerButton('Di2 R1 (Lever)', label: 'R1', action: InGameAction.shiftDown);
  static const rightButton = ControllerButton('Di2 R2 (Button)', label: 'R2', action: InGameAction.shiftUp);

  static const values = [leftLever, leftButton, rightLever, rightButton];

  static ControllerButton of(ShimanoPaddleEvent e) => switch ((e.shifter, e.paddle)) {
        (ShimanoShifter.left, ShimanoPaddle.big) => leftLever,
        (ShimanoShifter.left, ShimanoPaddle.small) => leftButton,
        (ShimanoShifter.right, ShimanoPaddle.big) => rightLever,
        (ShimanoShifter.right, ShimanoPaddle.small) => rightButton,
      };

  /// The website's Di2 lever line art: the right lever as drawn, mirrored for
  /// the left. Chips sit on the shift lever (big paddle) and on the shift
  /// button (small paddle) behind each brake lever.
  static final layout = ControllerLayout(
    aspectRatio: 980 / 1054,
    shape: ContourShape.steeringPad,
    svgAsset: 'assets/contours/shimano_di2_shifters.svg',
    positions: {
      leftButton: const Offset(0.206, 0.350),
      leftLever: const Offset(0.277, 0.546),
      rightButton: const Offset(0.794, 0.350),
      rightLever: const Offset(0.723, 0.546),
    },
  );

}

class ShimanoDi2Constants {
  static const String SERVICE_UUID = "000018ef-5348-494d-414e-4f5f424c4500";
  static const String SERVICE_UUID_ALTERNATIVE = "000018ff-5348-494d-414e-4f5f424c4500";

  static const String D_FLY_CHANNEL_UUID = "00002ac2-5348-494d-414e-4f5f424c4500";
}

enum _Di2State {
  shortPress,
  longPress,
  keep,
  doublePress,
  released,
}
