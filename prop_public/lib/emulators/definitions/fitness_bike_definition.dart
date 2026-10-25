import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:prop/emulators/ble_definition.dart';
import 'package:prop/ftms/ftms.dart';
import 'package:prop/transports/ble_trainer_transport.dart';
import 'package:prop/transports/trainer_transport.dart';
import 'package:prop/utils/constants.dart';
import 'package:prop/utils/cps_measurement.dart';
import 'package:prop/utils/shared.dart';
import 'package:prop/utils/uuid.dart';
import 'package:prop/utils/vs_physics.dart' as physics;
import 'package:universal_ble/universal_ble.dart';

/// FitnessDircon implements a virtual Fitness Machine (bike) that apps like
/// Zwift and MyWhoosh can connect to via the DirCon (Direct Connect) protocol.
///
/// Architecture mirrors SHIFTR's `DirConManager` (DirConManager.cpp):
/// - Exposes FTMS and Cycling Power as the source of truth (it is not a
///   passthrough): the trainer app talks to this class, never to the trainer.
/// - Translates FTMS Control Point writes (target power, indoor bike
///   simulation) into FTMS Control Point writes on the connected physical
///   trainer, with the rider's virtual gear folded into what is asked for.
/// - Pushes synthetic `INDOOR_BIKE_DATA` and `CYCLING_POWER_MEASUREMENT`
///   notifications to the connected client at 1 Hz.
///
/// Virtual shifting works because a gear sets the speed a cadence amounts to,
/// and speed sets the resistance: see `utils/vs_physics.dart`. Not implemented
/// here: the Zwift Sync and FE-C control paths, and the Zwift Custom service.
class FitnessBikeDefinition extends BleDefinition {
  final BleDevice connectedDevice;
  final List<BleService> connectedDeviceServices;
  final ValueNotifier<String> data;

  /// When true, the Zwift Play custom service is included in [serviceUUIDs]
  /// and thus advertised alongside FTMS / Cycling Power. The outer app sets
  /// this to true only when the user-selected trainer app is Zwift — other
  /// apps don't consume the Zwift service, and advertising it would just add
  /// noise to their scan results and occasionally confuse their pairing flows.
  /// (This build serves no Zwift service, so the flag changes nothing.)
  final bool shouldAdvertiseZwift;

  /// Upstream I/O transport. Defaults to BLE via the device's id.
  final TrainerTransport transport;

  FitnessBikeDefinition({
    required this.connectedDevice,
    required this.connectedDeviceServices,
    required this.data,
    this.shouldAdvertiseZwift = false,
    TrainerTransport? transport,
  }) : transport = transport ?? BleTrainerTransport(connectedDevice.deviceId);

  // ===========================================================================
  // BLE Service / characteristic UUIDs
  // ===========================================================================

  static const String FITNESS_MACHINE_SERVICE_UUID = '00001826-0000-1000-8000-00805f9b34fb';
  static const String CYCLING_POWER_SERVICE_UUID = '00001818-0000-1000-8000-00805f9b34fb';
  static const String DEVICE_INFORMATION_SERVICE_UUID = '0000180a-0000-1000-8000-00805f9b34fb';

  static const String FITNESS_MACHINE_FEATURE_UUID = '00002acc-0000-1000-8000-00805f9b34fb';
  static const String INDOOR_BIKE_DATA_UUID = '00002ad2-0000-1000-8000-00805f9b34fb';
  static const String SUPPORTED_INCLINATION_RANGE_UUID = '00002ad5-0000-1000-8000-00805f9b34fb';
  static const String SUPPORTED_RESISTANCE_LEVEL_RANGE_UUID = '00002ad6-0000-1000-8000-00805f9b34fb';
  static const String SUPPORTED_POWER_RANGE_UUID = '00002ad8-0000-1000-8000-00805f9b34fb';
  static const String FITNESS_MACHINE_CONTROL_POINT_UUID = '00002ad9-0000-1000-8000-00805f9b34fb';
  static const String FITNESS_MACHINE_STATUS_UUID = '00002ada-0000-1000-8000-00805f9b34fb';
  static const String TRAINING_STATUS_UUID = '00002ad3-0000-1000-8000-00805f9b34fb';

  static const String DEVICE_INFORMATION_CHARACTERISTIC_MANUFACTURER_NAME = "00002a29-0000-1000-8000-00805f9b34fb";
  static const String DEVICE_INFORMATION_CHARACTERISTIC_FIRMWARE_REVISION = "00002a26-0000-1000-8000-00805f9b34fb";
  static const String DEVICE_INFORMATION_CHARACTERISTIC_SERIAL_NUMBER = "00002a25-0000-1000-8000-00805f9b34fb";

  static const String CYCLING_POWER_MEASUREMENT_UUID = '00002a63-0000-1000-8000-00805f9b34fb';
  static const String CYCLING_POWER_FEATURE_UUID = '00002a65-0000-1000-8000-00805f9b34fb';
  static const String CYCLING_POWER_SENSOR_LOCATION_UUID = '00002a5d-0000-1000-8000-00805f9b34fb';

  /// Kept for external consumers (e.g. ProxyDircon) — this class no longer
  /// exposes a Heart Rate service itself.
  static const String HEART_RATE_MEASUREMENT_UUID = '00002a37-0000-1000-8000-00805f9b34fb';

  /// The ANT+ FE-C over Bluetooth LE primary service, as trainers such as Tacx
  /// and Elite expose it.
  static const String FEC_BLE_SERVICE_UUID = '6e40fec1-b5a3-f393-e0a9-e50e24dcca9e';

  /// Control writes to the trainer go out at most this often; while the rider
  /// changes gear or the slope moves, only the latest request is kept.
  static const Duration minControlWriteInterval = Duration(milliseconds: 250);

  static const String _notImplementedProtocol =
      'This trainer is controlled over a protocol that is not implemented in this build; only FTMS is.';

  // ===========================================================================
  // Gears and weights
  // ===========================================================================

  static const int minGear = 1;

  // The calibrator's per-trainer percentage applied to the resistance every
  // gear asks for.
  static const int defaultDifficultyPct = 100;
  static const int minDifficultyPct = 25;
  static const int maxDifficultyPct = 400;

  static const int _defaultMaxGear = 24;

  static final List<double> defaultGearRatios = physics.defaultGearRatiosFor(_defaultMaxGear);

  static List<double> defaultGearRatiosFor(int count) => physics.defaultGearRatiosFor(count);

  final ValueNotifier<int> _currentGear = ValueNotifier<int>(physics.neutralGearFor(_defaultMaxGear));
  final ValueNotifier<List<double>> _gearRatios = ValueNotifier<List<double>>(defaultGearRatios);
  final ValueNotifier<double> _gearRatioN = ValueNotifier<double>(defaultGearRatios[physics.neutralGearFor(_defaultMaxGear) - 1]);
  int _maxGear = _defaultMaxGear;
  bool _customRatios = false;

  /// Whether the rider has chosen a gear yet. Until they have, a change in the
  /// gear count keeps the definition in the middle of the new range.
  bool _gearTouched = false;

  final ValueNotifier<double> _bicycleWeightKg = ValueNotifier<double>(10.0);
  final ValueNotifier<double> _riderWeightKg = ValueNotifier<double>(70.0);

