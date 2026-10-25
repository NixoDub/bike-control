import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:prop/emulators/ble_definition.dart';
import 'package:prop/emulators/definitions/composite_ble_definition.dart';
import 'package:prop/emulators/definitions/fitness_bike_definition.dart';
import 'package:prop/emulators/definitions/sensor_definition.dart';
import 'package:prop/emulators/definitions/zwift_click_definition.dart';
import 'package:prop/emulators/definitions/zwift_emulator_definition.dart';
import 'package:prop/emulators/transporter/network_transporter.dart';
import 'package:prop/mdns/service_advertiser.dart';
import 'package:prop/utils/advertised_service_registry.dart';
import 'package:prop/utils/network_address.dart';
import 'package:prop/utils/resilient_tcp_server.dart';
import 'package:prop/utils/self_advertisement_registry.dart';
import 'package:prop/utils/serialized_lifecycle.dart';
import 'package:prop/utils/shared.dart';
import 'package:prop/utils/uuid.dart';

enum RetrofitMode {
  proxy,
  wifi,
  bluetooth;

  String get label => switch (this) {
    RetrofitMode.proxy => 'Proxy',
    RetrofitMode.wifi => 'Virtual Shifting (WiFi)',
    RetrofitMode.bluetooth => 'Virtual Shifting (Bluetooth)',
  };
}

/// The port Wahoo's own trainers serve DirCon on. Some trainer apps dial it
/// without reading the port out of the mDNS record.
const int kWahooDirconStandardPort = 36866;

/// The mDNS service type a DirCon server is announced under.
const String kDirconServiceType = '_wahoo-fitness-tnp._tcp';

int _portNumberIterator = 36868;

/// Test seam: rebase the TCP port iterator.
@visibleForTesting
void debugSetDirconPortBase(int base) => _portNumberIterator = base;

/// Serves what is attached to its [composite] to trainer apps over DirCon: a
/// TCP server speaking the DirCon protocol, announced over mDNS so apps on the
/// network find it.
class DirconEmulator {
  /// [preferredPort] pins the TCP port the emulator asks its server to bind
  /// first. Left unset it auto-assigns a distinct port so concurrent
  /// instances don't pile onto one.
  DirconEmulator({int? preferredPort}) : _ownPort = preferredPort ?? _portNumberIterator++;

  final int _ownPort;

  /// Serve on the standard DirCon port instead of this instance's own port
  /// while it returns true.
  bool Function()? preferStandardPort;

  /// The port this emulator prefers for its DirCon TCP server. The port it
  /// *actually* bound is [boundPort] (may differ after fallback).
  int get preferredPort => preferStandardPort?.call() == true ? kWahooDirconStandardPort : _ownPort;

  /// Forces the TCP listener to IPv4 only while it returns true.
  bool Function()? forceIPv4;

  /// Overrides the advertised peripheral / service name.
  String? Function()? advertisementNameOverride;

  /// Advertises 16-bit service UUIDs in their bare form while it returns true.
  bool Function()? bareShortServiceUuids;

  final ValueNotifier<bool> isStarted = ValueNotifier(false);
  final ValueNotifier<bool> isConnected = ValueNotifier(false);
  final ValueNotifier<String> data = ValueNotifier('');

  final ValueNotifier<String?> _localAddressN = ValueNotifier<String?>(null);
  ValueListenable<String?> get localAddress => _localAddressN;

  int? get boundPort => _server?.isRunning == true ? _server!.boundPort : null;

  /// All child definitions exposed by this emulator share a single transport
  /// via this composite.
  final CompositeBleDefinition composite = CompositeBleDefinition();

  /// Callback deciding whether the emulator should advertise on session start.
  bool Function()? shouldAdvertise;

  /// Returns the connected trainer-app name (e.g. "Rouvy", "Zwift").
  String? Function()? trainerApp;

  /// Returns `true` when the user is in trial / non-Pro state.
  bool Function()? isTrial;

  /// Returns the connected device's display name.
  String? Function()? deviceName;

