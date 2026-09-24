/* @screenpunk/sdk browser bridge. Schema major 1. No Node on devices. */
"use strict";
(function (global) {
const BRIDGE_TIMEOUT_MS = 15000;
const BRIDGE_MESSAGE_BYTES = 64 * 1024;
const CLIENT_AUTH_OVERRIDE_KEYS = [
    "authorization",
    "Authorization",
    "x-api-key",
    "X-Api-Key",
    "token",
    "password"
];
const PROTOCOL_VERSION = 1;
const HANDLER_NAME = "screenpunk";
class BridgeClientError extends Error {
    constructor(code, message) {
        super(message ?? code);
        this.code = code;
        this.name = "BridgeClientError";
    }
}
function createWebKitTransport(handlerName = HANDLER_NAME) {
    const listeners = new Set();
    const root = globalThis;
    const previous = root.__screenpunkDispatch;
    root.__screenpunkDispatch = (raw) => {
        if (typeof previous === "function")
            previous(raw);
        let parsed = raw;
        if (typeof raw === "string") {
            try {
                parsed = JSON.parse(raw);
            }
            catch {
                return;
            }
        }
        if (!isBridgeMessage(parsed))
            return;
        for (const listener of listeners)
            listener(parsed);
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
function createDashboardClient(options = {}) {
    const transport = options.transport ?? createWebKitTransport();
    const timeoutMs = options.timeoutMs ?? BRIDGE_TIMEOUT_MS;
    const clock = options.clock ?? Date.now;
    const nowId = options.nowId ?? defaultId;
    const pending = new Map();
    const subscriptions = new Map();
    const statusListeners = new Set();
    let seq = 0;
    let disposed = false;
    const rasterURLs = new Map();
    const publicRequestIDs = new Set();
    const cameraStops = new Set();
    const unsubscribeTransport = transport.onMessage((message) => {
        if (message.kind === "event") {
            if (message.method === "runtime.onStatus") {
                for (const listener of statusListeners)
                    listener(message.value);
                return;
            }
            const key = subscriptionKey(message.alias, message.operation, message.parameters);
            const byId = message.id ? subscriptions.get(message.id) : undefined;
            const byOp = subscriptions.get(key);
            const payload = eventPayload(message);
            if (byId) {
                for (const listener of byId)
                    listener(payload);
            }
            else if (byOp) {
                for (const listener of byOp)
                    listener(payload);
            }
            return;
        }
        const waiter = pending.get(message.id);
        if (!waiter)
            return;
        pending.delete(message.id);
        clearTimeout(waiter.timer);
        if (message.kind === "error" || message.ok === false) {
            waiter.reject(new BridgeClientError(message.code ?? "validation_failed", message.message));
            return;
        }
        waiter.resolve(message);
    });
    function sendRequest(method, fields = {}) {
        if (disposed)
            return Promise.reject(new BridgeClientError("validation_failed", "disposed"));
        const parameters = fields.parameters ?? {};
        assertSafeParameters(parameters);
        const id = fields.id ?? nowId();
        const message = {
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
                if (fields.alias === "googleTV" && (fields.operation === "voice" || fields.operation === "launchChannel" || fields.operation === "togglePower")) {
                    try {
                        transport.send({ protocolVersion: PROTOCOL_VERSION, kind: "request", id: nowId(), method: "connections.cancel", parameters: { requestId: id } });
                    }
                    catch { }
                }
                reject(new BridgeClientError("render_timeout", "bridge_timeout"));
            }, fields.alias === "googleTV" && (fields.operation === "voice" || fields.operation === "launchChannel" || fields.operation === "togglePower") ? Math.max(timeoutMs, 45000) : timeoutMs);
            pending.set(id, { resolve, reject, timer });
            try {
                transport.send(message);
            }
            catch (error) {
                pending.delete(id);
                clearTimeout(timer);
                reject(error);
            }
        });
    }
    function fire(method, fields = {}) {
        if (disposed)
            return;
        const parameters = fields.parameters ?? {};
        assertSafeParameters(parameters);
        const message = {
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
        navigation: {
            async open(pageId) { await sendRequest("navigation.open", { parameters: { pageId } }); },
            async get() { const response = await sendRequest("navigation.get"); return response.value; }
        },
        cameras: {
            mount(element, source, onStatus = () => { }, presentation = {}) {
                if (source.kind !== "homeAssistant" || source.connection !== "home" ||
                    !/^camera\.[a-z0-9_]+$/.test(source.entityId))
                    throw new BridgeClientError("validation_failed");
                const cameraId = `camera-${nowId()}`;
                const encodedSource = JSON.stringify({ kind: source.kind, connection: source.connection, entityId: source.entityId });
                let stopped = false, busy = false, active = false;
                const close = () => {
                    if (!active)
                        return;
                    active = false;
                    void sendRequest("connections.request", { alias: "home", operation: "cameraClose", parameters: { id: cameraId } }).catch(() => { });
                };
                const update = async () => {
                    if (stopped || busy)
                        return;
                    const rect = element.getBoundingClientRect();
                    const visible = element.isConnected && !document.hidden && rect.width > 0 && rect.height > 0 &&
                        rect.x >= 0 && rect.y >= 0 && rect.right <= innerWidth + 1 && rect.bottom <= innerHeight + 1 &&
                        getComputedStyle(element).visibility !== "hidden";
                    if (!visible) {
                        close();
                        onStatus({ state: "stopped" });
                        return;
                    }
                    busy = true;
                    active = true;
                    try {
                        const response = await sendRequest("connections.request", { alias: "home", operation: "cameraPresent", parameters: {
                                id: cameraId, source: encodedSource,
                                controls: presentation.controls === "gallery" ? "gallery" : "", label: (presentation.label ?? "Camera").slice(0, 80), order: String(presentation.order ?? 0),
                                rect: JSON.stringify({ x: rect.x, y: rect.y, width: rect.width, height: rect.height, viewportWidth: innerWidth })
                            } });
                        if (!stopped)
                            onStatus(response.value);
                    }
                    catch (error) {
                        if (!stopped)
                            onStatus({ state: "failed", code: error instanceof BridgeClientError ? error.code : "device_offline" });
                    }
                    finally {
                        busy = false;
                    }
                };
                const timer = setInterval(() => { void update(); }, 750);
                const onVisibility = () => { if (document.hidden)
                    close();
                else
                    void update(); };
                document.addEventListener("visibilitychange", onVisibility);
                const stop = () => {
                    if (stopped)
                        return;
                    stopped = true;
                    clearInterval(timer);
                    close();
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
                if (new TextEncoder().encode(encoded).length > 32 * 1024)
                    throw new BridgeClientError("size_limit");
                const response = await sendRequest("connections.request", { alias: "home", operation: "callService", parameters: { call: encoded } });
                return { value: response.value, stale: response.stale === true };
            }
        },
        connections: {
            async read(alias, operation, parameters = {}, options = {}) {
                if (options.signal?.aborted)
                    throw new DOMException("Aborted", "AbortError");
                const id = nowId();
                const abort = () => {
                    fire("connections.cancel", { parameters: { requestId: id } });
                    const waiter = pending.get(id);
                    if (waiter) {
                        clearTimeout(waiter.timer);
                        pending.delete(id);
                        waiter.reject(new DOMException("Aborted", "AbortError"));
                    }
                };
                publicRequestIDs.add(id);
                options.signal?.addEventListener("abort", abort, { once: true });
                try {
                    const response = await sendRequest("connections.request", { alias, operation, parameters, id });
                    const result = response.value;
                    if (!result || !["fresh", "stale", "unavailable", "error"].includes(result.state))
                        throw new BridgeClientError("unsupported_version");
                    if (result.resourceURL) {
                        if (!/^screenpunk:\/\/package\/__native-raster\/[a-z0-9-]+$/.test(result.resourceURL))
                            throw new BridgeClientError("validation_failed");
                        rasterURLs.set(result.resourceURL, (rasterURLs.get(result.resourceURL) ?? 0) + 1);
                    }
                    return result;
                }
                catch (error) {
                    if (error instanceof BridgeClientError && error.code === "permission_required") {
                        const status = await sendRequest("runtime.onStatus");
                        if (status.value?.publicReadHTTP !== 1) {
                            throw new BridgeClientError("unsupported_version", "Update Screenpunk to read public data.");
                        }
                    }
                    throw error;
                }
                finally {
                    options.signal?.removeEventListener("abort", abort);
                    publicRequestIDs.delete(id);
                }
            },
            release(resourceURL) {
                const count = rasterURLs.get(resourceURL) ?? 0;
                if (count > 1)
                    rasterURLs.set(resourceURL, count - 1);
                else
                    rasterURLs.delete(resourceURL);
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
                const idSet = new Set([listener]);
                subscriptions.set(id, idSet);
                void sendRequest("connections.subscribe", { alias, operation, parameters, id }).catch(() => {
                });
                return () => {
                    set?.delete(listener);
                    if (set && set.size === 0)
                        subscriptions.delete(key);
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
                if (first)
                    fire("runtime.onStatus");
                return () => {
                    statusListeners.delete(listener);
                };
            }
        },
        dispose() {
            for (const id of publicRequestIDs)
                fire("connections.cancel", { parameters: { requestId: id } });
            for (const [resourceURL, count] of rasterURLs)
                for (let i = 0; i < count; i++)
                    fire("connections.release", { parameters: { resourceURL } });
            publicRequestIDs.clear();
            rasterURLs.clear();
            for (const stop of cameraStops)
                stop();
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
    function defaultId() {
        const cryptoObj = globalThis.crypto;
        if (cryptoObj && typeof cryptoObj.randomUUID === "function") {
            return cryptoObj.randomUUID();
        }
        return `sp-${clock().toString(36)}-${++seq}`;
    }
}
function installScreenpunk(options = {}) {
    const root = globalThis;
    if (root.screenpunk && options.transport === undefined && options.timeoutMs === undefined) {
        return root.screenpunk;
    }
    const client = createDashboardClient(options);
    root.screenpunk = client;
    return client;
}
function isBridgeMessage(value) {
    if (typeof value !== "object" || value === null)
        return false;
    const message = value;
    return message.protocolVersion === PROTOCOL_VERSION && typeof message.id === "string" && !!message.kind;
}
function assertSafeParameters(parameters) {
    for (const key of Object.keys(parameters)) {
        if (CLIENT_AUTH_OVERRIDE_KEYS.includes(key)) {
            throw new BridgeClientError("permission_required");
        }
    }
}
function subscriptionKey(alias, operation, parameters) {
    return `${alias ?? ""}\u001f${operation ?? ""}\u001f${stable(parameters ?? {})}`;
}
function eventPayload(message) {
    if (message.stale === true) {
        return { value: message.value, stale: true };
    }
    return message.value;
}
function stable(value) {
    if (value === null || typeof value !== "object")
        return JSON.stringify(value);
    if (Array.isArray(value))
        return `[${value.map(stable).join(",")}]`;
    const obj = value;
    return `{${Object.keys(obj)
        .sort()
        .map((k) => `${JSON.stringify(k)}:${stable(obj[k])}`)
        .join(",")}}`;
}
function assertServiceData(data) {
    let nodes = 0;
    const visit = (value, depth) => {
        if (++nodes > 2048 || depth > 12)
            throw new BridgeClientError("size_limit");
        if (value === null || typeof value === "boolean")
            return;
        if (typeof value === "number" && Number.isFinite(value))
            return;
        if (typeof value === "string") {
            if (new TextEncoder().encode(value).length > 8192)
                throw new BridgeClientError("size_limit");
            return;
        }
        if (Array.isArray(value)) {
            for (const item of value)
                visit(item, depth + 1);
            return;
        }
        if (typeof value === "object" && value !== null &&
            (Object.getPrototypeOf(value) === Object.prototype || Object.getPrototypeOf(value) === null)) {
            for (const [key, item] of Object.entries(value)) {
                if (new TextEncoder().encode(key).length > 128)
                    throw new BridgeClientError("size_limit");
                visit(item, depth + 1);
            }
            return;
        }
        throw new BridgeClientError("validation_failed");
    };
    if (!data || typeof data !== "object" || Array.isArray(data))
        throw new BridgeClientError("validation_failed");
    visit(data, 0);
}

  var api = {
    createDashboardClient: createDashboardClient,
    createWebKitTransport: createWebKitTransport,
    installScreenpunk: installScreenpunk,
    BridgeClientError: BridgeClientError,
    BRIDGE_TIMEOUT_MS: BRIDGE_TIMEOUT_MS
  };
  var installed = installScreenpunk();
  installed.createDashboardClient = createDashboardClient;
  installed.createWebKitTransport = createWebKitTransport;
  installed.BridgeClientError = BridgeClientError;
  global.screenpunk = installed;
  global.ScreenpunkSDK = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
