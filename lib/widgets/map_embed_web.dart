import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:ui' as ui;
import 'dart:ui_web' as ui_web;
import 'dart:math' as math;

import 'dart:html' as html;

import 'dart:convert';

import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import 'package:http/http.dart' as http;

import 'package:trypr/services/google_maps_loader_web.dart';

const double _previewBubbleWidth = 280.0;
const double _previewMapHeight = 160.0;
const double _previewInfoHeight = 64.0;
const double _previewTriangleHeight = 10.0;
const double _previewBubbleHeight = _previewMapHeight + _previewInfoHeight;

class MapEmbed extends StatelessWidget {
  final List<Map<String, dynamic>> points;
  final void Function(double lat, double lon)? onMapTap;
  final void Function(Map<String, dynamic> point)? onPointTap;
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
  final bool disableDefaultUi;
  final bool disableGestures;
  final bool zoomControlsEnabled;
  final double minZoom;
  final double maxZoom;
  const MapEmbed({
    super.key,
    required this.points,
    this.onMapTap,
    this.onPointTap,
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
    this.disableDefaultUi = false,
    this.disableGestures = false,
    this.zoomControlsEnabled = false,
    this.minZoom = 3,
    this.maxZoom = 18,
  });

  String _resolveMapsKey() {
    const fromDefine = String.fromEnvironment('GOOGLE_MAPS_API_KEY');
    if (fromDefine.isNotEmpty) return fromDefine;

    try {
      final meta = html.document.querySelector(
        'meta[name="google-maps-api-key"]',
      );
      final fromMeta = meta?.getAttribute('content')?.trim() ?? '';
      return fromMeta;
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final mapsKey = _resolveMapsKey();
    if (mapsKey.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            'Google Maps is not configured. Build with '
            '--dart-define=GOOGLE_MAPS_API_KEY=YOUR_KEY '
            'or set <meta name="google-maps-api-key" ...> in web/index.html',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return _MapEmbedWebStateful(
      points: points,
      secondaryPoints: secondaryPoints,
      onMapTap: onMapTap,
      onPointTap: onPointTap,
      onRouteSummary: onRouteSummary,
      onRouteInstructions: onRouteInstructions,
      onTransitArrivalStop: onTransitArrivalStop,
      transportMode: transportMode,
      routeVia: routeVia,
      segmentRoutingTypes: segmentRoutingTypes,
      onRouteTapAddVia: onRouteTapAddVia,
      onViaDragEnd: onViaDragEnd,
      onViaTapDelete: onViaTapDelete,
      mapsKey: mapsKey,
      disableDefaultUi: disableDefaultUi,
      disableGestures: disableGestures,
      zoomControlsEnabled: zoomControlsEnabled,
      minZoom: minZoom,
      maxZoom: maxZoom,
    );
  }
}

class _MapEmbedWebStateful extends StatefulWidget {
  final List<Map<String, dynamic>> points;
  final List<Map<String, dynamic>> secondaryPoints;
  final void Function(double lat, double lon)? onMapTap;
  final void Function(Map<String, dynamic> point)? onPointTap;
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
  final String mapsKey;
  final bool disableDefaultUi;
  final bool disableGestures;
  final bool zoomControlsEnabled;
  final double minZoom;
  final double maxZoom;

  const _MapEmbedWebStateful({
    required this.points,
    required this.secondaryPoints,
    required this.onMapTap,
    required this.onPointTap,
    required this.onRouteSummary,
    required this.onRouteInstructions,
    required this.onTransitArrivalStop,
    required this.transportMode,
    required this.routeVia,
    required this.segmentRoutingTypes,
    required this.onRouteTapAddVia,
    required this.onViaDragEnd,
    required this.onViaTapDelete,
    required this.mapsKey,
    required this.disableDefaultUi,
    required this.disableGestures,
    required this.zoomControlsEnabled,
    required this.minZoom,
    required this.maxZoom,
  });

  @override
  State<_MapEmbedWebStateful> createState() => _MapEmbedWebStatefulState();
}

class _MapEmbedWebStatefulState extends State<_MapEmbedWebStateful> {
  gmaps.GoogleMapController? _controller;
  String? _controllerKeySig;
  Set<gmaps.Marker> _markers = const {};
  Set<gmaps.Polyline> _polylines = const {};

  int _suppressMapTapUntilMs = 0;

  late final String _instanceId = identityHashCode(this).toRadixString(16);

  String _mainSig = '';
  String _secondarySig = '';
  int _rebuildSeq = 0;

  List<String> _lastInstructions = const [];

  final _markerIconCache = _MarkerIconCache();

  Map<String, dynamic>? _previewPoint;
  gmaps.LatLng? _previewLatLng;
  Offset? _previewOffset;
  Size _mapSize = Size.zero;
  Timer? _previewUpdateTimer;

  String _mapKeySig() {
    return '${_instanceId}_${_mainSig}_${_secondarySig}_${widget.transportMode}_${_viaSignature(widget.routeVia)}_${_segmentRoutingSignature(widget.segmentRoutingTypes)}';
  }

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
    if (_isAdventureMode(mode)) {
      // Garmin-style High-Vis Green
      return const Color(0xFF00E676);
    }
    return Colors.blue;
  }

  Color? _parseHexColor(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return null;
    if (s.startsWith('#')) s = s.substring(1);
    if (s.length == 6) {
      final v = int.tryParse('FF$s', radix: 16);
      if (v == null) return null;
      return Color(v);
    }
    if (s.length == 8) {
      final v = int.tryParse(s, radix: 16);
      if (v == null) return null;
      return Color(v);
    }
    return null;
  }

  double _haversineMeters(gmaps.LatLng a, gmaps.LatLng b) {
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

  List<gmaps.LatLng> _decodeGooglePolyline(String encoded) {
    final points = <gmaps.LatLng>[];
    var index = 0;
    var lat = 0;
    var lng = 0;

    while (index < encoded.length) {
      var result = 0;
      var shift = 0;
      int b;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20 && index < encoded.length);
      final dLat = ((result & 1) != 0) ? ~(result >> 1) : (result >> 1);
      lat += dLat;

      result = 0;
      shift = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20 && index < encoded.length);
      final dLng = ((result & 1) != 0) ? ~(result >> 1) : (result >> 1);
      lng += dLng;

      points.add(gmaps.LatLng(lat / 1e5, lng / 1e5));
    }

    return points;
  }

