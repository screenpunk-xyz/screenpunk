import { StrictMode, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { ScreenpunkProvider, usePublicRead, useScreenReady } from '@screenpunk/react';
import { Activity, Button, Card, Choice, DataTable, InfoDialog, RefreshCw, TrendChart } from '@screenpunk/ui';
import { fixture, parseQuakes, type Feed } from './data';
function App() {
  useScreenReady();
  const [mode,setMode]=useState('Fixture');
  const {result,refresh}=usePublicRead<Feed>('earthquakes','day',{},mode==='Live');
  let rows=fixture; let message='Synthetic sample • no live requests'; let invalid=false;
  if(mode==='Live') {
    rows=[]; message=`Live data: ${result.state}`;
    if('data' in result && result.data) { try { rows=parseQuakes(result.data); } catch {invalid=true;message='Live response could not be read';} }
    if('code' in result && result.code) message+=` (${result.code})`;
  }
  return <main><div className="sp-badge">Screenpunk / public data</div><h1><Activity aria-hidden/> Earth in motion</h1><div className="sp-row"><Choice label="Data source" value={mode} onChange={setMode} options={['Fixture','Live']}/><Button disabled={mode!=='Live'} onClick={refresh}><RefreshCw aria-hidden/> Refresh</Button><InfoDialog title="About this screen">Magnitude 2.5+ earthquakes from the USGS past-day feed. Live mode requires an approved Screenpunk connection. Fixture mode uses synthetic records.</InfoDialog></div><p role="status" className={invalid?'sp-error':'sp-muted'}>{message}</p><div className="sp-grid"><Card><div className="sp-badge">Events</div><h2>{rows.length}</h2><p>{mode==='Fixture'?'Synthetic records':'Reported in the past day'}</p></Card><Card><div className="sp-badge">Largest magnitude</div><h2>{rows.length?Math.max(...rows.map(r=>r.magnitude)).toFixed(1):'—'}</h2><p>{mode==='Fixture'?'Example only':'USGS public feed'}</p></Card></div><Card><TrendChart label="Magnitude by event" data={rows.slice(0,20).map((r,i)=>({name:String(i+1),value:r.magnitude}))}/><DataTable data={rows} columns={[{accessorKey:'place',header:'Location'},{accessorKey:'magnitude',header:'Magnitude'},{accessorKey:'time',header:'Time (UTC)'}]}/>{!rows.length&&<p>No events to display.</p>}</Card></main>;
}
createRoot(document.getElementById('root')!).render(<StrictMode><ScreenpunkProvider><App/></ScreenpunkProvider></StrictMode>);
