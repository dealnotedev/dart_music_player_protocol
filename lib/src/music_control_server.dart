import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'music_control_protocol.dart';
import '../dart_music_player_protocol.dart';

class MusicControlServer {
  static const int _maxRequestBytes = 64 * 1024;

  final MusicRequests requests;
  final int requestedPort;

  final Set<WebSocket> _sockets = {};
  final String serverId = _createServerId();

  HttpServer? _server;
  StreamSubscription<MusicQueueSnapshot>? _stateSubscription;

  MusicControlServer({
    required this.requests,
    this.requestedPort = MusicControlProtocol.defaultPort,
  });

  bool get isRunning => _server != null;

  int? get port => _server?.port;

  Future<void> start() async {
    if (_server != null) return;
    if (requestedPort < 0 || requestedPort > 65535) {
      throw ArgumentError.value(requestedPort, 'requestedPort');
    }

    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      requestedPort,
      shared: false,
    );
    _server = server;
    _stateSubscription = requests.states.listen(_broadcastSnapshot);
    server.listen(_handleRequest);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (!_isTrustedLoopbackRequest(request)) {
      await _writeError(request, HttpStatus.forbidden, 'Request rejected');
      return;
    }

    try {
      switch ((request.method, request.uri.path)) {
        case ('GET', MusicControlProtocol.healthPath):
          await _writeJson(request, HttpStatus.ok, {
            'protocolVersion': MusicControlProtocol.version,
            'serverId': serverId,
            'status': 'ok',
          });
          return;
        case ('GET', MusicControlProtocol.playerPath):
          await _writeJson(
            request,
            HttpStatus.ok,
            MusicControlProtocol.snapshotEnvelope(
              serverId: serverId,
              snapshot: requests.current,
            ),
          );
          return;
        case ('POST', MusicControlProtocol.commandsPath):
          await _handleCommand(request);
          return;
        case ('GET', MusicControlProtocol.eventsPath):
          await _handleWebSocket(request);
          return;
        default:
          await _writeError(request, HttpStatus.notFound, 'Route not found');
      }
    } on MusicControlProtocolException catch (error) {
      await _writeError(request, HttpStatus.badRequest, error.message);
    } on FormatException catch (error) {
      await _writeError(
        request,
        HttpStatus.badRequest,
        error.message.toString(),
      );
    } catch (error) {
      await _writeError(
        request,
        HttpStatus.internalServerError,
        'Internal server error: $error',
      );
    }
  }

  Future<void> _handleCommand(HttpRequest request) async {
    final contentLength = request.contentLength;
    if (contentLength > _maxRequestBytes) {
      await _writeError(
        request,
        HttpStatus.requestEntityTooLarge,
        'Request body is too large',
      );
      return;
    }

    final body = await utf8.decoder.bind(request).join();
    if (body.length > _maxRequestBytes) {
      await _writeError(
        request,
        HttpStatus.requestEntityTooLarge,
        'Request body is too large',
      );
      return;
    }

    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const MusicControlProtocolException(
        'Command body must be a JSON object',
      );
    }
    if (decoded['protocolVersion'] != MusicControlProtocol.version) {
      throw const MusicControlProtocolException(
        'Unsupported or missing protocolVersion',
      );
    }

    final bool ok;
    switch (decoded['command']) {
      case 'setPaused':
        final paused = decoded['paused'];
        if (paused is! bool) {
          throw const MusicControlProtocolException('paused must be a boolean');
        }
        ok = await requests.setPaused(paused);
      case 'seek':
        final positionMs = decoded['positionMs'];
        if (positionMs is! int || positionMs < 0) {
          throw const MusicControlProtocolException(
            'positionMs must be a non-negative integer',
          );
        }
        ok = await requests.seek(Duration(milliseconds: positionMs));
      case 'skip':
        ok = await requests.skip();
      case 'remove':
        final itemId = decoded['itemId'];
        if (itemId is! String || itemId.isEmpty) {
          throw const MusicControlProtocolException(
            'itemId must be a non-empty string',
          );
        }
        ok = await requests.remove(itemId);
      default:
        throw const MusicControlProtocolException('Unsupported command');
    }

    await _writeJson(request, HttpStatus.ok, {
      'protocolVersion': MusicControlProtocol.version,
      'serverId': serverId,
      'type': 'commandResult',
      'ok': ok,
      'snapshot': MusicControlProtocol.snapshotToJson(requests.current),
    });
  }

  Future<void> _handleWebSocket(HttpRequest request) async {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      await _writeError(
        request,
        HttpStatus.badRequest,
        'A WebSocket upgrade is required',
      );
      return;
    }

    final socket = await WebSocketTransformer.upgrade(request);
    socket.pingInterval = const Duration(seconds: 15);
    _sockets.add(socket);
    socket.add(
      jsonEncode(
        MusicControlProtocol.snapshotEnvelope(
          serverId: serverId,
          snapshot: requests.current,
        ),
      ),
    );
    socket.listen(
      (_) {},
      onDone: () => _sockets.remove(socket),
      onError: (_) => _sockets.remove(socket),
      cancelOnError: true,
    );
  }

  void _broadcastSnapshot(MusicQueueSnapshot snapshot) {
    if (_sockets.isEmpty) return;
    final message = jsonEncode(
      MusicControlProtocol.snapshotEnvelope(
        serverId: serverId,
        snapshot: snapshot,
      ),
    );
    final failed = <WebSocket>[];
    for (final socket in _sockets) {
      try {
        socket.add(message);
      } catch (_) {
        failed.add(socket);
      }
    }
    for (final socket in failed) {
      _sockets.remove(socket);
      unawaited(socket.close());
    }
  }

  Future<void> close() async {
    final server = _server;
    if (server == null) return;
    _server = null;

    await _stateSubscription?.cancel();
    _stateSubscription = null;
    final sockets = _sockets.toList(growable: false);
    _sockets.clear();
    await Future.wait(
      sockets.map(
        (socket) => socket.close(
          WebSocketStatus.goingAway,
          'Music control server stopped',
        ),
      ),
    );
    await server.close(force: true);
  }

  static bool _isTrustedLoopbackRequest(HttpRequest request) {
    final address = request.connectionInfo?.remoteAddress.address;
    if (address != '127.0.0.1' && address != '::1') return false;

    // Browser-originated localhost requests are rejected. Native controller
    // clients do not send Origin, which prevents drive-by web pages from
    // issuing playback commands without adding pairing friction.
    final origin = request.headers.value('origin');
    return origin == null || origin.isEmpty;
  }

  static Future<void> _writeJson(
    HttpRequest request,
    int statusCode,
    Object body,
  ) async {
    request.response
      ..statusCode = statusCode
      ..headers.contentType = ContentType.json
      ..headers.set('x-content-type-options', 'nosniff')
      ..write(jsonEncode(body));
    await request.response.close();
  }

  static Future<void> _writeError(
    HttpRequest request,
    int statusCode,
    String message,
  ) => _writeJson(request, statusCode, {'error': message});

  static String _createServerId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}
