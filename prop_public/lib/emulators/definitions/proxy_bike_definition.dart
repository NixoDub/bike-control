import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:prop/emulators/ble_definition.dart';
import 'package:prop/ftms/ftms.dart';
import 'package:prop/transports/ble_trainer_transport.dart';
import 'package:prop/transports/trainer_transport.dart';
import 'package:prop/utils/shared.dart';
import 'package:prop/utils/uuid.dart';
import 'package:universal_ble/universal_ble.dart';

/// A transparent relay of a real trainer: the services the trainer exposes are
/// served as they are, writes and reads are forwarded to it, and what it
/// notifies is passed on to the client. Along the way the rider metrics it
/// reports (power, cadence, speed, heart rate) are read for the app's own
/// display.
class ProxyBikeDefinition extends BleDefinition {
  final BleDevice device;
  final List<BleService> services;
  final ValueNotifier<String> data;

  /// Upstream I/O transport. Defaults to BLE via the device's id.
  final TrainerTransport transport;

  ProxyBikeDefinition({
    required this.services,
    required this.device,
    required this.data,
    TrainerTransport? transport,
  }) : transport = transport ?? BleTrainerTransport(device.deviceId) {
    for (final service in services) {
      if (!_isRelayed(service)) continue;
      _relayedServices.add(service);
      for (final characteristic in service.characteristics) {
        _owners[normalizeUuid(characteristic.uuid)] = (service: service, characteristic: characteristic);
      }
    }
  }

  static const String _genericAccess = '1800';
  static const String _genericAttribute = '1801';

  /// Services a trainer app is told about in the advertisement: the cycling
  /// profiles, plus anything on a custom UUID. Housekeeping services (device
  /// information, battery) are still served, just not advertised.
  static const Set<String> _advertisedProfiles = {'1826', '1818', '1816', '180d'};

  static const String _heartRateMeasurement = '00002a37-0000-1000-8000-00805f9b34fb';
  static const String _cyclingPowerMeasurement = '00002a63-0000-1000-8000-00805f9b34fb';
  static const String _indoorBikeData = '00002ad2-0000-1000-8000-00805f9b34fb';

  final List<BleService> _relayedServices = [];
  final Map<String, ({BleService service, BleCharacteristic characteristic})> _owners = {};
  final Set<String> _subscribedUpstream = {};
  Future<void> _upstreamQueue = Future<void>.value();
  bool _disposed = false;

  static bool _isRelayed(BleService service) {
    final short = shortUuidOf(service.uuid);
    return short != _genericAccess && short != _genericAttribute && service.characteristics.isNotEmpty;
  }

  final ValueNotifier<int?> _powerW = ValueNotifier<int?>(null);
  final ValueNotifier<int?> _heartRateBpm = ValueNotifier<int?>(null);
  final ValueNotifier<int?> _cadenceRpm = ValueNotifier<int?>(null);
  final ValueNotifier<double?> _speedKph = ValueNotifier<double?>(null);

  ValueListenable<int?> get powerW => _powerW;

  ValueListenable<int?> get heartRateBpm => _heartRateBpm;

  ValueListenable<int?> get cadenceRpm => _cadenceRpm;

  ValueListenable<double?> get speedKph => _speedKph;

  @override
  List<String> get serviceUUIDs => [for (final s in _relayedServices) normalizeUuid(s.uuid)];

  @override
  List<String> get advertiseServiceUUIDs => [
    for (final s in _relayedServices)
      if (shortUuidOf(s.uuid) == null || _advertisedProfiles.contains(shortUuidOf(s.uuid))) normalizeUuid(s.uuid),
  ];

  @override
  List<BleCharacteristic> getCharacteristics(String serviceUUID) {
    final wanted = normalizeUuid(serviceUUID);
    for (final service in _relayedServices) {
      if (normalizeUuid(service.uuid) == wanted) return service.characteristics;
    }
    return const [];
  }

  /// Starts listening to the trainer's own metrics as soon as the relay is
  /// up, so the app can show them before any trainer app has connected.
  @override
  void onAttached() {
    // The Zwift and Di2 definitions ride on this class without an upstream
    // trainer of their own.
    if (runtimeType != ProxyBikeDefinition) return;
    for (final characteristic in const [_heartRateMeasurement, _cyclingPowerMeasurement, _indoorBikeData]) {
      _subscribeUpstream(characteristic);
    }
  }

