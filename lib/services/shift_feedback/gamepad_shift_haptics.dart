import 'package:bike_control/services/shift_feedback/shift_feedback_service.dart';
import 'package:bike_control/utils/core.dart';
import 'package:dartx/dartx.dart';

/// Rumbles the gamepad whose button shifted. Other controllers are left
/// alone: Zwift controllers buzz on the press by themselves.
class GamepadShiftHaptics implements ControllerShiftHaptics {
  const GamepadShiftHaptics();

  @override
  Future<void> play(ShiftCue cue, {required String deviceId}) async {
    final gamepad = core.connection.gamepadDevices.firstOrNullWhere((device) => device.id == deviceId);
    await gamepad?.playShiftCue(cue);
  }
}