  ValueListenable<double> get bicycleWeightKg => _bicycleWeightKg;

  ValueListenable<double> get riderWeightKg => _riderWeightKg;

  int get maxGear => _maxGear;

  int get neutralGear => physics.neutralGearFor(_maxGear);

  /// The gear the rider is in, from 1 (lowest) to [maxGear].
  ValueNotifier<int> get currentGear => _currentGear;

  /// The ratio of the current gear, including the front chainring.
  ValueListenable<double> get gearRatio => _gearRatioN;

  ValueNotifier<List<double>> get gearRatios => _gearRatios;

  void setMaxGear(int maxGear) {
    final count = maxGear.clamp(1, 60);
    if (count == _maxGear && _gearRatios.value.length == count) return;
    _maxGear = count;
    if (!_customRatios || _gearRatios.value.length != count) {
      _customRatios = false;
      _gearRatios.value = physics.defaultGearRatiosFor(count);
    }
    _currentGear.value = _gearTouched ? _currentGear.value.clamp(1, count) : neutralGear;
    _gearChanged();
  }

  void setBicycleWeightKg(double bikeWeightKg) {
    _bicycleWeightKg.value = bikeWeightKg;
    _controlChanged();
  }

  void setRiderWeightKg(double riderWeightKg) {
    _riderWeightKg.value = riderWeightKg;
    _controlChanged();
  }

  void setGearRatios(List<double> list) {
    if (list.isEmpty) return;
    _customRatios = true;
    _maxGear = list.length;
    _gearRatios.value = List<double>.unmodifiable(list);
    _currentGear.value = _gearTouched ? _currentGear.value.clamp(1, _maxGear) : neutralGear;
    _gearChanged();
  }

  void setGearRatio(int gear, double v) {
    if (gear < 1 || gear > _maxGear) return;
    final next = List<double>.of(_gearRatios.value)..[gear - 1] = v;
    _customRatios = true;
    _gearRatios.value = List<double>.unmodifiable(next);
    _gearChanged();
  }

  void resetGearRatios() {
    _customRatios = false;
    _gearRatios.value = physics.defaultGearRatiosFor(_maxGear);
    _gearChanged();
  }

  void setTargetGear(int gear) {
    _gearTouched = true;
    _currentGear.value = gear.clamp(1, _maxGear);
    _gearChanged();
  }

  /// Shifts one gear up; false when already in the highest.
  bool shiftUp() {
    if (_currentGear.value >= _maxGear) return false;
    setTargetGear(_currentGear.value + 1);
    return true;
  }

  bool shiftDown() {
    if (_currentGear.value <= 1) return false;
    setTargetGear(_currentGear.value - 1);
    return true;
  }

  void _gearChanged() {
    _gearRatioN.value = _effectiveRatio();
    _publish();
    _controlChanged();
  }

  double _effectiveRatio() {
    final ratios = _gearRatios.value;
    if (ratios.isEmpty) return physics.kAssumedChainRatio;
    final base = ratios[(_currentGear.value - 1).clamp(0, ratios.length - 1)];
    if (_frontShiftEnabled && _frontRingN.value == FrontRing.large && _smallChainringTeeth > 0) {
      return base * _largeChainringTeeth / _smallChainringTeeth;
    }
    return base;
  }

  // Front chainring.

  bool _frontShiftEnabled = false;
  int _smallChainringTeeth = 34;
  int _largeChainringTeeth = 50;
  final ValueNotifier<FrontRing> _frontRingN = ValueNotifier<FrontRing>(FrontRing.small);
  ValueListenable<FrontRing> get frontRing => _frontRingN;
  int get smallChainringTeeth => _smallChainringTeeth;
  int get largeChainringTeeth => _largeChainringTeeth;
  bool get frontShiftEnabled => _frontShiftEnabled;

  void setFrontShiftEnabled(bool enabled) {
    _frontShiftEnabled = enabled;
    if (!enabled) _frontRingN.value = FrontRing.small;
    _gearChanged();
  }

  void setChainringTeeth(int small, int large) {
    _smallChainringTeeth = small;
    _largeChainringTeeth = large;
    _frontRingN.value = FrontRing.small;
    _gearChanged();
  }

  bool toggleFrontChainring() {
    if (!_frontShiftEnabled) return false;
    _frontRingN.value = _frontRingN.value == FrontRing.small ? FrontRing.large : FrontRing.small;
    _gearChanged();
    return true;
  }

  // ===========================================================================
  // Difficulty, calibration and chain position
  // ===========================================================================

  final ValueNotifier<int> _difficultyPctN = ValueNotifier<int>(defaultDifficultyPct);

  /// The calibrator's per-trainer scale on every gear's resistance.
  ValueListenable<int> get difficultyPct => _difficultyPctN;

  void setDifficultyPct(int pct) {
    _difficultyPctN.value = pct.clamp(minDifficultyPct, maxDifficultyPct);
    _controlChanged();
  }

  /// Holds the trainer at [grade001Pct] (hundredths of a percent) while the
  /// calibration runs, shifting and difficulty still applying.
  void setCalibrationGrade(int grade001Pct) {
    _simGradeN.value = grade001Pct;
    _hasGrade = true;
    _smoothedGrade = null; // a calibration slope is held as is, not eased in
    _ergTargetPower.value = null;
    _trainerMode.value = TrainerMode.simModeVirtualShifting;
    _updateChainHint();
    _controlChanged(force: true);
  }

  /// What the trainer is doing right now (ERG and its target, or a grade),
  /// so a calibration run can hand it back.
  TrainerControlSnapshot captureControlState() => TrainerControlSnapshot(
    mode: _trainerMode.value,
    ergTarget: _ergTargetPower.value,
    simGrade: _simGradeN.value,
    hasGrade: _hasGrade,
  );

  void restoreControlState(TrainerControlSnapshot snapshot) {
    _simGradeN.value = snapshot.simGrade;
    _hasGrade = snapshot.hasGrade;
    _smoothedGrade = null;
    _ergTargetPower.value = snapshot.ergTarget;
    _trainerMode.value = snapshot.mode;
    _updateChainHint();
    _controlChanged(force: true);
  }

  final ValueNotifier<ChainPositionHint> _chainPositionHintN = ValueNotifier<ChainPositionHint>(ChainPositionHint.none);
  final ValueNotifier<double?> _estimatedChainRatioN = ValueNotifier<double?>(null);
  final List<({DateTime at, double ratio})> _chainSamples = [];

  static const double _chainTooBig = 3.8;
  static const double _chainTooSmall = 1.3;
  static const Duration _chainSustained = Duration(seconds: 20);
  static const Duration _chainRecent = Duration(seconds: 5);

  /// Where the rider's real chain seems to sit on the trainer.
  ValueListenable<ChainPositionHint> get chainPositionHint => _chainPositionHintN;

  /// Flywheel speed over cadence, approximate; null until it is known.
  ValueListenable<double?> get estimatedChainRatio => _estimatedChainRatioN;

  /// A smart bike has no real chain, so there is nothing to place.
  bool get _isSmartBike => RegExp(r'\bbike\b', caseSensitive: false).hasMatch(connectedDevice.name ?? '');

