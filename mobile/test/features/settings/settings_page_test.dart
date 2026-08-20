import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:buzz/features/settings/settings_page.dart';
import 'package:buzz/shared/community/community_membership_provider.dart';
import 'package:buzz/shared/contextual_agent/persistent_agent_audience.dart';
import 'package:buzz/shared/theme/theme.dart';

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
          child: const SettingsPage(
            profileHeader: SizedBox.shrink(),
            invitePageBuilder: _emptyPage,
            identityRecoveryPageBuilder: _emptyPage,
          ),
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

  testWidgets('shows community invite navigation to owners and admins', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          savedPrefsProvider.overrideWithValue(prefs),
          currentCommunityRoleProvider.overrideWithValue(
            const AsyncData<CommunityMemberRole?>(CommunityMemberRole.admin),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: SettingsPage(
            profileHeader: const SizedBox.shrink(),
            invitePageBuilder: (_) => const Text('Invite destination'),
            identityRecoveryPageBuilder: (_) => const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Invite to community'), findsOneWidget);
    expect(
      find.text('Add people directly or share an invite link'),
      findsNothing,
    );
    await tester.tap(find.text('Invite to community'));
    await tester.pumpAndSettle();
    expect(find.text('Invite destination'), findsOneWidget);
  });

  testWidgets('keeps invite navigation available when role lookup fails', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          savedPrefsProvider.overrideWithValue(prefs),
          currentCommunityRoleProvider.overrideWithValue(
            AsyncError<CommunityMemberRole?>(
              Exception('membership query failed'),
              StackTrace.empty,
            ),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: SettingsPage(
            profileHeader: const SizedBox.shrink(),
            invitePageBuilder: (_) => const Text('Invite destination'),
            identityRecoveryPageBuilder: (_) => const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Invite to community'), findsOneWidget);
    await tester.tap(find.text('Invite to community'));
    await tester.pumpAndSettle();
    expect(find.text('Invite destination'), findsOneWidget);
  });

  testWidgets('hides community invite navigation from plain members', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          savedPrefsProvider.overrideWithValue(prefs),
          currentCommunityRoleProvider.overrideWithValue(
            const AsyncData<CommunityMemberRole?>(CommunityMemberRole.member),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: SettingsPage(
            profileHeader: const SizedBox.shrink(),
            invitePageBuilder: (_) => const Text('Invite destination'),
            identityRecoveryPageBuilder: (_) => const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Invite to community'), findsNothing);
  });
}

Widget _emptyPage(BuildContext _) => const SizedBox.shrink();
