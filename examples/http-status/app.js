(function () {
  var POLL_MS = 15000;
  var timer = 0;

  function el(id) {
    return document.getElementById(id);
  }

  function setText(id, text) {
    var node = el(id);
    if (node) node.textContent = text;
  }

  function setHidden(id, hidden) {
    var node = el(id);
    if (node) node.hidden = hidden;
  }

  function readingValue(result) {
    if (result && typeof result === "object" && "value" in result) return result.value;
    return result;
  }

  function temperatureOf(reading) {
    if (reading && typeof reading === "object" && reading.temperatureC != null) {
      return reading.temperatureC;
    }
    return reading;
  }

  function paint(reading, stale) {
    var temp = temperatureOf(reading);
    setText("temperature", temp == null ? "—" : String(temp) + "°C");
    setHidden("stale", !stale);
    var status = el("status");
    if (status) {
      status.className = stale ? "stale" : "ok";
      status.textContent = stale ? "Showing last reading" : "Live";
    }
  }

  function showFault() {
    var status = el("status");
    if (status) {
      status.className = "error";
      status.textContent = "Status unavailable";
    }
  }

  async function refresh(sdk) {
    try {
      var result = await sdk.connections.request("status", "getStatus", {});
      var stale = !!(result && result.stale);
      var value = readingValue(result);
      paint(value, stale);
      if (!stale) await sdk.state.set("lastReading", value);
    } catch (_err) {
      var cached = await sdk.state.get("lastReading");
      if (cached) paint(cached, true);
      else showFault();
    }
  }

  async function start() {
    var sdk = globalThis.screenpunk;
    if (!sdk) return;
    var cached = await sdk.state.get("lastReading");
    if (cached) paint(cached, true);
    await refresh(sdk);
    sdk.runtime.ready();
    sdk.runtime.onStatus(function (status) {
      var node = el("native-status");
      if (!node) return;
      var label = status && typeof status === "object" && status.message ? String(status.message) : "";
      node.textContent = label;
      node.hidden = !label;
    });
    timer = setInterval(function () {
      refresh(sdk);
    }, POLL_MS);
    if (timer && typeof timer.unref === "function") timer.unref();
  }

  var task = start();
  globalThis.screenpunkExample = {
    start: start,
    task: task,
    stop: function () {
      clearInterval(timer);
    }
  };
})();
