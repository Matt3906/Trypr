// Drives a headless Chrome over CDP: builds the Western Uplands trip in the local app and screenshots it at 2x.
import { spawn } from 'node:child_process'
import { writeFileSync, mkdirSync } from 'node:fs'

const OUT = new URL('./capture/', import.meta.url).pathname // screenshots land here; copy capture/final.png to data/product.png
mkdirSync(OUT, { recursive: true })
const W = 1600, H = 1000, PORT = 9333
const chrome = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', [
  '--headless=new', `--remote-debugging-port=${PORT}`, `--user-data-dir=${OUT}profile`, '--hide-scrollbars',
  '--no-first-run', '--no-default-browser-check', `--window-size=${W},${H}`, 'about:blank',
], { stdio: 'ignore' })
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

let targets
for (let i = 0; i < 50 && !targets; i++) {
  await sleep(200)
  try { targets = await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json() } catch { /* starting */ }
}
const page = targets.find((t) => t.type === 'page')
const ws = new WebSocket(page.webSocketDebuggerUrl)
await new Promise((r) => ws.addEventListener('open', r))
let id = 0
const pending = new Map()
ws.addEventListener('message', (e) => {
  const m = JSON.parse(e.data)
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id) }
})
const send = (method, params = {}) => new Promise((resolve, reject) => {
  const i = ++id
  pending.set(i, (m) => (m.error ? reject(new Error(`${method}: ${m.error.message}`)) : resolve(m.result)))
  ws.send(JSON.stringify({ id: i, method, params }))
})
const js = async (expr) => {
  const r = await send('Runtime.evaluate', { expression: `(async () => { ${expr} })()`, awaitPromise: true, returnByValue: true })
  if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description ?? r.exceptionDetails.text)
  return r.result.value
}
const shot = async (name) => {
  const r = await send('Page.captureScreenshot', { format: 'png' })
  writeFileSync(`${OUT}${name}.png`, Buffer.from(r.data, 'base64'))
  console.log('shot', name)
}
const waitFor = async (cond, label, ms = 30000) => {
  const t = Date.now()
  while (Date.now() - t < ms) {
    if (await js(`return !!(${cond})`)) return
    await sleep(300)
  }
  await shot(`fail-${label}`)
  throw new Error(`timeout waiting for ${label}`)
}
// In-page helpers: click by visible text, set React-controlled inputs.
const HELPERS = `
window.__byText = (sel, text) => [...document.querySelectorAll(sel)].find((el) => el.offsetParent !== null && el.textContent.trim().includes(text));
window.__click = (sel, text) => { const el = window.__byText(sel, text); if (!el) throw new Error('no element ' + sel + ' ' + text); el.click(); return true };
window.__set = (el, value) => {
  const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
  Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, value);
  el.dispatchEvent(new Event('input', { bubbles: true })); el.dispatchEvent(new Event('change', { bubbles: true }));
};
window.__map = () => {
  if (window.__mapObj) return window.__mapObj;
  let el = document.querySelector('.gm-style');
  while (el) {
    const k = Object.keys(el).find((k) => k.startsWith('__reactFiber$'));
    for (let f = k && el[k]; f; f = f.return) for (let h = f.memoizedState; h; h = h.next) {
      const v = h.memoizedState;
      if (v && v.current instanceof google.maps.Map) return (window.__mapObj = v.current);
    }
    el = el.parentElement;
  }
  return null;
};
`

await send('Page.enable')
await send('Runtime.enable')
await send('Emulation.setDeviceMetricsOverride', { width: W, height: H, deviceScaleFactor: 2, mobile: false })
await send('Page.navigate', { url: 'http://localhost:5173/trip-builder' })
await sleep(3000)
await js(HELPERS)
await waitFor(`window.__byText('button', 'Hiking / Backpacking')`, 'start-dialog')

// Start dialog.
await js(`__click('button', 'Hiking / Backpacking')`)
await sleep(300)
await js(`__set(document.querySelector('input[placeholder="Trip name"]'), 'Western Uplands Loop')`)
await js(`const d = document.querySelectorAll('input[type=date]'); __set(d[0], '2026-11-06'); __set(d[1], '2026-11-10')`)
await js(`__click('button', 'Intermediate')`)
await js(`__click('button', 'Continue')`)
await sleep(800)