  bool get _chainHintApplies =>
      !_isSmartBike &&
      effectiveVirtualShiftingMode == VirtualShiftingMode.trackResistance &&
      _trainerMode.value == TrainerMode.simModeVirtualShifting;

  void _noteChainSample(double? speedKph, int? cadence) {
    final ratio = physics.estimateChainRatio(speedKph: speedKph ?? 0, cadenceRpm: (cadence ?? 0).toDouble());
    final now = _now();
    if (ratio != null) {
      _chainSamples.add((at: now, ratio: ratio));
      _chainSamples.removeWhere((s) => now.difference(s.at) > const Duration(seconds: 30));
    }
    _updateChainHint();
  }

  void _updateChainHint() {
    if (_isSmartBike) {
      _chainSamples.clear();
      _estimatedChainRatioN.value = null;
      _chainPositionHintN.value = ChainPositionHint.none;
      return;
    }
    final now = _now();
    final recent = [
      for (final s in _chainSamples)
        if (now.difference(s.at) <= _chainRecent) s.ratio,
    ]..sort();
    if (recent.length < 3) return;
    final median = recent[recent.length ~/ 2];
    _estimatedChainRatioN.value = median;

    // The hint is only about the grade physics, which assume a middle gear.
    if (!_chainHintApplies) {
      _chainPositionHintN.value = ChainPositionHint.none;
      return;
    }
    if (median >= _chainTooSmall && median <= _chainTooBig) {
      _chainPositionHintN.value = ChainPositionHint.none;
      return;
    }
    final spansLongEnough =
        _chainSamples.isNotEmpty && now.difference(_chainSamples.first.at) >= _chainSustained - const Duration(seconds: 1);
    if (!spansLongEnough) return;
    final window = [
      for (final s in _chainSamples)
        if (now.difference(s.at) <= _chainSustained) s.ratio,
    ];
    if (window.every((r) => r > _chainTooBig)) {
      _chainPositionHintN.value = ChainPositionHint.veryBigGear;
    } else if (window.every((r) => r < _chainTooSmall)) {
      _chainPositionHintN.value = ChainPositionHint.verySmallGear;
    }
  }

  /// Test seam: the clock the chain-position estimate reads.
  @visibleForTesting
  DateTime Function()? debugClock;

  DateTime _now() => (debugClock ?? DateTime.now)();

  // ===========================================================================
  // Rider metrics
  // ===========================================================================

  int? _trainerCadence;
  int? _trainerPower;
  int? _trainerHeartRate;
  double? _trainerSpeedKph;
  int? _externalCadence;
  int? _externalPower;
  int? _externalHeartRate;
  int _samplesWithoutCadence = 0;
  double _filteredCadence = 0;
  bool _cadenceFilterOn = false;

  final ValueNotifier<int?> _cadenceRpmN = ValueNotifier<int?>(null);
  final ValueNotifier<int?> _powerWN = ValueNotifier<int?>(null);
  final ValueNotifier<int?> _heartRateN = ValueNotifier<int?>(null);
  final ValueNotifier<double?> _speedKphN = ValueNotifier<double?>(null);

  ValueListenable<int?> get cadenceRpm => _cadenceRpmN;

  ValueListenable<int?> get powerW => _powerWN;

  ValueListenable<int?> get heartRateBpm => _heartRateN;

  /// The speed shown to the trainer app: what the rider's gear and cadence
  /// amount to, not what the trainer's flywheel reports.
  ValueListenable<double?> get speedKph => _speedKphN;

  /// Rider metrics sourced by the app rather than the trainer.
  void setExternalHeartRate(int? bpm) {
    _externalHeartRate = bpm;
    _publish();
  }

  void setExternalCadence(int? rpm) {
    _externalCadence = rpm;
    _publish();
  }

  void setExternalPower(int? watts) {
    _externalPower = watts;
    _publish();
  }

  /// Whether the trainer, having reported power for a while, never reported a
  /// cadence: virtual shifting then needs an external cadence source.
  bool get trainerReportsNoCadence => _trainerCadence == null && _samplesWithoutCadence >= 1;

  /// The cadence the resistance calculation actually uses.
  int get filteredCadence => _cadenceFilterOn ? _filteredCadence.round() : (_cadenceRpmN.value ?? 0);

  final ValueNotifier<bool> _cadenceFilterEnabledN = ValueNotifier(false);
  ValueListenable<bool> get cadenceFilterEnabled => _cadenceFilterEnabledN;
  void setCadenceFilterEnabled(bool enabled) {
    _cadenceFilterOn = enabled;
    _cadenceFilterEnabledN.value = enabled;
  }

  final ValueNotifier<bool> _gradeSmoothingN = ValueNotifier(true);
  ValueListenable<bool> get gradeSmoothingEnabled => _gradeSmoothingN;

  void setGradeSmoothingEnabled(bool gradeSmoothing) {
    _gradeSmoothingN.value = gradeSmoothing;
    if (!gradeSmoothing) _smoothedGrade = null;
  }

  void _publish() {
    final cadence = _externalCadence ?? _trainerCadence;
    _cadenceRpmN.value = cadence;
    _powerWN.value = _externalPower ?? _trainerPower;
    _heartRateN.value = _externalHeartRate ?? _trainerHeartRate;
    _speedKphN.value = cadence == null
        ? _trainerSpeedKph
        : physics.virtualSpeedMps(cadenceRpm: cadence.toDouble(), gearRatio: _gearRatioN.value) * 3.6;
    if (cadence != null) {
      _filteredCadence = _filteredCadence == 0 ? cadence.toDouble() : _filteredCadence + (cadence - _filteredCadence) * 0.4;
    }
    final parts = [
      if (_powerWN.value != null) '${_powerWN.value} W',
      if (_cadenceRpmN.value != null) '${_cadenceRpmN.value} rpm',
      if (_heartRateN.value != null) '${_heartRateN.value} bpm',
      'gear ${_currentGear.value}/$_maxGear',
    ];
    data.value = parts.join(' · ');
  }

  // ===========================================================================
  // Virtual shifting mode and the trainer's capabilities
  // ===========================================================================

  final ValueNotifier<MachineFeature?> _trainerFeatureN = ValueNotifier<MachineFeature?>(null);
  late final ValueNotifier<VirtualShiftingMode> _virtualShiftingModeN = ValueNotifier<VirtualShiftingMode>(
    defaultVirtualShiftingMode,
  );
  bool _usingDefaultMode = true;

  /// What the trainer says it can do (its Fitness Machine Feature), null until
  /// it has been read.
  ValueNotifier<MachineFeature?> get trainerFeature => _trainerFeatureN;

  ValueNotifier<VirtualShiftingMode> get virtualShiftingMode => _virtualShiftingModeN;

  final ValueNotifier<bool> trackResistanceRefused = ValueNotifier<bool>(false);

