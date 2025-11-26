import 'dart:math' as math;
import 'dart:convert';
import 'dart:html' as html;
import 'dart:async';
import 'package:flutter/foundation.dart';

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
  int nights = 1;
  _Waypoint(this.name, this.lat, this.lon);
}

class _TripBuilderScreenState extends State<TripBuilderScreen> {
  final TextEditingController _tripNameCtrl = TextEditingController();
  final TextEditingController _daysCtrl = TextEditingController(text: '1');
  final TextEditingController _searchCtrl = TextEditingController();

  final List<_Waypoint> _waypoints = [];
  DateTime? _startDate;
  List<Map<String, dynamic>> _searchResults = [];
  StreamSubscription? _windowMsgSub;
  StreamSubscription<User?>? _authSub;
  Timer? _searchDebounce;
  double? _roadDistanceKm;
  double? _routeDurationMin;
  User? _currentUser;
  bool _isSaving = false;
  DocumentReference<Map<String, dynamic>>? _lastSavedTripRef;

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

  Future<void> _showShareDialog(BuildContext context) async {
    if (_lastSavedTripRef == null) return;
    final me = FirebaseAuth.instance.currentUser;
    if (me == null) return;
    final meDoc =
        await FirebaseFirestore.instance.collection('users').doc(me.uid).get();
    final friendsRaw = meDoc.data()?['friends'] as List<dynamic>? ?? [];
    final friends =
        friendsRaw.map<Map<String, dynamic>>((f) {
          if (f is Map) return Map<String, dynamic>.from(f);
          return {'id': f.toString()};
        }).toList();

    final selected = <String>{};
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Share trip with friends'),
          content: SizedBox(
            width: 520,
            child: StatefulBuilder(
              builder: (ctx2, setState) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (friends.isEmpty) const Text('No friends to share with'),
                    if (friends.isNotEmpty)
                      SizedBox(
                        height: 280,
                        child: ListView.builder(
                          itemCount: friends.length,
                          itemBuilder: (ctx3, i) {
                            final f = friends[i];
                            final uid = (f['uid'] ?? f['id'])?.toString();
                            final label =
                                (f['displayName'] ??
                                        f['name'] ??
                                        f['email'] ??
                                        uid ??
                                        'Friend')
                                    .toString();
                            return CheckboxListTile(
                              value: uid != null && selected.contains(uid),
                              onChanged: (v) {
                                if (uid == null) return;
                                setState(() {
                                  if (v == true)
                                    selected.add(uid);
                                  else
                                    selected.remove(uid);
                                });
                              },
                              title: Text(label),
                              subtitle: Text((f['email'] ?? '').toString()),
                            );
                          },
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                Navigator.of(ctx).pop();
                if (selected.isEmpty) return;
                try {
                  final tripId = _lastSavedTripRef!.id;
                  await _lastSavedTripRef!.update({
                    'sharedWith': FieldValue.arrayUnion(selected.toList()),
                  });
                  for (final uid in selected) {
                    final dest = FirebaseFirestore.instance
                        .collection('users')
                        .doc(uid)
                        .collection('sharedTrips')
                        .doc(tripId);
                    await dest.set({
                      'ownerUid': me.uid,
                      'ownerName': me.displayName ?? '',
                      'tripRef': _lastSavedTripRef!.path,
                      'tripName': _tripNameCtrl.text.trim(),
                      'createdAt': FieldValue.serverTimestamp(),
                    });
                  }
                  if (mounted)
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Trip shared')),
                    );
                } catch (err) {
                  if (mounted)
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Failed to share: $err')),
                    );
                }
              },
              child: const Text('Share'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openPackingList(
    DocumentReference<Map<String, dynamic>> tripRef,
  ) async {
    final me = FirebaseAuth.instance.currentUser;
    if (me == null) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final addCtl = TextEditingController();
        return AlertDialog(
          title: const Text('Packing list'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Expanded(
                  child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream:
                        tripRef
                            .collection('packing')
                            .orderBy('createdAt')
                            .snapshots(),
                    builder: (ctx2, snap) {
                      if (!snap.hasData)
                        return const Center(child: CircularProgressIndicator());
                      final docs = snap.data!.docs;
                      if (docs.isEmpty)
                        return const Center(child: Text('No packing items'));
                      return ListView.separated(
                        itemCount: docs.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (ctx3, i) {
                          final d = docs[i];
                          final data = d.data();
                          final name = (data['name'] ?? '').toString();
                          final checkedBy = List<String>.from(
                            data['checkedBy'] ?? [],
                          );
                          final checked = checkedBy.contains(me.uid);
                          return CheckboxListTile(
                            value: checked,
                            onChanged: (v) async {
                              if (v == true) {
                                await d.reference.update({
                                  'checkedBy': FieldValue.arrayUnion([me.uid]),
                                });
                              } else {
                                await d.reference.update({
                                  'checkedBy': FieldValue.arrayRemove([me.uid]),
                                });
                              }
                            },
                            title: Text(name),
                          );
                        },
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: addCtl,
                        decoration: const InputDecoration(hintText: 'Add item'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: () async {
                        final t = addCtl.text.trim();
                        if (t.isEmpty) return;
                        await tripRef.collection('packing').add({
                          'name': t,
                          'createdAt': FieldValue.serverTimestamp(),
                          'checkedBy': [],
                        });
                        addCtl.clear();
                      },
                      child: const Text('Add'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openTripChat(
    DocumentReference<Map<String, dynamic>> tripRef,
  ) async {
    final me = FirebaseAuth.instance.currentUser;
    if (me == null) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final msgCtl = TextEditingController();
        final imgCtl = TextEditingController();
        return AlertDialog(
          title: const Text('Trip chat'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Expanded(
                  child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream:
                        tripRef
                            .collection('messages')
                            .orderBy('createdAt')
                            .snapshots(),
                    builder: (ctx2, snap) {
                      if (!snap.hasData)
                        return const Center(child: CircularProgressIndicator());
                      final docs = snap.data!.docs;
                      if (docs.isEmpty)
                        return const Center(child: Text('No messages yet'));
                      return ListView.builder(
                        itemCount: docs.length,
                        itemBuilder: (ctx3, i) {
                          final d = docs[i];
                          final data = d.data();
                          final sender = (data['senderUid'] ?? '').toString();
                          final text = (data['text'] ?? '').toString();
                          final imageUrl = (data['imageUrl'] ?? '').toString();
                          return ListTile(
                            title: Text(sender == me.uid ? 'You' : sender),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (text.isNotEmpty) Text(text),
                                if (imageUrl.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 6.0),
                                    child: Image.network(
                                      imageUrl,
                                      width: 200,
                                      errorBuilder:
                                          (_, __, ___) => const Text(
                                            'Image failed to load',
                                          ),
                                    ),
                                  ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: msgCtl,
                  decoration: const InputDecoration(hintText: 'Message'),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: imgCtl,
                        decoration: const InputDecoration(
                          hintText: 'Image URL (optional)',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: () async {
                        final t = msgCtl.text.trim();
                        final img = imgCtl.text.trim();
                        if (t.isEmpty && img.isEmpty) return;
                        if (kDebugMode)
                          print(
                            'TripBuilder chat send -> target: ${tripRef.path}',
                          );
                        await tripRef.collection('messages').add({
                          'senderUid': me.uid,
                          'senderName': me.displayName ?? '',
                          'text': t,
                          'imageUrl':
                              img.isNotEmpty ? img : FieldValue.delete(),
                          'createdAt': FieldValue.serverTimestamp(),
                        });
                        msgCtl.clear();
                        imgCtl.clear();
                      },
                      child: const Text('Send'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
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
    if (s != null) {
      final wp = _Waypoint(s.name, s.lat, s.lon);
      wp.nights = 1;
      setState(() => _waypoints.add(wp));
    }
  }

  int _parseDays() => int.tryParse(_daysCtrl.text) ?? 1;

  void _removeWaypoint(int index) {
    setState(() {
      if (index >= 0 && index < _waypoints.length) _waypoints.removeAt(index);
    });
  }

  @override
  void initState() {
    super.initState();
    // Listen to auth changes so the Save button enables/disables reactively.
    try {
      _authSub = FirebaseAuth.instance.authStateChanges().listen((u) {
        setState(() => _currentUser = u);
      });
    } catch (_) {
      // ignore in non-supported environments
    }
    // Listen for map click messages posted from the web map instance.
    try {
      _windowMsgSub = html.window.onMessage.listen((event) {
        try {
          final dataRaw = event.data;
          if (dataRaw is String) {
            final decoded = jsonDecode(dataRaw);
            if (decoded is Map) {
              if (decoded['type'] == 'map_click') {
                final lat = (decoded['lat'] ?? 0.0) as num;
                final lon = (decoded['lon'] ?? 0.0) as num;
                // Try reverse geocoding (web only). If it fails, fallback to "Dropped Pin".
                try {
                  reverseNominatim(lat.toDouble(), lon.toDouble()).then((name) {
                    final wp = _Waypoint(
                      name ?? 'Dropped Pin',
                      lat.toDouble(),
                      lon.toDouble(),
                    );
                    wp.nights = math.min(_waypoints.length + 1, _parseDays());
                    setState(() {
                      _waypoints.add(wp);
                    });
                  });
                } catch (_) {
                  setState(() {
                    _waypoints.add(
                      _Waypoint('Dropped Pin', lat.toDouble(), lon.toDouble()),
                    );
                  });
                }
              } else if (decoded['type'] == 'route_summary') {
                final dist = (decoded['distance'] ?? 0) as num;
                final dur = (decoded['duration'] ?? 0) as num;
                setState(() {
                  _roadDistanceKm = dist / 1000.0;
                  _routeDurationMin = dur / 60.0;
                });
              }
            }
          }
        } catch (e) {
          // ignore malformed messages
        }
      });
    } catch (_) {
      // html.window not available on non-web; ignore.
    }
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
    _windowMsgSub?.cancel();
    _authSub?.cancel();
    _searchDebounce?.cancel();
    _tripNameCtrl.dispose();
    _daysCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = _currentUser ?? FirebaseAuth.instance.currentUser;

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
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Start date',
                        ),
                        child: InkWell(
                          onTap: () async {
                            final now = DateTime.now();
                            final picked = await showDatePicker(
                              context: context,
                              initialDate: _startDate ?? now,
                              firstDate: DateTime(now.year - 5),
                              lastDate: DateTime(now.year + 5),
                            );
                            if (picked != null && mounted)
                              setState(() => _startDate = picked);
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12.0),
                            child: Text(
                              _startDate != null
                                  ? '${_startDate!.year}-${_startDate!.month.toString().padLeft(2, '0')}-${_startDate!.day.toString().padLeft(2, '0')}'
                                  : 'Select start date',
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
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
                  'Total: ${((_roadDistanceKm ?? _totalKm)).toStringAsFixed(2)} km',
                  style: const TextStyle(fontSize: 16),
                ),
                if (_routeDurationMin != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6.0),
                    child: Text(
                      'Estimated drive time: ${_routeDurationMin!.toStringAsFixed(0)} min',
                      style: const TextStyle(
                        fontSize: 13,
                        color: Colors.black54,
                      ),
                    ),
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
                              final nights = _waypoints[i].nights;
                              // compute arrival offset by summing nights of earlier stops
                              int offsetDays = 0;
                              for (var j = 0; j < i; j++)
                                offsetDays += _waypoints[j].nights;
                              String dateStr = '';
                              if (_startDate != null) {
                                final dt = _startDate!.add(
                                  Duration(days: offsetDays),
                                );
                                dateStr =
                                    ' — ${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
                              }
                              return ListTile(
                                dense: true,
                                leading: CircleAvatar(child: Text('${i + 1}')),
                                title: Text(_waypoints[i].name),
                                subtitle: Text(
                                  '${nights} night${nights == 1 ? '' : 's'}$dateStr — ' +
                                      (next != null
                                          ? '${segKm.toStringAsFixed(2)} km to next'
                                          : 'Last point'),
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    SizedBox(
                                      width: 90,
                                      child: DropdownButton<int>(
                                        value: nights,
                                        isExpanded: true,
                                        items: List.generate(
                                          math.max(1, _parseDays()),
                                          (idx) => DropdownMenuItem(
                                            value: idx + 1,
                                            child: Text(
                                              '${idx + 1} night${idx == 0 ? '' : 's'}',
                                            ),
                                          ),
                                        ),
                                        onChanged: (v) {
                                          if (v == null) return;
                                          setState(
                                            () => _waypoints[i].nights = v,
                                          );
                                        },
                                      ),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.delete_outline),
                                      onPressed: () => _removeWaypoint(i),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                ),
                const SizedBox(height: 8),
                if (user == null)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8.0),
                    child: Text(
                      'Sign in to save trips',
                      style: TextStyle(color: Colors.black54),
                    ),
                  ),
                ElevatedButton.icon(
                  onPressed:
                      (user == null || _waypoints.isEmpty || _isSaving)
                          ? null
                          : () async {
                            if (_waypoints.isEmpty) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Add at least one waypoint'),
                                ),
                              );
                              return;
                            }
                            setState(() => _isSaving = true);
                            final name = _tripNameCtrl.text.trim();
                            final data = {
                              'name': name,
                              'days': int.tryParse(_daysCtrl.text) ?? 1,
                              'createdAt': FieldValue.serverTimestamp(),
                              'totalKm': _totalKm,
                              'waypoints':
                                  _waypoints.asMap().entries.map((e) {
                                    final idx = e.key;
                                    final w = e.value;
                                    final m = {
                                      'name': w.name,
                                      'lat': w.lat,
                                      'lon': w.lon,
                                      'nights': w.nights,
                                    };
                                    if (_startDate != null) {
                                      int offset = 0;
                                      for (var j = 0; j < idx; j++)
                                        offset += _waypoints[j].nights;
                                      final dt = _startDate!.add(
                                        Duration(days: offset),
                                      );
                                      m['date'] =
                                          '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
                                    }
                                    return m;
                                  }).toList(),
                            };
                            try {
                              final uid =
                                  FirebaseAuth.instance.currentUser!.uid;
                              final ref = await FirebaseFirestore.instance
                                  .collection('users')
                                  .doc(uid)
                                  .collection('trips')
                                  .add(data);
                              _lastSavedTripRef = ref;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Trip saved to My Trips'),
                                ),
                              );
                            } catch (e) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Save failed: $e')),
                              );
                            } finally {
                              setState(() => _isSaving = false);
                            }
                          },
                  icon:
                      _isSaving
                          ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                          : const Icon(Icons.save),
                  label: Text(_isSaving ? 'Saving...' : 'Save Trip'),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    ElevatedButton.icon(
                      onPressed:
                          _lastSavedTripRef == null
                              ? null
                              : () => _showShareDialog(context),
                      icon: const Icon(Icons.share),
                      label: const Text('Share'),
                    ),
                  ],
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
                            hintText: 'Search locations',
                          ),
                          onChanged: (v) {
                            _searchDebounce?.cancel();
                            _searchDebounce = Timer(
                              const Duration(milliseconds: 400),
                              () async {
                                final q = _searchCtrl.text.trim();
                                if (q.isEmpty) {
                                  setState(() => _searchResults = []);
                                  return;
                                }
                                final results = await searchNominatim(q);
                                setState(() => _searchResults = results);
                              },
                            );
                          },
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
                            // Add first result by default
                            final r = results.first;
                            setState(() {
                              final wp = _Waypoint(
                                r['name'] ?? v,
                                r['lat'] ?? 0.0,
                                r['lon'] ?? 0.0,
                              );
                              wp.nights = math.min(
                                _waypoints.length + 1,
                                _parseDays(),
                              );
                              _waypoints.add(wp);
                              _searchResults = [];
                              _searchCtrl.clear();
                            });
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
                                  final wp = _Waypoint(
                                    r['name'] ?? 'Point',
                                    (r['lat'] ?? 0.0) as double,
                                    (r['lon'] ?? 0.0) as double,
                                  );
                                  wp.nights = math.min(
                                    _waypoints.length + 1,
                                    _parseDays(),
                                  );
                                  _waypoints.add(wp);
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
                        onMapTap: (lat, lon) async {
                          try {
                            final name = await reverseNominatim(lat, lon);
                            final wp = _Waypoint(
                              name ?? 'Dropped Pin',
                              lat,
                              lon,
                            );
                            wp.nights = math.min(
                              _waypoints.length + 1,
                              _parseDays(),
                            );
                            setState(() {
                              _waypoints.add(wp);
                            });
                          } catch (_) {
                            final wp = _Waypoint('Dropped Pin', lat, lon);
                            wp.nights = math.min(
                              _waypoints.length + 1,
                              _parseDays(),
                            );
                            setState(() {
                              _waypoints.add(wp);
                            });
                          }
                        },
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
