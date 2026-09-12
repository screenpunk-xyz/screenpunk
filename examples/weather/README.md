# Weather example

Generic HTTP dashboard. The device calls the approved origin itself.
The Mac is not a runtime proxy. No OAuth, MQTT, or Screenpunk cloud.

## Provider

Documented provider: [Open-Meteo](https://open-meteo.com/) Forecast API.

Checked 2026-09-12:

- Data licence: [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)
- Attribution required: “Weather data by Open-Meteo.com”
- Terms: https://open-meteo.com/en/terms
- Free `api.open-meteo.com` is **non-commercial only**
- Commercial / distribution use needs a customer plan (`customer-api.open-meteo.com` + operator-owned `apikey`) or a self-hosted Open-Meteo instance

This package does **not** hard-code the free unauthenticated host. Grants are Mac-side. Operators enter the origin and any credential. CI uses `fixture/forecast.json` only.

## Location and polling

Sample coordinates in the package: `37.7749, -122.4194` (San Francisco), labeled as a sample. Override with dashboard state key `location`:

```json
{ "latitude": "46.9480", "longitude": "7.4474", "place": "Bern" }
```

Polling interval is 15 minutes (`WeatherModel.POLL_SECONDS`). Required max age is 1815 seconds (twice the interval plus the 15-second HTTP timeout). No write operations.

## Grant

Packages name alias `weather` / operation `getForecast` only.

| File | Use |
| --- | --- |
| `grants/fixture.json` | Loopback CI / local fixture (`lan`, insecure HTTP) |
| `grants/open-meteo-customer.json` | Public customer API. Host binding: query field `apikey` from Keychain |
| `grants/open-meteo-self-hosted.json` | Operator URL, no credential placement |

The page never sends `apikey`, `Authorization`, or other auth fields. Native placement resolves those.

## Brand

Codex guide tokens (canvas / surface / danger). Stacked v1 lockup from copied mark + wordmark SVGs. Native Offline ring stays host-owned.

## Validate

```sh
node --test examples/weather/test.mjs
./scripts/ci/linux.sh
```
