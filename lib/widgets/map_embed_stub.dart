import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:math' as math;

// Native (non-web) map implementation using flutter_map. Supports tapping to
// add a dropped pin via the provided `onMapTap` callback and requests an OSRM
// driving route for multiple waypoints to draw a road-following polyline.
class MapEmbed extends StatefulWidget {
  final List<Map<String, dynamic>> points;
  final void Function(double lat, double lon)? onMapTap;
  final void Function(Map<String, dynamic> point)? onPointTap;
  final void Function(double distanceMeters, double durationSeconds)?
  onRouteSummary;
  final void Function(List<Map<String, dynamic>> geometry)? onRouteGeometry;
  final void Function(List<String> lines)? onRouteInstructions;
  final void Function(List<Map<String, dynamic>> segments)?
  onRouteSegmentDetails;
  final void Function(Map<String, dynamic> arrivalStop)? onTransitArrivalStop;
  final void Function(bool isComputing)? onRouteComputingChanged;
  final void Function(String message)? onRouteError;
  final Map<String, dynamic>? focusedRouteStep;
  final List<Map<String, dynamic>> initialRouteGeometry;
  final List<String> initialRouteInstructions;
  final List<Map<String, dynamic>> initialRouteSegmentDetails;
  final bool preferInitialRouteData;
  final String transportMode;
  final List<String> segmentTransportModes;
  final List<Map<String, dynamic>> routeVia;
  final List<String> segmentRoutingTypes;
  final void Function(int afterIndex, double lat, double lon)? onRouteTapAddVia;
  final void Function(int viaIndex, double lat, double lon)? onViaDragEnd;
  final void Function(int viaIndex)? onViaTapDelete;
  final void Function(Map<String, dynamic> campsite)? onHikingCampsiteTap;
  final void Function(Map<String, dynamic> accessPoint)? onPortageAccessTap;
  final List<Map<String, dynamic>> secondaryPoints;
  final bool disableDefaultUi;
  final bool disableGestures;
  final bool zoomControlsEnabled;
  final bool showNearbyContextOverlays;
  final double minZoom;
  final double maxZoom;
  final double routeComputingBannerTop;
  const MapEmbed({
    super.key,
    required this.points,
    this.onMapTap,
    this.onPointTap,
    this.onRouteSummary,
    this.onRouteGeometry,
    this.onRouteInstructions,
    this.onRouteSegmentDetails,
    this.onTransitArrivalStop,
    this.onRouteComputingChanged,
    this.onRouteError,
    this.focusedRouteStep,
    this.initialRouteGeometry = const [],
    this.initialRouteInstructions = const [],
    this.initialRouteSegmentDetails = const [],
    this.preferInitialRouteData = false,
    this.transportMode = 'car',
    this.segmentTransportModes = const [],
    this.routeVia = const [],
    this.segmentRoutingTypes = const [],
    this.onRouteTapAddVia,
    this.onViaDragEnd,
    this.onViaTapDelete,
    this.onHikingCampsiteTap,
    this.onPortageAccessTap,
    this.secondaryPoints = const [],
    this.disableDefaultUi = false,
    this.disableGestures = false,
    this.zoomControlsEnabled = false,
    this.showNearbyContextOverlays = true,
    this.minZoom = 3,
    this.maxZoom = 18,
    this.routeComputingBannerTop = 12,
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
  String _segModeSig = '';
  String _lastRouteCalcSig = '';

  String _normalizeTransportMode(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'car':
      case 'driving':
        return 'driving';
      case 'plane':
      case 'flying':
      case 'flight':
        return 'flying';
      case 'train':
      case 'rail':
      case 'public_transit':
      case 'public transit':
      case 'transit':
        return 'transit';
      case 'walk':
      case 'walking':
        return 'walking';
      case 'bike':
      case 'biking':
      case 'bicycling':
      case 'bikepacking':
        return 'biking';
      case 'portaging':
      case 'canoe':
      case 'canoeing':
      case 'portage':
        return 'portaging';
      case 'hiking':
      case 'backpacking':
        return 'hiking';
      case 'gas_stops':
      case 'gas/stops':
      case 'gas-stops':
      case 'gasstops':
        return 'driving';
      default:
        return 'driving';
    }
  }

  bool _isAdventureMode(String mode) {
    final m = mode.trim().toLowerCase();
    return m == 'hiking' || m == 'portaging';
  }

  String _segmentRoutingSignature(List<String> types) {
    final segments = math.max(0, widget.points.length - 1);
    if (segments <= 0) return '';
    return List<String>.generate(segments, (index) {
      final raw = index < types.length ? types[index] : '';
      return _normalizeSegmentRoutingType(
        raw,
        mode: _segmentTransportModeFor(index),
      );
    }).join(',');
  }

  String _segmentTransportSignature(List<String> types) {
    if (types.isEmpty) return '';
    return types.map(_normalizeTransportMode).join(',');
  }

  String _segmentTransportModeFor(int segmentIndex) {
    final fallback = _normalizeTransportMode(widget.transportMode);
    if (segmentIndex < 0) return fallback;
    if (segmentIndex >= widget.segmentTransportModes.length) return fallback;
    return _normalizeTransportMode(widget.segmentTransportModes[segmentIndex]);
  }

  String _defaultRoutingTypeForMode(String mode) {
    switch (_normalizeTransportMode(mode)) {
      case 'hiking':
        return 'trails';
      case 'portaging':
        return 'waterway';
      default:
        return 'calculated';
    }
  }

  String _normalizeSegmentRoutingType(String raw, {required String mode}) {
    final normalizedMode = _normalizeTransportMode(mode);
    final value = raw.trim().toLowerCase();
    if (value == 'direct') return 'direct';
    switch (normalizedMode) {
      case 'hiking':
        return 'trails';
      case 'portaging':
        return 'waterway';
      default:
        return 'calculated';
    }
  }

  String _segmentRoutingTypeFor(int segmentIndex) {
    if (segmentIndex < 0) return 'calculated';
    final mode = _segmentTransportModeFor(segmentIndex);
    if (segmentIndex >= widget.segmentRoutingTypes.length) {
      return _defaultRoutingTypeForMode(mode);
    }
    return _normalizeSegmentRoutingType(
      widget.segmentRoutingTypes[segmentIndex],
      mode: mode,
    );
  }

  Color _standardRouteColor(String mode) {
    if (_isAdventureMode(mode)) return const Color(0xFF2962FF);
    return Colors.blue;
  }

  double _haversineMeters(ll.LatLng a, ll.LatLng b) {
    const r = 6371000.0;
    final dLat = (b.latitude - a.latitude) * (math.pi / 180.0);
    final dLon = (b.longitude - a.longitude) * (math.pi / 180.0);
    final lat1 = a.latitude * (math.pi / 180.0);
    final lat2 = b.latitude * (math.pi / 180.0);
    final sinDLat = math.sin(dLat / 2);
    final sinDLon = math.sin(dLon / 2);
    final aa =
        sinDLat * sinDLat + math.cos(lat1) * math.cos(lat2) * sinDLon * sinDLon;
    final c = 2 * math.atan2(math.sqrt(aa), math.sqrt(1 - aa));
    return r * c;
  }

  IconData _iconFor(String kind, String category) {
    if (kind == 'accommodation') return Icons.hotel;
    switch (category) {
      case 'Driving':
        return Icons.directions_car;
      case 'Transit':
        return Icons.directions_transit;
      case 'Hiking':
        return Icons.terrain;
      case 'Portaging':
        return Icons.kayaking;
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
      case 'Free Time':
        return Icons.free_breakfast;
      default:
        return Icons.location_on;
    }
  }

  Color _colorFor(String kind, String category) {
    if (kind == 'accommodation') return Colors.purple.shade600;
    switch (category) {
      case 'Driving':
        return Colors.blueAccent;
      case 'Transit':
        return const Color(0xFF546E7A);
      case 'Hiking':
        return const Color(0xFF2E7D32);
      case 'Portaging':
        return const Color(0xFF00897B);
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
      case 'Free Time':
        return const Color(0xFF78909C);
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
    _segModeSig = _segmentTransportSignature(widget.segmentTransportModes);
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
    final newSegModes = _segmentTransportSignature(
      widget.segmentTransportModes,
    );
    if (newMain != _mainSig ||
        newSecondary != _secondarySig ||
        newVia != _viaSig ||
        newMode != _modeSig ||
        newSeg != _segSig ||
        newSegModes != _segModeSig) {
      _mainSig = newMain;
      _secondarySig = newSecondary;
      _viaSig = newVia;
      _modeSig = newMode;
      _segSig = newSeg;
      _segModeSig = newSegModes;
      _rebuildFromPoints();
    }
  }

  List<Map<String, dynamic>> _segmentPoints({required int afterIndex}) {
    final pts = widget.points;
    if (pts.length < 2) return const [];
    if (afterIndex < 0 || afterIndex >= pts.length - 1) return const [];

    final out = <Map<String, dynamic>>[pts[afterIndex]];
    if (_segmentTransportModeFor(afterIndex) != 'transit') {
      for (final v in widget.routeVia) {
        final after = (v['afterIndex'] as num?)?.toInt();
        if (after != afterIndex) continue;
        out.add({
          'lat': (v['lat'] as num?)?.toDouble() ?? 0.0,
          'lon': (v['lon'] as num?)?.toDouble() ?? 0.0,
        });
      }
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

  String _routeCalculationSignature() {
    final b = StringBuffer();
    for (final p in widget.points) {
      b
        ..write(_toDouble(p['lat']).toStringAsFixed(6))
        ..write(',')
        ..write(_toDouble(p['lon']).toStringAsFixed(6))
        ..write(';');
    }
    b
      ..write('|')
      ..write(_modeSig)
      ..write('|')
      ..write(_segSig)
      ..write('|')
      ..write(_segModeSig)
      ..write('|')
      ..write(_viaSig);
    return b.toString();
  }

  // ignore: unused_element
  List<Map<String, dynamic>> _expandedPointsWithVia() {
    final pts = widget.points;
    if (pts.length < 2 || widget.routeVia.isEmpty) return pts;

    final byAfter = <int, List<Map<String, dynamic>>>{};
    for (final v in widget.routeVia) {
      final after = (v['afterIndex'] as num?)?.toInt();
      if (after == null || after < 0 || after >= pts.length - 1) continue;
      if (_segmentTransportModeFor(after) == 'transit') continue;
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

  List<Map<String, dynamic>> _flattenRouteGeometry(
    Map<int, List<ll.LatLng>> segGeometry,
  ) {
    if (segGeometry.isEmpty) return const [];
    final keys = segGeometry.keys.toList()..sort();
    final out = <Map<String, dynamic>>[];
    double? lastLat;
    double? lastLon;
    for (final seg in keys) {
      final path = segGeometry[seg] ?? const <ll.LatLng>[];
      for (final p in path) {
        final lat = p.latitude;
        final lon = p.longitude;
        if (lastLat != null &&
            lastLon != null &&
            (lat - lastLat).abs() < 1e-7 &&
            (lon - lastLon).abs() < 1e-7) {
          continue;
        }
        out.add({'lat': lat, 'lon': lon, 'lng': lon});
        lastLat = lat;
        lastLon = lon;
      }
    }
    return out;
  }

  void _emitRouteGeometry(Map<int, List<ll.LatLng>> segGeometry) {
    final cb = widget.onRouteGeometry;
    if (cb == null) return;
    cb(_flattenRouteGeometry(segGeometry));
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
                (ctx) => GestureDetector(
                  onTap: () {
                    _suppressMapTapUntilMs =
                        DateTime.now().millisecondsSinceEpoch + 300;
                    widget.onPointTap?.call(p);
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.14),
                      shape: BoxShape.circle,
                    ),
                    padding: const EdgeInsets.all(6),
                    child: Icon(
                      _iconFor(kind, category),
                      color: color,
                      size: 24,
                    ),
                  ),
                ),
          );
        }).toList();

    final stopNumbers = <int?>[];
    var nextStopNumber = 1;
    for (final point in pts) {
      if (_pointUsesStopBadge(point)) {
        stopNumbers.add(nextStopNumber++);
      } else {
        stopNumbers.add(null);
      }
    }

    for (var i = 0; i < pts.length; i++) {
      final p = pts[i];
      final lat = _toDouble(p['lat']);
      final lon = _toDouble(p['lon']);
      final stopNumber = stopNumbers[i];
      _markers.add(
        Marker(
          width: 36,
          height: 36,
          point: ll.LatLng(lat, lon),
          builder:
              (ctx) => GestureDetector(
                onTap: () {
                  _suppressMapTapUntilMs =
                      DateTime.now().millisecondsSinceEpoch + 300;
                  widget.onPointTap?.call(p);
                },
                child:
                    stopNumber != null
                        ? CircleAvatar(child: Text('$stopNumber'))
                        : Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            color: Theme.of(ctx).colorScheme.primary,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2),
                          ),
                        ),
              ),
        ),
      );
    }

    for (var i = 0; i < widget.routeVia.length; i++) {
      final v = widget.routeVia[i];
      final after = (v['afterIndex'] as num?)?.toInt() ?? -1;
      if (after >= 0 && _segmentTransportModeFor(after) == 'transit') {
        continue;
      }
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
                child: Opacity(
                  opacity: 0.7,
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF2E7D32),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                  ),
                ),
              ),
        ),
      );
    }

    final routeSig = _routeCalculationSignature();
    if (widget.preferInitialRouteData &&
        !widget.showNearbyContextOverlays &&
        widget.initialRouteGeometry.length >= 2) {
      final cachedPath = widget.initialRouteGeometry
          .map((point) {
            final lat = _toDouble(point['lat']);
            final lon = _toDouble(point['lon'] ?? point['lng']);
            return ll.LatLng(lat, lon);
          })
          .toList(growable: false);
      if (cachedPath.length >= 2) {
        widget.onRouteGeometry?.call(widget.initialRouteGeometry);
        widget.onRouteInstructions?.call(
          widget.initialRouteInstructions.take(8).toList(growable: false),
        );
        widget.onRouteSegmentDetails?.call(widget.initialRouteSegmentDetails);
        _routes = [
          Polyline(
            points: cachedPath,
            strokeWidth:
                _isAdventureMode(widget.transportMode.trim().toLowerCase())
                    ? 4.0
                    : 3.0,
            color: _standardRouteColor(widget.transportMode).withOpacity(0.9),
          ),
        ];
        _lastRouteCalcSig = routeSig;
        if (mounted) {
          setState(() {});
        }
        return;
      }
    }
    if (_lastRouteCalcSig == routeSig) {
      if (mounted) {
        setState(() {});
      }
      return;
    }

    final out = <Polyline>[];
    final segGeometry = <int, List<ll.LatLng>>{};
    var distSum = 0.0;
    var durSum = 0.0;

    for (var seg = 0; seg < widget.points.length - 1; seg++) {
      final segType = _segmentRoutingTypeFor(seg);
      final segPts = _segmentPoints(afterIndex: seg);
      if (segPts.length < 2) continue;
      final mode = _segmentTransportModeFor(seg);
      final standardColor = _standardRouteColor(mode);
      final isAdventure = _isAdventureMode(mode);

      final fallback =
          segPts
              .map((p) => ll.LatLng(_toDouble(p['lat']), _toDouble(p['lon'])))
              .toList();

      if (mode == 'flying') {
        var segDist = 0.0;
        for (var i = 0; i + 1 < fallback.length; i++) {
          segDist += _haversineMeters(fallback[i], fallback[i + 1]);
        }
        distSum += segDist;
        segGeometry[seg] = fallback;
        out.add(
          Polyline(
            points: fallback,
            strokeWidth: 3.0,
            color: Colors.indigo.shade400,
          ),
        );
        continue;
      }

      if (segType == 'direct') {
        segGeometry[seg] = fallback;
        out.add(
          Polyline(
            points: fallback,
            strokeWidth: isAdventure ? 4.0 : 3.0,
            color:
                isAdventure
                    ? const Color(0xFF00E676)
                    : Colors.green.withOpacity(0.9),
          ),
        );
        continue;
      }

      if (mode == 'transit') {
        // Never route transit/train legs through OSRM driving roads.
        // Keep a neutral straight-line estimate when live transit data
        // isn't available on this platform.
        var segDist = 0.0;
        for (var i = 0; i + 1 < fallback.length; i++) {
          segDist += _haversineMeters(fallback[i], fallback[i + 1]);
        }
        distSum += segDist;
        segGeometry[seg] = fallback;
        out.add(
          Polyline(
            points: fallback,
            strokeWidth: 4.0,
            color: const Color(0xFF546E7A).withValues(alpha: 0.7),
          ),
        );
        continue;
      }

      // OSRM per segment.
      try {
        final profile = switch (mode) {
          'walking' => 'walking',
          'hiking' => 'walking',
          'backpacking' => 'walking',
          'portaging' => 'walking',
          'biking' => 'cycling',
          'bikepacking' => 'cycling',
          _ => 'driving',
        };

        var coords = segPts.map((p) => '${p['lon']},${p['lat']}').join(';');
        var url = Uri.parse(
          'https://router.project-osrm.org/route/v1/$profile/$coords?overview=full&geometries=geojson',
        );

        var resp = await http
            .get(url)
            .timeout(
              const Duration(seconds: 8),
              onTimeout: () {
                return http.Response('{"routes":[]}', 504);
              },
            );
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
                  strokeWidth: isAdventure ? 5.0 : 4.0,
                  color: isAdventure ? const Color(0xFF00E676) : standardColor,
                ),
              );
              segGeometry[seg] = latlngs;
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
        resp = await http
            .get(url)
            .timeout(
              const Duration(seconds: 8),
              onTimeout: () {
                return http.Response('{"routes":[]}', 504);
              },
            );
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
                  strokeWidth: isAdventure ? 5.0 : 4.0,
                  color: isAdventure ? const Color(0xFF00E676) : standardColor,
                ),
              );
              segGeometry[seg] = latlngs;
              if (dist != null) distSum += dist;
              if (dur != null) durSum += dur;
              continue;
            }
          }
        }
      } catch (_) {
        // fall through to fallback
      }

      segGeometry[seg] = fallback;
      out.add(
        Polyline(
          points: fallback,
          strokeWidth: isAdventure ? 4.0 : 3.0,
          color:
              isAdventure
                  ? const Color(0xFF00E676).withOpacity(0.7)
                  : standardColor.withOpacity(0.6),
        ),
      );
    }

    _emitRouteGeometry(segGeometry);
    widget.onRouteSegmentDetails?.call(const []);
    _lastRouteCalcSig = routeSig;

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

  bool _boolish(dynamic value, {required bool fallback}) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized == 'true' || normalized == 'yes' || normalized == '1') {
        return true;
      }
      if (normalized == 'false' || normalized == 'no' || normalized == '0') {
        return false;
      }
    }
    return fallback;
  }

  bool _pointUsesStopBadge(Map<String, dynamic> point) {
    return _boolish(point['isStop'], fallback: true);
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

    final segments = widget.points.length > 1 ? widget.points.length - 1 : 0;
    var useTopo = false;
    if (segments <= 0) {
      final mode = _normalizeTransportMode(widget.transportMode);
      useTopo =
          mode == 'biking' ||
          mode == 'walking' ||
          mode == 'hiking' ||
          _isAdventureMode(mode);
    } else {
      for (var i = 0; i < segments; i++) {
        final mode = _segmentTransportModeFor(i);
        if (mode == 'biking' ||
            mode == 'walking' ||
            mode == 'hiking' ||
            _isAdventureMode(mode)) {
          useTopo = true;
          break;
        }
      }
    }
    final tileTemplate =
        useTopo
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
        minZoom: widget.minZoom,
        maxZoom: widget.maxZoom,
        onTap: (tapPos, latlng) {
          if (widget.disableGestures) return;
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
        interactiveFlags:
            widget.disableGestures ? InteractiveFlag.none : InteractiveFlag.all,
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

class MapPreview3D extends StatelessWidget {
  final double lat;
  final double lon;
  final String title;

  const MapPreview3D({
    super.key,
    required this.lat,
    required this.lon,
    this.title = '',
  });

  @override
  Widget build(BuildContext context) {
    final center = ll.LatLng(lat, lon);
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: FlutterMap(
        options: MapOptions(
          center: center,
          zoom: 14,
          minZoom: 2,
          maxZoom: 18,
          interactiveFlags: InteractiveFlag.none,
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
            subdomains: const ['a', 'b', 'c'],
            userAgentPackageName: 'com.example.trypr',
          ),
          MarkerLayer(
            markers: [
              Marker(
                width: 24,
                height: 24,
                point: center,
                builder: (_) => const Icon(Icons.place, color: Colors.red),
              ),
            ],
          ),
          if (title.isNotEmpty)
            MarkerLayer(
              markers: [
                Marker(
                  width: 200,
                  height: 32,
                  point: center,
                  builder:
                      (_) => Align(
                        alignment: Alignment.topCenter,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.6),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
