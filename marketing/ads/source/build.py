"""Renders the Trypr ad set to PNG with headless Chrome. Usage: python3 -I build.py OUT_DIR [name ...]

Photos come from frontend/public/images and ~/Documents/Pictures/OutWest 25/LastCouple/Matthew;
map data (data/) is OpenStreetMap, routed by the app's own routers.
data/product.png is a real trip-builder screenshot taken by capture.mjs (needs the app running on localhost:5173).
Output names are flat; the folders one level up group them by how they are posted (see ../README.md).
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from mapsvg import MAP_CSS, fit_view, loop, svg, xy
import paddlesvg  # noqa: E402

REPO = '/Users/matt3906/Documents/Code/Trypr/Trypr'
IMG = f'file://{REPO}/frontend/public/images'
LOGO = f'file://{REPO}/images/TryprLogo.png'
CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'

BASE_CSS = '''
@font-face{font-family:Fredoka;src:url(FONTS/fredoka.woff2) format('woff2');font-weight:300 700}
@font-face{font-family:Nunito;src:url(FONTS/nunito.woff2) format('woff2');font-weight:200 1000}
*{box-sizing:border-box;margin:0;padding:0}
html,body{width:var(--w);height:var(--h);overflow:hidden}
body{font-family:Nunito,sans-serif;color:#2f2a26;background:#fbf5ea;position:relative;-webkit-font-smoothing:antialiased}
.display{font-family:Fredoka,sans-serif;font-weight:600;letter-spacing:-.01em;line-height:1.02}
.photo{position:absolute;inset:0;background-size:cover;background-position:center}
.glass{background:rgba(255,255,255,.62);backdrop-filter:blur(22px) saturate(180%);-webkit-backdrop-filter:blur(22px) saturate(180%);
  border:1.5px solid rgba(255,255,255,.75);box-shadow:inset 0 1px 0 rgba(255,255,255,.9),0 18px 48px rgba(74,56,40,.22),0 2px 6px rgba(74,56,40,.1)}
.glass-dark{background:rgba(42,32,26,.36);backdrop-filter:blur(18px) saturate(160%);-webkit-backdrop-filter:blur(18px) saturate(160%);
  border:1.5px solid rgba(255,255,255,.28);color:#fff}
.logo{position:absolute;background:url(LOGO) center/contain no-repeat}
.clay{color:#e78043}
.ocean{color:#2c9cc0}
.pill{display:inline-flex;align-items:center;gap:10px;border-radius:999px;font-weight:800}
.credit{position:absolute;font-size:15px;font-weight:700;opacity:.7}
'''.replace('LOGO', LOGO).replace('FONTS', f'file://{HERE}/fonts')

MODES = [('🚗', 'Road'), ('🚆', 'Rail'), ('✈️', 'Flight'), ('🥾', 'Hiking'), ('🛶', 'Paddle'), ('🚲', 'Bike')]
legs = loop['legs']
DAYS = [
    ('Redwing Lake', legs[0]['km']),
    ('Brown Lake', legs[1]['km']),
    ('Islet → Pincher Lake', round(legs[2]['km'] + legs[3]['km'], 1)),
    ('Maggie Lake', legs[4]['km']),
    ('Back to Hwy 60', legs[5]['km']),
]
TOTAL = round(sum(l['km'] for l in legs), 1)


def day_rows(size=30, pad=16):
    rows = []
    for i, (label, km) in enumerate(DAYS, 1):
        rows.append(f'''<div style="display:flex;align-items:center;gap:{pad}px;padding:{pad * 0.6:.0f}px 0;{'border-top:1.5px solid rgba(74,56,40,.1);' if i > 1 else ''}">
<div style="width:{size * 1.5:.0f}px;height:{size * 1.5:.0f}px;border-radius:50%;background:{'#2c9cc0' if i < 5 else '#2f2a26'};color:#fff;display:grid;place-items:center;font:600 {size * 0.8:.0f}px Fredoka,sans-serif">{i}</div>
<div style="flex:1;font-weight:800;font-size:{size}px">{label}</div>
<div style="font-weight:900;font-size:{size}px;color:#cf5a28">{km:.1f} km</div></div>''')
    return ''.join(rows)


def mode_pills(size=30, dark=False):
    cls = 'glass-dark' if dark else 'glass'
    return ''.join(f'<span class="pill {cls}" style="padding:{size * 0.45:.0f}px {size * 0.85:.0f}px;font-size:{size}px">{e} {n}</span>' for e, n in MODES)


ADS = {}

# 1. Road trip hook: Google Maps vs Trypr.
ADS['ig-01-google-maps'] = (1080, 1350, f'''
<div class="photo" style="background-image:url({IMG}/DSC_0042.jpg);background-position:50% 60%"></div>
<div style="position:absolute;inset:0;background:linear-gradient(180deg,rgba(30,22,16,.55) 0%,rgba(30,22,16,0) 34%,rgba(30,22,16,0) 52%,rgba(30,22,16,.82) 100%)"></div>
<div class="logo" style="left:44px;top:34px;width:230px;height:130px"></div>
<div style="position:absolute;left:72px;right:72px;top:190px;color:#fff">
  <div class="display" style="font-size:98px;text-shadow:0 4px 30px rgba(0,0,0,.35)">Google Maps<br>gets you there.</div>
</div>
<div style="position:absolute;left:72px;right:72px;bottom:96px;color:#fff">
  <div class="display" style="font-size:98px;color:#f5a46e;text-shadow:0 4px 30px rgba(0,0,0,.35)">Trypr plans<br>the whole trip.</div>
  <div style="margin-top:34px;display:flex;flex-wrap:wrap;gap:14px">{mode_pills(28, dark=True)}</div>
  <div style="margin-top:34px;font-size:30px;font-weight:800;opacity:.92">Every leg, every stop, every night · tryprtravel.com</div>
</div>
''')

# 2. Hiking: the real Western Uplands loop, routed by the app.
PANEL = (470, 40, 570, 1270)  # x, y, w, h of the map panel
ADS['ig-02-western-uplands'] = (1080, 1350, f'''
<div style="position:absolute;inset:0;background:radial-gradient(120% 80% at 0% 0%,#fff 0%,#fbf5ea 55%,#f3e6d2 100%)"></div>
<div style="position:absolute;left:{PANEL[0]}px;top:{PANEL[1]}px;width:{PANEL[2]}px;height:{PANEL[3]}px;border-radius:44px;overflow:hidden;
  box-shadow:0 24px 60px rgba(74,56,40,.22),0 2px 8px rgba(74,56,40,.1);border:6px solid #fff">{svg(vb=fit_view(PANEL[2] - 12, PANEL[3] - 12, 1.36), label_scale=0.62, route_width=6)}</div>
<div class="logo" style="left:36px;top:30px;width:250px;height:140px"></div>
<div style="position:absolute;left:60px;width:390px;top:200px">
  <div style="font-size:21px;font-weight:900;letter-spacing:.12em;color:#2c9cc0">BACKPACKING<br>ALGONQUIN PARK</div>
  <div class="display" style="font-size:78px;margin-top:16px">5 days.<br>{TOTAL} km.<br><span class="clay">Every night planned.</span></div>
</div>
<div class="glass" style="position:absolute;left:40px;width:410px;bottom:70px;border-radius:32px;padding:26px 26px 16px">
  <div style="font:600 30px Fredoka,sans-serif">Western Uplands Trail</div>
  <div style="font-size:19px;font-weight:700;color:#6e645b;margin:4px 0 8px">Full loop from Hwy 60</div>
  {day_rows(21, 12)}
</div>
<div class="credit" style="left:44px;bottom:30px;font-size:14px;color:#6e645b">Map data © OpenStreetMap contributors</div>
''')

# 3. Group planning features.
FEATURES = [('💬', 'Group chat', 'One thread per trip'), ('🎒', 'Packing lists', 'Nobody forgets the stove'),
            ('💸', 'Split costs', 'Who owes what, sorted'), ('🗺️', 'Shared itinerary', 'Everyone sees the plan')]
feat_cards = ''.join(f'''<div class="glass" style="border-radius:30px;padding:28px 30px">
<div style="font-size:52px">{e}</div><div style="font:600 36px Fredoka,sans-serif;margin-top:10px">{t}</div>
<div style="font-size:23px;font-weight:700;color:#6e645b;margin-top:4px">{s}</div></div>''' for e, t, s in FEATURES)
ADS['ig-03-together'] = (1080, 1350, f'''
<div class="photo" style="background-image:url({IMG}/DSC_0214.jpg);background-position:50% 40%"></div>
<div style="position:absolute;inset:0;background:linear-gradient(180deg,rgba(40,24,12,.5) 0%,rgba(40,24,12,0) 38%,rgba(40,24,12,.15) 60%,rgba(40,24,12,.55) 100%)"></div>
<div class="logo" style="left:44px;top:34px;width:230px;height:130px"></div>
<div style="position:absolute;left:72px;right:72px;top:196px;color:#fff">
  <div class="display" style="font-size:112px;text-shadow:0 4px 30px rgba(0,0,0,.3)">Plan it<br>together.</div>
  <div style="font-size:32px;font-weight:800;margin-top:22px;max-width:760px;text-shadow:0 2px 14px rgba(0,0,0,.35)">Invite friends to the trip and build it side by side.</div>
</div>
<div style="position:absolute;left:60px;right:60px;bottom:70px;display:grid;grid-template-columns:1fr 1fr;gap:22px">{feat_cards}</div>
''')

# 4. Founder story.
ADS['ig-04-founder'] = (1080, 1350, f'''
<div class="photo" style="background-image:url({IMG}/aboutUsPic.jpg);background-position:50% 30%"></div>
<div style="position:absolute;inset:0;background:linear-gradient(180deg,rgba(20,28,36,.0) 40%,rgba(20,28,36,.7) 100%)"></div>
<div class="glass" style="position:absolute;left:56px;right:56px;bottom:64px;border-radius:40px;padding:44px 48px">
  <div style="font-size:24px;font-weight:900;letter-spacing:.14em;color:#2c9cc0">MEET THE FOUNDER</div>
  <div class="display" style="font-size:72px;margin-top:12px">Built by a trip planner,<br><span class="clay">for trip planners.</span></div>
  <div style="font-size:29px;font-weight:700;color:#4a4039;margin-top:20px;line-height:1.38">I'm 19 and from Toronto. I plan every trip down to the night, and spreadsheets stopped cutting it, so I built the planner I wanted.</div>
  <div style="display:flex;align-items:center;justify-content:space-between;margin-top:26px">
    <div style="font-size:28px;font-weight:900;color:#cf5a28">tryprtravel.com</div>
    <div class="logo" style="position:relative;width:190px;height:96px"></div>
  </div>
</div>
''')

# 5. Story: every mode.
mode_rows = ''.join(f'<div class="glass" style="border-radius:28px;padding:22px 34px;display:flex;align-items:center;gap:22px;font:600 46px Fredoka,sans-serif"><span style="font-size:50px">{e}</span>{n}</div>' for e, n in MODES)
ADS['story-01-every-trip'] = (1080, 1920, f'''
<div class="photo" style="background-image:url({IMG}/DSC_0016.jpg);background-position:50% 50%"></div>
<div style="position:absolute;inset:0;background:linear-gradient(180deg,rgba(24,30,40,.62) 0%,rgba(24,30,40,.1) 30%,rgba(24,30,40,.1) 50%,rgba(24,30,40,.7) 100%)"></div>
<div class="logo" style="left:50%;top:150px;width:520px;height:290px;transform:translateX(-50%)"></div>
<div class="display" style="position:absolute;left:70px;right:70px;top:470px;text-align:center;color:#fff;font-size:104px;text-shadow:0 4px 30px rgba(0,0,0,.35)">Every kind of trip.<br><span style="color:#f5a46e">One planner.</span></div>
<div style="position:absolute;left:120px;right:120px;bottom:330px;display:grid;grid-template-columns:1fr 1fr;gap:20px">{mode_rows}</div>
<div class="pill" style="position:absolute;left:50%;bottom:150px;transform:translateX(-50%);background:#e78043;color:#fff;padding:30px 54px;font-size:38px;white-space:nowrap;box-shadow:0 14px 36px rgba(207,90,40,.45)">Start planning · tryprtravel.com</div>
''')

# 6. Portfolio hero (16:9).
TECH = ['React', 'TypeScript', 'FastAPI', 'Postgres', 'Google Maps', 'OpenStreetMap']
HP = (850, 50, 540, 980)
ADS['portfolio-01-hero'] = (1920, 1080, f'''
<div style="position:absolute;inset:0;background:radial-gradient(90% 90% at 0% 0%,#fff 0%,#fbf5ea 50%,#f3e6d2 100%)"></div>
<div class="logo" style="left:84px;top:60px;width:340px;height:190px"></div>
<div style="position:absolute;left:100px;top:320px;width:680px">
  <div class="display" style="font-size:86px">Plan deeper.<br><span class="clay">Travel smarter.</span></div>
  <div style="font-size:27px;font-weight:700;color:#4a4039;line-height:1.45;margin-top:28px">A trip planner for every kind of trip: roads, rail, flights, trail-snapped hiking routes and paddle routes across lakes and portages, with group chat, packing lists and shared budgets.</div>
  <div style="display:flex;flex-wrap:wrap;gap:12px;margin-top:36px">{''.join(f'<span class="pill" style="background:#fff;border:1.5px solid #eadfce;padding:11px 20px;font-size:21px;color:#6e645b">{t}</span>' for t in TECH)}</div>
</div>
<div style="position:absolute;left:{HP[0]}px;top:{HP[1]}px;width:{HP[2]}px;height:{HP[3]}px;border-radius:44px;overflow:hidden;
  box-shadow:0 24px 60px rgba(74,56,40,.22),0 2px 8px rgba(74,56,40,.1);border:6px solid #fff">{svg(vb=fit_view(HP[2] - 12, HP[3] - 12, 1.18), label_scale=0.62, route_width=6)}</div>
<div class="glass" style="position:absolute;left:1430px;width:440px;top:50%;transform:translateY(-50%);border-radius:32px;padding:30px 30px 18px;background:rgba(255,255,255,.8)">
  <div style="font-size:19px;font-weight:900;letter-spacing:.12em;color:#2c9cc0">5-DAY ITINERARY</div>
  <div style="font:600 32px Fredoka,sans-serif;margin-top:6px">Western Uplands Trail</div>
  <div style="font-size:19px;font-weight:700;color:#6e645b;margin:4px 0 10px">{TOTAL} km loop from Hwy 60, on the trail</div>
  {day_rows(21, 12)}
</div>
<div class="credit" style="left:{HP[0]}px;bottom:14px;font-size:15px;color:#9d9389">Map data © OpenStreetMap contributors</div>
''')

# 7. Portfolio: routing engineering.
def vb_for(bounds, px_w, px_h):
    """viewBox covering bounds (south, west, north, east), widened to the panel's aspect ratio."""
    x0, y1 = xy(bounds[0], bounds[1])
    x1, y0 = xy(bounds[2], bounds[3])
    scale = min(px_w / (x1 - x0), px_h / (y1 - y0))
    cx, cy, vw, vh = (x0 + x1) / 2, (y0 + y1) / 2, px_w / scale, px_h / scale
    return f'{cx - vw / 2:.1f} {cy - vh / 2:.1f} {vw:.1f} {vh:.1f}'


