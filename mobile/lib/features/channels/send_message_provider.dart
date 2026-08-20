import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/contextual_agent/composer_send_audience.dart';
import '../../shared/contextual_agent/contextual_agent_conversation_policy.dart';
import '../../shared/contextual_agent/persistent_agent_audience.dart';
import '../../shared/contextual_agent/unaddressed_channel_agent_mode.dart';
import '../../shared/mentions/agent_identity_provider.dart';
import '../../shared/relay/relay.dart';
import '../channels/channel_management_provider.dart';
import '../profile/user_cache_provider.dart';
import '../profile/user_profile.dart';
import 'channel.dart';
import 'channel_messages_provider.dart';
import 'channels_provider.dart';
import 'message_mention_pubkeys.dart';

/// Sends messages by signing an event with the user's nsec and publishing it
/// over the relay's NIP-42-authenticated WebSocket session.
class SendMessage {
  final SignedEventRelay _signedEventRelay;
  final Future<List<ChannelMember>> Function(String channelId) _fetchMembers;
  final Map<String, UserProfile> Function() _readUserCache;
  final void Function(String channelId, NostrEvent event) _addLocalMessage;
  final void Function(String channelId, String eventId) _completeLocalMessage;
  final void Function(String channelId, String eventId) _removeLocalMessage;
  final UnaddressedChannelAgentMode Function() _readUnaddressedMode;
  final Future<List<AgentDirectoryEntry>> Function() _fetchAgentDirectory;
  final Channel? Function(String channelId) _readChannel;
  final bool Function() _readKeepAddressedAgentsActive;
  final int Function() _readPersistentAudienceGeneration;
  final int Function(String scope) _readPersistentAudienceRevision;
  final String? Function({
    required String ownerPubkey,
    required String channelId,
    String? threadRootId,
  })
  _resolveAudienceScope;
  final List<String> Function(String scope) _readPersistentAudience;
  final void Function({
    required int expectedGeneration,
    required int? expectedRevision,
    required List<String> explicitAgentPubkeys,
    required String? scope,
  })
  _promotePersistentAudience;
  final bool Function()? _isDeliveryValid;

  SendMessage({
    required SignedEventRelay signedEventRelay,
    required Future<List<ChannelMember>> Function(String channelId)
    fetchMembers,
    required Map<String, UserProfile> Function() readUserCache,
    required void Function(String channelId, NostrEvent event) addLocalMessage,
    required void Function(String channelId, String eventId)
    completeLocalMessage,
    required void Function(String channelId, String eventId) removeLocalMessage,
    required UnaddressedChannelAgentMode Function() readUnaddressedMode,
    required Future<List<AgentDirectoryEntry>> Function() fetchAgentDirectory,
    required Channel? Function(String channelId) readChannel,
    required bool Function() readKeepAddressedAgentsActive,
    required int Function() readPersistentAudienceGeneration,
    required int Function(String scope) readPersistentAudienceRevision,
    required String? Function({
      required String ownerPubkey,
      required String channelId,
      String? threadRootId,
    })
    resolveAudienceScope,
    required List<String> Function(String scope) readPersistentAudience,
    required void Function({
      required int expectedGeneration,
      required int? expectedRevision,
      required List<String> explicitAgentPubkeys,
      required String? scope,
    })
    promotePersistentAudience,
    bool Function()? isDeliveryValid,
  }) : _signedEventRelay = signedEventRelay,
       _fetchMembers = fetchMembers,
       _readUserCache = readUserCache,
       _addLocalMessage = addLocalMessage,
       _completeLocalMessage = completeLocalMessage,
       _removeLocalMessage = removeLocalMessage,
       _readUnaddressedMode = readUnaddressedMode,
       _fetchAgentDirectory = fetchAgentDirectory,
       _readChannel = readChannel,
       _readKeepAddressedAgentsActive = readKeepAddressedAgentsActive,
       _readPersistentAudienceGeneration = readPersistentAudienceGeneration,
       _readPersistentAudienceRevision = readPersistentAudienceRevision,
       _resolveAudienceScope = resolveAudienceScope,
       _readPersistentAudience = readPersistentAudience,
       _promotePersistentAudience = promotePersistentAudience,
       _isDeliveryValid = isDeliveryValid;