  /// The mode virtual shifting is actually driven with, which can differ from
  /// the saved [virtualShiftingMode].
  VirtualShiftingMode get effectiveVirtualShiftingMode {
    final saved = _virtualShiftingModeN.value;
    if (saved == VirtualShiftingMode.trackResistance && trackResistanceRefused.value) {
      return VirtualShiftingMode.targetPower;
    }
    // A trainer whose telemetry carries no cadence is driven over track
    // resistance whatever mode was saved: the cadence-driven modes would write
    // nothing useful, since speed, and with it power, comes from the cadence.
    if (saved != VirtualShiftingMode.trackResistance &&
        trainerReportsNoCadence &&
        _externalCadence == null &&
        !trackResistanceRefused.value &&
        supportsVirtualShiftingMode(VirtualShiftingMode.trackResistance)) {
      return VirtualShiftingMode.trackResistance;
    }
    return supportsVirtualShiftingMode(saved) ? saved : defaultVirtualShiftingMode;
  }

  /// The mode auto-selection would pick for this trainer: track resistance
  /// wherever the trainer can simulate a grade (and for every trainer not
  /// controlled over FTMS), else target power, the one every FTMS trainer can
  /// hold.
  VirtualShiftingMode get defaultVirtualShiftingMode {
    if (controlProtocol != TrainerControlProtocol.ftms) return VirtualShiftingMode.trackResistance;
    final feature = _trainerFeatureN.value;
    if (feature == null) return VirtualShiftingMode.targetPower;
    if (feature.supports(TargetSettingFlag.indoorBikeSimulationParametersSettingFlag)) {
      return VirtualShiftingMode.trackResistance;
    }
    if (feature.supports(TargetSettingFlag.powerTargetSettingFlag)) return VirtualShiftingMode.targetPower;
    if (feature.supports(TargetSettingFlag.resistanceTargetSettingFlag)) return VirtualShiftingMode.basicResistance;
    return VirtualShiftingMode.targetPower;
  }

  bool supportsVirtualShiftingMode(VirtualShiftingMode value) {
    if (controlProtocol != TrainerControlProtocol.ftms) return true;
    final feature = _trainerFeatureN.value;
    if (feature == null) return true;
    return switch (value) {
      VirtualShiftingMode.targetPower => feature.supports(TargetSettingFlag.powerTargetSettingFlag),
      VirtualShiftingMode.trackResistance => feature.supports(
        TargetSettingFlag.indoorBikeSimulationParametersSettingFlag,
      ),
      VirtualShiftingMode.basicResistance => feature.supports(TargetSettingFlag.resistanceTargetSettingFlag),
    };
  }

  void setVirtualShiftingMode(VirtualShiftingMode mode) {
    _usingDefaultMode = false;
    _virtualShiftingModeN.value = mode;
    _controlChanged(force: true);
    _updateChainHint();
  }

  /// Hands the virtual-shifting mode back to auto-selection.
  void useDefaultVirtualShiftingMode() {
    _usingDefaultMode = true;
    _virtualShiftingModeN.value = defaultVirtualShiftingMode;
    _controlChanged(force: true);
    _updateChainHint();
  }

  /// Test seam: stands in for the trainer's Machine Feature read.
  @visibleForTesting
  void setTrainerFeatureForTesting(MachineFeature feature) => _setFeature(feature);

  void _setFeature(MachineFeature feature) {
    _trainerFeatureN.value = feature;
    if (_usingDefaultMode) _virtualShiftingModeN.value = defaultVirtualShiftingMode;
    _controlChanged(force: true);
  }

  List<String>? get trainerFtmsMachineFeatureFlagNames => _trainerFeatureN.value?.machineFeatureNames;

  List<String>? get trainerFtmsTargetSettingFlagNames => _trainerFeatureN.value?.targetSettingNames;

  /// Compact FTMS capability line for the support bundle.
  String get ftmsCapabilitySummary {
    final feature = _trainerFeatureN.value;
    if (feature == null) return 'unknown';
    return 'features=${feature.machineFeatureNames.join('+')} targets=${feature.targetSettingNames.join('+')}';
  }

  /// Reads the trainer's Fitness Machine Feature (and resistance range) so the
  /// app can offer only what the trainer can do.
  Future<void>? probeTrainerFeatures() async {
    final feature = _upstreamChar(FITNESS_MACHINE_FEATURE_UUID);
    if (feature == null) return;
    try {
      final bytes = await transport.read(feature.service, feature.characteristic).timeout(const Duration(seconds: 5));
      if (_disposed) return;
      _setFeature(MachineFeature(bytes));
    } catch (e) {
      Logger.warn('FitnessBike: could not read the trainer feature: $e');
    }
    final range = _upstreamChar(SUPPORTED_RESISTANCE_LEVEL_RANGE_UUID);
    if (range == null) return;
    try {
      final bytes = await transport.read(range.service, range.characteristic).timeout(const Duration(seconds: 5));
      if (bytes.length >= 4) {
        final view = ByteData.sublistView(Uint8List.fromList(bytes));
        _resistanceRange = (min: view.getInt16(0, Endian.little), max: view.getInt16(2, Endian.little));
      }
    } catch (_) {
      // The default range stays.
    }
  }

  ({int min, int max}) _resistanceRange = (min: 0, max: 100);

  // ===========================================================================
  // Control protocol
  // ===========================================================================

  TrainerControlProtocol? _controlProtocolOverride;

  bool _hasService(String uuid) => connectedDeviceServices.any((s) => normalizeUuid(s.uuid) == normalizeUuid(uuid));

  bool get _hasZwiftHub => connectedDeviceServices.any(
    (s) =>
        normalizeUuid(s.uuid) == normalizeUuid(FtmsMdnsConstants.ZWIFT_PLAY_SERVICE_UUID) &&
        s.characteristics.any(
          (c) => normalizeUuid(c.uuid) == normalizeUuid(FtmsMdnsConstants.ZWIFT_SYNC_RX_CHARACTERISTIC_UUID),
        ),
  );

  bool get _hasFtmsControl => _upstreamChar(FITNESS_MACHINE_CONTROL_POINT_UUID) != null;

  /// What auto-detection picks: a trainer that speaks the Zwift protocol shifts
  /// in its own firmware, so that wins; then FTMS where the trainer has its
  /// Control Point, then FE-C over BLE, and FTMS regardless.
  TrainerControlProtocol get autoControlProtocol {
    if (_hasZwiftHub) return TrainerControlProtocol.zwiftHub;
    if (_hasFtmsControl) return TrainerControlProtocol.ftms;
    if (_hasService(FEC_BLE_SERVICE_UUID)) return TrainerControlProtocol.fec;
    return TrainerControlProtocol.ftms;
  }

  /// The delivery the trainer is actually driven over: the rider's
  /// [controlProtocolOverride] when set, otherwise auto-detection.
  TrainerControlProtocol get controlProtocol => _controlProtocolOverride ?? autoControlProtocol;

  /// The rider's forced delivery, or null for auto.
  TrainerControlProtocol? get controlProtocolOverride => _controlProtocolOverride;

  /// Every delivery this trainer can actually carry.
  Set<TrainerControlProtocol> get supportedControlProtocols {
    final out = <TrainerControlProtocol>{
      if (_hasFtmsControl) TrainerControlProtocol.ftms,
      if (_hasService(FEC_BLE_SERVICE_UUID)) TrainerControlProtocol.fec,
      if (_hasZwiftHub) TrainerControlProtocol.zwiftHub,
    };
    return out.isEmpty ? {autoControlProtocol} : out;
  }

