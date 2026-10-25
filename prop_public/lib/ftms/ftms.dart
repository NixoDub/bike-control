/// The Bluetooth SIG Fitness Machine Service (FTMS) as far as a trainer bridge
/// needs it: the feature flags a machine reports, the Control Point opcodes
/// and their results, and builders for the frames both ends exchange.
library;

import 'dart:typed_data';

/// Fitness Machine Feature bits (the first uint32 of characteristic 0x2ACC).
enum MachineFeatureFlag {
  averageSpeedSupported,
  cadenceSupported,
  totalDistanceSupported,
  inclinationSupported,
  elevationGainSupported,
  paceSupported,
  stepCountSupported,
  resistanceLevelSupported,
  strideCountSupported,
  expendedEnergySupported,
  heartRateMeasurementSupported,
  metabolicEquivalentSupported,
  elapsedTimeSupported,
  remainingTimeSupported,
  powerMeasurementSupported,
  forceOnBeltAndPowerOutputSupported,
  userDataRetentionSupported,
}

/// Target Setting Feature bits (the second uint32 of characteristic 0x2ACC):
/// which targets the machine can be told to hold.
enum TargetSettingFlag {
  speedTargetSettingFlag,
  inclinationTargetSettingFlag,
  resistanceTargetSettingFlag,
  powerTargetSettingFlag,
  heartRateTargetSettingFlag,
  targetedExpendedEnergyConfigurationSettingFlag,
  targetedStepNumberConfigurationSettingFlag,
  targetedStrideNumberConfigurationSettingFlag,
  targetedDistanceConfigurationSettingFlag,
  targetedTrainingTimeConfigurationSettingFlag,
  targetedTimeInTwoHeartRateZonesConfigurationSettingFlag,
  targetedTimeInThreeHeartRateZonesConfigurationSettingFlag,
  targetedTimeInFiveHeartRateZonesConfigurationSettingFlag,
  indoorBikeSimulationParametersSettingFlag,
  wheelCircumferenceConfigurationSettingFlag,
  spinDownControlSettingFlag,
  targetedCadenceConfigurationSettingFlag,
}

/// What a fitness machine says it can do: the 8 bytes of characteristic 0x2ACC,
/// the machine features then the target settings, each a little-endian uint32.
class MachineFeature {
  MachineFeature(List<int> bytes)
    : machineFeatureBits = bytes.length >= 4 ? _u32(bytes, 0) : 0,
      targetSettingBits = bytes.length >= 8 ? _u32(bytes, 4) : 0;

  final int machineFeatureBits;
  final int targetSettingBits;

  /// The 8 bytes for the given flags.
  static Uint8List build({
    Set<MachineFeatureFlag> machineFeatures = const {},
    Set<TargetSettingFlag> targetSettings = const {},
  }) {
    var features = 0;
    for (final flag in machineFeatures) {
      features |= 1 << flag.index;
    }
    var targets = 0;
    for (final flag in targetSettings) {
      targets |= 1 << flag.index;
    }
    return Uint8List(8)
      ..buffer.asByteData().setUint32(0, features, Endian.little)
      ..buffer.asByteData().setUint32(4, targets, Endian.little);
  }

  Set<MachineFeatureFlag> get machineFeatures => {
    for (final flag in MachineFeatureFlag.values)
      if (machineFeatureBits & (1 << flag.index) != 0) flag,
  };

  Set<TargetSettingFlag> get targetSettings => {
    for (final flag in TargetSettingFlag.values)
      if (targetSettingBits & (1 << flag.index) != 0) flag,
  };

  bool supports(TargetSettingFlag flag) => targetSettingBits & (1 << flag.index) != 0;

  bool has(MachineFeatureFlag flag) => machineFeatureBits & (1 << flag.index) != 0;

  /// The names of the set flags, for a support bundle.
  List<String> get machineFeatureNames => [for (final f in machineFeatures) f.name];

  List<String> get targetSettingNames => [for (final f in targetSettings) f.name];

