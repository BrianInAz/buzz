import 'dart:async';
import 'dart:collection';

import 'package:buzz/features/profile/presence_cache_provider.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  testWidgets(
    'track batches an authenticated query and hydrates online presence',
    (tester) async {
      final relaySession = _RecordingRelaySessionNotifier()
        ..enqueueQueryResult([_snapshot('alice', 'online')]);
      final container = _buildContainer(relaySession: relaySession);

      container.read(presenceCacheProvider);
      await tester.pump();

      container.read(presenceCacheProvider.notifier).track(['ALICE']);
      await tester.pump(const Duration(milliseconds: 49));
      expect(relaySession.queries, isEmpty);

      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();

      expect(relaySession.queries, hasLength(1));
      expect(relaySession.queries.single, hasLength(1));
      expect(relaySession.queries.single.single.kinds, [
        EventKind.presenceUpdate,
      ]);
      expect(relaySession.queries.single.single.authors, ['alice']);
      expect(relaySession.queries.single.single.limit, 1);
      expect(container.read(presenceCacheProvider)['alice'], 'online');
      container.dispose();
    },
  );

  testWidgets(
    'snapshots trust p-tag subjects while live events remain author-scoped',
    (tester) async {
      final relaySession = _RecordingRelaySessionNotifier()
        ..enqueueQueryResult([
          _snapshot('alice', 'online', author: 'relay-author'),
        ]);
      final container = _buildContainer(relaySession: relaySession);

      container.read(presenceCacheProvider);
      await tester.pump();
      container.read(presenceCacheProvider.notifier).track(['alice', 'bob']);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump();

      expect(container.read(presenceCacheProvider)['alice'], 'online');
      expect(container.read(presenceCacheProvider)['relay-author'], isNull);

      relaySession.emit(
        _presence(
          'alice',
          'away',
          tags: const [
            ['p', 'bob'],
          ],
        ),
      );

      expect(container.read(presenceCacheProvider)['alice'], 'away');
      expect(container.read(presenceCacheProvider)['bob'], 'offline');
      container.dispose();
    },
  );

  testWidgets('successful snapshot omission records offline', (tester) async {
    final relaySession = _RecordingRelaySessionNotifier()
      ..enqueueQueryResult([]);
    final container = _buildContainer(relaySession: relaySession);

    container.read(presenceCacheProvider);
    await tester.pump();
    container.read(presenceCacheProvider.notifier).track(['alice']);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();

    expect(container.read(presenceCacheProvider)['alice'], 'offline');
    container.dispose();
  });

  testWidgets('query failure preserves the last known value', (tester) async {
    final relaySession = _RecordingRelaySessionNotifier()
      ..enqueueQueryResult([_snapshot('alice', 'online')])
      ..enqueueQueryError(StateError('query failed'));
    final container = _buildContainer(relaySession: relaySession);

    container.read(presenceCacheProvider);
    await tester.pump();
    container.read(presenceCacheProvider.notifier).track(['alice']);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();
    expect(container.read(presenceCacheProvider)['alice'], 'online');

    await tester.pump(const Duration(seconds: 60));
    await tester.pump();

    expect(relaySession.queries, hasLength(2));
    expect(container.read(presenceCacheProvider)['alice'], 'online');
    container.dispose();
  });

  testWidgets('live update wins over an older in-flight snapshot', (
    tester,
  ) async {
    final query = Completer<List<NostrEvent>>();
    final relaySession = _RecordingRelaySessionNotifier()
      ..enqueueQueryFuture(query.future);
    final container = _buildContainer(relaySession: relaySession);

    container.read(presenceCacheProvider);
    await tester.pump();
    container.read(presenceCacheProvider.notifier).track(['alice']);
    await tester.pump(const Duration(milliseconds: 50));
    expect(relaySession.queries, hasLength(1));

    relaySession.emit(_presence('alice', 'away'));
    expect(container.read(presenceCacheProvider)['alice'], 'away');

    query.complete([_snapshot('alice', 'online')]);
    await tester.pump();

    expect(container.read(presenceCacheProvider)['alice'], 'away');
    container.dispose();
  });

  testWidgets('repeated track calls normalize without query storms', (
    tester,
  ) async {
    final relaySession = _RecordingRelaySessionNotifier()
      ..enqueueQueryResult([_snapshot('alice', 'online')]);
    final container = _buildContainer(relaySession: relaySession);

    container.read(presenceCacheProvider);
    await tester.pump();
    final notifier = container.read(presenceCacheProvider.notifier);
    notifier.track([' ALICE ', 'alice']);
    notifier.track(['Alice']);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();

    expect(relaySession.queries, hasLength(1));
    expect(relaySession.queries.single.single.authors, ['alice']);

    notifier.track(['ALICE']);
    await tester.pump(const Duration(milliseconds: 100));
    expect(relaySession.queries, hasLength(1));
    container.dispose();
  });

  testWidgets('reconnection clears stale state and immediately rehydrates', (
    tester,
  ) async {
    final relaySession = _RecordingRelaySessionNotifier()
      ..enqueueQueryResult([_snapshot('alice', 'online')])
      ..enqueueQueryResult([_snapshot('alice', 'online')]);
    final container = _buildContainer(relaySession: relaySession);
    final presenceListener = container.listen(presenceCacheProvider, (_, _) {});

    container.read(presenceCacheProvider);
    await tester.pump();
    container.read(presenceCacheProvider.notifier).track(['alice']);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();
    expect(container.read(presenceCacheProvider)['alice'], 'online');

    relaySession.setStatus(SessionStatus.disconnected);
    await tester.pump();
    expect(container.read(presenceCacheProvider), isEmpty);
    expect(relaySession.activeListenerCount, 0);

    relaySession.setStatus(SessionStatus.connected);
    await tester.pump();
    await tester.pump();

    expect(relaySession.queries, hasLength(2));
    expect(relaySession.subscribeCallCount, 2);
    expect(container.read(presenceCacheProvider)['alice'], 'online');
    presenceListener.close();
    container.dispose();
  });

  testWidgets(
    'periodic refresh detects TTL expiry while live events stay the fast path',
    (tester) async {
      final relaySession = _RecordingRelaySessionNotifier()
        ..enqueueQueryResult([_snapshot('alice', 'online')])
        ..enqueueQueryResult([]);
      final container = _buildContainer(relaySession: relaySession);

      container.read(presenceCacheProvider);
      await tester.pump();
      container.read(presenceCacheProvider.notifier).track(['alice']);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump();
      expect(container.read(presenceCacheProvider)['alice'], 'online');

      relaySession.emit(_presence('alice', 'away'));
      expect(container.read(presenceCacheProvider)['alice'], 'away');

      await tester.pump(const Duration(seconds: 60));
      await tester.pump();
      expect(relaySession.queries, hasLength(2));
      expect(container.read(presenceCacheProvider)['alice'], 'offline');

      container.dispose();
      await tester.pump(const Duration(seconds: 60));
      expect(relaySession.queries, hasLength(2));
    },
  );

  testWidgets('failed initial subscription retries with backoff', (
    tester,
  ) async {
    final relaySession = _RecordingRelaySessionNotifier()
      ..subscribeFailuresRemaining = 1;
    final container = _buildContainer(relaySession: relaySession);

    container.read(presenceCacheProvider);
    await tester.pump();
    expect(relaySession.subscribeCallCount, 1);

    await tester.pump(const Duration(milliseconds: 999));
    expect(relaySession.subscribeCallCount, 1);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();

    expect(relaySession.subscribeCallCount, 2);
    expect(relaySession.activeListenerCount, 1);
    container.dispose();
  });

  test('WS presence event updates cache for tracked pubkey', () async {
    final relaySession = _RecordingRelaySessionNotifier();
    final container = _buildContainer(relaySession: relaySession);

    container.read(presenceCacheProvider);
    await _pumpEventQueue();
    container.read(presenceCacheProvider.notifier).track(['alice']);

    relaySession.emit(_presence('alice', 'online'));
    expect(container.read(presenceCacheProvider)['alice'], 'online');

    relaySession.emit(_presence('alice', 'away'));
    expect(container.read(presenceCacheProvider)['alice'], 'away');
    container.dispose();
  });

  test('WS presence event ignores untracked pubkeys', () async {
    final relaySession = _RecordingRelaySessionNotifier();
    final container = _buildContainer(relaySession: relaySession);

    container.read(presenceCacheProvider);
    await _pumpEventQueue();
    container.read(presenceCacheProvider.notifier).track(['alice']);

    relaySession.emit(_presence('bob', 'online'));
    expect(container.read(presenceCacheProvider).containsKey('bob'), isFalse);
    container.dispose();
  });

  test('WS presence event ignores invalid status values', () async {
    final relaySession = _RecordingRelaySessionNotifier();
    final container = _buildContainer(relaySession: relaySession);

    container.read(presenceCacheProvider);
    await _pumpEventQueue();
    container.read(presenceCacheProvider.notifier).track(['alice']);
    relaySession.emit(_presence('alice', 'online'));

    relaySession.emit(_presence('alice', 'garbage-status'));
    expect(container.read(presenceCacheProvider)['alice'], 'online');
    container.dispose();
  });

  test('WS presence event skips no-op updates', () async {
    final relaySession = _RecordingRelaySessionNotifier();
    final container = _buildContainer(relaySession: relaySession);

    container.read(presenceCacheProvider);
    await _pumpEventQueue();
    container.read(presenceCacheProvider.notifier).track(['alice']);
    relaySession.emit(_presence('alice', 'online'));

    var stateChangeCount = 0;
    container.listen(presenceCacheProvider, (prev, next) => stateChangeCount++);
    relaySession.emit(_presence('alice', 'online'));

    expect(stateChangeCount, 0);
    container.dispose();
  });

  test('subscribes to kind:20001 with limit 0', () async {
    final relaySession = _RecordingRelaySessionNotifier();
    final container = _buildContainer(relaySession: relaySession);

    container.read(presenceCacheProvider);
    await _pumpEventQueue();

    expect(relaySession.filters, hasLength(1));
    expect(relaySession.filters.single.kinds, [EventKind.presenceUpdate]);
    expect(relaySession.filters.single.limit, 0);
    container.dispose();
  });

  test('WS event uses the actual pubkey as the map key', () async {
    final relaySession = _RecordingRelaySessionNotifier();
    final container = _buildContainer(relaySession: relaySession);

    container.read(presenceCacheProvider);
    await _pumpEventQueue();
    container.read(presenceCacheProvider.notifier).track([
      'deadbeef',
      'cafebabe',
    ]);

    relaySession.emit(_presence('cafebabe', 'offline'));
    relaySession.emit(_presence('deadbeef', 'online'));

    final cache = container.read(presenceCacheProvider);
    expect(cache['deadbeef'], 'online');
    expect(cache['cafebabe'], 'offline');
    expect(cache.containsKey('pubkey'), isFalse);
    container.dispose();
  });
}

