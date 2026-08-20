import 'dart:async';

import 'package:buzz/features/channels/channel.dart';
import 'package:buzz/features/channels/channel_management_provider.dart';
import 'package:buzz/features/channels/send_message_provider.dart';
import 'package:buzz/shared/contextual_agent/persistent_agent_audience.dart';
import 'package:buzz/shared/contextual_agent/contextual_agent_conversation_policy.dart';
import 'package:buzz/shared/mentions/agent_identity_provider.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:buzz/features/profile/user_profile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:nostr/nostr.dart' as nostr;


const _channelId = '11111111-1111-4111-8111-111111111111';
const _threadRootId =
    'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';
const _self =
    '0000000000000000000000000000000000000000000000000000000000000000';
const _agentA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _agentB =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
void main() {
  setUp(() {
    capturedPromotions.clear();
  });

  test(
    'thread-rooted persistent audience contributes to message tags when enabled',
    () async {
      final session = _PendingPublishRelaySession();
      final localMessages = <NostrEvent>[];
      final removedIds = <String>[];
      final completedIds = <String>[];
      final keys = nostr.Keys.generate();

      final send = SendMessage(
        signedEventRelay: SignedEventRelay(session: session, nsec: keys.nsec),
        fetchMembers: (_) async => [
          ChannelMember(
            pubkey: keys.public,
            role: 'owner',
            joinedAt: DateTime.now().toUtc(),
          ),
          ChannelMember(pubkey: _agentA, role: 'bot', joinedAt: DateTime(2020)),
          ChannelMember(pubkey: _agentB, role: 'bot', joinedAt: DateTime(2020)),
        ],
        readUserCache: () => {
          _agentA: const UserProfile(pubkey: _agentA, displayName: 'agent-a'),
        },
        addLocalMessage: (_, event) => localMessages.add(event),
        completeLocalMessage: (_, eventId) => completedIds.add(eventId),
        removeLocalMessage: (_, eventId) => removedIds.add(eventId),
        readUnaddressedMode: () => UnaddressedChannelAgentMode.mentionsOnly,
        fetchAgentDirectory: () async => const [
          AgentDirectoryEntry(
            pubkey: _agentA,
            respondTo: null,
            respondToAllowlist: [],
            channelIds: [],
          ),
        ],
        readChannel: (_) => Channel(
          id: _channelId,
          name: 'channel',
          channelType: 'stream',
          visibility: 'private',
          description: '',
          createdBy: _self,
          createdAt: DateTime(2020),
          memberCount: 2,
          isMember: true,
        ),
        readKeepAddressedAgentsActive: () => true,
        readPersistentAudienceGeneration: () => 5,
        readPersistentAudienceRevision: (scope) =>
            scope ==
                getPersistentAgentAudienceScope(
                  ownerPubkey: keys.public,
                  channelId: _channelId,
                  threadRootId: _threadRootId,
                )
            ? 3
            : 0,
        resolveAudienceScope: getPersistentAgentAudienceScope,
        readPersistentAudience: (scope) =>
            scope ==
                getPersistentAgentAudienceScope(
                  ownerPubkey: keys.public,
                  channelId: _channelId,
                  threadRootId: _threadRootId,
                )
            ? [_agentB]
            : const [],
        promotePersistentAudience:
            ({
              required int expectedGeneration,
              required int? expectedRevision,
              required List<String> explicitAgentPubkeys,
              required String? scope,
            }) {
              capturedPromotions.add(
                _PromotionCapture(
                  expectedGeneration: expectedGeneration,
                  expectedRevision: expectedRevision,
                  explicitAgentPubkeys: explicitAgentPubkeys,
                  scope: scope,
                ),
              );
            },
      );

      final result = send(
        channelId: _channelId,
        content: 'threaded',
        rootEventId: _threadRootId,
      );
      await session.published;

      session.accept();
      await result;

      expect(localMessages.single.channelId, _channelId);
      expect(localMessages.single.tags, [
        ['h', _channelId],
        ['p', _agentB],
      ]);
      expect(completedIds, [localMessages.single.id]);
      expect(removedIds, isEmpty);
      expect(capturedPromotions, hasLength(1));
      expect(capturedPromotions.single.scope, isNotNull);
      expect(capturedPromotions.single.explicitAgentPubkeys, isEmpty);
    },
  );

  test(
    'explicit mentions are passed to promotion callback and tagged',
    () async {
      final session = _PendingPublishRelaySession();
      final keys = nostr.Keys.generate();

      final send = SendMessage(
        signedEventRelay: SignedEventRelay(session: session, nsec: keys.nsec),
        fetchMembers: (_) async => [
          ChannelMember(pubkey: _agentA, role: 'bot', joinedAt: DateTime(2020)),
        ],
        readUserCache: () => const {},
        addLocalMessage: (_, event) {},
        completeLocalMessage: (_, eventId) {},
        removeLocalMessage: (_, eventId) {},
        readUnaddressedMode: () => UnaddressedChannelAgentMode.mentionsOnly,
        fetchAgentDirectory: () async => const [
          AgentDirectoryEntry(
            pubkey: _agentA,
            respondTo: null,
            respondToAllowlist: [],
            channelIds: [],
          ),
        ],
        readChannel: (_) => Channel(
          id: _channelId,
          name: 'channel',
          channelType: 'stream',
          visibility: 'private',
          description: '',
          createdBy: _self,
          createdAt: DateTime(2020),
          memberCount: 1,
          isMember: true,
        ),
        readKeepAddressedAgentsActive: () => false,
        readPersistentAudienceGeneration: () => 0,
        readPersistentAudienceRevision: (_) => 0,
        resolveAudienceScope: getPersistentAgentAudienceScope,
        readPersistentAudience: (_) => const [_agentB],
        promotePersistentAudience:
            ({
              required int expectedGeneration,
              required int? expectedRevision,
              required List<String> explicitAgentPubkeys,
              required String? scope,
            }) {
              capturedPromotions.add(
                _PromotionCapture(
                  expectedGeneration: expectedGeneration,
                  expectedRevision: expectedRevision,
                  explicitAgentPubkeys: explicitAgentPubkeys,
                  scope: scope,
                ),
              );
            },
      );

      final result = send(
        channelId: _channelId,
        content: 'explicit mention',
        mentionPubkeys: [_agentA],
        rootEventId: _threadRootId,
      );
      await session.published;
      session.accept();
      await result;

      expect(capturedPromotions.single.explicitAgentPubkeys, [_agentA]);
      expect(
        session.event.tags.any(
          (tag) => tag.length >= 2 && tag[0] == 'p' && tag[1] == _agentA,
        ),
        isTrue,
      );
    },
  );

  test('top-level messages ignore scoped persistent audience', () async {
    final session = _PendingPublishRelaySession();
    final localMessages = <NostrEvent>[];
    final keys = nostr.Keys.generate();

    final readScopeErrors = <String>[];
    final send = SendMessage(
      signedEventRelay: SignedEventRelay(session: session, nsec: keys.nsec),
      fetchMembers: (_) async => [
        ChannelMember(pubkey: 'member', role: 'bot', joinedAt: DateTime(2020)),
      ],
      readUserCache: () => const {},
      addLocalMessage: (_, event) => localMessages.add(event),
      completeLocalMessage: (_, eventId) {},
      removeLocalMessage: (_, eventId) {},
      readUnaddressedMode: () => UnaddressedChannelAgentMode.mentionsOnly,
      fetchAgentDirectory: () async => const [],
      readChannel: (_) => Channel(
        id: _channelId,
        name: 'channel',
        channelType: 'stream',
        visibility: 'private',
        description: '',
        createdBy: _self,
        createdAt: DateTime(2020),
        memberCount: 1,
        isMember: true,
      ),
      readKeepAddressedAgentsActive: () => true,
      readPersistentAudienceGeneration: () => 0,
      readPersistentAudienceRevision: (scope) {
        readScopeErrors.add(scope);
        return 1;
      },
      resolveAudienceScope: getPersistentAgentAudienceScope,
      readPersistentAudience: (scope) {
        readScopeErrors.add(scope);
        return [_agentA];
      },
      promotePersistentAudience:
          ({
            required int expectedGeneration,
            required int? expectedRevision,
            required List<String> explicitAgentPubkeys,
            required String? scope,
          }) {},
    );

    final result = send(channelId: _channelId, content: 'top-level');
    await session.published;
    session.accept();
    await result;

    expect(localMessages.single.tags, [
      ['h', _channelId],
    ]);
    expect(readScopeErrors, isEmpty);
  });

  test('failed send does not promote persistent audience', () async {
    final session = _PendingPublishRelaySession();
    final keys = nostr.Keys.generate();
    var promoteCalls = 0;

    final send = SendMessage(
      signedEventRelay: SignedEventRelay(session: session, nsec: keys.nsec),
      fetchMembers: (_) async => [
        ChannelMember(
          pubkey: keys.public,
          role: 'bot',
          joinedAt: DateTime(2020),
        ),
      ],
      readUserCache: () => const {},
      addLocalMessage: (_, event) {},
      completeLocalMessage: (_, eventId) {},
      removeLocalMessage: (_, eventId) {},
      readUnaddressedMode: () => UnaddressedChannelAgentMode.mentionsOnly,
      fetchAgentDirectory: () async => const [
        AgentDirectoryEntry(
          pubkey: _agentA,
          respondTo: null,
          respondToAllowlist: [],
          channelIds: [],
        ),
      ],
      readChannel: (_) => Channel(
        id: _channelId,
        name: 'channel',
        channelType: 'stream',
        visibility: 'private',
        description: '',
        createdBy: _self,
        createdAt: DateTime(2020),
        memberCount: 1,
        isMember: true,
      ),
      readKeepAddressedAgentsActive: () => true,
      readPersistentAudienceGeneration: () => 0,
      readPersistentAudienceRevision: (_) => 0,
      resolveAudienceScope: getPersistentAgentAudienceScope,
      readPersistentAudience: (_) => const [_agentA],
      promotePersistentAudience:
          ({
            required int expectedGeneration,
            required int? expectedRevision,
            required List<String> explicitAgentPubkeys,
            required String? scope,
          }) {
            promoteCalls += 1;
          },
    );

    final result = send(
      channelId: _channelId,
      content: 'failing',
      mentionPubkeys: [_agentA],
      rootEventId: _threadRootId,
    );
    await session.published;
    session.reject();

    await expectLater(result, throwsException);
    expect(promoteCalls, 0);
  });

  test('direct-message behavior still resolves current dm recipient', () async {
    final session = _PendingPublishRelaySession();
    final localMessages = <NostrEvent>[];
    final self = nostr.Keys.generate();

    final send = SendMessage(
      signedEventRelay: SignedEventRelay(session: session, nsec: self.nsec),
      fetchMembers: (_) async => [
        ChannelMember(
          pubkey: self.public,
          role: 'member',
          joinedAt: DateTime(2020),
        ),
        ChannelMember(pubkey: _agentA, role: 'bot', joinedAt: DateTime(2020)),
      ],
      readUserCache: () => {_agentA: const UserProfile(pubkey: _agentA)},
      addLocalMessage: (_, event) => localMessages.add(event),
      completeLocalMessage: (_, eventId) {},
      removeLocalMessage: (_, eventId) {},
      readUnaddressedMode: () => UnaddressedChannelAgentMode.allChannelAgents,
      fetchAgentDirectory: () async => const [
        AgentDirectoryEntry(pubkey: _agentA, respondTo: null),
      ],
      readChannel: (_) => Channel(
        id: _channelId,
        name: 'dm',
        channelType: 'dm',
        visibility: 'private',
        description: '',
        createdBy: _self,
        createdAt: DateTime(2020),
        memberCount: 2,
        isMember: true,
      ),
      readKeepAddressedAgentsActive: () => true,
      readPersistentAudienceGeneration: () => 0,
      readPersistentAudienceRevision: (_) => 0,
      resolveAudienceScope: getPersistentAgentAudienceScope,
      readPersistentAudience: (_) => const [],
      promotePersistentAudience:
          ({
            required int expectedGeneration,
            required int? expectedRevision,
            required List<String> explicitAgentPubkeys,
            required String? scope,
          }) {},
    );

    final result = send(channelId: _channelId, content: 'dm hello');
    await session.published;
    session.accept();
    await result;

    expect(localMessages.single.tags, [
      ['h', _channelId],
      ['p', _agentA],
    ]);
  });

  test('member load failure in channel path keeps draft behavior', () async {
    final session = _PendingPublishRelaySession();
    final self = nostr.Keys.generate();
    final send = SendMessage(
      signedEventRelay: SignedEventRelay(session: session, nsec: self.nsec),
      fetchMembers: (_) async => throw Exception('member fetch failed'),
      readUserCache: () => const {},
      addLocalMessage: (_, event) {},
      completeLocalMessage: (_, eventId) {},
      removeLocalMessage: (_, eventId) {},
      readUnaddressedMode: () => UnaddressedChannelAgentMode.mentionsOnly,
      fetchAgentDirectory: () async => const [],
      readChannel: (_) => Channel(
        id: _channelId,
        name: 'channel',
        channelType: 'stream',
        visibility: 'private',
        description: '',
        createdBy: _self,
        createdAt: DateTime(2020),
        memberCount: 1,
        isMember: true,
      ),
      readKeepAddressedAgentsActive: () => true,
      readPersistentAudienceGeneration: () => 0,
      readPersistentAudienceRevision: (_) => 0,
      resolveAudienceScope: getPersistentAgentAudienceScope,
      readPersistentAudience: (_) => const [],
      promotePersistentAudience:
          ({
            required int expectedGeneration,
            required int? expectedRevision,
            required List<String> explicitAgentPubkeys,
            required String? scope,
          }) {},
    );

    await expectLater(
      send(channelId: _channelId, content: 'failing audience'),
      throwsA(isA<StateError>()),
    );
  });

  test('final signed event addresses the current DM agent member', () async {
    final session = _PendingPublishRelaySession();
    final signingKey = nostr.Keys.generate().nsec;
    final sender = nostr.Keys(
      nostr.Nip19.decode(payload: signingKey).data,
    ).public;
    final staleAgent = 'a' * 64;
    final activeAgent = 'c' * 64;
    final human = 'b' * 64;
    final send = SendMessage(
      signedEventRelay: SignedEventRelay(session: session, nsec: signingKey),
      fetchMembers: (_) async => [
        _member(sender),
        _member(activeAgent),
        _member(human),
      ],
      readUserCache: () => const {},
      addLocalMessage: (_, _) {},
      completeLocalMessage: (_, _) {},
      removeLocalMessage: (_, _) {},
    );

    final result = send(
      channelId: _channelId,
      content: 'hello without a visible mention',
      // Metadata still names the replaced agent. Delivery must follow the
      // authoritative current membership snapshot instead.
      channel: _dmChannel([sender, staleAgent, human]),
      mentionPubkeys: const [],
    );
    await session.published;

    expect(session.event.content, 'hello without a visible mention');
    expect(session.event.tags.where((tag) => tag.first == 'p').toList(), [
      ['p', activeAgent],
      ['p', human],
    ]);

    session.accept();
    await result;
  });

  test('final signed event addresses a human DM recipient', () async {
    final session = _PendingPublishRelaySession();
    final signingKey = nostr.Keys.generate().nsec;
    final sender = nostr.Keys(
      nostr.Nip19.decode(payload: signingKey).data,
    ).public;
    final human = 'b' * 64;
    final send = SendMessage(
      signedEventRelay: SignedEventRelay(session: session, nsec: signingKey),
      fetchMembers: (_) async => [_member(sender), _member(human)],
      readUserCache: () => const {},
      addLocalMessage: (_, _) {},
      completeLocalMessage: (_, _) {},
      removeLocalMessage: (_, _) {},
    );

    final result = send(
      channelId: _channelId,
      content: 'hello human',
      channel: _dmChannel([sender, human]),
      mentionPubkeys: const [],
    );
    await session.published;

    expect(session.event.tags.where((tag) => tag.first == 'p').toList(), [
      ['p', human],
    ]);

    session.accept();
    await result;
  });

  test(
    'falls back to metadata DM recipients when membership is empty',
    () async {
      final session = _PendingPublishRelaySession();
      final signingKey = nostr.Keys.generate().nsec;
      final sender = nostr.Keys(
        nostr.Nip19.decode(payload: signingKey).data,
      ).public;
      final recipient = 'b' * 64;
      final send = SendMessage(
        signedEventRelay: SignedEventRelay(session: session, nsec: signingKey),
        fetchMembers: (_) async => const [],
        readUserCache: () => const {},
        addLocalMessage: (_, _) {},
        completeLocalMessage: (_, _) {},
        removeLocalMessage: (_, _) {},
      );

      final result = send(
        channelId: _channelId,
        content: 'hello from an unavailable roster',
        channel: _dmChannel([sender, recipient]),
        mentionPubkeys: const [],
      );
      await session.published;

      expect(session.event.tags.where((tag) => tag.first == 'p').toList(), [
        ['p', recipient],
      ]);

      session.accept();
      await result;
    },
  );

  test('falls back to metadata DM recipients when membership fails', () async {
    final session = _PendingPublishRelaySession();
    final signingKey = nostr.Keys.generate().nsec;
    final sender = nostr.Keys(
      nostr.Nip19.decode(payload: signingKey).data,
    ).public;
    final recipientOne = 'b' * 64;
    final recipientTwo = 'c' * 64;
    final send = SendMessage(
      signedEventRelay: SignedEventRelay(session: session, nsec: signingKey),
      fetchMembers: (_) async => throw StateError('membership unavailable'),
      readUserCache: () => const {},
      addLocalMessage: (_, _) {},
      completeLocalMessage: (_, _) {},
      removeLocalMessage: (_, _) {},
    );

    final result = send(
      channelId: _channelId,
      content: 'hello group',
      channel: _dmChannel([sender, recipientOne, recipientTwo]),
      mentionPubkeys: [recipientOne.toUpperCase()],
    );
    await session.published;

    expect(session.event.tags.where((tag) => tag.first == 'p').toList(), [
      ['p', recipientOne],
      ['p', recipientTwo],
    ]);

    session.accept();
    await result;
  });

  test('cancels delivery after the active community changes', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(relayConfigProvider.notifier)
        .update(baseUrl: 'https://first.example');
    final send = container.read(sendMessageProvider);

    container
        .read(relayConfigProvider.notifier)
        .update(baseUrl: 'https://second.example');

    await expectLater(
      send(channelId: _channelId, content: 'old community draft'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('active community changed'),
        ),
      ),
    );
  });
}