  @override
  String toString() => 'MachineFeature(features: $machineFeatureNames, targets: $targetSettingNames)';

  static int _u32(List<int> b, int o) => b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
}

/// Fitness Machine Control Point opcodes (characteristic 0x2AD9).
abstract final class FtmsOpcode {
  static const int requestControl = 0x00;
  static const int reset = 0x01;
  static const int setTargetSpeed = 0x02;
  static const int setTargetInclination = 0x03;
  static const int setTargetResistance = 0x04;
  static const int setTargetPower = 0x05;
  static const int setTargetHeartRate = 0x06;
  static const int startOrResume = 0x07;
  static const int stopOrPause = 0x08;
  static const int setIndoorBikeSimulation = 0x11;
  static const int setWheelCircumference = 0x12;
  static const int spinDownControl = 0x13;
  static const int setTargetCadence = 0x14;

  /// The first byte of every Control Point indication.
  static const int responseCode = 0x80;
}

/// The result of a Control Point request.
abstract final class FtmsResult {
  static const int success = 0x01;
  static const int opCodeNotSupported = 0x02;
  static const int invalidParameter = 0x03;
  static const int operationFailed = 0x04;
  static const int controlNotPermitted = 0x05;
}

/// Fitness Machine Status opcodes (characteristic 0x2ADA).
abstract final class FtmsStatus {
  static const int reset = 0x01;
  static const int stoppedOrPaused = 0x02;
  static const int startedOrResumed = 0x04;
  static const int targetResistanceChanged = 0x07;
  static const int targetPowerChanged = 0x08;
  static const int indoorBikeSimulationChanged = 0x12;
}

/// The parameters of a Set Indoor Bike Simulation Parameters request.
class BikeSimulation {
  const BikeSimulation({
    this.windSpeedMps = 0,
    required this.gradePercent,
    this.rollingResistance = 0.004,
    this.windResistanceKgPerM = 0.51,
  });

  /// Headwind in m/s (negative is a tailwind).
  final double windSpeedMps;

  /// Slope in percent.
  final double gradePercent;

  /// Coefficient of rolling resistance (Crr).
  final double rollingResistance;

  /// Wind resistance coefficient in kg/m, `0.5 · rho · CdA`.
  final double windResistanceKgPerM;

  /// Parses the five parameter bytes after the opcode: wind (sint16, 0.001
  /// m/s), grade (sint16, 0.01 %), Crr (uint8, 0.0001), Cw (uint8, 0.01 kg/m).
  /// Null when there are too few bytes.
  static BikeSimulation? parse(List<int> parameters) {
    if (parameters.length < 6) return null;
    final view = ByteData.sublistView(Uint8List.fromList(parameters.sublist(0, 6)));
    return BikeSimulation(
      windSpeedMps: view.getInt16(0, Endian.little) / 1000,
      gradePercent: view.getInt16(2, Endian.little) / 100,
      rollingResistance: view.getUint8(4) / 10000,
      windResistanceKgPerM: view.getUint8(5) / 100,
    );
  }

  /// The request bytes for these parameters, opcode included.
  Uint8List toRequest() {
    final out = Uint8List(7);
    final view = out.buffer.asByteData();
    out[0] = FtmsOpcode.setIndoorBikeSimulation;
    view.setInt16(1, (windSpeedMps * 1000).round().clamp(-32768, 32767), Endian.little);
    view.setInt16(3, (gradePercent * 100).round().clamp(-32768, 32767), Endian.little);
    out[5] = (rollingResistance * 10000).round().clamp(0, 255);
    out[6] = (windResistanceKgPerM * 100).round().clamp(0, 255);
    return out;
  }
}

/// The request bytes for a Set Target Power of [watts].
Uint8List ftmsSetTargetPower(int watts) {
  final out = Uint8List(3);
  out[0] = FtmsOpcode.setTargetPower;
  out.buffer.asByteData().setInt16(1, watts.clamp(-32768, 32767), Endian.little);
  return out;
}

