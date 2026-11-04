"""Builds an on-brand SVG map of the Western Uplands loop from OSM data (lakes, trails, campsites) and the app's routed path."""
import json
import math

import os

DATA = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'data')
loop = json.load(open(os.path.join(DATA, 'loop.json')))
lakes_raw = json.load(open(os.path.join(DATA, 'lakes.json')))

BOX = loop['box']
COS = math.cos(math.radians((BOX['south'] + BOX['north']) / 2))
K = 4000  # svg units per degree latitude
W = (BOX['east'] - BOX['west']) * COS * K
H = (BOX['north'] - BOX['south']) * K


def xy(lat, lon):
    return ((lon - BOX['west']) * COS * K, (BOX['north'] - lat) * K)


def path_d(pts, close=False):
    out = []
    last = None
    for i, (lat, lon) in enumerate(pts):
        x, y = xy(lat, lon)
        p = (round(x, 1), round(y, 1))
        if p == last:
            continue
        out.append(('M' if not out else 'L') + f'{p[0]} {p[1]}')
        last = p
    return ''.join(out) + ('Z' if close else '')


def stitch(parts):
    def same(a, b):
        return abs(a[0] - b[0]) < 1e-7 and abs(a[1] - b[1]) < 1e-7
    rings, open_ = [], []
    for p in parts:
        if len(p) < 2:
            continue
        (rings if len(p) >= 4 and same(p[0], p[-1]) else open_).append(p)
    while open_:
        ring = open_.pop()
        joined = True
        while joined and not same(ring[0], ring[-1]):
            joined = False
            for i, c in enumerate(open_):
                if same(c[0], ring[-1]):
                    ring = ring + c[1:]
                elif same(c[-1], ring[-1]):
                    ring = ring + c[::-1][1:]
                else:
                    continue
                open_.pop(i)
                joined = True
                break
        if len(ring) >= 4:
            rings.append(ring)
    return rings


lake_paths = []
for e in lakes_raw['elements']:
    if e['type'] == 'way':
        g = [(p['lat'], p['lon']) for p in e.get('geometry') or []]
        if len(g) >= 4 and g[0] == g[-1]:
            lake_paths.append(path_d(g, True))
    elif e['type'] == 'relation':
        parts = [[(p['lat'], p['lon']) for p in m.get('geometry') or []] for m in e.get('members', []) if m.get('type') == 'way']
        rings = stitch(parts)
        if rings:
            lake_paths.append(''.join(path_d(r, True) for r in rings))


def fit_view(px_w, px_h, scale):
    """viewBox of px_w x px_h pixels at `scale` px per unit, centred on the routed loop and kept inside the data box."""
    xs, ys = zip(*(xy(lat, lon) for l in loop['legs'] for lat, lon in l['path']))
    vw, vh = px_w / scale, px_h / scale
    x0 = min(max((min(xs) + max(xs)) / 2 - vw / 2, 0), max(W - vw, 0))
    y0 = min(max((min(ys) + max(ys)) / 2 - vh / 2, 0), max(H - vh, 0))
    return f'{x0:.1f} {y0:.1f} {vw:.1f} {vh:.1f}'


