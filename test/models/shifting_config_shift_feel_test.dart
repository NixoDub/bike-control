import 'package:bike_control/models/shifting_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prop/emulators/definitions/fitness_bike_definition.dart';

/// How a shift feels (the gear step and the transition time) is stored on the
/// trainer's shifting config, like the difficulty: per trainer, kept across
/// restarts, and changeable in the app without a rebuild.
void main() {
  test('defaults to the table as it is, and a shift asked for at once', () {
    final cfg = ShiftingConfig.defaults(trainerKey: 'VICTORY');
    expect(cfg.gearStepPct, FitnessBikeDefinition.defaultGearStepPct);
    expect(cfg.shiftTransitionMs, 0);
  });

  test('a config stored before these existed reads as the defaults', () {
    final cfg = ShiftingConfig.fromJson({'name': 'Default', 'trainerKey': 'VICTORY', 'isActive': true});
    expect(cfg.gearStepPct, 100);
    expect(cfg.shiftTransitionMs, 0);
  });

  test('round-trips through JSON and is clamped on the way in', () {
    final cfg = ShiftingConfig.defaults(trainerKey: 'VICTORY').copyWith(gearStepPct: 180, shiftTransitionMs: 750);
    final back = ShiftingConfig.fromJson(cfg.toJson());
    expect(back.gearStepPct, 180);
    expect(back.shiftTransitionMs, 750);
    final wild = ShiftingConfig.fromJson({...cfg.toJson(), 'gearStepPct': 5, 'shiftTransitionMs': 99999});
    expect(wild.gearStepPct, FitnessBikeDefinition.minGearStepPct);
    expect(wild.shiftTransitionMs, FitnessBikeDefinition.maxShiftTransitionMs);
    expect(ShiftingConfig.fromJson({...cfg.toJson(), 'shiftTransitionMs': -3}).shiftTransitionMs, 0);
  });

  test('takes part in equality, so a changed feel is a changed config', () {
    final a = ShiftingConfig.defaults(trainerKey: 'VICTORY');
    expect(a.copyWith(gearStepPct: 150), isNot(a));
    expect(a.copyWith(shiftTransitionMs: 500), isNot(a));
    expect(a.copyWith(gearStepPct: 150, shiftTransitionMs: 500), a.copyWith(gearStepPct: 150, shiftTransitionMs: 500));
    expect(
      a.copyWith(gearStepPct: 150).hashCode,
      a.copyWith(gearStepPct: 150).hashCode,
    );
  });
}
