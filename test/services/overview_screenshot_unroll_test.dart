// The support screenshot unrolls the page's scroll view into one tall image.
// Every part of the page has to show up in it exactly once.
//
// Two ways that went wrong:
// - The Help Center's support row captures Home while the Help Center (an
//   opaque route) covers it. A covered route is neither laid out nor painted,
//   so scrolling it changed nothing on screen: every slice was the same view
//   and the image repeated the page.
// - Beside the scroll view (the sidebar on wide windows) the slices repeated
//   whatever sat next to the viewport.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bike_control/services/overview_screenshot.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../widget_snapshot.dart';

const int _stripeCount = 30;
const double _stripeHeight = 50;
const Size _screen = Size(300, 600);
const double _sidebarWidth = 80;
const _sidebarTop = Color(0xFFFF00FF);
const _sidebarBottom = Color(0xFF00FFFF);
const _sidebarFill = Color(0xFF808080);

Color _stripe(int i) => Color.fromARGB(255, i * 8, 255 - i * 8, 40);

class _Rgba {
  _Rgba(this.width, this.height, this.bytes);
  final int width;
  final int height;
  final ByteData bytes;

  static Future<_Rgba> decodePng(Uint8List png) async {
    final codec = await ui.instantiateImageCodec(png);
    final image = (await codec.getNextFrame()).image;
    try {
      final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      return _Rgba(image.width, image.height, data);
    } finally {
      image.dispose();
    }
  }

  int pixel(int x, int y) {
    final i = (y * width + x) * 4;
    return (bytes.getUint8(i) << 16) | (bytes.getUint8(i + 1) << 8) | bytes.getUint8(i + 2);
  }

  /// The colours down column [x], one entry per run of identical pixels.
  List<int> runsAt(int x) {
    final runs = <int>[];
    for (var y = 0; y < height; y++) {
      final p = pixel(x, y);
      if (runs.isEmpty || runs.last != p) runs.add(p);
    }
    return runs;
  }
}

int _rgb(Color c) => c.toARGB32() & 0xFFFFFF;

Future<void> main() async {
  await ensureSnapshotHarness();

  Widget stripes() => ListView(
    key: const ValueKey('stripes'),
    padding: EdgeInsets.zero,
    children: [
      for (var i = 0; i < _stripeCount; i++) Container(height: _stripeHeight, color: _stripe(i)),
    ],
  );

  Future<void> pumpHome(WidgetTester tester, {bool sidebar = false}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = _screen;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ShadcnApp(
        debugShowCheckedModeBanner: false,
        home: ScreenshotScaffold(
          headers: const [],
          child: sidebar
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      width: _sidebarWidth,
                      color: _sidebarFill,
                      child: Column(
                        children: [
                          Container(height: 40, color: _sidebarTop),
                          const Spacer(),
                          Container(height: 40, color: _sidebarBottom),
                        ],
                      ),
                    ),
                    Expanded(child: stripes()),
                  ],
                )
              : stripes(),
        ),
      ),
    );
    await tester.pump();
  }

  Future<_Rgba> capture(WidgetTester tester, BuildContext context) async {
    late _Rgba result;
    await tester.runAsync(() async {
      var done = false;
      final pending = captureOverviewScreenshot(context: context).whenComplete(() => done = true);
      // The stitched capture scrolls the page and awaits a frame per step;
      // the test binding only produces frames when pumped.
      while (!done) {
        await Future<void>.delayed(const Duration(milliseconds: 16));
        if (!done) await tester.pump();
      }
      final attachment = await pending;
      expect(attachment, isNotNull);
      result = await _Rgba.decodePng(attachment!.file.bytes!);
    });
    return result;
  }

  void expectEachStripeAtMostOnce(List<int> runs) {
    for (var i = 0; i < _stripeCount; i++) {
      expect(runs.where((c) => c == _rgb(_stripe(i))).length, lessThanOrEqualTo(1), reason: 'stripe $i repeats');
    }
  }

  testWidgets('captured from a page covering Home, Home shows up once', (tester) async {
    await pumpHome(tester);
    // Scrolled a little, as a rider might have left it.
    tester.state<ScrollableState>(find.byType(Scrollable)).position.jumpTo(120);
    await tester.pump();

    Navigator.of(tester.element(find.byKey(const ValueKey('stripes')))).push(
      PageRouteBuilder<void>(
        pageBuilder: (_, _, _) => const ColoredBox(color: Color(0xFF000000), child: SizedBox.expand(key: ValueKey('help'))),
      ),
    );
    await tester.pumpAndSettle();

    final image = await capture(tester, tester.element(find.byKey(const ValueKey('help'))));
    expectEachStripeAtMostOnce(image.runsAt(image.width ~/ 2));
    // What the rider was looking at is in it.
    expect(image.runsAt(image.width ~/ 2), contains(_rgb(_stripe(3))));
    // Home is left where the rider had it.
    expect(tester.state<ScrollableState>(find.byType(Scrollable, skipOffstage: false)).position.pixels, 120);
  });

  testWidgets('on Home the whole page is unrolled, each stripe once', (tester) async {
    await pumpHome(tester);
    final image = await capture(tester, tester.element(find.byKey(const ValueKey('stripes'))));
    expect(image.height, (_stripeCount * _stripeHeight).round());
    final runs = image.runsAt(image.width ~/ 2);
    expect(runs, [for (var i = 0; i < _stripeCount; i++) _rgb(_stripe(i))]);
  });

  testWidgets('what sits beside the scroll view is not repeated by the slices', (tester) async {
    await pumpHome(tester, sidebar: true);
    final image = await capture(tester, tester.element(find.byKey(const ValueKey('stripes'))));
    expect(image.height, (_stripeCount * _stripeHeight).round());

    final page = image.runsAt(_sidebarWidth.toInt() + 50);
    expect(page, [for (var i = 0; i < _stripeCount; i++) _rgb(_stripe(i))]);

    final side = image.runsAt(_sidebarWidth ~/ 2);
    expect(side.where((c) => c == _rgb(_sidebarTop)).length, 1, reason: 'sidebar top: $side');
    expect(side.where((c) => c == _rgb(_sidebarBottom)).length, 1, reason: 'sidebar bottom: $side');
  });
}
