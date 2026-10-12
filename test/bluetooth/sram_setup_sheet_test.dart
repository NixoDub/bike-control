import 'dart:async';

import 'package:bike_control/bluetooth/devices/sram/sram_setup_sheet.dart';
import 'package:bike_control/gen/l10n.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prop/prop.dart' show SramBondException;
import 'package:shadcn_flutter/shadcn_flutter.dart';

/// Which stage the guided sheet lands on for each way setup can fail: only a
/// refused authorization asks the rider to hold the AXS button; a link that
/// stopped answering says it is reconnecting instead.
void main() {
  Future<void> runWith(WidgetTester tester, Object error) async {
    await tester.pumpWidget(
      ShadcnApp(
        localizationsDelegates: const [AppLocalizations.delegate],
        supportedLocales: AppLocalizations.delegate.supportedLocales,
        home: Scaffold(
          child: SramGuidedSheet(
            title: 'Set up',
            intro: 'intro',
            successMessage: 'ok',
            confirmIcon: LucideIcons.slidersHorizontal,
            runningTitle: 'running',
            successTitle: 'done',
            checklistItems: const ['a', 'b'],
            operation: () async => throw error,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text(AppLocalizations.current.continueAction));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('decrypt failed → authorize (hold the AXS button)', (tester) async {
    await runWith(tester, SramBondException('create-bond decrypt failed — press and hold the AXS button'));
    expect(find.text(AppLocalizations.current.sramAuthorizeTitle), findsOneWidget);
    expect(find.text(AppLocalizations.current.sramLinkResetError), findsNothing);
  });

  testWidgets('handshake timeout → reconnecting error, not the authorize hero', (tester) async {
    await runWith(
      tester,
      SramBondException('handshake failed: TimeoutException after 0:00:15.000000: Future not completed'),
    );
    expect(find.text(AppLocalizations.current.sramAuthorizeTitle), findsNothing);
    expect(find.text(AppLocalizations.current.sramErrorTitle), findsOneWidget);
    expect(find.text(AppLocalizations.current.sramLinkResetError), findsOneWidget);
  });

  testWidgets('plain GATT timeout → reconnecting error', (tester) async {
    await runWith(tester, TimeoutException('Future not completed (write d9050028)', const Duration(seconds: 10)));
    expect(find.text(AppLocalizations.current.sramLinkResetError), findsOneWidget);
  });

  testWidgets('any other failure → generic error', (tester) async {
    await runWith(tester, StateError('boom'));
    expect(find.text(AppLocalizations.current.sramGenericError), findsOneWidget);
    expect(find.text(AppLocalizations.current.sramLinkResetError), findsNothing);
  });
}
