import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:trypr/widgets/map_embed.dart';
import 'package:http/http.dart' as http;
import 'dart:async';
import 'dart:convert';

class TripDetailScreen extends StatefulWidget {
  final String docId;
  final Map<String, dynamic> data;
  const TripDetailScreen({Key? key, required this.docId, required this.data}) : super(key: key);

  @override
  State<TripDetailScreen> createState() => _TripDetailScreenState();
}

class _TripDetailScreenState extends State<TripDetailScreen> {
  int _days = 1;
  bool _saving = false;
  bool _editing = false;
  late List<Map<String, dynamic>> _waypoints;
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _placeSuggestions = [];
  Timer? _debounce;
  bool _searchingPlaces = false;

  User? get _user => FirebaseAuth.instance.currentUser;

  @override
  void initState() {
    super.initState();
    final d = widget.data['totalDays'];
    if (d is num) _days = d.toInt();
    // copy waypoints into mutable list for editing
    final w = (widget.data['waypoints'] as List<dynamic>?) ?? [];
    _waypoints = w.map<Map<String, dynamic>>((e) {
      if (e is Map<String, dynamic>) return Map<String, dynamic>.from(e);
      if (e is Map) return Map<String, dynamic>.from(e.cast<String, dynamic>());
      return <String, dynamic>{};
    }).toList();

    _searchController.addListener(() {
      final v = _searchController.text.trim();
      if (_debounce?.isActive ?? false) _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 400), () {
        if (v.isNotEmpty) {
          _searchPlaces(v);
        } else {
          setState(() => _placeSuggestions = []);
        }
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _searchPlaces(String query) async {
    setState(() {
      _searchingPlaces = true;
    });
    try {
      final url = Uri.parse('https://nominatim.openstreetmap.org/search')
          .replace(queryParameters: {'q': query, 'format': 'json', 'limit': '6', 'addressdetails': '1'});
      final resp = await http.get(url, headers: {'User-Agent': 'trypr-app/1.0 (https://example.com)'});
      if (resp.statusCode == 200) {
        final List<dynamic> list = jsonDecode(resp.body) as List<dynamic>;
        setState(() {
          _placeSuggestions = list.map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map)).toList();
        });
      } else {
        setState(() => _placeSuggestions = []);
      }
    } catch (e) {
      setState(() => _placeSuggestions = []);
    } finally {
      if (mounted) setState(() => _searchingPlaces = false);
    }
  }

  Future<void> _saveDays() async {
    final u = _user;
    if (u == null) return;
    setState(() => _saving = true);
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(u.uid)
          .collection('trips')
          .doc(widget.docId)
          .update({
        'totalDays': _days,
        'waypoints': _waypoints,
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveAll() async {
    // same as _saveDays but used when editing waypoints too
    await _saveDays();
    if (mounted) setState(() => _editing = false);
  }

  void _toggleEditing() {
    setState(() => _editing = !_editing);
  }

  void _addWaypointFromTap(double lat, double lon) async {
    setState(() {
      final idx = _waypoints.length + 1;
      _waypoints.add({'lat': lat, 'lon': lon, 'name': 'Point $idx'});
    });
  }

  Future<void> _editWaypointDialog(int index) async {
    // Provide a search/autocomplete UI when editing a waypoint so users
    // don't have to touch raw coordinates. Selecting a suggestion updates
    // both name and lat/lon. If the user prefers just renaming, they can
    // type a new name and press Save.
    final current = Map<String, dynamic>.from(_waypoints[index]);
    final localNameCtrl = TextEditingController(text: current['name']?.toString() ?? '');
    final searchCtrl = TextEditingController();
    Timer? localDebounce;
    List<Map<String, dynamic>> localSuggestions = [];
    bool localLoading = false;

    Future<void> doSearch(String q) async {
      if (q.trim().isEmpty) {
        localSuggestions = [];
        if (mounted) setState(() {});
        return;
      }
      localLoading = true;
      if (mounted) setState(() {});
      try {
        final url = Uri.parse('https://nominatim.openstreetmap.org/search')
            .replace(queryParameters: {'q': q, 'format': 'json', 'limit': '6', 'addressdetails': '1'});
        final resp = await http.get(url, headers: {'User-Agent': 'trypr-app/1.0 (https://example.com)'});
        if (resp.statusCode == 200) {
          final List<dynamic> list = jsonDecode(resp.body) as List<dynamic>;
          localSuggestions = list.map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map)).toList();
        } else {
          localSuggestions = [];
        }
      } catch (e) {
        localSuggestions = [];
      } finally {
        localLoading = false;
        if (mounted) setState(() {});
      }
    }

    final res = await showDialog<bool>(context: context, builder: (ctx) {
      return StatefulBuilder(builder: (ctx2, setStateDialog) {
        return AlertDialog(
          title: const Text('Edit waypoint'),
          content: SizedBox(
            width: 560,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Name field (allows quick rename)
                TextField(controller: localNameCtrl, decoration: const InputDecoration(labelText: 'Name')),
                const SizedBox(height: 8),
                // Search box for picking a place (updates coords automatically)
                TextField(
                  controller: searchCtrl,
                  decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: 'Search place to update location', suffix: localLoading ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : null),
                  onChanged: (v) {
                    if (localDebounce?.isActive ?? false) localDebounce?.cancel();
                    localDebounce = Timer(const Duration(milliseconds: 350), () async {
                      await doSearch(v);
                      setStateDialog(() {});
                    });
                  },
                ),
                if (localSuggestions.isNotEmpty)
                  Container(
                    constraints: const BoxConstraints(maxHeight: 200),
                    margin: const EdgeInsets.only(top: 8),
                    decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Colors.grey.shade300), borderRadius: BorderRadius.circular(8), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 8)]),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: localSuggestions.length,
                      itemBuilder: (sctx, i) {
                        final p = localSuggestions[i];
                        final display = (p['display_name'] ?? '') as String;
                        return ListTile(
                          title: Text(display, maxLines: 2, overflow: TextOverflow.ellipsis),
                          onTap: () {
                            final lat = double.tryParse((p['lat'] ?? '').toString()) ?? current['lat'] ?? 0.0;
                            final lon = double.tryParse((p['lon'] ?? '').toString()) ?? current['lon'] ?? 0.0;
                            // update waypoint immediately and close
                            _waypoints[index]['name'] = display;
                            _waypoints[index]['lat'] = lat;
                            _waypoints[index]['lon'] = lon;
                            if (mounted) setState(() {});
                            Navigator.of(ctx).pop(true);
                          },
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () {
              localDebounce?.cancel();
              Navigator.of(ctx).pop(false);
            }, child: const Text('Cancel')),
            ElevatedButton(onPressed: () {
              // If user changed just the name, update that and close
              _waypoints[index]['name'] = localNameCtrl.text;
              localDebounce?.cancel();
              Navigator.of(ctx).pop(true);
            }, child: const Text('Save')),
          ],
        );
      });
    });

