/** Page isolation. Native host performs approved networking; the page cannot. */

export const CUSTOM_SCHEME = "screenpunk";
export const PACKAGE_HOST = "package";
export const NATIVE_NETWORKING_ONLY = true;
export const CONTENT_SECURITY_POLICY = [
  "default-src 'none'",
  "script-src 'self'",
  "style-src 'self'",
  "img-src 'self'",
  "font-src 'self'",
  "connect-src 'none'",
  "frame-src 'none'",
  "child-src 'none'",
  "worker-src 'none'",
  "object-src 'none'",
  "base-uri 'none'",
  "form-action 'none'",
  "media-src 'none'"
].join("; ");

export const CONTENT_PROCESS_TERMINATED = "content-process-terminated";

export type IsolationRequestKind =
  | "fetch"
  | "xhr"
  | "websocket"
  | "script"
  | "stylesheet"
  | "image"
  | "iframe"
  | "form"
  | "navigation"
  | "filePath"
  | "traversal"
  | "bridgeSpoof";

export type IsolationDecision =
  | "allowLocalAsset"
  | "denyDirectEgress"
  | "denyRemoteCode"
  | "denyNavigation"
  | "denyFrame"
  | "denyTraversal"
  | "denyBridgeSpoof"
  | "denyFilePath";

export interface IsolationRequest {
  kind: IsolationRequestKind;
  url: string;
  isMainFrame?: boolean;
  initiatorOrigin?: string;
}

export function isLocalPackageURL(url: string): boolean {
  const prefix = `${CUSTOM_SCHEME}://${PACKAGE_HOST}/`;
  if (!url.startsWith(prefix)) return false;
  const rest = url.slice(prefix.length);
  if (!rest || containsTraversal(rest)) return false;
  return /^[A-Za-z0-9._/-]+$/.test(rest);
}

export function decideIsolation(request: IsolationRequest): IsolationDecision {
  if (request.kind === "bridgeSpoof") return "denyBridgeSpoof";

  if (containsTraversal(request.url)) return "denyTraversal";
  if (request.kind === "filePath" || request.url.toLowerCase().startsWith("file:")) {
    return "denyFilePath";
  }
  if (request.kind === "iframe" || request.kind === "form") return "denyFrame";

  if (isRemote(request.url)) {
    if (request.kind === "script" || request.kind === "stylesheet") return "denyRemoteCode";
    if (request.kind === "navigation") return "denyNavigation";
    return "denyDirectEgress";
  }

  if (request.kind === "navigation" && !isLocalPackageURL(request.url)) {
    return "denyNavigation";
  }
  if (isLocalPackageURL(request.url)) return "allowLocalAsset";
  return "denyDirectEgress";
}

function isRemote(url: string): boolean {
  const lower = url.toLowerCase();
  return (
    lower.startsWith("http:") ||
    lower.startsWith("https:") ||
    lower.startsWith("ws:") ||
    lower.startsWith("wss:")
  );
}

function containsTraversal(url: string): boolean {
  return url.split("/").includes("..") || url.includes("\\..") || url.toLowerCase().includes("%2e%2e");
}
