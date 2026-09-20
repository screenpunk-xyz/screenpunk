import { HTTP_RESPONSE_BYTES, HTTP_TIMEOUT_SECONDS, MAX_BRIDGE_MESSAGE_BYTES, WEBSOCKET_MESSAGE_BYTES } from "./limits.js";

export const BRIDGE_METHODS = [
  "connections.request",
  "connections.cancel",
  "connections.release",
  "connections.subscribe",
  "connections.unsubscribe",
  "state.get",
  "state.set",
  "state.remove",
  "runtime.ready",
  "runtime.onStatus",
  "navigation.open",
  "navigation.get"
] as const;

export type BridgeMethod = (typeof BRIDGE_METHODS)[number];
export type BridgeKind = "request" | "response" | "event" | "error";

export type BridgeErrorCode =
  | "validation_failed"
  | "permission_required"
  | "unsupported_version"
  | "device_offline"
  | "render_timeout"
  | "not_paired"
  | "revision_conflict"
  | "size_limit"
  | "denied_egress";

export interface BridgeMessage {
  protocolVersion: 1;
  id: string;
  kind: BridgeKind;
  method?: BridgeMethod;
  alias?: string;
  operation?: string;
  parameters?: Record<string, unknown>;
  key?: string;
  value?: unknown;
  ok?: boolean;
  stale?: boolean;
  code?: BridgeErrorCode;
  message?: string;
}

export const AUTH_OVERRIDE_KEYS = [
  "authorization",
  "Authorization",
  "x-api-key",
  "X-Api-Key",
  "token",
  "password"
];

export function redactError(code: BridgeErrorCode): BridgeMessage {
  return {
    protocolVersion: 1,
    id: "redacted",
    kind: "error",
    code,
    message: code
  };
}

export function assertBridgeMessage(raw: unknown): BridgeMessage {
  if (typeof raw !== "object" || raw === null) {
    throw new Error("validation_failed");
  }
  const encoded = new TextEncoder().encode(JSON.stringify(raw)).byteLength;
  if (encoded > MAX_BRIDGE_MESSAGE_BYTES) throw new Error("size_limit");
  const msg = raw as BridgeMessage;
  if (msg.protocolVersion !== 1) throw new Error("unsupported_version");
  if (!msg.id || !msg.kind) throw new Error("validation_failed");
  if (msg.parameters) {
    for (const key of Object.keys(msg.parameters)) {
      if (AUTH_OVERRIDE_KEYS.includes(key)) {
        throw new Error("permission_required");
      }
    }
  }
  return msg;
}

export function httpBounds(): { timeoutSeconds: number; maxBytes: number } {
  return { timeoutSeconds: HTTP_TIMEOUT_SECONDS, maxBytes: HTTP_RESPONSE_BYTES };
}

export function websocketBounds(): { maxBytes: number } {
  return { maxBytes: WEBSOCKET_MESSAGE_BYTES };
}

export function shouldRetry(write: boolean, idempotent: boolean): boolean {
  if (write && !idempotent) return false;
  return true;
}

export type RenderState = "pending" | "ready" | "timeout" | "content-process-terminated";

export class RenderReadiness {
  state: RenderState = "pending";
  readyAtMs: number | null = null;

  constructor(private readonly clock: () => number = Date.now) {}

  markReady(): void {
    if (this.state === "timeout" || this.state === "content-process-terminated") return;
    this.state = "ready";
    this.readyAtMs = this.clock();
  }

  markTimeout(): void {
    if (this.state === "ready") return;
    this.state = "timeout";
  }

  markProcessDeath(): void {
    this.state = "content-process-terminated";
    this.readyAtMs = null;
  }

  /** Ready is layout/data first paint. It does not mean connections are healthy. */
  get connectionsHealthy(): boolean {
    return false;
  }
}