  /// Forces a delivery, or hands the choice back with null. A delivery this
  /// trainer cannot carry is ignored.
  void setControlProtocolOverride(TrainerControlProtocol? p) {
    if (p != null && !supportedControlProtocols.contains(p)) return;
    _controlProtocolOverride = p;
    if (!_usingDefaultMode) {
      // The saved mode stays; support for it can differ per delivery.
    } else {
      _virtualShiftingModeN.value = defaultVirtualShiftingMode;
    }
    _controlChanged(force: true);
  }

  /// How the gear echo watchdog resolved, or null while nothing is wrong. The
  /// FTMS path needs no echo, so it stays null here.
  final ValueNotifier<ZwiftGearEchoVerdict?> gearEchoVerdict = ValueNotifier<ZwiftGearEchoVerdict?>(null);

  /// Compact Zwift-Sync handshake line for the support bundle; 'n/a' when the
  /// trainer does not speak it.
  String get zwiftHandshakeSummary => 'n/a';

  /// Compact native gear-acknowledgement line for the support bundle; 'n/a'
  /// when the trainer does not speak it.
  String get gearEchoSummary => 'n/a';

  /// The most recent upstream control write, or null before the first one.
  ControlWriteResult? get lastControlWrite => _lastControlWrite;

  ControlWriteResult? _lastControlWrite;

  // ===========================================================================
  // Trainer mode: ERG, or a simulated grade with virtual shifting
  // ===========================================================================

  final ValueNotifier<TrainerMode> _trainerMode = ValueNotifier<TrainerMode>(TrainerMode.simMode);
  final ValueNotifier<int?> _ergTargetPower = ValueNotifier<int?>(null);
  final ValueNotifier<int?> _targetPowerW = ValueNotifier<int?>(null);
  final ValueNotifier<int> _simGradeN = ValueNotifier<int>(0);
  BikeSimulation? _sim;

  /// Whether a slope has been given, by the trainer app or a calibration run.
  bool _hasGrade = false;
  double _intensityFactor = 1.0;
  double? _smoothedGrade;

  ValueNotifier<TrainerMode> get trainerMode => _trainerMode;

  /// The target power held in ERG mode, null otherwise.
  ValueNotifier<int?> get ergTargetPower => _ergTargetPower;

  /// The power BikeControl last asked the trainer to hold, in any mode.
  ValueListenable<int?> get targetPowerW => _targetPowerW;

  /// The slope the trainer app reports, in hundredths of a percent.
  ValueListenable<int> get simGrade => _simGradeN;

  /// Test seam: puts the definition in [mode] without a trainer app's request.
  @visibleForTesting
  set trainerModeForTesting(TrainerMode mode) {
    _trainerMode.value = mode;
    _updateChainHint();
  }

  /// Holds an ERG target of [watts] (what a trainer app's workout, or the rider
  /// with the shift buttons, asks for).
  void setManualErgPower(Object? watts) {
    final value = (watts as num).round().clamp(0, 2000);
    _ergTargetPower.value = value;
    _trainerMode.value = TrainerMode.ergMode;
    _updateChainHint();
    _controlChanged(force: true);
  }

  void exitErgMode() {
    if (_trainerMode.value != TrainerMode.ergMode) return;
    _ergTargetPower.value = null;
    _trainerMode.value = _hasGrade ? TrainerMode.simModeVirtualShifting : TrainerMode.simMode;
    _updateChainHint();
    _controlChanged(force: true);
  }

  /// Scales the ERG target by [d] (0.05 is five percent).
  void adjustIntensity(double d) {
    _intensityFactor = (_intensityFactor + d).clamp(0.5, 1.5);
    _controlChanged(force: true);
  }

  // ===========================================================================
  // What the trainer app is shown
  // ===========================================================================

  static const List<String> _servedServices = [
    FITNESS_MACHINE_SERVICE_UUID,
    CYCLING_POWER_SERVICE_UUID,
    DEVICE_INFORMATION_SERVICE_UUID,
  ];

  @override
  List<String> get serviceUUIDs => [for (final s in _servedServices) normalizeUuid(s)];

  @override
  List<String> get advertiseServiceUUIDs => [
    normalizeUuid(FITNESS_MACHINE_SERVICE_UUID),
    normalizeUuid(CYCLING_POWER_SERVICE_UUID),
  ];

  static BleCharacteristic _char(String uuid, List<CharacteristicProperty> properties) =>
      BleCharacteristic(uuid, properties, []);

  @override
  List<BleCharacteristic> getCharacteristics(String serviceUUID) {
    switch (normalizeUuid(serviceUUID)) {
      case FITNESS_MACHINE_SERVICE_UUID:
        return [
          _char(FITNESS_MACHINE_FEATURE_UUID, [CharacteristicProperty.read]),
          _char(INDOOR_BIKE_DATA_UUID, [CharacteristicProperty.notify]),
          _char(TRAINING_STATUS_UUID, [CharacteristicProperty.read, CharacteristicProperty.notify]),
          _char(SUPPORTED_RESISTANCE_LEVEL_RANGE_UUID, [CharacteristicProperty.read]),
          _char(SUPPORTED_POWER_RANGE_UUID, [CharacteristicProperty.read]),
          _char(SUPPORTED_INCLINATION_RANGE_UUID, [CharacteristicProperty.read]),
          _char(FITNESS_MACHINE_CONTROL_POINT_UUID, [CharacteristicProperty.write, CharacteristicProperty.indicate]),
          _char(FITNESS_MACHINE_STATUS_UUID, [CharacteristicProperty.notify]),
        ];
      case CYCLING_POWER_SERVICE_UUID:
        return [
          _char(CYCLING_POWER_MEASUREMENT_UUID, [CharacteristicProperty.notify]),
          _char(CYCLING_POWER_FEATURE_UUID, [CharacteristicProperty.read]),
          _char(CYCLING_POWER_SENSOR_LOCATION_UUID, [CharacteristicProperty.read]),
        ];
      case DEVICE_INFORMATION_SERVICE_UUID:
        return [
          _char(DEVICE_INFORMATION_CHARACTERISTIC_MANUFACTURER_NAME, [CharacteristicProperty.read]),
          _char(DEVICE_INFORMATION_CHARACTERISTIC_FIRMWARE_REVISION, [CharacteristicProperty.read]),
          _char(DEVICE_INFORMATION_CHARACTERISTIC_SERIAL_NUMBER, [CharacteristicProperty.read]),
        ];
    }
    return const [];
  }

  /// What a virtual bike claims to do: cadence, resistance and power, and to
  /// hold a resistance, a power or a simulated grade.
  static final Uint8List _featureValue = MachineFeature.build(
    machineFeatures: {
      MachineFeatureFlag.cadenceSupported,
      MachineFeatureFlag.resistanceLevelSupported,
      MachineFeatureFlag.powerMeasurementSupported,
      MachineFeatureFlag.heartRateMeasurementSupported,
    },
    targetSettings: {
      TargetSettingFlag.resistanceTargetSettingFlag,
      TargetSettingFlag.powerTargetSettingFlag,
      TargetSettingFlag.indoorBikeSimulationParametersSettingFlag,
    },
  );