ZP = (60, 60, 880, 960)
zoom = (45.555, -78.905, 45.64, -78.835)  # Brown → Islet → Pincher
STATS = [('70.6 km', 'full loop, routed as 6 legs'), ('99%', 'of the official trail followed'),
         ('< 0.5 s', 'to route a leg in the browser'), ('< 1 s', 'map loads from the shared cache, down from 30-60 s')]
stat_cards = ''.join(f'<div class="glass" style="border-radius:28px;padding:26px 30px;background:rgba(255,255,255,.85)"><div class="display clay" style="font-size:60px">{v}</div><div style="font-size:22px;font-weight:800;color:#6e645b;margin-top:6px;line-height:1.3">{t}</div></div>' for v, t in STATS)
ADS['portfolio-02-routing'] = (1920, 1080, f'''
<div style="position:absolute;inset:0;background:radial-gradient(90% 90% at 100% 0%,#fff 0%,#fbf5ea 50%,#f3e6d2 100%)"></div>
<div style="position:absolute;left:{ZP[0]}px;top:{ZP[1]}px;width:{ZP[2]}px;height:{ZP[3]}px;border-radius:44px;overflow:hidden;
  box-shadow:0 24px 60px rgba(74,56,40,.22),0 2px 8px rgba(74,56,40,.1);border:6px solid #fff">{svg(vb=vb_for(zoom, ZP[2] - 12, ZP[3] - 12), route_width=3.2, show_labels=False, label_scale=0.36)}</div>
<div class="credit" style="left:{ZP[0] + 6}px;bottom:24px;font-size:15px;color:#9d9389">Western Uplands Trail, Algonquin Park · Map data © OpenStreetMap contributors</div>
<div style="position:absolute;left:1030px;right:90px;top:70px">
  <div class="logo" style="position:relative;width:200px;height:112px;margin-left:-14px"></div>
  <div style="font-size:23px;font-weight:900;letter-spacing:.14em;color:#2c9cc0;margin-top:14px">ENGINEERING</div>
  <div class="display" style="font-size:74px;margin-top:10px">Routes that stay<br><span class="clay">on the trail.</span></div>
  <div style="font-size:25px;font-weight:700;color:#4a4039;line-height:1.45;margin-top:22px">OpenStreetMap trails become a graph that is routed in the browser. Map data loads in fixed tiles that the overlay, the router and every user share through a Postgres cache.</div>
  <div style="display:grid;grid-template-columns:1fr 1fr;gap:18px;margin-top:32px">{stat_cards}</div>
</div>
''')


# Architecture diagram.
ROW_Y0, ROW_H, ROW_GAP = 336, 92, 12
row_y = lambda i: ROW_Y0 + i * (ROW_H + ROW_GAP)
COLS = {'web': 90, 'api': 700, 'svc': 1310}
COL_W = 520


def arch_row(col, i, icon, title, desc, span=1, tint='#2c9cc0'):
    h = ROW_H * span + ROW_GAP * (span - 1)
    return f'''<div class="glass" style="position:absolute;left:{COLS[col]}px;top:{row_y(i)}px;width:{COL_W}px;height:{h}px;border-radius:24px;
  padding:0 24px;display:flex;align-items:center;gap:20px;background:rgba(255,255,255,.82)">
  <div style="flex:none;width:58px;height:58px;border-radius:18px;background:{tint}1f;display:grid;place-items:center;font-size:32px">{icon}</div>
  <div><div style="font:600 27px Fredoka,sans-serif;line-height:1.1">{title}</div><div style="font-size:18.5px;font-weight:700;color:#6e645b;margin-top:4px;line-height:1.3">{desc}</div></div></div>'''


def arch_head(col, eyebrow, title, color):
    return f'''<div style="position:absolute;left:{COLS[col] + 6}px;top:228px;width:{COL_W}px">
  <div style="font-size:19px;font-weight:900;letter-spacing:.14em;color:{color}">{eyebrow}</div>
  <div style="font:600 34px Fredoka,sans-serif;margin-top:6px">{title}</div></div>'''


def arrow(x0, x1, y, label=''):
    lbl = f'<text x="{(x0 + x1) / 2:.0f}" y="{y + 30}" text-anchor="middle" font-family="Nunito" font-weight="900" font-size="15" fill="#9d9389">{label}</text>' if label else ''
    return f'<path d="M{x0} {y}H{x1 - 12}" stroke="#d9c7ad" stroke-width="4" stroke-linecap="round"/><path d="M{x1 - 16} {y - 9}L{x1} {y}L{x1 - 16} {y + 9}Z" fill="#d9c7ad"/>{lbl}'


cy = lambda i: row_y(i) + ROW_H / 2
web_rows = [('🧳', 'Trip builder', 'Itinerary, budget, checklists, chat'), ('📍', 'Google Maps', 'Maps, places search, directions, transit'),
            ('🥾', 'Trail router', 'OSM trails as a graph, shortest path'), ('🛶', 'Paddle router', 'Lakes as a grid, A* over water and portages')]
api_rows = [('🔐', 'Auth', 'Cookie sessions, bcrypt'), ('📄', 'Document API', 'Firestore-style data and access rules'),
            ('🌐', 'Map data proxy', 'Races 5 Overpass mirrors, caches results'), ('🧭', 'Routing proxy', 'OpenRouteService, GraphHopper'),
            ('💳', 'Billing', 'Stripe checkout and webhooks'), ('✨', 'AI suggestions', 'Stays and activities for a trip')]
svc_rows = [(0, 2, '🐘', 'Postgres 16', 'Trips, users, sessions and a 14-day map data cache'), (2, 1, '🗺️', 'OpenStreetMap', 'Trails, lakes, portages, campsites'),
            (3, 1, '🛣️', 'Routing engines', 'Foot and bike routing'), (4, 1, '🧾', 'Stripe', 'Premium subscriptions'), (5, 1, '🤖', 'Claude API', 'Anthropic')]
arrows = arrow(COLS['web'] + COL_W, COLS['api'], cy(1) + ROW_GAP / 2 + ROW_H / 2, 'HTTPS /api')
arrows += ''.join(arrow(COLS['api'] + COL_W, COLS['svc'], cy(i)) for i in range(6))
ADS['portfolio-05-architecture'] = (1920, 1080, f'''
<div style="position:absolute;inset:0;background:radial-gradient(90% 90% at 0% 0%,#fff 0%,#fbf5ea 50%,#f3e6d2 100%)"></div>
<div style="position:absolute;left:96px;top:50px">
  <div style="font-size:23px;font-weight:900;letter-spacing:.14em;color:#2c9cc0">ARCHITECTURE</div>
  <div class="display" style="font-size:72px;margin-top:8px">How Trypr <span class="clay">is built.</span></div>
</div>
<div class="logo" style="right:70px;top:44px;width:230px;height:130px"></div>
{arch_head('web', 'BROWSER', 'React 19 · TypeScript · Vite', '#2c9cc0')}
{arch_head('api', 'API', 'FastAPI · Python · Docker', '#cf5a28')}
{arch_head('svc', 'DATA AND SERVICES', 'Postgres and outside APIs', '#00897b')}
<svg style="position:absolute;inset:0" width="1920" height="1080">{arrows}</svg>
{''.join(arch_row('web', i, *r, tint='#2c9cc0') for i, r in enumerate(web_rows))}
{''.join(arch_row('api', i, *r, tint='#e78043') for i, r in enumerate(api_rows))}
{''.join(arch_row('svc', i, ic, t, d, span=sp, tint='#00897b') for i, sp, ic, t, d in svc_rows)}
<div style="position:absolute;left:{COLS['web']}px;top:{row_y(4) + 10}px;width:{COL_W}px;font-size:19px;font-weight:700;color:#6e645b;line-height:1.5;padding:0 8px">
  Routing runs in the browser on cached map data, so a leg routes in under half a second.</div>
<div style="position:absolute;left:96px;right:96px;bottom:34px;font-size:20px;font-weight:800;color:#9d9389">
  Website: static files on Hostinger  ·  API and Postgres: Docker on a DigitalOcean droplet behind nginx  ·  one-command deploys</div>
''')


# Paddle routing.
P = paddlesvg.paddle
p_runs = [r for leg in P['legs'] for r in leg['runs']]
P_KM = sum(l['km'] for l in P['legs'])
P_PORTAGES = [r for r in p_runs if r['kind'] != 'paddle']
P_CARRY = sum(r['meters'] for r in P_PORTAGES)
PP = (60, 60, 880, 960)
P_STATS = [(f'{P_KM:.1f} km', 'Canoe Lake to Burnt Island Lake'), (f'{len(P_PORTAGES)} portages', f'{P_CARRY / 1000:.1f} km carried, the rest paddled'),
           ('0.1 s', 'to route each leg in the browser'), (f'{len(P["areas"])}', 'lakes rebuilt from OpenStreetMap')]
p_stat_cards = ''.join(f'<div class="glass" style="border-radius:28px;padding:24px 30px;background:rgba(255,255,255,.85)"><div class="display clay" style="font-size:56px">{v}</div><div style="font-size:21px;font-weight:800;color:#6e645b;margin-top:6px;line-height:1.3">{t}</div></div>' for v, t in P_STATS)
COSTS = [('Lake', '1'), ('River', '1.25'), ('Portage', '2'), ('Stream', '4'), ('Land', '25')]
cost_chips = ''.join(f'<span class="pill" style="background:#fff;border:1.5px solid #eadfce;padding:10px 18px;font-size:20px;color:#4a4039">{n} <span style="color:#cf5a28;font-weight:900">×{c}</span></span>' for n, c in COSTS)
ADS['portfolio-03-paddle'] = (1920, 1080, f'''
<div style="position:absolute;inset:0;background:radial-gradient(90% 90% at 100% 0%,#fff 0%,#fbf5ea 50%,#f3e6d2 100%)"></div>
<div style="position:absolute;left:{PP[0]}px;top:{PP[1]}px;width:{PP[2]}px;height:{PP[3]}px;border-radius:44px;overflow:hidden;
  box-shadow:0 24px 60px rgba(74,56,40,.22),0 2px 8px rgba(74,56,40,.1);border:6px solid #fff">{paddlesvg.svg(PP[2] - 12, PP[3] - 12, unit=0.42)}
  <div class="glass" style="position:absolute;left:22px;top:22px;border-radius:20px;padding:14px 20px;display:flex;gap:22px;font-size:19px;font-weight:800;background:rgba(255,255,255,.88)">
    <span style="display:flex;align-items:center;gap:10px"><span style="width:34px;height:6px;border-radius:3px;background:#e46f2f"></span>Paddle</span>
    <span style="display:flex;align-items:center;gap:10px"><span style="width:34px;height:0;border-top:6px dotted #2f2a26"></span>Portage</span>
    <span style="display:flex;align-items:center;gap:8px"><span style="color:#e5a33c">▲</span>Campsite</span>
  </div>
</div>
<div class="credit" style="left:{PP[0] + 6}px;bottom:24px;font-size:15px;color:#9d9389">Algonquin Park, Ontario · Map data © OpenStreetMap contributors</div>
<div style="position:absolute;left:1030px;right:90px;top:70px">
  <div class="logo" style="position:relative;width:200px;height:112px;margin-left:-14px"></div>
  <div style="font-size:23px;font-weight:900;letter-spacing:.14em;color:#2c9cc0;margin-top:14px">CANOE ROUTING</div>
  <div class="display" style="font-size:72px;margin-top:10px">Paddle routes across<br><span class="clay">lakes and portages.</span></div>
  <div style="font-size:24px;font-weight:700;color:#4a4039;line-height:1.45;margin-top:20px">Lakes, rivers and portages are drawn onto a grid, then A* finds the cheapest way across. Each kind of ground costs more to cross:</div>
  <div style="display:flex;flex-wrap:wrap;gap:10px;margin-top:16px">{cost_chips}</div>
  <div style="display:grid;grid-template-columns:1fr 1fr;gap:16px;margin-top:28px">{p_stat_cards}</div>
</div>
''')


# Product screenshot (real app, captured with headless Chrome at 2x).
SHOT = f'file://{HERE}/data/product.png'
FX, FY, FW, BAR = 500, 92, 1360, 44
FH = FW * 1000 / 1600
sc = FW / 1600
pt = lambda x, y: (FX + x * sc, FY + BAR + y * sc)
rw, br = pt(1186, 611), pt(957, 361)
POINTS = ['Routes snap to the real trail network', 'Campsites and trails load from OpenStreetMap', 'Each campsite gets its night, dated automatically', 'Distance and time for every leg']
ADS['portfolio-04-product'] = (1920, 1080, f'''
<div style="position:absolute;inset:0;background:radial-gradient(90% 90% at 0% 0%,#fff 0%,#fbf5ea 50%,#f3e6d2 100%)"></div>
<div class="logo" style="left:60px;top:56px;width:230px;height:130px"></div>
<div style="position:absolute;left:80px;top:220px;width:380px">
  <div style="font-size:21px;font-weight:900;letter-spacing:.14em;color:#2c9cc0">THE PRODUCT</div>
  <div class="display" style="font-size:56px;margin-top:10px">Build the whole trip <span class="clay">on the map.</span></div>
  <div style="margin-top:30px;display:grid;gap:16px">{''.join(f'<div style="display:flex;gap:14px;font-size:22px;font-weight:800;color:#4a4039;line-height:1.35"><span style="flex:none;width:30px;height:30px;border-radius:50%;background:#e78043;color:#fff;display:grid;place-items:center;font:600 17px Fredoka,sans-serif;margin-top:1px">{i}</span>{t}</div>' for i, t in enumerate(POINTS, 1))}</div>
</div>
<div style="position:absolute;left:{FX}px;top:{FY}px;width:{FW}px;height:{FH + BAR:.0f}px;border-radius:22px;overflow:hidden;background:#f6efe4;
  box-shadow:0 30px 70px rgba(74,56,40,.25),0 2px 8px rgba(74,56,40,.12);border:1.5px solid #eadfce">
  <div style="height:{BAR}px;display:flex;align-items:center;gap:9px;padding:0 18px;background:#f3ebdf;border-bottom:1.5px solid #eadfce">
    <span style="width:13px;height:13px;border-radius:50%;background:#e8806e"></span><span style="width:13px;height:13px;border-radius:50%;background:#e5a33c"></span><span style="width:13px;height:13px;border-radius:50%;background:#6cc3b9"></span>
    <span style="margin-left:22px;flex:0 0 440px;height:28px;border-radius:999px;background:#fff;display:flex;align-items:center;padding:0 16px;font-size:15px;font-weight:800;color:#6e645b">tryprtravel.com/trip-builder</span>
  </div>
  <img src="{SHOT}" style="display:block;width:{FW}px;height:{FH:.0f}px">
</div>
<div class="glass" style="position:absolute;left:{rw[0] - 150:.0f}px;top:{rw[1] + 34:.0f}px;border-radius:18px;padding:12px 18px;background:rgba(255,255,255,.92);font-size:19px;font-weight:800">
  <span style="color:#cf5a28">13.1 km</span> on the trail to night 1</div>
<div class="glass" style="position:absolute;left:{br[0] + 44:.0f}px;top:{br[1] - 34:.0f}px;border-radius:18px;padding:12px 18px;background:rgba(255,255,255,.92);font-size:19px;font-weight:800">
  Tap a campsite to stay the night</div>
''')


