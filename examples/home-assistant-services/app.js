/* Replace these example entity IDs in both this file and manifest.serviceCalls. */
(() => {
  const sdk = globalThis.screenpunk;
  const status = document.getElementById('status');
  const controls = [
    { button: document.getElementById('color'), entity: 'light.example', domain: 'light', service: 'turn_on', data: { rgb_color: [255, 180, 100], transition: 1.5 } },
    { button: document.getElementById('temperature'), entity: 'climate.example', domain: 'climate', service: 'set_temperature', data: { temperature: 21 } }
  ];
  let busy = false;
  let healthy = false;
  const disable = () => controls.forEach(c => { c.button.disabled = true; });
  async function refresh() {
    if (busy) return;
    busy = true;
    disable();
    try {
      const result = await sdk.connections.request('home', 'getStates', {});
      healthy = !result.stale && Array.isArray(result.value);
      for (const control of controls) {
        const entity = healthy && result.value.find(s => s.entity_id === control.entity);
        control.button.disabled = !entity || ['unavailable', 'unknown'].includes(entity.state);
      }
      status.textContent = healthy ? 'Ready. Controls affect your Home Assistant devices.' : 'Offline. Controls are paused.';
    } catch {
      healthy = false;
      status.textContent = 'Connection unavailable. Controls are paused.';
    } finally { busy = false; }
  }
  for (const control of controls) control.button.addEventListener('click', async () => {
    if (busy || !healthy || control.button.disabled) return;
    busy = true;
    disable();
    try {
      await sdk.homeAssistant.callService({ domain: control.domain, service: control.service,
        target: { entity_id: control.entity }, serviceData: control.data });
      status.textContent = 'Sent.';
    } catch {
      healthy = false;
      status.textContent = 'Action failed. It will not be retried.';
    } finally { busy = false; }
    // Refresh only; never repeat the write, even after a timeout with an unknown outcome.
    await refresh();
  });
  if (!sdk?.homeAssistant?.callService) {
    status.textContent = 'Update Screenpunk to use these controls.';
    return;
  }
  sdk.runtime.ready();
  void refresh();
  setInterval(() => void refresh(), 15000);
})();
