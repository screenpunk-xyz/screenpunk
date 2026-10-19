import type { DashboardManifest, ManifestConnection } from "./package.js";
import { fail } from "./native-package-json.js";

function unique(values: string[], path: string): void {
  if (new Set(values.map((v) => v.normalize("NFC"))).size !== values.length)
    fail("duplicate", path, "duplicate native String identity");
}
function pathIdentity(path: string, field: string): void {
  // Native PackagePath preserves raw segments. Reject aliases that a ZIP/URL layer
  // could normalize differently; do not rewrite the path inside a digest.
  if (
    !/^[A-Za-z0-9._/-]+$/.test(path) ||
    /[\r\n]/.test(path) ||
    path.split("/").some((s) => s === "" || s === ".")
  )
    fail(
      "path_identity",
      field,
      "path must have exact schema ASCII spelling without empty, dot, or control segments",
    );
}
function publicRead(connection: ManifestConnection, index: number): void {
  const d = connection.publicHTTP;
  if (!d) return;
  const field = `$manifest.connections[${index}].publicHTTP`;
  const bad = (detail: string): never =>
    fail("native_validation", field, detail);
  const component = (s: string) =>
    /^[A-Za-z0-9_.-]{1,128}$/.test(s) && s !== "." && s !== "..";
  const pathPart = (s: string) =>
    /^[A-Za-z0-9_.,~-]{1,256}$/.test(s) && s !== "." && s !== "..";
  if (
    connection.alias === "home" ||
    connection.operations !== undefined ||
    connection.serviceCalls !== undefined ||
    connection.cameraEntities !== undefined
  )
    bad(
      "public HTTP declaration conflicts with native connection capabilities",
    );
  const host = d.origin.replace(/^https:\/\//, "").replace(/:443$/, "");
  if (
    host === "localhost" ||
    host.endsWith(".localhost") ||
    host === "metadata.google.internal" ||
    host.endsWith(".metadata.google.internal")
  )
    bad("native public HTTP origin is not public unicast");
  if (/^[0-9.]+$/.test(host)) {
    const b = host.split(".").map(Number);
    if (
      b.length !== 4 ||
      b.some((n) => n > 255) ||
      b[0] === 0 ||
      b[0] === 10 ||
      b[0] === 127 ||
      b[0] >= 224 ||
      (b[0] === 169 && b[1] === 254) ||
      (b[0] === 192 && b[1] === 168) ||
      (b[0] === 172 && b[1] >= 16 && b[1] <= 31) ||
      (b[0] === 100 && b[1] >= 64 && b[1] <= 127)
    )
      bad("native public HTTP origin is not public unicast");
  }
  unique(
    d.operations.map((o) => o.name),
    field + ".operations",
  );
  for (const op of d.operations) {
    if (!component(op.name)) bad("invalid public operation name");
    if (
      Object.values(op.parameters).some((p) => p.pathSegment !== undefined) &&
      (op.response !== "raster" ||
        !pathPart(op.path.split("/")[1] ?? "") ||
        op.path.split("/").length < 3)
    )
      bad("dynamic paths require a raster response and literal directory");
    let path = op.path;
    for (const [key, parameter] of Object.entries(op.parameters)) {
      if (
        !component(key) ||
        /^(authorization|x-api-key|token|password|access_token|api_key|apikey|secret|path|url|host|origin|method|headers|scheme|port)$/i.test(
          key,
        ) ||
        (parameter.location === "path") !== path.includes(`{${key}}`)
      )
        bad("invalid parameter name, destination override, or path binding");
      if (
        parameter.minimum !== undefined &&
        parameter.minimum > parameter.maximum!
      )
        bad("minimum exceeds maximum");
      if (
        parameter.values &&
        parameter.location === "path" &&
        !parameter.values.every(pathPart)
      )
        bad("path enum contains an invalid path component");
      const sample = parameter.pathSegment
        ? "x"
        : (parameter.values?.[0] ?? String(parameter.minimum));
      if (parameter.location === "path")
        path = path.replaceAll(`{${key}}`, sample);
    }
    if (
      Buffer.byteLength(path) > 512 ||
      !path.startsWith("/") ||
      !path.slice(1).split("/").every(pathPart)
    )
      bad("resolved sample is not a bounded native public path");
  }
}

/** Internal shared declaration checks; file existence waits for actual assets. */
export function nativeSemantics(
  m: Omit<DashboardManifest, "files" | "digest"> & {
    files?: DashboardManifest["files"];
  },
  inventory = true,
): void {
  unique(
    m.connections.map((c) => c.alias),
    "$manifest.connections",
  );
  if (m.connections.filter((c) => c.publicHTTP !== undefined).length > 8)
    fail(
      "native_validation",
      "$manifest.connections",
      "native provisioning permits at most eight public HTTP connections",
    );
  m.connections.forEach((c, index) => {
    const field = `$manifest.connections[${index}]`;
    if (
      (c.serviceCalls !== undefined || c.cameraEntities !== undefined) &&
      c.alias !== "home"
    )
      fail(
        "native_validation",
        field,
        "Home Assistant capabilities require alias home",
      );
    unique(
      (c.serviceCalls ?? []).map((g) => g.domain + "." + g.service),
      field + ".serviceCalls",
    );
    for (const g of c.serviceCalls ?? []) {
      if (
        (!g.entityIds.length && g.allowUntargeted !== true) ||
        g.entityIds.some((id) =>
          id.split(".").some((part) => part.length > 128),
        )
      )
        fail(
          "native_validation",
          field + ".serviceCalls",
          "invalid native service grant",
        );
    }
    publicRead(c, index);
  });
  if (
    /password|secret|token|api[_-]?key|bearer/.test(
      m.dashboardId + m.name + m.entrypoint,
    )
  )
    fail(
      "credential_leak",
      "$manifest",
      "native metadata credential heuristic rejected the package",
    );
  if (inventory) {
    unique(
      m.files!.map((f) => f.path),
      "$manifest.files",
    );
    let size = 0;
    for (const [index, f] of m.files!.entries()) {
      pathIdentity(f.path, `$manifest.files[${index}].path`);
      if (f.bytes > 50 * 1024 * 1024 - size)
        fail(
          "size_limit",
          "$manifest.files",
          "expanded package exceeds 50 MiB",
        );
      size += f.bytes;
    }
  }
  pathIdentity(m.entrypoint, "$manifest.entrypoint");
  if (inventory && !m.files!.some((f) => f.path === m.entrypoint))
    fail(
      "missing_entrypoint",
      "$manifest.entrypoint",
      "entrypoint is absent from the computed inventory",
    );
  const activation = m.deviceBehavior?.temporaryActivation;
  if (activation) {
    const states = [activation.activeState, activation.inactiveState];
    if (
      states.some(
        (s) => Buffer.byteLength(s) > 128 || /[\p{Cc}\p{Cf}]/u.test(s),
      ) ||
      states[0].normalize("NFC") === states[1].normalize("NFC")
    )
      fail(
        "native_validation",
        "$manifest.deviceBehavior.temporaryActivation",
        "native states must differ and contain bounded non-control UTF-8",
      );
    unique(
      [
        activation.idAttribute,
        activation.startedAtAttribute,
        activation.expiresAtAttribute,
      ],
      "$manifest.deviceBehavior.temporaryActivation",
    );
  }
  const pages = m.pages ?? [
    { id: "default", name: m.name, path: m.entrypoint },
  ];
  unique(
    pages.map((p) => p.id),
    "$manifest.pages",
  );
  const pageIds = new Set(pages.map((p) => p.id));
  if (!pageIds.has(m.defaultPageId ?? pages[0].id))
    fail(
      "native_validation",
      "$manifest.defaultPageId",
      "unknown default page",
    );
  for (const p of pages) {
    pathIdentity(p.path, "$manifest.pages.path");
    if (inventory && !m.files!.some((f) => f.path === p.path))
      fail(
        "native_validation",
        "$manifest.pages",
        "page is absent from the inventory",
      );
  }
  unique(
    (m.eventRules ?? []).map((r) => r.id),
    "$manifest.eventRules",
  );
  for (const [index, r] of (m.eventRules ?? []).entries()) {
    const field = `$manifest.eventRules[${index}]`;
    const bad = (detail: string): never =>
      fail("native_validation", field, detail);
    if (
      !pageIds.has(r.defaults.pageId) ||
      r.allowedPageIds.some((id) => !pageIds.has(id))
    )
      bad("event rule refers to an unknown page");
    if (
      (r.defaults.returnBehavior === "conditionClear" ||
        r.allowedReturnBehaviors.includes("conditionClear")) &&
      !r.condition
    )
      bad("conditionClear requires a condition");
    if (
      Object.keys(r.source.parameters).some(
        (k) =>
          !k.length ||
          Array.from(k).length > 128 ||
          ["authorization", "x-api-key", "token", "password"].includes(
            k.toLowerCase(),
          ),
      )
    )
      bad("invalid native event parameter key");
    const connection = m.connections.find((c) => c.alias === r.source.alias);
    if (
      !connection?.operations?.some(
        (o) =>
          o.name === r.source.operation &&
          o.kind === (r.source.mode === "live" ? "ws" : "http"),
      )
    )
      bad("event source operation is not declared");
    if (
      r.source.refreshOperation !== undefined &&
      !m.connections
        .find((c) => c.alias === (r.source.refreshAlias ?? r.source.alias))
        ?.operations?.some(
          (o) => o.name === r.source.refreshOperation && o.kind === "http",
        )
    )
      bad("refresh operation is not declared");
    if (r.source.mode === "poll" && !r.condition)
      bad("polling requires a condition");
    if (!r.condition && !r.payload?.occurredAt)
      bad("event rules without a condition require occurredAt");
  }
}