# ---------------- Batch 2 ----------------
def headline(top, size, text, color='#fff', shadow=True, left=72, right=72, align='left'):
    sh = 'text-shadow:0 4px 30px rgba(0,0,0,.35);' if shadow else ''
    return f'<div class="display" style="position:absolute;left:{left}px;right:{right}px;top:{top}px;font-size:{size}px;color:{color};text-align:{align};{sh}">{text}</div>'


def photo(name, pos='50% 50%', shade='linear-gradient(180deg,rgba(30,22,16,.5) 0%,rgba(30,22,16,0) 35%,rgba(30,22,16,0) 55%,rgba(30,22,16,.75) 100%)'):
    return f'<div class="photo" style="background-image:url({IMG}/{name});background-position:{pos}"></div><div style="position:absolute;inset:0;background:{shade}"></div>'


LOGO_TL = '<div class="logo" style="left:44px;top:34px;width:230px;height:130px"></div>'
CREAM = '<div style="position:absolute;inset:0;background:radial-gradient(120% 80% at 0% 0%,#fff 0%,#fbf5ea 55%,#f3e6d2 100%)"></div>'
OSM = '<div class="credit" style="left:44px;bottom:26px;font-size:14px;color:#6e645b">Map data © OpenStreetMap contributors</div>'


def check_rows(items, size=30):
    out = []
    for done, t in items:
        box = (f'<span style="flex:none;width:{size * 1.2:.0f}px;height:{size * 1.2:.0f}px;border-radius:10px;background:#4f9d5d;color:#fff;display:grid;place-items:center;font-size:{size * 0.8:.0f}px;font-weight:900">✓</span>'
               if done else f'<span style="flex:none;width:{size * 1.2:.0f}px;height:{size * 1.2:.0f}px;border-radius:10px;border:3px solid #d9c7ad"></span>')
        style = 'color:#9d9389;text-decoration:line-through' if done else ''
        out.append(f'<div style="display:flex;align-items:center;gap:18px;padding:12px 0;font-size:{size}px;font-weight:800;{style}">{box}{t}</div>')
    return ''.join(out)


# Carousel: one slide per day of the Western Uplands loop.
DAY_LEGS = [[0], [1], [2, 3], [4], [5]]
DAY_INFO = [('Hwy 60 → Redwing Lake', 'Leave the trailhead and head north into the hills.'),
            ('Redwing → Brown Lake', 'The longest day: west across the top of the loop.'),
            ('Brown → Islet → Pincher', 'Swing up past Islet Lake, then south to Pincher.'),
            ('Pincher → Maggie Lake', 'Down the west side to a lakeside site on Maggie.'),
            ('Maggie → Hwy 60', 'Back to the car. 70.6 km, done.')]
CP = (500, 40, 540, 1270)
for d in range(5):
    km = DAYS[d][1]
    ADS[f'ig-carousel-{d + 1:02d}-day{d + 1}'] = (1080, 1350, f'''
{CREAM}
<div style="position:absolute;left:{CP[0]}px;top:{CP[1]}px;width:{CP[2]}px;height:{CP[3]}px;border-radius:44px;overflow:hidden;
  box-shadow:0 24px 60px rgba(74,56,40,.22);border:6px solid #fff">{svg(vb=fit_view(CP[2] - 12, CP[3] - 12, 1.32), label_scale=0.62, route_width=6, highlight=DAY_LEGS[d])}</div>
<div class="logo" style="left:36px;top:30px;width:230px;height:130px"></div>
<div style="position:absolute;left:60px;width:410px;top:220px">
  <div style="font-size:22px;font-weight:900;letter-spacing:.12em;color:#2c9cc0">WESTERN UPLANDS · DAY {d + 1} OF 5</div>
  <div class="display" style="font-size:150px;margin-top:10px;color:#cf5a28">{km:.1f}<span style="font-size:60px;color:#2f2a26"> km</span></div>
  <div class="display" style="font-size:46px;margin-top:12px">{DAY_INFO[d][0]}</div>
  <div style="font-size:26px;font-weight:700;color:#4a4039;margin-top:18px;line-height:1.4">{DAY_INFO[d][1]}</div>
</div>
<div style="position:absolute;left:60px;bottom:90px;display:flex;gap:12px">{''.join(f'<span style="width:{46 if i == d else 14}px;height:14px;border-radius:7px;background:{"#e78043" if i == d else "#e3cca3"}"></span>' for i in range(5))}</div>
<div style="position:absolute;left:60px;bottom:120px;font-size:22px;font-weight:800;color:#9d9389">{"Swipe for day " + str(d + 2) + " →" if d < 4 else "Plan yours at tryprtravel.com"}</div>
{OSM}
''')

ADS['ig-05-spreadsheets'] = (1080, 1350, f'''
{photo('DSC_0072.jpg', '50% 70%')}
{LOGO_TL}
{headline(190, 96, 'Spreadsheets<br>weren’t cutting it.')}
<div class="glass" style="position:absolute;left:72px;right:72px;bottom:96px;border-radius:36px;padding:34px 40px;background:rgba(255,255,255,.86)">
  <div style="display:grid;grid-template-columns:1fr 1fr;gap:26px">
    <div><div style="font-size:21px;font-weight:900;letter-spacing:.12em;color:#9d9389">BEFORE</div>
      <div style="margin-top:12px;font-size:25px;font-weight:700;color:#7d7268;line-height:1.6;text-decoration:line-through">17 browser tabs<br>A spreadsheet per trip<br>Screenshots of maps<br>"Who paid for gas?"</div></div>
    <div><div style="font-size:21px;font-weight:900;letter-spacing:.12em;color:#2c9cc0">TRYPR</div>
      <div style="margin-top:12px;font-size:25px;font-weight:800;line-height:1.6">One trip, one place<br>Routes on the map<br>Every night dated<br>Costs split for you</div></div>
  </div>
</div>
''')

ADS['ig-06-packing'] = (1080, 1350, f'''
{photo('DSC_0001.jpg', '50% 40%')}
{LOGO_TL}
{headline(190, 100, 'Nobody forgets<br>the stove.')}
<div class="glass" style="position:absolute;left:72px;right:72px;bottom:90px;border-radius:36px;padding:30px 40px 24px;background:rgba(255,255,255,.8)">
  <div style="font:600 36px Fredoka,sans-serif">Packing list · Western Uplands</div>
  <div style="font-size:22px;font-weight:700;color:#6e645b;margin:4px 0 8px">Shared with everyone on the trip</div>
  {check_rows([(True, 'Tent and footprint'), (True, 'Stove and fuel'), (True, 'Water filter'), (False, 'Bear hang rope'), (False, 'Headlamps')], 28)}
</div>
''')

ADS['ig-07-split-costs'] = (1080, 1350, f'''
{photo('DSC_0310.jpg', '50% 60%')}
{LOGO_TL}
{headline(190, 100, 'Who owes<br>what? Sorted.')}
<div class="glass" style="position:absolute;left:72px;right:72px;bottom:90px;border-radius:36px;padding:32px 40px;background:rgba(255,255,255,.82)">
  <div style="font:600 36px Fredoka,sans-serif">Trip budget</div>
  {''.join(f'<div style="display:flex;justify-content:space-between;padding:12px 0;border-bottom:1.5px solid rgba(74,56,40,.1);font-size:28px;font-weight:800"><span>{n}</span><span>${v}</span></div>' for n, v in [('⛽ Gas', '186.00'), ('⛺ Campsites', '96.00'), ('🛒 Groceries', '142.50')])}
  <div style="display:flex;justify-content:space-between;align-items:baseline;margin-top:18px">
    <span style="font-size:26px;font-weight:800;color:#6e645b">Split 3 ways</span>
    <span class="display clay" style="font-size:64px">$141.50 <span style="font-size:28px;color:#6e645b">each</span></span></div>
</div>
''')

PADP = (60, 330, 960, 900)
ADS['ig-08-portage'] = (1080, 1350, f'''
{CREAM}
<div class="logo" style="right:40px;top:30px;width:230px;height:130px"></div>
<div style="position:absolute;left:66px;top:60px;width:720px">
  <div style="font-size:22px;font-weight:900;letter-spacing:.12em;color:#2c9cc0">CANOE TRIPS · ALGONQUIN PARK</div>
  <div class="display" style="font-size:78px;margin-top:10px">Every portage,<br><span class="clay">before you carry it.</span></div>
</div>
<div style="position:absolute;left:{PADP[0]}px;top:{PADP[1]}px;width:{PADP[2]}px;height:{PADP[3]}px;border-radius:44px;overflow:hidden;box-shadow:0 24px 60px rgba(74,56,40,.22);border:6px solid #fff">
  {paddlesvg.svg(PADP[2] - 12, PADP[3] - 12, unit=0.42)}
  <div class="glass" style="position:absolute;right:22px;bottom:22px;border-radius:24px;padding:18px 24px;background:rgba(255,255,255,.9)">
    <div class="display clay" style="font-size:46px">{P_KM:.1f} km</div>
    <div style="font-size:21px;font-weight:800;color:#4a4039">{len(P_PORTAGES)} portages · {P_CARRY / 1000:.1f} km carried</div></div>
</div>
<div class="credit" style="left:66px;bottom:46px;font-size:14px;color:#6e645b">Canoe Lake → Littledoe → Burnt Island · Map data © OpenStreetMap contributors</div>
''')

SP_ = (40, 370, 490, 860)
SP2 = (550, 370, 490, 860)
ADS['ig-09-straight-vs-trail'] = (1080, 1350, f'''
{CREAM}
<div class="logo" style="right:40px;top:30px;width:230px;height:130px"></div>
<div style="position:absolute;left:60px;top:60px;width:720px">
  <div style="font-size:22px;font-weight:900;letter-spacing:.12em;color:#2c9cc0">SAME FIVE STOPS</div>
  <div class="display" style="font-size:76px;margin-top:10px">A line on a map<br><span class="clay">isn't a route.</span></div>
</div>
{''.join(f'<div style="position:absolute;left:{b[0]}px;top:{b[1]}px;width:{b[2]}px;height:{b[3]}px;border-radius:36px;overflow:hidden;box-shadow:0 18px 44px rgba(74,56,40,.2);border:5px solid #fff">{svg(vb=fit_view(b[2] - 10, b[3] - 10, 1.2), label_scale=0.55, route_width=5, show_labels=False, straight=st, extra_class="straight" if st else "")}<div class="glass" style="position:absolute;left:16px;right:16px;bottom:16px;border-radius:22px;padding:16px 20px;background:rgba(255,255,255,.9)"><div style="font:600 30px Fredoka,sans-serif">{t}</div><div style="font-size:20px;font-weight:800;color:#6e645b;margin-top:2px">{d}</div></div></div>' for b, st, t, d in [(SP_, True, 'Straight lines', 'Cuts through lakes and bush'), (SP2, False, 'Trypr', f'{TOTAL} km on the real trail')])}
{OSM}
''')

ADS['ig-10-husky'] = (1080, 1350, f'''
{photo('DSC_0018.jpg', '50% 40%', 'linear-gradient(180deg,rgba(20,24,16,.55) 0%,rgba(20,24,16,0) 34%,rgba(20,24,16,0) 60%,rgba(20,24,16,.55) 100%)')}
{LOGO_TL}
{headline(190, 92, 'Even the dog knows<br>where we’re camping.')}
<div class="glass" style="position:absolute;left:72px;bottom:90px;border-radius:30px;padding:24px 30px;background:rgba(255,255,255,.85);display:flex;align-items:center;gap:22px">
  <div style="width:72px;height:72px;border-radius:50%;background:#2c9cc0;color:#fff;display:grid;place-items:center;font:600 38px Fredoka,sans-serif">2</div>
  <div><div style="font:600 34px Fredoka,sans-serif">Night 2 · Brown Lake</div><div style="font-size:23px;font-weight:800;color:#6e645b">16.1 km from Redwing, on the trail</div></div>
</div>
''')

ADS['ig-11-motto'] = (1080, 1350, f'''
{photo('DSC_0204.jpg', '50% 50%', 'linear-gradient(180deg,rgba(30,18,8,.25) 0%,rgba(30,18,8,0) 40%,rgba(30,18,8,.45) 100%)')}
<div class="logo" style="left:50%;top:120px;width:420px;height:236px;transform:translateX(-50%)"></div>
{headline(860, 110, 'Plan deeper.<br><span style="color:#ffd2ad">Travel smarter.</span>', align='center')}
<div style="position:absolute;left:0;right:0;bottom:70px;text-align:center;color:#fff;font-size:30px;font-weight:800;opacity:.9">tryprtravel.com</div>
''')

TILES = [('DSC_0006.jpg', '🚗 Road trips'), ('DSC_0003.jpg', '🥾 Backpacking'), ('DSC_0283.jpg', '🛶 Canoe trips'), ('DSC_0216.jpg', '⛺ Camping')]
ADS['ig-12-collage'] = (1080, 1350, f'''
<div style="position:absolute;inset:0;background:#fbf5ea"></div>
<div style="position:absolute;inset:0;display:grid;grid-template-columns:1fr 1fr;grid-template-rows:1fr 1fr;gap:10px">
{''.join(f'<div style="position:relative;background:url({IMG}/{f}) center/cover"><span class="pill glass-dark" style="position:absolute;left:22px;{"top" if i < 2 else "bottom"}:22px;padding:12px 22px;font-size:28px">{t}</span></div>' for i, (f, t) in enumerate(TILES))}
</div>
<div class="glass" style="position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);border-radius:40px;padding:30px 44px;text-align:center;background:rgba(255,255,255,.88)">
  <div class="logo" style="position:relative;width:220px;height:124px;margin:0 auto"></div>
  <div class="display" style="font-size:52px;margin-top:6px">One planner<br><span class="clay">for all of it.</span></div>
</div>
''')

ADS['ig-13-find-campsite'] = (1080, 1350, f'''
{photo('DSC_0062.jpg', '50% 50%')}
{LOGO_TL}
{headline(190, 96, 'Where do we<br>sleep in between?')}
<div class="glass" style="position:absolute;left:72px;right:72px;bottom:90px;border-radius:36px;padding:34px 40px;background:rgba(255,255,255,.85)">
  <div style="display:flex;align-items:center;gap:16px;font-size:26px;font-weight:800;color:#6e645b">
    <span style="padding:10px 18px;border-radius:999px;background:#fff;border:1.5px solid #eadfce">Stop A</span><span>→ ? →</span>
    <span style="padding:10px 18px;border-radius:999px;background:#fff;border:1.5px solid #eadfce">Stop B</span></div>
  <div class="pill" style="margin-top:22px;background:#e78043;color:#fff;padding:18px 30px;font-size:30px">✨ Find Campsite Between</div>
  <div style="font-size:25px;font-weight:700;color:#4a4039;margin-top:20px;line-height:1.4">Pick two stops and Trypr suggests places to stay along the way.</div>
</div>
''')