  String? _buildAudienceScope({
    required String channelId,
    String? threadRootId,
  }) {
    final owner = _signedEventRelay.pubkey;
    if (owner == null || owner.isEmpty) return null;

    return _resolveAudienceScope(
      ownerPubkey: owner,
      channelId: channelId,
      threadRootId: threadRootId,
    );
  }

  /// Send a text message to a channel.
  ///
  /// For thread replies, pass [parentEventId] and optionally [rootEventId].
  /// If [rootEventId] is null it defaults to [parentEventId] (direct reply to
  /// thread head). Tags are built to match the desktop's `buildReplyTags`
  /// convention with `root` / `reply` markers. Pass [mediaTags] to append
  /// relay-validated `imeta` tags and NIP-30 `emoji` tags.
  Future<void> call({
    required String channelId,
    required String content,
    String? parentEventId,
    String? rootEventId,
    List<String>? mentionPubkeys,
    Channel? channel,
    List<List<String>> mediaTags = const [],
  }) async {
    _ensureDeliveryValid();
    // Use explicitly passed pubkeys, or resolve @mentions against
    // channel members to avoid matching the wrong user.
    final explicitMentions =
        mentionPubkeys ?? await _resolveMentions(content, channelId);
    final authorPubkey = _signedEventRelay.pubkey;
    final dmRecipientPubkeys = channel?.isDm == true
        ? await _fetchDmRecipientPubkeys(channelId, channel!, authorPubkey)
        : null;
    final resolvedMentions = dmRecipientPubkeys != null
        ? messageMentionPubkeys(
            channel: channel!,
            senderPubkey: authorPubkey,
            explicitMentions: explicitMentions,
            dmRecipientPubkeys: dmRecipientPubkeys,
          )
        : explicitMentions;

    // Normalize mentions: lowercase, deduplicate, exclude self (matching
    // the desktop's normalizeMentionPubkeys).
    final selfLower = authorPubkey?.toLowerCase();
    final seenMentions = <String>{?selfLower};
    final explicitMentions = <String>[
      for (final pk in resolvedMentions)
        if (seenMentions.add(pk.toLowerCase())) pk.toLowerCase(),
    ];

    final threadAudienceScope = _buildAudienceScope(
      channelId: channelId,
      threadRootId: rootEventId ?? parentEventId,
    );
    final keepAddressedAgentsActive =
        _readKeepAddressedAgentsActive() && threadAudienceScope != null;
    final audienceGeneration = _readPersistentAudienceGeneration();
    final audienceRevision = threadAudienceScope == null
        ? null
        : _readPersistentAudienceRevision(threadAudienceScope);
    final persistentAudience = threadAudienceScope == null
        ? const <String>[]
        : _readPersistentAudience(threadAudienceScope);

    final resolution = await _mergeContextualAudience(
      channelId: channelId,
      explicitMentions: explicitMentions,
      parentEventId: parentEventId,
      rootEventId: rootEventId,
      keepAddressedAgentsActive: keepAddressedAgentsActive,
      persistentThreadAudience: persistentAudience,
    );

    final tags = <List<String>>[
      ['h', channelId],
      if (parentEventId != null) ..._buildReplyTags(parentEventId, rootEventId),
      for (final pk in resolution.mentionPubkeys) ['p', pk],
      ...mediaTags,
    ];

    _ensureDeliveryValid();
    NostrEvent? localMessage;
    try {
      await _signedEventRelay.submit(
        kind: EventKind.streamMessage,
        content: content,
        tags: tags,
        onSigned: (event) {
          localMessage = event;
          _addLocalMessage(channelId, event);
        },
      );
      final event = localMessage;
      if (event != null) _completeLocalMessage(channelId, event.id);

      _promotePersistentAudience(
        expectedGeneration: audienceGeneration,
        expectedRevision: audienceRevision,
        explicitAgentPubkeys: resolution.explicitAgentPubkeys,
        scope: threadAudienceScope,
      );
    } catch (_) {
      final event = localMessage;
      if (event != null) _removeLocalMessage(channelId, event.id);
      rethrow;
    }
  }

