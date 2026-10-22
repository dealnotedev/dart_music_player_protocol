import 'models.dart';

/// A local player or a remote connection. Its owner, never a view, closes it.
abstract interface class MusicRequests {
  MusicQueueSnapshot get current;

  Stream<MusicQueueSnapshot> get states;

  Future<bool> setPaused(bool paused);

  Future<bool> seek(Duration position);

  Future<bool> skip();

  Future<bool> remove(String itemId);

  Future<void> close();
}