  String _stripHtml(String raw) {
    return raw
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('  ', ' ')
        .trim();
  }

  IconData _iconFor(String kindRaw, String categoryRaw) {
    final kind = kindRaw.trim().toLowerCase();
    final category = categoryRaw.trim().toLowerCase();
    if (kind == 'accommodation') return Icons.hotel;

    switch (category) {
      case 'driving':
        return Icons.directions_car;
      case 'hiking':
        return Icons.terrain;
      case 'biking':
        return Icons.directions_bike;
      case 'walking':
        return Icons.directions_walk;
      case 'museum':
        return Icons.museum;
      case 'sightseeing':
        return Icons.camera_alt;
      case 'exploring':
        return Icons.explore;
      case 'restaurant':
        return Icons.restaurant;
      case 'shopping':
        return Icons.shopping_bag;
      case 'photography':
        return Icons.photo_camera;
      case 'adventure':
        return Icons.local_activity;
      default:
        return Icons.location_on;
    }
  }

  Color _colorFor(String kindRaw, String categoryRaw) {
    final kind = kindRaw.trim().toLowerCase();
    final category = categoryRaw.trim().toLowerCase();
    if (kind == 'accommodation') return Colors.purple.shade600;

    switch (category) {
      case 'driving':
        return Colors.blueAccent;
      case 'hiking':
        return const Color(0xFF2E7D32);
      case 'biking':
        return const Color(0xFF1565C0);
      case 'walking':
        return const Color(0xFF00796B);
      case 'museum':
        return const Color(0xFF6A1B9A);
      case 'sightseeing':
        return const Color(0xFFF57C00);
      case 'exploring':
        return const Color(0xFFC62828);
      case 'restaurant':
        return const Color(0xFFD32F2F);
      case 'shopping':
        return const Color(0xFF7B1FA2);
      case 'photography':
        return const Color(0xFF0277BD);
      case 'adventure':
        return const Color(0xFFFBC02D);
      default:
        return Colors.orange.shade700;
    }
  }

  double _hueFor(String kind, String category) {
    final k = kind.trim().toLowerCase();
    final c = category.trim().toLowerCase();

    if (k == 'accommodation') return gmaps.BitmapDescriptor.hueViolet;

    double hue;
    switch (c) {
      case 'driving':
        hue = gmaps.BitmapDescriptor.hueBlue;
        break;
      case 'hiking':
        hue = gmaps.BitmapDescriptor.hueGreen;
        break;
      case 'biking':
        hue = gmaps.BitmapDescriptor.hueAzure;
        break;
      case 'walking':
        hue = gmaps.BitmapDescriptor.hueCyan;
        break;
      case 'museum':
        hue = gmaps.BitmapDescriptor.hueMagenta;
        break;
      case 'sightseeing':
        hue = gmaps.BitmapDescriptor.hueOrange;
        break;
      case 'exploring':
        hue = gmaps.BitmapDescriptor.hueRed;
        break;
      case 'restaurant':
        hue = gmaps.BitmapDescriptor.hueRose;
        break;
      case 'shopping':
        // In the old non-GMaps renderer, Shopping was purple like Accommodation,
        // but on Google Maps all markers share the same pin shape. Use a nearby
        // hue so itinerary pins remain visually distinct from accommodations.
        hue = gmaps.BitmapDescriptor.hueMagenta;
        break;
      case 'photography':
        hue = gmaps.BitmapDescriptor.hueBlue;
        break;
      case 'adventure':
        hue = gmaps.BitmapDescriptor.hueYellow;
        break;
      default:
        hue = gmaps.BitmapDescriptor.hueOrange;
        break;
    }

    return hue;
  }

