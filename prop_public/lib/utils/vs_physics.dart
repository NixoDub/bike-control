/// The physics behind virtual shifting, as pure functions.
///
/// A rider in a given gear at a given cadence would be going a certain speed;
/// at that speed on the slope the game reports, a certain force resists them.
/// The bridge reproduces that resistance on the trainer, by asking for the
/// matching power (target power) or the matching slope (track resistance).
library;

import 'dart:math' as math;

const double kGravity = 9.80665;

/// Share of the pedalling power that reaches the road.
const double kDrivetrainEfficiency = 0.975;

/// Rolling circumference of a 700c wheel; speed and chain-ratio estimates agree
/// on it.
final double kWheelCircumferenceMeters = 0.7 * math.pi;

/// The chain ratio the track-resistance maths assumes the rider's real chain is
/// on: flywheel speed over cadence for a mid-cassette gear.
const double kAssumedChainRatio = 2.0;

/// Slope limits a trainer's simulation can be asked for.
const double kMinSimGradePercent = -15;
const double kMaxSimGradePercent = 20;

/// [count] gear ratios from a low climbing gear to a high sprinting one, in even
/// geometric steps (each gear is the same percentage faster than the last),
/// rounded to two decimals. The middle gear lands near [kAssumedChainRatio].
List<double> defaultGearRatiosFor(int count, {double lowest = 0.75, double highest = 5.49}) {
  if (count <= 0) return const [];
  if (count == 1) return [kAssumedChainRatio];
  final step = math.pow(highest / lowest, 1 / (count - 1)).toDouble();
  return [
    for (var i = 0; i < count; i++) double.parse((lowest * math.pow(step, i)).toStringAsFixed(2)),
  ];
}

/// The gear a rider in the middle of [maxGear] gears starts in.
int neutralGearFor(int maxGear) => math.max(1, maxGear ~/ 2);

/// Speed in m/s of a rider turning the cranks at [cadenceRpm] in a gear whose
/// ratio is [gearRatio].
double virtualSpeedMps({required double cadenceRpm, required double gearRatio}) =>
    cadenceRpm / 60 * gearRatio * kWheelCircumferenceMeters;

/// The force in newtons that resists a rider of total mass [massKg] at
/// [speedMps] on a slope of [gradePercent]: gravity along the slope, rolling
/// resistance, and air resistance against the apparent wind.
double resistiveForceN({
  required double speedMps,
  required double gradePercent,
  required double massKg,
  double rollingResistance = 0.004,
  double windResistanceKgPerM = 0.51,
  double windSpeedMps = 0,
}) {
  final theta = math.atan(gradePercent / 100);
  final gravityAndRolling = massKg * kGravity * (math.sin(theta) + rollingResistance * math.cos(theta));
  final apparentWind = speedMps + windSpeedMps;
  final air = windResistanceKgPerM * apparentWind * apparentWind.abs();
  return gravityAndRolling + air;
}

/// The power in watts needed to keep [speedMps] against [forceN].
double powerForForceW(double forceN, double speedMps) => math.max(0, forceN * speedMps / kDrivetrainEfficiency);

/// The target power for virtual shifting in target-power mode.
double targetPowerFor({
  required double cadenceRpm,
  required double gearRatio,
  required double gradePercent,
  required double massKg,
  double rollingResistance = 0.004,
  double windResistanceKgPerM = 0.51,
  double windSpeedMps = 0,
}) {
  final speed = virtualSpeedMps(cadenceRpm: cadenceRpm, gearRatio: gearRatio);
  final force = resistiveForceN(
    speedMps: speed,
    gradePercent: gradePercent,
    massKg: massKg,
    rollingResistance: rollingResistance,
    windResistanceKgPerM: windResistanceKgPerM,
    windSpeedMps: windSpeedMps,
  );
  return powerForForceW(force, speed);
}

/// The slope to ask the trainer to simulate, in track-resistance mode, so that
/// *its* resistance equals what the rider would feel in [gearRatio] on
/// [gradePercent].
///
/// The trainer works out its resistance from its own speed, which follows the
/// rider's real chain, assumed to be on [kAssumedChainRatio]; what the trainer's
/// air resistance does not already supply is made up in slope.
double trackResistanceGrade({
  required double cadenceRpm,
  required double gearRatio,
  required double gradePercent,
  required double massKg,
  double rollingResistance = 0.004,
  double windResistanceKgPerM = 0.51,
  double windSpeedMps = 0,
  double difficulty = 1,
}) {
  final wanted = difficulty * resistiveForceN(
    speedMps: virtualSpeedMps(cadenceRpm: cadenceRpm, gearRatio: gearRatio),
    gradePercent: gradePercent,
    massKg: massKg,
    rollingResistance: rollingResistance,
    windResistanceKgPerM: windResistanceKgPerM,
    windSpeedMps: windSpeedMps,
  );
  final trainerSpeed = virtualSpeedMps(cadenceRpm: cadenceRpm, gearRatio: kAssumedChainRatio);
  final trainerAir = windResistanceKgPerM * trainerSpeed * trainerSpeed;
  final x = (wanted - trainerAir) / (massKg * kGravity);
  final first = math.asin(x.clamp(-1.0, 1.0));
  final theta = math.asin((x - rollingResistance * math.cos(first)).clamp(-1.0, 1.0));
  return (100 * math.tan(theta)).clamp(kMinSimGradePercent, kMaxSimGradePercent).toDouble();
}

/// The chain ratio a rider's real chain is on, from the trainer's own speed and
/// the cadence; null when either is too low to say.
double? estimateChainRatio({required double speedKph, required double cadenceRpm}) {
  if (cadenceRpm < 40 || speedKph <= 0) return null;
  return (speedKph / 3.6) / (cadenceRpm / 60 * kWheelCircumferenceMeters);
}
