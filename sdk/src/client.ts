import type { BridgeErrorCode, BridgeMessage, BridgeMethod } from "./bridge.js";

/** Matches `HTTP_TIMEOUT_SECONDS` in limits.ts. Duplicated so this file has no runtime imports. */
export const BRIDGE_TIMEOUT_MS = 15_000;
/** Matches `MAX_BRIDGE_MESSAGE_BYTES` in limits.ts. */
export const BRIDGE_MESSAGE_BYTES = 64 * 1024;
/** Matches `AUTH_OVERRIDE_KEYS` in bridge.ts. */
export const CLIENT_AUTH_OVERRIDE_KEYS = [
  "authorization",
  "Authorization",
  "x-api-key",
  "X-Api-Key",
  "token",
  "password"
] as const;

const PROTOCOL_VERSION = 1;
const HANDLER_NAME = "screenpunk";

export type StatusListener = (status: unknown) => void;
export type SubscribeListener = (message: unknown) => void;

export interface ConnectionResult {
  value: unknown;
  stale: boolean;
}

export interface PublicReadResult {
  state: "fresh" | "stale" | "unavailable" | "error";
  data?: unknown;
  resourceURL?: string;
  fetchedAt?: string;
  /** Upstream Last-Modified value, when supplied; not inferred from request parameters. */
  lastModified?: string;
  status: number;
  retryAfterSeconds?: number;
  code?: string;
}

export interface BridgeTransport {
  send(message: BridgeMessage): void;
  onMessage(handler: (message: BridgeMessage) => void): () => void;
}

export interface ClientOptions {
  transport?: BridgeTransport;
  timeoutMs?: number;
  clock?: () => number;
  nowId?: () => string;
}

export type ServiceData = { [key: string]: null | boolean | number | string | ServiceData | ServiceValue[] };
export type ServiceValue = null | boolean | number | string | ServiceData | ServiceValue[];
export interface HomeAssistantServiceCall {
  domain: string;
  service: string;
  target?: { entity_id: string | string[] };
  serviceData: ServiceData;
}

export interface CameraSource { kind: "homeAssistant"; connection: "home"; entityId: string }
export interface CameraPlaybackStatus { state: "loading" | "playing" | "stopped" | "failed"; code?: string }
export interface CameraPresentation { controls?: "gallery"; label?: string; order?: number }
export interface CameraMount { stop(): void; retry(): void }

export interface DashboardClient {
  cameras: { mount(element: HTMLElement, source: CameraSource, onStatus?: (status: CameraPlaybackStatus) => void, presentation?: CameraPresentation): CameraMount };

  homeAssistant: { callService(call: HomeAssistantServiceCall): Promise<ConnectionResult> };
  connections: {
    read(alias: string, operation: string, parameters?: Record<string, string>, options?: { signal?: AbortSignal }): Promise<PublicReadResult>;
    release(resourceURL: string): void;
    request(
      alias: string,
      operation: string,
      parameters?: Record<string, unknown>
    ): Promise<ConnectionResult>;
    subscribe(
      alias: string,
      operation: string,
      parameters: Record<string, unknown>,
      listener: SubscribeListener
    ): () => void;
  };
  state: {
    get(key: string): Promise<unknown>;
    set(key: string, value: unknown): Promise<void>;
    remove(key: string): Promise<void>;
  };
  runtime: {
    ready(): void;
    onStatus(listener: StatusListener): () => void;
  };
  dispose(): void;
}

export class BridgeClientError extends Error {
  readonly code: BridgeErrorCode;
  constructor(code: BridgeErrorCode, message?: string) {
    super(message ?? code);
    this.code = code;
    this.name = "BridgeClientError";
  }
}

export function createWebKitTransport(handlerName = HANDLER_NAME): BridgeTransport {
  const listeners = new Set<(message: BridgeMessage) => void>();
  const root = globalThis as ScreenpunkGlobal;

  const previous = root.__screenpunkDispatch;
  root.__screenpunkDispatch = (raw: unknown) => {
    if (typeof previous === "function") previous(raw);
    let parsed: unknown = raw;
    if (typeof raw === "string") {
      try {
        parsed = JSON.parse(raw);
      } catch {
        return;
      }
    }
    if (!isBridgeMessage(parsed)) return;
    for (const listener of listeners) listener(parsed);
  };

  return {
    send(message) {
      const webkit = root.webkit;
      const handler = webkit?.messageHandlers?.[handlerName];
      if (handler && typeof handler.postMessage === "function") {
        handler.postMessage(message);
      }
    },
    onMessage(handler) {
      listeners.add(handler);
      return () => {
        listeners.delete(handler);
      };
    }
  };
}

