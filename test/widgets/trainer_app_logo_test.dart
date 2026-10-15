import 'package:bike_control/widgets/ui/trainer_app_logo.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

void main() {
  Widget host(Widget child) => Directionality(textDirection: TextDirection.ltr, child: Center(child: child));

  testWidgets('falls back to the network logo when the asset is missing', (tester) async {
    await tester.pumpWidget(host(const TrainerAppLogo(
      asset: 'assets/does-not-exist.png',
      url: 'https://bikecontrol.app/images/partners/example.png',
      width: 22,
      height: 22,
    )));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();

    final network = find.byWidgetPredicate((w) => w is Image && w.image is NetworkImage);
    expect(network, findsOneWidget);
    expect((tester.widget<Image>(network).image as NetworkImage).url,
        'https://bikecontrol.app/images/partners/example.png');
  });

  testWidgets('renders an empty box of the same size without a fallback url', (tester) async {
    await tester.pumpWidget(host(const TrainerAppLogo(
      asset: 'assets/does-not-exist.png',
      width: 22,
      height: 22,
    )));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();

    expect(find.byWidgetPredicate((w) => w is Image && w.image is NetworkImage), findsNothing);
    expect(tester.getSize(find.byType(TrainerAppLogo)), const Size(22, 22));
  });

  testWidgets('shows the bundled asset when it exists', (tester) async {
    await tester.pumpWidget(host(const TrainerAppLogo(
      asset: 'assets/strappo.png',
      url: 'https://bikecontrol.app/images/partners/example.png',
      width: 22,
      height: 22,
    )));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();

    expect(find.byWidgetPredicate((w) => w is Image && w.image is AssetImage), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is Image && w.image is NetworkImage), findsNothing);
  });
}
