import 'dart:convert';
import 'dart:ui';

import 'package:bike_control/gen/l10n.dart';
import 'package:bike_control/utils/core.dart';
import 'package:bike_control/utils/settings/ble_device_id_migration.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Settings.init must migrate stored device ids BEFORE anything reads them:
/// the keymap it loads during init already has to match the live device.
Future<void> main() async {
  await AppLocalizations.load(const Locale('en'));

  test('Settings.init migrates upper-case BLE ids before loading the keymap', () async {
    final keyPair = {
      'actions': [
        {'name': 'shiftUp', 'deviceId': 'AA:BB:CC:DD:EE:0F'},
      ],
      'inGameAction': 'shiftUp',
    };
    SharedPreferences.setMockInitialValues({
      'app': 'Mine',
      'customapp_Mine': <String>[jsonEncode(keyPair)],
      'ltwoo_pin_AA:BB:CC:DD:EE:0F': '123',
    });
    FlutterSecureStorage.setMockInitialValues({});

    await core.settings.init();

    expect(core.settings.prefs.getInt(bleDeviceIdMigrationVersionKey), bleDeviceIdMigrationVersion);
    expect(core.settings.getLtwooPin('aa:bb:cc:dd:ee:0f'), '123');
    final buttons = core.actionHandler.supportedApp!.keymap.keyPairs.expand((k) => k.buttons);
    expect(buttons.map((b) => b.sourceDeviceId), contains('aa:bb:cc:dd:ee:0f'));
  });
}