ADS['story-02-together'] = (1080, 1920, f'''
{photo('DSC_0216.jpg', '50% 50%', 'linear-gradient(180deg,rgba(40,24,12,.55) 0%,rgba(40,24,12,0) 30%,rgba(40,24,12,.1) 55%,rgba(40,24,12,.6) 100%)')}
<div class="logo" style="left:50%;top:120px;width:440px;height:248px;transform:translateX(-50%)"></div>
{headline(420, 124, 'Plan it<br>together.', align='center')}
<div style="position:absolute;left:110px;right:110px;bottom:300px;display:grid;gap:18px">
{''.join(f'<div class="glass" style="border-radius:28px;padding:24px 32px;display:flex;align-items:center;gap:22px;background:rgba(255,255,255,.8)"><span style="font-size:48px">{e}</span><div><div style="font:600 40px Fredoka,sans-serif">{t}</div><div style="font-size:24px;font-weight:700;color:#6e645b">{s}</div></div></div>' for e, t, s in FEATURES)}
</div>
<div class="pill" style="position:absolute;left:50%;bottom:150px;transform:translateX(-50%);background:#e78043;color:#fff;padding:28px 50px;font-size:36px;white-space:nowrap;box-shadow:0 14px 36px rgba(207,90,40,.45)">Invite your crew · tryprtravel.com</div>
''')

SQ = (60, 560, 960, 1180)
ADS['story-03-western-uplands'] = (1080, 1920, f'''
{CREAM}
<div class="logo" style="left:50%;top:60px;width:340px;height:190px;transform:translateX(-50%)"></div>
<div style="position:absolute;left:60px;right:60px;top:270px;text-align:center">
  <div style="font-size:24px;font-weight:900;letter-spacing:.14em;color:#2c9cc0">WESTERN UPLANDS TRAIL · ALGONQUIN</div>
  <div class="display" style="font-size:96px;margin-top:10px">5 days. {TOTAL} km.</div>
  <div class="display clay" style="font-size:60px;margin-top:6px">Every night planned.</div>
</div>
<div style="position:absolute;left:{SQ[0]}px;top:{SQ[1]}px;width:{SQ[2]}px;height:{SQ[3]}px;border-radius:48px;overflow:hidden;box-shadow:0 24px 60px rgba(74,56,40,.22);border:6px solid #fff">{svg(vb=fit_view(SQ[2] - 12, SQ[3] - 12, 1.5), label_scale=0.62, route_width=6)}</div>
<div class="pill" style="position:absolute;left:50%;bottom:70px;transform:translateX(-50%);background:#e78043;color:#fff;padding:26px 48px;font-size:34px;white-space:nowrap">Plan yours · tryprtravel.com</div>
<div class="credit" style="left:60px;bottom:24px;font-size:14px;color:#6e645b">Map data © OpenStreetMap contributors</div>
''')


# ---------------- Batch 3 ----------------
ROAD = [('Calgary', None), ('Banff', '~128 km'), ('Lake Louise', '~58 km'), ('Jasper', '~230 km')]
road_rows = ''.join(f'''<div style="display:flex;align-items:center;gap:18px;padding:12px 0;{'border-top:1.5px solid rgba(74,56,40,.1);' if i else ''}">
<div style="width:40px;height:40px;border-radius:50%;background:{'#2f2a26' if i == 0 else '#2c9cc0'};color:#fff;display:grid;place-items:center;font:600 22px Fredoka,sans-serif">{i + 1}</div>
<div style="flex:1;font-size:29px;font-weight:800">{n}</div><div style="font-size:26px;font-weight:900;color:#cf5a28">{k or 'Start'}</div></div>''' for i, (n, k) in enumerate(ROAD))
ADS['ig-14-road-trip'] = (1080, 1350, f'''
{photo('DSC_0009.jpg', '50% 55%')}
{LOGO_TL}
{headline(190, 100, 'Every stop.<br>Every night.')}
<div class="glass" style="position:absolute;left:72px;right:72px;bottom:90px;border-radius:36px;padding:28px 40px 18px;background:rgba(255,255,255,.84)">
  <div style="font:600 34px Fredoka,sans-serif">Rockies road trip</div>
  <div style="font-size:21px;font-weight:700;color:#6e645b;margin:2px 0 6px">Example itinerary · driving distances</div>
  {road_rows}
</div>
''')

ADS['ig-15-plan-ahead'] = (1080, 1350, f'''
{photo('mainScreenPic.jpg', '50% 50%', 'linear-gradient(180deg,rgba(20,28,36,.55) 0%,rgba(20,28,36,0) 40%,rgba(20,28,36,.1) 60%,rgba(20,28,36,.6) 100%)')}
{LOGO_TL}
{headline(190, 100, 'For people who<br><span style="color:#ffd2ad">plan ahead.</span>')}
<div style="position:absolute;left:72px;right:72px;bottom:96px;color:#fff;font-size:34px;font-weight:800;line-height:1.45;text-shadow:0 2px 14px rgba(0,0,0,.4)">Know the route, the nights and the costs before you leave the driveway.</div>
''')

ADS['ig-16-know-the-day'] = (1080, 1350, f'''
{photo('DSC_0171.jpg', '50% 50%', 'linear-gradient(180deg,rgba(20,20,16,.55) 0%,rgba(20,20,16,0) 36%,rgba(20,20,16,0) 55%,rgba(20,20,16,.55) 100%)')}
{LOGO_TL}
{headline(190, 96, 'Know the day<br>before you lace up.')}
<div class="glass" style="position:absolute;left:72px;right:72px;bottom:90px;border-radius:36px;padding:30px 36px;background:rgba(255,255,255,.86)">
  <div style="font:600 34px Fredoka,sans-serif">Day 2 · Redwing → Brown Lake</div>
  <div style="display:grid;grid-template-columns:repeat(3,1fr);gap:16px;margin-top:20px">
  {''.join(f'<div style="background:#fff;border:1.5px solid #eadfce;border-radius:22px;padding:18px 20px"><div style="font-size:19px;font-weight:900;letter-spacing:.1em;color:#9d9389">{k}</div><div class="display" style="font-size:40px;margin-top:6px;color:{c}">{v}</div></div>' for k, v, c in [('DISTANCE', '16.1 km', '#cf5a28'), ('TIME', '~3 h 50', '#2c9cc0'), ('LEVEL', 'Advanced', '#2f2a26')])}
  </div>
</div>
''')

PS = (60, 520, 960, 1220)
ADS['story-04-paddle'] = (1080, 1920, f'''
{CREAM}
<div class="logo" style="left:50%;top:60px;width:340px;height:190px;transform:translateX(-50%)"></div>
<div style="position:absolute;left:60px;right:60px;top:270px;text-align:center">
  <div style="font-size:24px;font-weight:900;letter-spacing:.14em;color:#2c9cc0">CANOE LAKE → BURNT ISLAND LAKE</div>
  <div class="display" style="font-size:84px;margin-top:10px">Paddle it. <span class="clay">Portage it.</span></div>
  <div style="font-size:30px;font-weight:800;color:#4a4039;margin-top:10px">{P_KM:.1f} km · {len(P_PORTAGES)} portages · {P_CARRY / 1000:.1f} km carried</div>
</div>
<div style="position:absolute;left:{PS[0]}px;top:{PS[1]}px;width:{PS[2]}px;height:{PS[3]}px;border-radius:48px;overflow:hidden;box-shadow:0 24px 60px rgba(74,56,40,.22);border:6px solid #fff">{paddlesvg.svg(PS[2] - 12, PS[3] - 12, unit=0.42)}</div>
<div class="pill" style="position:absolute;left:50%;bottom:70px;transform:translateX(-50%);background:#e78043;color:#fff;padding:26px 48px;font-size:34px;white-space:nowrap">Plan a canoe trip · tryprtravel.com</div>
<div class="credit" style="left:60px;bottom:24px;font-size:14px;color:#6e645b">Map data © OpenStreetMap contributors</div>
''')

ADS['story-05-spreadsheets'] = (1080, 1920, f'''
{photo('DSC_0075.jpg', '50% 55%', 'linear-gradient(180deg,rgba(20,28,40,.55) 0%,rgba(20,28,40,0) 30%,rgba(20,28,40,0) 50%,rgba(20,28,40,.65) 100%)')}
<div class="logo" style="left:50%;top:110px;width:420px;height:236px;transform:translateX(-50%)"></div>
{headline(390, 110, 'Spreadsheets<br>weren’t cutting it.', align='center')}
<div class="glass" style="position:absolute;left:90px;right:90px;bottom:300px;border-radius:40px;padding:36px 44px;background:rgba(255,255,255,.86)">
  {check_rows([(False, 'Routes on a real map'), (False, 'Every night dated'), (False, 'Packing lists for the group'), (False, 'Costs split for you')], 34).replace('border:3px solid #d9c7ad', 'background:#e78043').replace('></span>', '>✓</span>').replace('border-radius:10px;background:#e78043', 'border-radius:10px;background:#e78043;color:#fff;display:grid;place-items:center;font-weight:900')}
</div>
<div class="pill" style="position:absolute;left:50%;bottom:150px;transform:translateX(-50%);background:#e78043;color:#fff;padding:28px 50px;font-size:36px;white-space:nowrap;box-shadow:0 14px 36px rgba(207,90,40,.45)">Try Trypr · tryprtravel.com</div>
''')


# ---------------- Batch 4 ----------------
def eyebrow(t, color='#2c9cc0', size=22):
    return f'<div style="font-size:{size}px;font-weight:900;letter-spacing:.13em;color:{color}">{t}</div>'


def dots(n, active, left=60, bottom=90):
    return f'<div style="position:absolute;left:{left}px;bottom:{bottom}px;display:flex;gap:12px">' + ''.join(
        f'<span style="width:{46 if i == active else 14}px;height:14px;border-radius:7px;background:{"#e78043" if i == active else "#e3cca3"}"></span>' for i in range(n)) + '</div>'


def crop(x, y, w, h, k):
    """A piece of the real trip-builder screenshot (CSS px region of a 1600x1000 viewport) shown at scale k."""
    return (f'<div style="width:{w * k:.0f}px;height:{h * k:.0f}px;background:url({SHOT}) no-repeat;background-size:{1600 * k:.0f}px {1000 * k:.0f}px;'
            f'background-position:{-x * k:.0f}px {-y * k:.0f}px"></div>')


def panel(x, y, w, h, inner, radius=44):
    return (f'<div style="position:absolute;left:{x}px;top:{y}px;width:{w}px;height:{h}px;border-radius:{radius}px;overflow:hidden;'
            f'box-shadow:0 24px 60px rgba(74,56,40,.22);border:6px solid #fff;background:#fff">{inner}</div>')


# Carousel: canoe trip.
leg_runs = lambda i: P['legs'][i]['runs']
run_txt = lambda r: (f"Paddle {r['meters'] / 1000:.1f} km" if r['meters'] >= 1000 else f"Paddle {r['meters']} m") if r['kind'] == 'paddle' else (f"Portage {r['meters'] / 1000:.1f} km" if r['meters'] >= 1000 else f"Portage {r['meters']} m")
def run_rows(i):
    return ''.join(f'<div style="display:flex;align-items:center;gap:14px;padding:9px 0;font-size:25px;font-weight:800"><span style="flex:none;width:34px;height:6px;border-radius:3px;{"background:#e46f2f" if r["kind"] == "paddle" else "border-top:6px dotted #2f2a26"}"></span>{run_txt(r)}</div>' for r in leg_runs(i))

CANOE = (500, 40, 540, 1270)
CANOE_SLIDES = [
    ('cover', None, None),
    ('leg', [0], ('LEG 1 OF 2', f"{P['legs'][0]['km']:.1f} km", 'Canoe Lake → Littledoe Lake', 'North up Canoe Lake, a short carry, then the river and lakes to Littledoe.')),
    ('leg', [1], ('LEG 2 OF 2', f"{P['legs'][1]['km']:.1f} km", 'Littledoe → Burnt Island Lake', 'Two portages, then a long open paddle east across Burnt Island Lake.')),
    ('portage', None, None),
    ('cta', None, None),
]
PORTAGE_BOUNDS = (45.6135, -78.704, 45.6315, -78.672)
big_portage = max((r for l in P['legs'] for r in l['runs'] if r['kind'] != 'paddle'), key=lambda r: r['meters'])
for i, (kind, hl, info) in enumerate(CANOE_SLIDES):
    name = f'canoe-{i + 1}-' + ['cover', 'leg1', 'leg2', 'portage', 'plan-yours'][i]
    if kind == 'cover':
        body = f'''{CREAM}{panel(*CANOE, paddlesvg.svg(CANOE[2] - 12, CANOE[3] - 12, unit=0.42))}
<div class="logo" style="left:36px;top:30px;width:230px;height:130px"></div>
<div style="position:absolute;left:60px;width:410px;top:220px">{eyebrow('CANOE TRIP · ALGONQUIN')}
  <div class="display" style="font-size:80px;margin-top:12px">Canoe Lake to<br><span class="clay">Burnt Island.</span></div>
  <div style="font-size:27px;font-weight:700;color:#4a4039;margin-top:20px;line-height:1.4">{P_KM:.1f} km of lakes and rivers, {len(P_PORTAGES)} portages, planned by Trypr.</div></div>
<div style="position:absolute;left:60px;bottom:120px;font-size:22px;font-weight:800;color:#9d9389">Swipe for the route →</div>{dots(5, 0)}{OSM}'''
    elif kind == 'leg':
        tag, km, title, desc = info
        body = f'''{CREAM}{panel(*CANOE, paddlesvg.svg(CANOE[2] - 12, CANOE[3] - 12, unit=0.42, highlight=hl))}
<div class="logo" style="left:36px;top:30px;width:230px;height:130px"></div>
<div style="position:absolute;left:60px;width:410px;top:220px">{eyebrow(tag)}
  <div class="display" style="font-size:130px;margin-top:8px;color:#cf5a28">{km.split()[0]}<span style="font-size:56px;color:#2f2a26"> km</span></div>
  <div class="display" style="font-size:42px;margin-top:8px">{title}</div>
  <div style="font-size:24px;font-weight:700;color:#4a4039;margin-top:14px;line-height:1.4">{desc}</div>
  <div style="margin-top:18px">{run_rows(hl[0])}</div></div>
<div style="position:absolute;left:60px;bottom:120px;font-size:22px;font-weight:800;color:#9d9389">Swipe →</div>{dots(5, i)}{OSM}'''
    elif kind == 'portage':
        body = f'''{CREAM}{panel(60, 360, 960, 900, paddlesvg.svg(948, 888, bounds=PORTAGE_BOUNDS, unit=0.12, labels=False, highlight=[1], extra_class='zoomed'))}
<div class="logo" style="right:40px;top:30px;width:230px;height:130px"></div>
<div style="position:absolute;left:66px;top:60px;width:740px">{eyebrow('THE BIG CARRY')}
  <div class="display" style="font-size:76px;margin-top:10px">{big_portage['meters'] / 1000:.1f} km portage,<br><span class="clay">known before you go.</span></div></div>
<div class="glass" style="position:absolute;left:90px;bottom:120px;border-radius:24px;padding:18px 26px;background:rgba(255,255,255,.92);font-size:24px;font-weight:800">Between Littledoe and Burnt Island · know it before you lift the canoe</div>
{dots(5, 3, 80, 66)}<div class="credit" style="right:44px;bottom:26px;font-size:14px;color:#6e645b">Map data © OpenStreetMap contributors</div>'''
    else:
        body = f'''{photo('DSC_0283.jpg', '50% 50%', 'linear-gradient(180deg,rgba(20,28,36,.45) 0%,rgba(20,28,36,0) 40%,rgba(20,28,36,.65) 100%)')}
<div class="logo" style="left:50%;top:150px;width:420px;height:236px;transform:translateX(-50%)"></div>
{headline(440, 104, 'Plan your next<br><span style="color:#ffd2ad">canoe trip.</span>', align='center')}
<div class="glass" style="position:absolute;left:120px;right:120px;bottom:200px;border-radius:32px;padding:26px 34px;background:rgba(255,255,255,.86);font-size:27px;font-weight:800;line-height:1.6">
  ✓ Routes across lakes, rivers and portages<br>✓ Campsites on every lake<br>✓ Distance and time for each leg</div>
<div class="pill" style="position:absolute;left:50%;bottom:90px;transform:translateX(-50%);background:#e78043;color:#fff;padding:22px 40px;font-size:30px;white-space:nowrap">tryprtravel.com</div>
{dots(5, 4, 60, 40)}'''
    ADS[name] = (1080, 1350, body)

