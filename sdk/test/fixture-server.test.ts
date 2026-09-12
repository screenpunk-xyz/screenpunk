import assert from "node:assert/strict";
import { test } from "node:test";
import { createFixtureServer } from "../../tools/fixture-server/server.mjs";

test("HTTP fixture server returns deterministic JSON and no credentials", async () => {
  const server = createFixtureServer();
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as { port: number };
  try {
    const status = await fetch(`http://127.0.0.1:${port}/v1/status`).then((r) => r.json());
    assert.equal(status.fixture, "SCREENPUNK_HTTP_FIXTURE_V1");
    assert.equal(status.temperatureC, 21);
    const blob = JSON.stringify(status);
    assert.equal(/token|password|bearer/i.test(blob), false);
    const missing = await fetch(`http://127.0.0.1:${port}/nope`);
    assert.equal(missing.status, 404);
  } finally {
    await new Promise<void>((resolve, reject) =>
      server.close((err) => (err ? reject(err) : resolve()))
    );
  }
});