  @override
  void initState() {
    super.initState();
    _mainSig = _signature(widget.points);
    _secondarySig = _signature(widget.secondaryPoints);
    // _rebuild() uses inherited widgets (e.g. View.of / Theme.of). Defer until
    // after the first frame so initState can complete.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _rebuild();
    });
  }

  @override
  void dispose() {
    _previewUpdateTimer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _MapEmbedWebStateful oldWidget) {
    super.didUpdateWidget(oldWidget);

    final newMain = _signature(widget.points);
    final newSecondary = _signature(widget.secondaryPoints);
    final newVia = _viaSignature(widget.routeVia);
    final oldVia = _viaSignature(oldWidget.routeVia);
    final newSeg = _segmentRoutingSignature(widget.segmentRoutingTypes);
    final oldSeg = _segmentRoutingSignature(oldWidget.segmentRoutingTypes);

    if (newMain != _mainSig ||
        newSecondary != _secondarySig ||
        widget.transportMode.trim().toLowerCase() !=
            oldWidget.transportMode.trim().toLowerCase() ||
        newVia != oldVia ||
        newSeg != oldSeg) {
      _mainSig = newMain;
      _secondarySig = newSecondary;
      _controller = null;
      _controllerKeySig = null;
      _rebuild();
    }
  }

  String _viaSignature(List<Map<String, dynamic>> via) {
    if (via.isEmpty) return '';
    final b = StringBuffer();
    for (final v in via) {
      final after = (v['afterIndex'] as num?)?.toInt() ?? -1;
      final lat = (v['lat'] as num?)?.toDouble() ?? 0.0;
      final lon = (v['lon'] as num?)?.toDouble() ?? 0.0;
      b
        ..write(after)
        ..write(':')
        ..write(lat.toStringAsFixed(6))
        ..write(',')
        ..write(lon.toStringAsFixed(6))
        ..write(';');
    }
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
      byAfter.putIfAbsent(after, () => []).add({
        'lat': (v['lat'] as num?)?.toDouble() ?? 0.0,
        'lon': (v['lon'] as num?)?.toDouble() ?? 0.0,
        'name': 'Via',
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
        'name': 'Via',
      });
    }
    out.add(pts[afterIndex + 1]);
    return out;
  }

  double _distPointToSegmentSq(gmaps.LatLng p, gmaps.LatLng a, gmaps.LatLng b) {
    // Equirectangular projection for short distances.
    final lat0 = (a.latitude + b.latitude) / 2.0;
    final cosLat = math.cos(lat0 * (math.pi / 180.0));

    final px = p.longitude * cosLat;
    final py = p.latitude;
    final ax = a.longitude * cosLat;
    final ay = a.latitude;
    final bx = b.longitude * cosLat;
    final by = b.latitude;

    final abx = bx - ax;
    final aby = by - ay;
    final apx = px - ax;
    final apy = py - ay;

    final abLen2 = abx * abx + aby * aby;
    if (abLen2 <= 1e-12) {
      final dx = px - ax;
      final dy = py - ay;
      return dx * dx + dy * dy;
    }

    var t = (apx * abx + apy * aby) / abLen2;
    if (t < 0) t = 0;
    if (t > 1) t = 1;

    final cx = ax + abx * t;
    final cy = ay + aby * t;
    final dx = px - cx;
    final dy = py - cy;
    return dx * dx + dy * dy;
  }

  int _nearestSegmentAfterIndex(gmaps.LatLng tap) {
    final pts = widget.points;
    if (pts.length < 2) return 0;

    var best = double.infinity;
    var bestAfter = 0;
    for (var i = 0; i < pts.length - 1; i++) {
      final a = gmaps.LatLng(_latOf(pts[i]), _lonOf(pts[i]));
      final b = gmaps.LatLng(_latOf(pts[i + 1]), _lonOf(pts[i + 1]));
      final d = _distPointToSegmentSq(tap, a, b);
      if (d < best) {
        best = d;
        bestAfter = i;
      }
    }
    return bestAfter;
  }

  String _signature(List<Map<String, dynamic>> pts) {
    if (pts.isEmpty) return '';
    final b = StringBuffer();
    for (final p in pts) {
      final lat = _latOf(p).toStringAsFixed(6);
      final lon = _lonOf(p).toStringAsFixed(6);
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

  double _toDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0.0;
    return 0.0;
  }

  double _latOf(Map<String, dynamic> p) {
    return _toDouble(
      p['lat'] ?? p['latitude'] ?? p['locationLat'] ?? p['LocationLat'],
    );
  }

  double _lonOf(Map<String, dynamic> p) {
    return _toDouble(
      p['lon'] ??
          p['lng'] ??
          p['longitude'] ??
          p['locationLon'] ??
          p['LocationLon'],
    );
  }

  Future<void> _rebuild() async {
    final seq = ++_rebuildSeq;
    final main = widget.points;
    final secondary = widget.secondaryPoints;

    final dpr = View.of(context).devicePixelRatio;
    final mainBadgeColor = Theme.of(context).colorScheme.primary;

    final markers = <gmaps.Marker>{};

    final viaIconFuture = _markerIconCache.viaDot(dpr: dpr);

    Future<gmaps.BitmapDescriptor> buildMainIcon(int index) async {
      try {
        return await _markerIconCache.numbered(
          number: index + 1,
          color: mainBadgeColor,
          dpr: dpr,
        );
      } catch (_) {
        return gmaps.BitmapDescriptor.defaultMarkerWithHue(
          gmaps.BitmapDescriptor.hueAzure,
        );
      }
    }

    Future<gmaps.BitmapDescriptor> buildSecondaryIcon(
      String kind,
      String category,
    ) async {
      try {
        return await _markerIconCache.iconBadge(
          icon: _iconFor(kind, category),
          color: _colorFor(kind, category),
          dpr: dpr,
        );
      } catch (_) {
        return gmaps.BitmapDescriptor.defaultMarkerWithHue(
          _hueFor(kind, category),
        );
      }
    }

    final mainIconFutures = <Future<gmaps.BitmapDescriptor>>[];
    for (var i = 0; i < main.length; i++) {
      mainIconFutures.add(buildMainIcon(i));
    }

    final secondaryIconFutures = <Future<gmaps.BitmapDescriptor>>[];
    for (var i = 0; i < secondary.length; i++) {
      final p = secondary[i];
      final kind = (p['kind'] ?? '').toString();
      final category = (p['category'] ?? '').toString();
      secondaryIconFutures.add(buildSecondaryIcon(kind, category));
    }

    final mainIcons = await Future.wait(mainIconFutures);
    if (!mounted || seq != _rebuildSeq) return;
    final secondaryIcons = await Future.wait(secondaryIconFutures);
    if (!mounted || seq != _rebuildSeq) return;
    final viaIcon = await viaIconFuture;
    if (!mounted || seq != _rebuildSeq) return;

    for (var i = 0; i < main.length; i++) {
      final p = main[i];
      final lat = _latOf(p);
      final lon = _lonOf(p);
      final kind = (p['kind'] ?? '').toString();
      final category = (p['category'] ?? '').toString();
      markers.add(
        gmaps.Marker(
          markerId: gmaps.MarkerId('${_instanceId}_main_$i'),
          position: gmaps.LatLng(lat, lon),
          infoWindow: gmaps.InfoWindow(
            title: 'Stop ${i + 1}',
            snippet:
                category.isNotEmpty
                    ? category
                    : (kind.isNotEmpty ? kind : null),
          ),
          icon: mainIcons[i],
          anchor: const Offset(0.5, 0.5),
          onTap: () {
            _suppressMapTapUntilMs =
                DateTime.now().millisecondsSinceEpoch + 300;
            _showPreviewForPoint(p);
            widget.onPointTap?.call(p);
          },
        ),
      );
    }

    for (var i = 0; i < secondary.length; i++) {
      final p = secondary[i];
      final lat = _latOf(p);
      final lon = _lonOf(p);
      final kind = (p['kind'] ?? '').toString();
      final category = (p['category'] ?? '').toString();
      final name = (p['name'] ?? '').toString();
      markers.add(
        gmaps.Marker(
          markerId: gmaps.MarkerId('${_instanceId}_secondary_$i'),
          position: gmaps.LatLng(lat, lon),
          icon: secondaryIcons[i],
          anchor: const Offset(0.5, 0.5),
          infoWindow: gmaps.InfoWindow(
            title:
                name.isNotEmpty
                    ? name
                    : (category.isNotEmpty ? category : 'Point'),
            snippet:
                category.isNotEmpty
                    ? category
                    : (kind.isNotEmpty ? kind : null),
          ),
          onTap: () {
            _suppressMapTapUntilMs =
                DateTime.now().millisecondsSinceEpoch + 300;
            _showPreviewForPoint(p);
            widget.onPointTap?.call(p);
          },
        ),
      );
    }

    // Route shaping via markers (optional)
    for (var i = 0; i < widget.routeVia.length; i++) {
      final v = widget.routeVia[i];
      final lat = (v['lat'] as num?)?.toDouble();
      final lon = (v['lon'] as num?)?.toDouble();
      if (lat == null || lon == null) continue;
      markers.add(
        gmaps.Marker(
          markerId: gmaps.MarkerId('${_instanceId}_via_$i'),
          position: gmaps.LatLng(lat, lon),
          draggable: widget.onViaDragEnd != null,
          icon: viaIcon,
          alpha: 0.7,
          anchor: const Offset(0.5, 0.5),
          onDragEnd: (p) {
            _suppressMapTapUntilMs =
                DateTime.now().millisecondsSinceEpoch + 300;
            widget.onViaDragEnd?.call(i, p.latitude, p.longitude);
          },
          onTap: () {
            _suppressMapTapUntilMs =
                DateTime.now().millisecondsSinceEpoch + 300;
            widget.onViaTapDelete?.call(i);
            _hidePreview();
          },
        ),
      );
    }

    if (!mounted || seq != _rebuildSeq) return;
    setState(() {
      _markers = markers;
      _polylines = const {};
    });

    // Route + camera updates are async; ensure stale rebuilds don't win.
    await _updateRoutePolyline(seq: seq);
    if (!mounted || seq != _rebuildSeq) return;
    await _fitCamera();
  }

  Future<void> _updateRoutePolyline({required int seq}) async {
    final basePts = widget.points;
    if (basePts.length < 2) {
      if (!mounted || seq != _rebuildSeq) return;
      setState(() => _polylines = const {});
      return;
    }

    final mode = widget.transportMode.trim().toLowerCase();
    final standardColor = _standardRouteColor(mode);

    final outPolylines = <gmaps.Polyline>{};
    var distSum = 0.0;
    var durSum = 0.0;
    final instr = <String>[];

    Map<String, dynamic>? lastArrivalStop;

    for (var seg = 0; seg < basePts.length - 1; seg++) {
      if (!mounted || seq != _rebuildSeq) return;

      final segType = _segmentRoutingTypeFor(seg);
      final segPoints = _segmentPoints(afterIndex: seg);
      if (segPoints.length < 2) continue;

      final segLatLngs =
          segPoints.map((p) => gmaps.LatLng(_latOf(p), _lonOf(p))).toList();

      if (mode == 'flying') {
        var segDist = 0.0;
        for (var i = 0; i + 1 < segLatLngs.length; i++) {
          segDist += _haversineMeters(segLatLngs[i], segLatLngs[i + 1]);
        }
        distSum += segDist;
        outPolylines.add(
          gmaps.Polyline(
            polylineId: gmaps.PolylineId('${_instanceId}_seg_${seg}_flight'),
            points: segLatLngs,
            width: 4,
            color: Colors.indigo.shade400,
            patterns: [gmaps.PatternItem.dash(12), gmaps.PatternItem.gap(10)],
            geodesic: true,
          ),
        );
        continue;
      }

      if (segType == 'direct') {
        final isAdventure = _isAdventureMode(mode);
        var segDist = 0.0;
        for (var i = 0; i + 1 < segLatLngs.length; i++) {
          segDist += _haversineMeters(segLatLngs[i], segLatLngs[i + 1]);
        }
        distSum += segDist;
        outPolylines.add(
          gmaps.Polyline(
            polylineId: gmaps.PolylineId('${_instanceId}_seg_${seg}_direct'),
            points: segLatLngs,
            width: isAdventure ? 8 : 4,
            color: isAdventure ? const Color(0xFF00E676) : Colors.green,
            patterns: [gmaps.PatternItem.dash(18), gmaps.PatternItem.gap(10)],
            geodesic: true,
          ),
        );
        continue;
      }

      final isTransit = mode == 'transit';
      final isAdventure = _isAdventureMode(mode);

      // Prefer Google Directions ONLY for standard modes.
      // Adventure modes (bikepacking/backpacking) should fall through to OSRM
      // so we can pick up OSM trails/paths rather than road-snapping.
      final useGoogle =
          !kIsWeb &&
          (isTransit || mode == 'biking' || mode == 'walking') &&
          !isAdventure;

      if (useGoogle) {
        final googleMode =
            isTransit
                ? 'transit'
                : (mode == 'walking')
                ? 'walking'
                : 'bicycling';

        try {
          final origin =
              '${_latOf(segPoints.first)},${_lonOf(segPoints.first)}';
          final dest = '${_latOf(segPoints.last)},${_lonOf(segPoints.last)}';
          final intermediates =
              segPoints.length > 2
                  ? segPoints.sublist(1, segPoints.length - 1)
                  : const <Map<String, dynamic>>[];
          final waypoints =
              intermediates.isNotEmpty
                  ? intermediates
                      .map((p) => '${_latOf(p)},${_lonOf(p)}')
                      .join('|')
                  : '';

          final params = <String, String>{
            'origin': origin,
            'destination': dest,
            'mode': googleMode,
            'key': widget.mapsKey,
          };

          if (waypoints.isNotEmpty) {
            params['waypoints'] = waypoints;
          }

          if (isAdventure && googleMode == 'bicycling') {
            params['avoid'] = 'highways|ferries';
          }

          if (googleMode == 'transit') {
            params['transit_routing_preference'] = 'fewer_transfers';
            params['departure_time'] =
                (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
          }

          final url = Uri.https(
            'maps.googleapis.com',
            '/maps/api/directions/json',
            params,
          );

          final resp = await http.get(url);
          if (resp.statusCode == 200) {
            final data = jsonDecode(resp.body) as Map<String, dynamic>;
            final routes = data['routes'] as List<dynamic>?;
            if (routes != null && routes.isNotEmpty) {
              final r0 = routes.first as Map<String, dynamic>;
              final overview = r0['overview_polyline'] as Map<String, dynamic>?;
              final encoded = (overview?['points'] as String?) ?? '';
              if (encoded.isNotEmpty) {
                final path = _decodeGooglePolyline(encoded);

                var segDist = 0.0;
                var segDur = 0.0;
                Color? segTransitColor;

                final legs = (r0['legs'] as List<dynamic>?) ?? const [];
                for (final l in legs) {
                  final leg = (l as Map).cast<String, dynamic>();
                  final d = (leg['distance'] as Map?)?['value'] as num?;
                  final t = (leg['duration'] as Map?)?['value'] as num?;
                  if (d != null) segDist += d.toDouble();
                  if (t != null) segDur += t.toDouble();

                  final steps = (leg['steps'] as List<dynamic>?) ?? const [];
                  for (final s in steps) {
                    final step = (s as Map).cast<String, dynamic>();
                    if (googleMode == 'transit') {
                      final travelMode =
                          (step['travel_mode'] ?? '').toString().toUpperCase();
                      if (travelMode != 'TRANSIT') continue;

                      final td =
                          (step['transit_details'] as Map?)
                              ?.cast<String, dynamic>();
                      final line =
                          (td?['line'] as Map?)?.cast<String, dynamic>();
                      final short = (line?['short_name'] ?? '').toString();
                      final name = (line?['name'] ?? '').toString();
                      final colorHex = (line?['color'] ?? '').toString();
                      segTransitColor ??= _parseHexColor(colorHex);

                      final depStop =
                          (td?['departure_stop'] as Map?)
                              ?.cast<String, dynamic>();
                      final arrStop =
                          (td?['arrival_stop'] as Map?)
                              ?.cast<String, dynamic>();
                      final depName = (depStop?['name'] ?? '').toString();
                      final arrName = (arrStop?['name'] ?? '').toString();

                      final arrLoc =
                          (arrStop?['location'] as Map?)
                              ?.cast<String, dynamic>();
                      final arrLat = (arrLoc?['lat'] as num?)?.toDouble();
                      final arrLng = (arrLoc?['lng'] as num?)?.toDouble();
                      if (arrLat != null && arrLng != null) {
                        lastArrivalStop = {
                          'name': arrName,
                          'lat': arrLat,
                          'lon': arrLng,
                        };
                      }

                      final vehicle =
                          (line?['vehicle'] as Map?)?.cast<String, dynamic>();
                      final vehicleName = (vehicle?['name'] ?? '').toString();
                      final headsign = (td?['headsign'] ?? '').toString();

                      final label = [
                        if (vehicleName.isNotEmpty) vehicleName,
                        if (short.isNotEmpty)
                          short
                        else if (name.isNotEmpty)
                          name,
                      ].join(' ');

                      final stopPart =
                          (depName.isNotEmpty && arrName.isNotEmpty)
                              ? '$depName → $arrName'
                              : '';
                      final headPart = headsign.isNotEmpty ? '→ $headsign' : '';
                      final full = [
                        label,
                        stopPart,
                        headPart,
                      ].where((s) => s.trim().isNotEmpty).join(' — ');
                      if (full.isNotEmpty) instr.add(full);
                    } else {
                      final htmlInstr =
                          (step['html_instructions'] ?? '').toString();
                      final clean = _stripHtml(htmlInstr);
                      if (clean.isEmpty) continue;
                      final distText =
                          ((step['distance'] as Map?)?['text'] ?? '')
                              .toString();
                      instr.add(
                        distText.isNotEmpty ? '$clean ($distText)' : clean,
                      );
                    }
                  }
                }

                distSum += segDist;
                durSum += segDur;

                final color =
                    (googleMode == 'transit')
                        ? (segTransitColor ?? standardColor)
                        : standardColor;

                outPolylines.add(
                  gmaps.Polyline(
                    polylineId: gmaps.PolylineId('${_instanceId}_seg_$seg'),
                    points: path,
                    width: 4,
                    color: color,
                  ),
                );
                continue;
              }
            }
          }
        } catch (_) {
          // fall through to OSRM/fallback
        }
      }

      // OSRM-style routing fallback for non-google mode (PRIMARY for adventure modes).
      // For trail-first profiles, prefer routing.openstreetmap.de (routed-foot / routed-bike)
      // and fall back to the public OSRM demo server if needed.
      try {
        final coords = segPoints
            .map((p) => '${_lonOf(p)},${_latOf(p)}')
            .join(';');
        final candidates = <Uri>[];

        if (mode == 'walking' || mode == 'hiking' || mode == 'backpacking') {
          candidates.add(
            Uri.parse(
              'https://routing.openstreetmap.de/routed-foot/route/v1/driving/$coords?overview=full&geometries=geojson',
            ),
          );
        } else if (mode == 'biking' || mode == 'bikepacking') {
          candidates.add(
            Uri.parse(
              'https://routing.openstreetmap.de/routed-bike/route/v1/driving/$coords?overview=full&geometries=geojson',
            ),
          );
        }

        // Secondary fallback to the OSRM demo server.
        final demoProfile = switch (mode) {
          'walking' => 'walking',
          'backpacking' => 'walking',
          'hiking' => 'walking',
          'biking' => 'cycling',
          'bikepacking' => 'cycling',
          _ => 'driving',
        };
        candidates.add(
          Uri.parse(
            'https://router.project-osrm.org/route/v1/$demoProfile/$coords?overview=full&geometries=geojson',
          ),
        );

        bool routed = false;
        for (final url in candidates) {
          final resp = await http.get(url);
          if (resp.statusCode != 200) continue;

          final data = jsonDecode(resp.body) as Map<String, dynamic>;
          final routes = data['routes'] as List<dynamic>?;
          if (routes == null || routes.isEmpty) continue;

          final route0 = routes.first as Map<String, dynamic>;
          final dist = (route0['distance'] as num?)?.toDouble();
          final dur = (route0['duration'] as num?)?.toDouble();
          final geom = route0['geometry'] as Map<String, dynamic>?;
          final coordsList =
              (geom?['coordinates'] as List<dynamic>?)?.cast<List<dynamic>>();
          if (coordsList == null || coordsList.isEmpty) continue;

          final path =
              coordsList
                  .map(
                    (c) => gmaps.LatLng(
                      (c[1] as num).toDouble(),
                      (c[0] as num).toDouble(),
                    ),
                  )
                  .toList();

          outPolylines.add(
            gmaps.Polyline(
              polylineId: gmaps.PolylineId('${_instanceId}_seg_$seg'),
              points: path,
              width: isAdventure ? 8 : 5,
              color: isAdventure ? const Color(0xFF00E676) : standardColor,
              zIndex: isAdventure ? 10 : 0,
            ),
          );
          if (dist != null) distSum += dist;
          if (dur != null) durSum += dur;
          routed = true;
          break;
        }

        if (routed) continue;
      } catch (_) {
        // fall through
      }

      // Final segment fallback.
      outPolylines.add(
        gmaps.Polyline(
          polylineId: gmaps.PolylineId('${_instanceId}_seg_${seg}_fallback'),
          points: segLatLngs,
          width: 3,
          color: standardColor.withOpacity(0.6),
          geodesic: true,
        ),
      );
    }

    _lastInstructions = instr.take(6).toList(growable: false);
    widget.onRouteInstructions?.call(_lastInstructions);
    if (lastArrivalStop != null) {
      widget.onTransitArrivalStop?.call(lastArrivalStop);
    }

    if (!mounted || seq != _rebuildSeq) return;
    setState(() {
      _polylines = outPolylines;
    });

    if (distSum > 0 && durSum > 0) {
      widget.onRouteSummary?.call(distSum, durSum);
    }
  }

  void _hidePreview() {
    if (_previewPoint == null) return;
    setState(() {
      _previewPoint = null;
      _previewLatLng = null;
      _previewOffset = null;
    });
  }

  void _showPreviewForPoint(Map<String, dynamic> point) {
    final lat = _latOf(point);
    final lon = _lonOf(point);
    if (lat == 0.0 && lon == 0.0) return;
    _previewPoint = point;
    _previewLatLng = gmaps.LatLng(lat, lon);
    _schedulePreviewUpdate();
    setState(() {});
  }

  void _schedulePreviewUpdate() {
    if (_previewLatLng == null) return;
    _previewUpdateTimer?.cancel();
    _previewUpdateTimer = Timer(const Duration(milliseconds: 50), () {
      _updatePreviewPosition();
    });
  }

  Future<void> _updatePreviewPosition() async {
    final c = _controller;
    final target = _previewLatLng;
    if (c == null || target == null || _mapSize == Size.zero) return;

    try {
      final sc = await c.getScreenCoordinate(target);
      if (!mounted) return;
      final cardWidth = _previewBubbleWidth;
      final cardHeight = _previewBubbleHeight;
      final triangleHeight = _previewTriangleHeight;

      var left = sc.x.toDouble() - (cardWidth / 2);
      var top = sc.y.toDouble() - cardHeight - triangleHeight;

      left = left.clamp(12.0, _mapSize.width - cardWidth - 12.0);
      top = top.clamp(
        12.0,
        _mapSize.height - cardHeight - triangleHeight - 12.0,
      );

      setState(() {
        _previewOffset = Offset(left, top);
      });
    } catch (_) {}
  }

  String _previewTitle(Map<String, dynamic> point) {
    return (point['name'] ?? point['title'] ?? 'Location').toString();
  }

  String _previewRegion(Map<String, dynamic> point) {
    return (point['region'] ?? point['country'] ?? point['subtitle'] ?? '')
        .toString()
        .trim();
  }

  Widget _buildPreviewOverlay() {
    final point = _previewPoint;
    final pos = _previewOffset;
    final latLng = _previewLatLng;
    if (point == null || pos == null || latLng == null) {
      return const SizedBox.shrink();
    }

    final title = _previewTitle(point);
    final region = _previewRegion(point);

    return Positioned(
      left: pos.dx,
      top: pos.dy,
      child: MapPreview3D(
        lat: latLng.latitude,
        lon: latLng.longitude,
        title: title,
        region: region,
      ),
    );
  }

  gmaps.LatLngBounds? _boundsFromMarkers() {
    if (_markers.isEmpty) return null;
    double? minLat, maxLat, minLon, maxLon;
    for (final m in _markers) {
      final lat = m.position.latitude;
      final lon = m.position.longitude;
      minLat = (minLat == null) ? lat : (lat < minLat ? lat : minLat);
      maxLat = (maxLat == null) ? lat : (lat > maxLat ? lat : maxLat);
      minLon = (minLon == null) ? lon : (lon < minLon ? lon : minLon);
      maxLon = (maxLon == null) ? lon : (lon > maxLon ? lon : maxLon);
    }
    return gmaps.LatLngBounds(
      southwest: gmaps.LatLng(minLat!, minLon!),
      northeast: gmaps.LatLng(maxLat!, maxLon!),
    );
  }

  Future<void> _fitCamera() async {
    final c = _controller;
    if (c == null) return;

    if (_controllerKeySig != _mapKeySig()) return;

    final bounds = _boundsFromMarkers();
    if (bounds == null) return;

    if (_markers.length == 1) {
      final only = _markers.first.position;
      await c.moveCamera(gmaps.CameraUpdate.newLatLngZoom(only, 12));
      return;
    }

    await c.moveCamera(gmaps.CameraUpdate.newLatLngBounds(bounds, 48));
  }

  @override
  Widget build(BuildContext context) {
    if (widget.points.isEmpty && widget.secondaryPoints.isEmpty) {
      return const Center(child: Text('No points yet'));
    }

    final initialTarget =
        _markers.isNotEmpty
            ? _markers.first.position
            : const gmaps.LatLng(0, 0);

    final mode = widget.transportMode.trim().toLowerCase();
    final mapType =
        (mode == 'biking' || mode == 'walking' || _isAdventureMode(mode))
            ? gmaps.MapType.terrain
            : gmaps.MapType.normal;

    return LayoutBuilder(
      builder: (ctx, constraints) {
        _mapSize = Size(constraints.maxWidth, constraints.maxHeight);
        return Stack(
          children: [
            gmaps.GoogleMap(
              // google_maps_flutter on web can occasionally fail to visually update
              // markers/polylines even when the widget rebuilds. Keying the map by the
              // computed signatures forces a full re-init when route points change.
              key: ValueKey(_mapKeySig()),
              initialCameraPosition: gmaps.CameraPosition(
                target: initialTarget,
                zoom: 2,
              ),
              mapType: mapType,
              minMaxZoomPreference: gmaps.MinMaxZoomPreference(
                widget.minZoom,
                widget.maxZoom,
              ),
              onMapCreated: (c) {
                _controller = c;
                _controllerKeySig = _mapKeySig();
                _fitCamera();
                _schedulePreviewUpdate();
              },
              markers: _markers,
              polylines: _polylines,
              onCameraMove: (_) => _schedulePreviewUpdate(),
              onTap: (p) {
                _hidePreview();
                if (widget.disableGestures) return;
                if (DateTime.now().millisecondsSinceEpoch <
                    _suppressMapTapUntilMs) {
                  return;
                }
                if (widget.onRouteTapAddVia != null &&
                    widget.points.length >= 2) {
                  final after = _nearestSegmentAfterIndex(p);
                  widget.onRouteTapAddVia?.call(after, p.latitude, p.longitude);
                  return;
                }
                widget.onMapTap?.call(p.latitude, p.longitude);
              },
              zoomControlsEnabled:
                  widget.zoomControlsEnabled && !widget.disableDefaultUi,
              zoomGesturesEnabled: !widget.disableGestures,
              scrollGesturesEnabled: !widget.disableGestures,
              mapToolbarEnabled: false,
              myLocationButtonEnabled: false,
              rotateGesturesEnabled: false,
              tiltGesturesEnabled: false,
              compassEnabled: false,
            ),
            _buildPreviewOverlay(),
          ],
        );
      },
    );
  }
}

class MapPreview3D extends StatefulWidget {
  final double lat;
  final double lon;
  final String title;
  final String region;

  const MapPreview3D({
    super.key,
    required this.lat,
    required this.lon,
    this.title = '',
    this.region = '',
  });

  @override
  State<MapPreview3D> createState() => _MapPreview3DState();
}

class _MapPreview3DState extends State<MapPreview3D> {
  late final String _viewType;
  late final html.Element _element;
  late final html.DivElement _titleElement;
  late final html.DivElement _regionElement;

  static bool _styleInjected = false;

  static const String _earthMapId = 'DEMO_MAP_ID';

  static const double _mapWidthPx = _previewBubbleWidth;
  static const double _mapHeightPx = _previewMapHeight;

  @override
  void initState() {
    super.initState();
    _viewType = 'trypr-map3d-${identityHashCode(this)}';

    _ensureBubbleStyles();

    final container = html.DivElement();
    container.className = 'trypr-map3d-bubble';
    container.style.width = '${_previewBubbleWidth}px';
    container.style.height =
        '${_previewBubbleHeight + _previewTriangleHeight}px';
    container.style.pointerEvents = 'none';
    container.style.zIndex = '50';

    final mapWrap = html.DivElement();
    mapWrap.className = 'trypr-map3d-view';
    mapWrap.style.width = '100%';
    mapWrap.style.height = '${_mapHeightPx}px';

    final map3d = html.Element.tag('gmp-map-3d');
    map3d.style.width = '100%';
    map3d.style.height = '100%';
    map3d.style.border = '0';
    map3d.style.pointerEvents = 'none';

    _applyMap3dAttributes(map3d);

    mapWrap.append(map3d);

    final info = html.DivElement();
    info.className = 'trypr-map3d-info';

    _titleElement = html.DivElement();
    _titleElement.className = 'trypr-map3d-title';
    _titleElement.text = widget.title;

    _regionElement = html.DivElement();
    _regionElement.className = 'trypr-map3d-region';
    _regionElement.text = widget.region;
    _regionElement.style.display =
        widget.region.trim().isEmpty ? 'none' : 'block';

    info
      ..append(_titleElement)
      ..append(_regionElement);

    container
      ..append(mapWrap)
      ..append(info);

    _element = container;

    ui_web.platformViewRegistry.registerViewFactory(
      _viewType,
      (int viewId) => _element,
    );

    ensureGoogleMapsLoaded();
  }

  String _resolveMapId() {
    const fromDefine = String.fromEnvironment('GOOGLE_MAPS_MAP_ID');
    if (fromDefine.isNotEmpty) return fromDefine;

    try {
      final meta = html.document.querySelector(
        'meta[name="google-maps-map-id"]',
      );
      final fromMeta = meta?.getAttribute('content')?.trim() ?? '';
      return fromMeta;
    } catch (_) {
      return '';
    }
  }

  void _applyMap3dAttributes(html.Element map3d) {
    map3d.setAttribute('center', '${widget.lat},${widget.lon},0');
    map3d.setAttribute('tilt', '60');
    map3d.setAttribute('heading', '45');
    map3d.setAttribute('range', '1000');
    map3d.setAttribute('default-labels-disabled', 'true');
    final mapId = _resolveMapId();
    final resolved = mapId.isNotEmpty ? mapId : _earthMapId;
    // NOTE: Replace DEMO_MAP_ID with a real Map ID configured for Vector
    // rendering in Google Cloud Console. Map3D requires a Vector map ID.
    map3d.setAttribute('map-id', resolved);
  }

  void _ensureBubbleStyles() {
    if (_styleInjected) return;
    _styleInjected = true;

    final style = html.StyleElement();
    style.text = '''
.trypr-map3d-bubble {
  position: relative;
  background: #ffffff;
  border-radius: 12px;
  box-shadow: 0 10px 30px rgba(0, 0, 0, 0.3);
}
.trypr-map3d-bubble::after {
  content: '';
  position: absolute;
  bottom: -10px;
  left: 50%;
  transform: translateX(-50%);
  border-width: 10px 10px 0 10px;
  border-style: solid;
  border-color: #ffffff transparent transparent transparent;
}
.trypr-map3d-view {
  width: ${_previewBubbleWidth}px;
  height: ${_previewMapHeight}px;
  overflow: hidden;
  border-radius: 12px 12px 8px 8px;
  background: #f2f2f2;
}
.trypr-map3d-view > gmp-map-3d {
  width: ${_previewBubbleWidth}px;
  height: ${_previewMapHeight}px;
  display: block;
}
.trypr-map3d-info {
  padding: 10px 12px 12px;
  font-family: inherit;
}
.trypr-map3d-title {
  font-weight: 700;
  font-size: 14px;
  color: #111111;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.trypr-map3d-region {
  font-size: 12px;
  color: #555555;
  margin-top: 4px;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
''';
    html.document.head?.append(style);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _previewBubbleWidth,
      height: _previewBubbleHeight + _previewTriangleHeight,
      child: HtmlElementView(viewType: _viewType),
    );
  }

  @override
  void didUpdateWidget(covariant MapPreview3D oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lat != widget.lat || oldWidget.lon != widget.lon) {
      final map3d = _element.querySelector('gmp-map-3d');
      if (map3d != null) {
        _applyMap3dAttributes(map3d);
      }
    }
    if (oldWidget.title != widget.title) {
      _titleElement.text = widget.title;
    }
    if (oldWidget.region != widget.region) {
      _regionElement.text = widget.region;
      _regionElement.style.display =
          widget.region.trim().isEmpty ? 'none' : 'block';
    }
  }
}