  /// Resolve every identity that is actually a current member of this DM.
  ///
  /// Membership is authoritative for delivery. The channel metadata's `p`
  /// tags can lag membership changes, so they are only used when the membership
  /// snapshot is unavailable.
  Future<Set<String>> _fetchDmRecipientPubkeys(
    String channelId,
    Channel channel,
    String? authorPubkey,
  ) async {
    List<ChannelMember>? members;
    try {
      members = await _fetchMembers(channelId);
    } catch (_) {
      // Fall back to metadata below so an unavailable membership query does
      // not block ordinary DM sends.
    }

    final author = authorPubkey?.toLowerCase();
    final participants = members != null && members.isNotEmpty
        ? members.map((member) => member.pubkey)
        : channel.participantPubkeys;
    return {
      for (final participant in participants)
        if (participant.trim().isNotEmpty &&
            participant.toLowerCase() != author)
          participant.toLowerCase(),
    };
  }

  void _ensureDeliveryValid() {
    if (_isDeliveryValid?.call() == false) {
      throw StateError(
        'Message delivery cancelled because the active community changed',
      );
    }
  }

  /// Resolve @mentions to pubkeys, scoped to channel members.
  ///
  /// Fetches channel members from the relay and matches @names only
  /// against members of that channel. Falls back to the full user cache
  /// if the member fetch fails.
  Future<List<String>> _resolveMentions(
    String content,
    String channelId,
  ) async {
    final mentionPattern = RegExp(r'@(\w+)');
    final matches = mentionPattern.allMatches(content);
    if (matches.isEmpty) return const [];

    // Try to get channel member pubkeys for scoped resolution.
    Set<String>? memberPubkeys;
    try {
      final members = await _fetchMembers(channelId);
      memberPubkeys = {for (final m in members) m.pubkey.toLowerCase()};
    } catch (_) {
      // Non-fatal — fall through to unscoped cache lookup.
    }

    final cache = _readUserCache();
    final pubkeys = <String>{};

    for (final match in matches) {
      final name = match.group(1)?.toLowerCase();
      if (name == null || name.isEmpty) continue;

      for (final profile in cache.values) {
        final displayName = profile.displayName?.toLowerCase();
        if (displayName == null) continue;

        // Match against full display name or first word.
        final firstName = displayName.split(RegExp(r'\s+')).first;
        if (displayName != name && firstName != name) continue;

        // If we have channel members, only match members of this channel.
        if (memberPubkeys != null &&
            !memberPubkeys.contains(profile.pubkey.toLowerCase())) {
          continue;
        }

        pubkeys.add(profile.pubkey);
        break;
      }
    }

    return pubkeys.toList();
  }

  /// Merge explicit mentions with the unaddressed-channel agent policy.
  Future<_AudienceResolution> _mergeContextualAudience({
    required String channelId,
    required List<String> explicitMentions,
    String? parentEventId,
    String? rootEventId,
    required bool keepAddressedAgentsActive,
    required List<String> persistentThreadAudience,
  }) async {
    List<ChannelMember> members;
    var memberLoadError = false;
    try {
      members = await _fetchMembers(channelId);
    } catch (_) {
      memberLoadError = true;
      members = const [];
    }

    final directory = await _fetchAgentDirectory();
    final directoryPubkeys = {
      for (final agent in directory) agent.pubkey.toLowerCase(),
    };
    final memberPubkeys = [for (final m in members) m.pubkey.toLowerCase()];
    final verifiedAgents = [
      for (final m in members)
        if (m.isBot || directoryPubkeys.contains(m.pubkey.toLowerCase()))
          m.pubkey.toLowerCase(),
    ];
    final explicitAgentPubkeys = [
      for (final pk in explicitMentions)
        if (verifiedAgents.contains(pk) || directoryPubkeys.contains(pk)) pk,
    ];

    final channel = _readChannel(channelId);
    final isDm = channel?.isDm == true;
    final conversation = isDm ? 'direct' : 'channel';
    final messagePosition = parentEventId != null ? 'in-thread' : 'top-level';
    String? currentAgent;
    if (isDm) {
      final self = _signedEventRelay.pubkey?.toLowerCase();
      final others = [
        for (final pk in verifiedAgents)
          if (pk != self) pk,
      ];
      currentAgent = others.isEmpty ? null : others.first;
    }

    final result = resolveComposerSendAudience(
      conversation: conversation,
      messagePosition: messagePosition,
      unaddressedMode: _readUnaddressedMode(),
      keepAddressedAgentsActive: keepAddressedAgentsActive,
      explicitMentionPubkeys: explicitMentions,
      explicitAgentPubkeys: explicitAgentPubkeys,
      currentAgentPubkey: currentAgent,
      channelMemberPubkeys: memberPubkeys,
      verifiedChannelAgentPubkeys: verifiedAgents,
      persistentThreadAudience: persistentThreadAudience,
      threadRootEventId: rootEventId ?? parentEventId,
      recipientLoadError: memberLoadError && !isDm,
    );

    if (result.retainDraft) {
      throw StateError(
        'Could not resolve agent audience. Your draft was kept.',
      );
    }

    return _AudienceResolution(
      mentionPubkeys: result.mentionPubkeys,
      explicitAgentPubkeys: explicitAgentPubkeys,
    );
  }

