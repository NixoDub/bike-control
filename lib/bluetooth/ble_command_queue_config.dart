import 'package:universal_ble/universal_ble.dart';

/// Pins how universal_ble schedules GATT commands, instead of relying on the
/// 3.x default (`QueueType.auto`: per-device on Android/Web/Linux, fully
/// parallel on iOS/macOS/Windows).
///
/// Central role: [QueueType.perDevice] on every platform. Each device's
/// protocol code (handshakes, subscribe-then-write sequences, fire-and-forget
/// shift/haptic writes) was written against one GATT operation in flight per
/// device at a time — what the 2.x global queue guaranteed — so that ordering
/// is kept everywhere. Unlike the old global queue, a slow or stalled command
/// on one device (e.g. a trainer write waiting for its timeout) no longer holds
/// up the controllers.
///
/// Peripheral role (the emulated trainer/controller BikeControl advertises):
/// [QueueType.none], i.e. notifications are handed to the platform directly,
/// as before the peripheral queue existed. Its callers already pace and order
/// their notifications.
void configureBleCommandQueues() {
  UniversalBle.queueType = QueueType.perDevice;
  UniversalBlePeripheral.queueType = QueueType.none;
}