export function createDashboardClient(options: ClientOptions = {}): DashboardClient {
  const transport = options.transport ?? createWebKitTransport();
  const timeoutMs = options.timeoutMs ?? BRIDGE_TIMEOUT_MS;
  const clock = options.clock ?? Date.now;
  const nowId = options.nowId ?? defaultId;
  const pending = new Map<string, Pending>();
  const subscriptions = new Map<string, Set<SubscribeListener>>();
  const statusListeners = new Set<StatusListener>();
  let seq = 0;
  let disposed = false;
  const rasterURLs = new Map<string, number>();
  const publicRequestIDs = new Set<string>();
  const cameraStops = new Set<() => void>();

  const unsubscribeTransport = transport.onMessage((message) => {
    if (message.kind === "event") {
      if (message.method === "runtime.onStatus") {
        for (const listener of statusListeners) listener(message.value);
        return;
      }
      const key = subscriptionKey(message.alias, message.operation, message.parameters);
      const byId = message.id ? subscriptions.get(message.id) : undefined;
      const byOp = subscriptions.get(key);
      const payload = eventPayload(message);
      if (byId) {
        for (const listener of byId) listener(payload);
      } else if (byOp) {
        for (const listener of byOp) listener(payload);
      }
      return;
    }

    const waiter = pending.get(message.id);
    if (!waiter) return;
    pending.delete(message.id);
    clearTimeout(waiter.timer);
    if (message.kind === "error" || message.ok === false) {
      waiter.reject(new BridgeClientError(message.code ?? "validation_failed", message.message));
      return;
    }
    waiter.resolve(message);
  });

  function sendRequest(
    method: BridgeMethod,
    fields: Partial<BridgeMessage> = {}
  ): Promise<BridgeMessage> {
    if (disposed) return Promise.reject(new BridgeClientError("validation_failed", "disposed"));
    const parameters = fields.parameters ?? {};
    assertSafeParameters(parameters);
    const id = fields.id ?? nowId();
    const message: BridgeMessage = {
      protocolVersion: PROTOCOL_VERSION,
      kind: "request",
      method,
      ...fields,
      id,
      parameters: fields.parameters
    };
    const encoded = new TextEncoder().encode(JSON.stringify(message)).byteLength;
    if (encoded > BRIDGE_MESSAGE_BYTES) {
      return Promise.reject(new BridgeClientError("size_limit"));
    }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        pending.delete(id);
        reject(new BridgeClientError("render_timeout", "bridge_timeout"));
      }, timeoutMs);
      pending.set(id, { resolve, reject, timer });
      try {
        transport.send(message);
      } catch (error) {
        pending.delete(id);
        clearTimeout(timer);
        reject(error);
      }
    });
  }

  function fire(method: BridgeMethod, fields: Partial<BridgeMessage> = {}): void {
    if (disposed) return;
    const parameters = fields.parameters ?? {};
    assertSafeParameters(parameters);
    const message: BridgeMessage = {
      protocolVersion: PROTOCOL_VERSION,
      id: nowId(),
      kind: "request",
      method,
      ...fields
    };
    const encoded = new TextEncoder().encode(JSON.stringify(message)).byteLength;
    if (encoded > BRIDGE_MESSAGE_BYTES) {
      throw new BridgeClientError("size_limit");
    }
    transport.send(message);
  }

  return {
    cameras: {
      mount(element, source, onStatus = () => {}, presentation = {}) {
        if (source.kind !== "homeAssistant" || source.connection !== "home" ||
            !/^camera\.[a-z0-9_]+$/.test(source.entityId)) throw new BridgeClientError("validation_failed");
        const cameraId = `camera-${nowId()}`;
        // Serialize only known fields, never caller-supplied URLs or credentials.
        const encodedSource = JSON.stringify({ kind: source.kind, connection: source.connection, entityId: source.entityId });
        let stopped = false, busy = false, active = false;
        const close = () => {
          if (!active) return;
          active = false;
          void sendRequest("connections.request", { alias: "home", operation: "cameraClose", parameters: { id: cameraId } }).catch(() => {});
        };
        const update = async () => {
          if (stopped || busy) return;
          const rect = element.getBoundingClientRect();
          const visible = element.isConnected && !document.hidden && rect.width > 0 && rect.height > 0 &&
            rect.x >= 0 && rect.y >= 0 && rect.right <= innerWidth + 1 && rect.bottom <= innerHeight + 1 &&
            getComputedStyle(element).visibility !== "hidden";
          if (!visible) { close(); onStatus({ state: "stopped" }); return; }
          busy = true; active = true;
          try {
            const response = await sendRequest("connections.request", { alias: "home", operation: "cameraPresent", parameters: {
              id: cameraId, source: encodedSource,
              controls: presentation.controls === "gallery" ? "gallery" : "", label: (presentation.label ?? "Camera").slice(0,80), order: String(presentation.order ?? 0),
              rect: JSON.stringify({ x: rect.x, y: rect.y, width: rect.width, height: rect.height, viewportWidth: innerWidth })
            }});
            if (!stopped) onStatus(response.value as CameraPlaybackStatus);
          } catch (error) {
            if (!stopped) onStatus({ state: "failed", code: error instanceof BridgeClientError ? error.code : "device_offline" });
          } finally { busy = false; }
        };
        const timer = setInterval(() => { void update(); }, 750);
        const onVisibility = () => { if (document.hidden) close(); else void update(); };
        document.addEventListener("visibilitychange", onVisibility);
        const stop = () => {
          if (stopped) return;
          stopped = true; clearInterval(timer); close();
          document.removeEventListener("visibilitychange", onVisibility);
          cameraStops.delete(stop);
        };
        cameraStops.add(stop);
        void update();
        return { stop, retry() { close(); void update(); } };
      }
    },
    homeAssistant: {
      async callService(call) {
        assertServiceData(call.serviceData);
        const encoded = JSON.stringify(call);
        if (new TextEncoder().encode(encoded).length > 32 * 1024) throw new BridgeClientError("size_limit");
        const response = await sendRequest("connections.request", { alias: "home", operation: "callService", parameters: { call: encoded } });
        return { value: response.value, stale: response.stale === true };
      }
    },
    connections: {
      async read(alias, operation, parameters = {}, options = {}) {
        if (options.signal?.aborted) throw new DOMException("Aborted", "AbortError");
        const id = nowId();
        const abort = () => {
          fire("connections.cancel", { parameters: { requestId: id } });
          const waiter = pending.get(id);
          if (waiter) { clearTimeout(waiter.timer); pending.delete(id); waiter.reject(new DOMException("Aborted", "AbortError")); }
        };
        publicRequestIDs.add(id);
        options.signal?.addEventListener("abort", abort, { once: true });
        try {
          const response = await sendRequest("connections.request", { alias, operation, parameters, id });
          const result = response.value as PublicReadResult;
          if (!result || !["fresh", "stale", "unavailable", "error"].includes(result.state)) throw new BridgeClientError("unsupported_version");
          if (result.resourceURL) {
            if (!/^screenpunk:\/\/package\/__native-raster\/[a-z0-9-]+$/.test(result.resourceURL)) throw new BridgeClientError("validation_failed");
            rasterURLs.set(result.resourceURL, (rasterURLs.get(result.resourceURL) ?? 0) + 1);
          }
          return result;
        } catch (error) {
          if (error instanceof BridgeClientError && error.code === "permission_required") {
            // Older hosts use permission_required for unknown public-read operations.
            // Keep genuine revision approval failures distinct from missing runtime support.
            const status = await sendRequest("runtime.onStatus");
            if ((status.value as { publicReadHTTP?: number } | undefined)?.publicReadHTTP !== 1) {
              throw new BridgeClientError("unsupported_version", "Update Screenpunk to read public data.");
            }
          }
          throw error;
        } finally {
          options.signal?.removeEventListener("abort", abort); publicRequestIDs.delete(id);
        }
      },
      release(resourceURL) {
        const count = rasterURLs.get(resourceURL) ?? 0;
        if (count > 1) rasterURLs.set(resourceURL, count - 1); else rasterURLs.delete(resourceURL);
        fire("connections.release", { parameters: { resourceURL } });
      },
      async request(alias, operation, parameters = {}) {
        const response = await sendRequest("connections.request", { alias, operation, parameters });
        return { value: response.value, stale: response.stale === true };
      },
      subscribe(alias, operation, parameters, listener) {
        const key = subscriptionKey(alias, operation, parameters);
        let set = subscriptions.get(key);
        if (!set) {
          set = new Set();
          subscriptions.set(key, set);
        }
        set.add(listener);
        const id = `sub-${++seq}-${nowId()}`;
        const idSet = new Set<SubscribeListener>([listener]);
        subscriptions.set(id, idSet);
        void sendRequest("connections.subscribe", { alias, operation, parameters, id }).catch(() => {
          /* host may still push events; listener stays until unsubscribe */
        });
        return () => {
          set?.delete(listener);
          if (set && set.size === 0) subscriptions.delete(key);
          subscriptions.delete(id);
          void sendRequest("connections.unsubscribe", {
            alias,
            operation,
            parameters: { subscriptionId: id }
          }).catch(() => undefined);
        };
      }
    },
    state: {
      async get(key) {
        const response = await sendRequest("state.get", { key });
        return response.value ?? null;
      },
      async set(key, value) {
        await sendRequest("state.set", { key, value });
      },
      async remove(key) {
        await sendRequest("state.remove", { key });
      }
    },
    runtime: {
      ready() {
        fire("runtime.ready");
      },
      onStatus(listener) {
        const first = statusListeners.size === 0;
        statusListeners.add(listener);
        if (first) fire("runtime.onStatus");
        return () => {
          statusListeners.delete(listener);
        };
      }
    },
    dispose() {
      for (const id of publicRequestIDs) fire("connections.cancel", { parameters: { requestId: id } });
      for (const [resourceURL, count] of rasterURLs) for (let i = 0; i < count; i++) fire("connections.release", { parameters: { resourceURL } });
      publicRequestIDs.clear(); rasterURLs.clear();
      for (const stop of cameraStops) stop();
      disposed = true;
      unsubscribeTransport();
      for (const waiter of pending.values()) {
        clearTimeout(waiter.timer);
        waiter.reject(new BridgeClientError("validation_failed", "disposed"));
      }
      pending.clear();
      subscriptions.clear();
      statusListeners.clear();
    }
  };

  function defaultId(): string {
    const cryptoObj = globalThis.crypto;
    if (cryptoObj && typeof cryptoObj.randomUUID === "function") {
      return cryptoObj.randomUUID();
    }
    return `sp-${clock().toString(36)}-${++seq}`;
  }
}

