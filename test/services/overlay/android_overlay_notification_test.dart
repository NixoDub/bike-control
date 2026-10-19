import 'package:bike_control/gen/l10n.dart';
import 'package:bike_control/services/overlay/android_overlay_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('bike_control/overlay_actions');
  final calls = <MethodCall>[];
  late AppLocalizations l;

  setUpAll(() async => l = await AppLocalizations.load(const Locale('en')));

  void answer(Object? Function(int attempt) reply) {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return reply(calls.length);
    });
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('restyles the overlay notification with its own words', () async {
    answer((_) => true);

    expect(await styleAndroidOverlayNotification(l, retryDelay: Duration.zero), isTrue);

    expect(calls.single.method, 'styleOverlayNotification');
    expect(calls.single.arguments, {
      'title': l.overlayNotificationTitle,
      'text': l.overlayNotificationText,
      'channelName': l.overlayNotificationChannel,
    });
  });

  test('keeps trying until the overlay service has posted its notification', () async {
    // The service starts after showOverlay returns; until it has gone
    // foreground there is no notification to restyle.
    answer((attempt) => attempt >= 3);

    expect(await styleAndroidOverlayNotification(l, retryDelay: Duration.zero), isTrue);
    expect(calls, hasLength(3));
  });

  test('gives up after its attempts without throwing', () async {
    answer((_) => throw PlatformException(code: 'boom'));

    expect(await styleAndroidOverlayNotification(l, attempts: 4, retryDelay: Duration.zero), isFalse);
    expect(calls, hasLength(4));
  });
}
