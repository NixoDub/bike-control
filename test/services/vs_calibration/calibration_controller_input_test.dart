import 'package:bike_control/gen/l10n.dart';
import 'package:bike_control/services/vs_calibration/calibration_controller_input.dart';
import 'package:bike_control/services/vs_calibration/vs_calibration_session.dart';
import 'package:bike_control/utils/actions/base_actions.dart';
import 'package:bike_control/utils/keymap/buttons.dart';
import 'package:bike_control/utils/keymap/keymap.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// The calibrator answered from the rider's own controller: hold shift down =
/// too heavy, hold shift up = too light, both shifters together = about right,
/// and on controllers with navigation buttons left / select / right.
Future<void> main() async {
  await AppLocalizations.load(const Locale('en'));

  const plus = ControllerButton('plus');
  const minus = ControllerButton('minus');
  const nav = ControllerButton('nav');

  late List<CalibrationRating> answers;
  late int gear;
  late DateTime clock;
  late CalibrationControllerInput input;

  setUp(() {
    answers = [];
    gear = 12;
    clock = DateTime(2026, 10, 11, 8);
    input = CalibrationControllerInput(
      onAnswer: answers.add,
      currentGear: () => gear,
      restoreGear: (g) => gear = g,
      now: () => clock,
    );
  });

  void advance(int ms) => clock = clock.add(Duration(milliseconds: ms));

  group('two shifters', () {
    test('only the shift buttons have their long press claimed', () {
      expect(input.claimsLongPress(InGameAction.shiftUp), isTrue);
      expect(input.claimsLongPress(InGameAction.shiftDown), isTrue);
      expect(input.claimsLongPress(InGameAction.select), isFalse);
      expect(input.claimsLongPress(null), isFalse);
    });

    test('holding shift down answers too heavy, and nothing is forwarded', () {
      final down = input.intercept(minus, InGameAction.shiftDown, ButtonTrigger.longPress, isKeyDown: true);
      expect(down, isA<Success>());
      expect(answers, [CalibrationRating.tooHeavy]);

      final up = input.intercept(minus, InGameAction.shiftDown, ButtonTrigger.longPress, isKeyDown: false);
      expect(up, isNotNull, reason: 'the release of a claimed hold is consumed too');
      expect(answers, [CalibrationRating.tooHeavy]);
    });

    test('holding shift up answers too light', () {
      input.intercept(plus, InGameAction.shiftUp, ButtonTrigger.longPress, isKeyDown: true);
      expect(answers, [CalibrationRating.tooLight]);
    });

    test('a short press still shifts', () {
      expect(input.intercept(plus, InGameAction.shiftUp, ButtonTrigger.singleClick, isKeyDown: true), isNull);
      advance(400);
      expect(input.intercept(minus, InGameAction.shiftDown, ButtonTrigger.singleClick, isKeyDown: true), isNull);
      expect(answers, isEmpty);
    });

    test('both shifters at once on one controller answer about right', () {
      final r = input.interceptChord([plus, minus], [InGameAction.shiftUp, InGameAction.shiftDown]);
      expect(r, isNotNull);
      expect(answers, [CalibrationRating.aboutRight]);
    });

    test('both shifters on two separate halves answer about right and undo the first shift', () {
      // The first half's shift has already gone through by the time the
      // second arrives.
      expect(input.intercept(plus, InGameAction.shiftUp, ButtonTrigger.singleClick, isKeyDown: true), isNull);
      gear = 13;
      advance(60);
      final second = input.intercept(minus, InGameAction.shiftDown, ButtonTrigger.singleClick, isKeyDown: true);
      expect(second, isNotNull, reason: 'the second shift is not forwarded');
      expect(answers, [CalibrationRating.aboutRight]);
      expect(gear, 12, reason: 'the gear goes back to where it was before the chord');
    });

    test('a dedicated front-shift button still shifts the chainring', () {
      // The both-shifters chord is caught before the front-shift combo can
      // turn it into a chainring change, so a front shift that does arrive
      // comes from its own button and is the rider picking a gear.
      expect(input.intercept(plus, InGameAction.frontShift, ButtonTrigger.singleClick, isKeyDown: true), isNull);
      expect(answers, isEmpty);
    });

    test('the second half of a chord after the window is just a shift', () {
      input.intercept(plus, InGameAction.shiftUp, ButtonTrigger.singleClick, isKeyDown: true);
      advance(CalibrationControllerInput.chordWindow.inMilliseconds + 50);
      expect(input.intercept(minus, InGameAction.shiftDown, ButtonTrigger.singleClick, isKeyDown: true), isNull);
      expect(answers, isEmpty);
    });

    test('a chord of anything but the two shifters is left alone', () {
      expect(input.interceptChord([plus, nav], [InGameAction.shiftUp, InGameAction.uturn]), isNull);
      expect(answers, isEmpty);
    });
  });

  group('navigation buttons', () {
    test('left, select and right answer directly and are not forwarded', () {
      expect(input.intercept(nav, InGameAction.navigateLeft, ButtonTrigger.singleClick, isKeyDown: true), isNotNull);
      advance(1000);
      expect(input.intercept(nav, InGameAction.select, ButtonTrigger.singleClick, isKeyDown: true), isNotNull);
      advance(1000);
      expect(input.intercept(nav, InGameAction.navigateRight, ButtonTrigger.singleClick, isKeyDown: true), isNotNull);
      expect(answers, [CalibrationRating.tooHeavy, CalibrationRating.aboutRight, CalibrationRating.tooLight]);
    });

    test('a held navigation button repeating does not ratchet the difficulty', () {
      for (var i = 0; i < 4; i++) {
        input.intercept(nav, InGameAction.navigateLeft, ButtonTrigger.singleClick, isKeyDown: true);
        advance(250);
      }
      expect(answers, [CalibrationRating.tooHeavy]);
    });

    test('anything else passes through untouched', () {
      expect(input.intercept(nav, InGameAction.uturn, ButtonTrigger.singleClick, isKeyDown: true), isNull);
      expect(input.intercept(nav, null, ButtonTrigger.singleClick, isKeyDown: true), isNull);
      expect(answers, isEmpty);
    });
  });
}
