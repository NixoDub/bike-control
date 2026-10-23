import 'dart:async';

import 'package:bike_control/utils/settings/settings.dart';

/// What the rider is being told about a shift.
enum ShiftCue {
  /// A rear shift to a harder gear went through.
  up,

  /// A rear shift to an easier gear went through.
  down,

  /// The shift was rejected: already in the highest / lowest gear (or at the
  /// ERG stepping boundary).
  limit,
}

/// Phone vibration sink. Implemented with `HapticFeedback` on mobile; a no-op
/// elsewhere. Injected so the service can be tested without a platform.
abstract class ShiftHaptics {
  Future<void> play(ShiftCue cue);
}

/// Vibration on the controller whose button shifted, e.g. a gamepad's rumble
/// motors. A no-op for controllers that can't vibrate or buzz by themselves.
abstract class ControllerShiftHaptics {
  Future<void> play(ShiftCue cue, {required String deviceId});
}

/// Short-clip sink. One implementation per audio stack (just_audio on
/// iOS/Android/macOS, winmm on Windows, silent otherwise).
abstract class ShiftSoundPlayer {
  /// Decode the clips ahead of time so the first shift isn't late.
  Future<void> preload();

  Future<void> play(ShiftCue cue);

  Future<void> dispose();
}

typedef ShiftFeedbackErrorHandler = void Function(String context, Object error, StackTrace stack);

/// Turns a shift outcome into phone feedback — haptics and/or a sound — as
/// chosen in settings. Both default off.
///
/// Callers report what actually happened rather than the service guessing
/// from an [ActionResult]: in virtual-shifting mode a *successful* shift is
/// reported as `Ignored("shifted up")` (control flow for "handled, don't
/// forward"), so the result type alone can't tell a shift from a rejected
/// one. See `ProxyDevice.handleTrainerAction` and
/// `BaseActions.performAction` for the two call sites.
///
/// The sound player is created lazily the first time sound is actually
/// needed, so riders who never enable it never touch the audio session.
class ShiftFeedbackService {
  ShiftFeedbackService({
    required Settings settings,
    required ShiftHaptics haptics,
    ControllerShiftHaptics? controllerHaptics,
    required ShiftSoundPlayer Function() createSoundPlayer,
    required ShiftFeedbackErrorHandler onError,
  }) : _settings = settings,
       _haptics = haptics,
       _controllerHaptics = controllerHaptics,
       _createSoundPlayer = createSoundPlayer,
       _onError = onError;

  final Settings _settings;
  final ShiftHaptics _haptics;
  final ControllerShiftHaptics? _controllerHaptics;
  final ShiftSoundPlayer Function() _createSoundPlayer;
  final ShiftFeedbackErrorHandler _onError;

  Future<ShiftSoundPlayer>? _soundsReady;

  // A shift can land before Settings.init() has finished (and unit tests
  // routinely run without prefs); treat "not initialised" as off.
  bool get hapticsEnabled => _settings.isInitialized && _settings.getShiftHapticsEnabled();
  bool get soundEnabled => _settings.isInitialized && _settings.getShiftSoundEnabled();

  /// The controller-side buzz, shown on the controller page of each
  /// controller that can vibrate. On by default, like Zwift controllers.
  bool get controllerHapticsEnabled => _settings.isInitialized && _settings.getVibrationEnabled();

  /// Call once at startup: warms the sound player if the rider has sound on.
  Future<void> prepare() async {
    if (!soundEnabled) return;
    await _ensureSounds();
  }

  /// A rear shift went through, [up] = harder gear. [sourceDeviceId] is the
  /// controller whose button shifted, if any, so it can buzz too.
  Future<void> shifted({required bool up, String? sourceDeviceId}) =>
      _emit(up ? ShiftCue.up : ShiftCue.down, sourceDeviceId: sourceDeviceId);

  /// A shift was rejected because there is no next gear.
  Future<void> atLimit({String? sourceDeviceId}) => _emit(ShiftCue.limit, sourceDeviceId: sourceDeviceId);

  Future<void> setHapticsEnabled(bool enabled) async {
    await _settings.setShiftHapticsEnabled(enabled);
    if (enabled) await _playHaptic(ShiftCue.up);
  }

  Future<void> setSoundEnabled(bool enabled) async {
    await _settings.setShiftSoundEnabled(enabled);
    if (enabled) {
      await _playSound(ShiftCue.up);
    } else {
      await _disposeSounds();
    }
  }

  Future<void> _emit(ShiftCue cue, {String? sourceDeviceId}) async {
    await Future.wait([
      if (hapticsEnabled) _playHaptic(cue),
      if (soundEnabled) _playSound(cue),
      if (sourceDeviceId != null && controllerHapticsEnabled) _playControllerHaptic(cue, sourceDeviceId),
    ]);
  }

  Future<void> _playControllerHaptic(ShiftCue cue, String deviceId) async {
    final controllerHaptics = _controllerHaptics;
    if (controllerHaptics == null) return;
    try {
      await controllerHaptics.play(cue, deviceId: deviceId);
    } catch (e, s) {
      _onError('ShiftFeedback.controllerHaptic', e, s);
    }
  }

  Future<void> _playHaptic(ShiftCue cue) async {
    try {
      await _haptics.play(cue);
    } catch (e, s) {
      _onError('ShiftFeedback.haptic', e, s);
    }
  }

  Future<void> _playSound(ShiftCue cue) async {
    try {
      final player = await _ensureSounds();
      await player.play(cue);
    } catch (e, s) {
      _onError('ShiftFeedback.sound', e, s);
    }
  }

  Future<ShiftSoundPlayer> _ensureSounds() {
    return _soundsReady ??= () async {
      final player = _createSoundPlayer();
      await player.preload();
      return player;
    }();
  }

  Future<void> _disposeSounds() async {
    final pending = _soundsReady;
    _soundsReady = null;
    if (pending == null) return;
    try {
      final player = await pending;
      await player.dispose();
    } catch (e, s) {
      _onError('ShiftFeedback.dispose', e, s);
    }
  }
}
