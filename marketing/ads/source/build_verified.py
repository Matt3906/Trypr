"""Renders the "Verified Trip Wednesday" Instagram carousels (1080x1350).
Usage:
  python3 -I build_verified.py --maps [trip-key ...]      render the real maps (needs network; node + Chrome)
  python3 -I build_verified.py OUT_DIR [trip-key ...]     render the slides

Slides per trip: cover, route (real map of every stop), one slide per stretch of the trip (zoomed map of those days,
pins numbered to the stop list, three real photos from the area), know-before-you-go, open-in-Trypr.
Trip data is a snapshot of the public verifiedTrips collection (verified/trips.json); clay covers are the site's own.
Photos are from Wikimedia Commons (verified/photos, attribution in verified/credits.json) and credited on every photo.
Maps are OpenStreetMap data served by OpenFreeMap, drawn by render_maps.mjs.
"""
import html as H
import json
import math
import os
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from build import BASE_CSS, CHROME, LOGO  # noqa: E402

V = f'{HERE}/verified'
PHOTOS = f'file://{V}/photos'
COVERS = f'file://{V}/covers'
MAPS = f'{V}/maps'
CREDITS = json.load(open(f'{V}/credits.json'))
TRIPS_BY_ID = {d['id']: d['data'] for d in json.load(open(f'{V}/trips.json'))['docs']}
CREAM = '<div style="position:absolute;inset:0;background:radial-gradient(120% 80% at 0% 0%,#fff 0%,#fbf5ea 55%,#f3e6d2 100%)"></div>'
MAP_W, DAY_MAP_H = 936, 490

