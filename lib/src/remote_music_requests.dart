import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'music_control_protocol.dart';
import '../dart_music_player_protocol.dart';

enum MusicControlConnectionPhase {
  disconnected,
  connecting,
  connected,
  reconnecting,
  incompatible,
  closed,
}

class MusicControlConnectionState {
  final MusicControlConnectionPhase phase;
  final int attempt;
  final Duration? retryIn;
  final String? lastError;

  const MusicControlConnectionState({
    required this.phase,
    this.attempt = 0,
    this.retryIn,
    this.lastError,
  });

  static const disconnected = MusicControlConnectionState(
    phase: MusicControlConnectionPhase.disconnected,
  );
}

class RemoteMusicRequests implements MusicRequests {
  final Uri endpoint;
  final Duration requestTimeout;
  final List<Duration> reconnectDelays;

  HttpClient? _httpClient;
  final _stateController = StreamController<MusicQueueSnapshot>.broadcast();
  final _connectionController =
      StreamController<MusicControlConnectionState>.broadcast();

  MusicQueueSnapshot _current = MusicQueueSnapshot.empty;
  int _acceptedRevision = -1;
  MusicControlConnectionState _connection =
      MusicControlConnectionState.disconnected;
  String? _serverId;
  WebSocket? _socket;
  StreamSubscription<dynamic>? _socketSubscription;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _started = false;
  bool _connecting = false;
  bool _closed = false;