NostrEvent _presence(
  String pubkey,
  String status, {
  List<List<String>> tags = const [],
}) => NostrEvent(
  id: 'evt-$pubkey-$status',
  pubkey: pubkey,
  createdAt: 1000,
  kind: EventKind.presenceUpdate,
  tags: tags,
  content: status,
  sig: 'sig',
);

NostrEvent _snapshot(
  String subject,
  String status, {
  String author = 'relay',
  int createdAt = 1000,
}) => NostrEvent(
  id: 'snapshot-$subject-$status-$createdAt',
  pubkey: author,
  createdAt: createdAt,
  kind: EventKind.presenceUpdate,
  tags: [
    ['p', subject],
  ],
  content: status,
  sig: 'relay-sig',
);

Future<void> _pumpEventQueue() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

ProviderContainer _buildContainer({
  required _RecordingRelaySessionNotifier relaySession,
}) {
  return ProviderContainer(
    overrides: [
      appLifecycleProvider.overrideWith(() => _FakeAppLifecycleNotifier()),
      relaySessionProvider.overrideWith(() => relaySession),
    ],
  );
}

class _RecordingRelaySessionNotifier extends RelaySessionNotifier {
  final List<NostrFilter> filters = [];
  final List<List<NostrFilter>> queries = [];
  final List<void Function(NostrEvent)> _listeners = [];
  final Queue<Future<List<NostrEvent>> Function()> _queryPlans = Queue();
  int subscribeCallCount = 0;
  int subscribeFailuresRemaining = 0;

