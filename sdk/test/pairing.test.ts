import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { createHmac } from "node:crypto";
import {
  PAIRING_EXPIRY_SECONDS,
  PAIRING_MAX_FAILURES,
  PAIRING_SAS_INFO,
  PairingError,
  beginPairing,
  bytesToHex,
  canonicalTranscript,
  confirmPairing,
  emptyPairingState,
  hexToBytes,
  matchingCode,
  repeatingKey,
  type DevicePairingState,
  type PairingFailure,
  type PairingIdentity,
  type PairingTranscript
} from "../src/pairing.ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "../..");

interface ScenarioStep {
  op: "begin" | "confirm";
  case?: string;
  candidate?: string;
  code?: string;
  presented?: string;
  atSeconds: number;
  expect: "ok" | PairingFailure;
}

interface Scenario {
  id: string;
  steps: ScenarioStep[];
  finalOwner: string | null;
}

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
  identities: Record<string, { role: "device" | "controller"; publicKey: string }>;
  scenarios: Scenario[];
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
    const transcript = transcriptFor(c.controllerPublicKey);
    const code = matchingCode(transcript);
    assert.equal(code, c.code, c.id);
    const mac = createHmac("sha256", PAIRING_SAS_INFO).update(canonicalTranscript(transcript)).digest("hex");
    assert.equal(mac, c.macHex, `${c.id} full MAC`);
    if (c.expect === "codes-differ-from-honest") {
      assert.notEqual(code, honest.code, c.id);
    }
  }
});

function identityNamed(name: string): PairingIdentity {
  const entry = vectors.identities[name];
  assert.ok(entry, `unknown identity ${name}`);
  return { role: entry.role, publicKey: hexToBytes(entry.publicKey) };
}

function caseNamed(id: string) {
  const entry = vectors.cases.find((c) => c.id === id);
  assert.ok(entry, `unknown case ${id}`);
  return entry;
}

function resolveCode(spec: string): string {
  return spec.startsWith("case:") ? caseNamed(spec.slice("case:".length)).code : spec;
}

function runStep(state: DevicePairingState, step: ScenarioStep, t0: number): DevicePairingState | PairingFailure {
  const nowMs = t0 + step.atSeconds * 1000;
  try {
    if (step.op === "begin") {
      const c = caseNamed(step.case ?? "");
      const candidate = step.candidate
        ? identityNamed(step.candidate)
        : { role: "controller" as const, publicKey: hexToBytes(c.controllerPublicKey) };
      return beginPairing(state, transcriptFor(c.controllerPublicKey), candidate, nowMs);
    }
    return confirmPairing(state, resolveCode(step.code ?? ""), identityNamed(step.presented ?? ""), nowMs);
  } catch (err) {
    if (err instanceof PairingError) return err.failure;
    throw err;
  }
}

test("pairing scenarios are shared with Swift and cover every failure class", () => {
  assert.ok(vectors.scenarios.length >= 10);
  const seen = new Set<PairingFailure | "ok">();
  for (const scenario of vectors.scenarios) {
    let state = emptyPairingState();
    const t0 = 1_700_000_000_000;
    scenario.steps.forEach((step, index) => {
      const label = `${scenario.id} step ${index + 1} (${step.op})`;
      const outcome = runStep(state, step, t0);
      seen.add(step.expect);
      if (typeof outcome === "string") {
        assert.equal(outcome, step.expect, label);
      } else {
        assert.equal("ok", step.expect, label);
        state = outcome;
      }
    });
    const owner = state.owner ? bytesToHex(state.owner.publicKey) : null;
    const expected = scenario.finalOwner ? vectors.identities[scenario.finalOwner]?.publicKey ?? null : null;
    assert.equal(owner, expected, `${scenario.id} final owner`);
  }
  for (const failure of [
    "ok",
    "expired",
    "rateLimited",
    "codeMismatch",
    "identityChanged",
    "secondOwner",
    "invalidIdentity",
    "busy"
  ] as const) {
    assert.ok(seen.has(failure), `scenarios must exercise ${failure}`);
  }
});

test("published scenario ids are unique and code the expected pairing strings only", () => {
  const ids = vectors.scenarios.map((s) => s.id);
  assert.equal(new Set(ids).size, ids.length);
  for (const scenario of vectors.scenarios) {
    for (const step of scenario.steps) {
      if (step.code && !step.code.startsWith("case:")) {
        assert.match(step.code, /^[0-9]{6}$/, `${scenario.id} literal codes are six digits`);
      }
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
