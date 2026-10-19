import 'package:bike_control/services/overlay/overlay_state.dart';
import 'package:bike_control/widgets/overlay/trainer_overlay_view.dart';
import 'package:bike_control/widgets/ui/type_scale.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prop/emulators/definitions/fitness_bike_definition.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

void main() {
  ValueNotifier<TrainerOverlayState> mkState({
    int gear = 14,
    int maxGear = 24,
    int? powerW = 178,
    int? cadenceRpm = 86,
    Set<OverlayField> fields = const {OverlayField.power, OverlayField.cadence},
    TrainerMode mode = TrainerMode.simMode,
    bool frontShiftEnabled = false,
    bool frontRingLarge = false,
  }) {
    return ValueNotifier(
      TrainerOverlayState(
        gear: gear,
        maxGear: maxGear,
        gearRatio: 2.43,
        mode: mode,
        powerW: powerW,
        cadenceRpm: cadenceRpm,
        ergTargetW: null,
        fields: fields,
        frontShiftEnabled: frontShiftEnabled,
        frontRingLarge: frontRingLarge,
      ),
    );
  }

  testWidgets('renders the gear on its own (GEAR under it) and the mode pill', (tester) async {
    await tester.pumpWidget(
      ShadcnApp(
        home: Scaffold(
          child: TrainerOverlayView(state: mkState(), onModeToggle: null),
        ),
      ),
    );
    expect(find.text('14'), findsOneWidget);
    expect(find.text('14/24'), findsNothing, reason: 'the total is not what a rider glances for');
    expect(find.text('SIM'), findsOneWidget);
  });

  testWidgets('the ratio reads like Ride: ×2.43 trimmed of trailing zeros', (tester) async {
    await tester.pumpWidget(
      ShadcnApp(
        home: Scaffold(
          child: TrainerOverlayView(
            state: mkState(fields: const {OverlayField.gearRatio}),
            onModeToggle: null,
          ),
        ),
      ),
    );
    expect(find.text('×2.43'), findsOneWidget);
  });

  testWidgets('renders 2×N position notation when front shift is on', (tester) async {
    await tester.pumpWidget(
      ShadcnApp(
        home: Scaffold(
          child: TrainerOverlayView(
            state: mkState(frontShiftEnabled: true, frontRingLarge: true),
            onModeToggle: null,
          ),
        ),
      ),
    );
    expect(find.text('2×14'), findsOneWidget);
    expect(find.text('14'), findsNothing);
  });

  testWidgets('hides power when not selected', (tester) async {
    await tester.pumpWidget(
      ShadcnApp(
        home: Scaffold(
          child: TrainerOverlayView(
            state: mkState(fields: const {OverlayField.cadence}),
            onModeToggle: null,
          ),
        ),
      ),
    );
    expect(find.textContaining('W'), findsNothing);
    expect(find.textContaining('rpm'), findsOneWidget);
  });

  testWidgets('shows -- for null power and cadence', (tester) async {
    await tester.pumpWidget(
      ShadcnApp(
        home: Scaffold(
          child: TrainerOverlayView(
            state: mkState(powerW: null, cadenceRpm: null),
            onModeToggle: null,
          ),
        ),
      ),
    );
    expect(find.textContaining('--'), findsWidgets);
  });

  testWidgets('the -/gear/+ row fits its desktop window at 1.3x text with every field on', (tester) async {
    final needed = TrainerOverlayView.windowSize(const TextScaler.linear(1.3)).width;
    final window = needed > TrainerOverlayView.defaultWindowWidth ? needed : TrainerOverlayView.defaultWindowWidth;
    await tester.pumpWidget(
      ShadcnApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
          child: Scaffold(
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: window,
                child: TrainerOverlayView(
                  state: mkState(
                    fields: const {
                      OverlayField.controls,
                      OverlayField.power,
                      OverlayField.cadence,
                      OverlayField.gearRatio,
                    },
                  ),
                  onPrimaryDecrement: () {},
                  onPrimaryIncrement: () {},
                  onDragStart: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull, reason: 'no overflow');
    final card = tester.getRect(find.byType(TrainerOverlayView));
    for (final icon in [LucideIcons.minus, LucideIcons.plus]) {
      final button = tester.getRect(find.byIcon(icon));
      expect(card.left <= button.left && button.right <= card.right, isTrue, reason: '$icon at $button, card $card');
    }
    expect(find.text('14'), findsOneWidget);
  });

  group('the Android pill', () {
    Future<RenderBox> pumpPill(WidgetTester tester, Set<OverlayField> fields) async {
      await tester.pumpWidget(
        ShadcnApp(
          home: Scaffold(
            child: Center(
              child: TrainerOverlayView(
                key: const ValueKey('pill'),
                state: mkState(fields: fields),
                pill: true,
                onPrimaryDecrement: () {},
                onPrimaryIncrement: () {},
              ),
            ),
          ),
        ),
      );
      return tester.renderObject<RenderBox>(find.byKey(const ValueKey('pill')));
    }

    for (final fields in [
      const {OverlayField.power, OverlayField.cadence},
      const {OverlayField.controls, OverlayField.power, OverlayField.cadence, OverlayField.gearRatio},
      const <OverlayField>{},
    ]) {
      testWidgets('is as wide as what it shows: $fields', (tester) async {
        final box = await pumpPill(tester, fields);
        final ctx = tester.element(find.byKey(const ValueKey('pill')));
        final fit = TrainerOverlayView.fitWindowSizeOf(ctx, mkState(fields: fields).value, drag: false);
        expect(box.size.width, fit.width, reason: 'no empty room for fields that are off');
        expect(
          fit.width,
          lessThan(TrainerOverlayView.fitWindowSizeOf(ctx, mkState(fields: fields).value).width),
          reason: 'nor for a drag handle it does not draw (the whole window drags)',
        );
        expect(tester.takeException(), isNull, reason: 'and nothing overflows');
      });
    }
  });

  group('room for watts', () {
    TrainerOverlayState ride(int watts) => mkState(powerW: watts, cadenceRpm: 188).value;

    testWidgets('keeps room for three-digit watts, not four', (tester) async {
      await tester.pumpWidget(const ShadcnApp(home: SizedBox()));
      final ctx = tester.element(find.byType(SizedBox));
      final withPower = TrainerOverlayView.fitWindowSizeOf(ctx, ride(245), drag: false).width;
      final withoutPower = TrainerOverlayView.fitWindowSizeOf(
        ctx,
        mkState(cadenceRpm: 92, fields: const {OverlayField.cadence}).value,
        drag: false,
      ).width;
      final fourDigits = TextPainter(
        text: TextSpan(
          style: Theme.of(ctx).typography.caption,
          children: [
            TextSpan(text: '8888', style: BkNumerals.display(20, height: 1.0)),
            const TextSpan(text: ' W'),
          ],
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      expect(withPower - withoutPower, lessThan(fourDigits.width + 10), reason: 'no room kept for a fourth digit');
      fourDigits.dispose();
    });

    testWidgets('a sprint over 999 W keeps cadence on, a little smaller', (tester) async {
      await tester.pumpWidget(
        ShadcnApp(
          home: Scaffold(
            child: Center(
              child: TrainerOverlayView(state: ValueNotifier(ride(1888)), pill: true),
            ),
          ),
        ),
      );
      expect(find.textContaining("1888"), findsOneWidget);
      expect(find.textContaining("188 rpm"), findsOneWidget, reason: 'cadence does not give way to a sprint');
      expect(tester.takeException(), isNull);
    });
  });
}
