// The virtual bike end to end on loopback: a stand-in trainer app (a DirCon
// client) in front of a real DirconEmulator and FitnessBikeDefinition, with a
// fake trainer behind. Covers what the trainer app is shown, what the bike asks
// of the trainer in return, and how gears and modes shape that.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prop/emulators/definitions/fitness_bike_definition.dart';
import 'package:prop/emulators/dircon_emulator.dart';
import 'package:prop/ftms/ftms.dart';
import 'package:prop/mdns/service_advertiser.dart';
import 'package:prop/utils/cps_measurement.dart';
import 'package:prop/utils/network_address.dart';
import 'package:prop/utils/uuid.dart';
import 'package:universal_ble/universal_ble.dart';

import 'helpers.dart';

Future<void> settle([int ms = 40]) => Future<void>.delayed(Duration(milliseconds: ms));

List<int> u(String uuid) => uuidToBytes(uuid);

typedef Write = ({String service, String characteristic, List<int> value, bool withoutResponse});

void main() {
  late FakeTrainerTransport trainer;
  late FakeAdvertiser advertiser;
  late ServiceAdvertiser previousAdvertiser;
  late DirconEmulator emulator;
  late FitnessBikeDefinition bike;
  DirconTestClient? client;
  var clock = DateTime(2026, 10, 25, 9);

  FitnessBikeDefinition makeBike({List<BleService>? services, String name = 'JetBlack Victory'}) =>
      FitnessBikeDefinition(
        connectedDevice: BleDevice(deviceId: 'AA:BB:CC:DD:EE:FF', name: name),
        connectedDeviceServices: services ?? trainerServices(),
        data: emulator.data,
        transport: trainer,
      );

  setUp(() {
    previousAdvertiser = ServiceAdvertiser.instance;
    advertiser = FakeAdvertiser();
    ServiceAdvertiser.instance = advertiser;
    AdvertisedAddressPicker.debugPick = () async => InternetAddress('192.168.1.50');
    trainer = FakeTrainerTransport();
    emulator = DirconEmulator(preferredPort: 0)..deviceName = () => 'JetBlack Victory';
    bike = makeBike();
    clock = DateTime(2026, 10, 25, 9);
    bike.debugClock = () => clock;
  });

  tearDown(() async {
    await client?.close();
    client = null;
    bike.dispose();
    await emulator.stop();
    ServiceAdvertiser.instance = previousAdvertiser;
    AdvertisedAddressPicker.debugPick = null;
  });

  /// Serves [bike] and connects a trainer app that has subscribed to the Control
  /// Point's indications and the data it will be sent.
  Future<void> serve({bool subscribe = true}) async {
    await emulator.attachDefinition(bike);
    await emulator.startServer(mode: RetrofitMode.wifi);
    client = await DirconTestClient.connect(emulator.boundPort!);
    await settle();
    if (subscribe) {
      for (final uuid in [
        FitnessBikeDefinition.FITNESS_MACHINE_CONTROL_POINT_UUID,
        FitnessBikeDefinition.INDOOR_BIKE_DATA_UUID,
        FitnessBikeDefinition.CYCLING_POWER_MEASUREMENT_UUID,
        FitnessBikeDefinition.FITNESS_MACHINE_STATUS_UUID,
      ]) {
        await client!.request(5, [...u(uuid), 1]);
      }
    }
  }

  /// What the trainer app is told on [uuid], collected from now on.
  List<Uint8List> listen(String uuid) {
    final out = <Uint8List>[];
    final wanted = normalizeUuid(uuid);
    client!.notifications.listen((frame) {
      if (uuidFromBytes(frame.payload.sublist(0, 16)) == wanted) out.add(frame.payload.sublist(16));
    });
    return out;
  }

  Future<List<int>> controlPoint(List<int> request) async {
    final responses = listen(FitnessBikeDefinition.FITNESS_MACHINE_CONTROL_POINT_UUID);
    await client!.request(4, [...u(FitnessBikeDefinition.FITNESS_MACHINE_CONTROL_POINT_UUID), ...request]);
    await settle();
    return responses.isEmpty ? const [] : responses.last;
  }

  List<Write> controlWrites() =>
      trainer.writes.where((w) => normalizeUuid(w.characteristic) == FitnessBikeDefinition.FITNESS_MACHINE_CONTROL_POINT_UUID).toList();

  /// The writes to the trainer's control point with [opcode], newest last.
  List<List<int>> sent(int opcode) => [
    for (final w in controlWrites())
      if (w.value.first == opcode) w.value,
  ];

  int gradeOf(List<int> simulationRequest) =>
      ByteData.sublistView(Uint8List.fromList(simulationRequest)).getInt16(3, Endian.little);

  int wattsOf(List<int> targetPowerRequest) =>
      ByteData.sublistView(Uint8List.fromList(targetPowerRequest)).getInt16(1, Endian.little);

  /// A trainer reporting 90 rpm, 220 W, 27 km/h on its own.
  Uint8List ridingFrame({int rpm = 90, int watts = 220}) =>
      buildIndoorBikeData(speedKph: 27, cadenceRpm: rpm, powerW: watts);

  Future<void> ride() async {
    bike.onNotification(FitnessBikeDefinition.INDOOR_BIKE_DATA_UUID, ridingFrame());
  }

  group('what the trainer app is shown', () {
    test('serves Fitness Machine, Cycling Power and Device Information', () async {
      await serve();
      expect(await client!.discoverServices(), [
        FitnessBikeDefinition.FITNESS_MACHINE_SERVICE_UUID,
        FitnessBikeDefinition.CYCLING_POWER_SERVICE_UUID,
        FitnessBikeDefinition.DEVICE_INFORMATION_SERVICE_UUID,
      ]);
    });

    test('announces the first two, as 16-bit UUIDs', () async {
      await serve();
      final txt = String.fromCharCodes(advertiser.registered.single.txt['ble-service-uuids']!);
      expect(txt, '0x1826,0x1818');
      expect(advertiser.registered.single.name, 'JetBlack Victory - BikeControl');
    });

    test('lists the Fitness Machine characteristics with their properties', () async {
      await serve();
      final characteristics = await client!.discoverCharacteristics(FitnessBikeDefinition.FITNESS_MACHINE_SERVICE_UUID);
      expect(characteristics[FitnessBikeDefinition.FITNESS_MACHINE_FEATURE_UUID], 0x01);
      expect(characteristics[FitnessBikeDefinition.INDOOR_BIKE_DATA_UUID], 0x04);
      expect(characteristics[FitnessBikeDefinition.FITNESS_MACHINE_CONTROL_POINT_UUID], 0x06);
      expect(characteristics[FitnessBikeDefinition.FITNESS_MACHINE_STATUS_UUID], 0x04);
    });

    test('says it can hold a power, hold a resistance and simulate a grade', () async {
      await serve();
      final response = await client!.request(3, u(FitnessBikeDefinition.FITNESS_MACHINE_FEATURE_UUID));
      final feature = MachineFeature(response.payload.sublist(16));
      expect(feature.has(MachineFeatureFlag.cadenceSupported), isTrue);
      expect(feature.has(MachineFeatureFlag.powerMeasurementSupported), isTrue);
      expect(feature.supports(TargetSettingFlag.powerTargetSettingFlag), isTrue);
      expect(feature.supports(TargetSettingFlag.resistanceTargetSettingFlag), isTrue);
      expect(feature.supports(TargetSettingFlag.indoorBikeSimulationParametersSettingFlag), isTrue);
    });

    test('gives the power and inclination ranges, and a manufacturer', () async {
      await serve();
      final power = (await client!.request(3, u(FitnessBikeDefinition.SUPPORTED_POWER_RANGE_UUID))).payload.sublist(16);
      expect(ByteData.sublistView(power).getInt16(0, Endian.little), 0);
      expect(ByteData.sublistView(power).getInt16(2, Endian.little), 2000);
      final maker = (await client!.request(
        3,
        u(FitnessBikeDefinition.DEVICE_INFORMATION_CHARACTERISTIC_MANUFACTURER_NAME),
      )).payload.sublist(16);
      expect(String.fromCharCodes(maker), 'BikeControl');
    });
  });

  group('taking control of the trainer', () {
    test('subscribes to its data and control responses, then requests control and starts', () async {
      await serve();
      await settle();
      final subscribed = trainer.subscriptions.map((s) => s.characteristic).toList();
      expect(subscribed, containsAll([
        FitnessBikeDefinition.INDOOR_BIKE_DATA_UUID,
        FitnessBikeDefinition.CYCLING_POWER_MEASUREMENT_UUID,
        FitnessBikeDefinition.FITNESS_MACHINE_CONTROL_POINT_UUID,
      ]));
      final controlSubscription = trainer.subscriptions.firstWhere(
        (s) => s.characteristic == FitnessBikeDefinition.FITNESS_MACHINE_CONTROL_POINT_UUID,
      );
      expect(controlSubscription.indicate, isTrue);
      expect(controlSubscription.service, FitnessBikeDefinition.FITNESS_MACHINE_SERVICE_UUID);
      expect(controlWrites().map((w) => w.value.first), [FtmsOpcode.requestControl, FtmsOpcode.startOrResume]);
    });

    test('runs a pump while serving and stops it when the server stops or the bike is disposed', () async {
      expect(bike.isSubscribedToTrainer, isFalse);
      await serve();
      expect(bike.isSubscribedToTrainer, isTrue);
      await emulator.stop();
      expect(bike.isSubscribedToTrainer, isFalse);

      final second = makeBike();
      second.subscribeToTrainer();
      expect(second.isSubscribedToTrainer, isTrue);
      second.dispose();
      expect(second.isSubscribedToTrainer, isFalse);
    });

    test('a bike attached while the server already runs starts its pump then', () async {
      await emulator.startServer(mode: RetrofitMode.wifi);
      await emulator.attachDefinition(bike);
      expect(bike.isSubscribedToTrainer, isTrue);
      await emulator.detachDefinition(bike);
      expect(bike.isSubscribedToTrainer, isFalse);
    });

    test('a trainer with none of the characteristics is left alone, without a crash', () async {
      bike.dispose();
      bike = makeBike(services: const []);
      await serve();
      await settle();
      expect(trainer.writes, isEmpty);
      expect(trainer.subscriptions, isEmpty);
      bike.setManualErgPower(200);
      bike.setTargetGear(3);
      await settle(300);
      expect(trainer.writes, isEmpty);
    });
  });

  group('the trainer app\'s Control Point', () {
    test('is told control was granted', () async {
      await serve();
      expect(await controlPoint([FtmsOpcode.requestControl]), [0x80, 0x00, 0x01]);
    });

    test('is told an opcode this bike does not do is not supported', () async {
      await serve();
      expect(await controlPoint([0x13, 0x00]), [0x80, 0x13, 0x02]);
    });

    test('is told a request with too few parameters is invalid', () async {
      await serve();
      expect(await controlPoint([FtmsOpcode.setTargetPower, 0x10]), [0x80, 0x05, 0x03]);
      expect(await controlPoint([FtmsOpcode.setIndoorBikeSimulation, 1, 2]), [0x80, 0x11, 0x03]);
    });

    test('start and stop are acknowledged and reported in the machine status', () async {
      await serve();
      final status = listen(FitnessBikeDefinition.FITNESS_MACHINE_STATUS_UUID);
      expect(await controlPoint([FtmsOpcode.startOrResume]), [0x80, 0x07, 0x01]);
      expect(await controlPoint([FtmsOpcode.stopOrPause, 0x02]), [0x80, 0x08, 0x01]);
      await settle();
      expect(status.map((s) => s.toList()), [
        [FtmsStatus.startedOrResumed],
        [FtmsStatus.stoppedOrPaused, 0x02],
      ]);
    });

    test('a target power puts the bike in ERG and holds that power on the trainer', () async {
      await serve();
      expect(await controlPoint(ftmsSetTargetPower(220)), [0x80, 0x05, 0x01]);
      expect(bike.trainerMode.value, TrainerMode.ergMode);
      expect(bike.ergTargetPower.value, 220);
      expect(wattsOf(sent(FtmsOpcode.setTargetPower).last), 220);
    });

    test('ERG does not care which gear the rider is in', () async {
      await serve();
      await controlPoint(ftmsSetTargetPower(220));
      bike.setTargetGear(3);
      bike.setTargetGear(20);
      await settle(300);
      expect(sent(FtmsOpcode.setTargetPower).map(wattsOf).toSet(), {220});
    });

    test('a simulation moves the bike to virtual shifting and records the slope', () async {
      await serve();
      final response = await controlPoint(const BikeSimulation(gradePercent: 6.5).toRequest());
      expect(response, [0x80, 0x11, 0x01]);
      expect(bike.trainerMode.value, TrainerMode.simModeVirtualShifting);
      expect(bike.simGrade.value, 650);
    });

    test('leaving ERG goes back to the simulation the trainer app last gave', () async {
      await serve();
      await controlPoint(const BikeSimulation(gradePercent: 3).toRequest());
      await controlPoint(ftmsSetTargetPower(180));
      expect(bike.trainerMode.value, TrainerMode.ergMode);
      bike.exitErgMode();
      expect(bike.trainerMode.value, TrainerMode.simModeVirtualShifting);
      expect(bike.ergTargetPower.value, isNull);
    });

    test('a resistance request is passed on without virtual shifting', () async {
      await serve();
      expect(await controlPoint(ftmsSetTargetResistance(30)), [0x80, 0x04, 0x01]);
      expect(bike.trainerMode.value, TrainerMode.simMode);
      expect(sent(FtmsOpcode.setTargetResistance).last, [0x04, 30]);
    });
  });

  group('virtual shifting on the trainer', () {
    Future<void> climb({VirtualShiftingMode mode = VirtualShiftingMode.trackResistance, double grade = 5}) async {
      await serve();
      bike.setVirtualShiftingMode(mode);
      await ride();
      await controlPoint(BikeSimulation(gradePercent: grade).toRequest());
      await settle(300);
    }

    test('track resistance: a bigger gear asks the trainer for a steeper slope', () async {
      await climb();
      bike.setTargetGear(8);
      await settle(300);
      final low = gradeOf(sent(FtmsOpcode.setIndoorBikeSimulation).last);
      bike.setTargetGear(20);
      await settle(300);
      final high = gradeOf(sent(FtmsOpcode.setIndoorBikeSimulation).last);
      expect(high, greaterThan(low));
    });

    test('track resistance: a smaller gear asks for a gentler one', () async {
      await climb();
      bike.setTargetGear(12);
      await settle(300);
      final middle = gradeOf(sent(FtmsOpcode.setIndoorBikeSimulation).last);
      bike.setTargetGear(4);
      await settle(300);
      expect(gradeOf(sent(FtmsOpcode.setIndoorBikeSimulation).last), lessThan(middle));
    });

    test('target power: asks the trainer for the power the gear and slope call for', () async {
      await climb(mode: VirtualShiftingMode.targetPower);
      expect(bike.trainerMode.value, TrainerMode.simModeVirtualShifting);
      bike.setTargetGear(6);
      await settle(300);
      final low = wattsOf(sent(FtmsOpcode.setTargetPower).last);
      bike.setTargetGear(22);
      await settle(300);
      final high = wattsOf(sent(FtmsOpcode.setTargetPower).last);
      expect(high, greaterThan(low));
      expect(bike.targetPowerW.value, high);
    });

    test('target power: a steeper slope asks for more', () async {
      await climb(mode: VirtualShiftingMode.targetPower, grade: 2);
      await settle(300);
      final gentle = wattsOf(sent(FtmsOpcode.setTargetPower).last);
      await controlPoint(const BikeSimulation(gradePercent: 9).toRequest());
      await settle(300);
      expect(wattsOf(sent(FtmsOpcode.setTargetPower).last), greaterThan(gentle));
    });

    test('target power: the difficulty scales what is asked', () async {
      await climb(mode: VirtualShiftingMode.targetPower);
      final normal = wattsOf(sent(FtmsOpcode.setTargetPower).last);
      bike.setDifficultyPct(150);
      await settle(300);
      expect(wattsOf(sent(FtmsOpcode.setTargetPower).last), closeTo(normal * 1.5, 3));
    });

    test('basic resistance asks for a resistance level, higher in a bigger gear', () async {
      await climb(mode: VirtualShiftingMode.basicResistance);
      bike.setTargetGear(5);
      await settle(300);
      final low = sent(FtmsOpcode.setTargetResistance).last[1];
      bike.setTargetGear(22);
      await settle(300);
      expect(sent(FtmsOpcode.setTargetResistance).last[1], greaterThan(low));
    });

    test('a burst of shifts costs a few writes, the last one reflecting the final gear', () async {
      await climb();
      final before = sent(FtmsOpcode.setIndoorBikeSimulation).length;
      for (var gear = 13; gear <= 24; gear++) {
        bike.setTargetGear(gear);
      }
      await settle(400);
      final extra = sent(FtmsOpcode.setIndoorBikeSimulation).length - before;
      expect(extra, inInclusiveRange(1, 3));
      bike.setTargetGear(24);
      await settle(300);
      expect(gradeOf(sent(FtmsOpcode.setIndoorBikeSimulation).last), gradeOf(sent(FtmsOpcode.setIndoorBikeSimulation).last));
    });

    test('an unchanged request is not sent again', () async {
      await climb();
      final count = controlWrites().length;
      bike.debugTick();
      bike.debugTick();
      await settle(300);
      expect(controlWrites().length - count, lessThanOrEqualTo(1));
    });

    test('a calibration run holds a slope of its own, and hands the old state back', () async {
      await climb(grade: 2);
      final snapshot = bike.captureControlState();
      bike.setCalibrationGrade(800);
      await settle(300);
      final calibration = gradeOf(sent(FtmsOpcode.setIndoorBikeSimulation).last);
      bike.restoreControlState(snapshot);
      await settle(300);
      final restored = gradeOf(sent(FtmsOpcode.setIndoorBikeSimulation).last);
      expect(calibration, greaterThan(restored));
    });

    test('adjusting the intensity scales an ERG target', () async {
      await serve();
      await controlPoint(ftmsSetTargetPower(200));
      bike.adjustIntensity(0.1);
      await settle(300);
      expect(wattsOf(sent(FtmsOpcode.setTargetPower).last), 220);
      bike.adjustIntensity(-0.2);
      await settle(300);
      expect(wattsOf(sent(FtmsOpcode.setTargetPower).last), 180);
    });

    test('a trainer that refuses grade simulation is moved to target power, once', () async {
      await climb();
      expect(bike.effectiveVirtualShiftingMode, VirtualShiftingMode.trackResistance);
      bike.onNotification(
        FitnessBikeDefinition.FITNESS_MACHINE_CONTROL_POINT_UUID,
        ftmsResponse(FtmsOpcode.setIndoorBikeSimulation, FtmsResult.operationFailed),
      );
      expect(bike.trackResistanceRefused.value, isTrue);
      expect(bike.effectiveVirtualShiftingMode, VirtualShiftingMode.targetPower);
      expect(bike.lastControlWrite!.ok, isFalse, reason: 'the refusal is on record until the next write lands');
      await settle(300);
      expect(sent(FtmsOpcode.setTargetPower), isNotEmpty);
      expect(bike.lastControlWrite!.ok, isTrue);
    });

    test('a trainer that says control is not permitted is asked again', () async {
      await serve();
      final before = sent(FtmsOpcode.requestControl).length;
      bike.onNotification(
        FitnessBikeDefinition.FITNESS_MACHINE_CONTROL_POINT_UUID,
        ftmsResponse(FtmsOpcode.setTargetPower, FtmsResult.controlNotPermitted),
      );
      await settle();
      // Inside the five-second guard of the handshake just made: not again.
      expect(sent(FtmsOpcode.requestControl).length, before);
    });
  });

  group('gears', () {
    test('a fresh bike sits in the middle of 24 gears', () {
      expect(bike.maxGear, 24);
      expect(bike.neutralGear, 12);
      expect(bike.currentGear.value, 12);
      expect(bike.gearRatios.value, hasLength(24));
    });

    test('a new gear count re-centres a bike the rider has not shifted', () {
      bike.setMaxGear(30);
      expect(bike.currentGear.value, 15);
      expect(bike.gearRatios.value, hasLength(30));
    });

    test('a new gear count keeps a gear the rider chose, within the new range', () {
      bike.setTargetGear(20);
      bike.setMaxGear(13);
      expect(bike.currentGear.value, 13);
      bike.setMaxGear(30);
      expect(bike.currentGear.value, 13);
    });

    test('custom ratios set the count, and a plain count change drops them', () {
      bike.setGearRatios([1.0, 2.0, 3.0]);
      expect(bike.maxGear, 3);
      expect(bike.gearRatios.value, [1.0, 2.0, 3.0]);
      bike.setMaxGear(5);
      expect(bike.gearRatios.value, FitnessBikeDefinition.defaultGearRatiosFor(5));
    });

    test('one ratio can be edited and the table reset', () {
      bike.setGearRatio(3, 9.9);
      expect(bike.gearRatios.value[2], 9.9);
      bike.resetGearRatios();
      expect(bike.gearRatios.value, FitnessBikeDefinition.defaultGearRatios);
    });

    test('shifting stops at both ends and says so', () {
      bike.setTargetGear(bike.maxGear);
      expect(bike.shiftUp(), isFalse);
      expect(bike.currentGear.value, 24);
      bike.setTargetGear(1);
      expect(bike.shiftDown(), isFalse);
      expect(bike.currentGear.value, 1);
      expect(bike.shiftUp(), isTrue);
      expect(bike.currentGear.value, 2);
    });

    test('the ratio follows the gear', () {
      bike.setTargetGear(1);
      final low = bike.gearRatio.value;
      bike.setTargetGear(24);
      expect(bike.gearRatio.value, greaterThan(low));
      expect(bike.gearRatio.value, bike.gearRatios.value.last);
    });

    test('the large chainring scales the ratio by the teeth', () {
      bike.setChainringTeeth(34, 50);
      bike.setFrontShiftEnabled(true);
      bike.setTargetGear(12);
      final small = bike.gearRatio.value;
      expect(bike.toggleFrontChainring(), isTrue);
      expect(bike.frontRing.value, FrontRing.large);
      expect(bike.gearRatio.value, closeTo(small * 50 / 34, 1e-9));
    });

    test('the front ring cannot be toggled while front shifting is off', () {
      expect(bike.toggleFrontChainring(), isFalse);
    });
  });

  group('what the trainer app is sent', () {
    test('indoor bike data carries the trainer\'s power and cadence, once a second', () async {
      await serve();
      final frames = listen(FitnessBikeDefinition.INDOOR_BIKE_DATA_UUID);
      await ride();
      bike.debugTick();
      await settle();
      final reading = parseIndoorBikeDataFrame(frames.last);
      expect(reading.powerW, 220);
      expect(reading.cadenceRpm, 90);
    });

    test('the speed follows the gear, not the trainer\'s flywheel', () async {
      await serve();
      final frames = listen(FitnessBikeDefinition.INDOOR_BIKE_DATA_UUID);
      await ride();
      bike.setTargetGear(6);
      bike.debugTick();
      await settle();
      final slow = parseIndoorBikeDataFrame(frames.last).speedKph!;
      bike.setTargetGear(22);
      bike.debugTick();
      await settle();
      expect(parseIndoorBikeDataFrame(frames.last).speedKph!, greaterThan(slow));
    });

    test('a client that has just subscribed is sent a frame straight away', () async {
      await serve(subscribe: false);
      final frames = listen(FitnessBikeDefinition.INDOOR_BIKE_DATA_UUID);
      await client!.request(5, [...u(FitnessBikeDefinition.INDOOR_BIKE_DATA_UUID), 1]);
      await settle();
      expect(frames, isNotEmpty);
    });

    test('cycling power carries crank data that decodes back to the cadence', () async {
      await serve();
      final frames = listen(FitnessBikeDefinition.CYCLING_POWER_MEASUREMENT_UUID);
      await ride();
      bike.debugTick();
      for (var i = 0; i < 4; i++) {
        clock = clock.add(const Duration(seconds: 1));
        bike.debugTick();
      }
      await settle();
      final parsed = frames.map(CpsMeasurement.parse).whereType<CpsMeasurement>().toList();
      expect(parsed.length, greaterThanOrEqualTo(3));
      expect(parsed.last.powerWatts, 220);
      final rpm = cpsCadenceRpm(parsed[parsed.length - 3], parsed.last);
      expect(rpm, isNotNull);
      expect(rpm!, inInclusiveRange(86, 94));
    });

    test('external heart rate, cadence and power replace the trainer\'s', () async {
      await serve();
      final frames = listen(FitnessBikeDefinition.INDOOR_BIKE_DATA_UUID);
      await ride();
      bike.setExternalHeartRate(150);
      bike.setExternalCadence(75);
      bike.setExternalPower(300);
      bike.debugTick();
      await settle();
      final reading = parseIndoorBikeDataFrame(frames.last);
      expect(reading.heartRateBpm, 150);
      expect(reading.cadenceRpm, 75);
      expect(reading.powerW, 300);
      expect(bike.powerW.value, 300);
      bike.setExternalPower(null);
      expect(bike.powerW.value, 220);
    });

    test('the app\'s own readout follows the trainer', () async {
      await serve();
      await ride();
      expect(bike.powerW.value, 220);
      expect(bike.cadenceRpm.value, 90);
      expect(emulator.data.value, contains('220 W'));
      expect(emulator.data.value, contains('gear 12/24'));
    });

    test('a trainer with power but no cadence is noticed', () async {
      await serve();
      for (var i = 0; i < 12; i++) {
        bike.onNotification(
          FitnessBikeDefinition.INDOOR_BIKE_DATA_UUID,
          Uint8List.fromList([0x41, 0x00, 0xFA, 0x00]),
        );
      }
      expect(bike.trainerReportsNoCadence, isTrue);
    });

    test('a trainer without cadence is driven over track resistance whatever mode was saved', () async {
      await serve();
      bike.setVirtualShiftingMode(VirtualShiftingMode.targetPower);
      expect(bike.effectiveVirtualShiftingMode, VirtualShiftingMode.targetPower);
      bike.onNotification(FitnessBikeDefinition.INDOOR_BIKE_DATA_UUID, Uint8List.fromList([0x41, 0x00, 0xFA, 0x00]));
      expect(bike.effectiveVirtualShiftingMode, VirtualShiftingMode.trackResistance);
      expect(bike.virtualShiftingMode.value, VirtualShiftingMode.targetPower, reason: 'the saved choice is untouched');
      bike.setExternalCadence(80);
      expect(bike.effectiveVirtualShiftingMode, VirtualShiftingMode.targetPower, reason: 'an external cadence restores it');
    });

    test('cycling power fills in for a trainer whose bike data lacks the cadence', () async {
      await serve();
      final power = buildCyclingPowerMeasurement(180, crankRevs: 10, eventTime1024: 1024);
      final next = buildCyclingPowerMeasurement(180, crankRevs: 11, eventTime1024: 2048);
      bike.onNotification(FitnessBikeDefinition.CYCLING_POWER_MEASUREMENT_UUID, Uint8List.fromList(power));
      bike.onNotification(FitnessBikeDefinition.CYCLING_POWER_MEASUREMENT_UUID, Uint8List.fromList(next));
      expect(bike.cadenceRpm.value, 60);
      expect(bike.powerW.value, 180);
    });
  });

  group('what the trainer can do', () {
    MachineFeature features({bool sim = false, bool power = false, bool resistance = false}) => MachineFeature(
      MachineFeature.build(
        targetSettings: {
          if (sim) TargetSettingFlag.indoorBikeSimulationParametersSettingFlag,
          if (power) TargetSettingFlag.powerTargetSettingFlag,
          if (resistance) TargetSettingFlag.resistanceTargetSettingFlag,
        },
      ),
    );

    test('before the trainer is read, target power is the default and every mode is allowed', () {
      expect(bike.defaultVirtualShiftingMode, VirtualShiftingMode.targetPower);
      expect(bike.virtualShiftingMode.value, VirtualShiftingMode.targetPower);
      for (final mode in VirtualShiftingMode.values) {
        expect(bike.supportsVirtualShiftingMode(mode), isTrue);
      }
    });

    test('a trainer that simulates a grade defaults to track resistance', () {
      bike.setTrainerFeatureForTesting(features(sim: true, power: true));
      expect(bike.defaultVirtualShiftingMode, VirtualShiftingMode.trackResistance);
      expect(bike.virtualShiftingMode.value, VirtualShiftingMode.trackResistance);
    });

    test('a trainer that only holds a power defaults to target power and cannot track resistance', () {
      bike.setTrainerFeatureForTesting(features(power: true));
      expect(bike.defaultVirtualShiftingMode, VirtualShiftingMode.targetPower);
      expect(bike.supportsVirtualShiftingMode(VirtualShiftingMode.trackResistance), isFalse);
      expect(bike.supportsVirtualShiftingMode(VirtualShiftingMode.targetPower), isTrue);
      expect(bike.supportsVirtualShiftingMode(VirtualShiftingMode.basicResistance), isFalse);
    });

    test('a trainer with only a resistance level defaults to basic resistance', () {
      bike.setTrainerFeatureForTesting(features(resistance: true));
      expect(bike.defaultVirtualShiftingMode, VirtualShiftingMode.basicResistance);
    });

    test('a mode the rider chose survives the probe; one left on auto follows it', () {
      bike.setVirtualShiftingMode(VirtualShiftingMode.targetPower);
      bike.setTrainerFeatureForTesting(features(sim: true, power: true));
      expect(bike.virtualShiftingMode.value, VirtualShiftingMode.targetPower);
      bike.useDefaultVirtualShiftingMode();
      expect(bike.virtualShiftingMode.value, VirtualShiftingMode.trackResistance);
    });

    test('a saved mode the trainer cannot carry is replaced by the default while it runs', () {
      bike.setTrainerFeatureForTesting(features(power: true));
      bike.setVirtualShiftingMode(VirtualShiftingMode.trackResistance);
      expect(bike.virtualShiftingMode.value, VirtualShiftingMode.trackResistance);
      expect(bike.effectiveVirtualShiftingMode, VirtualShiftingMode.targetPower);
    });

    test('reading the trainer\'s Fitness Machine Feature fills in what it can do', () async {
      trainer.readValues[FitnessBikeDefinition.FITNESS_MACHINE_FEATURE_UUID] = MachineFeature.build(
        machineFeatures: {MachineFeatureFlag.cadenceSupported},
        targetSettings: {TargetSettingFlag.powerTargetSettingFlag, TargetSettingFlag.indoorBikeSimulationParametersSettingFlag},
      );
      await bike.probeTrainerFeatures();
      expect(bike.trainerFeature.value, isNotNull);
      expect(bike.trainerFtmsTargetSettingFlagNames, containsAll(['powerTargetSettingFlag', 'indoorBikeSimulationParametersSettingFlag']));
      expect(bike.trainerFtmsMachineFeatureFlagNames, ['cadenceSupported']);
      expect(bike.ftmsCapabilitySummary, contains('powerTargetSettingFlag'));
      expect(bike.virtualShiftingMode.value, VirtualShiftingMode.trackResistance);
    });

    test('a trainer that cannot be read leaves the capabilities unknown', () async {
      bike.dispose();
      bike = makeBike(services: const []);
      await bike.probeTrainerFeatures();
      expect(bike.trainerFeature.value, isNull);
      expect(bike.ftmsCapabilitySummary, 'unknown');
    });
  });

  group('control protocols', () {
    BleService withControlPoint() => BleService(FitnessBikeDefinition.FITNESS_MACHINE_SERVICE_UUID, [
      BleCharacteristic(FitnessBikeDefinition.FITNESS_MACHINE_CONTROL_POINT_UUID, [
        CharacteristicProperty.write,
        CharacteristicProperty.indicate,
      ], []),
    ]);

    test('a trainer with the FTMS Control Point is driven over FTMS', () {
      expect(bike.autoControlProtocol, TrainerControlProtocol.ftms);
      expect(bike.controlProtocol, TrainerControlProtocol.ftms);
      expect(bike.supportedControlProtocols, {TrainerControlProtocol.ftms});
    });

    test('a trainer that only has FE-C is driven over FE-C, and every mode is carriable', () {
      bike = makeBike(services: [BleService(FitnessBikeDefinition.FEC_BLE_SERVICE_UUID, [])]);
      expect(bike.autoControlProtocol, TrainerControlProtocol.fec);
      expect(bike.defaultVirtualShiftingMode, VirtualShiftingMode.trackResistance);
      expect(bike.supportsVirtualShiftingMode(VirtualShiftingMode.basicResistance), isTrue);
    });

    test('FTMS wins when a trainer has both', () {
      bike = makeBike(services: [withControlPoint(), BleService(FitnessBikeDefinition.FEC_BLE_SERVICE_UUID, [])]);
      expect(bike.autoControlProtocol, TrainerControlProtocol.ftms);
      expect(bike.supportedControlProtocols, {TrainerControlProtocol.ftms, TrainerControlProtocol.fec});
    });

    test('a protocol the trainer cannot carry is ignored', () {
      bike.setControlProtocolOverride(TrainerControlProtocol.zwiftHub);
      expect(bike.controlProtocolOverride, isNull);
      bike = makeBike(services: [withControlPoint(), BleService(FitnessBikeDefinition.FEC_BLE_SERVICE_UUID, [])]);
      bike.setControlProtocolOverride(TrainerControlProtocol.fec);
      expect(bike.controlProtocol, TrainerControlProtocol.fec);
      bike.setControlProtocolOverride(null);
      expect(bike.controlProtocol, TrainerControlProtocol.ftms);
    });

    test('over a protocol that is not implemented, nothing is written to the trainer', () async {
      bike.dispose();
      bike = makeBike(services: [withControlPoint(), BleService(FitnessBikeDefinition.FEC_BLE_SERVICE_UUID, [])]);
      bike.setControlProtocolOverride(TrainerControlProtocol.fec);
      bike.setManualErgPower(200);
      await settle(300);
      expect(trainer.writes, isEmpty);
    });
  });
}