# days: (eyebrow, heading, [(stop, lat, lon)], [photo refs]). A ref is "<trip>-<slot>" or a landmark key; the file is photos/<ref>.jpg.
TRIPS = [
    dict(key='kyoto', id='A0T8bN7k8qEfMKyTJfnH', slug='kyoto-osaka', title='Kyoto & Osaka', country='JAPAN', mode='🚆 Train',
         tagline='Ancient shrines, geisha districts, street food and a night in a traditional ryokan', focal='50% 50%',
         days=[
             ('DAYS 2–3 · KYOTO', 'Temples, gold & tea', [('Fushimi Inari Taisha', 34.968, 135.779), ('Kiyomizu-dera', 34.995, 135.785), ('Gion at dusk', 35.004, 135.775), ('Kinkaku-ji (Golden Pavilion)', 35.039, 135.729)], ['kyoto-1', 'kiyomizu', 'gion']),
             ('DAY 4 · ARASHIYAMA', 'Bamboo, gardens & a ryokan night', [('Arashiyama Bamboo Grove', 35.017, 135.671), ('Tenryu-ji Temple and gardens', 35.016, 135.674), ('Monkey Park and Togetsukyo Bridge', 35.011, 135.677)], ['kyoto-2', 'togetsukyo', 'tenryuji']),
             ('DAYS 6–7 · OSAKA', 'Eat your way through Osaka', [('Osaka Castle', 34.687, 135.526), ('Dotonbori food crawl', 34.669, 135.503), ('Kuromon Market', 34.665, 135.506), ('Shinsekai and Tsutenkaku', 34.652, 135.506), ('Umeda Sky Building', 34.705, 135.490)], ['kyoto-3', 'osakacastle', 'tsutenkaku'])],
         know_title='Know before you go',
         cards=[('🌸', 'Best time', 'Late March to April for cherry blossoms, mid-November for autumn leaves'), ('💴', 'Budget', 'Roughly $150–250 USD per person per day'),
                ('🚆', 'Getting around', 'Haruka Express from KIX to Kyoto (about 75 min), then an ICOCA card for trains, buses and konbini')],
         tips_title='INSIDER TIPS', tips=['Visit Fushimi Inari before 7am to beat the crowds', 'Carry cash for small shops and shrines', 'Book your ryokan and tea ceremony 1–2 months ahead in peak season']),
    dict(key='italy', id='iX8OCw1RlLTJyGs7ExtX', slug='rome-florence-venice', title='Rome, Florence & Venice', country='ITALY', mode='🚆 Train',
         tagline='The Colosseum, the Vatican, Renaissance Florence and gondolas in Venice on a high-speed train loop', focal='38% 50%',
         days=[
             ('DAYS 1–3 · ROME', 'Ruins, the Vatican & pasta', [('Trevi Fountain', 41.901, 12.483), ('Colosseum', 41.890, 12.492), ('Roman Forum', 41.892, 12.486), ('Pantheon', 41.899, 12.477), ("Vatican and St. Peter's", 41.902, 12.454)], ['italy-1', 'trevi', 'vatican']),
             ('DAYS 4–5 · FLORENCE', 'The Renaissance in two days', [('Duomo and the Dome', 43.773, 11.256), ('Uffizi Gallery', 43.768, 11.255), ('Ponte Vecchio', 43.768, 11.253), ('Accademia (David)', 43.777, 11.259), ('Piazzale Michelangelo', 43.763, 11.265)], ['italy-2', 'duomo', 'michelangelo']),
             ('DAYS 6–7 · VENICE', 'Canals, gondolas & islands', [("St. Mark's Basilica", 45.435, 12.340), ('Rialto Market', 45.440, 12.334), ('Murano glass', 45.457, 12.357), ('Burano', 45.485, 12.417)], ['italy-3', 'stmarks', 'murano'])],
         know_title='Know before you go',
         cards=[('🌤️', 'Best time', 'April to June and September to October. Avoid August'), ('💶', 'Budget', 'Roughly $140–280 USD per person per day'),
                ('🚆', 'Getting around', 'Frecciarossa: Rome to Florence about 1.5 hrs, Florence to Venice about 2 hrs')],
         tips_title='INSIDER TIPS', tips=['Book Colosseum, Vatican, Uffizi and Accademia tickets weeks ahead', 'Cover shoulders and knees for churches', 'Validate regional train tickets before boarding']),
    dict(key='bali', id='Qu9qwjzKYsEcBIoCN02K', slug='bali', title='Bali', country='INDONESIA', mode='🚗 Car',
         tagline='Ubud jungle, sacred water temples, Tanah Lot at sunset, Uluwatu cliffs and a day trip to Nusa Penida', focal='30% 50%',
         days=[
             ('DAYS 1–3 · UBUD', 'Rice terraces & holy water', [('Sacred Monkey Forest', -8.519, 115.261), ('Ubud Palace and Market', -8.507, 115.263), ('Campuhan Ridge Walk', -8.504, 115.255), ('Tegalalang Rice Terraces', -8.432, 115.279), ('Tirta Empul', -8.416, 115.315)], ['bali-1', 'tirta', 'monkey']),
             ('DAYS 4–5 · TANAH LOT TO ULUWATU', 'Sunset temples & clifftops', [('Tanah Lot', -8.617, 115.087), ('Padang Padang Beach', -8.811, 115.104), ('Bingin Beach', -8.806, 115.113), ('Uluwatu Temple', -8.829, 115.085)], ['bali-2', 'padang', 'kecak']),
             ('DAY 6 · NUSA PENIDA', 'A boat day to the dramatic coast', [('Sanur harbour (fast boat)', -8.670, 115.261), ('Kelingking Beach', -8.751, 115.473), ("Angel's Billabong and Broken Beach", -8.733, 115.451)], ['bali-3', 'broken', 'angel'])],
         know_title='Know before you go',
         cards=[('☀️', 'Best time', 'April to October (dry season)'), ('💵', 'Budget', 'Roughly $60–200 USD per person per day'),
                ('🚗', 'Getting around', 'A private driver (about 600–800k IDR a day) or Grab/Gojek. Traffic is heavy around Canggu and Seminyak')],
         tips_title='INSIDER TIPS', tips=['Wear a sarong and sash at temples', "Don't step on the offerings left on the ground", 'Book Nusa Penida fast boats early and check sea conditions']),
    dict(key='capetown', id='qkvoql8TdxvKBGcohd8J', slug='cape-town-winelands', title='Cape Town & the Winelands', country='SOUTH AFRICA', mode='🚗 Car',
         tagline='Table Mountain, the Cape Peninsula, Robben Island, Stellenbosch vineyards and whale season in Hermanus', focal='42% 50%',
         days=[
             ('DAY 3 · CAPE PENINSULA', 'The edge of Africa', [("Chapman's Peak Drive", -34.096, 18.357), ('Hout Bay harbour', -34.055, 18.344), ('Boulders Beach penguins', -34.196, 18.450), ('Cape Point', -34.351, 18.485)], ['capetown-2', 'capetown-1', 'chapman']),
             ('DAYS 1–4 · CAPE TOWN', 'Mountain, harbour & history', [('V&A Waterfront', -33.908, 18.420), ('Table Mountain', -33.948, 18.403), ('Bo-Kaap', -33.918, 18.414), ('Robben Island', -33.808, 18.371), ('Kirstenbosch Gardens', -33.988, 18.433)], ['cablecar', 'bokaap', 'kirsten']),
             ('DAYS 5–6 · WINELANDS', 'Lunch among the vines', [('Stellenbosch town', -33.940, 18.856), ('Estate wine tasting', -33.969, 18.862), ('Franschhoek', -33.911, 19.120)], ['capetown-3', 'franschhoek', 'stellenbosch'])],
         know_title='Know before you go',
         cards=[('🐋', 'Best time', 'November to March is warm. August to November for whales in Hermanus'), ('💵', 'Budget', 'Roughly $90–220 USD per person per day'),
                ('🚗', 'Getting around', 'Uber or Bolt in the city. Rent a car for days 3, 5, 6 and 7 (they drive on the left)')],
         tips_title='INSIDER TIPS', tips=['Check the Table Mountain cable car status on the day', 'Book Robben Island 1–2 weeks ahead', 'Use rideshare at night in the city centre']),
    dict(key='portugal', id='g8Wt8QM56w1sq0VGsYxE', slug='lisbon-sintra-porto', title='Lisbon, Sintra & Porto', country='PORTUGAL', mode='🚆 Train',
         tagline='Pastel de nata, fairytale palaces, tram rides and a day in the Douro Valley vineyards', focal='45% 50%',
         days=[
             ('DAYS 1–3 · LISBON', 'Hills, trams & pastéis', [('Alfama', 38.712, -9.130), ('Castelo de São Jorge', 38.714, -9.133), ('Time Out Market', 38.707, -9.146), ('Jerónimos Monastery', 38.698, -9.207), ('Belém Tower', 38.692, -9.216)], ['alfama', 'belem', 'jeronimos']),
             ('DAY 4 · SINTRA', 'A fairytale palace day', [('Pena Palace', 38.788, -9.391), ('Quinta da Regaleira', 38.796, -9.396)], ['portugal-1', 'regaleira', 'moors']),
             ('DAYS 5–6 · PORTO', 'Tiles, port & the river', [('Ribeira waterfront', 41.143, -8.610), ('Livraria Lello', 41.147, -8.615), ('São Bento Station tiles', 41.145, -8.610), ('Clérigos Tower', 41.146, -8.615), ('Port cellars in Gaia', 41.138, -8.625)], ['portugal-2', 'saobento', 'lello']),
             ('DAY 7 · DOURO VALLEY', 'Vineyards by train', [('São Bento Station, Porto', 41.145, -8.610), ('Pinhão: quinta wine tasting', 41.189, -7.541)], ['portugal-3', 'pinhao', 'rabelo'])],
         know_title='Know before you go',
         cards=[('🌤️', 'Best time', 'April to June and September to October: warm, fewer crowds'), ('💶', 'Budget', 'Roughly $110–200 USD per person per day'),
                ('🚆', 'Getting around', 'Lisbon to Porto by train in about 3 hrs. Skip the rental car in the cities')],
         tips_title='INSIDER TIPS', tips=['Wear flat, grippy shoes: the cobbled hills are slippery', 'Buy Pena Palace and Regaleira tickets online', 'Watch for pickpockets on Tram 28']),
    dict(key='peru', id='Is5FLgIxQXNIDtcu62fe', slug='cusco-machu-picchu', title='Cusco & Machu Picchu', country='PERU', mode='✈️ Fly & rail',
         tagline='Inca ruins, colourful markets, the Sacred Valley and a sunrise at Machu Picchu', focal='58% 50%',
         rename={'Sacred Valley Healing, Trauma Therapy , Therapeutic Body Work and Ceremonies.': 'Sacred Valley'},
         days=[
             ('DAYS 2–3 · CUSCO', 'Inca stone & a pisco sour', [('Plaza de Armas', -13.517, -71.979), ('San Pedro Market', -13.521, -71.983), ('Qorikancha', -13.520, -71.975), ('Saqsaywaman fortress', -13.510, -71.982)], ['peru-1', 'saqsay', 'qorikancha']),
             ('DAY 4 · SACRED VALLEY', 'Markets, salt mines & terraces', [('Pisac ruins and market', -13.408, -71.844), ('Maras salt mines', -13.304, -72.154), ('Moray terraces', -13.330, -72.197)], ['peru-2', 'maras', 'pisac']),
             ('DAYS 5–6 · MACHU PICCHU', 'The train to the lost city', [('Ollantaytambo fortress', -13.257, -72.266), ('Aguas Calientes', -13.158, -72.523), ('Machu Picchu', -13.163, -72.545)], ['peru-3', 'llama', 'perurail'])],
         know_title='Know before you go',
         cards=[('☀️', 'Best time', 'May to September is dry season. June to August is busiest, so book early'), ('💵', 'Budget', 'Roughly $90–250 USD per person per day'),
                ('⛰️', 'Altitude', 'Cusco sits at about 3,400 m. Take it slow, sip coca tea and skip the alcohol on night one')],
         tips_title='INSIDER TIPS', tips=['Book Machu Picchu tickets and trains months ahead', 'Bring soles in cash for markets and small shops', 'Pack sunscreen, a rain jacket and layers']),
    dict(key='westcoast', id='AM45gOBkQAEA1TXgfEyt', slug='west-coast', title='West Coast', country='CANADA · USA', mode='🚗 Road trip',
         tagline='A month across Canada and the United States', focal='35% 50%',
         days=[
             ('DAYS 2–5 · NORTHERN ONTARIO', 'Giants, falls & bear spray', [('Timmins', 48.469, -81.329), ('Sleeping Giant', 48.362, -88.800), ('Terry Fox Monument', 48.485, -89.168), ('Kakabeka Falls', 48.402, -89.616)], ['westcoast-1', 'kakabeka', 'terryfox']),
             ('JASPER · BANFF', 'Ten days in the Rockies', [('Jasper National Park', 52.873, -117.954), ('Banff National Park', 51.497, -115.928)], ['westcoast-2', 'louise', 'rundle']),
             ('OLYMPIC TO YELLOWSTONE', 'National park hopping', [('Vancouver', 49.283, -123.121), ('Olympic National Park', 47.802, -123.604), ('Glacier National Park', 48.526, -113.982), ('Grand Teton area', 43.756, -110.919), ('Yellowstone (Gardiner)', 45.032, -110.706)], ['westcoast-3', 'hoh', 'prismatic'])],
         know_title='By the numbers',
         cards=[('📅', 'Length', '32 days'), ('🚗', 'Distance', '10,687 km by car'), ('📍', 'Stops', '15 stops across Canada and the USA')],
         tips_title='ON THE ROUTE', tips=['Sleeping Giant, Jasper and Banff', 'Vancouver, Olympic and Glacier National Parks', 'Grand Teton, Yellowstone and Custer State Park']),
    dict(key='western', id='v94WtyVmetTdGhKhlGlO', slug='western-americas', title='Western Americas', country='CANADA · USA', mode='🚗 Road trip',
         tagline='44 days from the Rockies to the Pacific, through the best national parks in Canada and the USA', focal='62% 50%',
         days=[
             ('ROCKIES TO THE TETONS', 'Mountains, geysers & wildlife', [('Banff', 51.178, -115.571), ('Kananaskis Village', 50.917, -115.147), ('Glacier National Park', 48.526, -113.982), ('Yellowstone', 44.598, -110.561), ('Grand Teton', 43.790, -110.682)], ['vermilion', 'oxbow', 'oldfaithful']),
             ('BRYCE · ZION', 'Utah red rock', [('Bryce Canyon', 37.593, -112.187), ('Zion National Park', 37.298, -113.026), ('Grand Canyon', 36.100, -112.112)], ['western-1', 'bryce', 'narrows']),
             ('GRAND CANYON · YOSEMITE', 'Big canyons, bigger trees', [('Grand Canyon', 36.100, -112.112), ('Sequoia National Park', 36.486, -118.566), ('Yosemite National Park', 37.865, -119.538)], ['western-2', 'sequoia', 'bridalveil']),
             ('THE PACIFIC NORTHWEST', 'Lakes, volcanoes & rainforest', [('Crater Lake', 42.945, -122.109), ('Portland', 45.515, -122.678), ('Mount Rainier', 46.867, -121.700), ('Olympic National Park', 47.802, -123.604), ('Vancouver', 49.283, -123.121)], ['western-3', 'rainier', 'hurricane'])],
         know_title='By the numbers',
         cards=[('📅', 'Length', '44 days'), ('🚗', 'Distance', '6,751 km by car'), ('📍', 'Stops', '17 stops across Canada and the USA')],
         tips_title='ON THE ROUTE', tips=['Banff, Yellowstone and Grand Teton', 'Bryce, Zion and the Grand Canyon', 'Sequoia, Yosemite, Crater Lake and Olympic']),
]
for i, t in enumerate(TRIPS, 1):
    t['n'] = i
    t['total'] = 4 + len(t['days'])
