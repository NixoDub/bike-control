
import 'package:flutter/foundation.dart';
import 'package:prop/emulators/ble_definition.dart';
import 'package:prop/emulators/transporter/transporter.dart';
import 'package:prop/utils/uuid.dart';
import 'package:universal_ble/universal_ble.dart';

/// Several definitions served as one virtual peripheral: the services of every
/// child are offered together, and each request is routed to the child whose
/// service carries the characteristic it names.
class CompositeBleDefinition extends BleDefinition {
  CompositeBleDefinition({List<BleDefinition> initial = const []}) {
    _children.addAll(initial);
  }

  final List<BleDefinition> _children = [];
  bool _serving = false;

  /// Read-only view of the currently attached children, in attach-order.
  List<BleDefinition> get children => List.unmodifiable(_children);

  /// Attach [def] as a new child. Returns `true` if it was newly added.
  bool attach(BleDefinition def) {
    if (_children.contains(def)) return false;
    _children.add(def);
    def.transporter = transporter;
    def.onAttached();
    if (_serving) def.onServerStarted();
    return true;
  }

  /// Detach [def]. Returns `true` if [def] was a current child.
  bool detach(BleDefinition def) {
    final removed = _children.remove(def);
    if (removed && _serving) def.onServerStopped();
    if (removed && identical(def.transporter, transporter)) def.transporter = null;
    return removed;
  }

  /// First child whose runtime type is [T], or `null` if none.
  T? firstOfType<T extends BleDefinition>() {
    for (final c in _children) {
      if (c is T) return c;
    }
    return null;
  }

  /// A child's pushes go out through whichever transporter the composite is
  /// bound to, so the binding is handed down.
  @override
  set transporter(Transporter? value) {
    super.transporter = value;
    for (final child in _children) {
      child.transporter = value;
    }
  }

  @override
  List<String> get serviceUUIDs {
    final seen = <String>{};
    return [
      for (final child in _children)
        for (final service in child.serviceUUIDs)
          if (seen.add(normalizeUuid(service))) normalizeUuid(service),
    ];
  }

  @override
  List<String> get advertiseServiceUUIDs {
    final seen = <String>{};
    return [
      for (final child in _children)
        for (final service in child.advertiseServiceUUIDs)
          if (seen.add(normalizeUuid(service))) normalizeUuid(service),
    ];
  }

  @override
  List<BleCharacteristic> getCharacteristics(String serviceUUID) {
    final wanted = normalizeUuid(serviceUUID);
    final seen = <String>{};
    return [
      for (final child in _children)
        if (child.serviceUUIDs.any((s) => normalizeUuid(s) == wanted))
          for (final characteristic in child.getCharacteristics(serviceUUID))
            if (seen.add(normalizeUuid(characteristic.uuid))) characteristic,
    ];
  }

  /// The children whose services carry [characteristicUUID].
  List<BleDefinition> ownersOf(String characteristicUUID) {
    final wanted = normalizeUuid(characteristicUUID);
    return [
      for (final child in _children)
        if (_carries(child, wanted)) child,
    ];
  }

  static bool _carries(BleDefinition child, String normalizedCharacteristic) {
    for (final service in child.serviceUUIDs) {
      for (final characteristic in child.getCharacteristics(service)) {
        if (normalizeUuid(characteristic.uuid) == normalizedCharacteristic) return true;
      }
    }
    return false;
  }

  @override
  void onWriteRequest(String characteristicUUID, List<int> characteristicData) {
    for (final owner in ownersOf(characteristicUUID)) {
      owner.onWriteRequest(characteristicUUID, characteristicData);
    }
  }

  @override
  Future<Uint8List>? onReadRequest(String characteristicUUID) {
    for (final owner in ownersOf(characteristicUUID)) {
      final read = owner.onReadRequest(characteristicUUID);
      if (read != null) return read;
    }
    return null;
  }

  @override
  void onEnableNotificationRequest(String characteristicUUID) {
    for (final owner in ownersOf(characteristicUUID)) {
      owner.onEnableNotificationRequest(characteristicUUID);
    }
  }

  @override
  void onNotification(String characteristic, Uint8List bytes) {
    dispatchNotification(characteristic, bytes);
  }

  /// Hands a notification from the upstream link to the children that carry
  /// [characteristic]. Returns whether any did.
  bool dispatchNotification(String characteristic, Uint8List bytes) {
    final owners = ownersOf(characteristic);
    for (final owner in owners) {
      owner.onNotification(characteristic, bytes);
    }
    return owners.isNotEmpty;
  }

  @override
  void onServerStarted() {
    if (_serving) return;
    _serving = true;
    for (final child in List<BleDefinition>.from(_children)) {
      child.onServerStarted();
    }
  }

  @override
  void onServerStopped() {
    if (!_serving) return;
    _serving = false;
    for (final child in List<BleDefinition>.from(_children)) {
      child.onServerStopped();
    }
  }

  @override
  void dispose() {
    for (final child in List<BleDefinition>.from(_children)) {
      child.dispose();
    }
  }

  @override
  void debug() {
    for (final child in _children) {
      child.debug();
    }
  }

  @visibleForTesting
  int get childCount => _children.length;
}
