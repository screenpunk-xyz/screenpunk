(function () {
  const model = globalThis.TheaterModel;
  const sdk = globalThis.screenpunk;
  let snapshot = { lights: [], scenes: [], media: [] };
  let timer = 0;
  let unsubscribe = null;
  let readySent = false;
  let connectionUnavailable = true;

  const els = {
    lights: document.getElementById("lights"),
    scenes: document.getElementById("scenes"),
    media: document.getElementById("media"),
    lightsEmpty: document.getElementById("lights-empty"),
    scenesEmpty: document.getElementById("scenes-empty"),
    mediaEmpty: document.getElementById("media-empty"),
    stale: document.getElementById("stale"),
    events: document.getElementById("events"),
    error: document.getElementById("error"),
    updated: document.getElementById("updated")
  };

  function markReady() {
    if (readySent) return;
    readySent = true;
    if (sdk && typeof sdk.runtime?.ready === "function") {
      sdk.runtime.ready();
    }
  }

  function button(label, options) {
    const node = document.createElement("button");
    node.type = "button";
    node.textContent = label;
    if (options.className) node.className = options.className;
    if (options.pressed != null) node.setAttribute("aria-pressed", options.pressed ? "true" : "false");
    node.disabled = Boolean(options.disabled);
    if (options.disabled) node.title = "Unavailable on this installation";
    node.addEventListener("click", options.onClick);
    return node;
  }

  function render() {
    els.lights.replaceChildren(
      ...snapshot.lights.map((light) =>
        button(light.on ? `${light.name} on` : `${light.name} off`, {
          pressed: light.on,
          disabled: connectionUnavailable || light.unavailable,
          onClick: () => callWrite(light.on ? "lightOff" : "lightOn", model.lightParameters(light.entityId))
        })
      )
    );
    els.scenes.replaceChildren(
      ...snapshot.scenes.map((scene) =>
        button(scene.name, {
          className: "secondary",
          disabled: connectionUnavailable || scene.unavailable,
          onClick: () => callWrite("sceneOn", model.sceneParameters(scene.entityId))
        })
      )
    );
    els.media.replaceChildren(
      ...snapshot.media.map((player) => {
        const wrap = document.createElement("div");
        wrap.className = "stack";
        wrap.append(
          button(player.playing ? `Pause ${player.name}` : `Play ${player.name}`, {
            disabled: connectionUnavailable || player.unavailable,
            onClick: () => callWrite("mediaPlayPause", model.mediaParameters(player.entityId))
          })
        );
        if (player.sources.length) {
          const select = document.createElement("select");
          select.id = `${player.entityId}-source`;
          select.name = `${player.entityId}-source`;
          select.setAttribute("aria-label", `${player.name} source`);
          select.disabled = connectionUnavailable || player.unavailable;
          for (const source of player.sources) {
            const option = document.createElement("option");
            option.value = source;
            option.textContent = source;
            option.selected = source === player.source;
            select.append(option);
          }
          select.addEventListener("change", () => {
            callWrite("selectSource", model.mediaParameters(player.entityId, { source: select.value }));
          });
          wrap.append(select);
        }
        const slider = document.createElement("input");
        slider.type = "range";
        slider.min = "0";
        slider.max = "100";
        slider.step = "1";
        slider.value = String(Math.round((player.volume || 0) * 100));
        slider.id = `${player.entityId}-volume`;
        slider.name = `${player.entityId}-volume`;
        slider.disabled = connectionUnavailable || player.unavailable;
        slider.setAttribute("aria-label", `${player.name} volume`);
        slider.addEventListener("change", () => {
          callWrite(
            "volumeSet",
            model.mediaParameters(player.entityId, { volume_level: String(Number(slider.value) / 100) })
          );
        });
        wrap.append(slider);
        return wrap;
      })
    );
    els.lightsEmpty.hidden = snapshot.lights.length > 0;
    els.scenesEmpty.hidden = snapshot.scenes.length > 0;
    els.mediaEmpty.hidden = snapshot.media.length > 0;
  }

  async function configured() {
    if (!sdk?.state || typeof sdk.state.get !== "function") return {};
    const value = await sdk.state.get("entities");
    return value && typeof value === "object" ? value : {};
  }

  async function refresh() {
    if (!sdk || typeof sdk.connections?.request !== "function") {
      els.error.hidden = false;
      els.error.textContent = "Host SDK is not available. Native Offline stays host-owned.";
      markReady();
      return;
    }
    try {
      const raw = await sdk.connections.request("home", "getStates", {});
      const unwrapped = model.unwrapResult(raw);
      snapshot = model.parseTheater(unwrapped.data, await configured());
      connectionUnavailable = unwrapped.stale;
      els.stale.hidden = !unwrapped.stale;
      els.error.hidden = true;
      if (unwrapped.fetchedAt) {
        els.updated.textContent = `Updated ${new Date(unwrapped.fetchedAt).toLocaleString()}`;
      }
      render();
    } catch (error) {
      connectionUnavailable = true;
      render();
      els.error.hidden = false;
      els.error.textContent = "Required states read failed. Last data is kept when the host has a cache.";
      if (error && /permission_required/.test(String(error.message))) {
        els.error.textContent = "Home Assistant grant is missing or denied.";
      }
    } finally {
      markReady();
    }
  }

  async function callWrite(operation, parameters) {
    if (!sdk?.connections?.request || connectionUnavailable) return;
    els.error.hidden = true;
    try {
      await sdk.connections.request("home", operation, model.assertSafeParameters(parameters));
      await refresh();
    } catch {
      els.error.hidden = false;
      els.error.textContent = "That action was not accepted. Unavailable entities stay disabled.";
    }
  }

  function listen() {
    if (!sdk?.connections?.subscribe) {
      els.events.hidden = false;
      return;
    }
    try {
      unsubscribe = sdk.connections.subscribe("homeEvents", "subscribeStates", {}, (message) => {
        snapshot = model.applyStateChanged(snapshot, model.unwrapResult(message).data ?? message);
        render();
      });
    } catch {
      els.events.hidden = false;
    }
  }

  function start() {
    refresh();
    listen();
    timer = globalThis.setInterval(refresh, model.POLL_SECONDS * 1000);
  }

  markReady();
  start();
  globalThis.TheaterApp = { refresh, callWrite };
})();