# Carousel: how it works (crops of the real trip builder screenshot).
HOW = [
    ('how-1-cover', None),
    ('how-2-trailhead', ('STEP 1', 'Pick a trailhead', 'Search a trail, lake or access point, or tap anywhere on the map.')),
    ('how-3-campsites', ('STEP 2', 'Tap a campsite for each night', 'Every campsite on the map is one tap from your plan.')),
    ('how-4-route', ('STEP 3', 'Trypr routes it on the trail', 'Each day follows the real trail, with distance and time.')),
    ('how-5-together', ('STEP 4', 'Share it with your crew', 'Chat, packing lists and costs live with the trip.')),
]
search_mock = '''<div class="glass" style="border-radius:30px;padding:22px;background:rgba(255,255,255,.9)">
  <div style="border-radius:999px;background:#fff;border:1.5px solid #eadfce;padding:18px 24px;font-size:28px;font-weight:700">🔍 Western Uplands</div>
  <div style="margin-top:14px;border-radius:22px;background:#fff;padding:18px 22px;border:1.5px solid #eadfce">
    <div style="font:600 30px Fredoka,sans-serif">Western Uplands Backpacking Trail</div>
    <div style="font-size:21px;font-weight:800;color:#2c9cc0;margin-top:2px">Trail / portage</div>
    <div style="font-size:21px;font-weight:700;color:#6e645b">at km 3, ON-60</div></div>
  <div style="margin-top:10px;border-radius:22px;background:#fff;padding:18px 22px;border:1.5px solid #eadfce;opacity:.7">
    <div style="font:600 30px Fredoka,sans-serif">Highland Backpacking Trail</div>
    <div style="font-size:21px;font-weight:700;color:#6e645b">Highway 60 at km 29.7</div></div></div>'''
camp_mock = '''<div class="glass" style="border-radius:30px;padding:26px 30px;background:rgba(255,255,255,.94)">
  <div style="font:600 32px Fredoka,sans-serif">Add campsite to trip</div>
  <div style="margin-top:12px;border-radius:16px;background:#fff;border:1.5px solid #eadfce;padding:14px 18px;font-size:26px;font-weight:800">Brown #2</div>
  <div style="display:flex;gap:10px;margin-top:12px;flex-wrap:wrap">
    <span class="pill" style="background:#fff;border:1.5px solid #eadfce;padding:8px 16px;font-size:19px">Mode: Hiking</span>
    <span class="pill" style="background:#fff;border:1.5px solid #eadfce;padding:8px 16px;font-size:19px">Stay stop · 1 night</span></div>
  <div class="pill" style="margin-top:16px;background:#2c9cc0;color:#fff;padding:14px 26px;font-size:24px">Add to Trip</div></div>'''
for i, (name, info) in enumerate(HOW):
    if info is None:
        body = f'''{CREAM}
<div class="logo" style="left:50%;top:90px;width:380px;height:214px;transform:translateX(-50%)"></div>
<div style="position:absolute;left:70px;right:70px;top:340px;text-align:center">{eyebrow('HOW IT WORKS')}
  <div class="display" style="font-size:96px;margin-top:12px">Plan a 5-day hike<br><span class="clay">in 4 steps.</span></div></div>
<div style="position:absolute;left:90px;right:90px;top:700px;border-radius:36px;overflow:hidden;box-shadow:0 24px 60px rgba(74,56,40,.22);border:6px solid #fff">{crop(560, 120, 1040, 860, 0.865)}</div>
<div style="position:absolute;left:0;right:0;bottom:64px;text-align:center;font-size:24px;font-weight:800;color:#9d9389">Swipe →</div>{dots(5, 0, 470, 30)}'''
    else:
        step, title, desc = info
        if name.endswith('trailhead'):
            visual = f'<div style="position:absolute;left:90px;right:90px;top:560px">{search_mock}</div>'
        elif name.endswith('campsites'):
            visual = (f'<div style="position:absolute;left:90px;right:90px;top:520px;border-radius:36px;overflow:hidden;box-shadow:0 24px 60px rgba(74,56,40,.22);border:6px solid #fff">{crop(780, 230, 360, 300, 2.5)}</div>'
                      f'<div style="position:absolute;right:120px;bottom:110px;width:520px">{camp_mock}</div>')
        elif name.endswith('route'):
            visual = f'<div style="position:absolute;left:90px;right:90px;top:520px;border-radius:36px;overflow:hidden;box-shadow:0 24px 60px rgba(74,56,40,.22);border:6px solid #fff">{crop(700, 210, 560, 780, 1.6)}</div>'
        else:
            visual = f'<div style="position:absolute;left:90px;right:90px;top:540px;display:grid;grid-template-columns:1fr 1fr;gap:20px">' + ''.join(
                f'<div class="glass" style="border-radius:30px;padding:28px;background:rgba(255,255,255,.9)"><div style="font-size:52px">{e}</div><div style="font:600 34px Fredoka,sans-serif;margin-top:8px">{t}</div><div style="font-size:22px;font-weight:700;color:#6e645b;margin-top:4px">{s_}</div></div>' for e, t, s_ in FEATURES) + '</div>'
        body = f'''{CREAM}
<div class="logo" style="right:40px;top:30px;width:200px;height:112px"></div>
<div style="position:absolute;left:70px;right:250px;top:80px">{eyebrow(step)}
  <div class="display" style="font-size:72px;margin-top:10px">{title}</div>
  <div style="font-size:28px;font-weight:700;color:#4a4039;margin-top:16px;line-height:1.4">{desc}</div></div>
{visual}{dots(5, i, 70, 46)}'''
    ADS[name] = (1080, 1350, body)

# Singles.
ADS['ig-17-tag-the-canoe'] = (1080, 1350, f'''
{photo('DSC_0283.jpg', '50% 50%', 'linear-gradient(180deg,rgba(20,28,36,.55) 0%,rgba(20,28,36,0) 40%,rgba(20,28,36,0) 60%,rgba(20,28,36,.55) 100%)')}
{LOGO_TL}
{headline(200, 108, 'Tag who’s<br>carrying<br>the canoe.')}
<div style="position:absolute;left:72px;bottom:90px" class="pill glass-dark"><span style="padding:18px 30px;font-size:30px">🛶 1.1 km portage ahead</span></div>
''')

ADS['ig-18-paddle-or-portage'] = (1080, 1350, f'''
<div style="position:absolute;inset:0;display:grid;grid-template-columns:1fr 1fr">
  <div style="background:url({IMG}/DSC_0281.jpg) center/cover"></div><div style="background:url({IMG}/DSC_0003.jpg) center/cover"></div></div>
<div style="position:absolute;inset:0;background:linear-gradient(180deg,rgba(20,24,20,.45) 0%,rgba(20,24,20,0) 35%,rgba(20,24,20,0) 65%,rgba(20,24,20,.55) 100%)"></div>
<div class="logo" style="left:50%;top:40px;width:230px;height:130px;transform:translateX(-50%)"></div>
<div class="display" style="position:absolute;left:0;width:540px;top:520px;text-align:center;font-size:96px;color:#fff;text-shadow:0 4px 30px rgba(0,0,0,.4)">Paddle</div>
<div class="display" style="position:absolute;right:0;width:540px;top:520px;text-align:center;font-size:96px;color:#fff;text-shadow:0 4px 30px rgba(0,0,0,.4)">Hike</div>
<div style="position:absolute;left:50%;top:536px;transform:translateX(-50%);width:110px;height:110px;border-radius:50%;background:#e78043;color:#fff;display:grid;place-items:center;font:600 44px Fredoka,sans-serif;box-shadow:0 10px 30px rgba(0,0,0,.3)">or</div>
<div style="position:absolute;left:0;right:0;bottom:100px;text-align:center;color:#fff;font-size:36px;font-weight:900;text-shadow:0 2px 14px rgba(0,0,0,.4)">Which trip are you planning next? 👇</div>
''')

TIPS = ['Distance and time for each day', 'Where you sleep every night', 'Water along the way', 'What the group is packing', 'A way out if weather turns']
ADS['ig-19-checklist'] = (1080, 1350, f'''
{CREAM}
<div class="logo" style="right:40px;top:30px;width:230px;height:130px"></div>
<div style="position:absolute;left:72px;right:72px;top:80px">{eyebrow('SAVE THIS FOR YOUR NEXT TRIP')}
  <div class="display" style="font-size:84px;margin-top:12px">5 things to plan<br><span class="clay">before the backcountry.</span></div></div>
<div style="position:absolute;left:72px;right:72px;top:470px;display:grid;gap:18px">
{''.join(f'<div class="glass" style="border-radius:28px;padding:24px 30px;display:flex;align-items:center;gap:24px;background:rgba(255,255,255,.9)"><span class="display clay" style="font-size:60px;width:60px">{n}</span><span style="font-size:32px;font-weight:800">{t}</span></div>' for n, t in enumerate(TIPS, 1))}
</div>
<div style="position:absolute;left:72px;bottom:60px;font-size:24px;font-weight:800;color:#6e645b">Trypr keeps all five in one trip · tryprtravel.com</div>
''')

ADS['ig-20-founder-quote'] = (1080, 1350, f'''
{photo('DSC_0191.jpg', '50% 50%', 'linear-gradient(180deg,rgba(20,28,36,.35) 0%,rgba(20,28,36,.55) 100%)')}
<div class="glass" style="position:absolute;left:70px;right:70px;top:50%;transform:translateY(-50%);border-radius:44px;padding:56px 56px 44px;background:rgba(255,255,255,.88)">
  <div class="display clay" style="font-size:140px;line-height:.6">“</div>
  <div class="display" style="font-size:58px;line-height:1.15;margin-top:6px">I plan every trip down to the night. No app let me do that, so I built one.</div>
  <div style="display:flex;align-items:center;gap:20px;margin-top:36px">
    <div style="width:84px;height:84px;border-radius:50%;background:url({IMG}/aboutUsPic.jpg) 50% 22%/cover;border:4px solid #fff;box-shadow:0 4px 14px rgba(0,0,0,.2)"></div>
    <div><div style="font:600 30px Fredoka,sans-serif">Founder, Trypr</div><div style="font-size:22px;font-weight:700;color:#6e645b">19 · Toronto</div></div>
    <div class="logo" style="position:relative;margin-left:auto;width:170px;height:96px"></div></div>
</div>
''')

ADS['story-06-ask-me'] = (1080, 1920, f'''
{photo('DSC_0300.jpg', '50% 50%', 'linear-gradient(180deg,rgba(20,28,40,.55) 0%,rgba(20,28,40,.15) 40%,rgba(20,28,40,.6) 100%)')}
<div class="logo" style="left:50%;top:120px;width:420px;height:236px;transform:translateX(-50%)"></div>
{headline(420, 104, 'Where should<br>we plan next?', align='center')}
<div style="position:absolute;left:140px;right:140px;top:860px;height:420px;border-radius:40px;border:4px dashed rgba(255,255,255,.75);display:grid;place-items:center;color:#fff;font-size:30px;font-weight:800;opacity:.9">Add a question sticker here</div>
<div style="position:absolute;left:0;right:0;bottom:160px;text-align:center;color:#fff;font-size:34px;font-weight:800">We’ll plan the best answer and post the route.</div>
''')

ADS['story-07-new-canoe'] = (1080, 1920, f'''
{CREAM}
<div class="logo" style="left:50%;top:70px;width:340px;height:190px;transform:translateX(-50%)"></div>
<div style="position:absolute;left:60px;right:60px;top:290px;text-align:center">
  <div class="pill" style="background:#2c9cc0;color:#fff;padding:12px 26px;font-size:26px">NEW</div>
  <div class="display" style="font-size:96px;margin-top:20px">Canoe routing<br><span class="clay">is here.</span></div>
  <div style="font-size:30px;font-weight:800;color:#4a4039;margin-top:16px">Drop your stops. Trypr finds the lakes, rivers and portages between them.</div></div>
{panel(60, 820, 960, 920, paddlesvg.svg(948, 908, unit=0.42), 48)}
<div class="pill" style="position:absolute;left:50%;bottom:70px;transform:translateX(-50%);background:#e78043;color:#fff;padding:26px 48px;font-size:34px;white-space:nowrap">Try it · tryprtravel.com</div>
<div class="credit" style="left:60px;bottom:24px;font-size:14px;color:#6e645b">Map data © OpenStreetMap contributors</div>
''')


# ---------------- Batch 5: photos from ~/Documents/Pictures/OutWest 25 ----------------
from urllib.parse import quote as _q
OUTWEST = 'file://' + _q(os.path.expanduser('~/Documents/Pictures/OutWest 25/LastCouple/Matthew'))


def ophoto(name, pos='50% 50%', shade='linear-gradient(180deg,rgba(20,24,30,.5) 0%,rgba(20,24,30,0) 35%,rgba(20,24,30,0) 55%,rgba(20,24,30,.72) 100%)'):
    return f'<div class="photo" style="background-image:url({OUTWEST}/{name});background-position:{pos}"></div><div style="position:absolute;inset:0;background:{shade}"></div>'


def headline_low(bottom, size, text, align='left'):
    return f'<div class="display" style="position:absolute;left:72px;right:72px;bottom:{bottom}px;font-size:{size}px;color:#fff;text-align:{align};text-shadow:0 4px 30px rgba(0,0,0,.45)">{text}</div>'


