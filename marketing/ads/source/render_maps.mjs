// Renders real OpenStreetMap maps (OpenFreeMap vector tiles via MapLibre) to PNG with headless Chrome over CDP.
// Usage: node render_maps.mjs jobs.json   jobs: [{out, w, h, bounds:[w,s,e,n] | center+zoom, pad, maxZoom, line:[[lon,lat]..], pins:[{lon,lat,n,dark}], style}]
import { spawn } from 'node:child_process'
import { readFileSync, writeFileSync, mkdirSync, mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname } from 'node:path'

const jobs = JSON.parse(readFileSync(process.argv[2], 'utf8'))
const HERE = new URL('.', import.meta.url).pathname
const tmp = mkdtempSync(`${tmpdir()}/maps-`)
const PORT = 9400 + Math.floor(Math.random() * 300)
const page_html = `<!doctype html><html><head><meta charset="utf-8"><link rel="stylesheet" href="file://${HERE}maplibre/maplibre-gl.css">
<style>html,body{margin:0;padding:0;overflow:hidden;font-family:Fredoka,sans-serif}#m{position:absolute;inset:0}
.pin{width:54px;height:54px;border-radius:50%;background:#2c9cc0;border:5px solid #fff;color:#fff;display:grid;place-items:center;font:600 28px/1 Fredoka,Nunito,sans-serif;box-shadow:0 6px 16px rgba(30,20,10,.4)}
.pin.dark{background:#2f2a26}.pin.sm{width:42px;height:42px;font-size:22px;border-width:4px}</style></head>
<body><div id="m"></div><script src="file://${HERE}maplibre/maplibre-gl.js"></script></body></html>`
writeFileSync(`${tmp}/map.html`, page_html)

const chrome = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', [
  '--headless=new', `--remote-debugging-port=${PORT}`, `--user-data-dir=${tmp}/profile`, '--hide-scrollbars', '--no-first-run',
  '--allow-file-access-from-files', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist', '--window-size=1200,1200', `file://${tmp}/map.html`,
], { stdio: 'ignore' })
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
let targets
for (let i = 0; i < 60 && !targets?.find?.((t) => t.type === 'page'); i++) { await sleep(250); try { targets = await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json() } catch {} }
const ws = new WebSocket(targets.find((t) => t.type === 'page').webSocketDebuggerUrl)
await new Promise((r) => ws.addEventListener('open', r))
let id = 0; const pending = new Map()
ws.addEventListener('message', (e) => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id) } })
const send = (method, params = {}) => new Promise((res, rej) => { const i = ++id; pending.set(i, (m) => (m.error ? rej(new Error(`${method}: ${m.error.message}`)) : res(m.result))); ws.send(JSON.stringify({ id: i, method, params })) })
await send('Page.enable'); await send('Runtime.enable')
await sleep(800)

const DRAW = (job) => `(async () => {
  const job = ${JSON.stringify(job)};
  document.querySelectorAll('.maplibregl-marker').forEach((e) => e.remove());
  if (window.__map) { window.__map.remove(); document.getElementById('m').innerHTML = '' }
  const map = window.__map = new maplibregl.Map({ container: 'm', style: 'https://tiles.openfreemap.org/styles/' + (job.style || 'liberty'), interactive: false, attributionControl: false,
    fadeDuration: 0, preserveDrawingBuffer: true, center: job.center || [0, 0], zoom: job.zoom ?? 2, pixelRatio: 1 });
  await new Promise((r) => map.once('load', r));
  map.resize();
  if (job.bounds) map.fitBounds([[job.bounds[0], job.bounds[1]], [job.bounds[2], job.bounds[3]]], { padding: job.pad ?? 60, maxZoom: job.maxZoom ?? 16, duration: 0 });
  if (job.line && job.line.length > 1) {
    map.addSource('r', { type: 'geojson', data: { type: 'Feature', geometry: { type: 'LineString', coordinates: job.line } } });
    map.addLayer({ id: 'r-case', type: 'line', source: 'r', layout: { 'line-cap': 'round', 'line-join': 'round' }, paint: { 'line-color': '#fff', 'line-width': (job.lineWidth || 7) + 6, 'line-opacity': .9 } });
    map.addLayer({ id: 'r', type: 'line', source: 'r', layout: { 'line-cap': 'round', 'line-join': 'round' }, paint: { 'line-color': '#e0622a', 'line-width': job.lineWidth || 7, 'line-dasharray': job.dash === false ? [1, 0] : [1.6, 1.4] } });
  }
  const pins = job.pins || [];
  const px = pins.map((p) => { const q = map.project([p.lon, p.lat]); return [q.x, q.y] });
  const cur = px.map((q) => [...q]);
  if (job.declutter) {
    const min = (job.small ? 42 : 54) + 6;
    for (let k = 0; k < 120; k++) for (let i = 0; i < cur.length; i++) for (let j = i + 1; j < cur.length; j++) {
      let dx = cur[j][0] - cur[i][0], dy = cur[j][1] - cur[i][1], d = Math.hypot(dx, dy);
      if (d >= min) continue;
      if (d < 0.01) { dx = 1; dy = ((i + j) % 2 ? 0.4 : -0.4); d = Math.hypot(dx, dy) }
      const push = (min - d) / 2, ux = dx / d, uy = dy / d;
      cur[i][0] -= ux * push; cur[i][1] -= uy * push; cur[j][0] += ux * push; cur[j][1] += uy * push;
    }
  }
  pins.forEach((p, i) => {
    const el = document.createElement('div'); el.className = 'pin' + (p.dark ? ' dark' : '') + (job.small ? ' sm' : ''); el.textContent = p.n;
    new maplibregl.Marker({ element: el, offset: [cur[i][0] - px[i][0], cur[i][1] - px[i][1]] }).setLngLat([p.lon, p.lat]).addTo(map);
  });
  await new Promise((r) => setTimeout(r, 300));
  const t = Date.now();
  while (Date.now() - t < 40000) { if (map.loaded() && map.areTilesLoaded()) break; await new Promise((r) => setTimeout(r, 250)) }
  await new Promise((r) => setTimeout(r, 700));
  return map.areTilesLoaded();
})()`

for (const job of jobs) {
  await send('Emulation.setDeviceMetricsOverride', { width: job.w, height: job.h, deviceScaleFactor: 1, mobile: false })
  await sleep(250)
  const r = await send('Runtime.evaluate', { expression: DRAW(job), awaitPromise: true, returnByValue: true })
  if (r.exceptionDetails) { console.error('FAIL', job.out, r.exceptionDetails.exception?.description ?? r.exceptionDetails.text); continue }
  const shot = await send('Page.captureScreenshot', { format: 'png' })
  mkdirSync(dirname(job.out), { recursive: true })
  writeFileSync(job.out, Buffer.from(shot.data, 'base64'))
  console.log('map', job.out, 'tilesLoaded=', r.result.value)
}
ws.close(); chrome.kill()
process.exit(0)
