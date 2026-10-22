import '../dart_music_player_protocol.dart';

/// Wire contract shared by the overlay server and remote controllers.
abstract final class MusicControlProtocol {
  static const int version = 1;
  static const int defaultPort = 47821;
  static const int listenerPort = 47822;

  static const String healthPath = '/v1/health';
  static const String playerPath = '/v1/player';
  static const String commandsPath = '/v1/player/commands';
  static const String eventsPath = '/v1/player/events';

  static Map<String, Object?> snapshotEnvelope({
    required String serverId,
    required MusicQueueSnapshot snapshot,
  }) => {
    'protocolVersion': version,
    'serverId': serverId,
    'type': 'snapshot',
    'snapshot': snapshotToJson(snapshot),
  };

  static MusicControlSnapshotEnvelope snapshotEnvelopeFromJson(Object? value) {
    final json = _object(value, 'envelope');
    final protocolVersion = _integer(
      json['protocolVersion'],
      'protocolVersion',
    );
    if (protocolVersion != version) {
      throw MusicControlVersionException(
        actual: protocolVersion,
        expected: version,
      );
    }
    if (json['type'] != 'snapshot') {
      throw const MusicControlProtocolException('Expected a snapshot message');
    }

    return MusicControlSnapshotEnvelope(
      serverId: _string(json['serverId'], 'serverId'),
      snapshot: snapshotFromJson(json['snapshot']),
    );
  }

  static Map<String, Object?> snapshotToJson(MusicQueueSnapshot snapshot) => {
    'revision': snapshot.revision,
    'volume': snapshot.volume,
    'nowPlaying':
        snapshot.nowPlaying == null
            ? null
            : _nowPlayingToJson(snapshot.nowPlaying!),
    'queue': snapshot.queue.map(_queueItemToJson).toList(growable: false),
    'lastError':
        snapshot.lastError == null ? null : _errorToJson(snapshot.lastError!),
    // Optional in v1: older controllers ignore it and show held requests as
    // resolving.
    if (snapshot.hold case final hold?) 'hold': hold.name,
  };

  static MusicQueueSnapshot snapshotFromJson(Object? value) {
    final json = _object(value, 'snapshot');
    final queueValue = json['queue'];
    if (queueValue is! List<Object?>) {
      throw const MusicControlProtocolException('queue must be a JSON array');
    }

    return MusicQueueSnapshot(
      revision: _integer(json['revision'], 'revision'),
      volume: _nullableDouble(json['volume'], 'volume') ?? 1,
      nowPlaying:
          json['nowPlaying'] == null
              ? null
              : _nowPlayingFromJson(json['nowPlaying']),
      queue: List.unmodifiable(queueValue.map(_queueItemFromJson)),
      lastError:
          json['lastError'] == null ? null : _errorFromJson(json['lastError']),
      hold:
          musicPreparationHoldReasons
              .where((reason) => reason.name == json['hold'])
              .firstOrNull,
    );
  }

  static Map<String, Object?> _nowPlayingToJson(MusicNowPlaying playing) => {
    'item': _queueItemToJson(playing.item),
    'startedAtMs': playing.startedAt.toUtc().millisecondsSinceEpoch,
    'positionMs': playing.position.inMilliseconds,
    'positionUpdatedAtMs':
        playing.positionUpdatedAt.toUtc().millisecondsSinceEpoch,
    'paused': playing.paused,
    'starting': playing.starting,
  };

  static MusicNowPlaying _nowPlayingFromJson(Object? value) {
    final json = _object(value, 'nowPlaying');
    return MusicNowPlaying(
      item: _queueItemFromJson(json['item']),
      startedAt:
          DateTime.fromMillisecondsSinceEpoch(
            _integer(json['startedAtMs'], 'startedAtMs'),
            isUtc: true,
          ).toLocal(),
      position: Duration(
        milliseconds: _integer(json['positionMs'], 'positionMs'),
      ),
      positionUpdatedAt:
          DateTime.fromMillisecondsSinceEpoch(
            _integer(json['positionUpdatedAtMs'], 'positionUpdatedAtMs'),
            isUtc: true,
          ).toLocal(),
      paused: _boolean(json['paused'], 'paused'),
      starting: json['starting'] == true,
    );
  }

  static Map<String, Object?> _queueItemToJson(MusicQueueItem item) => {
    'id': item.id,
    'requestedBy': item.requestedBy.isEmpty ? '—' : item.requestedBy,
    if (item.requestedBy.isEmpty) 'requesterAbsent': true,
    'sourceUrl': item.sourceUrl.toString(),
    // v1 readers only know resolving/downloading/ready. New phases are
    // additive detail, so independently updated clients keep working.
    'phase': switch (item.phase) {
      MusicQueueItemPhase.analyzing ||
      MusicQueueItemPhase.normalizing => 'downloading',
      _ => item.phase.name,
    },
    if (item.phase == MusicQueueItemPhase.analyzing ||
        item.phase == MusicQueueItemPhase.normalizing)
      'preparationPhase': item.phase.name,
    'title': item.title,
    'author': item.author,
    'durationMs': item.duration?.inMilliseconds,
    'thumbnail': item.thumbnail?.toString(),
    'downloadProgress': item.downloadProgress,
  };

