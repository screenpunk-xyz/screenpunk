(function () {
  const model = globalThis.WeatherModel;
  const sdk = globalThis.screenpunk;
  const location = {
    latitude: model.SAMPLE_LATITUDE,
    longitude: model.SAMPLE_LONGITUDE,
    place: model.SAMPLE_PLACE
  };

  const els = {
    condition: document.getElementById("condition"),
    place: document.getElementById("place"),
    temp: document.getElementById("temp"),
    summary: document.getElementById("summary"),
    wind: document.getElementById("wind"),
    days: document.getElementById("days"),
    stale: document.getElementById("stale"),
    error: document.getElementById("error"),
    updated: document.getElementById("updated")
  };

  let timer = 0;
  let readySent = false;

  function markReady() {
    if (readySent) return;
    readySent = true;
    if (sdk && typeof sdk.runtime?.ready === "function") {
      sdk.runtime.ready();
    }
  }

  function weekday(date) {
    const parsed = new Date(`${date}T12:00:00`);
    if (Number.isNaN(parsed.getTime())) return date;
    return parsed.toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric" });
  }

  function render(snapshot, meta) {
    els.place.textContent = snapshot.place;
    els.condition.textContent = snapshot.condition;
    els.temp.textContent = model.formatTemp(snapshot.temperatureC);
    els.summary.textContent = snapshot.condition;
    els.wind.textContent = Number.isFinite(snapshot.windKmh)
      ? `Wind ${Math.round(snapshot.windKmh)} km/h`
      : "";
    els.days.replaceChildren(
      ...snapshot.days.map((day) => {
        const article = document.createElement("article");
        article.className = "day";
        article.innerHTML = `<div><strong></strong><p></p></div><p class="range"></p>`;
        article.querySelector("strong").textContent = weekday(day.date);
        article.querySelector("p").textContent = day.label;
        article.querySelector(".range").textContent =
          `${model.formatTemp(day.highC)} / ${model.formatTemp(day.lowC)}`;
        return article;
      })
    );
    els.stale.hidden = !meta.stale;
    els.error.hidden = !meta.error;
    els.error.textContent = meta.error ?? "";
    if (meta.fetchedAt) {
      const when = new Date(meta.fetchedAt);
      els.updated.textContent = `Updated ${when.toLocaleString()}`;
    }
  }

  async function refresh() {
    if (!sdk || typeof sdk.connections?.request !== "function") {
      els.error.hidden = false;
      els.error.textContent = "Host SDK is not available. Native Offline stays host-owned.";
      markReady();
      return;
    }
    try {
      const stored = sdk.state && typeof sdk.state.get === "function" ? await sdk.state.get("location") : null;
      const nextLocation = stored && typeof stored === "object" ? { ...location, ...stored } : location;
      const parameters = model.assertSafeParameters(model.forecastQuery(nextLocation));
      const raw = await sdk.connections.request("weather", "getForecast", parameters);
      const unwrapped = model.unwrapResult(raw);
      const snapshot = model.parseForecast(unwrapped.data, nextLocation);
      render(snapshot, {
        stale: unwrapped.stale,
        fetchedAt: unwrapped.fetchedAt ?? model.nowMs(),
        error: ""
      });
    } catch (error) {
      els.error.hidden = false;
      els.error.textContent = "Required weather read failed. Last data is kept when the host has a cache.";
      els.stale.hidden = false;
      if (error && /permission_required/.test(String(error.message))) {
        els.error.textContent = "Weather grant is missing or denied.";
      }
    } finally {
      markReady();
    }
  }

  function start() {
    refresh();
    timer = globalThis.setInterval(refresh, model.POLL_SECONDS * 1000);
    if (sdk && typeof sdk.runtime?.onStatus === "function") {
      sdk.runtime.onStatus(() => {});
    }
  }

  markReady();
  start();

  globalThis.WeatherApp = { refresh, start };
})();
