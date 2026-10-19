import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { ScreenpunkProvider, usePublicRead, useScreenPreferences, useScreenReady } from '@screenpunk/react';
import { Activity, Button, Card, Choice, DataTable, InfoDialog, RefreshCw, TrendChart } from '@screenpunk/ui';
import { fixture, parseQuakes, type Feed } from './data';
const defaults = { schemaVersion: 1, mode: 'Fixture' };
function decode(saved: unknown): typeof defaults {
  if (!saved || typeof saved !== 'object' || Array.isArray(saved)) throw new Error('Saved preferences need migration');
  const value = saved as Partial<typeof defaults>;
  if (value.schemaVersion !== 1 || (value.mode !== undefined && !['Fixture', 'Live'].includes(value.mode))) throw new Error('Saved preference schema is unsupported; existing data retained');
  return { ...defaults, ...value };
}
function App() {
  useScreenReady();
  const prefs = useScreenPreferences('earthquakes.preferences.v1', defaults, decode);
  const mode = prefs.phase === 'ready' ? prefs.value.mode : 'Fixture';
  const setMode = (mode: string) => { void prefs.save({ ...prefs.value, mode }).catch(() => undefined); };
  const {result,refresh}=usePublicRead<Feed>('earthquakes','day',{},mode==='Live');
  let rows=fixture; let message='Synthetic sample • no live requests'; let invalid=false;
  if(mode==='Live') {
    rows=[]; message=`Live data: ${result.state}`;
    if('data' in result && result.data) { try { rows=parseQuakes(result.data); } catch {invalid=true;message='Live response could not be read';} }
    if('code' in result && result.code) message+=` (${result.code})`;
  }
  return <main><div className="sp-badge">Screenpunk / public data</div><h1><Activity aria-hidden/> Earth in motion</h1><div className="sp-row"><fieldset disabled={!prefs.editable}><Choice label="Data source" value={mode} onChange={setMode} options={['Fixture','Live']}/></fieldset><Button disabled={mode!=='Live'} onClick={refresh}><RefreshCw aria-hidden/> Refresh</Button><InfoDialog title="About this screen">Magnitude 2.5+ earthquakes from the USGS past-day feed. Live mode requires an approved Screenpunk connection. Fixture mode uses synthetic records.</InfoDialog></div><p role="status">{prefs.error ?? (prefs.saving ? 'Saving preferences…' : `Durable preferences: ${prefs.phase}`)}</p><p role="status" className={invalid?'sp-error':'sp-muted'}>{message}</p><div className="sp-grid"><Card><div className="sp-badge">Events</div><h2>{rows.length}</h2><p>{mode==='Fixture'?'Synthetic records':'Reported in the past day'}</p></Card><Card><div className="sp-badge">Largest magnitude</div><h2>{rows.length?Math.max(...rows.map(r=>r.magnitude)).toFixed(1):'—'}</h2><p>{mode==='Fixture'?'Example only':'USGS public feed'}</p></Card></div><Card><TrendChart label="Magnitude by event" data={rows.slice(0,20).map((r,i)=>({name:String(i+1),value:r.magnitude}))}/><DataTable data={rows} columns={[{accessorKey:'place',header:'Location'},{accessorKey:'magnitude',header:'Magnitude'},{accessorKey:'time',header:'Time (UTC)'}]}/>{!rows.length&&<p>No events to display.</p>}</Card></main>;
}
createRoot(document.getElementById('root')!).render(<StrictMode><ScreenpunkProvider><App/></ScreenpunkProvider></StrictMode>);
