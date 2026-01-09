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
  final void Function(List<String> lines)? onRouteInstructions;
  final void Function(Map<String, dynamic> arrivalStop)? onTransitArrivalStop;
  final String transportMode;
  final List<Map<String, dynamic>> routeVia;
  final List<String> segmentRoutingTypes;
  final void Function(int afterIndex, double lat, double lon)? onRouteTapAddVia;
  final void Function(int viaIndex, double lat, double lon)? onViaDragEnd;
  final void Function(int viaIndex)? onViaTapDelete;
  final List<Map<String, dynamic>> secondaryPoints;
  const MapEmbed({
    super.key,
    required this.points,
    this.onMapTap,
    this.onRouteSummary,
    this.onRouteInstructions,
    this.onTransitArrivalStop,
    this.transportMode = 'driving',
    this.routeVia = const [],
    this.segmentRoutingTypes = const [],
    this.onRouteTapAddVia,
    this.onViaDragEnd,
    this.onViaTapDelete,
    this.secondaryPoints = const [],
  });

  @override
  State<MapEmbed> createState() => _MapEmbedState();
}

class _MapEmbedState extends State<MapEmbed> {
  List<Marker> _markers = [];
  List<Marker> _secondaryMarkers = [];
  List<Marker> _viaMarkers = [];
  List<Polyline> _routes = const [];

  int _suppressMapTapUntilMs = 0;

  String _mainSig = '';
  String _secondarySig = '';
  String _viaSig = '';
  String _modeSig = '';
  String _segSig = '';

  bool _isAdventureMode(String mode) {
    final m = mode.trim().toLowerCase();
    return m == 'bikepacking' || m == 'backpacking';
  }

  String _segmentRoutingSignature(List<String> types) {
    if (types.isEmpty) return '';
    return types.map((t) => t.trim().toLowerCase()).join(',');
  }

  String _segmentRoutingTypeFor(int segmentIndex) {
    if (segmentIndex < 0) return 'calculated';
    if (segmentIndex >= widget.segmentRoutingTypes.length) return 'calculated';
    final v = widget.segmentRoutingTypes[segmentIndex].trim().toLowerCase();
    return (v == 'direct') ? 'direct' : 'calculated';
  }

