import { useEffect, useId, useMemo, useRef, useState } from 'react'

/**
 * Runs a third-party widget snippet (e.g. a Travelpayouts search form) inside a sandboxed iframe.
 *
 * The snippet is arbitrary script, so it must not share Trypr's origin: without `allow-same-origin` the frame
 * cannot read the app's DOM, storage or cookies. Links and forms inside it may open new tabs (popups escape the
 * sandbox so the partner's page works normally). The frame reports its content height so it fits without scrollbars.
 */
export default function WidgetEmbed({ html, title, minHeight = 160 }: { html: string; title: string; minHeight?: number }) {
  const frameId = useId()
  const ref = useRef<HTMLIFrameElement>(null)
  const [height, setHeight] = useState(minHeight)

  const doc = useMemo(
    () => `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<script>(function(){
/* The frame has an opaque origin, so real storage and cookies throw. Many partner scripts use them; give them
   in-memory stand-ins so they run (nothing persists, and nothing of Trypr's is reachable). */
function mem(){var d={};return{getItem:function(k){return Object.prototype.hasOwnProperty.call(d,k)?d[k]:null},setItem:function(k,v){d[k]=String(v)},removeItem:function(k){delete d[k]},clear:function(){d={}},key:function(i){return Object.keys(d)[i]||null},get length(){return Object.keys(d).length}}}
['localStorage','sessionStorage'].forEach(function(n){try{void window[n]}catch(e){try{Object.defineProperty(window,n,{value:mem(),configurable:true})}catch(_){}}});
try{void document.cookie}catch(e){var jar={};try{Object.defineProperty(document,'cookie',{configurable:true,get:function(){return Object.keys(jar).map(function(k){return k+'='+jar[k]}).join('; ')},set:function(s){var p=String(s).split(';')[0],i=p.indexOf('=');if(i>0)jar[p.slice(0,i).trim()]=p.slice(i+1)}})}catch(_){}}
})()</script>
<base target="_blank"><style>html,body{margin:0;padding:0;overflow:hidden;background:transparent;font-family:system-ui,sans-serif}</style></head>
<body><div id="w">${html}</div>
<script>(function(){var id=${JSON.stringify(frameId)};
var w=document.getElementById('w');
function send(){parent.postMessage({trypWidget:id,height:Math.ceil(Math.max(w.getBoundingClientRect().height,w.scrollHeight))+6},'*')}
if(window.ResizeObserver){new ResizeObserver(send).observe(document.getElementById('w'))}
addEventListener('load',send);setTimeout(send,800);setTimeout(send,2500)})()</script></body></html>`,
    [html, frameId],
  )

  useEffect(() => {
    const onMessage = (e: MessageEvent) => {
      // A sandboxed frame has an opaque origin, so identify it by window identity and our per-instance id instead.
      if (e.source !== ref.current?.contentWindow || e.data?.trypWidget !== frameId) return
      const h = Number(e.data.height)
      if (Number.isFinite(h)) setHeight(Math.min(1400, Math.max(minHeight, h)))
    }
    window.addEventListener('message', onMessage)
    return () => window.removeEventListener('message', onMessage)
  }, [frameId, minHeight])

  return (
    <iframe
      ref={ref}
      title={title}
      srcDoc={doc}
      sandbox="allow-scripts allow-popups allow-popups-to-escape-sandbox allow-forms"
      loading="lazy"
      style={{ width: '100%', height, border: 0, display: 'block', colorScheme: 'light' }}
    />
  )
}
