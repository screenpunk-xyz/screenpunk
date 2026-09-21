import { useState, type ComponentProps, type ReactNode } from 'react';
import * as Dialog from '@radix-ui/react-dialog';
import * as Tabs from '@radix-ui/react-tabs';
import * as Select from '@radix-ui/react-select';
import { ArrowLeft, ArrowRight, Check, ChevronDown, X } from 'lucide-react';
import { Bar, BarChart, Line, LineChart, ResponsiveContainer, XAxis, YAxis } from 'recharts';
import { flexRender, getCoreRowModel, getSortedRowModel, getFilteredRowModel, useReactTable, type ColumnDef, type SortingState } from '@tanstack/react-table';
import useEmblaCarousel from 'embla-carousel-react';
import { motion, useReducedMotion } from 'motion/react';
import { useRuntimeStatus } from '@screenpunk/react';
import './theme.css';

// shadcn Card/Button source adapted to static CSS and 44px targets; see NOTICE.txt.
export function Card({className='', ...props}: ComponentProps<'div'>) { return <div data-slot="card" className={`sp-card ${className}`} {...props}/>; }
export function Button({className='', type='button', ...props}: ComponentProps<'button'>) { return <button type={type} data-slot="button" className={`sp-button ${className}`} {...props}/>; }
export function Input({className='', ...props}: ComponentProps<'input'>) { return <input className={`sp-input ${className}`} {...props}/>; }
export function TabGroup({tabs}: {tabs:{id:string; label:string; content:ReactNode}[]}) { return <Tabs.Root defaultValue={tabs[0]?.id}><Tabs.List className="sp-row" aria-label="Views">{tabs.map(t=><Tabs.Trigger className="sp-button" value={t.id} key={t.id}>{t.label}</Tabs.Trigger>)}</Tabs.List>{tabs.map(t=><Tabs.Content key={t.id} value={t.id}>{t.content}</Tabs.Content>)}</Tabs.Root>; }
export function InfoDialog({title,children}: {title:string;children:ReactNode}) { return <Dialog.Root><Dialog.Trigger asChild><Button>{title}</Button></Dialog.Trigger><Dialog.Portal><Dialog.Overlay className="sp-overlay"/><Dialog.Content className="sp-dialog"><Dialog.Title>{title}</Dialog.Title><Dialog.Description asChild><div>{children}</div></Dialog.Description><Dialog.Close asChild><Button aria-label="Close dialog"><X aria-hidden/> Close</Button></Dialog.Close></Dialog.Content></Dialog.Portal></Dialog.Root>; }
export function Choice({label,value,onChange,options}: {label:string;value:string;onChange:(v:string)=>void;options:string[]}) { return <Select.Root value={value} onValueChange={onChange}><Select.Trigger className="sp-button" aria-label={label}><Select.Value/><Select.Icon><ChevronDown aria-hidden/></Select.Icon></Select.Trigger><Select.Portal><Select.Content className="sp-select" position="item-aligned"><Select.Viewport>{options.map(o=><Select.Item className="sp-option" value={o} key={o}><Select.ItemText>{o}</Select.ItemText><Select.ItemIndicator><Check aria-hidden/></Select.ItemIndicator></Select.Item>)}</Select.Viewport></Select.Content></Select.Portal></Select.Root>; }
export function TrendChart({data,kind='line',label}: {data:{name:string;value:number}[];kind?:'line'|'bar';label:string}) {
  const axes=<><XAxis dataKey="name" tick={{fill:'currentColor'}}/><YAxis tick={{fill:'currentColor'}}/></>;
  return <figure aria-label={label}><figcaption>{label}</figcaption><div className="sp-chart"><ResponsiveContainer width="100%" height="100%">{kind==='bar'?<BarChart data={data}>{axes}<Bar dataKey="value" fill="currentColor" isAnimationActive={false}/></BarChart>:<LineChart data={data}>{axes}<Line dataKey="value" stroke="currentColor" isAnimationActive={false}/></LineChart>}</ResponsiveContainer></div><details><summary>Chart data</summary><table><thead><tr><th>Label</th><th>Value</th></tr></thead><tbody>{data.map((d,i)=><tr key={i}><td>{d.name}</td><td>{d.value}</td></tr>)}</tbody></table></details></figure>;
}
export function DataTable<T>({data,columns}: {data:T[];columns:ColumnDef<T,any>[]}) {
  const [sorting,setSorting]=useState<SortingState>([]); const [globalFilter,setGlobalFilter]=useState('');
  const table=useReactTable({data,columns,state:{sorting,globalFilter},onSortingChange:setSorting,onGlobalFilterChange:setGlobalFilter,getCoreRowModel:getCoreRowModel(),getSortedRowModel:getSortedRowModel(),getFilteredRowModel:getFilteredRowModel()});
  return <div className="sp-table"><Input aria-label="Filter rows" placeholder="Filter rows" value={globalFilter} onChange={e=>setGlobalFilter(e.target.value)}/><table><thead>{table.getHeaderGroups().map(g=><tr key={g.id}>{g.headers.map(h=><th key={h.id} aria-sort={h.column.getIsSorted()==='asc'?'ascending':h.column.getIsSorted()==='desc'?'descending':'none'}><Button disabled={!h.column.getCanSort()} onClick={h.column.getToggleSortingHandler()}>{flexRender(h.column.columnDef.header,h.getContext())}</Button></th>)}</tr>)}</thead><tbody>{table.getRowModel().rows.map(r=><tr key={r.id}>{r.getVisibleCells().map(c=><td key={c.id}>{flexRender(c.column.columnDef.cell,c.getContext())}</td>)}</tr>)}</tbody></table></div>;
}
export function Carousel({children}: {children:ReactNode[]}) {
  const [ref,api]=useEmblaCarousel({loop:false});
  return <section aria-label="Component carousel" onKeyDown={e=>{if(e.key==='ArrowRight')api?.scrollNext();if(e.key==='ArrowLeft')api?.scrollPrev();}}><div className="sp-carousel" ref={ref}><div className="sp-slides">{children.map((c,i)=><div className="sp-slide" key={i}>{c}</div>)}</div></div><div className="sp-row"><Button aria-label="Previous slide" onClick={()=>api?.scrollPrev()}><ArrowLeft aria-hidden/></Button><Button aria-label="Next slide" onClick={()=>api?.scrollNext()}><ArrowRight aria-hidden/></Button></div></section>;
}
export function Reveal({children}: {children:ReactNode}) { const {active}=useRuntimeStatus(); const reduce=useReducedMotion(); return <motion.div initial={false} animate={{opacity:active?1:0.65}} transition={{duration:reduce||!active?0:0.2}}>{children}</motion.div>; }
export { Activity, ChartLine, Globe, RefreshCw, Layers, Search, Sun, Moon } from 'lucide-react';
