import 'dart:async';

import 'package:dart_music_player_protocol/dart_music_player_protocol_io.dart';

/// A self-contained native transport demonstration; no audio backend needed.
Future<void> main() async {
  final host = _DemoPlayer();
  final server = MusicControlServer(requests: host, requestedPort: 0);
  await server.start();
  final remote = RemoteMusicRequests(
    endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
  );
  final connection = remote.connectionStates.firstWhere(
    (state) => state.phase == MusicControlConnectionPhase.connected,
  );
  try {
    remote.start();
    await connection.timeout(const Duration(seconds: 5));
    print('Connected to ${remote.endpoint}');
    print('Track: ${remote.current.nowPlaying?.item.title}');
    final paused = await remote.setPaused(true);
    print(
      'Pause accepted: $paused; host paused: ${host.current.nowPlaying?.paused}',
    );
  } finally {
    await remote.close();
    await server.close();
    await host.close();
  }
}

class _DemoPlayer implements MusicRequests {
  final _states = StreamController<MusicQueueSnapshot>.broadcast();
  bool _paused = false;
  int _revision = 0;
  final _startedAt = DateTime.now();

  @override
  MusicQueueSnapshot get current => MusicQueueSnapshot(
    revision: _revision,
    nowPlaying: MusicNowPlaying(
      item: MusicQueueItem(
        id: 'demo-track',
        requestedBy: '',
        sourceUrl: Uri.parse('https://example.com/audio'),
        phase: MusicQueueItemPhase.ready,
        title: 'Example track',
        author: 'Example artist',
        duration: const Duration(minutes: 3),
        thumbnail: null,
      ),
      startedAt: _startedAt,
      position: Duration.zero,
      positionUpdatedAt: DateTime.now(),
      paused: _paused,
    ),
    queue: const [],
    lastError: null,
  );

  @override
  Stream<MusicQueueSnapshot> get states => _states.stream;

  @override
  Future<bool> setPaused(bool paused) async {
    _paused = paused;
    _revision++;
    _states.add(current);
    return true;
  }

  // This minimal demo only supports pause. A real host implements all controls.
  @override
  Future<bool> seek(Duration position) async => false;
  @override
  Future<bool> skip() async => false;
  @override
  Future<bool> remove(String itemId) async => false;
  @override
  Future<void> close() => _states.close();
}
