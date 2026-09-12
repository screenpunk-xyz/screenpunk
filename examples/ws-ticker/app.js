(function () {
  function el(id) {
    return document.getElementById(id);
  }

  function setText(id, text) {
    var node = el(id);
    if (node) node.textContent = text;
  }

  function tickValue(message) {
    if (message && typeof message === "object" && "value" in message) return message.value;
    return message;
  }

  async function start() {
    var sdk = globalThis.screenpunk;
    if (!sdk) return;
    var last = await sdk.state.get("lastTick");
    if (last != null) setText("tick", String(tickValue(last)));
    var stop = sdk.connections.subscribe("ticker", "ticks", {}, function (message) {
      var value = tickValue(message);
      setText("tick", String(value));
      setText("stale", message && message.stale ? "Showing last tick" : "");
      sdk.state.set("lastTick", value);
    });
    sdk.runtime.ready();
    sdk.runtime.onStatus(function (status) {
      var node = el("native-status");
      if (!node) return;
      var label = status && typeof status === "object" && status.message ? String(status.message) : "";
      node.textContent = label;
      node.hidden = !label;
    });
    globalThis.screenpunkExample = { start: start, stop: stop, task: Promise.resolve() };
  }

  var task = start();
  globalThis.screenpunkExample = { start: start, task: task };
})();
