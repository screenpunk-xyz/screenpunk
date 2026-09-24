export interface Feed { features: { id: string; properties: { mag: number | null; place: string | null; time: number } }[] }
export const fixture=[{place:'Sample ridge',magnitude:3.2,time:'2026-01-01 08:00'},{place:'Sample coast',magnitude:4.1,time:'2026-01-01 09:15'},{place:'Sample valley',magnitude:2.8,time:'2026-01-01 10:30'}];
export function parseQuakes(value: unknown) {
  const feed=value as Feed;
  if(!feed || !Array.isArray(feed.features)) throw Error('Malformed feed');
  return feed.features.map(f=>{
    if(!f?.properties || !Number.isFinite(f.properties.time) || (f.properties.mag!==null&&!Number.isFinite(f.properties.mag))) throw Error('Malformed event');
    return {place:f.properties.place??'Unknown location',magnitude:f.properties.mag??0,time:new Date(f.properties.time).toISOString().slice(0,16).replace('T',' ')};
  });
}
