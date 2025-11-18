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
    _rebuildFromPoints();
  }

  @override
  void didUpdateWidget(covariant MapEmbed oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.points, widget.points)) {
      _rebuildFromPoints();
    }
  }

  void _rebuildFromPoints() async {
    _markers = [];
    final pts = widget.points;
    for (var i = 0; i < pts.length; i++) {
      final p = pts[i];
      _markers.add(
        Marker(
          width: 36,
          height: 36,
          point: ll.LatLng(
            (p['lat'] ?? 0.0) as double,
            (p['lon'] ?? 0.0) as double,
          ),
          builder: (ctx) => CircleAvatar(child: Text('${i + 1}')),
        ),
      );
    }

    if (pts.length > 1) {
      // Request OSRM route
      try {
        final coords = pts.map((p) => '${p['lon']},${p['lat']}').join(';');
        final url = Uri.parse(
          'https://router.project-osrm.org/route/v1/driving/$coords?overview=full&geometries=geojson',
        );
        final resp = await http.get(url);
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
        // ignore network errors; fall back to polyline between points
      }
    }

    // Fallback: straight polyline between points
    final fallback =
        widget.points
            .map(
              (p) => ll.LatLng(
                (p['lat'] ?? 0.0) as double,
                (p['lon'] ?? 0.0) as double,
              ),
            )
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