  int get activeListenerCount => _listeners.length;

  @override
  SessionState build() => const SessionState(status: SessionStatus.connected);

  void setStatus(SessionStatus status) {
    state = SessionState(status: status);
  }

  void enqueueQueryResult(List<NostrEvent> events) {
    _queryPlans.add(() async => events);
  }

  void enqueueQueryFuture(Future<List<NostrEvent>> events) {
    _queryPlans.add(() => events);
  }

  void enqueueQueryError(Object error) {
    _queryPlans.add(() async => throw error);
  }

  @override
  Future<List<NostrEvent>> queryRelay(
    List<NostrFilter> filters, {
    Duration timeout = const Duration(seconds: 8),
  }) {
    queries.add(List.unmodifiable(filters));
    if (_queryPlans.isEmpty) return Future.value(const []);
    return _queryPlans.removeFirst()();
  }

  @override
  Future<void Function()> subscribe(
    NostrFilter filter,
    void Function(NostrEvent) onEvent, {
    void Function(String message)? onClosed,
  }) async {
    subscribeCallCount++;
    if (subscribeFailuresRemaining > 0) {
      subscribeFailuresRemaining--;
      throw StateError('subscription failed');
    }
    filters.add(filter);
    _listeners.add(onEvent);
    return () {
      filters.remove(filter);
      _listeners.remove(onEvent);
    };
  }

  void emit(NostrEvent event) {
    for (final listener in List.of(_listeners)) {
      listener(event);
    }
  }
}

class _FakeAppLifecycleNotifier extends AppLifecycleNotifier {
  @override
  AppLifecycleState build() => AppLifecycleState.resumed;
}
