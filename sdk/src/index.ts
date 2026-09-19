export {
  CONTENT_PROCESS_TERMINATED,
  CONTENT_SECURITY_POLICY,
  CUSTOM_SCHEME,
  NATIVE_NETWORKING_ONLY,
  decideIsolation,
  isLocalPackageURL
} from "./isolation.js";
export type { IsolationDecision, IsolationRequest, IsolationRequestKind } from "./isolation.js";

export {
  PAIRING_EXPIRY_SECONDS,
  PAIRING_MAX_FAILURES,
  PAIRING_SAS_INFO,
  PairingError,
  beginPairing,
  confirmPairing,
  emptyPairingState,
  matchingCode
} from "./pairing.js";
export type { PairingFailure, PairingIdentity, PairingTranscript } from "./pairing.js";

export {
  APPROVED_SOOT,
  APPROVED_PORCELAIN,
  LOGOMARK_REVISION,
  WORDMARK_REVISION,
  DEFAULT_LOCKUP,
  STYLE_GUIDE_URL,
  IOS_MINIMUM,
  MACOS_MINIMUM,
  IOS_27_REQUIRED_TO_RUN,
  SCHEMA_MAJOR,
  OFFLINE_USES_SYSTEM_RED,
  DANGER_LIGHT,
  DANGER_DARK,
  LIGHT_CANVAS,
  COPYRIGHT_OWNER,
  BUNDLE_ID_PREFIX,
  IOS_BUNDLE_ID,
  MAC_BUNDLE_ID,
  PREVIEW_HOST_BUNDLE_ID
} from "./identity.js";

export {
  BACKOFF_CAP_SECONDS,
  EXPANDED_BYTES,
  HTTP_RESPONSE_BYTES,
  HTTP_TIMEOUT_SECONDS,
  MAX_FILES,
  READY_TIMEOUT_SECONDS,
  STATE_CACHE_BYTES,
  UNLINK_HOLD_SECONDS,
  WEBSOCKET_MESSAGE_BYTES
} from "./limits.js";

export { DashboardStore } from "./store.js";
export {
  AUTH_OVERRIDE_KEYS,
  RenderReadiness,
  assertBridgeMessage,
  shouldRetry
} from "./bridge.js";
export type { BridgeErrorCode, BridgeMessage, RenderState } from "./bridge.js";
export type { DashboardManifest, DashboardPage, EventReturnBehavior, EventCondition, EventPayloadFields, EventRuleDefaults, EventSource, ManifestEventRule } from "./package.js";
export {
  BRIDGE_MESSAGE_BYTES,
  BRIDGE_TIMEOUT_MS,
  BridgeClientError,
  CLIENT_AUTH_OVERRIDE_KEYS,
  createDashboardClient,
  createWebKitTransport,
  installScreenpunk
} from "./client.js";
export type {
  BridgeTransport,
  ClientOptions,
  ConnectionResult,
  DashboardClient,
  NavigationStatus,
  StatusListener,
  SubscribeListener
} from "./client.js";

export type Orientation = "portrait" | "landscape";

export interface ConnectionRequest {
  alias: string;
  operation: string;
  parameters: Record<string, unknown>;
}

/** Typed surface from PROTOCOL_AND_MCP. Native host implements these. */
export interface DashboardSDK {
  navigation: { open(pageId: string): Promise<void>; get(): Promise<import("./client.js").NavigationStatus> };
  connections: {
    request(
      alias: string,
      operation: string,
      parameters: Record<string, unknown>
    ): Promise<unknown>;
    subscribe(
      alias: string,
      operation: string,
      parameters: Record<string, unknown>,
      listener: (message: unknown) => void
    ): () => void;
  };
  state: {
    get(key: string): Promise<unknown>;
    set(key: string, value: unknown): Promise<void>;
    remove(key: string): Promise<void>;
  };
  runtime: {
    ready(): void;
    onStatus(listener: (status: unknown) => void): () => void;
  };
}