  /// The name the trainer app sees: the override when there is one, else
  /// "`<trainer>` - BikeControl", else plain "BikeControl".
  String get advertisementName {
    final override = advertisementNameOverride?.call();
    if (override != null && override.isNotEmpty) return override;
    final device = deviceName?.call();
    if (device == null || device.isEmpty) return 'BikeControl';
    return '$device - BikeControl';
  }

  final SerializedLifecycle _lifecycle = SerializedLifecycle();
  ResilientTcpServer? _server;
  NetworkTransporter? _transporter;
  ServiceAdvertisement? _advertisement;
  AdvertisedRecord? _record;
  ({String name, int port})? _selfEntry;
  InternetAddress? _address;
  RetrofitMode? _mode;
  Map<String, Uint8List> _mdnsTxt = const {};
  Map<String, Uint8List> Function()? _mdnsTxtBuilder;

  /// Hands a value the trainer notified to the definitions that carry it.
  /// Returns whether one did.
  bool processCharacteristic(String characteristic, Uint8List bytes) =>
      composite.dispatchNotification(characteristic, bytes);

  Future<void> startServer({
    required RetrofitMode mode,
    Map<String, Uint8List> mdnsTxt = const {},
    Map<String, Uint8List> Function()? mdnsTxtBuilder,
  }) => _lifecycle.run(() => _start(mode, mdnsTxt, mdnsTxtBuilder));

  Future<void> stop() => _lifecycle.run(_stop);

  /// Stops and starts again with the same settings, so a change in what is
  /// attached (or in the advertised name) reaches the trainer app.
  Future<void> restart() => _lifecycle.run(() async {
    final mode = _mode;
    if (!isStarted.value || mode == null) return;
    await _stop();
    await _start(mode, _mdnsTxt, _mdnsTxtBuilder);
  });

  /// Drops the connected trainer app so it connects afresh.
  void reconnect() => _server?.dropClient();

  /// Stops announcing without closing the server: a trainer app that is
  /// already connected keeps its connection, a new one cannot find us.
  Future<void> pauseAdvertising() => _lifecycle.run(_unadvertise);

  Future<void> debug() async {
    Logger.info(
      'DirCon emulator: started=${isStarted.value} connected=${isConnected.value} '
      'port=$boundPort address=${_localAddressN.value} name=$advertisementName '
      'services=${composite.serviceUUIDs}',
    );
  }

  Future<void> _start(RetrofitMode mode, Map<String, Uint8List> mdnsTxt, Map<String, Uint8List> Function()? builder) async {
    if (mode == RetrofitMode.bluetooth) {
      throw UnsupportedError('Bluetooth bridging is not available in this build; use a WiFi mode.');
    }
    _mode = mode;
    _mdnsTxt = mdnsTxt;
    _mdnsTxtBuilder = builder;

    if (_server == null) {
      final address = await AdvertisedAddressPicker.pick();
      if (address == null) {
        isStarted.value = false;
        throw 'Could not find network interface';
      }
      _address = address;
      final server = ResilientTcpServer(
        preferredPort: preferredPort,
        forceIPv4: forceIPv4?.call() ?? false,
        label: 'dircon',
        owner: this,
        onClientConnected: _onClientConnected,
        onData: (socket, bytes) => _transporter?.handleIncomingData(bytes),
        onClientDisconnected: _onClientDisconnected,
      );
      try {
        await server.start();
      } catch (e) {
        isStarted.value = false;
        rethrow;
      }
      _server = server;
      _localAddressN.value = address.address;
      isStarted.value = true;
      composite.onServerStarted();
    }

    try {
      await _advertise();
    } catch (e) {
      await _stop();
      rethrow;
    }
  }

  Future<void> _stop() async {
    composite.onServerStopped();
    await _unadvertise();
    _transporter?.dispose();
    _transporter = null;
    final server = _server;
    _server = null;
    await server?.stop();
    isStarted.value = false;
    isConnected.value = false;
    _localAddressN.value = null;
    _address = null;
  }

  void _onClientConnected(Socket socket) {
    _transporter?.dispose();
    _transporter = NetworkTransporter(socket: socket, definition: composite);
    isConnected.value = true;
    Logger.info('DirCon: client connected from ${socket.remoteAddress.address}');
  }

