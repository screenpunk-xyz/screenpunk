#!/usr/bin/env node
/**
 * Generic local HTTP fixture. No credentials. Deterministic JSON only.
 */
import { createServer } from "node:http";

const port = Number(process.env.SCREENPUNK_FIXTURE_PORT ?? 0);

export function createFixtureServer() {
  return createServer((req, res) => {
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
    json(res, 404, { error: "not_found" });
  });
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
