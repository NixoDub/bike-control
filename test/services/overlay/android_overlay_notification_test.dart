import 'package:bike_control/gen/l10n.dart';
import 'package:bike_control/services/overlay/android_overlay_controller.dart';
import 'package:bike_control/utils/core.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show Locale, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
      'hideLabel': l.overlayHide,
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

  group('the notification\'s Hide overlay button', () {
    const pluginChannel = MethodChannel('x-slayer/overlay_channel');
    final pluginCalls = <String>[];

    setUp(() async {
      SharedPreferences.setMockInitialValues({'overlay_enabled': true});
      core.settings.prefs = await SharedPreferences.getInstance();
      pluginCalls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(pluginChannel, (
        call,
      ) async {
        pluginCalls.add(call.method);
        return true;
      });
      answer((_) => null);
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(pluginChannel, null);
    });

    Future<void> tapHide() async {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(const MethodCall('action', 'hideOverlay')),
        (_) {},
      );
    }

    test('switches the overlay off like the Overlay section\'s switch', () async {
      final controller = AndroidOverlayController();

      await tapHide();

      expect(pluginCalls, contains('closeOverlay'));
      expect(controller.isShowing.value, isFalse);
      // Persisted, or the next trainer reconnect would put it straight back.
      expect(core.settings.getOverlayEnabled(), isFalse);
    });

    test('works in a run that never showed the overlay — the overlay can outlive the screen that opened it', () async {
      // No show() in this isolate: Android recreated the app's screen while
      // the overlay service kept running.
      AndroidOverlayController();

      await tapHide();

      expect(pluginCalls, contains('closeOverlay'));
      expect(core.settings.getOverlayEnabled(), isFalse);
    });

    test('a close that fails still switches the overlay off', () async {
      AndroidOverlayController();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(pluginChannel, (
        call,
      ) async {
        throw PlatformException(code: 'service-gone');
      });

      await tapHide();

      expect(core.settings.getOverlayEnabled(), isFalse);
    });
  });

  group('resizing the overlay window', () {
    const pluginChannel = MethodChannel('x-slayer/overlay_channel');
    const overlayChannel = MethodChannel('x-slayer/overlay');
    final resizes = <Object?>[];

    void setUpPlugin({required bool active}) {
      resizes.clear();
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        pluginChannel,
        (call) async => call.method == 'isOverlayActive' ? active : null,
      );
      messenger.setMockMethodCallHandler(overlayChannel, (call) async {
        if (call.method == 'resizeOverlay') resizes.add(call.arguments);
        return true;
      });
    }

    tearDown(() {
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(pluginChannel, null);
      messenger.setMockMethodCallHandler(overlayChannel, null);
    });

    test('resizes the window to the card plus its margin', () async {
      setUpPlugin(active: true);
      await resizeAndroidOverlayWindow(const Size(200, 80));
      expect(resizes, hasLength(1));
      expect((resizes.single as Map)['width'], 200 + androidOverlayMargin);
      expect((resizes.single as Map)['height'], 80 + androidOverlayMargin);
    });

    test('leaves it alone while there is no window — the engine runs before the overlay is shown', () async {
      setUpPlugin(active: false);
      await resizeAndroidOverlayWindow(const Size(200, 80));
      expect(resizes, isEmpty);
    });
  });
}