/// The request bytes for a Set Target Resistance Level; [level] is in the
/// unitless 0.1 steps the Control Point uses.
Uint8List ftmsSetTargetResistance(int level) => Uint8List.fromList([FtmsOpcode.setTargetResistance, level.clamp(0, 255)]);

/// The indication a machine sends for a Control Point request.
Uint8List ftmsResponse(int requestOpcode, int result) =>
    Uint8List.fromList([FtmsOpcode.responseCode, requestOpcode, result]);

/// Heart Rate Measurement (0x2A37): flag bit 0 says whether the rate is 8 or 16
/// bits wide.
int? parseHeartRateMeasurement(Uint8List b) {
  if (b.length < 2) return null;
  if (b[0] & 0x01 == 0) return b[1];
  return b.length >= 3 ? b[1] | (b[2] << 8) : null;
}

/// Cycling Power Measurement (0x2A63): flags (16 bit), then the instantaneous
/// power as a signed 16-bit watts value.
int? parseCyclingPowerWatts(Uint8List b) {
  if (b.length < 4) return null;
  return ByteData.sublistView(b).getInt16(2, Endian.little);
}

/// What an Indoor Bike Data frame (0x2AD2) carries of the riding values.
typedef IndoorBikeReading = ({double? speedKph, int? cadenceRpm, int? powerW, int? heartRateBpm});

/// Indoor Bike Data (0x2AD2). The 16-bit flags say which fields follow, in a
/// fixed order; bit 0 is inverted (set means the speed is *absent*).
IndoorBikeReading parseIndoorBikeDataFrame(Uint8List b) {
  if (b.length < 2) return (speedKph: null, cadenceRpm: null, powerW: null, heartRateBpm: null);
  final view = ByteData.sublistView(b);
  final flags = view.getUint16(0, Endian.little);
  var offset = 2;
  double? speed;
  int? cadence;
  int? power;
  int? heartRate;

  bool has(int bytes) => offset + bytes <= b.length;

  if (flags & 0x0001 == 0 && has(2)) {
    speed = view.getUint16(offset, Endian.little) / 100;
    offset += 2;
  }
  if (flags & 0x0002 != 0 && has(2)) offset += 2; // average speed
  if (flags & 0x0004 != 0 && has(2)) {
    cadence = (view.getUint16(offset, Endian.little) / 2).round();
    offset += 2;
  }
  if (flags & 0x0008 != 0 && has(2)) offset += 2; // average cadence
  if (flags & 0x0010 != 0 && has(3)) offset += 3; // total distance
  if (flags & 0x0020 != 0 && has(2)) offset += 2; // resistance level
  if (flags & 0x0040 != 0 && has(2)) {
    power = view.getInt16(offset, Endian.little);
    offset += 2;
  }
  if (flags & 0x0080 != 0 && has(2)) offset += 2; // average power
  if (flags & 0x0100 != 0 && has(5)) offset += 5; // expended energy
  if (flags & 0x0200 != 0 && has(1)) {
    heartRate = b[offset];
    offset += 1;
  }
  return (speedKph: speed, cadenceRpm: cadence, powerW: power, heartRateBpm: heartRate);
}

/// An Indoor Bike Data frame with the given values: speed (0.01 km/h),
/// cadence (0.5 rpm), power (watts), and heart rate when known.
Uint8List buildIndoorBikeData({
  required double speedKph,
  required int cadenceRpm,
  required int powerW,
  int? heartRateBpm,
}) {
  final flags = 0x0044 | (heartRateBpm != null ? 0x0200 : 0);
  final out = Uint8List(heartRateBpm != null ? 9 : 8);
  final view = out.buffer.asByteData();
  view.setUint16(0, flags, Endian.little);
  view.setUint16(2, (speedKph * 100).round().clamp(0, 0xFFFF), Endian.little);
  view.setUint16(4, (cadenceRpm * 2).clamp(0, 0xFFFF), Endian.little);
  view.setInt16(6, powerW.clamp(-32768, 32767), Endian.little);
  if (heartRateBpm != null) out[8] = heartRateBpm.clamp(0, 255);
  return out;
}