  static MusicQueueItem _queueItemFromJson(Object? value) {
    final json = _object(value, 'queueItem');
    return MusicQueueItem(
      id: _string(json['id'], 'id'),
      requestedBy:
          json['requesterAbsent'] == true
              ? ''
              : _text(json['requestedBy'], 'requestedBy'),
      sourceUrl: _uri(json['sourceUrl'], 'sourceUrl'),
      phase:
          MusicQueueItemPhase.values
              .where((phase) => phase.name == json['preparationPhase'])
              .firstOrNull ??
          _enumValue(MusicQueueItemPhase.values, json['phase'], 'phase'),
      title: _nullableString(json['title'], 'title'),
      author: _nullableString(json['author'], 'author'),
      duration:
          json['durationMs'] == null
              ? null
              : Duration(
                milliseconds: _integer(json['durationMs'], 'durationMs'),
              ),
      thumbnail:
          json['thumbnail'] == null
              ? null
              : _uri(json['thumbnail'], 'thumbnail'),
      downloadProgress: _nullableDouble(
        json['downloadProgress'],
        'downloadProgress',
      ),
    );
  }

  static const _preparationReasons = {
    MusicQueueErrorType.youtubeAccessRequired,
    MusicQueueErrorType.youtubeDownloadBlocked,
    MusicQueueErrorType.youtubeRateLimited,
    MusicQueueErrorType.youtubeUnavailable,
    MusicQueueErrorType.networkUnavailable,
    MusicQueueErrorType.musicToolsUnavailable,
  };

  static Map<String, Object?> _errorToJson(MusicQueueError error) {
    final preparationFailure = _preparationReasons.contains(error.type);
    // Older v1 controllers know operationFailed. The optional reason lets new
    // controllers localize the recovery action without breaking those clients.
    return {
      'requester': error.requester.isEmpty ? '—' : error.requester,
      if (error.requester.isEmpty) 'requesterAbsent': true,
      'type': preparationFailure ? 'operationFailed' : error.type.name,
      if (preparationFailure) 'reason': error.type.name,
      'details':
          preparationFailure
              ? _legacyPreparationMessage(error.type)
              : error.details,
    };
  }

  static String _legacyPreparationMessage(
    MusicQueueErrorType type,
  ) => switch (type) {
    MusicQueueErrorType.youtubeAccessRequired =>
      'Music requests are paused: YouTube needs verification. Open OBS overlay '
          'Music settings and connect YouTube.',
    MusicQueueErrorType.youtubeDownloadBlocked =>
      'Music requests are paused: YouTube blocked the audio download (403). '
          'Open OBS overlay Music settings.',
    MusicQueueErrorType.youtubeRateLimited =>
      'Music requests are paused: YouTube temporarily limited requests. '
          'Resume them later in OBS overlay Music settings.',
    MusicQueueErrorType.youtubeUnavailable =>
      'This YouTube video is unavailable. Choose another.',
    MusicQueueErrorType.networkUnavailable =>
      'Check your internet connection and try again.',
    _ =>
      'Music components are unavailable. Reinstall the latest full application.',
  };

  static MusicQueueError _errorFromJson(Object? value) {
    final json = _object(value, 'lastError');
    final reason =
        MusicQueueErrorType.values
            .where(
              (type) =>
                  _preparationReasons.contains(type) &&
                  type.name == json['reason'],
            )
            .firstOrNull;
    return MusicQueueError(
      requester:
          json['requesterAbsent'] == true
              ? ''
              : _text(json['requester'], 'requester'),
      type:
          reason ??
          _enumValue(MusicQueueErrorType.values, json['type'], 'error.type'),
      details: _nullableString(json['details'], 'details'),
    );
  }

  static Map<String, dynamic> _object(Object? value, String field) {
    if (value is Map<String, dynamic>) return value;
    throw MusicControlProtocolException('$field must be a JSON object');
  }

  static String _string(Object? value, String field) {
    if (value is String && value.isNotEmpty) return value;
    throw MusicControlProtocolException('$field must be a non-empty string');
  }

  // A manual request has no Twitch requester. Identity fields still use
  // _string, but display text may legitimately be empty.
  static String _text(Object? value, String field) {
    if (value is String) return value;
    throw MusicControlProtocolException('$field must be a string');
  }

  static String? _nullableString(Object? value, String field) {
    if (value == null || value is String) return value as String?;
    throw MusicControlProtocolException('$field must be a string or null');
  }

  static int _integer(Object? value, String field) {
    if (value is int) return value;
    if (value is num && value.isFinite && value == value.roundToDouble()) {
      return value.round();
    }
    throw MusicControlProtocolException('$field must be an integer');
  }

  static double? _nullableDouble(Object? value, String field) {
    if (value == null) return null;
    if (value is num && value.isFinite) return value.toDouble();
    throw MusicControlProtocolException('$field must be a number or null');
  }

  static bool _boolean(Object? value, String field) {
    if (value is bool) return value;
    throw MusicControlProtocolException('$field must be a boolean');
  }

  static Uri _uri(Object? value, String field) {
    final text = _string(value, field);
    final uri = Uri.tryParse(text);
    if (uri == null || !uri.hasScheme) {
      throw MusicControlProtocolException('$field must be an absolute URI');
    }
    return uri;
  }

  static T _enumValue<T extends Enum>(
    List<T> values,
    Object? value,
    String field,
  ) {
    if (value is String) {
      for (final candidate in values) {
        if (candidate.name == value) return candidate;
      }
    }
    throw MusicControlProtocolException('$field has an unsupported value');
  }
}

class MusicControlSnapshotEnvelope {
  final String serverId;
  final MusicQueueSnapshot snapshot;

  const MusicControlSnapshotEnvelope({
    required this.serverId,
    required this.snapshot,
  });
}

class MusicControlProtocolException implements Exception {
  final String message;

  const MusicControlProtocolException(this.message);

  @override
  String toString() => message;
}

class MusicControlVersionException extends MusicControlProtocolException {
  final int actual;
  final int expected;

  MusicControlVersionException({required this.actual, required this.expected})
    : super('Unsupported protocol version $actual (expected $expected)');
}
