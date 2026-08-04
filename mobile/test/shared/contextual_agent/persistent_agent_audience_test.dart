import 'package:buzz/shared/contextual_agent/persistent_agent_audience.dart';
import 'package:buzz/shared/theme/theme_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _ownerA =
    '1111111111111111111111111111111111111111111111111111111111111111';
const _ownerB =
    '2222222222222222222222222222222222222222222222222222222222222222';
const _agentA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _agentB =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

Future<ProviderContainer> _container([
  Map<String, Object> initial = const {},
]) async {
  SharedPreferences.setMockInitialValues(initial);
  return ProviderContainer(
    overrides: [
      savedPrefsProvider.overrideWithValue(
        await SharedPreferences.getInstance(),
      ),
    ],
  );
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  test('scopes include owner, channel, and thread root', () {
    final scope = getPersistentAgentAudienceScope(
      ownerPubkey: _ownerA,
      channelId: 'channel-a',
      threadRootId: 'thread-1',
    );
    expect(scope, '$_ownerA:channel-a:thread:thread-1');

    final badOwnerScope = getPersistentAgentAudienceScope(
      ownerPubkey: 'bad',
      channelId: 'channel-a',
      threadRootId: 'thread-1',
    );
    expect(badOwnerScope, isNull);

    expect(
      getPersistentAgentAudienceScope(
        ownerPubkey: _ownerA,
        channelId: 'channel-a',
        threadRootId: null,
      ),
      isNull,
    );
  });

  test('normalize and validate audience members', () {
    final members = normalizePersistentAgentAudienceMembers([
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      'bad',
      '${_agentA}zz',
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      'A' * 64,
      _agentB,
    ]);

    expect(members, [_agentA, _agentB]);
  });

  test('parse and serialize survive malformed state', () {
    expect(parsePersistentAgentAudienceJson('not json'), const {});
    expect(parsePersistentAgentAudienceJson('{"scope":["bad"]}'), const {});
    expect(
      parsePersistentAgentAudienceJson('{"scope":{"scope":true}}'),
      const {},
    );

    expect(
      serializePersistentAgentAudienceJson({
        'scope': ['A' * 64, 'bad', _agentA],
      }),
      '{"scope":["$_agentA"]}',
    );
  });

  test('audiences default to disabled and empty', () async {
    final container = await _container();
    final state = container.read(persistentAgentAudienceProvider);

    expect(state.enabled, isFalse);
    expect(state.generation, 0);
    expect(state.audiences, isEmpty);

    final saved = SharedPreferences.getInstance();
    expect(
      (await saved).getString(keepAddressedAgentsActiveStorageKey),
      isNull,
    );
  });

  test('disabling clears persisted audiences and bumps generation', () async {
    final scopeA = getPersistentAgentAudienceScope(
      ownerPubkey: _ownerA,
      channelId: 'channel-a',
      threadRootId: 'thread-1',
    );
    final scopeB = getPersistentAgentAudienceScope(
      ownerPubkey: _ownerA,
      channelId: 'channel-b',
      threadRootId: 'thread-2',
    );
    final container = await _container({
      keepAddressedAgentsActiveStorageKey: '1',
      persistentAgentAudiencesStorageKey:
          '{"$scopeA":["$_agentA"],"$scopeB":["$_agentB"]}',
    });

    final notifier = container.read(persistentAgentAudienceProvider.notifier);
    expect(notifier.getAudienceForScope(scopeA!), [_agentA]);
    expect(notifier.getAudienceForScope(scopeB!), [_agentB]);

    final generationBefore = notifier.getGeneration();
    notifier.setEnabled(false);

    final prefs = await SharedPreferences.getInstance();
    final state = container.read(persistentAgentAudienceProvider);
    expect(state.enabled, isFalse);
    expect(state.generation, generationBefore + 1);
    expect(state.audiences, isEmpty);
    expect(notifier.getAudienceForScope(scopeA), isEmpty);
    expect(notifier.getAudienceForScope(scopeB), isEmpty);
    expect(prefs.getString(persistentAgentAudiencesStorageKey), '{}');
    expect(prefs.getString(keepAddressedAgentsActiveStorageKey), '0');
  });

  test('thread + identity scoping isolates persisted audiences', () async {
    final container = await _container({
      keepAddressedAgentsActiveStorageKey: '1',
    });
    final notifier = container.read(persistentAgentAudienceProvider.notifier);

    final scopeA = getPersistentAgentAudienceScope(
      ownerPubkey: _ownerA,
      channelId: 'channel-a',
      threadRootId: 'thread-1',
    )!;
    final scopeB = getPersistentAgentAudienceScope(
      ownerPubkey: _ownerA,
      channelId: 'channel-a',
      threadRootId: 'thread-2',
    )!;
    final scopeC = getPersistentAgentAudienceScope(
      ownerPubkey: _ownerB,
      channelId: 'channel-a',
      threadRootId: 'thread-1',
    )!;

    notifier.initializeAudience(scopeA, [_agentA]);
    notifier.initializeAudience(scopeB, [_agentB]);
    notifier.initializeAudience(scopeC, [_agentB]);

    expect(notifier.getAudienceForScope(scopeA), [_agentA]);
    expect(notifier.getAudienceForScope(scopeB), [_agentB]);
    expect(notifier.getAudienceForScope(scopeC), [_agentB]);
    expect(notifier.getAudienceForScope('$scopeC:thread:other'), isEmpty);
  });

  test('generation and revision stale guards prevent re-promotion', () async {
    final container = await _container({
      keepAddressedAgentsActiveStorageKey: '1',
    });
    final notifier = container.read(persistentAgentAudienceProvider.notifier);

    final scope = getPersistentAgentAudienceScope(
      ownerPubkey: _ownerA,
      channelId: 'channel-a',
      threadRootId: 'thread-1',
    )!;
    notifier.initializeAudience(scope, [_agentA]);
    final generation = notifier.getGeneration();
    final staleRevision = notifier.getRevisionForScope(scope);

    notifier.promotePersistentAgentAudience(
      expectedGeneration: generation,
      expectedRevision: staleRevision,
      explicitAgentPubkeys: [_agentB],
      scope: scope,
    );
    expect(notifier.getAudienceForScope(scope), [_agentB, _agentA]);

    final currentRevision = notifier.getRevisionForScope(scope);
    notifier.promotePersistentAgentAudience(
      expectedGeneration: generation,
      expectedRevision: staleRevision,
      explicitAgentPubkeys: [_agentA],
      scope: scope,
    );
    expect(notifier.getAudienceForScope(scope), [_agentB, _agentA]);
    expect(notifier.getRevisionForScope(scope), currentRevision);

    notifier.promotePersistentAgentAudience(
      expectedGeneration: generation + 1,
      expectedRevision: currentRevision,
      explicitAgentPubkeys: [_agentA],
      scope: scope,
    );
    expect(notifier.getAudienceForScope(scope), [_agentB, _agentA]);
  });

  test(
    'settings toggle persists keep-addressed state in preferences',
    () async {
      SharedPreferences.setMockInitialValues(const {});
      final container = await _container();
      final notifier = container.read(persistentAgentAudienceProvider.notifier);
      final prefs = await SharedPreferences.getInstance();

      expect(container.read(persistentAgentAudienceProvider).enabled, isFalse);
      notifier.setEnabled(true);
      expect(prefs.getString(keepAddressedAgentsActiveStorageKey), '1');
      expect(container.read(persistentAgentAudienceProvider).enabled, isTrue);

      notifier.setEnabled(false);
      expect(prefs.getString(keepAddressedAgentsActiveStorageKey), '0');
      expect(container.read(persistentAgentAudienceProvider).enabled, isFalse);
    },
  );
}