PHOTO_FOCAL = {}  # ref -> css background-position when the default centre crop cuts the subject


# ---------------------------------------------------------------- maps
def trip_waypoints(trip):
    data = TRIPS_BY_ID[trip['id']]
    return [dict(w, name=trip.get('rename', {}).get(w['name'], w['name'])) for w in data['waypoints']]


def route_panel_h(n):
    list_h = (math.ceil(n / 2) if n > 6 else n) * 46
    return max(420, min(660, 1350 - 370 - 90 - list_h - 36))


def bounds_of(pts, min_span=0.006):
    lons, lats = [p[1] for p in pts], [p[0] for p in pts]
    w, e, s, n = min(lons), max(lons), min(lats), max(lats)
    if e - w < min_span:
        w, e = w - min_span / 2, e + min_span / 2
    if n - s < min_span:
        s, n = s - min_span / 2, n + min_span / 2
    return [w, s, e, n]


def map_jobs(trip):
    jobs = []
    wps = trip_waypoints(trip)
    pts = [(w['lat'], w['lon']) for w in wps]
    n = len(wps)
    jobs.append(dict(out=f"{MAPS}/{trip['key']}-route.png", w=MAP_W, h=route_panel_h(n), bounds=bounds_of(pts), pad=70, maxZoom=11, small=n > 5, declutter=True,
                     line=[[lon, lat] for lat, lon in pts], lineWidth=6,
                     pins=[dict(lon=lon, lat=lat, n=i + 1, dark=i in (0, n - 1) and n > 1) for i, (lat, lon) in enumerate(pts)]))
    for i, (_, _, stops, _) in enumerate(trip['days'], 1):
        sp = [(la, lo) for _, la, lo in stops]
        jobs.append(dict(out=f"{MAPS}/{trip['key']}-day{i}.png", w=MAP_W, h=DAY_MAP_H, bounds=bounds_of(sp), pad=100, maxZoom=15, declutter=True,
                         line=[[lo, la] for la, lo in sp], lineWidth=6, pins=[dict(lon=lo, lat=la, n=k + 1) for k, (la, lo) in enumerate(sp)]))
    return jobs


