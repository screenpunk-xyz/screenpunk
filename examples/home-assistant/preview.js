(function () {
  const states = [
    { entity_id: "light.theater", state: "on", attributes: { friendly_name: "Theater" } },
    { entity_id: "light.sconce", state: "unavailable", attributes: { friendly_name: "Sconce" } },
    { entity_id: "scene.movie", state: "on", attributes: { friendly_name: "Movie" } },
    {
      entity_id: "media_player.theater",
      state: "playing",
      attributes: {
        friendly_name: "Theater",
        volume_level: 0.4,
        source: "Apple TV",
        source_list: ["Apple TV", "Blu-ray", "Tuner"]
      }
    }
  ];
  globalThis.screenpunk = {
    connections: {
      async request(alias, operation, parameters) {
        if (operation === "getStates") {
          return { statusCode: 200, body: states, stale: false, fetchedAt: Date.now() };
        }
        if (operation === "lightOff" && parameters.entity_id === "light.theater") {
          states[0].state = "off";
        }
        if (operation === "lightOn" && parameters.entity_id === "light.theater") {
          states[0].state = "on";
        }
        if (operation === "mediaPlayPause") {
          states[3].state = states[3].state === "playing" ? "paused" : "playing";
        }
        if (operation === "volumeSet") {
          states[3].attributes.volume_level = Number(parameters.volume_level);
        }
        if (operation === "selectSource") {
          states[3].attributes.source = parameters.source;
        }
        return { statusCode: 200, body: [], stale: false, fetchedAt: Date.now() };
      },
      subscribe() {
        return () => {};
      }
    },
    state: {
      get: async () => null,
      set: async () => {},
      remove: async () => {}
    },
    runtime: { ready() {}, onStatus() { return () => {}; } }
  };
})();
