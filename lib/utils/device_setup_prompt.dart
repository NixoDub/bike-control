import 'package:bike_control/bluetooth/devices/base_device.dart';
import 'package:dartx/dartx.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

/// Offers a controller's one-time setup ([DeviceSetupNeed.setup]) the moment
/// the controller turns up — once per setup per app session.
///
/// A controller that needs its setup does nothing until the rider has run it,
/// and a Zwift Click V2 is not even connected before then. Left to a row on
/// Devices it sits there unexplained, so the setup opens by itself instead,
/// the way the onboarding's controller step already does it.
///
/// Once is the rule: a rider who closes it has seen it and decided, and the
/// device's card on Ride keeps the way back in. The record is shared with the
/// onboarding, so a setup the rider closed there is not reopened the moment
/// the onboarding ends. It is not persisted — a controller still not set up at
/// the next launch is offered its setup once more.
abstract final class DeviceSetupPrompt {
  static final Set<String> _offered = {};

  /// The first of [devices] whose setup should open by itself now, or null.
  static BaseDevice? next(Iterable<BaseDevice> devices) => devices.firstOrNullWhere(
    (d) => d.setupNeed == DeviceSetupNeed.setup && !_offered.contains(d.setupPromptKey),
  );

  /// Records that [device]'s setup has been offered — opened by itself or by
  /// the rider.
  static void markOffered(BaseDevice device) => _offered.add(device.setupPromptKey);

  /// Whether [device]'s setup has been offered this session.
  static bool wasOffered(BaseDevice device) => _offered.contains(device.setupPromptKey);

  @visibleForTesting
  static void debugReset() => _offered.clear();
}
