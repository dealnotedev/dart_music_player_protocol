# Music player protocol v1

This document describes the wire format implemented by
`MusicControlProtocol`, `MusicControlServer` and `RemoteMusicRequests`.
The server uses native loopback HTTP and WebSocket on one computer. The
protocol carries playback state and controls; audio playback stays in the host.

## Routes

| Method | Path | Result |
| --- | --- | --- |
| GET | `/v1/health` | Protocol version, server identity and status |
| GET | `/v1/player` | Complete snapshot envelope |
| GET | `/v1/player/events` | WebSocket sending complete snapshot envelopes |
| POST | `/v1/player/commands` | Apply one control and return the resulting snapshot |

The server binds to IPv4 loopback and rejects requests from other addresses or
with a nonempty browser `Origin`. These restrictions are intentional. A future
LAN or browser implementation must define its own authentication and origin
policy before exposing playback controls.

## Health

```json
{
  "protocolVersion": 1,
  "serverId": "example-server-id",
  "status": "ok"
}
```

`serverId` is a nonempty identity for a server instance. A new server instance
generates a new identity; stopping and restarting the same object retains it.

## Snapshot envelope

HTTP and WebSocket use the same envelope:

```json
{
  "protocolVersion": 1,
  "serverId": "example-server-id",
  "type": "snapshot",
  "snapshot": {
    "revision": 42,
    "volume": 0.7,
    "nowPlaying": null,
    "queue": [],
    "lastError": null
  }
}
```

| Snapshot field | Type | Meaning |
| --- | --- | --- |
| `revision` | integer | Increasing state revision within a server identity |
| `volume` | number, optional | Host volume, normally 0 to 1; defaults to 1 |
| `nowPlaying` | object or null | Current track and playback position |
| `queue` | array | Pending tracks in playback order |
| `lastError` | object or null | Host-reported request or playback error |
| `hold` | string, optional | Host-wide preparation hold reason |

The host remains authoritative for ordering, preparation, playback and controls.
Clients ignore revisions older than the last accepted revision for the same
server. A different `serverId` may restart its revision at zero. After a
disconnect, clients clear the visible snapshot and accept a complete snapshot
with the same revision on reconnect. Equal revisions may also be received in a
command response and a WebSocket update.

## Queue item

```json
{
  "id": "request-123",
  "requestedBy": "viewer",
  "sourceUrl": "https://www.youtube.com/watch?v=aaaaaaaaaaa",
  "phase": "downloading",
  "preparationPhase": "normalizing",
  "title": "Example track",
  "author": "Example artist",
  "durationMs": 180000,
  "thumbnail": null,
  "downloadProgress": 0.5
}
```

`id` is a nonempty stable identifier. `sourceUrl` and nonnull `thumbnail` must
be absolute URIs. `title`, `author`, `durationMs`, `thumbnail` and
`downloadProgress` can be null while metadata or preparation is unavailable.
Duration and position values are integer milliseconds. Progress is normally
between 0 and 1.

The legacy `phase` values are `resolving`, `downloading` and `ready`. Analysis
and normalization use `phase: downloading` plus an optional
`preparationPhase: analyzing` or `preparationPhase: normalizing`. New clients
restore the detailed phase; old clients retain a meaningful fallback. Unknown
optional preparation details fall back to `phase`. Unknown core phase values
are rejected.

The Dart model calls the progress field `preparationProgress`, with
`downloadProgress` retained as a constructor/getter alias. The wire field stays
`downloadProgress` for v1 compatibility.

For a manual request with no requester, the encoder sends a nonempty display
placeholder and `requesterAbsent: true`. New readers restore the empty name;
older readers display the placeholder. Readers also accept an empty requester
string from other compatible hosts. Request identity must still be nonempty.

## Now playing

