import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'dart:ui' as ui;

import 'dart:html' as html;

import 'dart:convert';

import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import 'package:http/http.dart' as http;

class MapEmbed extends StatelessWidget {
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
      onRouteSummary: onRouteSummary,
    );
  }
}

class _MapEmbedWebStateful extends StatefulWidget {
  final List<Map<String, dynamic>> points;
  final List<Map<String, dynamic>> secondaryPoints;
  final void Function(double lat, double lon)? onMapTap;
  final void Function(double distanceMeters, double durationSeconds)?
  onRouteSummary;

  const _MapEmbedWebStateful({
    required this.points,
    required this.secondaryPoints,
    required this.onMapTap,
    required this.onRouteSummary,
  });

  @override
  State<_MapEmbedWebStateful> createState() => _MapEmbedWebStatefulState();
}

class _MapEmbedWebStatefulState extends State<_MapEmbedWebStateful> {
  gmaps.GoogleMapController? _controller;
  Set<gmaps.Marker> _markers = const {};
  Set<gmaps.Polyline> _polylines = const {};

  late final String _instanceId = identityHashCode(this).toRadixString(16);

  String _mainSig = '';
  String _secondarySig = '';
  int _rebuildSeq = 0;

  final _markerIconCache = _MarkerIconCache();

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
  void didUpdateWidget(covariant _MapEmbedWebStateful oldWidget) {
    super.didUpdateWidget(oldWidget);

    final newMain = _signature(widget.points);
    final newSecondary = _signature(widget.secondaryPoints);
    if (newMain != _mainSig || newSecondary != _secondarySig) {
      _mainSig = newMain;
      _secondarySig = newSecondary;
      _rebuild();
    }
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
    final pts = widget.points;
    if (pts.length < 2) {
      if (!mounted || seq != _rebuildSeq) return;
      setState(() => _polylines = const {});
      return;
    }

    try {
      final coords = pts.map((p) => '${_lonOf(p)},${_latOf(p)}').join(';');
      final url = Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/$coords?overview=full&geometries=geojson',
      );
      final resp = await http.get(url);
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
            final path =
                coordsList
                    .map(
                      (c) => gmaps.LatLng(
                        (c[1] as num).toDouble(),
                        (c[0] as num).toDouble(),
                      ),
                    )
                    .toList();

            if (!mounted || seq != _rebuildSeq) return;
            final primary = Theme.of(context).colorScheme.primary;
            setState(() {
              _polylines = {
                gmaps.Polyline(
                  polylineId: gmaps.PolylineId('${_instanceId}_route'),
                  points: path,
                  width: 4,
                  color: primary,
                ),
              };
            });

            if (dist != null && dur != null) {
              widget.onRouteSummary?.call(dist, dur);
            }
            return;
          }
        }
      }
    } catch (_) {
      // fall back
    }

    final fallback =
        pts.map((p) => gmaps.LatLng(_latOf(p), _lonOf(p))).toList();

    if (!mounted || seq != _rebuildSeq) return;
    setState(() {
      _polylines = {
        gmaps.Polyline(
          polylineId: gmaps.PolylineId('${_instanceId}_route_fallback'),
          points: fallback,
          width: 3,
          color: Theme.of(context).colorScheme.primary.withOpacity(0.6),
        ),
      };
    });
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

    return gmaps.GoogleMap(
      // google_maps_flutter on web can occasionally fail to visually update
      // markers/polylines even when the widget rebuilds. Keying the map by the
      // computed signatures forces a full re-init when route points change.
      key: ValueKey('${_instanceId}_${_mainSig}_$_secondarySig'),
      initialCameraPosition: gmaps.CameraPosition(
        target: initialTarget,
        zoom: 2,
      ),
      onMapCreated: (c) {
        _controller = c;
        _fitCamera();
      },
      markers: _markers,
      polylines: _polylines,
      onTap: (p) => widget.onMapTap?.call(p.latitude, p.longitude),
      mapToolbarEnabled: false,
      myLocationButtonEnabled: false,
      rotateGesturesEnabled: false,
      tiltGesturesEnabled: false,
      compassEnabled: false,
    );
  }
}

class _MarkerIconCache {
  final Map<String, Future<gmaps.BitmapDescriptor>> _cache = {};

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
    required Color background,
    required Color foreground,
    required IconData? icon,
    required String? text,
  }) async {
    final logicalSize = 40.0;
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
          ..strokeWidth = (2.0 * dpr).clamp(2.0, 4.0);

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
