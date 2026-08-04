import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:buzz/features/settings/settings_page.dart';
import 'package:buzz/shared/contextual_agent/persistent_agent_audience.dart';
import 'package:buzz/shared/theme/theme_provider.dart';

import '../../helpers/widget_helpers.dart';

const _packageInfoChannel = MethodChannel(
  'dev.fluttercommunity.plus/package_info',
);

Future<SharedPreferences> _container(Map<String, Object> initial) async {
  SharedPreferences.setMockInitialValues(initial);
  return SharedPreferences.getInstance();
}

void _mockPackageInfo() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_packageInfoChannel, (call) async {
        if (call.method == 'getAll') {
          return {
            'appName': 'buzz',
            'packageName': 'buzz',
            'version': '0.0.0',
            'buildNumber': '1',
            'buildSignature': '',
            'installerStore': null,
          };
        }
        return null;
      });
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    _mockPackageInfo();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_packageInfoChannel, null);
  });

  testWidgets(
    'settings row shows keep addressed agents toggle state and persists changes',
    (tester) async {
      final prefs = await _container({
        keepAddressedAgentsActiveStorageKey: '1',
        persistentAgentAudiencesStorageKey: '{}',
      });

      await tester.pumpWidget(
        WidgetHelpers.testable(
          child: const SettingsPage(profileHeader: SizedBox.shrink()),
          overrides: [savedPrefsProvider.overrideWithValue(prefs)],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Keep addressed agents active'), findsOneWidget);
      expect(find.text('On'), findsOneWidget);
      final switchFinder = find.byType(Switch);
      expect(switchFinder, findsOneWidget);
      expect(tester.widget<Switch>(switchFinder).value, isTrue);
      expect(prefs.getString(keepAddressedAgentsActiveStorageKey), '1');

      await tester.tap(switchFinder);
      await tester.pumpAndSettle();

      expect(find.text('Off'), findsOneWidget);
      expect(tester.widget<Switch>(switchFinder).value, isFalse);
      expect(prefs.getString(keepAddressedAgentsActiveStorageKey), '0');
    },
  );
}