  static Uint8List _range(int min, int max, int step) {
    final out = Uint8List(6);
    final view = out.buffer.asByteData();
    view.setInt16(0, min, Endian.little);
    view.setInt16(2, max, Endian.little);
    view.setUint16(4, step, Endian.little);
    return out;
  }

  @override
  Future<Uint8List>? onReadRequest(String characteristicUUID) {
    final Uint8List? value = switch (normalizeUuid(characteristicUUID)) {
      FITNESS_MACHINE_FEATURE_UUID => _featureValue,
      SUPPORTED_RESISTANCE_LEVEL_RANGE_UUID => _range(_resistanceRange.min, _resistanceRange.max, 1),
      SUPPORTED_POWER_RANGE_UUID => _range(0, 2000, 1),
      SUPPORTED_INCLINATION_RANGE_UUID => _range(-150, 200, 1),
      TRAINING_STATUS_UUID => Uint8List.fromList([0x00, 0x01]),
      CYCLING_POWER_FEATURE_UUID => Uint8List.fromList([0x08, 0x00, 0x00, 0x00]),
      CYCLING_POWER_SENSOR_LOCATION_UUID => Uint8List.fromList([0x0D]),
      DEVICE_INFORMATION_CHARACTERISTIC_MANUFACTURER_NAME => Uint8List.fromList('BikeControl'.codeUnits),
      DEVICE_INFORMATION_CHARACTERISTIC_FIRMWARE_REVISION => Uint8List.fromList('1.0'.codeUnits),
      DEVICE_INFORMATION_CHARACTERISTIC_SERIAL_NUMBER => Uint8List.fromList(
        (connectedDevice.deviceId.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase()).codeUnits,
      ),
      _ => null,
    };
    return value == null ? null : Future<Uint8List>.value(value);
  }

  @override
  void onEnableNotificationRequest(String characteristicUUID) {
    // A client that has just subscribed need not wait out the second.
    switch (normalizeUuid(characteristicUUID)) {
      case INDOOR_BIKE_DATA_UUID:
        _emitIndoorBikeData();
      case CYCLING_POWER_MEASUREMENT_UUID:
        _emitCyclingPower();
    }
  }

  @override
  void onWriteRequest(String characteristicUUID, List<int> characteristicData) {
    if (normalizeUuid(characteristicUUID) != FITNESS_MACHINE_CONTROL_POINT_UUID) return;
    _onClientControlPoint(characteristicData);
  }

  // ---------------------------------------------------------------------------
  // The trainer app's Control Point requests
  // ---------------------------------------------------------------------------

  void _onClientControlPoint(List<int> request) {
    if (request.isEmpty) return;
    final opcode = request[0];
    final parameters = request.sublist(1);
    var result = FtmsResult.success;
    switch (opcode) {
      case FtmsOpcode.requestControl:
        break;
      case FtmsOpcode.reset:
        _sendStatus([FtmsStatus.reset]);
      case FtmsOpcode.startOrResume:
        _sendStatus([FtmsStatus.startedOrResumed]);
      case FtmsOpcode.stopOrPause:
        _sendStatus([FtmsStatus.stoppedOrPaused, parameters.isEmpty ? 0x01 : parameters[0]]);
      case FtmsOpcode.setTargetPower:
        if (parameters.length < 2) {
          result = FtmsResult.invalidParameter;
        } else {
          final watts = ByteData.sublistView(Uint8List.fromList(parameters)).getInt16(0, Endian.little);
          setManualErgPower(watts);
          _sendStatus([FtmsStatus.targetPowerChanged, ...parameters.sublist(0, 2)]);
        }
      case FtmsOpcode.setIndoorBikeSimulation:
        final sim = BikeSimulation.parse(parameters);
        if (sim == null) {
          result = FtmsResult.invalidParameter;
        } else {
          _onClientSimulation(sim);
          _sendStatus([FtmsStatus.indoorBikeSimulationChanged, ...parameters.sublist(0, 6)]);
        }
      case FtmsOpcode.setTargetResistance:
        if (parameters.isEmpty) {
          result = FtmsResult.invalidParameter;
        } else {
          _trainerMode.value = TrainerMode.simMode;
          _ergTargetPower.value = null;
          _sendUpstream(ftmsSetTargetResistance(parameters[0]), 'resistance');
        }
      default:
        result = FtmsResult.opCodeNotSupported;
    }
    sendCharacteristicNotification(FITNESS_MACHINE_CONTROL_POINT_UUID, ftmsResponse(opcode, result));
  }

  void _onClientSimulation(BikeSimulation sim) {
    _sim = sim;
    _hasGrade = true;
    _simGradeN.value = (sim.gradePercent * 100).round();
    _ergTargetPower.value = null;
    _trainerMode.value = TrainerMode.simModeVirtualShifting;
    _updateChainHint();
    _controlChanged(force: true);
  }

  void _sendStatus(List<int> status) =>
      sendCharacteristicNotification(FITNESS_MACHINE_STATUS_UUID, Uint8List.fromList(status));

  // ---------------------------------------------------------------------------
  // Synthetic data for the trainer app
  // ---------------------------------------------------------------------------

  Timer? _pump;
  bool _disposed = false;

  int _crankRevs = 0;
  int _crankEventTime1024 = 0;
  double _crankFraction = 0;
  DateTime? _lastCrankStep;

  /// Whether the periodic pump to the trainer app (and the subscriptions to
  /// the trainer that feed it) is running.
  bool get isSubscribedToTrainer => _pump != null;

  @override
  void onServerStarted() => subscribeToTrainer();

  @override
  void onServerStopped() => _stopPump();

  /// Starts what runs while the bridge serves: subscriptions to the trainer's
  /// data and control responses, taking control of it, and the 1 Hz pump that
  /// recomputes virtual shifting and notifies the trainer app.
  void subscribeToTrainer() {
    if (_disposed || _pump != null) return;
    _pump = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    _lastCrankStep = _now();
    for (final uuid in [INDOOR_BIKE_DATA_UUID, CYCLING_POWER_MEASUREMENT_UUID, FITNESS_MACHINE_CONTROL_POINT_UUID]) {
      final upstream = _upstreamChar(uuid);
      if (upstream == null) continue;
      final properties = _propertiesOf(uuid);
      final indicate =
          properties.contains(CharacteristicProperty.indicate) && !properties.contains(CharacteristicProperty.notify);
      _enqueueUpstream(
        'subscribe to $uuid',
        () => transport.subscribe(upstream.service, upstream.characteristic, indicate: indicate),
      );
    }
    _takeControlOfTrainer();
  }

  void _stopPump() {
    _pump?.cancel();
    _pump = null;
    _controlTimer?.cancel();
    _controlTimer = null;
    _pendingControl = null;
  }

  /// Test seam: one beat of the pump, without waiting a second for it.
  @visibleForTesting
  void debugTick() => _tick();

  void _tick() {
    if (_disposed) return;
    _advanceCrank();
    _publish();
    if (_smoothingTarget != null && _gradeSmoothingN.value) _smoothedGrade = _smoothedStep();
    _controlChanged();
    _emitIndoorBikeData();
    _emitCyclingPower();
    _updateChainHint();
  }