def body_text(bottom, size, text, left=72, right=72):
    return f'<div style="position:absolute;left:{left}px;right:{right}px;bottom:{bottom}px;color:#fff;font-size:{size}px;font-weight:800;line-height:1.42;text-shadow:0 2px 14px rgba(0,0,0,.45)">{text}</div>'


def wdots(n, active, bottom=60):
    return f'<div style="position:absolute;left:72px;bottom:{bottom}px;display:flex;gap:12px">' + ''.join(
        f'<span style="width:{46 if i == active else 14}px;height:14px;border-radius:7px;background:{"#f5a46e" if i == active else "rgba(255,255,255,.55)"}"></span>' for i in range(n)) + '</div>'


# Carousel 4: why I built Trypr.
WHY = [
    ('DSC_0221.jpg', '50% 40%', 'Why I built<br><span style="color:#ffd2ad">Trypr.</span>', 'A thread, from the founder. Swipe →'),
    ('DSC_0236.jpg', '50% 35%', 'I plan every trip<br>down to the night.', 'Where we drive, where we hike, where we sleep. All of it, before we leave.'),
    ('DSC_0360.jpg', '50% 45%', 'Spreadsheets<br>stopped cutting it.', '17 tabs, screenshots of maps, and a group chat asking who paid for gas.'),
    ('DSC_0386.jpg', '50% 45%', 'So I built one place<br>for the whole trip.', 'Routes on the real trail, every night dated, packing lists and costs for the crew.'),
    ('DSC_0602.jpg', '50% 30%', 'Come plan<br><span style="color:#ffd2ad">with me.</span>', 'Trypr is live at tryprtravel.com'),
]
LOW = {0, 1, 4}  # slides where the photo's subject fills the top: headline goes to the bottom
for i, (f, pos, h, sub) in enumerate(WHY):
    ADS[f'why-{i + 1}-' + ['cover', 'every-night', 'spreadsheets', 'one-place', 'join'][i]] = (1080, 1350, f'''
{ophoto(f, pos, 'linear-gradient(180deg,rgba(20,24,30,.35) 0%,rgba(20,24,30,0) 30%,rgba(20,24,30,.1) 50%,rgba(20,24,30,.8) 100%)' if i in LOW else 'linear-gradient(180deg,rgba(20,24,30,.5) 0%,rgba(20,24,30,0) 35%,rgba(20,24,30,0) 55%,rgba(20,24,30,.72) 100%)')}
{LOGO_TL}
{headline_low(240, 88, h) if i in LOW else headline(200, 92, h)}
{body_text(120, 32, sub)}
{wdots(5, i)}
''')

# Carousel 5: every kind of trip.
KINDS = [
    (None, None, None, None),
    ('DSC_0500.jpg', '50% 50%', '🚗 Road trips', 'Every stop, every drive, every night on one map.'),
    ('DSC_0324.jpg', '50% 50%', '🥾 Backpacking', 'Days that follow the real trail, with distance and time.'),
    ('DSC_0264.jpg', '50% 50%', '🛶 Canoe trips', 'Routes across lakes and rivers, with every portage.'),
    ('DSC_0245.jpg', '50% 40%', '👥 Group trips', 'Chat, packing lists and split costs, in the trip.'),
]
for i, (f, pos, title, sub) in enumerate(KINDS):
    name = 'kinds-' + str(i + 1) + '-' + ['cover', 'road', 'backpacking', 'canoe', 'group'][i]
    if f is None:
        tiles = ''.join(f'<div style="background:url({OUTWEST}/{t}) center/cover"></div>' for t in ['DSC_0500.jpg', 'DSC_0324.jpg', 'DSC_0264.jpg', 'DSC_0245.jpg'])
        ADS[name] = (1080, 1350, f'''
<div style="position:absolute;inset:0;display:grid;grid-template-columns:1fr 1fr;grid-template-rows:1fr 1fr;gap:8px;background:#fbf5ea">{tiles}</div>
<div style="position:absolute;inset:0;background:rgba(30,22,16,.35)"></div>
<div class="glass" style="position:absolute;left:90px;right:90px;top:50%;transform:translateY(-50%);border-radius:44px;padding:44px;text-align:center;background:rgba(255,255,255,.9)">
  <div class="logo" style="position:relative;width:260px;height:146px;margin:0 auto"></div>
  <div class="display" style="font-size:76px;margin-top:8px">One app.<br><span class="clay">Every kind of trip.</span></div>
  <div style="font-size:26px;font-weight:800;color:#9d9389;margin-top:14px">Swipe →</div></div>
''')
    else:
        ADS[name] = (1080, 1350, f'''
{ophoto(f, pos)}
{LOGO_TL}
<div class="pill glass-dark" style="position:absolute;left:72px;top:200px;padding:16px 28px;font-size:40px">{title}</div>
{body_text(130, 44, sub)}
{wdots(5, i)}
''')

# Singles.
ADS['ig-21-the-view'] = (1080, 1350, f'''
{ophoto('DSC_0386.jpg', '50% 45%')}
{LOGO_TL}
{headline(200, 100, 'You enjoy<br>the view.')}
{headline(1000, 100, '<span style="color:#ffd2ad">We’ll handle<br>the plan.</span>')}
''')

ADS['ig-22-ready'] = (1080, 1350, f'''
{ophoto('DSC_0254.jpg', '50% 40%', 'linear-gradient(180deg,rgba(20,24,30,.25) 0%,rgba(20,24,30,0) 40%,rgba(20,24,30,.7) 100%)')}
{LOGO_TL}
<div class="glass" style="position:absolute;left:72px;right:420px;bottom:90px;border-radius:34px;padding:30px 34px;background:rgba(255,255,255,.88)">
  {check_rows([(True, 'Selfie stick'), (True, 'Route'), (True, 'Campsites'), (True, 'Snacks')], 30).replace('color:#9d9389;text-decoration:line-through', '')}
</div>
''')

ADS['ig-23-long-way'] = (1080, 1350, f'''
{ophoto('DSC_0498.jpg', '50% 50%', 'linear-gradient(180deg,rgba(20,24,20,.6) 0%,rgba(20,24,20,0) 40%,rgba(20,24,20,.45) 100%)')}
{LOGO_TL}
{headline(200, 104, 'Take the long way.<br><span style="color:#ffd2ad">We’ll map it.</span>')}
''')

ADS['ig-24-golden-hour'] = (1080, 1350, f'''
{ophoto('DSC_0513.jpg', '50% 60%', 'linear-gradient(180deg,rgba(30,20,10,.15) 0%,rgba(30,20,10,0) 40%,rgba(30,20,10,.65) 100%)')}
{LOGO_TL}
{headline(930, 74, 'Golden hour hits different<br>when you know where<br><span style="color:#ffd2ad">you’re sleeping.</span>')}
''')

ADS['ig-25-big-trips'] = (1080, 1350, f'''
{ophoto('DSC_0331.jpg', '50% 50%', 'linear-gradient(180deg,rgba(30,22,14,.55) 0%,rgba(30,22,14,0) 35%,rgba(30,22,14,0) 70%,rgba(30,22,14,.5) 100%)')}
{LOGO_TL}
{headline(200, 104, 'Big trips start<br>with a <span style="color:#ffd2ad">small plan.</span>')}
''')

ADS['ig-26-look-up'] = (1080, 1350, f'''
{ophoto('DSC_0219.jpg', '50% 40%', 'linear-gradient(180deg,rgba(20,30,40,.4) 0%,rgba(20,30,40,0) 35%,rgba(20,30,40,0) 60%,rgba(20,30,40,.6) 100%)')}
{LOGO_TL}
{headline(1000, 96, 'Close the spreadsheet.<br><span style="color:#ffd2ad">Look up.</span>')}
''')

ADS['story-08-hi'] = (1080, 1920, f'''
{ophoto('DSC_0602.jpg', '50% 30%', 'linear-gradient(180deg,rgba(20,24,30,.35) 0%,rgba(20,24,30,0) 30%,rgba(20,24,30,.1) 55%,rgba(20,24,30,.75) 100%)')}
<div class="logo" style="left:50%;top:100px;width:380px;height:214px;transform:translateX(-50%)"></div>
{headline(1260, 104, 'Hi, I built<br><span style="color:#ffd2ad">Trypr.</span> 👋', align='center')}
<div style="position:absolute;left:90px;right:90px;bottom:180px;text-align:center;color:#fff;font-size:34px;font-weight:800;line-height:1.4;text-shadow:0 2px 14px rgba(0,0,0,.45)">19, Toronto, and a little obsessed with planning trips.</div>
''')

ADS['story-09-pov'] = (1080, 1920, f'''
{ophoto('DSC_0221.jpg', '50% 40%', 'linear-gradient(180deg,rgba(20,30,40,.2) 0%,rgba(20,30,40,0) 30%,rgba(20,30,40,.1) 50%,rgba(20,30,40,.8) 100%)')}
{headline_low(330, 92, 'POV: the trip<br>was planned<br>in <span style="color:#ffd2ad">Trypr.</span>', align='center')}
<div class="pill" style="position:absolute;left:50%;bottom:160px;transform:translateX(-50%);background:#e78043;color:#fff;padding:28px 50px;font-size:36px;white-space:nowrap">tryprtravel.com</div>
''')

ADS['story-10-lake-or-mountains'] = (1080, 1920, f'''
<div style="position:absolute;inset:0;display:grid;grid-template-rows:1fr 1fr">
  <div style="background:url({OUTWEST}/DSC_0198.jpg) 50% 40%/cover"></div><div style="background:url({OUTWEST}/DSC_0322.jpg) 50% 50%/cover"></div></div>
<div style="position:absolute;inset:0;background:linear-gradient(180deg,rgba(0,0,0,.35) 0%,rgba(0,0,0,0) 25%,rgba(0,0,0,0) 75%,rgba(0,0,0,.35) 100%)"></div>
<div class="logo" style="left:50%;top:60px;width:300px;height:170px;transform:translateX(-50%)"></div>
<div class="pill glass-dark" style="position:absolute;left:70px;top:820px;padding:16px 30px;font-size:46px">🏞️ Lake</div>
<div class="pill glass-dark" style="position:absolute;right:70px;top:1010px;padding:16px 30px;font-size:46px">⛰️ Mountains</div>
<div style="position:absolute;left:50%;top:1790px;transform:translate(-50%,-50%);width:420px;height:150px;border-radius:30px;border:4px dashed rgba(255,255,255,.85);display:grid;place-items:center;color:#fff;font-size:22px;font-weight:800;text-align:center;background:rgba(0,0,0,.2)">Poll sticker here</div>
''')


# ---------------- Batch 6: public transit + AI travel agent ----------------
OCEAN_BG = '<div style="position:absolute;inset:0;background:radial-gradient(120% 90% at 0% 0%,#e9f6fa 0%,#fbf5ea 55%,#f3e6d2 100%)"></div>'


def line_chip(text, color, size=26):
    return f'<span style="display:inline-block;background:{color};color:#fff;border-radius:10px;padding:{size * 0.15:.0f}px {size * 0.45:.0f}px;font:700 {size}px Nunito,sans-serif;letter-spacing:.02em">{text}</span>'


def step_row(icon, title, sub='', time='', color='#2c9cc0', last=False, size=27, hint=''):
    rail = '' if last else f'<div style="position:absolute;left:{size * 0.95:.0f}px;top:{size * 2.1:.0f}px;bottom:-6px;width:6px;border-radius:3px;background:{color};opacity:.35"></div>'
    hint_html = f'<div style="margin-top:10px;border-radius:14px;background:#fff6ec;border:1.5px solid #f3d9bf;padding:10px 14px;font-size:{size * 0.78:.0f}px;font-weight:800;color:#8a4a20">💡 {hint}</div>' if hint else ''
    return f'''<div style="position:relative;display:flex;gap:18px;padding-bottom:{size * 0.9:.0f}px">{rail}
  <div style="flex:none;width:{size * 2:.0f}px;height:{size * 2:.0f}px;border-radius:50%;background:{color};color:#fff;display:grid;place-items:center;font-size:{size:.0f}px">{icon}</div>
  <div style="flex:1;min-width:0"><div style="display:flex;justify-content:space-between;gap:12px;align-items:baseline">
    <div style="font-size:{size}px;font-weight:800;line-height:1.3">{title}</div><div style="flex:none;font-size:{size * 0.85:.0f}px;font-weight:900;color:#6e645b">{time}</div></div>
    <div style="font-size:{size * 0.8:.0f}px;font-weight:700;color:#6e645b;margin-top:2px">{sub}</div>{hint_html}</div></div>'''


EXAMPLE = '<div style="font-size:18px;font-weight:900;letter-spacing:.12em;color:#9d9389">EXAMPLE JOURNEY</div>'
S8 = line_chip('S8', '#2f8f3a')
RJ = line_chip('Railjet', '#c8102e')

journey = (step_row('🚶', 'Walk to the S-Bahn station', 'Munich Airport · 4 min', '09:02', '#9d9389')
           + step_row('🚆', f'Take {S8} towards Herrsching', 'Munich Airport → München Hbf · 12 stops', '09:10', '#2f8f3a')
           + step_row('🚶', 'Change at München Hbf', 'Find your train on the board ("Abfahrt")', '09:52', '#9d9389', hint='14 min to change.')
           + step_row('🚄', f'Take {RJ} towards Wien', 'München Hbf → Salzburg Hbf', '10:06', '#c8102e')
           + step_row('🏁', 'Arrive at Salzburg Hbf', 'Follow the exit signs ("Ausgang")', '11:35', '#2f2a26', last=True))


def phone(inner, x, y, w=560, h=1080, rotate=0):
    return f'''<div style="position:absolute;left:{x}px;top:{y}px;width:{w}px;height:{h}px;border-radius:64px;background:#1d1a18;padding:16px;
  box-shadow:0 30px 80px rgba(40,30,20,.35);transform:rotate({rotate}deg)">
  <div style="width:100%;height:100%;border-radius:50px;overflow:hidden;background:#fbf6ee;position:relative">
    <div style="position:absolute;left:50%;top:14px;transform:translateX(-50%);width:150px;height:34px;border-radius:20px;background:#1d1a18"></div>
    <div style="padding:70px 28px 28px">{inner}</div></div></div>'''