class _MarkerIconCache {
  final Map<String, Future<gmaps.BitmapDescriptor>> _cache = {};

  Future<gmaps.BitmapDescriptor> viaDot({required double dpr}) {
    return _cache.putIfAbsent(
      'viaDot:${Colors.green.value}:$dpr',
      () => _buildCircleBadge(
        dpr: dpr,
        logicalSize: 18.0,
        background: const Color(0xFF2E7D32),
        foreground: Colors.white,
        icon: null,
        text: null,
        borderWidthLogical: 2.0,
      ),
    );
  }

  Future<gmaps.BitmapDescriptor> numbered({
    required int number,
    required Color color,
    required double dpr,
  }) {
    return _cache.putIfAbsent(
      'num:$number:${color.value}:$dpr',
      () => _buildCircleBadge(
        dpr: dpr,
        background: color,
        foreground: Colors.white,
        icon: null,
        text: number.toString(),
      ),
    );
  }

  Future<gmaps.BitmapDescriptor> iconBadge({
    required IconData icon,
    required Color color,
    required double dpr,
  }) {
    return _cache.putIfAbsent(
      'ic:${icon.codePoint}:${icon.fontFamily}:${icon.fontPackage}:${color.value}:$dpr',
      () => _buildCircleBadge(
        dpr: dpr,
        background: color,
        foreground: Colors.white,
        icon: icon,
        text: null,
      ),
    );
  }