  void _advanceCrank() {
    final now = _now();
    final last = _lastCrankStep ?? now;
    _lastCrankStep = now;
    final cadence = _cadenceRpmN.value ?? 0;
    if (cadence <= 0) return;
    final seconds = now.difference(last).inMicroseconds / 1e6;
    final revsPerSecond = cadence / 60;
    final before = _crankFraction;
    _crankFraction += revsPerSecond * seconds;
    final whole = _crankFraction.floor();
    if (whole <= 0) return;
    // The event time is that of the last whole revolution, so two frames decode
    // back to the true cadence whatever the notify rate.
    final secondsSinceLast = (_crankFraction - whole) / revsPerSecond;
    _crankRevs = (_crankRevs + whole) & 0xFFFF;
    _crankFraction -= whole;
    final eventAt = now.subtract(Duration(microseconds: (secondsSinceLast * 1e6).round()));
    _crankEventTime1024 = (eventAt.microsecondsSinceEpoch * 1024 ~/ 1000000) & 0xFFFF;
    if (before < 0) _crankFraction = 0;
  }

  void _emitIndoorBikeData() {
    final cadence = _cadenceRpmN.value ?? 0;
    sendCharacteristicNotification(
      INDOOR_BIKE_DATA_UUID,
      buildIndoorBikeData(
        speedKph: _speedKphN.value ?? 0,
        cadenceRpm: cadence,
        powerW: _powerWN.value ?? 0,
        heartRateBpm: _heartRateN.value,
      ),
    );
  }

