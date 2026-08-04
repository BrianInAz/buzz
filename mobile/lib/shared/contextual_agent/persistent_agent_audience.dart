import 'dart:convert';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../theme/theme_provider.dart';

/// Keep-addressed agents setting key.
const keepAddressedAgentsActiveStorageKey = 'buzz:keep-addressed-agents-active';

/// Persistent audience map key.
const persistentAgentAudiencesStorageKey = 'buzz:persistent-agent-audiences:v2';

const String _hexPubkeyPattern = r'^[0-9a-f]{64}$';

/// Validates and canonicalizes pubkeys used in the persistent audience map.
List<String> normalizePersistentAgentAudienceMembers(Iterable<String> raw) {
  final seen = <String>{};
  final normalized = <String>[];
  for (final candidate in raw) {
    final pubkey = candidate.trim().toLowerCase();
    if (!RegExp(_hexPubkeyPattern).hasMatch(pubkey)) continue;
    if (seen.add(pubkey)) normalized.add(pubkey);
  }
  return normalized;
}

/// Builds the persistence scope for a thread audience.
///
/// Scopes include owner pubkey, channel id, and thread root. Without a thread
/// root there is no valid scope and no persistent audience can be applied.
String? getPersistentAgentAudienceScope({
  required String ownerPubkey,
  required String channelId,
  String? threadRootId,
}) {
  final owner = ownerPubkey.trim().toLowerCase();
  if (!RegExp(_hexPubkeyPattern).hasMatch(owner)) return null;
  if (channelId.trim().isEmpty) return null;
  final root = threadRootId?.trim();
  if (root == null || root.isEmpty) return null;
  return '$owner:$channelId:thread:$root';
}

/// Parses a serialized audience map into a scoped audience map.
Map<String, List<String>> parsePersistentAgentAudienceJson(String? raw) {
  if (raw == null || raw.isEmpty) return const {};
  try {
    final parsed = jsonDecode(raw);
    if (parsed is! Map) return const {};

    final result = <String, List<String>>{};
    for (final entry in parsed.entries) {
      final scope = entry.key;
      final value = entry.value;
      if (scope is! String || scope.isEmpty || value is! List) continue;
      final members = normalizePersistentAgentAudienceMembers(
        value.whereType<String>(),
      );
      if (members.isEmpty) continue;
      result[scope] = members;
    }
    return result;
  } catch (_) {
    return const {};
  }
}

/// Serializes scoped persistent audiences for SharedPreferences persistence.
String serializePersistentAgentAudienceJson(
  Map<String, List<String>> audiences,
) {
  return jsonEncode({
    for (final entry in audiences.entries)
      entry.key: normalizePersistentAgentAudienceMembers(entry.value),
  });
}

class PersistentAgentAudienceState {
  const PersistentAgentAudienceState({
    required this.enabled,
    required this.generation,
    required this.audiences,
  });

  final bool enabled;
  final int generation;
  final Map<String, List<String>> audiences;
}

