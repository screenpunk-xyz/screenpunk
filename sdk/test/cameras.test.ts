import assert from "node:assert/strict";
import { test } from "node:test";
import { createDashboardClient } from "../src/client.ts";
import type { BridgeMessage } from "../src/bridge.ts";

test("camera mounting sends scoped IDs and geometry; disposal stops native playback", async () => {
  const sent: BridgeMessage[] = [];
  let listener: (m: BridgeMessage) => void = () => {};
  const root = globalThis as any;
  const keys = ["document", "innerWidth", "innerHeight", "getComputedStyle"];
  const previous = keys.map(k => Object.getOwnPropertyDescriptor(root, k));
  root.document = { hidden: false, addEventListener() {}, removeEventListener() {} };
  root.innerWidth = 1000; root.innerHeight = 800;
  root.getComputedStyle = () => ({visibility: "visible"});
  const client = createDashboardClient({transport: {
    onMessage(fn) { listener = fn; return () => {}; },
    send(message) {
      sent.push(message);
      queueMicrotask(() => listener({protocolVersion: 1, id: message.id, kind: "response", value: {state: "loading"}}));
    }
  }});
  try {
    const element = {isConnected: true, getBoundingClientRect: () => ({x: 10, y: 10, width: 320, height: 180, right: 330, bottom: 190})} as HTMLElement;
    const status: unknown[] = [];
    client.cameras.mount(element, {kind: "homeAssistant", connection: "home", entityId: "camera.deck"}, s => status.push(s), {controls: "gallery", label: "Deck", order: 0});
    await new Promise(resolve => setTimeout(resolve, 10));
    assert.equal(sent[0].operation, "cameraPresent");
    assert.deepEqual(JSON.parse(sent[0].parameters!.source as string), {kind: "homeAssistant", connection: "home", entityId: "camera.deck"});
    assert.equal(sent[0].parameters!.controls, "gallery");
    assert.equal(sent[0].parameters!.label, "Deck");
    assert.equal(sent[0].parameters!.order, "0");
    assert.deepEqual(status, [{state: "loading"}]);
    assert.throws(() => client.cameras.mount(element, {kind: "homeAssistant", connection: "home", entityId: "camera.*"}));
    client.dispose();
    assert.equal(sent.at(-1)?.operation, "cameraClose");
  } finally {
    client.dispose();
    keys.forEach((k,i) => { if (previous[i]) Object.defineProperty(root,k,previous[i]!); else delete root[k]; });
  }
});
