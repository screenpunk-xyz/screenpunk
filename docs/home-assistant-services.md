# Home Assistant service calls

Screenpunk's Mac canvas, native preview helper, and iOS/iPadOS runtime share the same native service authorization and HTTP runtime. The minimum device OS remains 16. Once these hosts are updated, adding ordinary Home Assistant controls or service parameters requires screen changes only.

## Declare services in the screen manifest

```json
{
  "alias": "home",
  "required": true,
  "operations": [
    {"name": "getStates", "kind": "http"},
    {"name": "callService", "kind": "http"}
  ],
  "serviceCalls": [
    {"domain": "light", "service": "turn_on", "entityIds": ["light.living_room"]},
    {"domain": "climate", "service": "set_temperature", "entityIds": ["climate.living_room"]}
  ]
}
```

Put this object in `connections`. Use `inspect_connection` with alias `home` and query `services:` for the live Home Assistant catalog, or `services:light` for one domain. The catalog contains the service descriptions and fields returned by that server. An ordinary query still finds entities and their capabilities. `describe_connection` and `get_help(topic: "home-assistant")` explain this contract.

Discovery is descriptive, not permission. The owner-approved screen revision supplies the service declarations. Native provisioning copies those declarations into the credential record bound to the owner, dashboard and revision. JavaScript cannot change that record. Duplicate service declarations and duplicate connection aliases are rejected.

## Call with structured service data

```js
const states = await screenpunk.connections.request('home', 'getStates', {});
if (!states.stale) {
  await screenpunk.homeAssistant.callService({
    domain: 'light',
    service: 'turn_on',
    target: {entity_id: 'light.living_room'},
    serviceData: {rgb_color: [255, 180, 100], transition: 1.5}
  });
}
```

`serviceData` is a JSON object: nested objects, arrays, strings, finite numbers, booleans, and null are preserved. The SDK rejects values JSON would silently change, such as undefined and non-finite numbers. Home Assistant validates service-specific parameters; Screenpunk has no action or parameter allowlist for this interface.

`target.entity_id` accepts one entity ID or a nonempty list, all present in that service's `entityIds`. Cross-domain services such as `homeassistant.turn_on` work with explicitly declared entity IDs. Wildcards, comma-separated IDs, area/device/label/floor targets and target overrides in top-level service data are rejected. To change the target set, update and apply the screen manifest.

For services that intentionally omit a target, such as a notification or a direct `script.my_script` invocation, declare `entityIds: []` and `allowUntargeted: true`, then omit `target` in the call. Targetless permission is separate from entity targeting. Service declarations authorize the **whole behavior** of that service, including scripts' downstream effects and services that ignore entity targets. They are not a sandbox around Home Assistant's internal behavior. Review that behavior when granting the service. Home Assistant always enforces the authenticated user's permissions.

## Wire and security contract

The convenience method uses the existing bridge method `connections.request`, alias `home`, operation `callService`, with `{call: JSON.stringify(call)}` as its string parameters. This preserves existing hosts' string-parameter handling and keeps structured JSON intact. Direct wire callers receive the same native validation.

- Exact domain/service identifiers form `/api/services/{domain}/{service}`. Callers cannot supply a native origin, path, headers, or credentials.
- Native code flattens the validated entity target into REST service data. The API follows Home Assistant's [REST service endpoint](https://developers.home-assistant.io/docs/api/rest/).
- Call JSON and serialized service bodies: at most 32 KiB each. Data: depth 12, 2,048 values, 8,192 UTF-8 bytes per string, 128 bytes per key. Declarations: up to 128 services and 128 entity IDs per service.
- Credentials remain in the native Keychain/provisioning channel; no token goes into a package or JavaScript. Existing destination validation, configured HTTP opt-in, normal TLS validation, and redirect denial remain in force.
- Writes require a successful state read in the same credential generation within 45 seconds. Failed reads mark cached state stale; permission denials clear it. Failed writes invalidate freshness. Concurrent requests remain bounded.
- Writes are never automatically queued, retried, or replayed. After a timeout the outcome can be unknown; refresh state and require a new user action. Cancellation or a changed owner/revision invalidates pending results.
- Success returns `{value: null, stale: false}`. Service response bodies are discarded to avoid exposing changed entities or service response data. Services requiring response-data mode are not supported by this initial write contract.

Screen UI should disable actions until fresh state arrives, for missing/unavailable entities, while a write is in flight, and on stale/error state. The runnable [example](../examples/home-assistant-services/) demonstrates color and thermostat controls. Replace its example entity IDs in both JavaScript and the manifest, regenerate the package inventory, and apply the new revision.

## Compatibility and installation

Screens without `serviceCalls` keep provisioning schema 1 and their existing named operations. This includes `mediaOn`, `mediaOff`, and `lightOn` with the JSON string `rgb_color` parameter. Color discovery attributes are retained.

Screens declaring `serviceCalls` use provisioning schema 2, and legacy aliases are constrained by those same service/target declarations. A legacy alias cannot bypass a new screen's scope. Omitting declarations never enables the new `callService` operation.

New devices advertise `home-assistant-services-v1`. The controller checks it before transferring new screens or credentials, and older provisioning decoders reject schema 2. Update the Mac app, bundled helper/MCP components, and device runtime together before applying a new-contract screen. No new OS requirement is introduced.
