import { createHmac } from "node:crypto";

/** Short authentication string. Not a cipher and not an encryption key. */
export const PAIRING_EXPIRY_SECONDS = 120;
export const PAIRING_MAX_FAILURES = 5;
export const PAIRING_CODE_DIGITS = 6;
export const PAIRING_IDENTITY_BYTES = 32;
export const PAIRING_SESSION_BYTES = 16;
export const PAIRING_SAS_INFO = "screenpunk-pairing-sas-v1";

export type PairingRole = "device" | "controller";

export interface PairingIdentity {
  role: PairingRole;
  publicKey: Uint8Array;
}

export interface PairingTranscript {
  devicePublicKey: Uint8Array;
  controllerPublicKey: Uint8Array;
  sessionNonce: Uint8Array;
}

export type PairingFailure =
  | "expired"
  | "rateLimited"
  | "codeMismatch"
  | "identityChanged"
  | "secondOwner"
  | "invalidIdentity"
  | "busy";

export class PairingError extends Error {
  readonly failure: PairingFailure;
  constructor(failure: PairingFailure) {
    super(failure);
    this.failure = failure;
  }
}

export function hexToBytes(hex: string): Uint8Array {
  if (hex.length % 2 !== 0) throw new Error("odd hex");
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i += 1) {
    out[i] = Number.parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  }
  return out;
}

export function bytesToHex(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString("hex");
}

export function repeatingKey(byte: number, length = PAIRING_IDENTITY_BYTES): Uint8Array {
  return new Uint8Array(length).fill(byte);
}

export function canonicalTranscript(transcript: PairingTranscript): Buffer {
  return Buffer.concat([
    Buffer.from(transcript.devicePublicKey),
    Buffer.from([0]),
    Buffer.from(transcript.controllerPublicKey),
    Buffer.from([0]),
    Buffer.from(transcript.sessionNonce)
  ]);
}

/** HMAC-SHA256(key: sasInfo, data: transcript). Standard MAC, not a home-grown cipher. */
export function matchingCode(transcript: PairingTranscript): string {
  const mac = createHmac("sha256", PAIRING_SAS_INFO).update(canonicalTranscript(transcript)).digest();
  const raw = mac.readUInt32BE(0) % 1_000_000;
  return raw.toString().padStart(PAIRING_CODE_DIGITS, "0");
}

export interface DevicePairingState {
  owner: PairingIdentity | null;
  session: {
    transcript: PairingTranscript;
    expectedCode: string;
    createdAtMs: number;
    failures: number;
    confirmed: boolean;
    candidateOwner: PairingIdentity;
  } | null;
}

export function emptyPairingState(): DevicePairingState {
  return { owner: null, session: null };
}

function identitiesEqual(a: PairingIdentity, b: PairingIdentity): boolean {
  return a.role === b.role && bytesToHex(a.publicKey) === bytesToHex(b.publicKey);
}

export function beginPairing(
  state: DevicePairingState,
  transcript: PairingTranscript,
  candidateOwner: PairingIdentity,
  nowMs: number
): DevicePairingState {
  if (candidateOwner.role !== "controller" || candidateOwner.publicKey.length !== PAIRING_IDENTITY_BYTES) {
    throw new PairingError("invalidIdentity");
  }
  if (state.owner && !identitiesEqual(state.owner, candidateOwner)) {
    throw new PairingError("secondOwner");
  }
  // A live session belongs to its candidate until it completes, is cancelled,
  // or expires; a late begin from someone else cannot swap the code on screen.
  if (
    state.session &&
    !state.session.confirmed &&
    nowMs - state.session.createdAtMs <= PAIRING_EXPIRY_SECONDS * 1000 &&
    !identitiesEqual(state.session.candidateOwner, candidateOwner)
  ) {
    throw new PairingError("busy");
  }
  return {
    owner: state.owner,
    session: {
      transcript,
      expectedCode: matchingCode(transcript),
      createdAtMs: nowMs,
      failures: 0,
      confirmed: false,
      candidateOwner
    }
  };
}

export function confirmPairing(
  state: DevicePairingState,
  code: string,
  presentedOwner: PairingIdentity,
  nowMs: number
): DevicePairingState {
  if (!state.session) throw new PairingError("expired");
  if (nowMs - state.session.createdAtMs > PAIRING_EXPIRY_SECONDS * 1000) {
    throw new PairingError("expired");
  }
  if (state.session.failures >= PAIRING_MAX_FAILURES) {
    throw new PairingError("rateLimited");
  }
  if (!identitiesEqual(presentedOwner, state.session.candidateOwner)) {
    throw new PairingError("identityChanged");
  }
  if (state.owner && !identitiesEqual(state.owner, presentedOwner)) {
    throw new PairingError("secondOwner");
  }
  if (code !== state.session.expectedCode) {
    state.session.failures += 1;
    if (state.session.failures >= PAIRING_MAX_FAILURES) throw new PairingError("rateLimited");
    throw new PairingError("codeMismatch");
  }
  return {
    owner: presentedOwner,
    session: { ...state.session, confirmed: true }
  };
}