  @override
  void onEnableNotificationRequest(String characteristicUUID) => _subscribeUpstream(characteristicUUID);

  void _subscribeUpstream(String characteristicUUID) {
    final owner = _owners[normalizeUuid(characteristicUUID)];
    if (owner == null || _disposed) return;
    final properties = owner.characteristic.properties;
    final indicate =
        properties.contains(CharacteristicProperty.indicate) && !properties.contains(CharacteristicProperty.notify);
    if (!indicate && !properties.contains(CharacteristicProperty.notify)) return;
    if (!_subscribedUpstream.add(normalizeUuid(characteristicUUID))) return;
    _enqueueUpstream(
      'subscribe to ${owner.characteristic.uuid}',
      () => transport.subscribe(owner.service.uuid, owner.characteristic.uuid, indicate: indicate),
      onError: () => _subscribedUpstream.remove(normalizeUuid(characteristicUUID)),
    );
  }

  @override
  void onWriteRequest(String characteristicUUID, List<int> characteristicData) {
    final owner = _owners[normalizeUuid(characteristicUUID)];
    if (owner == null || _disposed) return;
    final properties = owner.characteristic.properties;
    final withoutResponse =
        properties.contains(CharacteristicProperty.writeWithoutResponse) &&
        !properties.contains(CharacteristicProperty.write);
    final value = Uint8List.fromList(characteristicData);
    _enqueueUpstream(
      'write ${owner.characteristic.uuid}',
      () => transport.write(owner.service.uuid, owner.characteristic.uuid, value, withoutResponse: withoutResponse),
    );
  }

  @override
  Future<Uint8List>? onReadRequest(String characteristicUUID) {
    final owner = _owners[normalizeUuid(characteristicUUID)];
    if (owner == null || _disposed) return null;
    return transport.read(owner.service.uuid, owner.characteristic.uuid);
  }

  /// Upstream operations run in order, so a sequence of control-point writes
  /// reaches the trainer as it was sent.
  void _enqueueUpstream(String what, Future<void> Function() op, {void Function()? onError}) {
    _upstreamQueue = _upstreamQueue.then((_) => op()).catchError((Object e, StackTrace s) {
      onError?.call();
      Logger.recordError('ProxyBikeDefinition: could not $what', e, s);
    });
  }

  @override
  void onNotification(String characteristic, Uint8List bytes) {
    if (_disposed) return;
    final normalized = normalizeUuid(characteristic);
    if (!_owners.containsKey(normalized)) return;
    _readMetrics(normalized, bytes);
    sendCharacteristicNotification(normalized, bytes);
  }

  void _readMetrics(String characteristic, Uint8List bytes) {
    try {
      switch (characteristic) {
        case _heartRateMeasurement:
          final hr = parseHeartRate(bytes);
          if (hr != null) _heartRateBpm.value = hr;
        case _cyclingPowerMeasurement:
          final power = parseCyclingPower(bytes);
          if (power != null) _powerW.value = power;
        case _indoorBikeData:
          final bike = parseIndoorBikeData(bytes);
          if (bike.speedKph != null) _speedKph.value = bike.speedKph;
          if (bike.cadenceRpm != null) _cadenceRpm.value = bike.cadenceRpm;
          if (bike.powerW != null) _powerW.value = bike.powerW;
          if (bike.heartRateBpm != null) _heartRateBpm.value = bike.heartRateBpm;
        default:
          return;
      }
    } catch (_) {
      return;
    }
    // The app shows the metrics once this is not empty, and redraws on change.
    data.value = [
      if (_powerW.value != null) '${_powerW.value} W',
      if (_cadenceRpm.value != null) '${_cadenceRpm.value} rpm',
      if (_speedKph.value != null) '${_speedKph.value!.toStringAsFixed(1)} km/h',
      if (_heartRateBpm.value != null) '${_heartRateBpm.value} bpm',
    ].join(' · ');
  }

  @override
  void dispose() {
    _disposed = true;
  }

  // Measurement parsing lives in ftms.dart, shared with the virtual bike.

  @visibleForTesting
  static int? parseHeartRate(Uint8List b) => parseHeartRateMeasurement(b);

  @visibleForTesting
  static int? parseCyclingPower(Uint8List b) => parseCyclingPowerWatts(b);

  @visibleForTesting
  static ({double? speedKph, int? cadenceRpm, int? powerW, int? heartRateBpm}) parseIndoorBikeData(Uint8List b) =>
      parseIndoorBikeDataFrame(b);
}