def build_maps(keys):
    jobs = [j for t in TRIPS if not keys or t['key'] in keys for j in map_jobs(t)]
    os.makedirs(MAPS, exist_ok=True)
    with tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as f:
        json.dump(jobs, f)
    subprocess.run(['node', f'{HERE}/render_maps.mjs', f.name], check=True)


# ---------------------------------------------------------------- slides
def credit_text(ref):
    c = CREDITS[f'{ref}.jpg']
    return f"{H.escape(c['author'])} · {H.escape(c['license'])}"


def credit_el(ref, bottom=26):
    c = CREDITS[f'{ref}.jpg']
    lic = c['license']
    return (f'<div style="position:absolute;left:72px;right:72px;bottom:{bottom}px;font-size:18px;font-weight:800;color:rgba(255,255,255,.88);'
            f'text-shadow:0 1px 8px rgba(0,0,0,.6)">📷 Photo: {credit_text(ref)}{"" if lic == "CC0" else " (cropped)"} · via Wikimedia Commons</div>')


def badge(trip):
    return (f'<div class="pill glass-dark" style="position:absolute;right:44px;top:44px;padding:12px 24px;font-size:20px;letter-spacing:.1em">'
            f'✅ VERIFIED TRIP WEDNESDAY · #{trip["n"]}</div>')


