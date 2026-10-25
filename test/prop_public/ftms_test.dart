import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prop/ftms/ftms.dart';

void main() {
  group('MachineFeature', () {
    test('round-trips its flags through the 8 bytes', () {
      final bytes = MachineFeature.build(
        machineFeatures: {MachineFeatureFlag.cadenceSupported, MachineFeatureFlag.powerMeasurementSupported},
        targetSettings: {TargetSettingFlag.powerTargetSettingFlag, TargetSettingFlag.indoorBikeSimulationParametersSettingFlag},
      );
      expect(bytes.length, 8);
      final feature = MachineFeature(bytes);
      expect(feature.machineFeatures, {MachineFeatureFlag.cadenceSupported, MachineFeatureFlag.powerMeasurementSupported});
      expect(feature.supports(TargetSettingFlag.powerTargetSettingFlag), isTrue);
      expect(feature.supports(TargetSettingFlag.indoorBikeSimulationParametersSettingFlag), isTrue);
      expect(feature.supports(TargetSettingFlag.resistanceTargetSettingFlag), isFalse);
    });

    test('puts each flag on the bit the specification gives it', () {
      // Cadence is bit 1, power measurement bit 14; power target is bit 3 and
      // the indoor bike simulation bit 13 of the second word.
      final bytes = MachineFeature.build(
        machineFeatures: {MachineFeatureFlag.cadenceSupported, MachineFeatureFlag.powerMeasurementSupported},
        targetSettings: {TargetSettingFlag.powerTargetSettingFlag, TargetSettingFlag.indoorBikeSimulationParametersSettingFlag},
      );
      final view = bytes.buffer.asByteData();
      expect(view.getUint32(0, Endian.little), (1 << 1) | (1 << 14));
      expect(view.getUint32(4, Endian.little), (1 << 3) | (1 << 13));
    });

    test('reads a real trainer\'s feature bytes', () {
      // A KICKR reports cadence, power, resistance and HR; targets resistance,
      // power and simulation: 0x0000_4482 / 0x0000_200C.
      final feature = MachineFeature([0x82, 0x44, 0x00, 0x00, 0x0C, 0x20, 0x00, 0x00]);
      expect(feature.has(MachineFeatureFlag.cadenceSupported), isTrue);
      expect(feature.has(MachineFeatureFlag.resistanceLevelSupported), isTrue);
      expect(feature.has(MachineFeatureFlag.powerMeasurementSupported), isTrue);
      expect(feature.supports(TargetSettingFlag.resistanceTargetSettingFlag), isTrue);
      expect(feature.supports(TargetSettingFlag.powerTargetSettingFlag), isTrue);
      expect(feature.supports(TargetSettingFlag.indoorBikeSimulationParametersSettingFlag), isTrue);
    });

    test('a short read means nothing is supported, not a crash', () {
      final feature = MachineFeature([1, 2]);
      expect(feature.machineFeatures, isEmpty);
      expect(feature.targetSettings, isEmpty);
    });

    test('names the set flags for a support bundle', () {
      final feature = MachineFeature(MachineFeature.build(targetSettings: {TargetSettingFlag.powerTargetSettingFlag}));
      expect(feature.targetSettingNames, ['powerTargetSettingFlag']);
    });
  });

  group('Control Point frames', () {
    test('a simulation request is the opcode, wind, grade, crr and cw', () {
      final bytes = const BikeSimulation(gradePercent: 4.5, windSpeedMps: -1.2, rollingResistance: 0.004, windResistanceKgPerM: 0.51)
          .toRequest();
      expect(bytes[0], 0x11);
      final view = bytes.buffer.asByteData();
      expect(view.getInt16(1, Endian.little), -1200);
      expect(view.getInt16(3, Endian.little), 450);
      expect(bytes[5], 40);
      expect(bytes[6], 51);
    });

    test('a simulation request parses back, negative grade included', () {
      final sim = BikeSimulation.parse(const BikeSimulation(gradePercent: -7.25).toRequest().sublist(1))!;
      expect(sim.gradePercent, closeTo(-7.25, 1e-9));
      expect(sim.rollingResistance, closeTo(0.004, 1e-9));
    });

    test('a simulation request that is too short does not parse', () {
      expect(BikeSimulation.parse([1, 2, 3]), isNull);
    });

    test('a grade is clamped to what 16 bits can carry', () {
      final bytes = const BikeSimulation(gradePercent: 9999).toRequest();
      expect(bytes.buffer.asByteData().getInt16(3, Endian.little), 32767);
    });

    test('target power and resistance requests', () {
      expect(ftmsSetTargetPower(250), [0x05, 0xFA, 0x00]);
      expect(ftmsSetTargetPower(-1), [0x05, 0xFF, 0xFF]);
      expect(ftmsSetTargetResistance(40), [0x04, 40]);
      expect(ftmsSetTargetResistance(999), [0x04, 255]);
    });

    test('a response is 0x80, the request opcode, the result', () {
      expect(ftmsResponse(FtmsOpcode.setTargetPower, FtmsResult.success), [0x80, 0x05, 0x01]);
    });
  });

  group('measurement frames', () {
    test('an indoor bike data frame reads back what built it', () {
      final bytes = buildIndoorBikeData(speedKph: 31.4, cadenceRpm: 92, powerW: 287, heartRateBpm: 151);
      final reading = parseIndoorBikeDataFrame(bytes);
      expect(reading.speedKph, closeTo(31.4, 0.01));
      expect(reading.cadenceRpm, 92);
      expect(reading.powerW, 287);
      expect(reading.heartRateBpm, 151);
    });

    test('without a heart rate the frame is shorter and says nothing of it', () {
      final bytes = buildIndoorBikeData(speedKph: 20, cadenceRpm: 80, powerW: 200);
      expect(bytes.length, 8);
      expect(parseIndoorBikeDataFrame(bytes).heartRateBpm, isNull);
    });
  });
}
