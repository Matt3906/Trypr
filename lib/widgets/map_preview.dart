import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as latlng;

class MapPreview extends StatelessWidget {
  final List<dynamic> waypoints;
  const MapPreview({super.key, required this.waypoints});

  List<latlng.LatLng> _toLatLngs() {
    final pts = <latlng.LatLng>[];
    for (final w in waypoints) {
      try {
        if (w is Map) {
          final lat = (w['lat'] ?? w['latitude']) as num?;
          final lon =
              (w['lon'] ?? w['longitude'] ?? w['lng'] ?? w['lng']) as num?;
          if (lat != null && lon != null) {
            pts.add(latlng.LatLng(lat.toDouble(), lon.toDouble()));
          }
        }
      } catch (_) {
        // skip malformed
      }
    }
    return pts;
  }

  @override
  Widget build(BuildContext context) {
    final pts = _toLatLngs();
    if (pts.isEmpty) {
      return Container(
        color: Colors.grey.shade200,
        child: const Center(
          child: Icon(Icons.map, size: 36, color: Colors.black26),
        ),
      );
    }

    // compute simple center
    double lat = 0, lon = 0;
    for (final p in pts) {
      lat += p.latitude;
      lon += p.longitude;
    }
    lat /= pts.length;
    lon /= pts.length;
    final center = latlng.LatLng(lat, lon);

    final zoom = pts.length == 1 ? 10.0 : 5.0;

    return FlutterMap(
      options: MapOptions(
        center: center,
        zoom: zoom,
        // Allow panning/zooming on the card preview so users can move the map.
        interactiveFlags: InteractiveFlag.all,
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
          subdomains: const ['a', 'b', 'c'],
          userAgentPackageName: 'com.example.trypr',
        ),
        if (pts.length > 1)
          PolylineLayer(
            polylines: [
              Polyline(
                points: pts,
                color: Colors.blue.withOpacity(0.8),
                strokeWidth: 3.0,
              ),
            ],
          ),
        MarkerLayer(
          markers:
              pts.asMap().entries.map((e) {
                final idx = e.key;
                final p = e.value;
                return Marker(
                  point: p,
                  width: 28,
                  height: 28,
                  builder:
                      (ctx) => Container(
                        decoration: BoxDecoration(
                          color: Colors.blue,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          '${idx + 1}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                );
              }).toList(),
        ),
      ],
    );
  }
}
