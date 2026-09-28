/* Calendar access is selected by the owner in native Settings. No tokens here. */
const status = document.querySelector('#status');
const list = document.querySelector('#events');
function eventDate(event) {
  const start = event.start || {};
  // All-day dates are local calendar dates, not UTC timestamps.
  return start.dateTime ? new Date(start.dateTime) : new Date((start.date || '1970-01-01') + 'T00:00:00');
}
async function refresh() {
  try {
    const start = new Date(); start.setHours(0, 0, 0, 0);
    const end = new Date(start); end.setDate(end.getDate() + 7);
    const result = await screenpunk.connections.request('googleCalendar', 'events', {
      timeMin: start.toISOString(), timeMax: end.toISOString()
    });
    const events = result.value.events.slice().sort((a, b) => eventDate(a) - eventDate(b));
    list.replaceChildren();
    for (const event of events.slice(0, 40)) {
      const row = document.createElement('li');
      const time = document.createElement('time');
      const title = document.createElement('strong');
      const date = eventDate(event);
      time.textContent = date.toLocaleDateString(undefined, { weekday: 'short', month: 'short', day: 'numeric' }) +
        (event.start.date ? ' · All day' : ' · ' + date.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' }));
      title.textContent = event.summary;
      row.append(time, title);
      if (event.location) { const location = document.createElement('small'); location.textContent = event.location; row.append(location); }
      list.append(row);
    }
    status.textContent = result.stale ? 'Offline · showing recently loaded events' : events.length ? 'Next seven days' : 'No upcoming events';
  } catch {
    // Do not leave previously displayed private events visible after revocation.
    list.replaceChildren();
    status.textContent = 'Calendar unavailable. Check Google Calendar in device Settings.';
  } finally { setTimeout(refresh, 60000); }
}
refresh();