def counter(idx, total):
    return f'<div class="pill glass-dark" style="position:absolute;right:44px;top:44px;padding:10px 22px;font-size:22px">{idx} / {total}</div>'


def chips(trip, data):
    km = round(data.get('totalKm') or 0)
    items = [f'📅 {data["recommendedDays"]} days', f'📍 {len(data["waypoints"])} stops']
    if km:
        items.append(f'🗺️ {km:,} km')
    items.append(trip['mode'])
    return ''.join(f'<span class="pill glass-dark" style="padding:12px 24px;font-size:26px">{c}</span>' for c in items)


def pin(n, dark=False, size=34):
    return (f'<div style="flex:none;width:{size}px;height:{size}px;border-radius:50%;background:{"#2f2a26" if dark else "#2c9cc0"};color:#fff;'
            f'display:grid;place-items:center;font:600 {size * 0.6:.0f}px Fredoka,sans-serif">{n}</div>')


MAP_CREDIT = ('<div style="position:absolute;right:10px;bottom:8px;padding:3px 10px;border-radius:8px;background:rgba(255,255,255,.85);'
              'font-size:13px;font-weight:700;color:#4a4039">© OpenStreetMap contributors · OpenFreeMap</div>')


def map_card(path, top, h, radius=36):
    return (f'<div style="position:absolute;left:72px;top:{top}px;width:{MAP_W}px;height:{h}px;border-radius:{radius}px;overflow:hidden;'
            f'box-shadow:0 18px 48px rgba(74,56,40,.25),0 2px 6px rgba(74,56,40,.12);border:5px solid #fff;background:#eee">'
            f'<img src="file://{path}" style="width:100%;height:100%;object-fit:cover;display:block">{MAP_CREDIT}</div>')


