// `--dart-define=BIKECONTROL_LOCAL_PRO=true` makes a local build behave as Pro
// on this device. It must never read as a verified subscription: settings
// sync and the other server-side features key off that and stay closed.
//
// The flag is a compile-time constant, so the suite asserts whichever mode it
// was compiled in; run it once with the flag and once without.
import 'dart:convert';

import 'package:bike_control/utils/iap/iap_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _localPro = bool.fromEnvironment('BIKECONTROL_LOCAL_PRO');

IAPManager get iap => IAPManager.instance;

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://127.0.0.1:9',
      anonKey: 'iap-manager-test-anon-key',
      debug: false,
      authOptions: const FlutterAuthClientOptions(
        localStorage: EmptyLocalStorage(),
        detectSessionInUri: false,
        autoRefreshToken: false,
      ),
    );
    // A real account that holds no subscription.
    await Supabase.instance.client.auth.recoverSession(
      jsonEncode({
        'access_token': 'test-access-token',
        'token_type': 'bearer',
        'expires_in': 3600,
        'refresh_token': 'test-refresh-token',
        'user': {
          'id': 'user-id',
          'aud': 'authenticated',
          'created_at': '2026-08-24T00:00:00Z',
          'app_metadata': <String, dynamic>{},
          'user_metadata': <String, dynamic>{},
          'is_anonymous': false,
          'email': 'rider@example.com',
        },
      }),
    );
  });

  setUp(() => iap.setProForTesting(enabled: false));

  test('a free account is logged in', () {
    expect(iap.isLoggedIn, isTrue);
  });

  test(_localPro ? 'the flag turns the Pro gates on for this device' : 'without the flag a free account is not Pro', () {
    expect(iap.isProEnabled, _localPro);
    expect(iap.hasActiveSubscription, _localPro);
    expect(iap.isProEnabledForCurrentDevice, _localPro);
    expect(iap.isTrialExpired, isFalse);
    expect(iap.canExecuteCommand, isTrue);
  });

  test('the flag is never a verified subscription, so server-side features stay closed', () {
    expect(iap.hasVerifiedSubscription, isFalse);
  });

  test('the flag does not mask a device that could not be registered under test', () {
    iap.setProForTesting(enabled: true, registeredDevice: false);
    expect(iap.isProEnabledForCurrentDevice, isFalse);
  });
}
