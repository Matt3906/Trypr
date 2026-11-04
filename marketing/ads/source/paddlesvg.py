"""On-brand SVG map of a paddle route (lakes, portages, campsites) computed by the app's water router."""
import json
import math
import os

DATA = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'data') if os.path.exists(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), 'data', 'paddle.json')) else os.path.dirname(os.path.abspath(__file__))
paddle = json.load(open(os.path.join(DATA, 'paddle.json')))

LAT0 = 45.6
COS = math.cos(math.radians(LAT0))
K = 4000


def xy(lat, lon):
    return ((lon + 79) * COS * K, (46 - lat) * K)


def path_d(pts, close=False):
    out, last = [], None
    for lat, lon in pts:
        x, y = xy(lat, lon)
        p = (round(x, 1), round(y, 1))
        if p == last:
            continue
        out.append(('M' if not out else 'L') + f'{p[0]} {p[1]}')
        last = p
    return ''.join(out) + ('Z' if close else '')


def vb_for(bounds, px_w, px_h):
    x0, y1 = xy(bounds[0], bounds[1])
    x1, y0 = xy(bounds[2], bounds[3])
    scale = min(px_w / (x1 - x0), px_h / (y1 - y0))
    cx, cy, vw, vh = (x0 + x1) / 2, (y0 + y1) / 2, px_w / scale, px_h / scale
    return f'{cx - vw / 2:.1f} {cy - vh / 2:.1f} {vw:.1f} {vh:.1f}', (cx - vw / 2, cy - vh / 2, vw, vh)


def route_bounds(pad=0.012):
    pts = [p for leg in paddle['legs'] for run in leg['runs'] for p in run['path']]
    lats, lons = [p[0] for p in pts], [p[1] for p in pts]
    return (min(lats) - pad, min(lons) - pad, max(lats) + pad, max(lons) + pad)


def svg(px_w, px_h, bounds=None, unit=1.0, labels=True, highlight=None, extra_class=''):
    vb, (vx, vy, vw, vh) = vb_for(bounds or route_bounds(), px_w, px_h)

    def visible(pts):
        xs = [xy(a, b) for a, b in pts]
        return any(vx - 50 <= x <= vx + vw + 50 and vy - 50 <= y <= vy + vh + 50 for x, y in xs[:: max(1, len(xs) // 40)] + xs[-1:])

    lakes = ''.join(f'<path d="{"".join(path_d(r, True) for r in area)}"/>' for area in paddle['areas'] if any(visible(r) for r in area))
    portages = ''.join(f'<path d="{path_d(l)}"/>' for l in paddle['portages'] if visible(l))
    rivers = ''.join(f'<path d="{path_d(l)}"/>' for l in paddle.get('channels', []) if visible(l))
    camps = []
    for lat, lon in paddle['camps']:
        x, y = xy(lat, lon)
        if not (vx <= x <= vx + vw and vy <= y <= vy + vh):
            continue
        s = 6 * unit
        camps.append(f'<path d="M{x:.1f} {y - s:.1f}L{x + s * 0.9:.1f} {y + s * 0.6:.1f}L{x - s * 0.9:.1f} {y + s * 0.6:.1f}Z"/>')
    on = [l for i, l in enumerate(paddle['legs']) if highlight is None or i in highlight]
    off = [l for i, l in enumerate(paddle['legs']) if highlight is not None and i not in highlight]
    paddle_d = ''.join(path_d(r['path']) for leg in on for r in leg['runs'] if r['kind'] == 'paddle')
    carry_d = ''.join(path_d(r['path']) for leg in on for r in leg['runs'] if r['kind'] != 'paddle')
    dim_d = ''.join(path_d(r['path']) for leg in off for r in leg['runs'])
    marks = []
    for i, st in enumerate(paddle['stops']):
        x, y = xy(st['lat'], st['lon'])
        r = 15 * unit
        fill = '#2f2a26' if i == 0 else '#2c9cc0'
        marks.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r:.1f}" fill="{fill}" stroke="#fff" stroke-width="{4 * unit:.1f}"/>'
                     f'<text x="{x:.1f}" y="{y + r * 0.36:.1f}" font-size="{r * 1.05:.1f}" class="num">{"ABC"[i]}</text>')
        if labels:
            dx, anchor = (22 * unit, 'start') if i == 0 else (-22 * unit, 'end')
            marks.append(f'<text class="lbl" x="{x + dx:.1f}" y="{y + 7 * unit:.1f}" font-size="{19 * unit:.1f}" text-anchor="{anchor}">{st["name"]}</text>')
    return f'''<svg class="pmap {extra_class}" viewBox="{vb}" preserveAspectRatio="xMidYMid slice" xmlns="http://www.w3.org/2000/svg">
<rect x="-99999" y="-99999" width="999999" height="999999" class="land"/>
<g class="lakes" fill-rule="evenodd">{lakes}</g>
<g class="rivers" stroke-width="{5 * unit:.1f}">{rivers}</g>
<g class="portages" stroke-width="{2.4 * unit:.1f}">{portages}</g>
<g class="camps">{''.join(camps)}</g>
<path class="dim" d="{dim_d}" stroke-width="{4 * unit:.1f}"/>
<path class="casing" d="{paddle_d}{carry_d}" stroke-width="{11 * unit:.1f}"/>
<path class="paddle" d="{paddle_d}" stroke-width="{5.5 * unit:.1f}"/>
<path class="carry-casing" d="{carry_d}" stroke-width="{14 * unit:.1f}"/>
<path class="carry" d="{carry_d}" stroke-width="{8 * unit:.1f}" stroke-dasharray="{0.1:.1f} {14 * unit:.1f}"/>
{''.join(marks)}
</svg>'''


PADDLE_CSS = '''
.pmap .land{fill:#f3ead9}
.pmap .lakes path{fill:#a9d8e6;stroke:#8ac7da;stroke-width:1}
.pmap .portages path{fill:none;stroke:#8d6e63;stroke-dasharray:5 4;opacity:.8}
.pmap .camps path{fill:#e5a33c;opacity:.9}
.pmap .casing{fill:none;stroke:#fff;stroke-linecap:round;stroke-linejoin:round}
.pmap .paddle{fill:none;stroke:#e46f2f;stroke-linecap:round;stroke-linejoin:round}
.pmap.zoomed .lakes path{stroke-width:.12}
.pmap.zoomed .portages path{stroke-dasharray:.7 .5}
.pmap .dim{fill:none;stroke:#e46f2f;opacity:.3;stroke-linecap:round;stroke-linejoin:round}
.pmap .carry{fill:none;stroke:#2f2a26;stroke-linecap:round}
.pmap .carry-casing{fill:none;stroke:#fff;stroke-linecap:round;stroke-linejoin:round}
.pmap .rivers path{fill:none;stroke:#8ac7da;stroke-linecap:round;stroke-linejoin:round}
.pmap .num{fill:#fff;font-family:Fredoka,sans-serif;font-weight:600;text-anchor:middle}
.pmap .lbl{fill:#2f2a26;font-family:Fredoka,sans-serif;font-weight:600;paint-order:stroke;stroke:#fff;stroke-width:5px;stroke-linejoin:round}
'''
