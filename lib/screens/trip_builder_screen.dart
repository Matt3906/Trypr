import 'dart:math' as math;
import 'dart:convert';
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:trypr/widgets/top_taskbar.dart';
import 'package:trypr/widgets/map_embed.dart';
import 'package:trypr/services/geocode.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class TripBuilderScreen extends StatefulWidget {
  const TripBuilderScreen({Key? key}) : super(key: key);

  @override
  State<TripBuilderScreen> createState() => _TripBuilderScreenState();
}

class _Waypoint {
  final String name;
  final double lat;
  final double lon;
  _Waypoint(this.name, this.lat, this.lon);
}

class _TripBuilderScreenState extends State<TripBuilderScreen> {
  final TextEditingController _tripNameCtrl = TextEditingController();
  final TextEditingController _daysCtrl = TextEditingController(text: '1');
  final TextEditingController _searchCtrl = TextEditingController();

  final List<_Waypoint> _waypoints = [];
  List<Map<String, dynamic>> _searchResults = [];

  // Small sample lookup so we don't need external geocoding packages
  final Map<String, _Waypoint> _sampleLookup = {
    'banff': _Waypoint('Banff, AB', 51.1784, -115.5708),
    'calgary': _Waypoint('Calgary, AB', 51.0447, -114.0719),
    'vancouver': _Waypoint('Vancouver, BC', 49.2827, -123.1207),
    'victoria': _Waypoint('Victoria, BC', 48.4284, -123.3656),
    'tofino': _Waypoint('Tofino, BC', 49.1526, -125.9033),
  };

  double get _totalKm {
    double total = 0.0;
    for (var i = 1; i < _waypoints.length; i++) {
      total += _haversine(
        _waypoints[i - 1].lat,
        _waypoints[i - 1].lon,
        _waypoints[i].lat,
        _waypoints[i].lon,
      );
    }
    return total;
  }

  static double _haversine(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371.0; // km
    final dLat = _deg2rad(lat2 - lat1);
    final dLon = _deg2rad(lon2 - lon1);
    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_deg2rad(lat1)) *
            math.cos(_deg2rad(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return r * c;
  }

  static double _deg2rad(double deg) => deg * (math.pi / 180);

  void _addWaypointFromLookup(String key) {
    final k = key.toLowerCase().trim();
    final s = _sampleLookup[k];
    if (s != null) setState(() => _waypoints.add(s));
  }

  void _removeWaypoint(int index) {
    setState(() {
      if (index >= 0 && index < _waypoints.length) _waypoints.removeAt(index);
    });
  }

  void _openMapInNewTab() {
    final pts =
        _waypoints
            .map((w) => {'name': w.name, 'lat': w.lat, 'lon': w.lon})
            .toList();
    final markersJson = jsonEncode(pts);
    final htmlDoc = '''<!doctype html>
<html>
<head>
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" />
  <style>html,body,#map{height:100%;margin:0;padding:0} .num-marker { background:#1976D2;color:white;border-radius:50%;width:28px;height:28px;line-height:28px;text-align:center;font-weight:700; }</style>
</head>
<body>
  <div id="map"></div>
  <script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
  <script>
    try {
      const pts = $markersJson;
      const map = L.map('map').setView([0,0],2);
      L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom: 19, attribution: '© OpenStreetMap contributors' }).addTo(map);
      const markers = [];
      const latlngs = [];
      for (let i = 0; i < pts.length; i++) {
        const p = pts[i];
        latlngs.push([p.lat, p.lon]);
        const icon = L.divIcon({className: 'num-marker', html: '<div class="num-marker">'+(i+1)+'</div>', iconSize:[28,28]});
        const m = L.marker([p.lat, p.lon], {icon: icon}).addTo(map).bindPopup('<b>' + (p.name||'Point') + '</b>');
        markers.push(m);
      }
      if (markers.length > 0) {
        const group = L.featureGroup(markers);
        map.fitBounds(group.getBounds().pad(0.2));
        if (latlngs.length>1) {
          L.polyline(latlngs, {color: 'blue', weight:3, opacity:0.7}).addTo(map);
        }
      }
    } catch(e) { document.body.innerHTML = '<pre style="color:red">Map init error: '+e+'</pre>'; }
  </script>
</body>
</html>''';

    // Create a Blob URL to avoid data URL/CSP issues
    final blob = html.Blob([htmlDoc], 'text/html');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.window.open(url, '_blank');
    // Revoke the object URL after a delay to allow the new tab to load
    Future.delayed(
      const Duration(seconds: 2),
      () => html.Url.revokeObjectUrl(url),
    );
  }

  @override
  void dispose() {
    _tripNameCtrl.dispose();
    _daysCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const TopTaskbar(dockProgress: 1.0),
      body: Row(
        children: [
          // Left info panel
          Container(
            width: 340,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              border: Border(right: BorderSide(color: Colors.grey.shade200)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Trip Information',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _tripNameCtrl,
                  decoration: const InputDecoration(labelText: 'Trip Name'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _daysCtrl,
                  decoration: const InputDecoration(labelText: 'Trip Days'),
                  keyboardType: TextInputType.number,
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                Text(
                  'Total distance: ${_totalKm.toStringAsFixed(2)} km',
                  style: const TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Segments (kms between):',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child:
                      _waypoints.isEmpty
                          ? const Text(
                            'No points yet. Use the search in the main pane to add locations.',
                          )
                          : ListView.builder(
                            itemCount: _waypoints.length,
                            itemBuilder: (ctx, i) {
                              final next =
                                  i + 1 < _waypoints.length
                                      ? _waypoints[i + 1]
                                      : null;
                              double segKm = 0.0;
                              if (next != null) {
                                segKm = _haversine(
                                  _waypoints[i].lat,
                                  _waypoints[i].lon,
                                  next.lat,
                                  next.lon,
                                );
                              }
                              return ListTile(
                                dense: true,
                                title: Text(_waypoints[i].name),
                                subtitle: Text(
                                  next != null
                                      ? '${segKm.toStringAsFixed(2)} km to next'
                                      : 'Last point',
                                ),
                                trailing: IconButton(
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () => _removeWaypoint(i),
                                ),
                              );
                            },
                          ),
                ),
                const SizedBox(height: 8),
                ElevatedButton.icon(
                  onPressed: () async {
                    final name = _tripNameCtrl.text.trim();
                    final user = FirebaseAuth.instance.currentUser;
                    if (user == null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Sign in to save trips')),
                      );
                      return;
                    }
                    final data = {
                      'name': name,
                      'days': int.tryParse(_daysCtrl.text) ?? 1,
                      'createdAt': FieldValue.serverTimestamp(),
                      'totalKm': _totalKm,
                      'waypoints':
                          _waypoints
                              .map(
                                (w) => {
                                  'name': w.name,
                                  'lat': w.lat,
                                  'lon': w.lon,
                                },
                              )
                              .toList(),
                    };
                    try {
                      await FirebaseFirestore.instance
                          .collection('users')
                          .doc(user.uid)
                          .collection('trips')
                          .add(data);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Trip saved to My Trips')),
                      );
                    } catch (e) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Save failed: $e')),
                      );
                    }
                  },
                  icon: const Icon(Icons.save),
                  label: const Text('Save Trip'),
                ),
              ],
            ),
          ),