class PersistentAgentAudienceNotifier
    extends Notifier<PersistentAgentAudienceState> {
  int _revisionClock = 0;
  int _defaultRevision = 0;
  int _generation = 0;
  final Map<String, int> _revisions = {};
  final Map<String, List<String>> _audiences = {};

  @override
  PersistentAgentAudienceState build() {
    final prefs = ref.read(savedPrefsProvider);
    final enabled = prefs.getString(keepAddressedAgentsActiveStorageKey) == '1';
    _generation = 0;
    _revisionClock = 0;
    _defaultRevision = 0;
    _revisions.clear();
    _audiences
      ..clear()
      ..addAll(
        parsePersistentAgentAudienceJson(
          prefs.getString(persistentAgentAudiencesStorageKey),
        ),
      );

    if (!enabled) {
      return const PersistentAgentAudienceState(
        enabled: false,
        generation: 0,
        audiences: {},
      );
    }

    return PersistentAgentAudienceState(
      enabled: true,
      generation: _generation,
      audiences: Map.unmodifiable({
        for (final entry in _audiences.entries)
          entry.key: List<String>.unmodifiable(entry.value),
      }),
    );
  }

  bool getEnabled() => state.enabled;

  int getGeneration() => state.generation;

  List<String> getAudienceForScope(String scope) {
    if (!state.enabled) return const [];
    return List.unmodifiable(_audiences[scope] ?? const []);
  }

  int getRevisionForScope(String scope) {
    return _revisions[scope] ?? _defaultRevision;
  }

  void setEnabled(bool nextEnabled) {
    if (state.enabled == nextEnabled) return;

    final prefs = ref.read(savedPrefsProvider);
    if (!nextEnabled) {
      _generation += 1;
      _revisionClock += 1;
      _defaultRevision = _revisionClock;
      _revisions.clear();
      _audiences.clear();
      _emit(enabled: false, audiences: {});
      _persistAudiences();
      prefs.setString(keepAddressedAgentsActiveStorageKey, '0');
      return;
    }

    _emit(
      enabled: true,
      audiences: {
        for (final entry in _audiences.entries) entry.key: entry.value,
      },
    );
    prefs.setString(keepAddressedAgentsActiveStorageKey, '1');
  }

  void initializeAudience(String scope, Iterable<String> pubkeys) {
    if (!state.enabled || scope.isEmpty) return;
    if (_audiences.containsKey(scope)) return;
    _setAudience(scope, pubkeys);
  }

  void promotePersistentAgentAudience({
    required int expectedGeneration,
    required int? expectedRevision,
    required List<String> explicitAgentPubkeys,
    required String? scope,
  }) {
    if (!state.enabled || scope == null || scope.isEmpty) return;
    if (expectedGeneration != state.generation) return;
    if (expectedRevision != null &&
        getRevisionForScope(scope) != expectedRevision) {
      return;
    }

    final explicit = normalizePersistentAgentAudienceMembers(
      explicitAgentPubkeys,
    );
    if (explicit.isEmpty) return;

    final prior = _audiences[scope] ?? const [];
    final merged = <String>[
      ...explicit,
      for (final agent in prior)
        if (!explicit.contains(agent)) agent,
    ];

    _setAudience(scope, merged);
  }

  void removePersistentAgentAudienceMember(String scope, String pubkey) {
    if (!state.enabled || scope.isEmpty) return;
    final normalized = pubkey.trim().toLowerCase();
    final prior = _audiences[scope] ?? const [];
    _setAudience(scope, prior.where((candidate) => candidate != normalized));
  }

  void _setAudience(String scope, Iterable<String> pubkeys) {
    if (!state.enabled || scope.isEmpty) return;
    final normalized = normalizePersistentAgentAudienceMembers(pubkeys);
    final current = _audiences[scope] ?? const [];

    if (_audiences.containsKey(scope) &&
        current.length == normalized.length &&
        _listEquals(current, normalized)) {
      return;
    }

    _audiences[scope] = normalized;
    _revisionClock += 1;
    _revisions[scope] = _revisionClock;
    _emit(
      enabled: true,
      audiences: {
        for (final entry in _audiences.entries) entry.key: entry.value,
      },
    );
    _persistAudiences();
  }

  void _emit({
    required bool enabled,
    required Map<String, List<String>> audiences,
  }) {
    state = PersistentAgentAudienceState(
      enabled: enabled,
      generation: _generation,
      audiences: Map.unmodifiable({
        for (final entry in audiences.entries)
          entry.key: List<String>.unmodifiable(entry.value),
      }),
    );
  }

  void _persistAudiences() {
    final prefs = ref.read(savedPrefsProvider);
    try {
      prefs.setString(
        persistentAgentAudiencesStorageKey,
        serializePersistentAgentAudienceJson(_audiences),
      );
    } catch (_) {
      // SharedPreferences persistence is best effort.
    }
  }

  static bool _listEquals(List<String> left, List<String> right) {
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) return false;
    }
    return true;
  }
}

final persistentAgentAudienceProvider =
    NotifierProvider<
      PersistentAgentAudienceNotifier,
      PersistentAgentAudienceState
    >(PersistentAgentAudienceNotifier.new);
