// The Settings plan card on a phone: "Sign in" and "Go Pro" must not starve
// the plan column, so the plan name ("TESTPHASE" in German) stays on one line
// instead of breaking mid-word. On a wide column the actions keep their place
// beside the plan.
import 'package:bike_control/pages/settings/settings_page.dart';
import 'package:bike_control/utils/iap/iap_manager.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../../widget_snapshot.dart';

/// Lines [finder]'s paragraph is laid out in.
int _lines(WidgetTester tester, Finder finder) {
  final paragraph = tester.renderObject<RenderParagraph>(finder);
  final painter = TextPainter(
    text: paragraph.text,
    textDirection: paragraph.textDirection,
    textScaler: paragraph.textScaler,
  )..layout(maxWidth: paragraph.size.width);
  final lines = painter.computeLineMetrics().length;
  painter.dispose();
  return lines;
}

Future<void> main() async {
  await ensureSnapshotHarness();

  setUp(() {
    IAPManager.instance.setProForTesting(enabled: false);
    IAPManager.instance.isPurchased.value = false;
  });

  tearDown(() {
    IAPManager.instance.isPurchased.value = true;
  });

  final planName = find.descendant(of: find.byKey(const ValueKey('settings-plan')), matching: find.text('TESTPHASE'));
  final goPro = find.text('Pro werden');

  testWidgets('phone width: the plan name stays on one line, nothing overflows', (tester) async {
    await captureWidget(
      tester,
      name: 'settings_plan_card_phone',
      width: 390,
      locales: const ['de'],
      brightness: Brightness.dark,
      builder: (context) => const SettingsPlanCard(),
      beforeCapture: (tester) async {
        expect(planName, findsOneWidget);
        expect(_lines(tester, planName), 1);
        expect(_lines(tester, find.text('Aktueller Plan')), 1);
        expect(goPro, findsOneWidget);
        expect(find.text('Anmelden'), findsOneWidget);
      },
    );
  });

  testWidgets('wide column: the actions sit beside the plan', (tester) async {
    await captureWidget(
      tester,
      name: 'settings_plan_card_wide',
      width: 720,
      locales: const ['de'],
      brightness: Brightness.dark,
      builder: (context) => const SettingsPlanCard(),
      beforeCapture: (tester) async {
        expect(_lines(tester, planName), 1);
        final name = tester.getRect(planName);
        final pill = tester.getRect(goPro);
        expect(pill.left, greaterThan(name.right));
        expect(pill.top, lessThan(name.bottom));
      },
    );
  });
}
