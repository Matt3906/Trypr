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
  final void Function(double distanceMeters, double durationSeconds)?
  onRouteSummary;
  final List<Map<String, dynamic>> secondaryPoints;
  const MapEmbed({
    super.key,
    required this.points,
    this.onMapTap,
    this.onRouteSummary,
    this.secondaryPoints = const [],
  });

  @override
  State<MapEmbed> createState() => _MapEmbedState();
}

class _MapEmbedState extends State<MapEmbed> {
  List<Marker> _markers = [];
  List<Marker> _secondaryMarkers = [];
  Polyline? _route;

  String _mainSig = '';
  String _secondarySig = '';

  IconData _iconFor(String kind, String category) {
    if (kind == 'accommodation') return Icons.hotel;
    switch (category) {
      case 'Driving':
        return Icons.directions_car;
      case 'Hiking':
        return Icons.terrain;
      case 'Biking':
        return Icons.directions_bike;
      case 'Walking':
        return Icons.directions_walk;
      case 'Museum':
        return Icons.museum;
      case 'Sightseeing':
        return Icons.camera_alt;
      case 'Exploring':
        return Icons.explore;
      case 'Restaurant':
        return Icons.restaurant;
      case 'Shopping':
        return Icons.shopping_bag;
      case 'Photography':
        return Icons.photo_camera;
      case 'Adventure':
        return Icons.local_activity;
      default:
        return Icons.location_on;
    }
  }

  Color _colorFor(String kind, String category) {
    if (kind == 'accommodation') return Colors.purple.shade600;
    switch (category) {
      case 'Driving':
        return Colors.blueAccent;
      case 'Hiking':
        return const Color(0xFF2E7D32);
      case 'Biking':
        return const Color(0xFF1565C0);
      case 'Walking':
        return const Color(0xFF00796B);
      case 'Museum':
        return const Color(0xFF6A1B9A);
      case 'Sightseeing':
        return const Color(0xFFF57C00);
      case 'Exploring':
        return const Color(0xFFC62828);
      case 'Restaurant':
        return const Color(0xFFD32F2F);
      case 'Shopping':
        return const Color(0xFF7B1FA2);
      case 'Photography':
        return const Color(0xFF0277BD);
      case 'Adventure':
        return const Color(0xFFFBC02D);
      default:
        return Colors.orange.shade700;
    }
  }

  @override
  void initState() {
    super.initState();
    _mainSig = _signature(widget.points);
    _secondarySig = _signature(widget.secondaryPoints);
    // run rebuild defensively so exceptions don't bubble to the framework
    _safeRebuild();
  }

  @override
  void didUpdateWidget(covariant MapEmbed oldWidget) {
    super.didUpdateWidget(oldWidget);

    final newMain = _signature(widget.points);
    final newSecondary = _signature(widget.secondaryPoints);
    if (newMain != _mainSig || newSecondary != _secondarySig) {
      _mainSig = newMain;
      _secondarySig = newSecondary;
      _rebuildFromPoints();
    }
  }

  String _signature(List<Map<String, dynamic>> pts) {
    if (pts.isEmpty) return '';
    final b = StringBuffer();
    for (final p in pts) {
      final lat = _toDouble(p['lat']).toStringAsFixed(6);
      final lon = _toDouble(p['lon']).toStringAsFixed(6);
      final kind = (p['kind'] ?? '').toString();
      final category = (p['category'] ?? '').toString();
      final name = (p['name'] ?? '').toString();
      b
        ..write(lat)
        ..write(',')
        ..write(lon)
        ..write('|')
        ..write(kind)
        ..write('|')
        ..write(category)
        ..write('|')
        ..write(name)
        ..write(';');
    }
    return b.toString();
  }

  Future<void> _rebuildFromPoints() async {
    _markers = [];
    _secondaryMarkers = [];
    final pts = widget.points;

    _secondaryMarkers =
        widget.secondaryPoints.map((p) {
          final lat = _toDouble(p['lat']);
          final lon = _toDouble(p['lon']);
          final kind = (p['kind'] ?? '') as String;
          final category = (p['category'] ?? '') as String;
          final color = _colorFor(kind, category);
          return Marker(
            width: 42,
            height: 42,
            point: ll.LatLng(lat, lon),
            builder:
                (ctx) => Container(
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.14),
                    shape: BoxShape.circle,
                  ),
                  padding: const EdgeInsets.all(6),
                  child: Icon(_iconFor(kind, category), color: color, size: 24),
                ),
          );
        }).toList();

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
              final route0 = routes[0] as Map<String, dynamic>;
              final dist = (route0['distance'] as num?)?.toDouble();
              final dur = (route0['duration'] as num?)?.toDouble();
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
              if (dist != null && dur != null) {
                widget.onRouteSummary?.call(dist, dur);
              }
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
              final route0 = routes[0] as Map<String, dynamic>;
              final dist = (route0['distance'] as num?)?.toDouble();
              final dur = (route0['duration'] as num?)?.toDouble();
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
              if (dist != null && dur != null) {
                widget.onRouteSummary?.call(dist, dur);
              }
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
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0.0;
    return 0.0;
  }

  Future<void> _safeRebuild() async {
    try {
      await _rebuildFromPoints();
    } catch (err, st) {
      // don't let map errors crash the app; log and clear state
      if (kDebugMode) {
        // ignore: avoid_print
        print('Map rebuild failed: $err\n$st');
      }
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
      return const Center(child: Text('No points yet'));
    }

    final mainPts =
        widget.points
            .map((p) => ll.LatLng(_toDouble(p['lat']), _toDouble(p['lon'])))
            .toList();
    final secondaryPts =
        widget.secondaryPoints
            .map((p) => ll.LatLng(_toDouble(p['lat']), _toDouble(p['lon'])))
            .toList();
    final allPts = <ll.LatLng>[...mainPts, ...secondaryPts];
    final bounds = LatLngBounds.fromPoints(allPts);

    return FlutterMap(
      options: MapOptions(
        bounds: bounds,
        boundsOptions: FitBoundsOptions(
          padding: const EdgeInsets.all(24),
          maxZoom: allPts.length <= 1 ? 12 : 10,
        ),
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
        if (_secondaryMarkers.isNotEmpty)
          MarkerLayer(markers: _secondaryMarkers),
        MarkerLayer(markers: _markers),
      ],
    );
  }
}