  Color _standardRouteColor(String mode) {
    if (_isAdventureMode(mode)) return Colors.green;
    return Colors.blue;
  }

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
    _viaSig = _signature(widget.routeVia);
    _modeSig = widget.transportMode.trim().toLowerCase();
    _segSig = _segmentRoutingSignature(widget.segmentRoutingTypes);
    // run rebuild defensively so exceptions don't bubble to the framework
    _safeRebuild();
  }

  @override
  void didUpdateWidget(covariant MapEmbed oldWidget) {
    super.didUpdateWidget(oldWidget);

    final newMain = _signature(widget.points);
    final newSecondary = _signature(widget.secondaryPoints);
    final newVia = _signature(widget.routeVia);
    final newMode = widget.transportMode.trim().toLowerCase();
    final newSeg = _segmentRoutingSignature(widget.segmentRoutingTypes);
    if (newMain != _mainSig ||
        newSecondary != _secondarySig ||
        newVia != _viaSig ||
        newMode != _modeSig ||
        newSeg != _segSig) {
      _mainSig = newMain;
      _secondarySig = newSecondary;
      _viaSig = newVia;
      _modeSig = newMode;
      _segSig = newSeg;
      _rebuildFromPoints();
    }
  }

  List<Map<String, dynamic>> _segmentPoints({required int afterIndex}) {
    final pts = widget.points;
    if (pts.length < 2) return const [];
    if (afterIndex < 0 || afterIndex >= pts.length - 1) return const [];

    final out = <Map<String, dynamic>>[pts[afterIndex]];
    for (final v in widget.routeVia) {
      final after = (v['afterIndex'] as num?)?.toInt();
      if (after != afterIndex) continue;
      out.add({
        'lat': (v['lat'] as num?)?.toDouble() ?? 0.0,
        'lon': (v['lon'] as num?)?.toDouble() ?? 0.0,
      });
    }
    out.add(pts[afterIndex + 1]);
    return out;
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

  List<Map<String, dynamic>> _expandedPointsWithVia() {
    final pts = widget.points;
    if (pts.length < 2 || widget.routeVia.isEmpty) return pts;

    final byAfter = <int, List<Map<String, dynamic>>>{};
    for (final v in widget.routeVia) {
      final after = (v['afterIndex'] as num?)?.toInt();
      if (after == null || after < 0 || after >= pts.length - 1) continue;
      byAfter.putIfAbsent(after, () => []).add({
        'lat': (v['lat'] as num?)?.toDouble() ?? 0.0,
        'lon': (v['lon'] as num?)?.toDouble() ?? 0.0,
      });
    }

    if (byAfter.isEmpty) return pts;

    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < pts.length; i++) {
      out.add(pts[i]);
      if (i < pts.length - 1) {
        final list = byAfter[i];
        if (list != null) out.addAll(list);
      }
    }
    return out;
  }

  int _nearestSegmentAfterIndex(ll.LatLng tap) {
    final pts = widget.points;
    if (pts.length < 2) return 0;

    double best = double.infinity;
    var bestAfter = 0;
    for (var i = 0; i < pts.length - 1; i++) {
      final a = ll.LatLng(_toDouble(pts[i]['lat']), _toDouble(pts[i]['lon']));
      final b = ll.LatLng(
        _toDouble(pts[i + 1]['lat']),
        _toDouble(pts[i + 1]['lon']),
      );
      final d = _distPointToSegmentSq(tap, a, b);
      if (d < best) {
        best = d;
        bestAfter = i;
      }
    }
    return bestAfter;
  }

  double _distPointToSegmentSq(ll.LatLng p, ll.LatLng a, ll.LatLng b) {
    final px = p.longitude;
    final py = p.latitude;
    final ax = a.longitude;
    final ay = a.latitude;
    final bx = b.longitude;
    final by = b.latitude;

    final abx = bx - ax;
    final aby = by - ay;
    final apx = px - ax;
    final apy = py - ay;

    final abLenSq = (abx * abx) + (aby * aby);
    if (abLenSq <= 1e-12) {
      final dx = px - ax;
      final dy = py - ay;
      return (dx * dx) + (dy * dy);
    }

    var t = (apx * abx + apy * aby) / abLenSq;
    if (t < 0) t = 0;
    if (t > 1) t = 1;

    final cx = ax + t * abx;
    final cy = ay + t * aby;
    final dx = px - cx;
    final dy = py - cy;
    return (dx * dx) + (dy * dy);
  }

  Future<void> _rebuildFromPoints() async {
    _markers = [];
    _secondaryMarkers = [];
    _viaMarkers = [];
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

    for (var i = 0; i < widget.routeVia.length; i++) {
      final v = widget.routeVia[i];
      final lat = _toDouble(v['lat']);
      final lon = _toDouble(v['lon']);
      if (lat == 0.0 && lon == 0.0) continue;
      _viaMarkers.add(
        Marker(
          width: 18,
          height: 18,
          point: ll.LatLng(lat, lon),
          builder:
              (ctx) => GestureDetector(
                onTap: () {
                  _suppressMapTapUntilMs =
                      DateTime.now().millisecondsSinceEpoch + 300;
                  widget.onViaTapDelete?.call(i);
                },
                onLongPress: () {
                  _suppressMapTapUntilMs =
                      DateTime.now().millisecondsSinceEpoch + 300;
                  widget.onViaTapDelete?.call(i);
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF2E7D32),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                ),
              ),
        ),
      );
    }

    final mode = widget.transportMode.trim().toLowerCase();
    final standardColor = _standardRouteColor(mode);

    final out = <Polyline>[];
    var distSum = 0.0;
    var durSum = 0.0;

    for (var seg = 0; seg < widget.points.length - 1; seg++) {
      final segType = _segmentRoutingTypeFor(seg);
      final segPts = _segmentPoints(afterIndex: seg);
      if (segPts.length < 2) continue;

      final fallback =
          segPts
              .map((p) => ll.LatLng(_toDouble(p['lat']), _toDouble(p['lon'])))
              .toList();

      if (segType == 'direct') {
        out.add(
          Polyline(
            points: fallback,
            strokeWidth: 3.0,
            color: Colors.green.withOpacity(0.9),
          ),
        );
        continue;
      }

      // OSRM per segment.
      try {
        final profile = switch (mode) {
          'walking' => 'walking',
          'biking' => 'cycling',
          _ => 'driving',
        };

        var coords = segPts.map((p) => '${p['lon']},${p['lat']}').join(';');
        var url = Uri.parse(
          'https://router.project-osrm.org/route/v1/$profile/$coords?overview=full&geometries=geojson',
        );

        var resp = await http.get(url);
        if (resp.statusCode == 200) {
          final data = jsonDecode(resp.body) as Map<String, dynamic>;
          final routes = data['routes'] as List<dynamic>?;
          if (routes != null && routes.isNotEmpty) {
            final route0 = routes.first as Map<String, dynamic>;
            final dist = (route0['distance'] as num?)?.toDouble();
            final dur = (route0['duration'] as num?)?.toDouble();
            final geom = route0['geometry'] as Map<String, dynamic>?;
            final coordsList =
                (geom?['coordinates'] as List<dynamic>?)?.cast<List<dynamic>>();
            if (coordsList != null && coordsList.isNotEmpty) {
              final latlngs =
                  coordsList
                      .map(
                        (c) => ll.LatLng(
                          (c[1] as num).toDouble(),
                          (c[0] as num).toDouble(),
                        ),
                      )
                      .toList();
              out.add(
                Polyline(
                  points: latlngs,
                  strokeWidth: 4.0,
                  color: standardColor,
                ),
              );
              if (dist != null) distSum += dist;
              if (dur != null) durSum += dur;
              continue;
            }
          }
        }

        // Try reversed lat/lon order if upstream data is flipped.
        coords = segPts.map((p) => '${p['lat']},${p['lon']}').join(';');
        url = Uri.parse(
          'https://router.project-osrm.org/route/v1/$profile/$coords?overview=full&geometries=geojson',
        );
        resp = await http.get(url);
        if (resp.statusCode == 200) {
          final data = jsonDecode(resp.body) as Map<String, dynamic>;
          final routes = data['routes'] as List<dynamic>?;
          if (routes != null && routes.isNotEmpty) {
            final route0 = routes.first as Map<String, dynamic>;
            final dist = (route0['distance'] as num?)?.toDouble();
            final dur = (route0['duration'] as num?)?.toDouble();
            final geom = route0['geometry'] as Map<String, dynamic>?;
            final coordsList =
                (geom?['coordinates'] as List<dynamic>?)?.cast<List<dynamic>>();
            if (coordsList != null && coordsList.isNotEmpty) {
              final latlngs =
                  coordsList
                      .map(
                        (c) => ll.LatLng(
                          (c[1] as num).toDouble(),
                          (c[0] as num).toDouble(),
                        ),
                      )
                      .toList();
              out.add(
                Polyline(
                  points: latlngs,
                  strokeWidth: 4.0,
                  color: standardColor,
                ),
              );
              if (dist != null) distSum += dist;
              if (dur != null) durSum += dur;
              continue;
            }
          }
        }
      } catch (_) {
        // fall through to fallback
      }

      out.add(
        Polyline(
          points: fallback,
          strokeWidth: 3.0,
          color: standardColor.withOpacity(0.6),
        ),
      );
    }

    setState(() {
      _routes = out;
    });

    if (distSum > 0 && durSum > 0) {
      widget.onRouteSummary?.call(distSum, durSum);
    }
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
          _routes = const [];
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.points.isEmpty) {
      return const Center(child: Text('No points yet'));
    }

    final mode = widget.transportMode.trim().toLowerCase();
    final tileTemplate =
        (mode == 'biking' || mode == 'walking' || _isAdventureMode(mode))
            ? 'https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png'
            : 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png';

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
          if (DateTime.now().millisecondsSinceEpoch < _suppressMapTapUntilMs) {
            return;
          }
          if (widget.onRouteTapAddVia != null && widget.points.length >= 2) {
            final after = _nearestSegmentAfterIndex(latlng);
            widget.onRouteTapAddVia?.call(
              after,
              latlng.latitude,
              latlng.longitude,
            );
            return;
          }
          widget.onMapTap?.call(latlng.latitude, latlng.longitude);
        },
      ),
      children: [
        TileLayer(
          urlTemplate: tileTemplate,
          subdomains: const ['a', 'b', 'c'],
          userAgentPackageName: 'com.example.trypr',
        ),
        if (_routes.isNotEmpty) PolylineLayer(polylines: _routes),
        if (_secondaryMarkers.isNotEmpty)
          MarkerLayer(markers: _secondaryMarkers),
        if (_viaMarkers.isNotEmpty) MarkerLayer(markers: _viaMarkers),
        MarkerLayer(markers: _markers),
      ],
    );
  }
}