def slide_cover(trip, data):
    t = trip['title']
    size = 124 if len(t) <= 12 else 100 if len(t) <= 24 else 88
    ref = f"{trip['key']}-0"
    return f'''
<div class="photo" style="background-image:url({PHOTOS}/{ref}.jpg);background-position:{trip['focal']} "></div>
<div style="position:absolute;inset:0;background:linear-gradient(180deg,rgba(24,18,12,.55) 0%,rgba(24,18,12,0) 24%,rgba(24,18,12,0) 30%,rgba(24,18,12,.42) 52%,rgba(24,18,12,.88) 100%)"></div>
<div class="logo" style="left:44px;top:34px;width:230px;height:130px"></div>
{badge(trip)}
<div style="position:absolute;left:72px;right:72px;bottom:96px;color:#fff">
  <div style="font-size:26px;font-weight:900;letter-spacing:.16em;color:#f5a46e;text-shadow:0 2px 14px rgba(0,0,0,.5)">{trip['country']} · {data['recommendedDays']} DAYS</div>
  <div class="display" style="font-size:{size}px;margin-top:10px;text-shadow:0 4px 30px rgba(0,0,0,.45)">{H.escape(t)}</div>
  <div style="font-size:30px;font-weight:800;margin-top:20px;line-height:1.35;max-width:900px;text-shadow:0 2px 14px rgba(0,0,0,.5)">{H.escape(trip['tagline'])}</div>
  <div style="margin-top:30px;display:flex;flex-wrap:wrap;gap:12px">{chips(trip, data)}</div>
  <div style="margin-top:26px;font-size:28px;font-weight:900;color:#ffd2ad">Swipe for the plan →</div>
</div>
{credit_el(ref)}
'''


def slide_route(trip, data):
    wps = trip_waypoints(trip)
    n = len(wps)
    rows = []
    for i, p in enumerate(wps, 1):
        name = p['name'] if len(p['name']) <= 28 else p['name'][:27].rstrip() + '…'
        d = p.get('days') or 1
        rows.append(f'<div style="display:flex;align-items:center;gap:14px;height:46px">{pin(i, i in (1, n) and n > 1)}'
                    f'<div style="flex:1;font-weight:800;font-size:25px;white-space:nowrap">{H.escape(name)}</div>'
                    f'<div style="font-weight:900;font-size:22px;color:#cf5a28;white-space:nowrap">{d} {"day" if d == 1 else "days"}</div></div>')
    half = math.ceil(n / 2)
    cols = (f'<div style="display:grid;grid-template-columns:1fr 1fr;column-gap:44px;align-items:start"><div>{"".join(rows[:half])}</div><div>{"".join(rows[half:])}</div></div>'
            if n > 6 else f'<div>{"".join(rows)}</div>')
    panel_h = route_panel_h(n)
    return f'''
{CREAM}
<div class="logo" style="left:44px;top:34px;width:230px;height:130px"></div>
{counter(2, trip['total'])}
<div style="position:absolute;left:72px;right:72px;top:190px">
  <div style="font-size:24px;font-weight:900;letter-spacing:.14em;color:#2c9cc0">THE ROUTE</div>
  <div class="display" style="font-size:72px;margin-top:8px">{n} stops. <span class="clay">{data['recommendedDays']} days.</span></div>
</div>
{map_card(f"{MAPS}/{trip['key']}-route.png", 370, panel_h)}
<div style="position:absolute;left:72px;right:72px;top:{370 + panel_h + 30}px">{cols}</div>
<div style="position:absolute;left:72px;bottom:30px;font-size:16px;font-weight:800;color:#9d9389;letter-spacing:.04em">LINES CONNECT THE STOPS IN ORDER · THEY ARE NOT ROADS</div>
'''


