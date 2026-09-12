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
  LIGHT_CANVAS
} from "./identity.js";

export type Orientation = "portrait" | "landscape";

export interface ConnectionRequest {
  alias: string;
  operation: string;
  parameters: Record<string, unknown>;
}

/** Typed surface from PROTOCOL_AND_MCP. Native host implements these. */
export interface DashboardSDK {
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