  void _emitCyclingPower() {
    sendCharacteristicNotification(
      CYCLING_POWER_MEASUREMENT_UUID,
      Uint8List.fromList(
        buildCyclingPowerMeasurement(_powerWN.value ?? 0, crankRevs: _crankRevs, eventTime1024: _crankEventTime1024),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // From the trainer
  // ---------------------------------------------------------------------------

  @override
  void onNotification(String characteristic, Uint8List bytes) {
    if (_disposed) return;
    switch (normalizeUuid(characteristic)) {
      case INDOOR_BIKE_DATA_UUID:
        _onTrainerBikeData(bytes);
      case CYCLING_POWER_MEASUREMENT_UUID:
        _onTrainerPower(bytes);
      case FITNESS_MACHINE_CONTROL_POINT_UUID:
        _onTrainerControlResponse(bytes);
    }
  }

  void _onTrainerBikeData(Uint8List bytes) {
    final reading = parseIndoorBikeDataFrame(bytes);
    if (reading.powerW != null) _trainerPower = reading.powerW;
    if (reading.speedKph != null) _trainerSpeedKph = reading.speedKph;
    if (reading.heartRateBpm != null && reading.heartRateBpm! > 0) _trainerHeartRate = reading.heartRateBpm;
    if (reading.cadenceRpm != null) {
      _trainerCadence = reading.cadenceRpm;
      _samplesWithoutCadence = 0;
    } else if (reading.powerW != null) {
      _samplesWithoutCadence++;
    }
    _publish();
    _noteChainSample(reading.speedKph, reading.cadenceRpm);
  }

  CpsMeasurement? _previousPower;

  void _onTrainerPower(Uint8List bytes) {
    final cur = CpsMeasurement.parse(bytes);
    if (cur == null) return;
    // The Indoor Bike Data frame is the better source of power and cadence; the
    // Cycling Power service fills in for a trainer that has no such field.
    if (_trainerPower == null || _lastBikeData == null) _trainerPower = cur.powerWatts;
    final prev = _previousPower;
    _previousPower = cur;
    if (_lastBikeData == null && prev != null) {
      final rpm = cpsCadenceRpm(prev, cur);
      if (rpm != null) _trainerCadence = rpm;
    }
    _publish();
  }

  DateTime? get _lastBikeData => _trainerSpeedKph == null && _trainerCadence == null ? null : DateTime.now();

  void _onTrainerControlResponse(Uint8List bytes) {
    if (bytes.length < 3 || bytes[0] != FtmsOpcode.responseCode) return;
    final opcode = bytes[1];
    final result = bytes[2];
    final ok = result == FtmsResult.success;
    _lastControlWrite = ControlWriteResult(at: DateTime.now(), ok: ok, op: _opName(opcode));
    if (ok) return;
    if (opcode == FtmsOpcode.setIndoorBikeSimulation && !trackResistanceRefused.value) {
      trackResistanceRefused.value = true;
      Logger.warn('FitnessBike: the trainer refused grade simulation; switched to Target Power');
      _controlChanged(force: true);
    } else if (result == FtmsResult.controlNotPermitted) {
      _takeControlOfTrainer();
    }
  }

  static String _opName(int opcode) => switch (opcode) {
    FtmsOpcode.requestControl => 'request-control',
    FtmsOpcode.startOrResume => 'start',
    FtmsOpcode.setTargetPower => 'target-power',
    FtmsOpcode.setIndoorBikeSimulation => 'simulation',
    FtmsOpcode.setTargetResistance => 'resistance',
    _ => '0x${opcode.toRadixString(16)}',
  };

  // ---------------------------------------------------------------------------
  // To the trainer
  // ---------------------------------------------------------------------------

  ({String service, String characteristic})? _upstreamChar(String uuid) {
    final wanted = normalizeUuid(uuid);
    for (final service in connectedDeviceServices) {
      for (final characteristic in service.characteristics) {
        if (normalizeUuid(characteristic.uuid) == wanted) {
          return (service: service.uuid, characteristic: characteristic.uuid);
        }
      }
    }
    return null;
  }

  List<CharacteristicProperty> _propertiesOf(String uuid) {
    final wanted = normalizeUuid(uuid);
    for (final service in connectedDeviceServices) {
      for (final characteristic in service.characteristics) {
        if (normalizeUuid(characteristic.uuid) == wanted) return characteristic.properties;
      }
    }
    return const [];
  }

  Future<void> _upstreamQueue = Future<void>.value();

  void _enqueueUpstream(String what, Future<void> Function() op, {void Function(Object error)? onError}) {
    _upstreamQueue = _upstreamQueue.then((_) => op()).catchError((Object e, StackTrace s) {
      onError?.call(e);
      Logger.recordError('FitnessBike: could not $what', e, s);
    });
  }

  DateTime? _lastTakeControl;

  void _takeControlOfTrainer() {
    final control = _upstreamChar(FITNESS_MACHINE_CONTROL_POINT_UUID);
    if (control == null || controlProtocol != TrainerControlProtocol.ftms) return;
    final now = DateTime.now();
    if (_lastTakeControl != null && now.difference(_lastTakeControl!) < const Duration(seconds: 5)) return;
    _lastTakeControl = now;
    for (final request in [
      Uint8List.fromList([FtmsOpcode.requestControl]),
      Uint8List.fromList([FtmsOpcode.startOrResume]),
    ]) {
      _enqueueUpstream(
        'write ${_opName(request[0])}',
        () => transport.write(control.service, control.characteristic, request),
      );
    }
  }

  Uint8List? _lastControl;
  DateTime _lastControlAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastWriteAt = DateTime.fromMillisecondsSinceEpoch(0);
  ({Uint8List bytes, String op})? _pendingControl;
  Timer? _controlTimer;

  /// Queues a Control Point request for the trainer. At most one goes out per
  /// [minControlWriteInterval]; while one waits, a newer request replaces it,
  /// and a request identical to the last is dropped unless it is stale.
  void _sendUpstream(Uint8List bytes, String op) {
    if (_disposed || _upstreamChar(FITNESS_MACHINE_CONTROL_POINT_UUID) == null) return;
    if (controlProtocol != TrainerControlProtocol.ftms) {
      Logger.trace(() => _notImplementedProtocol, record: false);
      return;
    }
    final now = DateTime.now();
    final last = _lastControl;
    if (_controlTimer == null &&
        last != null &&
        listEquals(last, bytes) &&
        now.difference(_lastControlAt) < const Duration(seconds: 5)) {
      return;
    }
    _pendingControl = (bytes: bytes, op: op);
    if (_controlTimer != null) return;
    final wait = minControlWriteInterval - now.difference(_lastWriteAt);
    if (wait <= Duration.zero) {
      _flushControl();
    } else {
      _controlTimer = Timer(wait, _flushControl);
    }
  }

  void _flushControl() {
    _controlTimer = null;
    final pending = _pendingControl;
    _pendingControl = null;
    final control = _upstreamChar(FITNESS_MACHINE_CONTROL_POINT_UUID);
    if (pending == null || control == null || _disposed) return;
    final now = DateTime.now();
    _lastControl = pending.bytes;
    _lastControlAt = now;
    _lastWriteAt = now;
    _enqueueUpstream(
      'write ${pending.op}',
      () async {
        await transport.write(control.service, control.characteristic, pending.bytes);
        _lastControlWrite = ControlWriteResult(at: DateTime.now(), ok: true, op: pending.op);
      },
      onError: (_) => _lastControlWrite = ControlWriteResult(at: DateTime.now(), ok: false, op: pending.op),
    );
  }

  void _controlChanged({bool force = false}) {
    if (_disposed) return;
    if (force) _lastControl = null;
    _applyControl();
  }

  /// Works out what the trainer should be asked for, given the mode, the gear,
  /// the slope and the rider, and queues it.
  void _applyControl() {
    switch (_trainerMode.value) {
      case TrainerMode.ergMode:
        final target = ((_ergTargetPower.value ?? 0) * _intensityFactor).round().clamp(0, 2000);
        _targetPowerW.value = target;
        _sendUpstream(ftmsSetTargetPower(target), 'target-power');
      case TrainerMode.simMode:
        return;
      case TrainerMode.simModeVirtualShifting:
        _applyVirtualShifting();
    }
  }

  double? get _smoothingTarget => _hasGrade ? _simGradeN.value / 100 : null;

  double _smoothedStep() {
    final target = _smoothingTarget ?? 0;
    final current = _smoothedGrade ?? target;
    return current + (target - current) * 0.35;
  }

  void _applyVirtualShifting() {
    final target = _smoothingTarget;
    if (target == null) return;
    final grade = _gradeSmoothingN.value ? (_smoothedGrade ??= target) : target;
    final mass = _riderWeightKg.value + _bicycleWeightKg.value;
    final cadence = filteredCadence.toDouble();
    final ratio = _gearRatioN.value;
    final crr = _sim?.rollingResistance ?? 0.004;
    final cw = _sim?.windResistanceKgPerM ?? 0.51;
    final wind = _sim?.windSpeedMps ?? 0;
    final difficulty = _difficultyPctN.value / 100;
    switch (effectiveVirtualShiftingMode) {
      case VirtualShiftingMode.targetPower:
        final watts =
            (difficulty *
                    physics.targetPowerFor(
                      cadenceRpm: cadence,
                      gearRatio: ratio,
                      gradePercent: grade,
                      massKg: mass,
                      rollingResistance: crr,
                      windResistanceKgPerM: cw,
                      windSpeedMps: wind,
                    ))
                .round()
                .clamp(0, 2000);
        _targetPowerW.value = watts;
        _sendUpstream(ftmsSetTargetPower(watts), 'target-power');
      case VirtualShiftingMode.trackResistance:
        final simulated = physics.trackResistanceGrade(
          cadenceRpm: cadence,
          gearRatio: ratio,
          gradePercent: grade,
          massKg: mass,
          rollingResistance: crr,
          windResistanceKgPerM: cw,
          windSpeedMps: wind,
          difficulty: difficulty,
        );
        _sendUpstream(
          BikeSimulation(
            gradePercent: simulated,
            rollingResistance: crr,
            windResistanceKgPerM: cw,
          ).toRequest(),
          'simulation',
        );
      case VirtualShiftingMode.basicResistance:
        final watts = difficulty *
            physics.targetPowerFor(
              cadenceRpm: cadence <= 0 ? 80 : cadence,
              gearRatio: ratio,
              gradePercent: grade,
              massKg: mass,
              rollingResistance: crr,
              windResistanceKgPerM: cw,
              windSpeedMps: wind,
            );
        final fraction = (watts / 600).clamp(0.0, 1.0);
        final level = (_resistanceRange.min + fraction * (_resistanceRange.max - _resistanceRange.min)).round();
        _sendUpstream(ftmsSetTargetResistance(level), 'resistance');
    }
  }

  // ===========================================================================
  // Not implemented in this build
  // ===========================================================================

  /// Wahoo KICKR CLIMB relay: not implemented.
  Future<bool> writeClimbInclineUpstream(int grade001Pct) async => false;

  bool get supportsClimbRelay => false;

  /// Test seam: 250 W at 90 rpm in gear 12 of 24.
  @visibleForTesting
  void setDebugValues() {
    _trainerPower = 250;
    _trainerCadence = 90;
    _gearTouched = true;
    _currentGear.value = 12.clamp(1, _maxGear);
    _gearChanged();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopPump();
  }
}

/// Outcome of the most recent control write sent upstream to the trainer.
class ControlWriteResult {
  final DateTime at;
  final bool ok;
  final String op;
  const ControlWriteResult({required this.at, required this.ok, required this.op});
}

/// How the gear echo watchdog resolved, once a trainer has ignored enough
/// native gear commands — see [FitnessBikeDefinition.gearEchoVerdict].
enum ZwiftGearEchoVerdict {
  /// Delivery moved to FTMS automatically.
  fellBackToFtms,

  /// The trainer has no FTMS Control Point; the native path stays.
  noFtmsToFallBackTo,

  /// The rider forced a protocol; that choice is kept.
  riderOverrideKept,
}

enum FrontRing { small, large }

/// Whether the real chain on the trainer sits at an extreme of the cassette.
enum ChainPositionHint { none, veryBigGear, verySmallGear }

/// What the trainer was doing before a calibration run, handed back after.
class TrainerControlSnapshot {
  const TrainerControlSnapshot({
    this.mode = TrainerMode.simMode,
    this.ergTarget,
    this.simGrade = 0,
    this.hasGrade = false,
  });

  final TrainerMode mode;
  final int? ergTarget;

  /// The slope, in hundredths of a percent, and whether one had been given.
  final int simGrade;
  final bool hasGrade;
}

enum TrainerMode { ergMode, simMode, simModeVirtualShifting }

enum VirtualShiftingMode { targetPower, trackResistance, basicResistance }

/// The wire a trainer's control commands are delivered over.
enum TrainerControlProtocol { ftms, fec, zwiftHub }
