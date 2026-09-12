#!/usr/bin/env node
import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const forecast = JSON.parse(
  readFileSync(join(dirname(fileURLToPath(import.meta.url)), "forecast.json"), "utf8")
);

export function createWeatherFixtureServer() {
  return createServer((req, res) => {
    const url = new URL(req.url ?? "/", "http://127.0.0.1");
    if (req.method === "GET" && url.pathname === "/v1/forecast") {
      const body = JSON.stringify(forecast);
      res.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" });
      res.end(body);
      return;
    }
    res.writeHead(404, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: "not_found" }));
  });
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const server = createWeatherFixtureServer();
  server.listen(Number(process.env.SCREENPUNK_WEATHER_FIXTURE_PORT ?? 0), "127.0.0.1", () => {
    process.stdout.write(`weather-fixture ${server.address().port}\n`);
  });
}
