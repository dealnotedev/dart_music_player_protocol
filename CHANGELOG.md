# Changelog

## 1.0.0

- Extract the shared player contract and native transport into an independent
  Dart package used by the OBS overlay and Twitch Listener.
- Provide queue snapshots, playback state, preparation progress, errors and
  pause, seek, skip and remove controls without Flutter dependencies.
- Preserve wire protocol v1, including additive preparation-phase details and
  compatibility with existing controllers.
- Include a loopback HTTP/WebSocket server, a reconnecting native client,
  protocol documentation, an executable example and standalone tests.
