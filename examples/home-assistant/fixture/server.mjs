#!/usr/bin/env node
import { createHash } from "node:crypto";
import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const initial = JSON.parse(
  readFileSync(join(dirname(fileURLToPath(import.meta.url)), "states.json"), "utf8")
);

function cloneStates() {
  return JSON.parse(JSON.stringify(initial));
}

export function createHomeAssistantFixtureServer() {
  let states = cloneStates();
  const server = createServer((req, res) => {
    const url = new URL(req.url ?? "/", "http://127.0.0.1");
    if (req.method === "GET" && url.pathname === "/api/states") {
      json(res, 200, states);
      return;
    }
    if (req.method === "POST" && url.pathname.startsWith("/api/services/")) {
      collect(req).then((body) => {
        const parts = url.pathname.split("/");
        const domain = parts[3] ?? "";
        const service = parts[4] ?? "";
        applyService(states, domain, service, body);
        json(res, 200, []);
      });
      return;
    }
    json(res, 404, { error: "not_found" });
  });

  server.on("upgrade", (req, socket) => {
    const url = new URL(req.url ?? "/", "http://127.0.0.1");
    if (url.pathname !== "/api/websocket") {
      socket.write("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n");
      socket.destroy();
      return;
    }
    const key = req.headers["sec-websocket-key"];
    if (typeof key !== "string") {
      socket.destroy();
      return;
    }
    const accept = createHash("sha1").update(key + WS_GUID).digest("base64");
    socket.write(
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
        `Sec-WebSocket-Accept: ${accept}\r\n\r\n`
    );
    const theater = states.find((item) => item.entity_id === "light.theater") ?? states[0];
    socket.write(
      encodeText(
        JSON.stringify({
          type: "event",
          event: {
            event_type: "state_changed",
            data: { entity_id: theater.entity_id, new_state: theater }
          }
        })
      )
    );
  });

  return server;
}

function applyService(states, domain, service, body) {
  const entityId = body.entity_id;
  const entity = states.find((item) => item.entity_id === entityId);
  if (!entity) return;
  if (domain === "light" && service === "turn_on") entity.state = "on";
  if (domain === "light" && service === "turn_off") entity.state = "off";
  if (domain === "media_player" && service === "media_play_pause") {
    entity.state = entity.state === "playing" ? "paused" : "playing";
  }
  if (domain === "media_player" && service === "volume_set" && body.volume_level != null) {
    entity.attributes.volume_level = Number(body.volume_level);
  }
  if (domain === "media_player" && service === "select_source" && body.source) {
    entity.attributes.source = String(body.source);
  }
}

function collect(req) {
  return new Promise((resolve) => {
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => {
      const raw = Buffer.concat(chunks).toString("utf8") || "{}";
      try {
        resolve(JSON.parse(raw));
      } catch {
        resolve({});
      }
    });
  });
}

function json(res, status, body) {
  res.writeHead(status, { "content-type": "application/json", "cache-control": "no-store" });
  res.end(JSON.stringify(body));
}

function encodeText(text) {
  const payload = Buffer.from(text, "utf8");
  let header;
  if (payload.length < 126) {
    header = Buffer.from([0x81, payload.length]);
  } else {
    header = Buffer.alloc(4);
    header[0] = 0x81;
    header[1] = 126;
    header.writeUInt16BE(payload.length, 2);
  }
  return Buffer.concat([header, payload]);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const server = createHomeAssistantFixtureServer();
  server.listen(Number(process.env.SCREENPUNK_HA_FIXTURE_PORT ?? 0), "127.0.0.1", () => {
    process.stdout.write(`ha-fixture ${server.address().port}\n`);
  });
}
