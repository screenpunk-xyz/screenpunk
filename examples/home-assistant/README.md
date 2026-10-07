# Home Assistant theater example

Generic HTTP + optional WebSocket dashboard. The device talks to the
operator’s Home Assistant origin with a user-entered long-lived access
credential stored in Keychain. The Mac is not a runtime proxy.

No generic OAuth, MQTT, or Screenpunk cloud. Prefer a dedicated HA user.

## Entities

The dashboard inspects `GET /api/states` and shows only lights, scenes,
and media players that exist in that payload. Unavailable / unknown
entities stay visible but disabled. Optional dashboard state key
`entities` can narrow the set:

```json
{
  "lights": ["light.theater"],
  "scenes": ["scene.movie"],
  "media": ["media_player.theater"]
}
```

Starter writes (user gesture only — never timed):

| Operation | Method | Path |
| --- | --- | --- |
| `getStates` | GET | `/api/states` |
| `lightOn` / `lightOff` | POST | `/api/services/light/turn_on` / `turn_off` |
| `sceneOn` | POST | `/api/services/scene/turn_on` |
| `mediaPlayPause` | POST | `/api/services/media_player/media_play_pause` |
| `volumeSet` | POST | `/api/services/media_player/volume_set` |
| `selectSource` | POST | `/api/services/media_player/select_source` |

Required HTTP `getStates` polls every 15 seconds. Optional `homeEvents` /
`subscribeStates` listens on `/api/websocket`. HA WebSocket auth stays in
the native adapter; page JavaScript never receives the credential.

CI uses `fixture/states.json` and `fixture/server.mjs`. Do not depend on
a live home or third-party uptime.

## Grants

| File | Use |
| --- | --- |
| `grants/fixture-http.json` | Loopback HTTP fixture |
| `grants/fixture-ws.json` | Loopback WS fixture |
| `grants/operator-http.json` | LAN `http://homeassistant.local:8123` (insecure HTTP explicitly approved) |
| `grants/operator-ws.json` | Same origin, WS transport |

Operator origin is configurable. TLS remains the default for non-LAN
grants. Self-signed HTTPS is not silently trusted.

## Brand

Codex guide tokens and danger treatment for action failures. Stacked v1
lockup. Landscape fixture-phone target. Native Offline overlay is
host-owned and follows required connection health only.

## Validate

```sh
node --test examples/home-assistant/test.mjs
./scripts/ci/linux.sh
```
