import 'package:flutter_test/flutter_test.dart';
import 'package:prop/utils/vs_physics.dart' as physics;

void main() {
  group('gear ratios', () {
    test('run from the low gear to the high one in rising steps', () {
      final ratios = physics.defaultGearRatiosFor(24);
      expect(ratios, hasLength(24));
      expect(ratios.first, 0.75);
      expect(ratios.last, 5.0);
      for (var i = 1; i < ratios.length; i++) {
        expect(ratios[i], greaterThan(ratios[i - 1]));
      }
    });

    test('are in even geometric steps', () {
      final ratios = physics.defaultGearRatiosFor(13);
      final first = ratios[1] / ratios[0];
      for (var i = 2; i < ratios.length; i++) {
        expect(ratios[i] / ratios[i - 1], closeTo(first, 0.02));
      }
    });

    test('put the middle gear near the chain ratio the maths assumes', () {
      for (final count in [13, 24, 30]) {
        final ratios = physics.defaultGearRatiosFor(count);
        final middle = ratios[physics.neutralGearFor(count) - 1];
        expect(middle, inInclusiveRange(1.5, 2.6), reason: '$count gears');
      }
    });

    test('cope with a single gear and with none', () {
      expect(physics.defaultGearRatiosFor(1), [physics.kAssumedChainRatio]);
      expect(physics.defaultGearRatiosFor(0), isEmpty);
    });

    test('the neutral gear is the middle one, and never below the first', () {
      expect(physics.neutralGearFor(24), 12);
      expect(physics.neutralGearFor(30), 15);
      expect(physics.neutralGearFor(1), 1);
      expect(physics.neutralGearFor(2), 1);
    });
  });

  group('speed and resistance', () {
    test('a faster cadence or a bigger gear is a higher speed', () {
      final base = physics.virtualSpeedMps(cadenceRpm: 90, gearRatio: 2);
      expect(physics.virtualSpeedMps(cadenceRpm: 100, gearRatio: 2), greaterThan(base));
      expect(physics.virtualSpeedMps(cadenceRpm: 90, gearRatio: 3), greaterThan(base));
      expect(physics.virtualSpeedMps(cadenceRpm: 0, gearRatio: 3), 0);
    });

    test('speed follows one rev, one gear ratio, one wheel turn', () {
      // 60 rpm in a 1:1 gear is one wheel circumference per second.
      expect(physics.virtualSpeedMps(cadenceRpm: 60, gearRatio: 1), closeTo(physics.kWheelCircumferenceMeters, 1e-9));
    });

    test('the resistive force grows with the slope and with speed', () {
      double force(double speed, double grade) =>
          physics.resistiveForceN(speedMps: speed, gradePercent: grade, massKg: 80);
      expect(force(8, 8), greaterThan(force(8, 0)));
      expect(force(12, 0), greaterThan(force(6, 0)));
      expect(force(8, -5), lessThan(force(8, 0)));
    });

    test('on the flat at 8 m/s an 80 kg rider needs about 150-170 W', () {
      final watts = physics.targetPowerFor(cadenceRpm: 90, gearRatio: 2.2, gradePercent: 0, massKg: 80);
      // 90 rpm * 2.2 * 2.199 m = 7.26 m/s; rolling ~31 N + air ~27 N.
      expect(watts, inInclusiveRange(150, 330));
    });

    test('target power rises with the gear, the slope and the cadence, and never goes negative', () {
      double power({double cadence = 90, double ratio = 2, double grade = 0}) =>
          physics.targetPowerFor(cadenceRpm: cadence, gearRatio: ratio, gradePercent: grade, massKg: 80);
      expect(power(ratio: 3), greaterThan(power(ratio: 2)));
      expect(power(grade: 6), greaterThan(power(grade: 0)));
      expect(power(cadence: 100), greaterThan(power(cadence: 80)));
      expect(power(cadence: 0), 0);
      expect(power(grade: -15, ratio: 0.8, cadence: 40), greaterThanOrEqualTo(0));
    });

    test('an off-the-chart hill is a big number, not an error', () {
      final watts = physics.targetPowerFor(cadenceRpm: 120, gearRatio: 5, gradePercent: 30, massKg: 90);
      expect(watts, greaterThan(500));
      expect(watts.isFinite, isTrue);
    });
  });

  group('track resistance', () {
    double grade({double ratio = 2, double slope = 4, double cadence = 90, double difficulty = 1}) =>
        physics.trackResistanceGrade(
          cadenceRpm: cadence,
          gearRatio: ratio,
          gradePercent: slope,
          massKg: 80,
          difficulty: difficulty,
        );

    test('a bigger gear asks the trainer for a steeper slope, a smaller one for less', () {
      expect(grade(ratio: 3.5), greaterThan(grade(ratio: 2)));
      expect(grade(ratio: 1), lessThan(grade(ratio: 2)));
    });

    test('in the gear the maths assumes, the slope comes back nearly unchanged', () {
      expect(grade(ratio: physics.kAssumedChainRatio, slope: 5), closeTo(5, 0.6));
    });

    test('is held inside what a trainer can simulate', () {
      expect(grade(ratio: 5, slope: 25, cadence: 130), physics.kMaxSimGradePercent);
      expect(grade(ratio: 0.5, slope: -20, cadence: 40), greaterThanOrEqualTo(physics.kMinSimGradePercent));
    });

    test('the difficulty scales the resistance', () {
      expect(grade(difficulty: 1.5), greaterThan(grade()));
      expect(grade(difficulty: 0.5), lessThan(grade()));
    });
  });

  group('chain ratio estimate', () {
    test('recovers the ratio from speed and cadence', () {
      final speed = physics.virtualSpeedMps(cadenceRpm: 64, gearRatio: 4.5) * 3.6;
      expect(physics.estimateChainRatio(speedKph: speed, cadenceRpm: 64), closeTo(4.5, 1e-6));
    });

    test('says nothing for a rider who is barely pedalling or stopped', () {
      expect(physics.estimateChainRatio(speedKph: 20, cadenceRpm: 30), isNull);
      expect(physics.estimateChainRatio(speedKph: 0, cadenceRpm: 90), isNull);
    });
  });
}
