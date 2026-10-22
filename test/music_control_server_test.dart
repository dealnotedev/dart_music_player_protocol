import 'package:dart_music_player_protocol/dart_music_player_protocol_io.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  late _FakeMusicRequests requests;
  late MusicControlServer server;
  late HttpClient httpClient;

  setUp(() async {
    requests = _FakeMusicRequests(_snapshot(1));
    server = MusicControlServer(requests: requests, requestedPort: 0);
    await server.start();
    httpClient = HttpClient();
  });

  tearDown(() async {
    httpClient.close(force: true);
    await server.close();
    await requests.close();
  });

  test('serves health and the current snapshot over HTTP', () async {
    final health = await _requestJson(
      httpClient,
      server.port!,
      'GET',
      MusicControlProtocol.healthPath,
    );
    expect(health.statusCode, HttpStatus.ok);
    expect(health.body['status'], 'ok');
    expect(health.body['protocolVersion'], MusicControlProtocol.version);

    final response = await _requestJson(
      httpClient,
      server.port!,
      'GET',
      MusicControlProtocol.playerPath,
    );
    final envelope = MusicControlProtocol.snapshotEnvelopeFromJson(
      response.body,
    );
    expect(envelope.snapshot.revision, 1);
    expect(envelope.snapshot.nowPlaying?.item.title, 'Track 1');
  });

  test('routes every player command to MusicRequests', () async {
    Future<_JsonResponse> command(Map<String, Object?> body) => _requestJson(
      httpClient,
      server.port!,
      'POST',
      MusicControlProtocol.commandsPath,
      {'protocolVersion': MusicControlProtocol.version, ...body},
    );

    expect(
      (await command({'command': 'setPaused', 'paused': true})).body['ok'],
      isTrue,
    );
    await command({'command': 'seek', 'positionMs': 12345});
    await command({'command': 'skip'});
    await command({'command': 'remove', 'itemId': 'queued-1'});

    expect(requests.pauseChanges, [true]);
    expect(requests.seekPositions, [const Duration(milliseconds: 12345)]);
    expect(requests.skipCount, 1);
    expect(requests.removedItemIds, ['queued-1']);
  });

  test('streams the initial and subsequent snapshots over WebSocket', () async {
    final socket = await WebSocket.connect(
      'ws://127.0.0.1:${server.port}${MusicControlProtocol.eventsPath}',
    );
    addTearDown(socket.close);
    final messages = StreamIterator<dynamic>(socket);

    expect(await messages.moveNext(), isTrue);
    final initial = MusicControlProtocol.snapshotEnvelopeFromJson(
      jsonDecode(messages.current as String),
    );
    expect(initial.snapshot.revision, 1);

    requests.emit(_snapshot(2));
    expect(await messages.moveNext(), isTrue);
    final next = MusicControlProtocol.snapshotEnvelopeFromJson(
      jsonDecode(messages.current as String),
    );
    expect(next.snapshot.revision, 2);
    await messages.cancel();
  });

  test('rejects browser-originated commands', () async {
    final request = await httpClient.postUrl(
      Uri.parse(
        'http://127.0.0.1:${server.port}${MusicControlProtocol.commandsPath}',
      ),
    );
    request.headers.set('origin', 'https://example.com');
    request.write('{}');
    final response = await request.close();
    await response.drain<void>();

    expect(response.statusCode, HttpStatus.forbidden);
  });
}

Future<_JsonResponse> _requestJson(
  HttpClient client,
  int port,
  String method,
  String path, [
  Object? body,
]) async {
  final request = await client.openUrl(
    method,
    Uri.parse('http://127.0.0.1:$port$path'),
  );
  request.headers.contentType = ContentType.json;
  if (body != null) request.write(jsonEncode(body));
  final response = await request.close();
  final text = await utf8.decoder.bind(response).join();
  return _JsonResponse(
    response.statusCode,
    jsonDecode(text) as Map<String, dynamic>,
  );
}

class _JsonResponse {
  final int statusCode;
  final Map<String, dynamic> body;

  const _JsonResponse(this.statusCode, this.body);
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

MusicQueueSnapshot _snapshot(int revision) {
  final item = MusicQueueItem(
    id: 'track-$revision',
    requestedBy: 'viewer',
    sourceUrl: Uri.parse('https://youtu.be/track-$revision'),
    phase: MusicQueueItemPhase.ready,
    title: 'Track $revision',
    author: 'Artist',
    duration: const Duration(minutes: 3),
    thumbnail: null,
    downloadProgress: 1,
  );
  return MusicQueueSnapshot(
    revision: revision,
    nowPlaying: MusicNowPlaying(
      item: item,
      startedAt: DateTime(2026, 9, 3, 12),
      position: const Duration(seconds: 10),
      positionUpdatedAt: DateTime.now(),
      paused: false,
    ),
    queue: const [],
    lastError: null,
  );
}