// Trailhead from search.
await js(`const i = document.querySelector('input[placeholder^="Search trailheads"]'); i.focus(); __set(i, 'Western Uplands')`)
await waitFor(`window.__byText('*', 'Western Uplands Backpacking Trail') && [...document.querySelectorAll('div,button,li')].some((e) => e.textContent.trim().startsWith('Western Uplands Backpacking Trail'))`, 'search')
await js(`[...document.querySelectorAll('div,button,li')].filter((e) => e.offsetParent && e.textContent.trim().startsWith('Western Uplands Backpacking Trail')).pop().click()`)
await waitFor(`window.__byText('button', 'Add to Trip')`, 'th-dialog')
await js(`const d = document.querySelector('[role=dialog]') || document.body; __set(d.querySelector('input[type=text], input:not([type])'), 'Western Uplands Trailhead')`)
await js(`__click('label', 'Waypoint')`)
await js(`__click('button', 'Add to Trip')`)
await sleep(2500)
await js(HELPERS)
await waitFor(`window.__map()`, 'map')

const CAMPS = [
  { name: 'Redwing #1', lat: 45.5466031, lng: -78.7725765 },
  { name: 'Brown #2', lat: 45.6067374, lng: -78.8512989 },
  { name: 'Islet #2', lat: 45.6282816, lng: -78.8838762, waypoint: true },
  { name: 'Pincher #3', lat: 45.5711782, lng: -78.8619434 },
  { name: 'Maggie 4', lat: 45.4962628, lng: -78.8637903 },
]
for (const c of CAMPS) {
  let opened = false
  for (let attempt = 0; attempt < 4 && !opened; attempt++) {
    await js(`const m = __map(); m.setZoom(15); m.setCenter({ lat: ${c.lat}, lng: ${c.lng} })`)
    await sleep(3500)
    const r = await js(`const d = __map().getDiv().getBoundingClientRect(); return { x: d.left + d.width / 2, y: d.top + d.height / 2 }`)
    for (const type of ['mouseMoved', 'mousePressed', 'mouseReleased']) {
      await send('Input.dispatchMouseEvent', { type, x: r.x, y: r.y - 1, button: 'left', clickCount: 1 })
    }
    await sleep(900)
    opened = await js(`return !!window.__byText('*', 'Add campsite to trip')`)
    if (!opened) await js(`const b = window.__byText('button', 'Cancel'); if (b) b.click()`)
  }
  if (!opened) { await shot(`fail-${c.name}`); throw new Error(`campsite dialog for ${c.name}`) }
  const name = await js(`const d = [...document.querySelectorAll('[role=dialog]')].pop() || document.body; return d.querySelector('input').value`)
  console.log('dialog for', name)
  if (c.waypoint) await js(`__click('label', 'Waypoint')`)
  await js(`__click('button', 'Add to Trip')`)
  await sleep(6000)
}

await js(`__click('button', 'Return to start')`)
await sleep(9000)
const total = await js(`return (document.body.innerText.match(/Total: [0-9.]+ km/) || [''])[0]`)
console.log('total', total)
// Scroll the destinations list back to the top and let the camera settle on the fitted route.
await js(`document.querySelectorAll('*').forEach((e) => { if (e.scrollTop > 0) e.scrollTop = 0 })`)
await sleep(3000)
await js(`const m = __map(); m.setCenter({ lat: 45.5485, lng: -78.828 }); m.panBy(-225, -72); const st = document.createElement("style"); st.textContent = ".map-load-btn{display:none!important}"; document.head.appendChild(st)`)
await sleep(4000)
await shot('final')
const proj = await js(`
  const m = __map(), d = m.getDiv().getBoundingClientRect(), b = m.getBounds(), ne = b.getNorthEast(), sw = b.getSouthWest();
  const px = (lat, lng) => ({ x: d.left + (lng - sw.lng()) / (ne.lng() - sw.lng()) * d.width, y: d.top + (ne.lat() - lat) / (ne.lat() - sw.lat()) * d.height });
  return { brown: px(45.6067374, -78.8512989), redwing: px(45.5466031, -78.7725765), maggie: px(45.4962628, -78.8637903), th: px(45.4632333, -78.7978506), pincher: px(45.5711782, -78.8619434), zoom: m.getZoom() }`)
console.log(JSON.stringify(proj))
ws.close()
chrome.kill()
