(function (root) {
  const POLL_SECONDS = 2;
  const MAX_AGE_SECONDS = POLL_SECONDS * 2 + 15;
  const LIGHT_LIMIT = 8;
  const SCENE_LIMIT = 6;
  const MEDIA_LIMIT = 4;

  const AUTH_OVERRIDE_KEYS = [
    "authorization",
    "Authorization",
    "x-api-key",
    "X-Api-Key",
    "token",
    "password",
    "access_token",
    "api_key",
    "apikey",
    "secret"
  ];

  function nowMs(clock) {
    if (clock && typeof clock.now === "function") return clock.now();
    if (root.screenpunkClock && typeof root.screenpunkClock.now === "function") {
      return root.screenpunkClock.now();
    }
    return Date.now();
  }

  function assertSafeParameters(parameters) {
    for (const key of Object.keys(parameters ?? {})) {
      if (AUTH_OVERRIDE_KEYS.includes(key)) {
        throw new Error("permission_required");
      }
    }
    return parameters;
  }

  function unwrapResult(result) {
    if (result == null) return { data: null, stale: false, fetchedAt: null, statusCode: 0 };
    let value = result;
    if (typeof value === "string") {
      try {
        value = JSON.parse(value);
      } catch {
        return { data: value, stale: false, fetchedAt: null, statusCode: 0 };
      }
    }
    if (typeof value === "object" && value !== null && Object.prototype.hasOwnProperty.call(value, "value")) {
      const nested = unwrapResult(value.value);
      return { ...nested, stale: value.stale === true || nested.stale };
    }
    if (typeof value === "object" && value !== null && Object.prototype.hasOwnProperty.call(value, "body")) {
      let data = value.body;
      if (typeof data === "string") {
        try {
          data = JSON.parse(data);
        } catch {
          /* keep string */
        }
      }
      return {
        data,
        stale: Boolean(value.stale),
        fetchedAt: value.fetchedAt ?? null,
        statusCode: Number(value.statusCode ?? 0)
      };
    }
    return {
      data: value,
      stale: Boolean(value.stale),
      fetchedAt: value.fetchedAt ?? null,
      statusCode: Number(value.statusCode ?? 0)
    };
  }

  function asEntities(raw) {
    const payload = Array.isArray(raw) ? raw : unwrapResult(raw).data;
    if (!Array.isArray(payload)) throw new Error("validation_failed");
    return payload;
  }

  function isUnavailable(state) {
    const value = String(state ?? "").toLowerCase();
    return value === "unavailable" || value === "unknown";
  }

  function domainOf(entityId) {
    const id = String(entityId ?? "");
    const dot = id.indexOf(".");
    return dot === -1 ? "" : id.slice(0, dot);
  }

  function friendlyName(entity) {
    return String(entity?.attributes?.friendly_name || entity?.entity_id || "");
  }

  function preferConfigured(entities, configuredIds, domain, limit) {
    const configured = new Set((configuredIds ?? []).filter((id) => domainOf(id) === domain));
    const matching = entities.filter((entity) => domainOf(entity.entity_id) === domain);
    const selected = configured.size
      ? matching.filter((entity) => configured.has(entity.entity_id))
      : matching;
    return selected.slice(0, limit);
  }

  function parseTheater(raw, configured) {
    const entities = asEntities(raw);
    const lights = preferConfigured(entities, configured?.lights, "light", LIGHT_LIMIT).map((entity) => ({
      entityId: entity.entity_id,
      name: friendlyName(entity),
      on: String(entity.state) === "on",
      unavailable: isUnavailable(entity.state)
    }));
    const scenes = preferConfigured(entities, configured?.scenes, "scene", SCENE_LIMIT).map((entity) => ({
      entityId: entity.entity_id,
      name: friendlyName(entity),
      unavailable: isUnavailable(entity.state)
    }));
    const media = preferConfigured(entities, configured?.media, "media_player", MEDIA_LIMIT).map((entity) => {
      const attrs = entity.attributes ?? {};
      return {
        entityId: entity.entity_id,
        name: friendlyName(entity),
        playing: String(entity.state) === "playing",
        paused: String(entity.state) === "paused",
        unavailable: isUnavailable(entity.state),
        volume: Number(attrs.volume_level ?? 0),
        source: attrs.source ? String(attrs.source) : "",
        sources: Array.isArray(attrs.source_list) ? attrs.source_list.map(String) : []
      };
    });
    return { lights, scenes, media };
  }

  function applyStateChanged(snapshot, message) {
    const event = message?.event ?? message;
    const data = event?.data ?? event;
    const next = data?.new_state;
    if (!next?.entity_id) return snapshot;
    const domain = domainOf(next.entity_id);
    const copy = {
      lights: snapshot.lights.map((item) => ({ ...item })),
      scenes: snapshot.scenes.map((item) => ({ ...item })),
      media: snapshot.media.map((item) => ({ ...item }))
    };
    if (domain === "light") {
      copy.lights = copy.lights.map((item) =>
        item.entityId === next.entity_id
          ? {
              ...item,
              on: String(next.state) === "on",
              unavailable: isUnavailable(next.state)
            }
          : item
      );
    }
    if (domain === "scene") {
      copy.scenes = copy.scenes.map((item) =>
        item.entityId === next.entity_id
          ? { ...item, unavailable: isUnavailable(next.state) }
          : item
      );
    }
    if (domain === "media_player") {
      const attrs = next.attributes ?? {};
      copy.media = copy.media.map((item) =>
        item.entityId === next.entity_id
          ? {
              ...item,
              playing: String(next.state) === "playing",
              paused: String(next.state) === "paused",
              unavailable: isUnavailable(next.state),
              volume: Number(attrs.volume_level ?? item.volume),
              source: attrs.source ? String(attrs.source) : item.source,
              sources: Array.isArray(attrs.source_list) ? attrs.source_list.map(String) : item.sources
            }
          : item
      );
    }
    return copy;
  }

  function lightParameters(entityId, turnOn) {
    return assertSafeParameters({
      entity_id: entityId,
      ...(turnOn ? {} : {})
    });
  }

  function sceneParameters(entityId) {
    return assertSafeParameters({ entity_id: entityId });
  }

  function mediaParameters(entityId, extras) {
    return assertSafeParameters({ entity_id: entityId, ...(extras ?? {}) });
  }

  const api = {
    POLL_SECONDS,
    MAX_AGE_SECONDS,
    LIGHT_LIMIT,
    SCENE_LIMIT,
    MEDIA_LIMIT,
    AUTH_OVERRIDE_KEYS,
    nowMs,
    assertSafeParameters,
    unwrapResult,
    asEntities,
    isUnavailable,
    domainOf,
    parseTheater,
    applyStateChanged,
    lightParameters,
    sceneParameters,
    mediaParameters
  };

  root.TheaterModel = api;
  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }
})(typeof globalThis !== "undefined" ? globalThis : this);
