// Native SDK is injected at document start. Do not replace its global.
const KEY = 'example.preferences.v1';
const form = document.querySelector('form');
const text = document.querySelector('input');
const message = document.querySelector('[role=status]');
const save = document.querySelector('button');
let ready = false, busy = false, generation = 0, lastMode = '';
const sdk = globalThis.screenpunk;
function report(value) { message.textContent = value; }
function decode(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value) ||
      value.schemaVersion !== 1 || (value.text !== undefined && typeof value.text !== 'string'))
    throw new Error('Saved schema needs migration; existing data retained');
  return { schemaVersion: 1, text: value.text ?? '' };
}
if (!sdk?.runtime?.onStatus || !sdk?.state?.get || !sdk?.state?.set || !sdk?.state?.remove) {
  report('Durable preferences unsupported. Editing disabled.');
} else sdk.runtime.onStatus(async status => {
  const mode = [status.active, status.persistentState, status.persistentStateWritable].join(':');
  if (mode === lastMode) return; lastMode = mode;
  const observed = ++generation; ready = false; text.disabled = true; save.disabled = true;
  if (status.persistentState !== 1) return report('Durable preferences unsupported. Editing disabled.');
  if (status.persistentStateWritable !== 1) return report('Durable preferences read-only. Editing disabled.');
  if (status.active !== true) return report('Waiting for the screen to become active.');
  try {
    const saved = await sdk.state.get(KEY);
    if (observed !== generation) return;
    text.value = saved === null ? '' : decode(saved).text;
    ready = true; text.disabled = busy; save.disabled = busy;
    report('Restored. Press Save to keep edits across updates.');
  } catch (error) {
    if (observed === generation) report('Preference read failed; existing data retained. ' + (error?.message ?? ''));
  }
});
form.addEventListener('submit', async event => {
  event.preventDefault();
  if (!ready || busy) return;
  const observed = generation; busy = true; save.disabled = true; text.disabled = true;
  report('Saving…');
  try {
    await sdk.state.set(KEY, decode({ schemaVersion: 1, text: text.value }));
    if (observed === generation) report('Saved on this device.');
  } catch (error) {
    if (observed === generation) report('Save failed; existing saved data was not replaced with defaults. ' + (error?.message ?? ''));
  } finally {
    busy = false; save.disabled = !ready; text.disabled = !ready;
  }
});
