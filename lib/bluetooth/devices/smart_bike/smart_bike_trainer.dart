import 'package:bike_control/bluetooth/devices/bluetooth_device.dart';
import 'package:bike_control/bluetooth/devices/proxy/proxy_device.dart';
import 'package:bike_control/bluetooth/messages/notification.dart';
import 'package:bike_control/main.dart' show recordError;
import 'package:bike_control/utils/core.dart';
import 'package:flutter/foundation.dart';
import 'package:prop/emulators/definitions/fitness_bike_definition.dart';
import 'package:universal_ble/universal_ble.dart';

/// The smart-trainer half of a smart bike.
///
/// A smart bike (KICKR BIKE, Stages SB20, …) is one Bluetooth peripheral that
/// is both a smart trainer and the host of its own shift buttons. One
/// peripheral maps to one device class, and the bike is classified by name as
/// its controller class (a [SmartBikeHost]) so its buttons keep working. When
/// that controller's service discovery finds a trainer service, it attaches
/// this trainer role next to itself, so the same bike is also listed, bridged
/// and controlled like any other [ProxyDevice].
///
/// The controller owns the Bluetooth link: it connects as soon as the bike is
/// found, while a trainer is only bridged once the rider asked for it. This
/// role therefore never opens or closes the link itself — it rides on the
/// controller's connection ([connectUpstream] / [disconnectUpstream]), and
/// the controller tears it down whenever its own connection goes away (see
/// [SmartBikeHost.disconnect]), so a dropped bike never leaves a trainer
/// entry behind that still looks alive.
class SmartBikeTrainer extends ProxyDevice {
  /// [scanResult] should come from [trainerScanResult]; [discovered] is the
  /// host's full GATT database, from which the host's own services are
  /// dropped.
  SmartBikeTrainer(super.scanResult, {required this.host, required List<BleService> discovered})
    : _trainerServices = discovered.where((s) => !host.controllerServiceUuids.contains(s.uuid.toLowerCase())).toList();

  /// The controller that owns the Bluetooth link to the bike.
  final SmartBikeHost host;

  /// The bike's GATT database as discovered by [host], minus the host's own
  /// services ([SmartBikeHost.controllerServiceUuids]) — those belong to the
  /// controller role, and mirroring them through a Proxy bridge would hand
  /// the trainer app a second copy of the buttons BikeControl is already
  /// acting on, or a vendor channel it has no business with.
  final List<BleService> _trainerServices;

  /// The services that make a peripheral a trainer BikeControl can drive:
  /// FTMS, FE-C over BLE, or Cycling Power (Proxy only, like any power-only
  /// trainer). Heart rate is deliberately not one of them — a bike relaying a
  /// strap is not a trainer because of it.
  static final _trainerServiceUuids = {
    FitnessBikeDefinition.FITNESS_MACHINE_SERVICE_UUID.toLowerCase(),
    FitnessBikeDefinition.FEC_BLE_SERVICE_UUID.toLowerCase(),
    FitnessBikeDefinition.CYCLING_POWER_SERVICE_UUID.toLowerCase(),
  };

  /// The scan result for [host]'s trainer role, built from the services its
  /// discovery returned — or null when the bike exposes no trainer service;
  /// then it stays a controller only.
  ///
  /// The scan advertisement is not trusted for this: whether the bike lists
  /// its trainer services there is unknown, so the role's own scan result
  /// carries the trainer services actually discovered. That is what
  /// [isSmartTrainer] (and with it the default bridge mode) reads.
  static BleDevice? trainerScanResult(BluetoothDevice host, List<BleService> discovered) {
    final found = discovered.map((s) => s.uuid.toLowerCase()).where(_trainerServiceUuids.contains).toSet();
    if (found.isEmpty) return null;

    final ad = host.scanResult;
    return BleDevice(
      deviceId: ad.deviceId,
      name: ad.rawName ?? ad.name,
      rssi: ad.rssi,
      paired: ad.paired,
      services: {...ad.services.map((s) => s.toLowerCase()), ...found}.toList(),
      isSystemDevice: ad.isSystemDevice,
      manufacturerDataList: ad.manufacturerDataList,
      serviceData: ad.serviceData,
    );
  }