export function installScreenpunk(options: ClientOptions = {}): DashboardClient {
  const root = globalThis as ScreenpunkGlobal;
  if (root.screenpunk && options.transport === undefined && options.timeoutMs === undefined) {
    return root.screenpunk;
  }
  const client = createDashboardClient(options);
  root.screenpunk = client;
  return client;
}

interface Pending {
  resolve: (message: BridgeMessage) => void;
  reject: (error: unknown) => void;
  timer: ReturnType<typeof setTimeout>;
}

interface ScreenpunkGlobal {
  screenpunk?: DashboardClient;
  __screenpunkDispatch?: (raw: unknown) => void;
  webkit?: {
    messageHandlers?: Record<string, { postMessage: (message: unknown) => void }>;
  };
}

function isBridgeMessage(value: unknown): value is BridgeMessage {
  if (typeof value !== "object" || value === null) return false;
  const message = value as BridgeMessage;
  return message.protocolVersion === PROTOCOL_VERSION && typeof message.id === "string" && !!message.kind;
}

function assertSafeParameters(parameters: Record<string, unknown>): void {
  for (const key of Object.keys(parameters)) {
    if ((CLIENT_AUTH_OVERRIDE_KEYS as readonly string[]).includes(key)) {
      throw new BridgeClientError("permission_required");
    }
  }
}

