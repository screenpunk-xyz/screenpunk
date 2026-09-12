import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import {
  PAIRING_EXPIRY_SECONDS,
  PAIRING_MAX_FAILURES,
  PAIRING_SAS_INFO,
  PairingError,
  beginPairing,
  confirmPairing,
  emptyPairingState,
  hexToBytes,
  matchingCode,
  repeatingKey,
  type PairingTranscript
} from "../src/pairing.ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "../..");
const vectors = JSON.parse(
  readFileSync(join(root, "tests/feasibility/pairing/vectors.json"), "utf8")
) as {
  info: string;
  expirySeconds: number;
  maxFailedAttempts: number;
  devicePublicKey: string;
  sessionNonce: string;
  cases: Array<{
    id: string;
    controllerPublicKey: string;
    macHex: string;
    code: string;
    expect?: string;
  }>;
};

function transcriptFor(controllerHex: string): PairingTranscript {
  return {
    devicePublicKey: hexToBytes(vectors.devicePublicKey),
    controllerPublicKey: hexToBytes(controllerHex),
    sessionNonce: hexToBytes(vectors.sessionNonce)
  };
}

test("published SAS vectors use HMAC-SHA256 and contain no credentials", () => {
  assert.equal(vectors.info, PAIRING_SAS_INFO);
  assert.equal(vectors.expirySeconds, PAIRING_EXPIRY_SECONDS);
  assert.equal(vectors.maxFailedAttempts, PAIRING_MAX_FAILURES);
  const blob = JSON.stringify(vectors);
  assert.equal(blob.includes("sk-"), false);
  assert.equal(/Bearer\s/i.test(blob), false);
  assert.equal(/password/i.test(blob), false);
});

test("honest pairing codes match; MITM and key-change codes differ", () => {
  const honest = vectors.cases.find((c) => c.id === "honest");
  assert.ok(honest);
  for (const c of vectors.cases) {
    const code = matchingCode(transcriptFor(c.controllerPublicKey));
    assert.equal(code, c.code, c.id);
    if (c.expect === "codes-differ-from-honest") {
      assert.notEqual(code, honest.code, c.id);
    }
  }
});

test("expiry, rate limit, second owner, and identity change", () => {
  const honest = vectors.cases.find((c) => c.id === "honest");
  const mitm = vectors.cases.find((c) => c.id === "mitm-substituted-controller");
  assert.ok(honest && mitm);
  const owner = { role: "controller" as const, publicKey: hexToBytes(honest.controllerPublicKey) };
  const attacker = { role: "controller" as const, publicKey: hexToBytes(mitm.controllerPublicKey) };
  const t0 = 1_700_000_000_000;

  let state = beginPairing(emptyPairingState(), transcriptFor(honest.controllerPublicKey), owner, t0);
  assert.throws(
    () => confirmPairing(state, honest.code, owner, t0 + (PAIRING_EXPIRY_SECONDS + 1) * 1000),
    (err: unknown) => err instanceof PairingError && err.failure === "expired"
  );

  state = beginPairing(emptyPairingState(), transcriptFor(honest.controllerPublicKey), owner, t0);
  for (let i = 0; i < 4; i += 1) {
    assert.throws(
      () => confirmPairing(state, "000000", owner, t0),
      (err: unknown) => err instanceof PairingError && err.failure === "codeMismatch"
    );
  }
  assert.throws(
    () => confirmPairing(state, "000000", owner, t0),
    (err: unknown) => err instanceof PairingError && err.failure === "rateLimited"
  );
  assert.equal(state.owner, null);

  state = beginPairing(emptyPairingState(), transcriptFor(honest.controllerPublicKey), owner, t0);
  state = confirmPairing(state, honest.code, owner, t0);
  assert.deepEqual(state.owner?.publicKey, owner.publicKey);
  assert.throws(
    () => beginPairing(state, transcriptFor(mitm.controllerPublicKey), attacker, t0),
    (err: unknown) => err instanceof PairingError && err.failure === "secondOwner"
  );

  state = beginPairing(emptyPairingState(), transcriptFor(honest.controllerPublicKey), owner, t0);
  assert.throws(
    () => confirmPairing(state, honest.code, attacker, t0),
    (err: unknown) => err instanceof PairingError && err.failure === "identityChanged"
  );
  assert.ok(repeatingKey(1).length === 32);
});