  /// Build `e`-tags for a thread reply, matching the desktop convention:
  /// - Direct reply to thread head: `["e", id, "", "reply"]`
  /// - Nested reply: `["e", rootId, "", "root"]` + `["e", parentId, "", "reply"]`
  static List<List<String>> _buildReplyTags(
    String parentEventId,
    String? rootEventId,
  ) {
    final root = rootEventId ?? parentEventId;
    if (parentEventId == root) {
      return [
        ['e', root, '', 'reply'],
      ];
    }
    return [
      ['e', root, '', 'root'],
      ['e', parentEventId, '', 'reply'],
    ];
  }
}

final sendMessageProvider = Provider<SendMessage>((ref) {
  final config = ref.watch(relayConfigProvider);
  final audience = ref.watch(persistentAgentAudienceProvider.notifier);

  return SendMessage(
    signedEventRelay: SignedEventRelay(
      session: ref.read(relaySessionProvider.notifier),
      nsec: config.nsec,
    ),
    fetchMembers: (channelId) =>
        ref.read(channelMembersProvider(channelId).future),
    readUserCache: () => ref.read(userCacheProvider),
    addLocalMessage: (channelId, event) => ref
        .read(channelMessagesProvider(channelId).notifier)
        .addLocalMessage(event),
    completeLocalMessage: (channelId, eventId) => ref
        .read(channelMessagesProvider(channelId).notifier)
        .completeLocalMessage(eventId),
    removeLocalMessage: (channelId, eventId) => ref
        .read(channelMessagesProvider(channelId).notifier)
        .removeLocalMessage(eventId),
    readUnaddressedMode: () => ref.read(unaddressedChannelAgentModeProvider),
    fetchAgentDirectory: () async {
      try {
        return await ref.read(agentDirectoryProvider.future);
      } catch (_) {
        return const [];
      }
    },
    readChannel: (channelId) {
      final channels = ref.read(channelsProvider).asData?.value;
      if (channels == null) return null;
      for (final c in channels) {
        if (c.id == channelId) return c;
      }
      return null;
    },
    readKeepAddressedAgentsActive: audience.getEnabled,
    readPersistentAudienceGeneration: audience.getGeneration,
    readPersistentAudienceRevision: audience.getRevisionForScope,
    resolveAudienceScope: getPersistentAgentAudienceScope,
    readPersistentAudience: audience.getAudienceForScope,
    promotePersistentAudience: audience.promotePersistentAgentAudience,
    isDeliveryValid: () {
      final currentConfig = ref.read(relayConfigProvider);
      return currentConfig.baseUrl == config.baseUrl &&
          currentConfig.nsec == config.nsec;
    },
  );
});

class _AudienceResolution {
  final List<String> mentionPubkeys;
  final List<String> explicitAgentPubkeys;

  const _AudienceResolution({
    required this.mentionPubkeys,
    required this.explicitAgentPubkeys,
  });
}
