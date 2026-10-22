import 'package:dart_music_player_protocol/dart_music_player_protocol_io.dart';
import 'package:test/test.dart';

void main() {
  test('manual requests and their errors may have an empty requester', () {
    final wire = MusicControlProtocol.snapshotToJson(
      MusicQueueSnapshot(
        revision: 1,
        nowPlaying: null,
        queue: [
          MusicQueueItem(
            id: 'manual',
            requestedBy: '',
            sourceUrl: Uri.parse('https://youtu.be/aaaaaaaaaaa'),
            phase: MusicQueueItemPhase.ready,
            title: 'Manual',
            author: '',
            duration: const Duration(minutes: 3),
            thumbnail: null,
          ),
        ],
        lastError: const MusicQueueError(
          requester: '',
          type: MusicQueueErrorType.invalidYoutubeUrl,
        ),
      ),
    );
    expect(((wire['queue'] as List).single as Map)['requestedBy'], '—');
    expect((wire['lastError'] as Map)['requester'], '—');
    final restored = MusicControlProtocol.snapshotFromJson(wire);
    expect(restored.queue.single.requestedBy, isEmpty);
    expect(restored.lastError!.requester, isEmpty);
  });
  for (final phase in [
    MusicQueueItemPhase.analyzing,
    MusicQueueItemPhase.normalizing,
  ]) {
    test('$phase is readable by new clients and falls back for v1 clients', () {
      final state = MusicQueueSnapshot(
        revision: 2,
        nowPlaying: null,
        queue: [_item('preparing', phase: phase)],
        lastError: null,
        volume: 0.4,
      );
      final wire = MusicControlProtocol.snapshotToJson(state);
      final item = (wire['queue'] as List).single as Map;
      expect(item['phase'], 'downloading');
      expect(item['preparationPhase'], phase.name);
      expect(
        MusicControlProtocol.snapshotFromJson(wire).queue.single.phase,
        phase,
      );
      expect(MusicControlProtocol.snapshotFromJson(wire).volume, 0.4);
      item.remove('preparationPhase');
      expect(
        MusicControlProtocol.snapshotFromJson(wire).queue.single.phase,
        MusicQueueItemPhase.downloading,
      );
      item['preparationPhase'] = 'future-detail';
      expect(
        MusicControlProtocol.snapshotFromJson(wire).queue.single.phase,
        MusicQueueItemPhase.downloading,
      );
      wire.remove('volume');
      expect(MusicControlProtocol.snapshotFromJson(wire).volume, 1);
    });
  }
  test('starting state round-trips and remains optional for older servers', () {
    final now = DateTime(2026);
    final state = MusicQueueSnapshot(
      revision: 1,
      nowPlaying: MusicNowPlaying(
        item: _item('cueing', phase: MusicQueueItemPhase.ready),
        startedAt: now,
        position: Duration.zero,
        positionUpdatedAt: now,
        paused: false,
        starting: true,
      ),
      queue: [],
      lastError: null,
    );
    final wire = MusicControlProtocol.snapshotToJson(state);
    expect(
      MusicControlProtocol.snapshotFromJson(wire).nowPlaying!.starting,
      isTrue,
    );
    (wire['nowPlaying']! as Map).remove('starting');
    expect(
      MusicControlProtocol.snapshotFromJson(wire).nowPlaying!.starting,
      isFalse,
    );
  });
  test(
    'media 403 keeps v1 compatibility without claiming login is required',
    () {
      const state = MusicQueueSnapshot(
        revision: 1,
        nowPlaying: null,
        queue: [],
        lastError: MusicQueueError(
          requester: 'viewer',
          type: MusicQueueErrorType.youtubeDownloadBlocked,
        ),
      );
      final wire = MusicControlProtocol.snapshotToJson(state);
      final error = wire['lastError'] as Map;
      expect(error['type'], 'operationFailed');
      expect(error['reason'], 'youtubeDownloadBlocked');
      expect(error['details'], contains('403'));
      expect(
        MusicControlProtocol.snapshotFromJson(wire).lastError?.type,
        MusicQueueErrorType.youtubeDownloadBlocked,
      );
    },
  );
  test(
    'YouTube verification keeps v1 controllers compatible and localizes on new clients',
    () {
      const state = MusicQueueSnapshot(
        revision: 1,
        nowPlaying: null,
        queue: [],
        lastError: MusicQueueError(
          requester: 'viewer',
          type: MusicQueueErrorType.youtubeAccessRequired,
        ),
      );
      final wire = MusicControlProtocol.snapshotToJson(state);
      final error = wire['lastError'] as Map;
      expect(error['type'], 'operationFailed');
      expect(error['reason'], 'youtubeAccessRequired');
      expect(error['details'], contains('connect YouTube'));
      expect(
        MusicControlProtocol.snapshotFromJson(wire).lastError?.type,
        MusicQueueErrorType.youtubeAccessRequired,
      );
    },
  );
  test('carries a preparation hold as an optional v1 field', () {
    const state = MusicQueueSnapshot(
      revision: 1,
      nowPlaying: null,
      queue: [],
      lastError: MusicQueueError(
        requester: 'viewer',
        type: MusicQueueErrorType.youtubeRateLimited,
      ),
      hold: MusicQueueErrorType.youtubeRateLimited,
    );
    final wire = MusicControlProtocol.snapshotToJson(state);
    final error = wire['lastError'] as Map;
    expect(wire['hold'], 'youtubeRateLimited');
    expect(error['type'], 'operationFailed');
    expect(error['reason'], 'youtubeRateLimited');
    expect(error['details'], contains('paused'));
    final restored = MusicControlProtocol.snapshotFromJson(wire);
    expect(restored.hold, MusicQueueErrorType.youtubeRateLimited);
    expect(restored.lastError?.type, MusicQueueErrorType.youtubeRateLimited);
    expect(
      MusicControlProtocol.snapshotFromJson({...wire}..remove('hold')).hold,
      isNull,
    );
    expect(
      MusicControlProtocol.snapshotFromJson({...wire, 'hold': 'future'}).hold,
      isNull,
    );
    expect(
      MusicControlProtocol.snapshotToJson(MusicQueueSnapshot.empty),
      isNot(contains('hold')),
    );
  });
  test('round-trips a complete music queue snapshot', () {
    final updatedAt = DateTime(2026, 9, 3, 14, 30, 15, 250);
    final playingItem = _item(
      'playing',
      phase: MusicQueueItemPhase.ready,
      progress: 1,
    );
    final original = MusicQueueSnapshot(
      revision: 42,
      nowPlaying: MusicNowPlaying(
        item: playingItem,
        startedAt: updatedAt.subtract(const Duration(seconds: 20)),
        position: const Duration(seconds: 20),
        positionUpdatedAt: updatedAt,
        paused: true,
      ),
      queue: [
        _item('resolving', phase: MusicQueueItemPhase.resolving),
        _item(
          'downloading',
          phase: MusicQueueItemPhase.downloading,
          progress: 0.375,
        ),
      ],
      lastError: const MusicQueueError(
        requester: 'viewer',
        type: MusicQueueErrorType.operationFailed,
        details: 'network unavailable',
      ),
    );

    final envelope = MusicControlProtocol.snapshotEnvelopeFromJson(
      MusicControlProtocol.snapshotEnvelope(
        serverId: 'server-1',
        snapshot: original,
      ),
    );

    expect(envelope.serverId, 'server-1');
    expect(envelope.snapshot.revision, 42);
    expect(envelope.snapshot.nowPlaying?.item.id, 'playing');
    expect(envelope.snapshot.nowPlaying?.paused, isTrue);
    expect(envelope.snapshot.nowPlaying?.position, const Duration(seconds: 20));
    expect(envelope.snapshot.nowPlaying?.positionUpdatedAt, updatedAt);
    expect(envelope.snapshot.queue.map((item) => item.phase), [
      MusicQueueItemPhase.resolving,
      MusicQueueItemPhase.downloading,
    ]);
    expect(envelope.snapshot.queue.last.downloadProgress, 0.375);
    expect(
      envelope.snapshot.lastError?.type,
      MusicQueueErrorType.operationFailed,
    );
    expect(envelope.snapshot.lastError?.details, 'network unavailable');
  });

  test('rejects incompatible protocol versions', () {
    expect(
      () => MusicControlProtocol.snapshotEnvelopeFromJson({
        'protocolVersion': MusicControlProtocol.version + 1,
        'serverId': 'server-1',
        'type': 'snapshot',
        'snapshot': MusicControlProtocol.snapshotToJson(
          MusicQueueSnapshot.empty,
        ),
      }),
      throwsA(isA<MusicControlProtocolException>()),
    );
  });
}

MusicQueueItem _item(
  String id, {
  required MusicQueueItemPhase phase,
  double? progress,
}) => MusicQueueItem(
  id: id,
  requestedBy: 'viewer',
  sourceUrl: Uri.parse('https://youtu.be/$id'),
  phase: phase,
  title: 'Track $id',
  author: 'Artist',
  duration: const Duration(minutes: 3),
  thumbnail: Uri.parse('https://img.youtube.com/$id.jpg'),
  downloadProgress: progress,
);
