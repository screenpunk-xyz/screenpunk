import { useEffect, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { ScreenpunkProvider, useScreenPreferences, useScreenReady } from '@screenpunk/react';
import { Activity, Button, Card, Carousel, Choice, DataTable, InfoDialog, Input, Reveal, TabGroup, TrendChart } from '@screenpunk/ui';
const defaults = { schemaVersion: 1, count: 0, period: 'Day', text: '' };
function decode(saved: unknown): typeof defaults {
  if (!saved || typeof saved !== 'object' || Array.isArray(saved)) throw new Error('Saved preferences need migration');
  const value = saved as Partial<typeof defaults>;
  if (value.schemaVersion !== 1) throw new Error('Saved preference schema is unsupported; existing data retained');
  if (value.count !== undefined && (!Number.isSafeInteger(value.count) || value.count < 0)) throw new Error('Invalid saved count');
  if (value.period !== undefined && !['Day', 'Week', 'Month'].includes(value.period)) throw new Error('Invalid saved period');
  if (value.text !== undefined && (typeof value.text !== 'string' || value.text.length > 1024)) throw new Error('Invalid saved text');
  return { ...defaults, ...value };
}
function Gallery() {
  useScreenReady();
  const prefs = useScreenPreferences('gallery.preferences.v1', defaults, decode);
  const [text, setText] = useState('');
  useEffect(() => setText(prefs.value.text), [prefs.value.text]);
  const save = (next: typeof defaults) => { void prefs.save(next).catch(() => undefined); };
  return <main><div className="sp-badge">Screenpunk / component gallery</div>
    <h1>Built for your screen.</h1><p className="sp-muted">Local components. Preferences stay on this device.</p>
    <p role="status">{prefs.error ?? (prefs.saving ? 'Saving…' : prefs.phase === 'ready' ? 'Saved preferences restored. Save text before leaving.' : `Durable preferences: ${prefs.phase}`)}</p>
    <div className="sp-grid"><Card><h2><Activity aria-hidden/> Controls</h2>
      <fieldset disabled={!prefs.editable}><div className="sp-row">
        <Button onClick={() => save({ ...prefs.value, count: prefs.value.count + 1 })}>Count {prefs.value.count}</Button>
        <Choice label="Period" value={prefs.value.period} onChange={period => save({ ...prefs.value, period })} options={['Day', 'Week', 'Month']}/>
        <Input aria-label="Example input" placeholder="Type something" maxLength={1024} value={text} onChange={event => setText(event.target.value)}/>
        <Button onClick={() => save({ ...prefs.value, text })}>Save text</Button>
      </div></fieldset><InfoDialog title="Open dialog">Keyboard focus stays inside this dialog and returns to its trigger when closed.</InfoDialog></Card>
      <Card><h2>Tabs</h2><TabGroup tabs={[{id:'one',label:'Overview',content:<p>Reusable UI, one theme.</p>},{id:'two',label:'Details',content:<p>Arrow keys move between tabs.</p>}]}/></Card>
    </div><Card><TrendChart kind="bar" label="Sample trend" data={[{name:'Mon',value:4},{name:'Tue',value:7},{name:'Wed',value:5}]}/></Card>
    <div className="sp-grid"><Card><h2>Sortable table</h2><DataTable data={[{name:'North',value:12},{name:'South',value:7}]} columns={[{accessorKey:'name',header:'Region'},{accessorKey:'value',header:'Value'}]}/></Card>
      <Card><h2>Touch carousel</h2><Carousel>{[<p key="a">One finger moves this carousel.</p>,<p key="b">Two fingers switch Screenpunk screens.</p>]}</Carousel><Reveal><p>Motion respects reduced motion and inactivity.</p></Reveal></Card>
    </div></main>;
}
createRoot(document.getElementById('root')!).render(<ScreenpunkProvider><Gallery/></ScreenpunkProvider>);
