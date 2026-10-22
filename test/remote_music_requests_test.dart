import 'package:dart_music_player_protocol/dart_music_player_protocol_io.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test(
    'disconnect clears state and the same server revision restores it',
    () async {
      final reservation = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final port = reservation.port;
      await reservation.close(force: true);
      final requests = _FakeMusicRequests(_snapshot(7));
      final server = MusicControlServer(
        requests: requests,
        requestedPort: port,
      );
      final remote = RemoteMusicRequests(
        endpoint: Uri.parse('http://127.0.0.1:$port'),
        requestTimeout: const Duration(seconds: 1),
        reconnectDelays: const [Duration(milliseconds: 20)],
      );
      addTearDown(() async {
        await remote.close();
        await server.close();
        await requests.close();
      });
      await server.start();
      remote.start();
      await _waitUntil(
        () =>
            remote.currentConnection.phase ==
                MusicControlConnectionPhase.connected &&
            remote.current.revision == 7,
      );
      final serverId = server.serverId;
      await server.close();
      await _waitUntil(
        () =>
            remote.currentConnection.phase ==
            MusicControlConnectionPhase.reconnecting,
      );
      expect(remote.current.queue, isEmpty);
      expect(await remote.skip(), isFalse);
      await server.start();
      expect(server.serverId, serverId);
      await _waitUntil(
        () =>
            remote.currentConnection.phase ==
                MusicControlConnectionPhase.connected &&
            remote.current.revision == 7,
      );
      expect(remote.current.queue.single.title, 'Track 7');
      await remote.close();
      expect(server.isRunning, isTrue);
      expect(requests.current.revision, 7);
    },
  );

  test('connects, receives state, sends commands, and reconnects', () async {
    final firstRequests = _FakeMusicRequests(_snapshot(7));
    final firstServer = MusicControlServer(
      requests: firstRequests,
      requestedPort: 0,
    );
    await firstServer.start();
    final port = firstServer.port!;
    final remote = RemoteMusicRequests(
      endpoint: Uri.parse('http://127.0.0.1:$port'),
      requestTimeout: const Duration(seconds: 1),
      reconnectDelays: const [Duration(milliseconds: 20)],
    );
    final connectionStates = <MusicControlConnectionState>[];
    final subscription = remote.connectionStates.listen(connectionStates.add);
    MusicControlServer? secondServer;
    _FakeMusicRequests? secondRequests;
    addTearDown(() async {
      await subscription.cancel();
      await remote.close();
      await firstServer.close();
      await secondServer?.close();
      await firstRequests.close();
      await secondRequests?.close();
    });

    remote.start();
    await _waitUntil(
      () =>
          remote.currentConnection.phase ==
              MusicControlConnectionPhase.connected &&
          remote.current.revision == 7,
    );

    expect(await remote.setPaused(true), isTrue);
    expect(await remote.seek(const Duration(seconds: 15)), isTrue);
    expect(await remote.skip(), isTrue);
    expect(await remote.remove('queued-1'), isTrue);
    expect(firstRequests.pauseChanges, [true]);
    expect(firstRequests.seekPositions, [const Duration(seconds: 15)]);
    expect(firstRequests.skipCount, 1);
    expect(firstRequests.removedItemIds, ['queued-1']);

    firstRequests.emit(_snapshot(8));
    await _waitUntil(() => remote.current.revision == 8);

    await firstServer.close();
    await _waitUntil(
      () =>
          remote.currentConnection.phase ==
          MusicControlConnectionPhase.reconnecting,
    );
    expect(remote.currentConnection.lastError, isNotEmpty);

    secondRequests = _FakeMusicRequests(_snapshot(1));
    secondServer = MusicControlServer(
      requests: secondRequests,
      requestedPort: port,
    );
    await secondServer.start();

    await _waitUntil(
      () =>
          remote.currentConnection.phase ==
              MusicControlConnectionPhase.connected &&
          remote.current.revision == 1,
    );
    expect(
      connectionStates.map((state) => state.phase),
      contains(MusicControlConnectionPhase.reconnecting),
    );
  });

  test(
    'reports an incompatible protocol without reconnecting forever',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requestCount = 0;
      server.listen((request) async {
        requestCount++;
        request.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'protocolVersion': 999,
              'serverId': 'future-overlay',
              'type': 'snapshot',
              'snapshot': {},
            }),
          );
        await request.response.close();
      });
      final remote = RemoteMusicRequests(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
        reconnectDelays: const [Duration(milliseconds: 10)],
      );
      addTearDown(() async {
        await remote.close();
        await server.close(force: true);
      });

      remote.start();
      await _waitUntil(
        () =>
            remote.currentConnection.phase ==
            MusicControlConnectionPhase.incompatible,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(remote.currentConnection.lastError, contains('999'));
      expect(requestCount, 1);
    },
  );
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for remote music state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _FakeMusicRequests implements MusicRequests {
  final _states = StreamController<MusicQueueSnapshot>.broadcast();
  final List<bool> pauseChanges = [];
  final List<Duration> seekPositions = [];
  final List<String> removedItemIds = [];
  MusicQueueSnapshot _current;
  int skipCount = 0;

  _FakeMusicRequests(this._current);

  @override
  MusicQueueSnapshot get current => _current;

  @override
  Stream<MusicQueueSnapshot> get states async* {
    yield _current;
    yield* _states.stream;
  }

  void emit(MusicQueueSnapshot snapshot) {
    _current = snapshot;
    _states.add(snapshot);
  }

  @override
  Future<bool> setPaused(bool paused) async {
    pauseChanges.add(paused);
    return true;
  }

  @override
  Future<bool> seek(Duration position) async {
    seekPositions.add(position);
    return true;
  }

  @override
  Future<bool> skip() async {
    skipCount++;
    return true;
  }

  @override
  Future<bool> remove(String itemId) async {
    removedItemIds.add(itemId);
    return true;
  }

  @override
  Future<void> close() => _states.close();
}

MusicQueueSnapshot _snapshot(int revision) => MusicQueueSnapshot(
  revision: revision,
  nowPlaying: null,
  queue: [
    MusicQueueItem(
      id: 'track-$revision',
      requestedBy: 'viewer',
      sourceUrl: Uri.parse('https://youtu.be/track-$revision'),
      phase: MusicQueueItemPhase.ready,
      title: 'Track $revision',
      author: 'Artist',
      duration: const Duration(minutes: 3),
      thumbnail: null,
      downloadProgress: 1,
    ),
  ],
  lastError: null,
);
