import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:http/http.dart' as http;
import 'dart:convert';

// Native (non-web) map implementation using flutter_map. Supports tapping to
// add a dropped pin via the provided `onMapTap` callback and requests an OSRM
// driving route for multiple waypoints to draw a road-following polyline.
class MapEmbed extends StatefulWidget {
  final List<Map<String, dynamic>> points;
  final void Function(double lat, double lon)? onMapTap;
  const MapEmbed({super.key, required this.points, this.onMapTap});

  @override
  State<MapEmbed> createState() => _MapEmbedState();
}

class _MapEmbedState extends State<MapEmbed> {
  List<Marker> _markers = [];
  Polyline? _route;

  @override
  void initState() {
    super.initState();
    // run rebuild defensively so exceptions don't bubble to the framework
    _safeRebuild();
  }

  @override
  void didUpdateWidget(covariant MapEmbed oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.points, widget.points)) {
      _rebuildFromPoints();
    }
  }

  Future<void> _rebuildFromPoints() async {
    _markers = [];
    final pts = widget.points;
    for (var i = 0; i < pts.length; i++) {
      final p = pts[i];
      final lat = _toDouble(p['lat']);
      final lon = _toDouble(p['lon']);
      _markers.add(
        Marker(
          width: 36,
          height: 36,
          point: ll.LatLng(lat, lon),
          builder: (ctx) => CircleAvatar(child: Text('${i + 1}')),
        ),
      );
    }

    if (pts.length > 1) {
      // Request OSRM route
      try {
        String coords = pts.map((p) => '${p['lon']},${p['lat']}').join(';');
        Uri url = Uri.parse(
          'https://router.project-osrm.org/route/v1/driving/$coords?overview=full&geometries=geojson',
        );
        var resp = await http.get(url);
        if (resp.statusCode == 200) {
          try {
            final data = jsonDecode(resp.body) as Map<String, dynamic>;
            final routes = data['routes'] as List<dynamic>?;
            if (routes != null && routes.isNotEmpty) {
              final geom = routes[0]['geometry'] as Map<String, dynamic>;
              final coordsList =
                  (geom['coordinates'] as List<dynamic>).cast<List<dynamic>>();
              final latlngs =
                  coordsList
                      .map(
                        (c) => ll.LatLng(
                          (c[1] as num).toDouble(),
                          (c[0] as num).toDouble(),
                        ),
                      )
                      .toList();
              setState(() {
                _route = Polyline(
                  points: latlngs,
                  strokeWidth: 4.0,
                  color: Colors.blue,
                );
              });
              return;
            }
          } catch (_) {
            // ignore malformed response
          }
        }
        // If we get here, try the alternative coordinate order (lat,lon)
        // in case upstream data uses reversed keys.
        try {
          coords = pts.map((p) => '${p['lat']},${p['lon']}').join(';');
          url = Uri.parse(
            'https://router.project-osrm.org/route/v1/driving/$coords?overview=full&geometries=geojson',
          );
          resp = await http.get(url);
          if (resp.statusCode == 200) {
            final data = jsonDecode(resp.body) as Map<String, dynamic>;
            final routes = data['routes'] as List<dynamic>?;
            if (routes != null && routes.isNotEmpty) {
              final geom = routes[0]['geometry'] as Map<String, dynamic>;
              final coordsList =
                  (geom['coordinates'] as List<dynamic>).cast<List<dynamic>>();
              final latlngs =
                  coordsList
                      .map(
                        (c) => ll.LatLng(
                          (c[1] as num).toDouble(),
                          (c[0] as num).toDouble(),
                        ),
                      )
                      .toList();
              setState(() {
                _route = Polyline(
                  points: latlngs,
                  strokeWidth: 4.0,
                  color: Colors.blue,
                );
              });
              return;
            }
          }
        } catch (_) {
          // fall through to fallback
        }
      } catch (_) {
        // ignore network errors; fall back to polyline between points
      }
    }

    // Fallback: straight polyline between points
    final fallback =
        widget.points
            .map((p) => ll.LatLng(_toDouble(p['lat']), _toDouble(p['lon'])))
            .toList();
    setState(() {
      _route =
          fallback.length > 1
              ? Polyline(
                points: fallback,
                strokeWidth: 3.0,
                color: Colors.blueGrey,
              )
              : null;
    });
  }

  double _toDouble(dynamic v) {
    if (v == null) return 0.0;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0.0;
    return 0.0;
  }

  Future<void> _safeRebuild() async {
    try {
      await _rebuildFromPoints();
    } catch (err, st) {
      // don't let map errors crash the app; log and clear state
      // ignore: avoid_print
      print('Map rebuild failed: $err\n$st');
      if (mounted) {
        setState(() {
          _markers = [];
          _route = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.points.isEmpty) {
      return const Center(
        child: Text('No points yet — tap map to add a point'),
      );
    }

    final center = ll.LatLng(
      (widget.points.last['lat'] ?? 0.0) as double,
      (widget.points.last['lon'] ?? 0.0) as double,
    );

    return FlutterMap(
      options: MapOptions(
        center: center,
        zoom: 6.0,
        onTap: (tapPos, latlng) {
          widget.onMapTap?.call(latlng.latitude, latlng.longitude);
        },
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
          subdomains: const ['a', 'b', 'c'],
          userAgentPackageName: 'com.example.trypr',
        ),
        if (_route != null) PolylineLayer(polylines: [_route!]),
        MarkerLayer(markers: _markers),
      ],
    );
  }
}