final capturedPromotions = <_PromotionCapture>[];

Channel _dmChannel(List<String> participantPubkeys) => Channel(
  id: _channelId,
  name: 'DM',
  channelType: 'dm',
  visibility: 'private',
  description: '',
  createdBy: participantPubkeys.first,
  createdAt: DateTime(2025),
  memberCount: participantPubkeys.length,
  participantPubkeys: participantPubkeys,
  isMember: true,
);

ChannelMember _member(String pubkey, {String role = 'member'}) =>
    ChannelMember(pubkey: pubkey, role: role, joinedAt: DateTime(2025));

class _PendingPublishRelaySession extends RelaySessionNotifier {
  final Completer<NostrEvent> _result = Completer<NostrEvent>();
  final Completer<void> _published = Completer<void>();
  late NostrEvent event;

  Future<void> get published => _published.future;

  @override
  SessionState build() => const SessionState(status: SessionStatus.connected);

  @override
  Future<NostrEvent> publish(
    NostrEvent event, {
    Duration timeout = const Duration(seconds: 8),
  }) {
    this.event = event;
    _published.complete();
    return _result.future;
  }

  void accept() => _result.complete(event);

  void reject() => _result.completeError(Exception('relay rejected event'));
}

class _PromotionCapture {
  _PromotionCapture({
    required this.expectedGeneration,
    required this.expectedRevision,
    required this.explicitAgentPubkeys,
    required this.scope,
  });

  final int expectedGeneration;
  final int? expectedRevision;
  final List<String> explicitAgentPubkeys;
  final String? scope;
}
