#!/usr/bin/env node
/**
 * Generic local HTTP/WebSocket fixture. No credentials. Deterministic JSON only.
 */
import { createHash } from "node:crypto";
import { createServer } from "node:http";

const port = Number(process.env.SCREENPUNK_FIXTURE_PORT ?? 0);
const requiredToken = process.env.SCREENPUNK_FIXTURE_TOKEN ?? "";
const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const WS_MAX_BYTES = 256 * 1024;

function authorized(req) {
  if (!requiredToken) return true;
  return req.headers.authorization === `Bearer ${requiredToken}`;
}

export function createFixtureServer() {
  const server = createServer((req, res) => {
    if (!authorized(req)) {
      json(res, 401, { error: "unauthorized" });
      return;
    }
    const url = new URL(req.url ?? "/", "http://127.0.0.1");
    if (req.method === "GET" && url.pathname === "/health") {
      json(res, 200, { ok: true, stale: false });
      return;
    }
    if (req.method === "GET" && url.pathname === "/v1/status") {
      json(res, 200, { fixture: "SCREENPUNK_HTTP_FIXTURE_V1", temperatureC: 21 });
      return;
    }
    if (req.method === "POST" && url.pathname === "/v1/write") {
      json(res, 200, { accepted: true, write: true });
      return;
    }
    if (req.method === "GET" && url.pathname === "/v1/redirect") {
      res.writeHead(302, { location: "/v1/status", "cache-control": "no-store" });
      res.end();
      return;
    }
    if (req.method === "GET" && url.pathname === "/v1/blob") {
      const bytes = Math.min(Number(url.searchParams.get("bytes") ?? 1024), 3 * 1024 * 1024);
      json(res, 200, { fixture: "SCREENPUNK_HTTP_FIXTURE_V1", blob: "x".repeat(Math.max(0, bytes)) });
      return;
    }
    if (req.method === "GET" && url.pathname === "/v1/events") {
      res.writeHead(426, {
        "content-type": "application/json",
        upgrade: "websocket",
        "cache-control": "no-store"
      });
      res.end(JSON.stringify({ error: "upgrade_required" }));
      return;
    }
    json(res, 404, { error: "not_found" });
  });

  server.on("upgrade", (req, socket) => {
    if (!authorized(req)) {
      socket.write("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n");
      socket.destroy();
      return;
    }
    const url = new URL(req.url ?? "/", "http://127.0.0.1");
    if (url.pathname !== "/v1/events") {
      socket.write("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n");
      socket.destroy();
      return;
    }
    const key = req.headers["sec-websocket-key"];
    if (typeof key !== "string" || req.headers.upgrade?.toLowerCase() !== "websocket") {
      socket.write("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n");
      socket.destroy();
      return;
    }
    const accept = createHash("sha1").update(key + WS_GUID).digest("base64");
    socket.write(
      "HTTP/1.1 101 Switching Protocols\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: Upgrade\r\n" +
        `Sec-WebSocket-Accept: ${accept}\r\n\r\n`
    );
    attachWebSocket(socket);
  });

  return server;
}

function attachWebSocket(socket) {
  let buffer = Buffer.alloc(0);
  let closing = false;
  const close = (code) => {
    if (closing) return;
    closing = true;
    socket.write(encodeClose(code));
    socket.end();
  };
  socket.on("error", () => {});
  socket.write(
    encodeText(
      JSON.stringify({
        fixture: "SCREENPUNK_WS_FIXTURE_V1",
        event: "hello",
        stale: false
      })
    )
  );
  socket.on("data", (chunk) => {
    if (closing) return;
    buffer = Buffer.concat([buffer, chunk]);
    try {
      while (buffer.length > 0) {
        const parsed = decodeFrame(buffer);
        if (!parsed) break;
        buffer = parsed.rest;
        if (parsed.opcode === 0x8) {
          close(1000);
          return;
        }
        if (parsed.opcode === 0x9) {
          socket.write(encodeFrame(0xa, parsed.payload));
          continue;
        }
        if (parsed.opcode === 0x1) {
          if (parsed.payload.length > WS_MAX_BYTES) {
            close(1009);
            return;
          }
          socket.write(
            encodeText(
              JSON.stringify({
                fixture: "SCREENPUNK_WS_FIXTURE_V1",
                received: true,
                echo: false
              })
            )
          );
        }
      }
    } catch {
      close(1002);
    }
  });
}

function decodeFrame(buffer) {
  if (buffer.length < 2) return null;
  const opcode = buffer[0] & 0x0f;
  const masked = (buffer[1] & 0x80) !== 0;
  let len = buffer[1] & 0x7f;
  let offset = 2;
  if (len === 126) {
    if (buffer.length < 4) return null;
    len = buffer.readUInt16BE(2);
    offset = 4;
  } else if (len === 127) {
    if (buffer.length < 10) return null;
    const high = buffer.readUInt32BE(2);
    const low = buffer.readUInt32BE(6);
    if (high !== 0 || low > WS_MAX_BYTES + 64) {
      throw new Error("too_large");
    }
    len = low;
    offset = 10;
  }
  const maskSize = masked ? 4 : 0;
  if (buffer.length < offset + maskSize + len) return null;
  let payload = buffer.subarray(offset + maskSize, offset + maskSize + len);
  if (masked) {
    const mask = buffer.subarray(offset, offset + 4);
    payload = Buffer.from(payload);
    for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i % 4];
  }
  return { opcode, payload, rest: buffer.subarray(offset + maskSize + len) };
}

function encodeText(text) {
  return encodeFrame(0x1, Buffer.from(text, "utf8"));
}

function encodeClose(code) {
  const payload = Buffer.alloc(2);
  payload.writeUInt16BE(code);
  return encodeFrame(0x8, payload);
}

function encodeFrame(opcode, payload) {
  const len = payload.length;
  let header;
  if (len < 126) {
    header = Buffer.from([0x80 | opcode, len]);
  } else if (len < 65536) {
    header = Buffer.alloc(4);
    header[0] = 0x80 | opcode;
    header[1] = 126;
    header.writeUInt16BE(len, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x80 | opcode;
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(len), 2);
  }
  return Buffer.concat([header, payload]);
}

function json(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": "application/json",
    "cache-control": "no-store"
  });
  res.end(payload);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const server = createFixtureServer();
  server.listen(port, "127.0.0.1", () => {
    const address = server.address();
    process.stdout.write(`fixture-server ${address.port}\n`);
  });
}