          // Main search & simple visualizer pane
          Expanded(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _searchCtrl,
                          decoration: const InputDecoration(
                            prefixIcon: Icon(Icons.search),
                            hintText: 'Search sample locations (try "Banff")',
                          ),
                          onSubmitted: (v) async {
                            // Try web geocoding (Nominatim) first; fallback to sample lookup
                            List<Map<String, dynamic>> results =
                                await searchNominatim(v);
                            if (results.isEmpty) {
                              final match = _sampleLookup.keys.firstWhere(
                                (k) =>
                                    k.toLowerCase().contains(v.toLowerCase()),
                                orElse: () => '',
                              );
                              if (match.isNotEmpty)
                                _addWaypointFromLookup(match);
                              return;
                            }
                            // Let user pick first result (quick UX). You can extend to show a picker.
                            final r = results.first;
                            setState(
                              () => _waypoints.add(
                                _Waypoint(
                                  r['name'] ?? v,
                                  r['lat'] ?? 0.0,
                                  r['lon'] ?? 0.0,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: () {
                          _addWaypointFromLookup(_searchCtrl.text);
                          _searchCtrl.clear();
                        },
                        child: const Text('Add'),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: _openMapInNewTab,
                        child: const Text('Open Map'),
                      ),
                      const SizedBox(width: 8),
                      PopupMenuButton<String>(
                        child: ElevatedButton(
                          onPressed: null,
                          child: const Text('Add from list'),
                        ),
                        onSelected: (v) => _addWaypointFromLookup(v),
                        itemBuilder:
                            (_) =>
                                _sampleLookup.keys
                                    .map(
                                      (k) => PopupMenuItem(
                                        value: k,
                                        child: Text(k),
                                      ),
                                    )
                                    .toList(),
                      ),
                    ],
                  ),
                ),

                // Search results (Nominatim)
                _searchResults.isEmpty
                    ? const SizedBox.shrink()
                    : Container(
                      height: 160,
                      margin: const EdgeInsets.symmetric(horizontal: 12.0),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        border: Border.all(color: Colors.grey.shade300),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: ListView.builder(
                        itemCount: _searchResults.length,
                        itemBuilder: (ctx, i) {
                          final r = _searchResults[i];
                          return ListTile(
                            title: Text(
                              r['name'] ??
                                  r['display_name'] ??
                                  'Result ${i + 1}',
                            ),
                            subtitle: Text(
                              '${r['lat'] ?? '-'}, ${r['lon'] ?? '-'}',
                            ),
                            trailing: TextButton(
                              onPressed: () {
                                setState(() {
                                  _waypoints.add(
                                    _Waypoint(
                                      r['name'] ?? 'Point',
                                      (r['lat'] ?? 0.0) as double,
                                      (r['lon'] ?? 0.0) as double,
                                    ),
                                  );
                                  _searchResults = [];
                                  _searchCtrl.clear();
                                });
                              },
                              child: const Text('Add'),
                            ),
                          );
                        },
                      ),
                    ),

                // Embedded map (web) or list stub (mobile/desktop)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey.shade300),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: MapEmbed(
                        points:
                            _waypoints
                                .map(
                                  (w) => {
                                    'name': w.name,
                                    'lat': w.lat,
                                    'lon': w.lon,
                                  },
                                )
                                .toList(),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
