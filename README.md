# dart_music_player_protocol

Shared music player state, queue and control protocol with a native
HTTP/WebSocket client and server for Dart.

The package lets a presentation observe and control a player running in the
same process or in another application on the same computer. It is used by
the Flutter OBS overlay, its standalone music controller, and Twitch Listener.
It has no Flutter dependencies and does not own audio playback or downloading.

## Install

Add the Git dependency to your application's `pubspec.yaml`:

```yaml
dependencies:
  dart_music_player_protocol:
    git:
      url: https://github.com/dealnotedev/dart_music_player_protocol.git
      ref: v1.0.0
```

Run `dart pub get`, or `flutter pub get` for a Flutter application. A specific
commit SHA may be used instead of a tag. Commit application lockfiles so builds
on other computers resolve the same revision. No sibling checkout is required.
The compiled application does not need Git or GitHub access at runtime.

## Libraries

```dart
// Models and the player interface, suitable for local presentations.
import 'package:dart_music_player_protocol/dart_music_player_protocol.dart';

// Models plus the native client, server and JSON codec.
import 'package:dart_music_player_protocol/dart_music_player_protocol_io.dart';
```

| Interface | Responsibility |
| --- | --- |
| `MusicRequests` | Current snapshot, state stream and pause/seek/skip/remove controls |
| `MusicQueueSnapshot` | Playback, queue, preparation progress, volume and errors |
| `MusicControlProtocol` | Versioned JSON serialization and endpoint paths |
| `MusicControlServer` | Publish an existing player over loopback HTTP/WebSocket |
| `RemoteMusicRequests` | Connect to a host through the same player interface |

A host implements `MusicRequests` using its own queue and audio backend. A view
depends on that interface and can receive either the local implementation or
`RemoteMusicRequests`. Playback engines, Twitch events and point refunds,
downloading, normalization, persistent settings, and widgets stay in the host
applications.

## Host an existing player

```dart
final server = MusicControlServer(
  requests: player, // Your MusicRequests implementation.
  requestedPort: MusicControlProtocol.listenerPort,
);
await server.start();

// On host shutdown:
await server.close();
```

The default OBS player port is **47821**; Twitch Listener uses **47822**. A test
can request port `0` and read the actual bound port from `server.port`.
Closing the server leaves the hosted player running. Its owner closes the
player separately.

## Connect a presentation

```dart
final player = RemoteMusicRequests(
  endpoint: Uri.parse('http://127.0.0.1:47822'),
);
final subscription = player.states.listen(renderSnapshot);
player.start();

// Controls return false if unavailable or rejected.
await player.setPaused(true);
await player.seek(const Duration(seconds: 30));

// On presentation shutdown:
await subscription.cancel();
await player.close();
```

The client exposes `currentConnection` and `connectionStates`, reconnects with
backoff, and clears stale playback state when disconnected. Commands are not
automatically retried. Closing a client never closes the remote player.

`current` is available synchronously. Views should read it before subscribing
to `states`; implementations may also replay their current state. The object
owner manages `close()`, independently of any observing widget.

## Transport and compatibility

The server binds to **127.0.0.1** and accepts native clients without a browser
`Origin` header. It serves a complete initial snapshot over HTTP and a complete
snapshot on WebSocket connection, followed by updates. Controls use HTTP POST.
Audio stays in the host application and is captured separately by OBS.

Package releases and the wire `protocolVersion` are independent. The initial
release uses **wire version 1**, including additive fields understood by newer
clients and compatible fallback values for existing v1 controllers. An
incompatible major version produces an explicit connection state.

See [the protocol specification](doc/protocol.md) for routes, JSON fields,
ordering rules, defaults and compatibility requirements. Cross-computer
connections and browser clients require a separate transport policy; publishing
this Git dependency does not enable either.

## Develop and test

Requires Dart **3.7.0 or later**. Flutter is not required.

```sh
dart pub get
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
dart test
dart run example/dart_music_player_protocol_example.dart
```

CI runs analysis and tests on stable Dart for Linux and Windows, plus the minimum
supported SDK on Linux. Formatting is checked with stable Dart.

To test a local package change from an application, create an untracked
`pubspec_overrides.yaml` next to its `pubspec.yaml`:

```yaml
dependency_overrides:
  dart_music_player_protocol:
    path: ../dart_music_player_protocol
```

Adjust the path for nested applications. Remove the override and run `pub get`
before committing an application's lockfile for a Git-based release.

## Release

Run the checks, commit the package and tag the release, for example `v1.0.0`.
Pin each consuming application to the tested tag or commit and update its
lockfile. A package fix does not require a wire-version change; change the wire
major only when existing clients cannot safely interpret the new contract.
