import 'package:bike_control/bluetooth/devices/controller_input_interceptor.dart';
import 'package:bike_control/gen/l10n.dart';
import 'package:bike_control/services/vs_calibration/vs_calibration_session.dart';
import 'package:bike_control/utils/actions/base_actions.dart';
import 'package:bike_control/utils/keymap/buttons.dart';
import 'package:bike_control/utils/keymap/keymap.dart';

/// Answers the shifting calibrator from the rider's own controller, so a run
/// never needs a hand off the bars.
///
/// The scheme has to work on a controller with nothing but two shift buttons,
/// and the rider keeps shifting with those to pick a gear on every grade, so a
/// short press must stay a shift:
///
/// * hold shift down: too heavy (the way the rider wants the gear to go)
/// * hold shift up: too light
/// * press both shifters together: about right, on to the next grade
///
/// A hold is the existing long-press trigger (claimed via [claimsLongPress],
/// so it is detected even with no long-press mapping); a short press then
/// fires on release, as on any button with a long-press action. Both shifters
/// arrive either as one chord (one controller) or as two shifts from two
/// controller halves within [chordWindow]; in the second case the first shift
/// has already gone through, so it is undone.
///
/// A controller with navigation buttons answers directly with whatever the
/// rider's keymap maps to navigate left / select / navigate right, left to
/// right as the answers are laid out on screen.
class CalibrationControllerInput implements ControllerInputInterceptor {
  CalibrationControllerInput({
    required this.onAnswer,
    required this.currentGear,
    required this.restoreGear,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final void Function(CalibrationRating rating) onAnswer;
  final int Function() currentGear;
  final void Function(int gear) restoreGear;
  final DateTime Function() _now;

  /// Two shifts this close together, one up and one down, are one chord.
  static const chordWindow = Duration(milliseconds: 150);

  /// A held navigation button repeats; presses closer together than this
  /// count as one.
  static const answerDebounce = Duration(milliseconds: 700);

  DateTime? _lastAnswerAt;
  ({InGameAction action, DateTime at, int gearBefore})? _lastShift;

  @override
  bool claimsLongPress(InGameAction? mappedAction) =>
      mappedAction == InGameAction.shiftUp || mappedAction == InGameAction.shiftDown;

  @override
  ActionResult? intercept(
    ControllerButton button,
    InGameAction? mappedAction,
    ButtonTrigger trigger, {
    required bool isKeyDown,
  }) {
    if (trigger == ButtonTrigger.longPress && claimsLongPress(mappedAction)) {
      if (!isKeyDown) return Ignored('', button: button);
      return _answer(
        mappedAction == InGameAction.shiftDown ? CalibrationRating.tooHeavy : CalibrationRating.tooLight,
        button,
      );
    }
    final direct = switch (mappedAction) {
      InGameAction.navigateLeft => CalibrationRating.tooHeavy,
      InGameAction.select => CalibrationRating.aboutRight,
      InGameAction.navigateRight => CalibrationRating.tooLight,
      _ => null,
    };
    if (direct != null) {
      return isKeyDown ? _answer(direct, button) : Ignored('', button: button);
    }
    if (trigger == ButtonTrigger.singleClick && isKeyDown && claimsLongPress(mappedAction)) {
      return _shift(mappedAction!, button);
    }
    return null;
  }

  @override
  ActionResult? interceptChord(List<ControllerButton> buttons, List<InGameAction?> mappedActions) {
    if (!mappedActions.contains(InGameAction.shiftUp) || !mappedActions.contains(InGameAction.shiftDown)) {
      return null;
    }
    return _answer(CalibrationRating.aboutRight, buttons.first);
  }

  /// A plain shift passes through, unless it completes a chord with the
  /// opposite shift from another controller half.
  ActionResult? _shift(InGameAction action, ControllerButton button) {
    final now = _now();
    final last = _lastShift;
    if (last != null && last.action != action && now.difference(last.at) <= chordWindow) {
      _lastShift = null;
      restoreGear(last.gearBefore);
      return _answer(CalibrationRating.aboutRight, button);
    }
    _lastShift = (action: action, at: now, gearBefore: currentGear());
    return null;
  }

  ActionResult _answer(CalibrationRating rating, ControllerButton button) {
    final now = _now();
    final last = _lastAnswerAt;
    // Measured from the last answer press, consumed or not, so a held button
    // that keeps repeating never gets a second answer through.
    _lastAnswerAt = now;
    if (last != null && now.difference(last) < answerDebounce) {
      return Ignored('', button: button);
    }
    onAnswer(rating);
    final l10n = AppLocalizations.current;
    return Success(
      switch (rating) {
        CalibrationRating.tooHeavy => l10n.vsCalibrateTooHeavy,
        CalibrationRating.aboutRight => l10n.vsCalibrateAboutRight,
        CalibrationRating.tooLight => l10n.vsCalibrateTooLight,
      },
      button: button,
    );
  }
}
