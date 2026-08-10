import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/relay/relay.dart';

/// In-memory cache of other users' presence.
///
/// The authenticated HTTP query hydrates tracked users from the relay's Redis
/// presence snapshot. Live kind:20001 events remain the fast path, while a
/// periodic refresh catches TTL expiry and reconnection gaps.
class PresenceCacheNotifier extends Notifier<Map<String, String>> {
  static const _batchDelay = Duration(milliseconds: 50);
  static const _refreshInterval = Duration(seconds: 60);
  static const _maxAuthorsPerFilter = 100;
  static const _subscriptionRetryDelays = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 16),
    Duration(seconds: 30),
  ];

  final Set<String> _tracked = {};
  final Set<String> _pendingHydration = {};
  final Map<String, int> _revisions = {};

  Map<String, String> _cache = const {};
  void Function()? _presenceUnsub;
  Timer? _batchTimer;
  Timer? _refreshTimer;
  Timer? _subscriptionRetryTimer;
  int _subscriptionVersion = 0;
  bool _connected = false;
  bool _disposed = false;

  @override
  Map<String, String> build() {
    _connected =
        ref.read(relaySessionProvider).status == SessionStatus.connected;
    _cache = const {};
    ref.listen(relaySessionProvider, _handleSessionState);
    ref.onDispose(_dispose);

    if (_connected) {
      Future.microtask(_startConnectedResources);
    }

    return _cache;
  }

  void _handleSessionState(SessionState? previous, SessionState next) {
    final connected = next.status == SessionStatus.connected;
    if (_disposed || _connected == connected) return;

    _connected = connected;
    _stopConnectedResources();
    _cache = const {};
    state = _cache;
    if (_connected) {
      Future.microtask(_startConnectedResources);
    }
  }

  /// Track presence for [pubkeys].
  ///
  /// Newly tracked, unresolved keys are normalized and hydrated in one
  /// debounced relay query. Repeated widget-driven calls do not issue another
  /// query; periodic refresh and reconnection handle later reconciliation.
  void track(List<String> pubkeys) {
    for (final pubkey in pubkeys) {
      final normalized = pubkey.trim().toLowerCase();
      if (normalized.isEmpty || !_tracked.add(normalized)) continue;
      _pendingHydration.add(normalized);
    }

    if (!_connected || _pendingHydration.isEmpty || _batchTimer != null) {
      return;
    }
    _batchTimer = Timer(_batchDelay, _flushPendingHydration);
  }

  void _startConnectedResources() {
    if (_disposed || !_connected) return;

    _subscriptionRetryTimer?.cancel();
    _subscriptionRetryTimer = null;
    unawaited(_subscribePresenceUpdates());

    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(_refreshInterval, (_) {
      if (_connected && _tracked.isNotEmpty) {
        unawaited(_queryPresence(Set<String>.from(_tracked)));
      }
    });

    if (_tracked.isNotEmpty) {
      _pendingHydration.clear();
      unawaited(_queryPresence(Set<String>.from(_tracked)));
    }
  }

  void _stopConnectedResources() {
    _subscriptionVersion++;
    _presenceUnsub?.call();
    _presenceUnsub = null;
    _batchTimer?.cancel();
    _batchTimer = null;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _subscriptionRetryTimer?.cancel();
    _subscriptionRetryTimer = null;
    _pendingHydration.clear();
  }

  void _dispose() {
    _disposed = true;
    _connected = false;
    _stopConnectedResources();
    _tracked.clear();
    _revisions.clear();
  }

  void _flushPendingHydration() {
    _batchTimer = null;
    if (_disposed || !_connected) return;

    final unresolved = _pendingHydration
        .where((pubkey) => !_cache.containsKey(pubkey))
        .toSet();
    _pendingHydration.clear();
    if (unresolved.isNotEmpty) {
      unawaited(_queryPresence(unresolved));
    }
  }

  Future<void> _queryPresence(Set<String> requested) async {
    if (_disposed || !_connected || requested.isEmpty) return;

    final pubkeys = requested.toList()..sort();
    final requestRevisions = <String, int>{};
    for (final pubkey in pubkeys) {
      final revision = (_revisions[pubkey] ?? 0) + 1;
      _revisions[pubkey] = revision;
      requestRevisions[pubkey] = revision;
    }

    final filters = <NostrFilter>[];
    for (
      var offset = 0;
      offset < pubkeys.length;
      offset += _maxAuthorsPerFilter
    ) {
      final end = offset + _maxAuthorsPerFilter < pubkeys.length
          ? offset + _maxAuthorsPerFilter
          : pubkeys.length;
      final authors = pubkeys.sublist(offset, end);
      filters.add(
        NostrFilter(
          kinds: const [EventKind.presenceUpdate],
          authors: authors,
          limit: authors.length,
        ),
      );
    }

    final List<NostrEvent> events;
    try {
      events = await ref
          .read(relaySessionProvider.notifier)
          .queryRelay(filters);
    } catch (error) {
      debugPrint('[PresenceCacheNotifier] presence query failed: $error');
      return;
    }

    if (_disposed || !_connected) return;

    final latest = <String, ({int createdAt, String status})>{};
    for (final event in events) {
      if (event.kind != EventKind.presenceUpdate) continue;
      final subject = event.getTagValue('p')?.trim().toLowerCase();
      final status = _validStatus(event.content);
      if (subject == null || !requested.contains(subject) || status == null) {
        continue;
      }
      final previous = latest[subject];
      if (previous == null || event.createdAt > previous.createdAt) {
        latest[subject] = (createdAt: event.createdAt, status: status);
      }
    }

    final updated = Map<String, String>.from(_cache);
    var changed = false;
    for (final pubkey in pubkeys) {
      if (_revisions[pubkey] != requestRevisions[pubkey]) continue;
      final status = latest[pubkey]?.status ?? 'offline';
      if (updated[pubkey] == status) continue;
      updated[pubkey] = status;
      changed = true;
    }
    if (changed) _publish(updated);
  }

  /// Subscribe to live kind:20001 updates, retrying only subscription setup.
  Future<void> _subscribePresenceUpdates([int attempt = 0]) async {
    if (_disposed || !_connected) return;

    _presenceUnsub?.call();
    _presenceUnsub = null;
    _subscriptionVersion++;
    final version = _subscriptionVersion;

    final session = ref.read(relaySessionProvider.notifier);
    try {
      final unsub = await session.subscribe(
        const NostrFilter(kinds: [EventKind.presenceUpdate], limit: 0),
        _handlePresenceEvent,
      );
      if (_disposed || !_connected || version != _subscriptionVersion) {
        unsub();
        return;
      }
      _subscriptionRetryTimer?.cancel();
      _subscriptionRetryTimer = null;
      _presenceUnsub = unsub;
    } catch (error) {
      if (_disposed || !_connected || version != _subscriptionVersion) return;
      debugPrint(
        '[PresenceCacheNotifier] presence subscription failed: $error',
      );
      final index = attempt < _subscriptionRetryDelays.length
          ? attempt
          : _subscriptionRetryDelays.length - 1;
      _subscriptionRetryTimer?.cancel();
      _subscriptionRetryTimer = Timer(
        _subscriptionRetryDelays[index],
        () => unawaited(_subscribePresenceUpdates(attempt + 1)),
      );
    }
  }

  void _handlePresenceEvent(NostrEvent event) {
    if (_disposed || event.kind != EventKind.presenceUpdate) return;
    final pubkey = event.pubkey.trim().toLowerCase();
    if (!_tracked.contains(pubkey)) return;
    final status = _validStatus(event.content);
    if (status == null) return;

    _revisions[pubkey] = (_revisions[pubkey] ?? 0) + 1;
    if (_cache[pubkey] == status) return;
    final updated = Map<String, String>.from(_cache)..[pubkey] = status;
    _publish(updated);
  }

  String? _validStatus(String content) {
    final status = content.trim();
    return switch (status) {
      'online' || 'away' || 'offline' => status,
      _ => null,
    };
  }

  void _publish(Map<String, String> updated) {
    if (_disposed) return;
    _cache = Map.unmodifiable(updated);
    state = _cache;
  }
}

final presenceCacheProvider =
    NotifierProvider<PresenceCacheNotifier, Map<String, String>>(
      PresenceCacheNotifier.new,
    );