# Carousel 6: trains, step by step.
TRAIN = [
    ('cover', 'TRAINS · SUBWAYS · BUSES', 'Transit,<br><span class="clay">step by step.</span>', 'Every walk, ride and change between your stops, with real departure times.'),
    ('walk', 'STEP 1 · GET TO THE STATION', 'Know where<br>to start.', 'Trypr tells you which station to walk to, and what to look for when you get there.'),
    ('ride', 'STEP 2 · RIDE', 'Know which<br>train to take.', 'The line, the direction it says on the front, and how many stops until you get off.'),
    ('change', 'STEP 3 · CHANGE', 'Know how long<br>you have.', 'Tight change? Trypr says head straight there. Long one? Grab a snack.'),
    ('arrive', 'STEP 4 · ARRIVE', 'Know the words<br>on the signs.', 'Platform, departures and exit, in the local language.'),
]
focus = {
    'walk': step_row('🚶', 'Walk to the S-Bahn station', 'Munich Airport · 4 min', '09:02', '#9d9389', size=40, hint='Head into the station, then find your train on the departure boards ("Abfahrt").'),
    'ride': step_row('🚆', f'Take {line_chip("S8", "#2f8f3a", 40)} towards Herrsching', 'Munich Airport → München Hbf · 12 stops · 42 min', '09:10', '#2f8f3a', size=40, last=True),
    'change': step_row('🚶', 'Change at München Hbf', 'S8 arrives 09:52 · Railjet leaves 10:06', '', '#9d9389', size=40, last=True, hint='14 min to change. Find your train on the board ("Abfahrt").'),
    'arrive': ''.join(f'<div style="display:flex;justify-content:space-between;padding:28px 4px;border-bottom:1.5px solid #eadfce;font-size:44px;font-weight:800"><span>{en}</span><span class="clay">{de}</span></div>' for en, de in [('Platform', 'Gleis'), ('Departures', 'Abfahrt'), ('Exit', 'Ausgang')]),
}
for i, (key, eb, h, sub) in enumerate(TRAIN):
    if key == 'cover':
        visual = phone(f'{EXAMPLE}<div style="font:600 30px Fredoka,sans-serif;margin:6px 0 18px">Munich Airport → Salzburg</div>{journey.replace("font-size:27px", "font-size:22px")}', 470, 300, 560, 1120)
        txt_w = 380
    else:
        visual = f'<div class="glass" style="position:absolute;left:72px;right:72px;top:50%;transform:translateY(-20%);border-radius:44px;padding:50px 48px;background:rgba(255,255,255,.92)">{EXAMPLE}<div style="height:22px"></div>{focus[key]}</div>'
        txt_w = 900
    ADS[f'transit-{i + 1}-{key}'] = (1080, 1350, f'''
{OCEAN_BG}
<div class="logo" style="right:40px;top:30px;width:200px;height:112px"></div>
<div style="position:absolute;left:72px;top:{220 if key == 'cover' else 90}px;width:{txt_w}px">{eyebrow(eb)}
  <div class="display" style="font-size:{80 if key == 'cover' else 84}px;margin-top:12px">{h}</div>
  <div style="font-size:28px;font-weight:700;color:#4a4039;margin-top:18px;line-height:1.4">{sub}</div></div>
{visual}{dots(5, i, 72, 46)}
''')

# Transit singles.
ADS['transit-post-01-plan-the-train'] = (1080, 1350, f'''
{OCEAN_BG}
<div class="logo" style="left:40px;top:30px;width:230px;height:130px"></div>
<div style="position:absolute;left:72px;top:200px;width:430px">{eyebrow('PUBLIC TRANSIT')}
  <div class="display" style="font-size:78px;margin-top:12px">The train is<br>part of the<br><span class="clay">trip too.</span></div>
  <div style="font-size:27px;font-weight:700;color:#4a4039;margin-top:20px;line-height:1.4">Step-by-step transit between your stops, right inside your itinerary.</div></div>
{phone(f'{EXAMPLE}<div style="font:600 30px Fredoka,sans-serif;margin:6px 0 18px">Munich Airport → Salzburg</div>{journey.replace("font-size:27px", "font-size:22px")}', 500, 120, 540, 1120, 3)}
''')

ADS['transit-post-02-tight-change'] = (1080, 1350, f'''
<div style="position:absolute;inset:0;background:#2f2a26"></div>
<div style="position:absolute;inset:0;background:radial-gradient(80% 60% at 50% 35%,rgba(231,128,67,.35),rgba(47,42,38,0) 70%)"></div>
<div class="logo" style="left:40px;top:30px;width:230px;height:130px"></div>
<div style="position:absolute;left:72px;right:72px;top:250px;text-align:center;color:#fff">
  <div class="display" style="font-size:230px;color:#f5a46e;line-height:1">4 min</div>
  <div class="display" style="font-size:64px;margin-top:20px">to change trains?</div></div>
<div class="glass" style="position:absolute;left:90px;right:90px;bottom:150px;border-radius:36px;padding:34px 40px;background:rgba(255,255,255,.94)">
  <div style="font-size:20px;font-weight:900;letter-spacing:.12em;color:#9d9389">TRYPR SAYS</div>
  <div style="font-size:38px;font-weight:800;margin-top:10px;line-height:1.35">💡 Only 4 min to change: head straight there, don’t stop for food or tickets.</div></div>
''')

SIGNS = [('🇩🇪', 'Gleis', 'Abfahrt', 'Ausgang'), ('🇫🇷', 'Voie / Quai', 'Départs', 'Sortie'), ('🇮🇹', 'Binario', 'Partenze', 'Uscita'), ('🇪🇸', 'Andén / Vía', 'Salidas', 'Salida')]
sign_rows = ''.join(f'<div style="display:grid;grid-template-columns:70px 1fr 1fr 1fr;gap:10px;align-items:center;padding:16px 0;border-top:1.5px solid #eadfce;font-size:27px;font-weight:800"><span style="font-size:40px">{f}</span><span>{a}</span><span>{b}</span><span>{c}</span></div>' for f, a, b, c in SIGNS)
ADS['transit-post-03-sign-words'] = (1080, 1350, f'''
{OCEAN_BG}
<div class="logo" style="right:40px;top:30px;width:230px;height:130px"></div>
<div style="position:absolute;left:72px;top:90px;width:700px">{eyebrow('SAVE THIS BEFORE EUROPE')}
  <div class="display" style="font-size:84px;margin-top:12px">Read the station<br><span class="clay">like a local.</span></div></div>
<div class="glass" style="position:absolute;left:72px;right:72px;top:470px;border-radius:40px;padding:30px 40px;background:rgba(255,255,255,.92)">
  <div style="display:grid;grid-template-columns:70px 1fr 1fr 1fr;gap:10px;font-size:22px;font-weight:900;letter-spacing:.08em;color:#2c9cc0;padding-bottom:12px"><span></span><span>PLATFORM</span><span>DEPARTURES</span><span>EXIT</span></div>
  {sign_rows}</div>
<div style="position:absolute;left:72px;right:72px;bottom:70px;font-size:26px;font-weight:800;color:#4a4039">Trypr shows the right words for the station you’re in.</div>
''')

times = ''.join(f'<div style="display:flex;justify-content:space-between;align-items:center;padding:18px 6px;border-bottom:1.5px solid #eadfce;font-size:30px;font-weight:800;{"background:#e9f6fa;border-radius:16px;padding:18px 16px" if sel else ""}"><span>{d} → {a}</span><span style="color:#6e645b;font-size:24px">{dur}</span></div>' for d, a, dur, sel in [('08:10', '10:05', '1 h 55', False), ('09:10', '11:35', '2 h 25', True), ('10:10', '12:05', '1 h 55', False)])
ADS['transit-post-04-leave-at'] = (1080, 1350, f'''
{OCEAN_BG}
<div class="logo" style="right:40px;top:30px;width:230px;height:130px"></div>
<div style="position:absolute;left:72px;top:90px;width:760px">{eyebrow('REAL DEPARTURE TIMES')}
  <div class="display" style="font-size:84px;margin-top:12px">Pick when you leave.<br><span class="clay">See what runs.</span></div></div>
<div class="glass" style="position:absolute;left:72px;right:72px;top:480px;border-radius:40px;padding:36px 40px;background:rgba(255,255,255,.92)">
  {EXAMPLE}
  <div style="display:flex;align-items:center;gap:16px;margin:18px 0 10px;font-size:28px;font-weight:800"><span>🕘 Leave at</span>
    <span style="border-radius:14px;border:2px solid #2c9cc0;padding:8px 18px;color:#1d7f9f">Tue 09:00</span></div>
  {times}
  <div style="font-size:21px;font-weight:700;color:#9d9389;margin-top:16px">Times are shown in the station’s local time.</div></div>
''')

ADS['transit-post-05-local-tips'] = (1080, 1350, f'''
{OCEAN_BG}
<div class="logo" style="right:40px;top:30px;width:230px;height:130px"></div>
<div style="position:absolute;left:72px;top:90px;width:760px">{eyebrow('FIRST TIME ON THE SUBWAY?')}
  <div class="display" style="font-size:80px;margin-top:12px">Tips a local<br><span class="clay">would give you.</span></div></div>
<div style="position:absolute;left:72px;right:72px;top:470px;display:grid;gap:20px">
{''.join(f'<div class="glass" style="border-radius:30px;padding:26px 32px;display:flex;gap:22px;align-items:center;background:rgba(255,255,255,.92)"><span style="font-size:50px">{e}</span><span style="font-size:29px;font-weight:800;line-height:1.35">{t}</span></div>' for e, t in [('🚇', 'Subway entrances are often just a staircase down from the sidewalk.'), ('🎟️', 'Buy a ticket before you board. Many systems fine riders without one.'), ('🏛️', 'Big station? Allow 10 minutes to find your platform.'), ('☕', '22 minutes to change: enough time for a snack.')])}
</div>
''')

legs_tl = [('🚗', 'Drive', 'Home → Toronto Pearson', '#e78043'), ('✈️', 'Fly', 'Toronto → Munich', '#2c9cc0'), ('🚆', 'Train', 'Munich Airport → Salzburg', '#2f8f3a'), ('🥾', 'Hike', 'Salzburg → Untersberg', '#7d9a5a')]
ADS['transit-post-06-every-mode'] = (1080, 1350, f'''
{OCEAN_BG}
<div class="logo" style="right:40px;top:30px;width:230px;height:130px"></div>
<div style="position:absolute;left:72px;top:90px;width:760px">{eyebrow('ONE TRIP · FOUR WAYS TO MOVE')}
  <div class="display" style="font-size:84px;margin-top:12px">Drive. Fly.<br><span class="clay">Train. Hike.</span></div></div>
<div class="glass" style="position:absolute;left:72px;right:72px;top:470px;border-radius:40px;padding:40px 40px 14px;background:rgba(255,255,255,.92)">
  {EXAMPLE}<div style="height:18px"></div>
  {''.join(step_row(e, f'{m}', s, '', c, last=(i == len(legs_tl) - 1), size=32) for i, (e, m, s, c) in enumerate(legs_tl))}</div>
<div style="position:absolute;left:72px;right:72px;bottom:60px;font-size:26px;font-weight:800;color:#4a4039">Every leg gets the right kind of route.</div>
''')

ADS['transit-post-07-up-express'] = (1080, 1350, f'''
<div style="position:absolute;inset:0;background:linear-gradient(160deg,#1d7f9f 0%,#2c9cc0 55%,#77c4d6 100%)"></div>
<div class="logo" style="left:40px;top:30px;width:230px;height:130px"></div>
<div style="position:absolute;left:72px;right:72px;top:220px;color:#fff">{eyebrow('TORONTO', '#d6f0f7')}
  <div class="display" style="font-size:96px;margin-top:12px">Landing at<br>Pearson?</div>
  <div style="font-size:32px;font-weight:800;margin-top:18px;opacity:.95">Trypr plans the ride downtown, step by step.</div></div>
<div class="glass" style="position:absolute;left:72px;right:72px;bottom:110px;border-radius:40px;padding:36px 40px 10px;background:rgba(255,255,255,.94)">
  {EXAMPLE}<div style="height:16px"></div>
  {step_row('🚶', 'Walk to the UP Express station', 'Terminal 1, Toronto Pearson', '', '#9d9389', size=28)}
  {step_row('🚆', f'Take {line_chip("UP Express", "#1d7f9f", 26)} towards Union', 'Pearson → Union Station · about 25 min', '', '#1d7f9f', size=28)}
  {step_row('🏁', 'Arrive at Union Station', 'Downtown Toronto', '', '#2f2a26', last=True, size=28)}</div>
''')

ADS['transit-post-08-no-more-tabs'] = (1080, 1350, f'''
<div style="position:absolute;inset:0;background:#fbf5ea"></div>
<div class="logo" style="right:40px;top:30px;width:230px;height:130px"></div>
<div style="position:absolute;left:72px;top:90px;width:760px">{eyebrow('TRAVELLING BY TRAIN?')}
  <div class="display" style="font-size:84px;margin-top:12px">Your itinerary<br><span class="clay">and your train,</span><br>finally together.</div></div>
<div style="position:absolute;left:72px;right:72px;top:600px;display:grid;grid-template-columns:1fr 1fr;gap:22px">
  <div class="glass" style="border-radius:32px;padding:30px;background:rgba(255,255,255,.9);opacity:.85"><div style="font-size:20px;font-weight:900;letter-spacing:.12em;color:#9d9389">BEFORE</div>
    <div style="font-size:27px;font-weight:700;color:#7d7268;line-height:1.7;margin-top:12px;text-decoration:line-through">Trip plan in one app<br>Train times in another<br>Hotel in your email<br>Screenshot of the map</div></div>
  <div class="glass" style="border-radius:32px;padding:30px;background:rgba(255,255,255,.95)"><div style="font-size:20px;font-weight:900;letter-spacing:.12em;color:#2c9cc0">TRYPR</div>
    <div style="font-size:27px;font-weight:800;line-height:1.7;margin-top:12px">Every stop<br>Every train, step by step<br>Every night<br>One map</div></div></div>
''')

ADS['story-11-transit'] = (1080, 1920, f'''
{OCEAN_BG}
<div class="logo" style="left:50%;top:70px;width:320px;height:180px;transform:translateX(-50%)"></div>
<div style="position:absolute;left:60px;right:60px;top:280px;text-align:center">
  <div class="pill" style="background:#2c9cc0;color:#fff;padding:12px 26px;font-size:26px">NEW</div>
  <div class="display" style="font-size:92px;margin-top:20px">Transit,<br><span class="clay">step by step.</span></div></div>
{phone(f'{EXAMPLE}<div style="font:600 30px Fredoka,sans-serif;margin:6px 0 18px">Munich Airport → Salzburg</div>{journey.replace("font-size:27px", "font-size:22px")}', 240, 650, 600, 1080)}
<div class="pill" style="position:absolute;left:50%;bottom:60px;transform:translateX(-50%);background:#e78043;color:#fff;padding:24px 46px;font-size:32px;white-space:nowrap">Try it · tryprtravel.com</div>
''')

# Carousel 7 + singles: AI travel agent.
def ai_card(icon, title, meta, tag=''):
    tag_html = f'<span class="pill" style="background:#e9f6fa;color:#1d7f9f;padding:6px 14px;font-size:19px">{tag}</span>' if tag else ''
    return f'''<div style="display:flex;gap:18px;align-items:center;padding:18px;border-radius:24px;background:#fff;border:1.5px solid #eadfce">
  <div style="flex:none;width:72px;height:72px;border-radius:20px;background:#fff1e6;display:grid;place-items:center;font-size:38px">{icon}</div>
  <div style="flex:1"><div style="font:600 29px Fredoka,sans-serif;line-height:1.15">{title}</div><div style="font-size:21px;font-weight:700;color:#6e645b;margin-top:4px">{meta}</div></div>
  <div class="pill" style="flex:none;background:#2c9cc0;color:#fff;padding:12px 18px;font-size:20px">+ Add</div></div>'''


