import 'package:bike_control/utils/actions/base_actions.dart';
import 'package:bike_control/utils/keymap/buttons.dart';
import 'package:bike_control/utils/keymap/keymap.dart';

/// Lets a screen take over some controller presses for as long as it is
/// installed in `BaseDevice.inputInterceptor`, before they become actions.
///
/// Every press is offered with the action the rider's keymap gives the button
/// on a single click ([mappedAction]), so a scheme can be written in terms of
/// "the shift up button" rather than hardware button names. A non-null result
/// consumes the press: it is not forwarded to the trainer app, keyboard or
/// touch output. Null lets it through unchanged.
abstract interface class ControllerInputInterceptor {
  /// True when a long press of a button mapped to [mappedAction] should be
  /// detected (and offered to [intercept]) even though the keymap gives it no
  /// long-press action. Its short press then fires on release, as for any
  /// button with a long-press action.
  bool claimsLongPress(InGameAction? mappedAction);

  ActionResult? intercept(
    ControllerButton button,
    InGameAction? mappedAction,
    ButtonTrigger trigger, {
    required bool isKeyDown,
  });

  /// Several buttons pressed in the same frame.
  ActionResult? interceptChord(List<ControllerButton> buttons, List<InGameAction?> mappedActions);
}