    // Clean up any local debounce timer
    // (if dialog closed via selection, localDebounce may already be cancelled)
    try {
      localDebounce?.cancel();
    } catch (_) {}

    if (res == true) {
      if (mounted) setState(() {});
    }
  }

  void _removeWaypoint(int index) {
    setState(() {
      _waypoints.removeAt(index);
    });
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final name = data['name'] ?? 'Untitled Trip';
    final waypoints = _waypoints;
    final totalKm = (data['totalKm'] ?? 0) as num;

    return Scaffold(
      appBar: AppBar(
        title: Text(name),
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: _saving ? null : _saveDays,
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 360,
              // Use MapEmbed (OSRM route request) so saved trips show road-following
              // routes the same way they were built. When editing, allow tapping
              // the map to add a waypoint via `onMapTap`.
              child: MapEmbed(
                points: waypoints.map((w) {
                  return {
                    'lat': (w['lat'] ?? w['latitude'] ?? 0.0),
                    'lon': (w['lon'] ?? w['longitude'] ?? w['lng'] ?? 0.0),
                    'name': w['name'] ?? '',
                  };
                }).toList(),
                onMapTap: _editing ? (lat, lon) => _addWaypointFromTap(lat, lon) : null,
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Text('Days:', style: TextStyle(fontSize: 16)),
                      const SizedBox(width: 12),
                      Container(
                        decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.grey.shade300)),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.remove),
                              onPressed: _days > 1 ? () => setState(() => _days--) : null,
                            ),
                            SizedBox(width: 40, child: Center(child: Text('$_days', style: const TextStyle(fontSize: 16)))),
                            IconButton(
                              icon: const Icon(Icons.add),
                              onPressed: () => setState(() => _days++),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      ElevatedButton.icon(
                        onPressed: _saving ? null : _saveDays,
                        icon: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save),
                        label: const Text('Save'),
                      ),
                    ],
                  ),

                  const SizedBox(height: 16),
                  Row(children: [Text('${waypoints.length} stops'), const SizedBox(width: 12), Text('${totalKm.toStringAsFixed(1)} km')]),
                  const SizedBox(height: 12),

                  const Divider(),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Waypoints', style: TextStyle(fontWeight: FontWeight.bold)),
                      Row(children: [
                        if (_editing)
                          TextButton.icon(onPressed: _saveAll, icon: const Icon(Icons.save), label: const Text('Save')),
                        TextButton.icon(onPressed: _toggleEditing, icon: Icon(_editing ? Icons.check : Icons.edit), label: Text(_editing ? 'Done' : 'Edit')),
                      ])
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_editing)
                    SizedBox(
                      height: 220,
                      child: Column(
                        children: [
                          // Search / autocomplete input to help users pick a location
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 6.0),
                            child: Column(
                              children: [
                                TextField(
                                  controller: _searchController,
                                  decoration: InputDecoration(
                                    prefixIcon: const Icon(Icons.search),
                                    hintText: 'Type a place name or address',
                                    suffix: _searchingPlaces ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : null,
                                  ),
                                ),
                                if (_placeSuggestions.isNotEmpty)
                                  Container(
                                    constraints: const BoxConstraints(maxHeight: 160),
                                    margin: const EdgeInsets.only(top: 6),
                                    decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Colors.grey.shade300), borderRadius: BorderRadius.circular(8), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 8)]),
                                    child: ListView.builder(
                                      shrinkWrap: true,
                                      itemCount: _placeSuggestions.length,
                                      itemBuilder: (ctx, i) {
                                        final p = _placeSuggestions[i];
                                        final display = (p['display_name'] ?? '') as String;
                                        return ListTile(
                                          title: Text(display, maxLines: 2, overflow: TextOverflow.ellipsis),
                                          onTap: () {
                                            // Add waypoint from the selected place; user doesn't need to edit coords
                                            final lat = double.tryParse((p['lat'] ?? '').toString()) ?? 0.0;
                                            final lon = double.tryParse((p['lon'] ?? '').toString()) ?? 0.0;
                                            setState(() {
                                              _waypoints.add({'lat': lat, 'lon': lon, 'name': display});
                                              _placeSuggestions = [];
                                              _searchController.clear();
                                            });
                                          },
                                        );
                                      },
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: ReorderableListView(
                              onReorder: (oldIndex, newIndex) {
                                setState(() {
                                  if (newIndex > oldIndex) newIndex -= 1;
                                  final item = _waypoints.removeAt(oldIndex);
                                  _waypoints.insert(newIndex, item);
                                });
                              },
                              children: _waypoints.asMap().entries.map((e) {
                                final idx = e.key;
                                final wp = e.value;
                                return ListTile(
                                  key: ValueKey('wp-$idx'),
                                  leading: CircleAvatar(child: Text('${idx + 1}')),
                                  title: Text(wp['name'] ?? 'Point ${idx + 1}'),
                                  subtitle: Text('${wp['lat'] ?? '-'}, ${wp['lon'] ?? '-'}'),
                                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                                    IconButton(icon: const Icon(Icons.edit), onPressed: () => _editWaypointDialog(idx)),
                                    IconButton(icon: const Icon(Icons.delete), onPressed: () => _removeWaypoint(idx)),
                                  ]),
                                );
                              }).toList(),
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    ...waypoints.asMap().entries.map((e) {
                      final idx = e.key;
                      final wp = e.value;
                      return ListTile(
                        leading: CircleAvatar(child: Text('${idx + 1}')),
                        title: Text(wp['name'] ?? 'Point ${idx + 1}'),
                        subtitle: Text('${wp['lat'] ?? '-'}, ${wp['lon'] ?? '-'}'),
                      );
                    }),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
