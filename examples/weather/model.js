(function (root) {
  const POLL_SECONDS = 15 * 60;
  const MAX_AGE_SECONDS = POLL_SECONDS * 2 + 15;
  const SAMPLE_LATITUDE = "37.7749";
  const SAMPLE_LONGITUDE = "-122.4194";
  const SAMPLE_PLACE = "San Francisco (sample)";
  const ATTRIBUTION_TEXT = "Weather data by Open-Meteo.com";
  const ATTRIBUTION_URL = "https://open-meteo.com/";
  const LICENCE_URL = "https://creativecommons.org/licenses/by/4.0/";

  const WMO = {
    0: "Clear",
    1: "Mostly clear",
    2: "Partly cloudy",
    3: "Overcast",
    45: "Fog",
    48: "Rime fog",
    51: "Light drizzle",
    53: "Drizzle",
    55: "Heavy drizzle",
    56: "Freezing drizzle",
    57: "Freezing drizzle",
    61: "Light rain",
    63: "Rain",
    65: "Heavy rain",
    66: "Freezing rain",
    67: "Freezing rain",
    71: "Light snow",
    73: "Snow",
    75: "Heavy snow",
    77: "Snow grains",
    80: "Showers",
    81: "Showers",
    82: "Heavy showers",
    85: "Snow showers",
    86: "Snow showers",
    95: "Thunderstorm",
    96: "Thunderstorm",
    99: "Thunderstorm"
  };

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

  function forecastQuery(location) {
    const latitude = String(location?.latitude ?? SAMPLE_LATITUDE);
    const longitude = String(location?.longitude ?? SAMPLE_LONGITUDE);
    return {
      latitude,
      longitude,
      current: "temperature_2m,weather_code,wind_speed_10m",
      daily: "weather_code,temperature_2m_max,temperature_2m_min",
      timezone: "auto",
      forecast_days: "3"
    };
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

  function wmoLabel(code) {
    const numeric = Number(code);
    return WMO[numeric] ?? "Unknown";
  }

  function parseForecast(raw, location) {
    const payload = raw && raw.current ? raw : unwrapResult(raw).data;
    if (!payload || typeof payload !== "object" || !payload.current) {
      throw new Error("validation_failed");
    }
    const current = payload.current;
    const daily = payload.daily ?? {};
    const days = [];
    const times = Array.isArray(daily.time) ? daily.time : [];
    for (let i = 0; i < times.length && i < 3; i += 1) {
      days.push({
        date: String(times[i]),
        label: wmoLabel(daily.weather_code?.[i]),
        code: Number(daily.weather_code?.[i] ?? 0),
        highC: Number(daily.temperature_2m_max?.[i]),
        lowC: Number(daily.temperature_2m_min?.[i])
      });
    }
    return {
      place: location?.place ?? SAMPLE_PLACE,
      latitude: Number(payload.latitude ?? location?.latitude ?? SAMPLE_LATITUDE),
      longitude: Number(payload.longitude ?? location?.longitude ?? SAMPLE_LONGITUDE),
      timezone: String(payload.timezone ?? ""),
      observedAt: String(current.time ?? ""),
      temperatureC: Number(current.temperature_2m),
      windKmh: Number(current.wind_speed_10m),
      code: Number(current.weather_code ?? 0),
      condition: wmoLabel(current.weather_code),
      days,
      attribution: ATTRIBUTION_TEXT,
      attributionUrl: ATTRIBUTION_URL,
      licenceUrl: LICENCE_URL
    };
  }

  function formatTemp(value) {
    if (!Number.isFinite(value)) return "—";
    return `${Math.round(value)}°`;
  }

  const api = {
    POLL_SECONDS,
    MAX_AGE_SECONDS,
    SAMPLE_LATITUDE,
    SAMPLE_LONGITUDE,
    SAMPLE_PLACE,
    ATTRIBUTION_TEXT,
    ATTRIBUTION_URL,
    LICENCE_URL,
    AUTH_OVERRIDE_KEYS,
    nowMs,
    forecastQuery,
    assertSafeParameters,
    unwrapResult,
    wmoLabel,
    parseForecast,
    formatTemp
  };

  root.WeatherModel = api;
  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }
})(typeof globalThis !== "undefined" ? globalThis : this);