def svg(view=None, route_width=7, show_labels=True, label_scale=1.0, extra_class='', vb=None, highlight=None, straight=False):
    """view: (south, west, north, east) crop; vb: explicit viewBox; defaults to the whole box."""
    if vb:
        pass
    elif view:
        x0, y1 = xy(view[0], view[1])
        x1, y0 = xy(view[2], view[3])
        vb = f'{x0:.0f} {y0:.0f} {x1 - x0:.0f} {y1 - y0:.0f}'
    else:
        vb = f'0 0 {W:.0f} {H:.0f}'
    trails = ''.join(f'<path d="{path_d(t)}"/>' for t in loop['trails'])
    lakes = ''.join(f'<path d="{d}"/>' for d in lake_paths)
    legs = loop['legs']
    if straight:
        pts = [(st['lat'], st['lon']) for st in loop['stops']]
        route = path_d(pts)
        dim = ''
    elif highlight is not None:
        route = ''.join(path_d(l['path']) for i, l in enumerate(legs) if i in highlight)
        dim = ''.join(path_d(l['path']) for i, l in enumerate(legs) if i not in highlight)
    else:
        route = ''.join(path_d(l['path']) for l in legs)
        dim = ''
    camps = []
    for lat, lon in loop['camps']:
        x, y = xy(lat, lon)
        s = 7
        camps.append(f'<path d="M{x:.1f} {y - s:.1f}L{x + s * 0.9:.1f} {y + s * 0.6:.1f}L{x - s * 0.9:.1f} {y + s * 0.6:.1f}Z"/>')
    # Night stops (skip the Islet waypoint) and the trailhead.
    marks = []
    night = 0
    for st in loop['stops'][1:-1]:
        x, y = xy(st['lat'], st['lon'])
        if st['name'].startswith('Islet'):
            marks.append(f'<circle class="via" cx="{x:.1f}" cy="{y:.1f}" r="{9 * label_scale:.1f}"/>')
            continue
        night += 1
        r = 26 * label_scale
        marks.append(f'<g class="stop"><circle cx="{x:.1f}" cy="{y:.1f}" r="{r:.1f}"/><text x="{x:.1f}" y="{y + r * 0.36:.1f}" font-size="{r * 1.05:.1f}">{night}</text></g>')
    th = loop['stops'][0]
    x, y = xy(th['lat'], th['lon'])
    r = 30 * label_scale
    marks.append(f'<g class="th"><rect x="{x - r:.1f}" y="{y - r:.1f}" width="{2 * r:.1f}" height="{2 * r:.1f}" rx="{r * 0.45:.1f}"/><text x="{x:.1f}" y="{y + r * 0.3:.1f}" font-size="{r * 0.78:.1f}">TH</text></g>')
    labels = ''
    if show_labels:
        lx, ly = xy(th['lat'], th['lon'])
        fs = 30 * label_scale
        labels = f'<text class="lbl" x="{lx + 40 * label_scale:.1f}" y="{ly + 12 * label_scale:.1f}" font-size="{fs:.1f}">Hwy 60</text>'
    return f'''<svg class="map {extra_class}" viewBox="{vb}" preserveAspectRatio="xMidYMid slice" xmlns="http://www.w3.org/2000/svg">
<rect x="-5000" y="-5000" width="20000" height="20000" class="land"/>
<g class="lakes" fill-rule="evenodd">{lakes}</g>
<g class="trails">{trails}</g>
<g class="camps">{''.join(camps)}</g>
<path class="route-dim" d="{dim}" stroke-width="{route_width * 0.7:.1f}"/>
<path class="route-casing" d="{route}" stroke-width="{route_width + 6}"/>
<path class="route" d="{route}" stroke-width="{route_width}"/>
{''.join(marks)}{labels}
</svg>'''


MAP_CSS = '''
.map .land{fill:#f3ead9}
.map .lakes path{fill:#a9d8e6;stroke:#8ac7da;stroke-width:1.2}
.map .trails path{fill:none;stroke:#7d9a5a;stroke-width:2.6;stroke-linecap:round;stroke-linejoin:round;opacity:.75}
.map .camps path{fill:#e5a33c;opacity:.85}
.map .route-casing{fill:none;stroke:#fff;stroke-linecap:round;stroke-linejoin:round;opacity:.95}
.map .route{fill:none;stroke:#e46f2f;stroke-linecap:round;stroke-linejoin:round}
.map .route-dim{fill:none;stroke:#e46f2f;opacity:.32;stroke-linecap:round;stroke-linejoin:round}
.map.straight .route{stroke-dasharray:14 12}
.map .stop circle{fill:#2c9cc0;stroke:#fff;stroke-width:5}
.map .stop text,.map .th text{fill:#fff;font-family:Fredoka,sans-serif;font-weight:600;text-anchor:middle}
.map .th rect{fill:#2f2a26;stroke:#fff;stroke-width:5}
.map .via{fill:#fff;stroke:#2c9cc0;stroke-width:5}
.map .lbl{fill:#6e645b;font-family:Nunito,sans-serif;font-weight:800;letter-spacing:.04em}
'''

if __name__ == '__main__':
    print('size', round(W), round(H), 'lakes', len(lake_paths), 'trails', len(loop['trails']), 'camps', len(loop['camps']))