  Future<gmaps.BitmapDescriptor> _buildCircleBadge({
    required double dpr,
    double logicalSize = 40.0,
    required Color background,
    required Color foreground,
    required IconData? icon,
    required String? text,
    double borderWidthLogical = 2.0,
  }) async {
    final pixelSize = (logicalSize * dpr).round();

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final size = ui.Size(pixelSize.toDouble(), pixelSize.toDouble());
    final center = ui.Offset(size.width / 2, size.height / 2);

    // Background circle + subtle border.
    final bgPaint = ui.Paint()..color = background;
    final borderPaint =
        ui.Paint()
          ..color = Colors.white.withOpacity(0.85)
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = (borderWidthLogical * dpr).clamp(2.0, 6.0);

    canvas.drawCircle(center, (size.width / 2) - (1.0 * dpr), bgPaint);
    canvas.drawCircle(center, (size.width / 2) - (1.0 * dpr), borderPaint);

    if (icon != null) {
      final iconPainter = TextPainter(
        textDirection: TextDirection.ltr,
        text: TextSpan(
          text: String.fromCharCode(icon.codePoint),
          style: TextStyle(
            fontSize: (22.0 * dpr).clamp(18.0, 34.0),
            fontFamily: icon.fontFamily,
            package: icon.fontPackage,
            color: foreground,
          ),
        ),
      )..layout();
      final offset = ui.Offset(
        center.dx - iconPainter.width / 2,
        center.dy - iconPainter.height / 2,
      );
      iconPainter.paint(canvas, offset);
    } else if (text != null && text.isNotEmpty) {
      final textPainter = TextPainter(
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
        text: TextSpan(
          text: text,
          style: TextStyle(
            fontSize: (18.0 * dpr).clamp(16.0, 28.0),
            fontWeight: FontWeight.w800,
            color: foreground,
          ),
        ),
      )..layout();
      final offset = ui.Offset(
        center.dx - textPainter.width / 2,
        center.dy - textPainter.height / 2,
      );
      textPainter.paint(canvas, offset);
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(pixelSize, pixelSize);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) {
      return gmaps.BitmapDescriptor.defaultMarker;
    }
    final bytes = data.buffer.asUint8List();
    return gmaps.BitmapDescriptor.fromBytes(
      bytes,
      size: ui.Size(logicalSize, logicalSize),
    );
  }
}