  RemoteMusicRequests({
    required this.endpoint,
    this.requestTimeout = const Duration(seconds: 3),
    this.reconnectDelays = const [
      Duration(milliseconds: 500),
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 5),
    ],
    HttpClient? httpClient,
  }) : _httpClient = httpClient {
    if (endpoint.scheme != 'http' && endpoint.scheme != 'https') {
      throw ArgumentError.value(
        endpoint,
        'endpoint',
        'Only http and https endpoints are supported',
      );
    }
    if (reconnectDelays.isEmpty) {
      throw ArgumentError.value(
        reconnectDelays,
        'reconnectDelays',
        'At least one reconnect delay is required',
      );
    }
  }

  @override
  MusicQueueSnapshot get current => _current;

  @override
  Stream<MusicQueueSnapshot> get states async* {
    yield _current;
    yield* _stateController.stream;
  }

  MusicControlConnectionState get currentConnection => _connection;

  Stream<MusicControlConnectionState> get connectionStates async* {
    yield _connection;
    yield* _connectionController.stream;
  }

  void start() {
    if (_started || _closed) return;
    _started = true;
    unawaited(_connect());
  }

  Future<void> _connect() async {
    if (_closed || _connecting || _socket != null) return;
    _connecting = true;
    _emitConnection(
      MusicControlConnectionState(
        phase:
            _reconnectAttempt == 0
                ? MusicControlConnectionPhase.connecting
                : MusicControlConnectionPhase.reconnecting,
        attempt: _reconnectAttempt,
        lastError: _connection.lastError,
      ),
    );

    try {
      final initial = await _requestJson(
        'GET',
        MusicControlProtocol.playerPath,
      );
      if (_closed) return;
      _acceptSnapshotEnvelope(initial);

      final socket = await WebSocket.connect(
        _uriFor(MusicControlProtocol.eventsPath, webSocket: true).toString(),
      ).timeout(requestTimeout);
      if (_closed) {
        await socket.close();
        return;
      }

      socket.pingInterval = const Duration(seconds: 15);
      _socket = socket;
      _reconnectAttempt = 0;
      _emitConnection(
        const MusicControlConnectionState(
          phase: MusicControlConnectionPhase.connected,
        ),
      );
      _socketSubscription = socket.listen(
        (message) => _handleSocketMessage(socket, message),
        onDone: () => _handleSocketClosed(socket),
        onError: (Object error) => _handleSocketClosed(socket, error: error),
        cancelOnError: true,
      );
    } on MusicControlVersionException catch (error) {
      _emitConnection(
        MusicControlConnectionState(
          phase: MusicControlConnectionPhase.incompatible,
          lastError: _describeError(error),
        ),
      );
    } catch (error) {
      _scheduleReconnect(error);
    } finally {
      _connecting = false;
    }
  }

  void _handleSocketMessage(WebSocket socket, Object? message) {
    if (!identical(socket, _socket)) return;
    try {
      if (message is! String) {
        throw const MusicControlProtocolException(
          'Expected a text WebSocket message',
        );
      }
      _acceptSnapshotEnvelope(jsonDecode(message));
    } catch (error) {
      _handleSocketClosed(socket, error: error);
      unawaited(socket.close(WebSocketStatus.unsupportedData));
    }
  }

  void _handleSocketClosed(WebSocket socket, {Object? error}) {
    if (!identical(socket, _socket) || _closed) return;
    _socket = null;
    unawaited(_socketSubscription?.cancel());
    _socketSubscription = null;
    _scheduleReconnect(error ?? 'Connection closed by the player host');
  }

  void _scheduleReconnect(Object error) {
    if (_closed || _reconnectTimer != null) return;
    // A disconnected view must not keep advancing an old playback timeline.
    _current = MusicQueueSnapshot.empty;
    _stateController.add(_current);
    final index = _reconnectAttempt.clamp(0, reconnectDelays.length - 1);
    final delay = reconnectDelays[index];
    _reconnectAttempt++;
    _emitConnection(
      MusicControlConnectionState(
        phase: MusicControlConnectionPhase.reconnecting,
        attempt: _reconnectAttempt,
        retryIn: delay,
        lastError: _describeError(error),
      ),
    );
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      unawaited(_connect());
    });
  }

  void _acceptSnapshotEnvelope(Object? value) {
    if (_closed) return;
    final envelope = MusicControlProtocol.snapshotEnvelopeFromJson(value);
    final serverChanged = envelope.serverId != _serverId;
    if (!serverChanged && envelope.snapshot.revision < _acceptedRevision) {
      return;
    }

    _serverId = envelope.serverId;
    _acceptedRevision = envelope.snapshot.revision;
    _current = envelope.snapshot;
    _stateController.add(_current);
  }

  @override
  Future<bool> setPaused(bool paused) =>
      _sendCommand({'command': 'setPaused', 'paused': paused});

  @override
  Future<bool> seek(Duration position) => _sendCommand({
    'command': 'seek',
    'positionMs': position.inMilliseconds.clamp(0, 0x7FFFFFFF).toInt(),
  });

  @override
  Future<bool> skip() => _sendCommand({'command': 'skip'});

  @override
  Future<bool> remove(String itemId) =>
      _sendCommand({'command': 'remove', 'itemId': itemId});

  Future<bool> _sendCommand(Map<String, Object?> command) async {
    if (_closed || _connection.phase != MusicControlConnectionPhase.connected) {
      return false;
    }
    try {
      final response = await _requestJson(
        'POST',
        MusicControlProtocol.commandsPath,
        {'protocolVersion': MusicControlProtocol.version, ...command},
      );
      if (response['protocolVersion'] != MusicControlProtocol.version ||
          response['type'] != 'commandResult') {
        throw const MusicControlProtocolException(
          'Invalid command response from the player host',
        );
      }

      _acceptSnapshotEnvelope({
        'protocolVersion': response['protocolVersion'],
        'serverId': response['serverId'],
        'type': 'snapshot',
        'snapshot': response['snapshot'],
      });
      return response['ok'] == true;
    } catch (error) {
      _emitConnection(
        MusicControlConnectionState(
          phase: _connection.phase,
          attempt: _connection.attempt,
          retryIn: _connection.retryIn,
          lastError: _describeError(error),
        ),
      );
      if (_socket == null && _reconnectTimer == null) {
        _scheduleReconnect(error);
      }
      return false;
    }
  }

  Future<Map<String, dynamic>> _requestJson(
    String method,
    String path, [
    Object? body,
  ]) async {
    final client = _httpClient ??= HttpClient();
    final request = await client
        .openUrl(method, _uriFor(path))
        .timeout(requestTimeout);
    request.headers
      ..contentType = ContentType.json
      ..set('x-music-player-client', 'dart_music_player_protocol');
    if (body != null) request.write(jsonEncode(body));

    final response = await request.close().timeout(requestTimeout);
    final text = await utf8.decoder
        .bind(response)
        .join()
        .timeout(requestTimeout);
    final decoded = text.isEmpty ? null : jsonDecode(text);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final detail =
          decoded is Map<String, dynamic>
              ? decoded['error']
              : response.reasonPhrase;
      throw HttpException(
        'Player host returned HTTP ${response.statusCode}: ${detail ?? 'unknown error'}',
        uri: _uriFor(path),
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const MusicControlProtocolException(
        'Player host returned an invalid JSON response',
      );
    }
    return decoded;
  }

  Uri _uriFor(String path, {bool webSocket = false}) => endpoint.replace(
    scheme:
        webSocket
            ? (endpoint.scheme == 'https' ? 'wss' : 'ws')
            : endpoint.scheme,
    path: path,
    query: null,
    fragment: null,
  );

  void _emitConnection(MusicControlConnectionState next) {
    if (_closed) return;
    _connection = next;
    _connectionController.add(next);
  }

  static String _describeError(Object error) {
    final text = error.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.length <= 240 ? text : '${text.substring(0, 237)}...';
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _socketSubscription?.cancel();
    _socketSubscription = null;
    await _socket?.close(WebSocketStatus.normalClosure);
    _socket = null;
    _httpClient?.close(force: true);
    _httpClient = null;
    _connection = const MusicControlConnectionState(
      phase: MusicControlConnectionPhase.closed,
    );
    _connectionController.add(_connection);
    await _stateController.close();
    await _connectionController.close();
  }
}
