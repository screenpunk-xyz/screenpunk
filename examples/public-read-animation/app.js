/* Synthetic provider contract. Run the debug native fixture for a deterministic preview. */
const status = document.querySelector('#status');
const image = document.querySelector('#frame');
const abort = new AbortController();
const frames = [];
let playing = true, index = 0, timer;
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const read = (operation, parameters = {}) => screenpunk.connections.read('publicData', operation, parameters, { signal: abort.signal });
document.querySelector('#play').onclick = () => {
  playing = !playing;
  document.querySelector('#play').textContent = playing ? 'Pause' : 'Play';
};
(async () => {
  try {
    const timeline = await read('timeline');
    if (!timeline.data || !Array.isArray(timeline.data.frames)) throw new Error(timeline.code || 'Timeline unavailable');
    for (const timestamp of timeline.data.frames.slice(0, 2)) {
      await delay(150); // Respect native throttling; handle retryAfterSeconds in real providers.
      const result = await read('frame', { timestamp: String(timestamp) });
      if (result.state === 'unavailable') { status.textContent = 'No image coverage for this frame'; continue; }
      if (!result.resourceURL) throw new Error(result.code || 'Frame unavailable');
      const loaded = new Image(); loaded.src = result.resourceURL; await loaded.decode();
      frames.push({ timestamp, result, loaded });
    }
    if (frames.length < 2) throw new Error('Two frames are required for this example');
    image.src = frames[0].result.resourceURL;
    timer = setInterval(() => {
      if (playing) { index = (index + 1) % frames.length; image.src = frames[index].result.resourceURL; }
    }, 600); // Playback uses local handles, with no refetches.
    await delay(1200);
    const refreshed = await read('timeline');
    status.textContent = refreshed.state === 'stale' ? 'Stale timeline · replaying 2 cached frames' : 'Fresh timeline · playing 2 cached frames';
    document.body.dataset.publicReadState = refreshed.state;
    document.body.dataset.loadedFrames = String(frames.length);
    screenpunk.runtime.ready();
  } catch (error) { status.textContent = `Unavailable: ${error.message}`; }
})();
addEventListener('pagehide', () => {
  abort.abort(); clearInterval(timer);
  for (const frame of frames) screenpunk.connections.release(frame.result.resourceURL);
  screenpunk.dispose();
}, { once: true });