```json
{
  "item": {
    "id": "request-123",
    "requestedBy": "viewer",
    "sourceUrl": "https://www.youtube.com/watch?v=aaaaaaaaaaa",
    "phase": "ready",
    "title": "Example track",
    "author": "Example artist",
    "durationMs": 180000,
    "thumbnail": null,
    "downloadProgress": 1.0
  },
  "startedAtMs": 1792700000000,
  "positionMs": 12000,
  "positionUpdatedAtMs": 1792700012000,
  "paused": false,
  "starting": false
}
```

Timestamps are UTC Unix epoch milliseconds. `positionMs` is the position at
`positionUpdatedAtMs`. Presentations can extrapolate elapsed time while playing
and clamp it to the track duration. `starting` is optional and defaults to false;
starting or paused playback must not advance visually. Presentation animations
must not become a prerequisite for starting audio.

Hosts and clients currently share the same computer clock. Clock-skew and
cross-computer position synchronization are outside this transport's scope.

## Errors and preparation holds

An error contains `requester`, `type`, optional `reason` and nullable `details`.
It uses the same optional `requesterAbsent` marker as queue items.

Legacy error types are `missingYoutubeUrl`, `invalidYoutubeUrl`, `queueFull`,
`trackTooLongOrLive` and `operationFailed`. Preparation failures use
`type: operationFailed` plus one of these optional `reason` values:

- `youtubeAccessRequired`
- `youtubeDownloadBlocked`
- `youtubeRateLimited`
- `youtubeUnavailable`
- `networkUnavailable`
- `musicToolsUnavailable`

The first three reasons can also appear in snapshot `hold`, indicating that
pending preparation waits for recovery. Unknown hold values are ignored. A hold
does not mean that already prepared audio has stopped.

Hosts must sanitize diagnostic text before exposing `details`. The protocol
does not include downloaded audio, local file paths or credentials as dedicated
fields. Backend diagnostics can still contain sensitive data if a host places
them in free-form text.

## Controls

Every command includes `protocolVersion: 1` and `command`:

```json
{"protocolVersion": 1, "command": "setPaused", "paused": true}
```

```json
{"protocolVersion": 1, "command": "seek", "positionMs": 30000}
```

```json
{"protocolVersion": 1, "command": "skip"}
```

```json
{"protocolVersion": 1, "command": "remove", "itemId": "request-123"}
```

`paused` must be a boolean, `positionMs` a nonnegative integer and `itemId` a
nonempty string. The host decides whether a valid command can be applied.
For example, skipping an idle player can return `ok: false`.

A successful HTTP exchange returns:

```json
{
  "protocolVersion": 1,
  "serverId": "example-server-id",
  "type": "commandResult",
  "ok": true,
  "snapshot": {
    "revision": 43,
    "volume": 0.7,
    "nowPlaying": null,
    "queue": [],
    "lastError": null
  }
}
```

Invalid commands or missing/mismatched versions return HTTP 400 with an `error`
message. Rejected origins return 403; unknown routes return 404. Controls are
unavailable while disconnected. Commands are never automatically retried:
the host might have applied a command before a response was lost.

## Connection lifecycle

The client first retrieves `/v1/player`, then connects to the WebSocket. The
server immediately sends a fresh full snapshot, covering changes between the
HTTP response and WebSocket connection. Later changes send complete snapshots.

The connection phases are `disconnected`, `connecting`, `connected`,
`reconnecting`, `incompatible` and `closed`. Reconnect delays default to 500 ms,
1 s, 2 s, 4 s and then 5 s. Native WebSocket ping intervals are 15 seconds.
Stopping a server or client does not stop or close the hosted player.

## Version policy

Wire major `1` is independent of package version `1.0.0`. Additive optional
fields with defaults and meaningful legacy fallback values retain the wire
major. New required fields, changed control semantics or incompatible core enum
values require a new major and route version. Major negotiation is not
implemented: mismatched snapshot versions produce `incompatible` instead of an
endless reconnect loop. Test compatibility before tagging any package release.