function subscriptionKey(
  alias: string | undefined,
  operation: string | undefined,
  parameters: unknown
): string {
  return `${alias ?? ""}\u001f${operation ?? ""}\u001f${stable(parameters ?? {})}`;
}

function eventPayload(message: BridgeMessage): unknown {
  if (message.stale === true) {
    return { value: message.value, stale: true };
  }
  return message.value;
}

function stable(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(stable).join(",")}]`;
  const obj = value as Record<string, unknown>;
  return `{${Object.keys(obj)
    .sort()
    .map((k) => `${JSON.stringify(k)}:${stable(obj[k])}`)
    .join(",")}}`;
}

/** Reject values JSON.stringify would silently alter, and bound work before serialization. */
function assertServiceData(data: ServiceData): void {
  let nodes = 0;
  const visit = (value: unknown, depth: number): void => {
    if (++nodes > 2048 || depth > 12) throw new BridgeClientError("size_limit");
    if (value === null || typeof value === "boolean") return;
    if (typeof value === "number" && Number.isFinite(value)) return;
    if (typeof value === "string") {
      if (new TextEncoder().encode(value).length > 8192) throw new BridgeClientError("size_limit");
      return;
    }
    if (Array.isArray(value)) {
      for (const item of value) visit(item, depth + 1);
      return;
    }
    if (typeof value === "object" && value !== null &&
        (Object.getPrototypeOf(value) === Object.prototype || Object.getPrototypeOf(value) === null)) {
      for (const [key, item] of Object.entries(value)) {
        if (new TextEncoder().encode(key).length > 128) throw new BridgeClientError("size_limit");
        visit(item, depth + 1);
      }
      return;
    }
    throw new BridgeClientError("validation_failed");
  };
  if (!data || typeof data !== "object" || Array.isArray(data)) throw new BridgeClientError("validation_failed");
  visit(data, 0);
}
