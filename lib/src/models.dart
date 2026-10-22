enum MusicQueueItemPhase {
  resolving,
  downloading,
  analyzing,
  normalizing,
  ready,
}

enum MusicQueueErrorType {
  missingYoutubeUrl,
  invalidYoutubeUrl,
  queueFull,
  trackTooLongOrLive,
  youtubeAccessRequired,
  youtubeDownloadBlocked,
  youtubeRateLimited,
  youtubeUnavailable,
  networkUnavailable,
  musicToolsUnavailable,
  operationFailed,
}

/// YouTube-wide blocks. Every following request would fail the same way, so
/// preparation pauses instead of refunding the queue one request at a time.
const musicPreparationHoldReasons = {
  MusicQueueErrorType.youtubeAccessRequired,
  MusicQueueErrorType.youtubeDownloadBlocked,
  MusicQueueErrorType.youtubeRateLimited,
};

/// A preparation failure with a stable, localizable reason for the UI.
class MusicTrackException implements Exception {
  final String message;
  final MusicQueueErrorType errorType;

  const MusicTrackException(
    this.message, {
    this.errorType = MusicQueueErrorType.operationFailed,
  });

  @override
  String toString() => message;
}

class MusicQueueError {
  final String requester;
  final MusicQueueErrorType type;
  final String? details;

  const MusicQueueError({
    required this.requester,
    required this.type,
    this.details,
  });

  String get signature => '$requester|$type|${details ?? ''}';
}

class MusicTrackMetadata {
  final String videoId;
  final String title;
  final String author;
  final Duration duration;
  final Uri? thumbnail;
  final Uri sourceUrl;

  const MusicTrackMetadata({
    required this.videoId,
    required this.title,
    required this.author,
    required this.duration,
    required this.thumbnail,
    required this.sourceUrl,
  });
}

class DownloadedMusicTrack {
  final String itemId;
  final String requestedBy;
  final MusicTrackMetadata metadata;
  final String filePath;

  const DownloadedMusicTrack({
    required this.itemId,
    required this.requestedBy,
    required this.metadata,
    required this.filePath,
  });
}

class MusicQueueItem {
  final String id;
  final String requestedBy;
  final Uri sourceUrl;
  final MusicQueueItemPhase phase;
  final String? title;
  final String? author;
  final Duration? duration;
  final Uri? thumbnail;
  final double? preparationProgress;

  /// Legacy name retained for existing callers.
  double? get downloadProgress => preparationProgress;

  const MusicQueueItem({
    required this.id,
    required this.requestedBy,
    required this.sourceUrl,
    required this.phase,
    required this.title,
    required this.author,
    required this.duration,
    required this.thumbnail,
    double? downloadProgress,
    double? preparationProgress,
  }) : preparationProgress = preparationProgress ?? downloadProgress;
}

class MusicNowPlaying {
  final MusicQueueItem item;
  final DateTime startedAt;
  final Duration position;
  final DateTime positionUpdatedAt;
  final bool paused;
  final bool starting;

  const MusicNowPlaying({
    required this.item,
    required this.startedAt,
    required this.position,
    required this.positionUpdatedAt,
    required this.paused,
    this.starting = false,
  });
}

class MusicQueueSnapshot {
  final int revision;
  final double volume;
  final MusicNowPlaying? nowPlaying;
  final List<MusicQueueItem> queue;
  final MusicQueueError? lastError;

  /// Why track preparation is paused; queued requests wait instead of failing.
  final MusicQueueErrorType? hold;

  const MusicQueueSnapshot({
    required this.revision,
    required this.nowPlaying,
    required this.queue,
    required this.lastError,
    this.volume = 1,
    this.hold,
  });

  static const empty = MusicQueueSnapshot(
    revision: 0,
    nowPlaying: null,
    queue: [],
    lastError: null,
  );
}