  void _onClientDisconnected() {
    _transporter?.dispose();
    _transporter = null;
    isConnected.value = false;
    Logger.info('DirCon: client disconnected');
  }

  /// Announces what the composite serves. A composite with nothing to
  /// advertise is not announced at all.
  Future<void> _advertise() async {
    await _unadvertise();
    final server = _server;
    final address = _address;
    if (server == null || address == null) return;
    if (!(shouldAdvertise?.call() ?? true)) return;
    final services = composite.advertiseServiceUUIDs;
    if (services.isEmpty) return;

    final txt = <String, Uint8List>{..._mdnsTxt, ...?_mdnsTxtBuilder?.call()};
    txt.putIfAbsent('ble-service-uuids', () => Uint8List.fromList(bleServiceUuidsTxt(services).codeUnits));

    final name = advertisementName;
    final service = AdvertisedService(
      name: name,
      type: kDirconServiceType,
      port: server.boundPort,
      address: address,
      txt: txt,
    );
    _advertisement = await ServiceAdvertiser.instance.register(service);
    _record = AdvertisedServiceRegistry.instance.add(
      name: name,
      type: kDirconServiceType,
      port: server.boundPort,
      address: address.address,
      txt: txt,
    );
    _selfEntry = (name: name, port: server.boundPort);
    SelfAdvertisementRegistry.instance.add(name: name, port: server.boundPort);
  }

  Future<void> _unadvertise() async {
    final advertisement = _advertisement;
    _advertisement = null;
    final record = _record;
    _record = null;
    final entry = _selfEntry;
    _selfEntry = null;
    if (record != null) AdvertisedServiceRegistry.instance.remove(record);
    if (entry != null) SelfAdvertisementRegistry.instance.remove(name: entry.name, port: entry.port);
    try {
      await advertisement?.unregister();
    } catch (e) {
      Logger.warn('DirCon: could not withdraw the mDNS announcement: $e');
    }
  }

  /// The `ble-service-uuids` TXT value: the 16-bit services as `0x1826` (or
  /// `1826` when [bareShortServiceUuids] says the trainer app wants it bare),
  /// custom ones in full.
  @visibleForTesting
  String bleServiceUuidsTxt(List<String> services) {
    final bare = bareShortServiceUuids?.call() ?? false;
    return services.map((uuid) {
      final short = shortUuidOf(uuid);
      if (short != null) return bare ? short : '0x$short';
      return normalizeUuid(uuid).toUpperCase();
    }).join(',');
  }

  BleDefinition? get activeDefinition => composite;

  /// Whether the composite holds nothing a trainer app would connect for —
  /// rider-metric sinks alone don't count.
  bool get hasNothingToServe => composite.children.every((c) => c is SensorDefinition);

  /// Attach [def] as a child of this emulator's [composite]. A running
  /// emulator announces itself again, so the trainer app learns of the change.
  Future<void> attachDefinition(BleDefinition def) async {
    if (def is ZwiftClickDefinition && composite.firstOfType<ZwiftEmulatorDefinition>() != null) {
      composite.detach(composite.firstOfType<ZwiftEmulatorDefinition>()!);
    }
    composite.attach(def);
    await _reAdvertiseIfRunning();
  }

  /// Detach [def] from this emulator's [composite].
  Future<void> detachDefinition(BleDefinition def) async {
    composite.detach(def);
    await _reAdvertiseIfRunning();
  }

  Future<void> _reAdvertiseIfRunning() => _lifecycle.run(() async {
    if (_server == null) return;
    try {
      await _advertise();
    } catch (e, s) {
      Logger.recordError('DirCon: could not announce the new set of services', e, s);
    }
  });

  FitnessBikeDefinition? get fitnessBike => composite.firstOfType<FitnessBikeDefinition>();

  @visibleForTesting
  void debugSetActiveDefinition(BleDefinition def) {
    for (final c in List<BleDefinition>.from(composite.children)) {
      composite.detach(c);
    }
    composite.attach(def);
  }

  @visibleForTesting
  void debugSetTransporter(NetworkTransporter transporter) {
    _transporter = transporter;
  }
}
