import { useLayoutEffect } from 'react';
// Keep react-remove-scroll's event isolation; replace only its injected stylesheet.
// Nested overlays share the lock and restore the original inline values once.
let locks=0;
let saved: {overflow:string;paddingRight:string;position:string;attribute:string|null}|undefined;
export function RemoveScrollBar({noRelative=false}: {noRelative?:boolean;gapMode?:string}) {
 useLayoutEffect(()=>{
  const body=document.body;
  if(locks++===0){
   saved={overflow:body.style.overflow,paddingRight:body.style.paddingRight,position:body.style.position,attribute:body.getAttribute('data-scroll-locked')};
   const gap=Math.max(0,innerWidth-document.documentElement.clientWidth);
   body.style.paddingRight=`${parseFloat(getComputedStyle(body).paddingRight)+gap}px`;
   body.style.overflow='hidden';if(!noRelative)body.style.position='relative';body.setAttribute('data-scroll-locked','true');
  }
  return ()=>{if(--locks===0&&saved){body.style.overflow=saved.overflow;body.style.paddingRight=saved.paddingRight;body.style.position=saved.position;if(saved.attribute===null)body.removeAttribute('data-scroll-locked');else body.setAttribute('data-scroll-locked',saved.attribute);saved=undefined}};
 },[noRelative]);
 return null;
}
