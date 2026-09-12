(function () {
  const forecast = {
    latitude: 37.7749,
    longitude: -122.4194,
    timezone: "America/Los_Angeles",
    current: { time: "2026-09-12T12:00", temperature_2m: 18.4, weather_code: 2, wind_speed_10m: 12 },
    daily: {
      time: ["2026-09-12", "2026-09-13", "2026-09-14"],
      weather_code: [2, 3, 61],
      temperature_2m_max: [21, 19.5, 17.2],
      temperature_2m_min: [14, 13.2, 12.8]
    }
  };
  globalThis.screenpunk = {
    connections: {
      request: async () => ({ statusCode: 200, body: forecast, stale: false, fetchedAt: Date.now() }),
      subscribe: () => () => {}
    },
    state: {
      get: async () => null,
      set: async () => {},
      remove: async () => {}
    },
    runtime: { ready() {}, onStatus() { return () => {}; } }
  };
})();