  @override
  Future<void> connectUpstream() async {
    // Never a second connect to the same peripheral: the controller already
    // holds the link. Without it there is nothing to ride on — fail like a
    // real connect would, rather than report a trainer that is not there.
    if (!host.isConnected) {
      throw StateError('$this: the Bluetooth connection to the bike is not up');
    }
    // The link was up before this role existed, so no connection-state event
    // will ever arrive to flip this flag — set it here, like a WiFi trainer.
    isConnected = true;
    core.connection.signalChange(this);
  }

  /// The controller's discovery already ran on this exact link; a copy, since
  /// [disconnect] clears the list it was handed.
  @override
  Future<List<BleService>> discoverUpstreamServices() async => _trainerServices.toList();

  /// Stopping the bridge must not cut the controller's link — the buttons
  /// keep working after "No connection". The link goes down with the
  /// controller, which then releases this role.
  @override
  Future<void> disconnectUpstream() async {}

  @override
  Future<void> processCharacteristic(String characteristic, Uint8List bytes) {
    // Notifications are routed by device id, and both roles share one. Hand
    // button frames to the controller whichever role received them.
    if (host.isControllerCharacteristic(characteristic)) {
      return host.processCharacteristic(characteristic, bytes);
    }
    return super.processCharacteristic(characteristic, bytes);
  }
}

/// The controller half of a smart bike: owns the link, and lists the bike a
/// second time as a [SmartBikeTrainer] when its discovery finds a trainer
/// service.
mixin SmartBikeHost on BluetoothDevice {
  /// The host's own services (lower-case) — never mirrored by the trainer role.
  Set<String> get controllerServiceUuids;

  /// The host's button characteristics (lower-case) — routed back to the host
  /// whichever role receives them.
  Set<String> get controllerCharacteristicUuids;

  bool isControllerCharacteristic(String characteristic) =>
      controllerCharacteristicUuids.contains(characteristic.toLowerCase());

  /// Builds the trainer role. Overridable so a bike can keep its own role
  /// type; the default is a plain [SmartBikeTrainer].
  @protected
  SmartBikeTrainer createTrainer(BleDevice scanResult, List<BleService> discovered) =>
      SmartBikeTrainer(scanResult, host: this, discovered: discovered);

  /// The bike's trainer role, when its service discovery found a trainer
  /// service; null for a bike that exposes only its buttons, which then stays
  /// a controller only.
  SmartBikeTrainer? get trainer => _trainer;
  SmartBikeTrainer? _trainer;

  /// A smart bike's link is not a battery to save, and cutting it would take a
  /// running bridge down with it — mid-ride, without a single button press.
  @override
  bool get exemptFromBatterySaver => _trainer?.isConnectedOrConnecting ?? false;

  /// Lists the bike a second time, as a trainer, when it exposes a trainer
  /// service — over this same connection. Not on web, where BikeControl has no
  /// trainer bridge at all.
  @protected
  Future<void> attachTrainer(List<BleService> services) async {
    if (kIsWeb) return;
    // A previous connection's role cannot outlive it (see [disconnect]); this
    // only guards a repeated discovery on the same link.
    await _releaseTrainer();
    final scanResult = SmartBikeTrainer.trainerScanResult(this, services);
    if (scanResult == null) return;
    final trainer = createTrainer(scanResult, services);
    _trainer = trainer;
    core.connection.signalNotification(LogNotification('$this: trainer services found, also listed as a trainer'));
    core.connection.addDevices([trainer]);
  }

  /// Notifications are routed by device id, which the trainer role shares —
  /// everything that is not one of the host's characteristics is the
  /// trainer's.
  @protected
  Future<void> forwardToTrainer(String characteristic, Uint8List bytes) =>
      _trainer?.processCharacteristic(characteristic, bytes) ?? Future.value();

  /// Removes the trainer role together with this connection, so the bike is
  /// never left listed as a trainer whose link is gone.
  Future<void> _releaseTrainer() async {
    final trainer = _trainer;
    _trainer = null;
    if (trainer == null) return;
    try {
      await core.connection.disconnect(
        trainer,
        forget: false,
        persistForget: false,
        dropped: trainer.isConnectedOrConnecting,
      );
    } catch (e, s) {
      await recordError(e, s, context: '$runtimeType: release trainer role');
    }
  }

  @override
  Future<void> disconnect() async {
    await _releaseTrainer();
    return super.disconnect();
  }
}