AGENT_HEAD = '<div style="display:flex;align-items:center;gap:12px;font:600 30px Fredoka,sans-serif;color:#00897b">🧭 Trypr Travel Agent</div>'
EX_SUG = '<div style="font-size:18px;font-weight:900;letter-spacing:.12em;color:#9d9389;margin-top:14px">EXAMPLE SUGGESTIONS</div>'


def chips(items, active):
    return '<div style="display:flex;flex-wrap:wrap;gap:10px;margin-top:16px">' + ''.join(
        f'<span class="pill" style="padding:10px 18px;font-size:21px;{"background:#e78043;color:#fff" if t == active else "background:#fff;border:1.5px solid #eadfce;color:#4a4039"}">{t}</span>' for t in items) + '</div>'


ACT_TYPES = ['Adventure', 'Food & Drink', 'Culture/Museum', 'Relaxation', 'Sightseeing', 'Nightlife', 'Attractions']
AI_SLIDES = [
    ('cover', 'AI TRAVEL AGENT', 'Not sure what<br>to do there?<br><span class="clay">Ask Trypr.</span>', 'Ideas for food, stays and things to do, picked for your trip.', None),
    ('dinner', 'FOOD & DRINK', 'Where’s dinner<br><span class="clay">tonight?</span>', 'Set a budget, pick Food & Drink, and get spots near where you’re staying.',
     AGENT_HEAD + chips(ACT_TYPES[:4], 'Food & Drink') + chips(['$', '$$', '$$$'], '$$') + EX_SUG + '<div style="display:grid;gap:12px;margin-top:12px">'
     + ai_card('🍝', 'Neighbourhood trattoria', '$$ · 10 min walk · Dinner', 'Food & Drink') + ai_card('🍜', 'Late-night noodle bar', '$ · near your hotel', 'Food & Drink') + '</div>'),
    ('stays', 'HOTELS · HOSTELS · CAMPING', 'Where do we<br><span class="clay">sleep?</span>', 'Pick hotel, hostel or camping and get three options with a price and rating.',
     AGENT_HEAD + chips(['Hotel', 'Hostel', 'Camping'], 'Hotel') + EX_SUG + '<div style="display:grid;gap:12px;margin-top:12px">'
     + ai_card('🏨', 'Boutique hotel, old town', '~$180 / night · ★ 4.6') + ai_card('🛏️', 'Central hostel', '~$45 / night · ★ 4.4') + ai_card('⛺', 'Lakeside campground', '~$35 / night · ★ 4.5') + '</div>'),
    ('activities', 'THINGS TO DO', 'Half a day free?<br><span class="clay">Fill it.</span>', 'Tell it how much time you have and what you’re into.',
     AGENT_HEAD + chips(ACT_TYPES, 'Sightseeing') + chips(['1-2 Hours', 'Half Day (4 hrs)', 'Full Day (8+ hrs)'], 'Half Day (4 hrs)') + EX_SUG + '<div style="display:grid;gap:12px;margin-top:12px">'
     + ai_card('🏰', 'Castle and old town walk', 'About 3 hours · Sightseeing') + '</div>'),
    ('add', 'ONE TAP', 'Like it?<br><span class="clay">Add it to a day.</span>', 'Suggestions drop straight into your itinerary.',
     '<div style="font:600 32px Fredoka,sans-serif">Add to which day?</div><div style="display:grid;gap:12px;margin-top:18px">'
     + ''.join(f'<div style="display:flex;justify-content:space-between;align-items:center;padding:20px 24px;border-radius:20px;{"background:#e78043;color:#fff" if d == 2 else "background:#fff;border:1.5px solid #eadfce"};font-size:27px;font-weight:800"><span>Day {d}</span><span style="font-size:22px;opacity:.85">{lbl}</span></div>' for d, lbl in [(1, 'Arrive'), (2, 'Free afternoon'), (3, 'Day trip'), (4, 'Fly home')]) + '</div>'),
]
for i, (key, eb, h, sub, card) in enumerate(AI_SLIDES):
    if card is None:
        visual = f'''<div class="glass" style="position:absolute;left:72px;right:72px;top:700px;border-radius:40px;padding:36px;background:rgba(255,255,255,.92)">{AGENT_HEAD}
  <div style="display:grid;grid-template-columns:1fr 1fr 1fr;gap:16px;margin-top:22px">{''.join(f'<div style="border-radius:24px;background:#fff;border:1.5px solid #eadfce;padding:22px;text-align:center"><div style="font-size:52px">{e}</div><div style="font:600 27px Fredoka,sans-serif;margin-top:8px">{t}</div></div>' for e, t in [('🍽️', 'Dinner'), ('🏨', 'Stays'), ('🎟️', 'Things to do')])}</div></div>'''
    else:
        visual = f'<div class="glass" style="position:absolute;left:72px;right:72px;top:560px;border-radius:40px;padding:36px;background:rgba(255,255,255,.93)">{card}</div>'
    ADS[f'ai-{i + 1}-{key}'] = (1080, 1350, f'''
{CREAM}
<div class="logo" style="right:40px;top:30px;width:200px;height:112px"></div>
<div style="position:absolute;left:72px;top:{150 if card is None else 80}px;width:820px">{eyebrow(eb, '#00897b')}
  <div class="display" style="font-size:{84 if card is None else 78}px;margin-top:12px">{h}</div>
  <div style="font-size:27px;font-weight:700;color:#4a4039;margin-top:16px;line-height:1.4">{sub}</div></div>
{visual}{dots(5, i, 72, 46)}
''')

ADS['ai-post-01-dinner'] = (1080, 1350, f'''
{photo('DSC_0214.jpg', '50% 45%', 'linear-gradient(180deg,rgba(30,18,8,.55) 0%,rgba(30,18,8,0) 35%,rgba(30,18,8,0) 50%,rgba(30,18,8,.6) 100%)')}
{LOGO_TL}
{headline(190, 100, 'Where’s dinner<br><span style="color:#ffd2ad">tonight?</span>')}
<div class="glass" style="position:absolute;left:72px;right:72px;bottom:90px;border-radius:36px;padding:30px 34px;background:rgba(255,255,255,.9)">
  {AGENT_HEAD}{chips(['Food & Drink', '$$', '1-2 Hours'], 'Food & Drink')}
  <div style="font-size:26px;font-weight:800;color:#4a4039;margin-top:18px;line-height:1.4">Ask the Trypr Travel Agent for spots that fit your budget and your evening.</div></div>
''')

STAY_OPTS = [('🏨', 'Hotel', 'Boutique hotel, old town', '~$180', '4.6'), ('🛏️', 'Hostel', 'Central hostel, private room', '~$45', '4.4'), ('⛺', 'Camping', 'Lakeside campground', '~$35', '4.5')]
STAY_CARDS = ''.join(
    f'<div class="glass" style="border-radius:32px;padding:28px 32px;display:flex;align-items:center;gap:26px;background:rgba(255,255,255,.93)">'
    f'<div style="flex:none;width:110px;height:110px;border-radius:28px;background:#fff1e6;display:grid;place-items:center;font-size:60px">{e}</div>'
    f'<div style="flex:1"><div style="font-size:20px;font-weight:900;letter-spacing:.12em;color:#00897b">{k.upper()}</div>'
    f'<div style="font:600 36px Fredoka,sans-serif;margin-top:4px">{n}</div><div style="font-size:25px;font-weight:800;color:#6e645b;margin-top:4px">{p} / night · ★ {r}</div></div>'
    f'<div class="pill" style="flex:none;background:#2c9cc0;color:#fff;padding:14px 22px;font-size:24px">+ Add</div></div>' for e, k, n, p, r in STAY_OPTS)
ADS['ai-post-02-hotel-hostel-camp'] = (1080, 1350, f'''
{CREAM}
<div class="logo" style="right:40px;top:30px;width:230px;height:130px"></div>
<div style="position:absolute;left:72px;top:90px;width:760px">{eyebrow('AI TRAVEL AGENT', '#00897b')}
  <div class="display" style="font-size:88px;margin-top:12px">Hotel, hostel<br><span class="clay">or campsite?</span></div>
  <div style="font-size:28px;font-weight:700;color:#4a4039;margin-top:16px">Pick one. Trypr suggests three, with a price and a rating.</div></div>
<div style="position:absolute;left:72px;right:72px;top:560px;display:grid;gap:22px">
{STAY_CARDS}
</div>
<div style="position:absolute;left:72px;bottom:60px;font-size:20px;font-weight:900;letter-spacing:.12em;color:#9d9389">EXAMPLE SUGGESTIONS</div>
''')

ADS['ai-post-03-free-afternoon'] = (1080, 1350, f'''
{ophoto('DSC_0337.jpg', '50% 50%')}
{LOGO_TL}
{headline(190, 96, 'Free afternoon?<br><span style="color:#ffd2ad">Get ideas that fit.</span>')}
<div class="glass" style="position:absolute;left:72px;right:72px;bottom:90px;border-radius:36px;padding:30px 34px;background:rgba(255,255,255,.9)">
  {AGENT_HEAD}{chips(['1-2 Hours', 'Half Day (4 hrs)', 'Full Day (8+ hrs)'], 'Half Day (4 hrs)')}
  {chips(['Adventure', 'Sightseeing', 'Relaxation', 'Nightlife'], 'Adventure')}</div>
''')

ADS['ai-post-04-travel-agent'] = (1080, 1350, f'''
<div style="position:absolute;inset:0;background:linear-gradient(160deg,#00897b 0%,#2c9cc0 100%)"></div>
<div class="logo" style="left:40px;top:30px;width:230px;height:130px"></div>
<div style="position:absolute;left:72px;right:72px;top:220px;color:#fff">{eyebrow('MEET YOUR', '#d6f0f7')}
  <div class="display" style="font-size:104px;margin-top:10px">Travel agent<br>in your pocket.</div></div>
<div style="position:absolute;left:72px;right:72px;bottom:110px;display:grid;grid-template-columns:1fr 1fr;gap:18px">
{''.join(f'<div class="glass" style="border-radius:28px;padding:26px;background:rgba(255,255,255,.92)"><div style="font-size:46px">{e}</div><div style="font:600 32px Fredoka,sans-serif;margin-top:6px">{t}</div><div style="font-size:21px;font-weight:700;color:#6e645b">{s_}</div></div>' for e, t, s_ in [('🍽️', 'Dinner spots', 'By budget, $ to $$$'), ('🏨', 'Places to stay', 'Hotel, hostel, camping'), ('🎟️', 'Things to do', 'By type and time free'), ('📍', 'Stops between', 'Along your route')])}
</div>
''')

ADS['story-12-ask-trypr'] = (1080, 1920, f'''
{CREAM}
<div class="logo" style="left:50%;top:70px;width:320px;height:180px;transform:translateX(-50%)"></div>
<div style="position:absolute;left:60px;right:60px;top:290px;text-align:center">{eyebrow('AI TRAVEL AGENT', '#00897b', 26)}
  <div class="display" style="font-size:96px;margin-top:14px">Dinner? Hotel?<br><span class="clay">Ask Trypr.</span></div></div>
<div class="glass" style="position:absolute;left:80px;right:80px;top:760px;border-radius:44px;padding:40px;background:rgba(255,255,255,.93)">
  {AGENT_HEAD}{chips(['Food & Drink', 'Sightseeing', 'Nightlife'], 'Food & Drink')}{chips(['$', '$$', '$$$'], '$$')}{EX_SUG}
  <div style="display:grid;gap:12px;margin-top:12px">{ai_card('🍝', 'Neighbourhood trattoria', '$$ · 10 min walk', 'Food & Drink')}{ai_card('🏨', 'Boutique hotel, old town', '~$180 / night · ★ 4.6')}{ai_card('🏰', 'Castle and old town walk', 'About 3 hours')}</div></div>
<div class="pill" style="position:absolute;left:50%;bottom:90px;transform:translateX(-50%);background:#e78043;color:#fff;padding:26px 48px;font-size:34px;white-space:nowrap">Try it · tryprtravel.com</div>
''')


# ---------------- Teaser: rebrand ----------------
OLD_LOGO = f'file://{REPO}/frontend/public/images/TryprLogo_White.png'
ADS['teaser-new-beginning'] = (1080, 1350, f'''
{photo('DSC_0206.jpg', '50% 55%', 'linear-gradient(180deg,rgba(18,12,8,.82) 0%,rgba(18,12,8,.45) 45%,rgba(18,12,8,.35) 70%,rgba(18,12,8,.85) 100%)')}
<div style="position:absolute;left:50%;top:430px;width:900px;height:640px;transform:translate(-50%,-50%);background:radial-gradient(closest-side,rgba(245,164,110,.45),rgba(245,164,110,0))"></div>
<div style="position:absolute;left:0;right:0;top:90px;text-align:center">
  <span class="pill" style="border:2px solid rgba(255,255,255,.55);color:#fff;padding:12px 30px;font-size:24px;letter-spacing:.18em">COMING SOON</span></div>
<div class="logo" style="left:50%;top:430px;width:820px;height:460px;transform:translate(-50%,-50%);filter:drop-shadow(0 20px 50px rgba(0,0,0,.45))"></div>
<div class="display" style="position:absolute;left:60px;right:60px;top:720px;text-align:center;color:#fff;font-size:112px;text-shadow:0 4px 30px rgba(0,0,0,.4)">A new<br><span style="color:#f5a46e">beginning.</span></div>
<div style="position:absolute;left:0;right:0;top:1005px;text-align:center;color:#fff;font-size:32px;font-weight:800;opacity:.92">New look. New Trypr. Almost here.</div>
<div style="position:absolute;left:50%;bottom:70px;transform:translateX(-50%);display:flex;align-items:center;gap:28px">
  <div style="width:130px;height:130px;background:url({OLD_LOGO}) center/contain no-repeat;opacity:.45"></div>
  <div style="color:rgba(255,255,255,.7);font-size:44px">→</div>
  <div style="width:170px;height:96px;background:url({LOGO}) center/contain no-repeat"></div>
</div>
''')


def render(name, out_dir, scale):
    w, h, body = ADS[name]
    html = f'<!doctype html><html><head><meta charset="utf-8"><style>:root{{--w:{w}px;--h:{h}px}}{BASE_CSS}{MAP_CSS}{paddlesvg.PADDLE_CSS}.map,.pmap{{width:100%;height:100%;display:block}}</style></head><body>{body}</body></html>'
    src = os.path.join(HERE, f'{name}.html')
    open(src, 'w').write(html)
    out = os.path.join(out_dir, f'{name}.png')
    subprocess.run([CHROME, '--headless=new', '--disable-gpu', '--hide-scrollbars', '--allow-file-access-from-files',
                    f'--force-device-scale-factor={scale}', f'--window-size={w},{h}', '--virtual-time-budget=8000',
                    f'--screenshot={out}', f'file://{src}'], check=True, capture_output=True)
    print(name, out)


if __name__ == '__main__':
    out_dir = sys.argv[1]
    os.makedirs(out_dir, exist_ok=True)
    for name in sys.argv[2:] or ADS:
        render(name, out_dir, 2 if name.startswith('portfolio') else 1)
