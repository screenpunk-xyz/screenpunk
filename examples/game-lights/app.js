(() => {
  const entity = 'light.game_lights';
  const sdk = window.screenpunk;
  const get = id => document.getElementById(id);
  let busy = false, fresh = false, brightness = 59;
  let refreshTask = null, adjusting = false;
  function controls() { ['on','off','brightness'].forEach(id => { get(id).disabled = busy || !fresh; }); }
  function failure(error) { fresh = false; controls(); get('state').textContent = 'Connection unavailable'; get('status').textContent = 'Check Home Assistant and try again.' + (error?.code ? ' (' + error.code + ')' : ''); }
  async function readState() {
    try {
      if (!sdk?.connections) throw new Error('unavailable');
      const result = await sdk.connections.request('home','getStates',{});
      const light = Array.isArray(result.value) ? result.value.find(item => item.entity_id === entity) : null;
      fresh = !result.stale && !!light && ['on','off'].includes(light.state);
      if (!fresh) throw new Error('unavailable');
      document.body.dataset.on = String(light.state === 'on');
      get('state').textContent = light.state === 'on' ? 'Lights are on' : 'Lights are off';
      if (!adjusting && !busy) {
        if (Number.isFinite(light.attributes?.brightness)) brightness = light.attributes.brightness;
        get('brightness').value = String(brightness);
        get('level').textContent = Math.round(brightness / 255 * 100) + '%';
      }
      get('status').textContent = 'Live · Updated ' + new Date().toLocaleTimeString([], {hour:'numeric',minute:'2-digit',second:'2-digit'});
    } catch (error) { failure(error); }
    finally { controls(); }
  }
  function refresh() {
    if (refreshTask) return refreshTask;
    if (busy) return Promise.resolve();
    // Background reads retain the last usable controls and never interrupt a drag.
    refreshTask = readState().finally(() => { refreshTask = null; });
    return refreshTask;
  }
  async function change(operation, values = {}) {
    if (busy || !fresh) return;
    busy = true; controls();
    try {
      // The native bridge accepts one request at a time. Finish the current read
      // before sending this explicit action, and abandon it if that read failed.
      if (refreshTask) await refreshTask;
      if (fresh) await sdk.connections.request('home',operation,{entity_id:entity,...values});
    }
    catch (error) { failure(error); }
    finally { busy = false; controls(); }
    await refresh();
    setTimeout(refresh, 650);
  }
  get('on').onclick = () => change('lightOn', {brightness:String(brightness)});
  get('off').onclick = () => change('lightOff');
  get('brightness').onpointerdown = () => { adjusting = true; };
  get('brightness').oninput = () => { adjusting = true; get('level').textContent = Math.round(Number(get('brightness').value)/255*100)+'%'; };
  get('brightness').onchange = () => { adjusting = false; brightness = Number(get('brightness').value); return change('lightOn',{brightness:String(brightness)}); };
  get('brightness').onpointerup = get('brightness').onpointercancel = get('brightness').onblur = () => { adjusting = false; };
  refresh().finally(() => sdk?.runtime?.ready());
  setInterval(refresh,2000);
})();