def photo_tile(ref, style):
    pos = PHOTO_FOCAL.get(ref, '50% 50%')
    return (f'<div style="position:relative;border-radius:26px;overflow:hidden;background:#ddd url({PHOTOS}/{ref}.jpg) {pos}/cover;{style};'
            f'box-shadow:0 10px 26px rgba(74,56,40,.22);border:4px solid #fff">'
            f'<div style="position:absolute;left:8px;bottom:8px;padding:3px 10px;border-radius:8px;background:rgba(30,22,16,.62);color:#fff;font-size:14px;font-weight:800">📷 {credit_text(ref)}</div></div>')


def slide_day(trip, data, k):
    eyebrow, heading, stops, refs = trip['days'][k - 1]
    idx = 2 + k
    big, s1, s2 = refs
    photos = (f'<div style="position:absolute;left:72px;top:806px;width:{MAP_W}px;height:330px;display:grid;grid-template-columns:520px 1fr;grid-template-rows:1fr 1fr;gap:12px">'
              f'{photo_tile(big, "grid-row:1 / span 2")}{photo_tile(s1, "")}{photo_tile(s2, "")}</div>')
    half = math.ceil(len(stops) / 2)
    cells = [f'<div style="display:flex;align-items:center;gap:14px;height:46px;min-width:0">{pin(i)}<div style="font-weight:800;font-size:25px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">{H.escape(name)}</div></div>'
             for i, (name, _, _) in enumerate(stops, 1)]
    lst = f'<div style="display:grid;grid-template-columns:1fr 1fr;column-gap:36px;grid-auto-flow:column;grid-template-rows:repeat({half},46px)">{"".join(cells)}</div>'
    return f'''
{CREAM}
<div class="logo" style="left:44px;top:14px;width:190px;height:106px"></div>
{counter(idx, trip['total'])}
<div style="position:absolute;left:72px;right:72px;top:128px">
  <div style="font-size:22px;font-weight:900;letter-spacing:.13em;color:#2c9cc0">{H.escape(eyebrow)}</div>
  <div class="display" style="font-size:56px;margin-top:4px;line-height:1.04">{H.escape(heading)}</div>
</div>
{map_card(f"{MAPS}/{trip['key']}-day{k}.png", 296, DAY_MAP_H)}
{photos}
<div style="position:absolute;left:72px;right:72px;top:1156px">{lst}</div>
<div style="position:absolute;left:72px;right:72px;bottom:18px;font-size:15px;font-weight:800;color:#9d9389">Photos: Wikimedia Commons (cropped) · Map © OpenStreetMap contributors</div>
'''


def slide_know(trip, data):
    cards = ''.join(f'<div class="glass" style="border-radius:30px;padding:26px 32px;display:flex;align-items:center;gap:26px;background:#fffdf9;backdrop-filter:none;-webkit-backdrop-filter:none">'
                    f'<div style="flex:none;width:96px;height:96px;border-radius:26px;background:#fff1e6;display:grid;place-items:center;font-size:54px">{e}</div>'
                    f'<div><div style="font-size:20px;font-weight:900;letter-spacing:.12em;color:#00897b">{l.upper()}</div>'
                    f'<div style="font:600 {40 if len(t) < 24 else 29}px Fredoka,sans-serif;margin-top:4px;line-height:1.25">{H.escape(t)}</div></div></div>' for e, l, t in trip['cards'])
    tips = ''.join(f'<div style="display:flex;gap:14px;align-items:flex-start;padding:8px 0;font-size:27px;font-weight:800;line-height:1.3"><span style="color:#e78043">●</span><span>{H.escape(t)}</span></div>' for t in trip['tips'])
    return f'''
{CREAM}
<div class="logo" style="left:44px;top:34px;width:230px;height:130px"></div>
{counter(trip['total'] - 1, trip['total'])}
<div style="position:absolute;left:72px;right:72px;top:190px">
  <div style="font-size:24px;font-weight:900;letter-spacing:.14em;color:#2c9cc0">{H.escape(trip['title'].upper())}</div>
  <div class="display" style="font-size:80px;margin-top:8px">{H.escape(trip['know_title'])}</div>
</div>
<div style="position:absolute;left:72px;right:72px;top:400px;display:grid;gap:20px">{cards}</div>
<div class="glass" style="position:absolute;left:72px;right:72px;bottom:90px;border-radius:32px;padding:26px 34px;background:#fffdf9;backdrop-filter:none;-webkit-backdrop-filter:none">
  <div style="font-size:20px;font-weight:900;letter-spacing:.12em;color:#cf5a28;margin-bottom:6px">{trip['tips_title']}</div>{tips}
</div>
'''


def slide_cta(trip, data):
    return f'''
{CREAM}
<div style="position:absolute;left:0;right:0;top:0;height:640px;background:url({COVERS}/{trip['id']}.jpg) center/cover;border-radius:0 0 56px 56px;box-shadow:0 24px 60px rgba(74,56,40,.25)"></div>
<div style="position:absolute;left:0;right:0;top:0;height:200px;border-radius:0 0 56px 56px;background:linear-gradient(180deg,rgba(24,18,12,.35),rgba(24,18,12,0))"></div>
<div class="logo" style="left:44px;top:34px;width:230px;height:130px"></div>
{counter(trip['total'], trip['total'])}
<div style="position:absolute;left:72px;right:72px;top:690px">
  <div style="font-size:24px;font-weight:900;letter-spacing:.14em;color:#2c9cc0">{H.escape(trip['title'].upper())}</div>
  <div class="display" style="font-size:88px;margin-top:8px">Want this trip?<br><span class="clay">Open it in Trypr.</span></div>
  <div style="font-size:29px;font-weight:700;color:#4a4039;margin-top:20px;line-height:1.4">The full {data['recommendedDays']}-day plan: every stop, every day, ready to make your own.</div>
</div>
<div class="pill" style="position:absolute;left:72px;top:1040px;background:#e78043;color:#fff;padding:24px 44px;font-size:34px;box-shadow:0 14px 36px rgba(207,90,40,.4)">tryprtravel.com · Verified Trips</div>
<div style="position:absolute;left:72px;right:72px;bottom:60px;display:flex;gap:14px;flex-wrap:wrap">
  <span class="pill glass" style="padding:12px 24px;font-size:25px">🔖 Save it</span><span class="pill glass" style="padding:12px 24px;font-size:25px">✈️ Send it to your travel buddy</span>
</div>
'''


def slides(trip):
    data = dict(TRIPS_BY_ID[trip['id']])
    data['recommendedDays'] = data.get('recommendedDays') or data.get('days')
    out = [('1-cover', slide_cover(trip, data)), ('2-route', slide_route(trip, data))]
    for k in range(1, len(trip['days']) + 1):
        out.append((f'{2 + k}-days', slide_day(trip, data, k)))
    out += [(f"{trip['total'] - 1}-know", slide_know(trip, data)), (f"{trip['total']}-open-in-trypr", slide_cta(trip, data))]
    return out


def render(job):
    name, body, out = job
    doc = (f'<!doctype html><html><head><meta charset="utf-8"><style>:root{{--w:1080px;--h:1350px}}{BASE_CSS}</style></head><body>{body}</body></html>')
    with tempfile.TemporaryDirectory() as td:
        src = os.path.join(td, 'slide.html')
        open(src, 'w').write(doc)
        subprocess.run([CHROME, '--headless=new', '--disable-gpu', '--hide-scrollbars', '--allow-file-access-from-files', f'--user-data-dir={td}/p',
                        '--force-device-scale-factor=1', '--window-size=1080,1350', '--virtual-time-budget=10000',
                        f'--screenshot={out}', f'file://{src}'], check=True, capture_output=True)
    print(out)


if __name__ == '__main__':
    args = sys.argv[1:]
    if args and args[0] == '--maps':
        build_maps(args[1:])
        sys.exit(0)
    out_dir, keys = args[0], args[1:]
    jobs = []
    for trip in TRIPS:
        if keys and trip['key'] not in keys:
            continue
        folder = os.path.join(out_dir, f"{trip['n']:02d}-{trip['slug']}")
        os.makedirs(folder, exist_ok=True)
        for name, body in slides(trip):
            jobs.append((name, body, os.path.join(folder, f'{name}.png')))
    with ThreadPoolExecutor(4) as ex:
        list(ex.map(render, jobs))
