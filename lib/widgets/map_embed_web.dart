import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;
import 'dart:ui_web' as ui_web;
import 'dart:math' as math;

import 'dart:html' as html;
// ignore: uri_does_not_exist
import 'dart:js_util' as js_util;

import 'dart:convert';

import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import 'package:http/http.dart' as http;

import 'package:trypr/services/directions_web.dart' as directions_web;
import 'package:trypr/services/google_maps_loader.dart' as maps_loader;

const double _previewBubbleWidth = 280.0;
const double _previewMapHeight = 160.0;
const double _previewInfoHeight = 64.0;
const double _previewTriangleHeight = 10.0;
const double _previewBubbleHeight = _previewMapHeight + _previewInfoHeight;

const Duration _overlayCacheTtl = Duration(minutes: 30);
const Duration _segmentRouteCacheTtl = Duration(minutes: 20);
const bool _strictRouting = bool.fromEnvironment(
  'STRICT_ROUTING',
  defaultValue: false,
);
const String _routingProxyUrlDefine = String.fromEnvironment(
  'ROUTING_PROXY_URL',
  defaultValue: '/api/route',
);
const String _overpassProxyUrlDefine = String.fromEnvironment(
  'OVERPASS_PROXY_URL',
  defaultValue: '/api/overpass',
);
const String _campsiteInfoMarkerIdDefine = String.fromEnvironment(
  'CAMPSITE_INFO_MARKER_ID',
  defaultValue: '',
);

const String _roadsOnlyStyleJson = '''
[
  {"featureType":"poi","stylers":[{"visibility":"off"}]},
  {"featureType":"transit","stylers":[{"visibility":"off"}]},
  {"featureType":"administrative","elementType":"labels","stylers":[{"visibility":"off"}]}
]
''';

const String _bikeLayerStyleJson = '''
[
  {"featureType":"poi","stylers":[{"visibility":"off"}]},
  {"featureType":"transit","stylers":[{"visibility":"off"}]},
  {"featureType":"road.highway","stylers":[{"saturation":-80}]},
  {"featureType":"road.arterial","stylers":[{"hue":"#2e7d32"},{"saturation":20}]}
]
''';

const String _walkLayerStyleJson = '''
[
  {"featureType":"poi","stylers":[{"visibility":"off"}]},
  {"featureType":"transit","stylers":[{"visibility":"off"}]},
  {"featureType":"road.highway","stylers":[{"visibility":"off"}]},
  {"featureType":"road.local","stylers":[{"hue":"#00897b"},{"saturation":10}]}
]
''';

const String _hikingLayerStyleJson = '''
[
  {"featureType":"poi","stylers":[{"visibility":"off"}]},
  {"featureType":"transit","stylers":[{"visibility":"off"}]},
  {"featureType":"road.highway","stylers":[{"saturation":-70},{"lightness":-15}]},
  {"featureType":"road.arterial","stylers":[{"saturation":-55},{"lightness":-10}]}
]
''';

const String _portagingLayerStyleJson = '''
[
  {"featureType":"poi","stylers":[{"visibility":"off"}]},
  {"featureType":"transit","stylers":[{"visibility":"off"}]},
  {"featureType":"road.highway","stylers":[{"saturation":-70},{"lightness":-15}]},
  {"featureType":"road.arterial","stylers":[{"saturation":-55},{"lightness":-10}]},
  {"featureType":"water","stylers":[{"saturation":30},{"lightness":-10}]}
]
''';

const String _planeLayerStyleJson = '''
[
  {"featureType":"road","stylers":[{"visibility":"off"}]},
  {"featureType":"poi","stylers":[{"visibility":"off"}]},
  {"featureType":"transit","stylers":[{"visibility":"off"}]}
]
''';

const Color _portagingCarryRouteColor = Color(0xFF8D6E63);

class _ModeOverlays {
  final Set<gmaps.Polyline> polylines;
  final Set<gmaps.Marker> markers;
  final int trailSegments;
  final int campsiteMarkers;
  final int trailheadMarkers;
  final int gasMarkers;

  const _ModeOverlays({
    this.polylines = const {},
    this.markers = const {},
    this.trailSegments = 0,
    this.campsiteMarkers = 0,
    this.trailheadMarkers = 0,
    this.gasMarkers = 0,
  });
}

class _AdventureViewportFocus {
  final gmaps.LatLng center;
  final List<gmaps.LatLng> hikingAnchors;
  final double portagingPadDegrees;
  final String signature;

  const _AdventureViewportFocus({
    required this.center,
    required this.hikingAnchors,
    required this.portagingPadDegrees,
    required this.signature,
  });
}

class _StyledRouteSegment {
  final List<gmaps.LatLng> path;
  final Color color;
  final int width;
  final int zIndex;

  const _StyledRouteSegment({
    required this.path,
    required this.color,
    required this.width,
    required this.zIndex,
  });

  bool get geodesic => false;

  List<gmaps.PatternItem> get patterns => const [];
}

class _HikingOverlayCacheEntry {
  final DateTime fetchedAt;
  final List<List<gmaps.LatLng>> trailLines;
  final List<Map<String, dynamic>> campsites;
  final List<Map<String, dynamic>> trailheads;
  final Map<String, dynamic> geoJson;

  const _HikingOverlayCacheEntry({
    required this.fetchedAt,
    required this.trailLines,
    required this.campsites,
    required this.trailheads,
    required this.geoJson,
  });
}

class _PortagingOverlayCacheEntry {
  final DateTime fetchedAt;
  final List<List<gmaps.LatLng>> waterLines;
  final List<List<gmaps.LatLng>> waterPolygons;
  final List<List<gmaps.LatLng>> portageLines;
  final List<Map<String, dynamic>> campsites;
  final List<Map<String, dynamic>> accessPoints;
  final Map<String, dynamic> geoJson;

  const _PortagingOverlayCacheEntry({
    required this.fetchedAt,
    required this.waterLines,
    required this.waterPolygons,
    required this.portageLines,
    required this.campsites,
    required this.accessPoints,
    required this.geoJson,
  });
}

class _TrailEdge {
  final int to;
  final double meters;

  const _TrailEdge({required this.to, required this.meters});
}

class _TrailCandidate {
  final int index;
  final double meters;

  const _TrailCandidate({required this.index, required this.meters});
}

class _TrailSpatialIndex {
  static const double _metersPerDegree = 111320.0;

  final double cellMeters;
  final double lonScale;
  final List<double> projectedX;
  final List<double> projectedY;
  final Map<String, List<int>> buckets;

  const _TrailSpatialIndex({
    required this.cellMeters,
    required this.lonScale,
    required this.projectedX,
    required this.projectedY,
    required this.buckets,
  });

  factory _TrailSpatialIndex.fromNodes(
    List<gmaps.LatLng> nodes, {
    double cellMeters = 1800.0,
  }) {
    final safeCellMeters = cellMeters.clamp(300.0, 5000.0).toDouble();
    if (nodes.isEmpty) {
      return _TrailSpatialIndex(
        cellMeters: safeCellMeters,
        lonScale: 1.0,
        projectedX: const <double>[],
        projectedY: const <double>[],
        buckets: const <String, List<int>>{},
      );
    }

    var meanLat = 0.0;
    for (final node in nodes) {
      meanLat += node.latitude;
    }
    meanLat /= nodes.length;
    final lonScale =
        math.cos(meanLat * (math.pi / 180.0)).abs().clamp(0.2, 1.0).toDouble();

    final projectedX = List<double>.filled(nodes.length, 0.0);
    final projectedY = List<double>.filled(nodes.length, 0.0);
    final buckets = <String, List<int>>{};

    for (var i = 0; i < nodes.length; i++) {
      final node = nodes[i];
      final x = node.longitude * _metersPerDegree * lonScale;
      final y = node.latitude * _metersPerDegree;
      projectedX[i] = x;
      projectedY[i] = y;
      final bucketX = (x / safeCellMeters).floor();
      final bucketY = (y / safeCellMeters).floor();
      final key = '$bucketX,$bucketY';
      buckets.putIfAbsent(key, () => <int>[]).add(i);
    }

    return _TrailSpatialIndex(
      cellMeters: safeCellMeters,
      lonScale: lonScale,
      projectedX: projectedX,
      projectedY: projectedY,
      buckets: buckets,
    );
  }

  List<int> indicesWithinRadius(gmaps.LatLng target, double radiusMeters) {
    if (projectedX.isEmpty || radiusMeters <= 0) return const <int>[];
    final x = target.longitude * _metersPerDegree * lonScale;
    final y = target.latitude * _metersPerDegree;
    final paddedRadius = math.max(radiusMeters + 180.0, radiusMeters * 1.08);
    final bucketRadius = math.max(1, (paddedRadius / cellMeters).ceil());
    final bucketX = (x / cellMeters).floor();
    final bucketY = (y / cellMeters).floor();
    final radiusSq = paddedRadius * paddedRadius;
    final out = <int>[];

    for (var dx = -bucketRadius; dx <= bucketRadius; dx++) {
      for (var dy = -bucketRadius; dy <= bucketRadius; dy++) {
        final key = '${bucketX + dx},${bucketY + dy}';
        final bucket = buckets[key];
        if (bucket == null || bucket.isEmpty) continue;
        for (final index in bucket) {
          final deltaX = projectedX[index] - x;
          final deltaY = projectedY[index] - y;
          final approxSq = deltaX * deltaX + deltaY * deltaY;
          if (approxSq <= radiusSq) {
            out.add(index);
          }
        }
      }
    }

    return out;
  }
}

class _PortageGraphCandidate {
  final int index;
  final double searchMeters;
  final double connectorMeters;
  final gmaps.LatLng graphAnchor;
  final bool usedAccess;

  const _PortageGraphCandidate({
    required this.index,
    required this.searchMeters,
    required this.connectorMeters,
    required this.graphAnchor,
    required this.usedAccess,
  });

  double get totalConnectorMeters => connectorMeters + searchMeters;
}

class _TrailPathResult {
  final List<int> nodePath;
  final double meters;

  const _TrailPathResult({required this.nodePath, required this.meters});
}

class _TrailLegSolution {
  final gmaps.LatLng start;
  final gmaps.LatLng end;
  final _TrailCandidate startCandidate;
  final _TrailCandidate endCandidate;
  final List<int> nodePath;
  final double graphMeters;

  const _TrailLegSolution({
    required this.start,
    required this.end,
    required this.startCandidate,
    required this.endCandidate,
    required this.nodePath,
    required this.graphMeters,
  });
}

class _PortageLegSolution {
  final gmaps.LatLng start;
  final gmaps.LatLng end;
  final _PortageGraphCandidate startOption;
  final _PortageGraphCandidate endOption;
  final List<gmaps.LatLng> pathPoints;
  final double graphMeters;

  const _PortageLegSolution({
    required this.start,
    required this.end,
    required this.startOption,
    required this.endOption,
    required this.pathPoints,
    required this.graphMeters,
  });
}

class _PortageWaterFirstLegSolution {
  final List<gmaps.LatLng> path;
  final double distanceMeters;

  const _PortageWaterFirstLegSolution({
    required this.path,
    required this.distanceMeters,
  });
}

class _PortageWaterFirstEdge {
  final int to;
  final double meters;
  final List<gmaps.LatLng> path;
  final bool isCarry;

  const _PortageWaterFirstEdge({
    required this.to,
    required this.meters,
    required this.path,
    required this.isCarry,
  });
}

class _LineProjection {
  final gmaps.LatLng point;
  final int segmentIndex;
  final double anchorMeters;

  const _LineProjection({
    required this.point,
    required this.segmentIndex,
    required this.anchorMeters,
  });
}

class _TrailGraphCacheEntry {
  final DateTime fetchedAt;
  final List<gmaps.LatLng> nodes;
  final List<List<_TrailEdge>> adjacency;
  final _TrailSpatialIndex spatialIndex;

  const _TrailGraphCacheEntry({
    required this.fetchedAt,
    required this.nodes,
    required this.adjacency,
    required this.spatialIndex,
  });
}

class _SegmentRouteCacheEntry {
  final DateTime fetchedAt;
  final _RouteComputation route;

  const _SegmentRouteCacheEntry({required this.fetchedAt, required this.route});
}

class _NodeDistance {
  final int node;
  final double meters;

  const _NodeDistance(this.node, this.meters);
}

class _MinNodeHeap {
  final List<_NodeDistance> _items = <_NodeDistance>[];

  bool get isEmpty => _items.isEmpty;

  void add(_NodeDistance value) {
    _items.add(value);
    var i = _items.length - 1;
    while (i > 0) {
      final parent = (i - 1) >> 1;
      if (_items[parent].meters <= _items[i].meters) break;
      final tmp = _items[parent];
      _items[parent] = _items[i];
      _items[i] = tmp;
      i = parent;
    }
  }

  _NodeDistance removeFirst() {
    final first = _items.first;
    final last = _items.removeLast();
    if (_items.isEmpty) {
      return first;
    }
    _items[0] = last;
    var i = 0;
    while (true) {
      final left = (i << 1) + 1;
      final right = left + 1;
      var smallest = i;
      if (left < _items.length &&
          _items[left].meters < _items[smallest].meters) {
        smallest = left;
      }
      if (right < _items.length &&
          _items[right].meters < _items[smallest].meters) {
        smallest = right;
      }
      if (smallest == i) break;
      final tmp = _items[i];
      _items[i] = _items[smallest];
      _items[smallest] = tmp;
      i = smallest;
    }
    return first;
  }
}

class _RouteComputation {
  final List<gmaps.LatLng> path;
  final double distanceMeters;
  final double durationSeconds;
  final Color color;
  final int width;
  final int zIndex;
  final bool geodesic;
  final List<gmaps.PatternItem> patterns;
  final List<_StyledRouteSegment> styledSegments;
  final List<String> instructions;
  final List<Map<String, dynamic>> stepDetails;
  final Map<String, dynamic>? arrivalStop;

  const _RouteComputation({
    required this.path,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.color,
    required this.width,
    required this.zIndex,
    this.geodesic = false,
    this.patterns = const [],
    this.styledSegments = const [],
    this.instructions = const [],
    this.stepDetails = const [],
    this.arrivalStop,
  });
}

class MapEmbed extends StatelessWidget {
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
      onRouteGeometry: onRouteGeometry,
      onRouteInstructions: onRouteInstructions,
      onRouteSegmentDetails: onRouteSegmentDetails,
      onTransitArrivalStop: onTransitArrivalStop,
      onRouteComputingChanged: onRouteComputingChanged,
      onRouteError: onRouteError,
      focusedRouteStep: focusedRouteStep,
      initialRouteGeometry: initialRouteGeometry,
      initialRouteInstructions: initialRouteInstructions,
      initialRouteSegmentDetails: initialRouteSegmentDetails,
      preferInitialRouteData: preferInitialRouteData,
      transportMode: transportMode,
      segmentTransportModes: segmentTransportModes,
      routeVia: routeVia,
      segmentRoutingTypes: segmentRoutingTypes,
      onRouteTapAddVia: onRouteTapAddVia,
      onViaDragEnd: onViaDragEnd,
      onViaTapDelete: onViaTapDelete,
      onHikingCampsiteTap: onHikingCampsiteTap,
      onPortageAccessTap: onPortageAccessTap,
      mapsKey: mapsKey,
      disableDefaultUi: disableDefaultUi,
      disableGestures: disableGestures,
      zoomControlsEnabled: zoomControlsEnabled,
      showNearbyContextOverlays: showNearbyContextOverlays,
      minZoom: minZoom,
      maxZoom: maxZoom,
      routeComputingBannerTop: routeComputingBannerTop,
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
  final String mapsKey;
  final bool disableDefaultUi;
  final bool disableGestures;
  final bool zoomControlsEnabled;
  final bool showNearbyContextOverlays;
  final double minZoom;
  final double maxZoom;
  final double routeComputingBannerTop;

  const _MapEmbedWebStateful({
    required this.points,
    required this.secondaryPoints,
    required this.onMapTap,
    required this.onPointTap,
    required this.onRouteSummary,
    required this.onRouteGeometry,
    required this.onRouteInstructions,
    required this.onRouteSegmentDetails,
    required this.onTransitArrivalStop,
    required this.onRouteComputingChanged,
    required this.onRouteError,
    required this.focusedRouteStep,
    required this.initialRouteGeometry,
    required this.initialRouteInstructions,
    required this.initialRouteSegmentDetails,
    required this.preferInitialRouteData,
    required this.transportMode,
    required this.segmentTransportModes,
    required this.routeVia,
    required this.segmentRoutingTypes,
    required this.onRouteTapAddVia,
    required this.onViaDragEnd,
    required this.onViaTapDelete,
    required this.onHikingCampsiteTap,
    required this.onPortageAccessTap,
    required this.mapsKey,
    required this.disableDefaultUi,
    required this.disableGestures,
    required this.zoomControlsEnabled,
    required this.showNearbyContextOverlays,
    required this.minZoom,
    required this.maxZoom,
    required this.routeComputingBannerTop,
  });

  @override
  State<_MapEmbedWebStateful> createState() => _MapEmbedWebStatefulState();
}

class _MapEmbedWebStatefulState extends State<_MapEmbedWebStateful> {
  gmaps.GoogleMapController? _controller;
  String? _controllerKeySig;
  Set<gmaps.Marker> _markers = const {};
  Set<gmaps.Polyline> _polylines = const {};
  Set<gmaps.Marker> _modeSpecificMarkers = const {};
  Set<gmaps.Polyline> _modeSpecificPolylines = const {};
  Set<gmaps.Marker> _routeComputingMarkers = const {};
  Set<gmaps.Polyline> _routeComputingPolylines = const {};
  bool _mapsReady = false;
  bool _isRouteComputing = false;

  /// Actual routed polyline geometry per segment index.
  /// Used for accurate nearest-segment detection (critical for loop routes).
  Map<int, List<gmaps.LatLng>> _segmentGeometry = {};

  int _suppressMapTapUntilMs = 0;

  late final String _instanceId = identityHashCode(this).toRadixString(16);

  String _mainSig = '';
  String _secondarySig = '';
  int _rebuildSeq = 0;
  String _lastRouteCalcSig = '';
  String _lastRouteErrorSig = '';
  bool _lastRouteHadBlockingGaps = false;

  List<String> _lastInstructions = const [];

  static final Map<String, _HikingOverlayCacheEntry> _hikingOverlayCache = {};
  static final Map<String, _PortagingOverlayCacheEntry> _portagingOverlayCache =
      {};
  static final Map<String, Future<_HikingOverlayCacheEntry?>>
  _hikingOverlayInFlight = {};
  static final Map<String, Future<_PortagingOverlayCacheEntry?>>
  _portagingOverlayInFlight = {};
  static final Map<String, _TrailGraphCacheEntry> _trailGraphCache = {};
  static final Map<String, _SegmentRouteCacheEntry> _segmentRouteCache = {};
  static final Map<String, Future<_RouteComputation?>> _segmentRouteInFlight =
      {};
  static final Map<String, List<Map<String, dynamic>>> _gasOverlayCache = {};
  static final Set<String> _routingProxyUnavailableUrls = <String>{};
  static final Set<String> _overpassUnavailableEndpoints = <String>{};
  static final Map<String, DateTime> _overpassEndpointCooldownUntil =
      <String, DateTime>{};
  html.DivElement? _placesHost;
  Object? _placesService;
  bool _didLogRuntimeKeyPresence = false;
  bool _didAttemptCampsiteInfoOpen = false;

  final _markerIconCache = _MarkerIconCache();

  Map<String, dynamic>? _previewPoint;
  gmaps.LatLng? _previewLatLng;
  Offset? _previewOffset;
  Size _mapSize = Size.zero;
  Timer? _previewUpdateTimer;
  Timer? _routeComputingOverlayUpdateTimer;
  Timer? _routeComputingHideTimer;
  Timer? _routeComputingAnimationTimer;
  DateTime? _routeComputingShownAt;
  Offset? _routeComputingStartOffset;
  Offset? _routeComputingTargetOffset;
  double _routeComputingCurveSeed = 0.5;
  double _routeComputingAnimationPhase = 0.0;
  Set<gmaps.Marker> _focusedStepMarkers = const {};
  Set<gmaps.Polyline> _focusedStepPolylines = const {};
  Timer? _focusedStepHighlightTimer;
  String _lastFocusedRouteStepSig = '';

  static const Duration _routeComputingMinVisible = Duration(
    milliseconds: 1100,
  );

  // ── Garmin-style ghost via marker (route hover + drag) ──
  gmaps.LatLng? _ghostViaLatLng; // snapped onto the polyline
  int _ghostViaSegAfterIndex = -1; // which segment it belongs to
  Offset? _ghostScreenOffset; // where to draw the overlay
  Timer? _ghostHoverTimer;
  double _currentZoom = 2.0;
  bool _isDraggingGhost = false;
  Offset? _ghostDragScreenOffset; // follows cursor during drag
  Timer? _adventureOverlayRefreshTimer;
  String _lastAdventureOverlayCameraSig = '';
  String _pendingAdventureOverlayCameraSig = '';
  String _lastAdventureOverlayAutoLoadSig = '';
  bool _showAdventureOverlayLoadButton = false;
  bool _isAdventureOverlayLoading = false;
  _PortagingOverlayCacheEntry? _lastVisiblePortagingOverlayEntry;

  String _normalizeTransportMode(String raw) {
    var mode = raw.trim().toLowerCase();
    if (mode == 'driving') mode = 'car';
    if (mode == 'flying' || mode == 'flight') mode = 'plane';
    if (mode == 'rail' ||
        mode == 'public_transit' ||
        mode == 'public transit' ||
        mode == 'transit') {
      mode = 'train';
    }
    if (mode == 'walking') mode = 'walk';
    if (mode == 'biking' || mode == 'bicycling' || mode == 'bikepacking') {
      mode = 'bike';
    }
    if (mode == 'canoe' || mode == 'canoeing' || mode == 'portage') {
      mode = 'portaging';
    }
    if (mode == 'backpacking') mode = 'hiking';
    if (mode == 'gas/stops' || mode == 'gas-stops' || mode == 'gasstops') {
      mode = 'gas_stops';
    }
    switch (mode) {
      case 'car':
      case 'plane':
      case 'train':
      case 'walk':
      case 'bike':
      case 'portaging':
      case 'hiking':
      case 'gas_stops':
        return mode;
      default:
        return 'car';
    }
  }

  String _mapKeySig() {
    return '${_instanceId}_${_mainSig}_${widget.transportMode}_${_segmentTransportSignature(widget.segmentTransportModes)}_${_viaSignature(widget.routeVia)}_${_segmentRoutingSignature(widget.segmentRoutingTypes)}';
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
    switch (_normalizeTransportMode(mode)) {
      case 'plane':
        return const Color(0xFF3949AB);
      case 'train':
        return const Color(0xFF546E7A);
      case 'walk':
        return const Color(0xFF00897B);
      case 'bike':
        return const Color(0xFF1565C0);
      case 'hiking':
        // Keep hiking route highly visible against green terrain overlays.
        return const Color(0xFF8E24AA);
      case 'portaging':
        // Use a warm accent so backcountry routes do not blend into water.
        return const Color(0xFFD81B60);
      case 'gas_stops':
        return const Color(0xFFEF6C00);
      case 'car':
      default:
        return const Color(0xFF1E88E5);
    }
  }

  bool _usesTerrainMap() {
    final mode = _normalizeTransportMode(widget.transportMode);
    if (mode == 'hiking' || mode == 'portaging') return true;
    final segments = widget.points.length > 1 ? widget.points.length - 1 : 0;
    if (segments <= 0) {
      return mode == 'hiking' || mode == 'portaging';
    }
    for (var i = 0; i < segments; i++) {
      final mode = _segmentTransportModeFor(i);
      if (mode == 'hiking' || mode == 'portaging') return true;
    }
    return false;
  }

  bool _modeMatchesAnySegment(String mode) {
    final target = _normalizeTransportMode(mode);
    final segments = widget.points.length > 1 ? widget.points.length - 1 : 0;
    if (segments <= 0) {
      return _normalizeTransportMode(widget.transportMode) == target;
    }
    for (var i = 0; i < segments; i++) {
      if (_segmentTransportModeFor(i) == target) return true;
    }
    return false;
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

  IconData _iconFor(String kindRaw, String categoryRaw) {
    final kind = kindRaw.trim().toLowerCase();
    final category = categoryRaw.trim().toLowerCase();
    if (kind == 'accommodation') return Icons.hotel;

    switch (category) {
      case 'car':
      case 'driving':
        return Icons.directions_car;
      case 'train':
      case 'transit':
        return Icons.directions_transit;
      case 'plane':
      case 'flight':
        return Icons.flight_takeoff;
      case 'gas_stops':
      case 'gas':
        return Icons.local_gas_station;
      case 'bike':
        return Icons.directions_bike;
      case 'walk':
      case 'pedestrian':
      case 'foot':
        return Icons.directions_walk;
      case 'hiking':
        return Icons.terrain;
      case 'portaging':
        return Icons.kayaking;
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
      case 'free time':
        return Icons.free_breakfast;
      default:
        return Icons.location_on;
    }
  }

  Color _colorFor(String kindRaw, String categoryRaw) {
    final kind = kindRaw.trim().toLowerCase();
    final category = categoryRaw.trim().toLowerCase();
    if (kind == 'accommodation') return Colors.purple.shade600;

    switch (category) {
      case 'car':
      case 'driving':
        return Colors.blueAccent;
      case 'train':
      case 'transit':
        return const Color(0xFF546E7A);
      case 'plane':
      case 'flight':
        return const Color(0xFF3949AB);
      case 'gas_stops':
      case 'gas':
        return const Color(0xFFEF6C00);
      case 'bike':
        return const Color(0xFF1565C0);
      case 'walk':
        return const Color(0xFF00796B);
      case 'hiking':
        return const Color(0xFF2E7D32);
      case 'portaging':
        return const Color(0xFF00897B);
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
      case 'free time':
        return const Color(0xFF78909C);
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
      case 'car':
      case 'driving':
        hue = gmaps.BitmapDescriptor.hueBlue;
        break;
      case 'train':
      case 'transit':
        hue = gmaps.BitmapDescriptor.hueCyan;
        break;
      case 'plane':
      case 'flight':
        hue = gmaps.BitmapDescriptor.hueViolet;
        break;
      case 'gas_stops':
      case 'gas':
        hue = gmaps.BitmapDescriptor.hueOrange;
        break;
      case 'bike':
        hue = gmaps.BitmapDescriptor.hueAzure;
        break;
      case 'walk':
        hue = gmaps.BitmapDescriptor.hueCyan;
        break;
      case 'portaging':
        hue = gmaps.BitmapDescriptor.hueAzure;
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
      case 'free time':
        hue = gmaps.BitmapDescriptor.hueCyan;
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
    _ensureMapsSDK();
  }

  Future<void> _ensureMapsSDK() async {
    await maps_loader.ensureGoogleMapsLoaded();
    if (!mounted) return;
    setState(() => _mapsReady = true);
    _logRuntimeKeyPresence();
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
    _routeComputingOverlayUpdateTimer?.cancel();
    _routeComputingHideTimer?.cancel();
    _routeComputingAnimationTimer?.cancel();
    _focusedStepHighlightTimer?.cancel();
    _ghostHoverTimer?.cancel();
    _adventureOverlayRefreshTimer?.cancel();
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
    final newSegModes = _segmentTransportSignature(
      widget.segmentTransportModes,
    );
    final oldSegModes = _segmentTransportSignature(
      oldWidget.segmentTransportModes,
    );
    final overlayModeChanged =
        widget.showNearbyContextOverlays != oldWidget.showNearbyContextOverlays;
    final modeChanged =
        _normalizeTransportMode(widget.transportMode) !=
        _normalizeTransportMode(oldWidget.transportMode);
    final initialRouteChanged =
        _geometrySignature(widget.initialRouteGeometry) !=
            _geometrySignature(oldWidget.initialRouteGeometry) ||
        _instructionsSignature(widget.initialRouteInstructions) !=
            _instructionsSignature(oldWidget.initialRouteInstructions) ||
        _routeSegmentDetailsSignature(widget.initialRouteSegmentDetails) !=
            _routeSegmentDetailsSignature(
              oldWidget.initialRouteSegmentDetails,
            ) ||
        widget.preferInitialRouteData != oldWidget.preferInitialRouteData;
    final shouldUseLateInitialRoute =
        initialRouteChanged &&
        widget.preferInitialRouteData &&
        _polylines.isEmpty &&
        _lastRouteCalcSig.isEmpty;

    if (newMain != _mainSig ||
        newSecondary != _secondarySig ||
        overlayModeChanged ||
        modeChanged ||
        shouldUseLateInitialRoute ||
        newSegModes != oldSegModes ||
        newVia != oldVia ||
        newSeg != oldSeg) {
      _lastAdventureOverlayCameraSig = '';
      _lastAdventureOverlayAutoLoadSig = '';
      _mainSig = newMain;
      _secondarySig = newSecondary;
      if (modeChanged || overlayModeChanged) {
        _clearModeSpecificLayers();
      }
      final nextMapKey = _mapKeySig();
      final requiresMapRemount =
          _controllerKeySig != null && _controllerKeySig != nextMapKey;
      if (requiresMapRemount) {
        _controller = null;
        _controllerKeySig = null;
      }
      _rebuild();
    }

    final nextFocusedStepSig = _focusedRouteStepSignature(
      widget.focusedRouteStep,
    );
    if (nextFocusedStepSig != _lastFocusedRouteStepSig) {
      _lastFocusedRouteStepSig = nextFocusedStepSig;
      if (widget.focusedRouteStep == null || nextFocusedStepSig.isEmpty) {
        _clearFocusedRouteStepHighlight();
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          unawaited(
            _applyFocusedRouteStep(
              Map<String, dynamic>.from(widget.focusedRouteStep!),
            ),
          );
        });
      }
    }

    if (_isRouteComputing) {
      _scheduleRouteComputingOverlayRefresh();
    }
  }

  void _clearModeSpecificLayers() {
    _lastAdventureOverlayCameraSig = '';
    _pendingAdventureOverlayCameraSig = '';
    _lastAdventureOverlayAutoLoadSig = '';
    _showAdventureOverlayLoadButton = false;
    _isAdventureOverlayLoading = false;
    _modeSpecificMarkers = const {};
    _modeSpecificPolylines = const {};
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

  String _geometrySignature(List<Map<String, dynamic>> geometry) {
    if (geometry.isEmpty) return '';
    final b = StringBuffer();
    for (final point in geometry) {
      final lat = _toDouble(point['lat']);
      final lon = _toDouble(point['lon'] ?? point['lng']);
      b
        ..write(lat.toStringAsFixed(5))
        ..write(',')
        ..write(lon.toStringAsFixed(5))
        ..write(';');
    }
    return b.toString();
  }

  String _instructionsSignature(List<String> lines) {
    if (lines.isEmpty) return '';
    return lines.map((line) => line.trim()).join('\n');
  }

  String _routeSegmentDetailsSignature(List<Map<String, dynamic>> details) {
    if (details.isEmpty) return '';
    final b = StringBuffer();
    for (final detail in details) {
      final segmentIndex = (detail['segmentIndex'] as num?)?.toInt() ?? -1;
      b
        ..write(segmentIndex)
        ..write(':')
        ..write((detail['mode'] ?? '').toString().trim())
        ..write(':');
      final steps = detail['steps'];
      if (steps is List) {
        for (final rawStep in steps) {
          if (rawStep is! Map) continue;
          b
            ..write((rawStep['tabLabel'] ?? '').toString().trim())
            ..write('|')
            ..write((rawStep['headline'] ?? '').toString().trim())
            ..write('|')
            ..write((rawStep['detail'] ?? '').toString().trim())
            ..write('|')
            ..write((rawStep['caption'] ?? '').toString().trim())
            ..write(';');
        }
      }
      b.write('\n');
    }
    return b.toString();
  }

  String _focusedRouteStepSignature(Map<String, dynamic>? step) {
    if (step == null || step.isEmpty) return '';
    final requestId = (step['requestId'] ?? '').toString().trim();
    final headline = (step['headline'] ?? '').toString().trim();
    final focusLat = _toDouble(step['focusLat'] ?? step['lat']);
    final focusLon = _toDouble(step['focusLon'] ?? step['lon'] ?? step['lng']);
    final pathLen = step['path'] is List ? (step['path'] as List).length : 0;
    return [
      requestId,
      headline,
      focusLat.toStringAsFixed(5),
      focusLon.toStringAsFixed(5),
      pathLen.toString(),
    ].join('|');
  }

  List<gmaps.LatLng> _routeStepPath(Map<String, dynamic> step) {
    final raw = step['path'];
    if (raw is! List) return const <gmaps.LatLng>[];
    final out = <gmaps.LatLng>[];
    for (final point in raw) {
      if (point is! Map) continue;
      final lat = _toDouble(point['lat']);
      final lon = _toDouble(point['lon'] ?? point['lng']);
      if (!lat.isFinite || !lon.isFinite) continue;
      if (out.isNotEmpty) {
        final last = out.last;
        if ((last.latitude - lat).abs() < 1e-7 &&
            (last.longitude - lon).abs() < 1e-7) {
          continue;
        }
      }
      out.add(gmaps.LatLng(lat, lon));
    }
    return out;
  }

  gmaps.LatLng? _routeStepFocusPoint(
    Map<String, dynamic> step, {
    List<gmaps.LatLng>? path,
  }) {
    final focusLat = _toDouble(step['focusLat'] ?? step['lat']);
    final focusLon = _toDouble(step['focusLon'] ?? step['lon'] ?? step['lng']);
    if (focusLat.isFinite && focusLon.isFinite) {
      return gmaps.LatLng(focusLat, focusLon);
    }
    final resolvedPath = path ?? _routeStepPath(step);
    if (resolvedPath.isEmpty) return null;
    return resolvedPath[resolvedPath.length ~/ 2];
  }

  Color? _parseRouteStepColor(String raw) {
    final hex = raw.trim().replaceAll('#', '');
    if (hex.length != 6) return null;
    try {
      return Color(int.parse('FF$hex', radix: 16));
    } catch (_) {
      return null;
    }
  }

  gmaps.LatLngBounds? _boundsForPath(List<gmaps.LatLng> path) {
    if (path.isEmpty) return null;
    var minLat = path.first.latitude;
    var maxLat = path.first.latitude;
    var minLon = path.first.longitude;
    var maxLon = path.first.longitude;
    for (final point in path.skip(1)) {
      minLat = math.min(minLat, point.latitude);
      maxLat = math.max(maxLat, point.latitude);
      minLon = math.min(minLon, point.longitude);
      maxLon = math.max(maxLon, point.longitude);
    }
    return gmaps.LatLngBounds(
      southwest: gmaps.LatLng(minLat, minLon),
      northeast: gmaps.LatLng(maxLat, maxLon),
    );
  }

  void _clearFocusedRouteStepHighlight() {
    _focusedStepHighlightTimer?.cancel();
    if (_focusedStepMarkers.isEmpty && _focusedStepPolylines.isEmpty) return;
    if (!mounted) return;
    setState(() {
      _focusedStepMarkers = const {};
      _focusedStepPolylines = const {};
    });
  }

  Future<void> _applyFocusedRouteStep(Map<String, dynamic> step) async {
    final focusPath = _routeStepPath(step);
    final focusPoint = _routeStepFocusPoint(step, path: focusPath);
    if (focusPoint == null) {
      _clearFocusedRouteStepHighlight();
      return;
    }

    final mode = _normalizeTransportMode((step['mode'] ?? '').toString());
    final accent =
        _parseRouteStepColor((step['lineColor'] ?? '').toString()) ??
        _standardRouteColor(mode);
    final highlightPolylines =
        focusPath.length >= 2
            ? <gmaps.Polyline>{
              gmaps.Polyline(
                polylineId: gmaps.PolylineId('${_instanceId}_focus_step_path'),
                points: focusPath,
                color: accent.withValues(alpha: 0.96),
                width: 8,
                zIndex: 70,
              ),
            }
            : const <gmaps.Polyline>{};
    final highlightMarkers = <gmaps.Marker>{
      gmaps.Marker(
        markerId: gmaps.MarkerId('${_instanceId}_focus_step_marker'),
        position: focusPoint,
        zIndex: 71,
        icon: gmaps.BitmapDescriptor.defaultMarkerWithHue(
          _hueFor('route_step', mode),
        ),
      ),
    };

    if (mounted) {
      setState(() {
        _focusedStepPolylines = highlightPolylines;
        _focusedStepMarkers = highlightMarkers;
      });
    }

    final c = _controller;
    if (c != null) {
      final requestedZoom = _toDouble(step['focusZoom']);
      final zoom = (requestedZoom > 0 ? requestedZoom : 14.0).clamp(
        widget.minZoom,
        widget.maxZoom,
      );
      final bounds = focusPath.length >= 2 ? _boundsForPath(focusPath) : null;
      final focusDistanceMeters = _pathDistanceMeters(focusPath);
      final shouldFitBounds =
          bounds != null &&
          focusDistanceMeters > 140.0 &&
          ((bounds.northeast.latitude - bounds.southwest.latitude).abs() >
                  1e-4 ||
              (bounds.northeast.longitude - bounds.southwest.longitude).abs() >
                  1e-4);
      try {
        if (shouldFitBounds) {
          await c.animateCamera(gmaps.CameraUpdate.newLatLngBounds(bounds, 72));
        } else {
          await c.animateCamera(
            gmaps.CameraUpdate.newLatLngZoom(focusPoint, zoom),
          );
        }
      } catch (_) {
        try {
          if (shouldFitBounds) {
            await c.moveCamera(gmaps.CameraUpdate.newLatLngBounds(bounds, 72));
          } else {
            await c.moveCamera(
              gmaps.CameraUpdate.newLatLngZoom(focusPoint, zoom),
            );
          }
        } catch (_) {}
      }
    }

    _focusedStepHighlightTimer?.cancel();
    _focusedStepHighlightTimer = Timer(const Duration(milliseconds: 1500), () {
      _clearFocusedRouteStepHighlight();
    });
  }

  List<gmaps.LatLng> _decodedInitialRoutePath() {
    final out = <gmaps.LatLng>[];
    double? lastLat;
    double? lastLon;
    for (final point in widget.initialRouteGeometry) {
      final lat = _toDouble(point['lat']);
      final lon = _toDouble(point['lon'] ?? point['lng']);
      if (!lat.isFinite || !lon.isFinite) continue;
      if (lastLat != null &&
          lastLon != null &&
          (lat - lastLat).abs() < 1e-7 &&
          (lon - lastLon).abs() < 1e-7) {
        continue;
      }
      out.add(gmaps.LatLng(lat, lon));
      lastLat = lat;
      lastLon = lon;
    }
    return out;
  }

  Map<int, List<gmaps.LatLng>> _initialSegmentGeometry(
    List<gmaps.LatLng> path,
  ) {
    final segmentCount =
        widget.points.length > 1 ? widget.points.length - 1 : 0;
    if (segmentCount <= 0 || path.length < 2) {
      return const <int, List<gmaps.LatLng>>{};
    }
    if (segmentCount == 1) {
      return <int, List<gmaps.LatLng>>{0: path};
    }

    final waypointTargets = widget.points
        .map((point) => gmaps.LatLng(_latOf(point), _lonOf(point)))
        .toList(growable: false);
    final boundaryIndexes = <int>[0];
    var searchStart = 0;
    for (var i = 1; i < waypointTargets.length - 1; i++) {
      final target = waypointTargets[i];
      var bestIndex = searchStart;
      var bestDistance = double.infinity;
      for (var j = searchStart; j < path.length; j++) {
        final distance = _haversineMeters(target, path[j]);
        if (distance < bestDistance) {
          bestDistance = distance;
          bestIndex = j;
        }
      }
      boundaryIndexes.add(bestIndex);
      searchStart = bestIndex;
    }
    boundaryIndexes.add(path.length - 1);

    final out = <int, List<gmaps.LatLng>>{};
    for (var seg = 0; seg < segmentCount; seg++) {
      final startIndex = boundaryIndexes[seg];
      final endIndex = boundaryIndexes[seg + 1];
      if (endIndex <= startIndex) {
        out[seg] = [waypointTargets[seg], waypointTargets[seg + 1]];
        continue;
      }
      out[seg] = path.sublist(startIndex, endIndex + 1);
    }
    return out;
  }

  double _pathDistanceMeters(List<gmaps.LatLng> path) {
    if (path.length < 2) return 0.0;
    var total = 0.0;
    for (var i = 0; i < path.length - 1; i++) {
      total += _haversineMeters(path[i], path[i + 1]);
    }
    return total;
  }

  bool _applyInitialRouteDataIfAvailable({required int seq}) {
    if (!widget.preferInitialRouteData || widget.showNearbyContextOverlays) {
      return false;
    }
    final path = _decodedInitialRoutePath();
    if (path.length < 2) return false;

    final mode = _normalizeTransportMode(widget.transportMode);
    final instructions = widget.initialRouteInstructions
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .take(8)
        .toList(growable: false);
    final geometry = _initialSegmentGeometry(path);
    final color = _standardRouteColor(mode).withOpacity(0.9);

    _segmentGeometry = geometry;
    _lastInstructions = instructions;

    final totalDistance = _pathDistanceMeters(path);

    widget.onRouteInstructions?.call(instructions);
    widget.onRouteSegmentDetails?.call(widget.initialRouteSegmentDetails);

    if (!mounted || seq != _rebuildSeq) return true;
    setState(() {
      _polylines =
          geometry.entries
              .map(
                (entry) => gmaps.Polyline(
                  polylineId: gmaps.PolylineId(
                    '${_instanceId}_cached_route_${entry.key}',
                  ),
                  points: entry.value,
                  color: color,
                  width: (mode == 'hiking' || mode == 'portaging') ? 6 : 4,
                  zIndex: 2,
                ),
              )
              .toSet();
      _modeSpecificMarkers = const {};
      _modeSpecificPolylines = const {};
    });
    if (totalDistance > 0) {
      widget.onRouteSummary?.call(totalDistance, 0);
    }
    _lastRouteCalcSig = _routeCalculationSignature();
    _lastRouteHadBlockingGaps = false;
    _lastRouteErrorSig = '';
    _setRouteComputing(false, seq: seq);
    return true;
  }

  // ignore: unused_element
  List<Map<String, dynamic>> _expandedPointsWithVia() {
    final pts = widget.points;
    if (pts.length < 2 || widget.routeVia.isEmpty) return pts;

    final byAfter = <int, List<Map<String, dynamic>>>{};
    for (final v in widget.routeVia) {
      final after = (v['afterIndex'] as num?)?.toInt();
      if (after == null || after < 0 || after >= pts.length - 1) continue;
      if (!_shouldUseViaForSegment(after)) continue;
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

  bool _shouldUseViaForSegment(int segmentIndex) {
    if (segmentIndex < 0) return false;
    final mode = _segmentTransportModeFor(segmentIndex);
    return mode != 'train' && mode != 'plane';
  }

  List<Map<String, dynamic>> _segmentPoints({required int afterIndex}) {
    final pts = widget.points;
    if (pts.length < 2) return const [];
    if (afterIndex < 0 || afterIndex >= pts.length - 1) return const [];

    final out = <Map<String, dynamic>>[pts[afterIndex]];
    if (_shouldUseViaForSegment(afterIndex)) {
      for (final v in widget.routeVia) {
        final after = (v['afterIndex'] as num?)?.toInt();
        if (after != afterIndex) continue;
        out.add({
          'lat': (v['lat'] as num?)?.toDouble() ?? 0.0,
          'lon': (v['lon'] as num?)?.toDouble() ?? 0.0,
          'name': 'Via',
        });
      }
    }
    out.add(pts[afterIndex + 1]);
    return out;
  }

  List<Map<String, dynamic>> _flattenRouteGeometry(
    Map<int, List<gmaps.LatLng>> segGeometry,
  ) {
    if (segGeometry.isEmpty) return const [];
    final keys = segGeometry.keys.toList()..sort();
    final out = <Map<String, dynamic>>[];
    double? lastLat;
    double? lastLon;
    for (final seg in keys) {
      final path = segGeometry[seg] ?? const <gmaps.LatLng>[];
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

  void _emitRouteGeometry(Map<int, List<gmaps.LatLng>> segGeometry) {
    final cb = widget.onRouteGeometry;
    if (cb == null) return;
    cb(_flattenRouteGeometry(segGeometry));
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

  /// Returns the segment index nearest to [tap], or -1 if the tap
  /// is not close enough to any route segment.
  ///
  /// When [_segmentGeometry] is populated (i.e. after routing), the distance
  /// check runs against the **actual routed path** instead of the simple
  /// waypoint-to-waypoint straight line. This is critical for loop routes
  /// (A→B→C→A) where straight-line segments overlap and would cause the
  /// wrong segment to be selected.
  int _nearestSegmentAfterIndex(
    gmaps.LatLng tap, {
    double maxDistanceDegrees = 0.008,
  }) {
    final pts = widget.points;
    if (pts.length < 2) return -1;

    var best = double.infinity;
    var bestAfter = 0;

    for (var seg = 0; seg < pts.length - 1; seg++) {
      final geom = _segmentGeometry[seg];
      if (geom != null && geom.length >= 2) {
        // Check every sub-segment of the actual routed polyline.
        for (var j = 0; j < geom.length - 1; j++) {
          final d = _distPointToSegmentSq(tap, geom[j], geom[j + 1]);
          if (d < best) {
            best = d;
            bestAfter = seg;
          }
        }
      } else {
        // Fall back to straight-line waypoint connection.
        final a = gmaps.LatLng(_latOf(pts[seg]), _lonOf(pts[seg]));
        final b = gmaps.LatLng(_latOf(pts[seg + 1]), _lonOf(pts[seg + 1]));
        final d = _distPointToSegmentSq(tap, a, b);
        if (d < best) {
          best = d;
          bestAfter = seg;
        }
      }
    }

    // Proximity gate: only match if tap is within ~maxDistanceDegrees of the route.
    final bestDist = math.sqrt(best);
    if (bestDist > maxDistanceDegrees) return -1;

    return bestAfter;
  }

  // ── Garmin-style ghost via marker helpers ──

  /// Project [p] onto line segment [a]→[b], returning the closest point ON
  /// the segment (clamped to endpoints).
  gmaps.LatLng _projectOnSegment(
    gmaps.LatLng p,
    gmaps.LatLng a,
    gmaps.LatLng b,
  ) {
    final lat0 = (a.latitude + b.latitude) / 2.0;
    final cosLat = math.cos(lat0 * (math.pi / 180.0));

    final ax = a.longitude * cosLat, ay = a.latitude;
    final bx = b.longitude * cosLat, by = b.latitude;
    final px = p.longitude * cosLat, py = p.latitude;

    final abx = bx - ax, aby = by - ay;
    final apx = px - ax, apy = py - ay;
    final abLen2 = abx * abx + aby * aby;

    var t = abLen2 > 1e-12 ? (apx * abx + apy * aby) / abLen2 : 0.0;
    t = t.clamp(0.0, 1.0);

    return gmaps.LatLng(
      a.latitude + t * (b.latitude - a.latitude),
      a.longitude + t * (b.longitude - a.longitude),
    );
  }

  /// Find the nearest point on any route polyline segment.
  /// Returns the snapped LatLng, segment index, and squared distance,
  /// or null if there are no segments.
  ({gmaps.LatLng point, int segAfterIndex, double distSq})?
  _nearestPointOnRoute(gmaps.LatLng cursor) {
    final pts = widget.points;
    if (pts.length < 2) return null;

    var bestDistSq = double.infinity;
    var bestPoint = cursor;
    var bestSeg = 0;

    for (var seg = 0; seg < pts.length - 1; seg++) {
      final geom = _segmentGeometry[seg];
      if (geom != null && geom.length >= 2) {
        for (var j = 0; j < geom.length - 1; j++) {
          final proj = _projectOnSegment(cursor, geom[j], geom[j + 1]);
          final d = _distPointToSegmentSq(cursor, geom[j], geom[j + 1]);
          if (d < bestDistSq) {
            bestDistSq = d;
            bestPoint = proj;
            bestSeg = seg;
          }
        }
      } else {
        final a = gmaps.LatLng(_latOf(pts[seg]), _lonOf(pts[seg]));
        final b = gmaps.LatLng(_latOf(pts[seg + 1]), _lonOf(pts[seg + 1]));
        final proj = _projectOnSegment(cursor, a, b);
        final d = _distPointToSegmentSq(cursor, a, b);
        if (d < bestDistSq) {
          bestDistSq = d;
          bestPoint = proj;
          bestSeg = seg;
        }
      }
    }

    return (point: bestPoint, segAfterIndex: bestSeg, distSq: bestDistSq);
  }

  void _hideGhostVia() {
    if (_ghostViaLatLng == null) return;
    setState(() {
      _ghostViaLatLng = null;
      _ghostScreenOffset = null;
      _ghostViaSegAfterIndex = -1;
    });
  }

  /// Called on every pointer-hover over the map. Throttled to avoid jank.
  Future<void> _handlePointerHover(Offset localPosition) async {
    _ghostHoverTimer?.cancel();

    // Don't update ghost while user is actively dragging it.
    if (_isDraggingGhost) return;

    // Only show ghost if route shaping is enabled.
    if (widget.onRouteTapAddVia == null || widget.points.length < 2) {
      _hideGhostVia();
      return;
    }

    _ghostHoverTimer = Timer(const Duration(milliseconds: 40), () async {
      if (_isDraggingGhost) return;
      final c = _controller;
      if (c == null || !mounted) return;

      try {
        final screenCoord = gmaps.ScreenCoordinate(
          x: localPosition.dx.round(),
          y: localPosition.dy.round(),
        );
        final latLng = await c.getLatLng(screenCoord);
        if (!mounted) return;

        final result = _nearestPointOnRoute(latLng);
        if (result == null) {
          _hideGhostVia();
          return;
        }

        // Pixel-based proximity threshold (~30 px at any zoom level).
        // 360 / 256 ≈ 1.40625, so 30 pixels ≈ 42° / 2^zoom.
        final threshold = 42.0 / math.pow(2, _currentZoom);
        final dist = math.sqrt(result.distSq);

        if (dist < threshold) {
          final screenPos = await c.getScreenCoordinate(result.point);
          if (!mounted) return;
          setState(() {
            _ghostViaLatLng = result.point;
            _ghostViaSegAfterIndex = result.segAfterIndex;
            _ghostScreenOffset = Offset(
              screenPos.x.toDouble(),
              screenPos.y.toDouble(),
            );
          });
        } else {
          _hideGhostVia();
        }
      } catch (_) {
        // Ignore coordinate conversion errors during rapid movement.
      }
    });
  }

  /// Complete a ghost-drag: convert final screen offset to lat/lng and create
  /// a via point at that location.
  Future<void> _endGhostDrag() async {
    final c = _controller;
    final offset = _ghostDragScreenOffset;
    final seg = _ghostViaSegAfterIndex;

    setState(() {
      _isDraggingGhost = false;
      _ghostDragScreenOffset = null;
      _ghostViaLatLng = null;
      _ghostScreenOffset = null;
      _ghostViaSegAfterIndex = -1;
    });

    if (c == null || offset == null || seg < 0) return;

    try {
      final sc = gmaps.ScreenCoordinate(
        x: offset.dx.round(),
        y: offset.dy.round(),
      );
      final latLng = await c.getLatLng(sc);
      widget.onRouteTapAddVia?.call(seg, latLng.latitude, latLng.longitude);
    } catch (_) {
      // Conversion error – discard the drag.
    }
  }

  /// Translucent blue circle overlay shown when the cursor hovers over the
  /// route line, mimicking Garmin's route-editing ghost handle.
  /// Supports both tap-to-create and drag-to-reroute.
  Widget _buildGhostViaOverlay() {
    // While dragging, show overlay at the drag position.
    final offset =
        _isDraggingGhost ? _ghostDragScreenOffset : _ghostScreenOffset;
    if (offset == null || (_ghostViaLatLng == null && !_isDraggingGhost)) {
      return const SizedBox.shrink();
    }
    final isDragging = _isDraggingGhost;
    const hitSize = 48.0; // generous touch / click target
    const dotSize = 28.0;
    return Positioned(
      left: offset.dx - hitSize / 2,
      top: offset.dy - hitSize / 2,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Single tap → instantly create via point at the snapped position.
        onTap: () {
          if (_ghostViaLatLng != null &&
              _ghostViaSegAfterIndex >= 0 &&
              widget.onRouteTapAddVia != null) {
            final ghost = _ghostViaLatLng!;
            final seg = _ghostViaSegAfterIndex;
            _hideGhostVia();
            widget.onRouteTapAddVia?.call(seg, ghost.latitude, ghost.longitude);
          }
        },
        // Drag → move the ghost freely, then create via on release.
        onPanStart: (_) {
          setState(() {
            _isDraggingGhost = true;
            _ghostDragScreenOffset = offset;
          });
        },
        onPanUpdate: (details) {
          final RenderBox? box = context.findRenderObject() as RenderBox?;
          if (box == null) return;
          final local = box.globalToLocal(details.globalPosition);
          setState(() {
            _ghostDragScreenOffset = local;
          });
        },
        onPanEnd: (_) => _endGhostDrag(),
        onPanCancel: () {
          setState(() {
            _isDraggingGhost = false;
            _ghostDragScreenOffset = null;
          });
        },
        child: SizedBox(
          width: hitSize,
          height: hitSize,
          child: Center(
            child: Container(
              width: dotSize,
              height: dotSize,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color:
                    isDragging
                        ? const Color(0xFF1565C0).withOpacity(0.70)
                        : const Color(0xFF1565C0).withOpacity(0.45),
                border: Border.all(color: Colors.white, width: 2.5),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.25),
                    blurRadius: 6,
                    spreadRadius: 1,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
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

  Future<void> _rebuild() async {
    final seq = ++_rebuildSeq;
    final main = widget.points;
    final secondary = widget.secondaryPoints;

    double dpr = 1.0;
    try {
      dpr = View.of(context).devicePixelRatio;
    } catch (_) {
      dpr = 1.0;
    }
    final mainBadgeColor = Theme.of(context).colorScheme.primary;

    final markers = <gmaps.Marker>{};

    final viaIconFuture = _markerIconCache.viaDot(dpr: dpr);

    final stopNumbers = <int?>[];
    var nextStopNumber = 1;
    for (final point in main) {
      if (_pointUsesStopBadge(point)) {
        stopNumbers.add(nextStopNumber++);
      } else {
        stopNumbers.add(null);
      }
    }

    Future<gmaps.BitmapDescriptor> buildMainIcon(int? stopNumber) async {
      if (stopNumber == null) {
        return viaIconFuture;
      }
      try {
        return await _markerIconCache.numbered(
          number: stopNumber,
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
      mainIconFutures.add(buildMainIcon(stopNumbers[i]));
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
      final stopNumber = stopNumbers[i];
      final name = (p['name'] ?? '').toString().trim();
      markers.add(
        gmaps.Marker(
          markerId: gmaps.MarkerId('${_instanceId}_main_$i'),
          position: gmaps.LatLng(lat, lon),
          infoWindow: gmaps.InfoWindow(
            title:
                name.isNotEmpty
                    ? name
                    : (stopNumber != null ? 'Stop $stopNumber' : 'Waypoint'),
            snippet:
                category.isNotEmpty
                    ? category
                    : (kind.isNotEmpty ? kind : null),
          ),
          icon: mainIcons[i],
          anchor: const Offset(0.5, 0.5),
          onTap: () {
            _suppressMapTapUntilMs =
                DateTime.now().millisecondsSinceEpoch + 900;
            _focusPoint(gmaps.LatLng(lat, lon));
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
                DateTime.now().millisecondsSinceEpoch + 900;
            _focusPoint(gmaps.LatLng(lat, lon));
            _showPreviewForPoint(p);
            widget.onPointTap?.call(p);
          },
        ),
      );
    }

    // Route shaping via markers (optional)
    for (var i = 0; i < widget.routeVia.length; i++) {
      final v = widget.routeVia[i];
      final after = (v['afterIndex'] as num?)?.toInt() ?? -1;
      if (!_shouldUseViaForSegment(after)) continue;
      final lat = (v['lat'] as num?)?.toDouble();
      final lon = (v['lon'] as num?)?.toDouble();
      if (lat == null || lon == null) continue;
      final origin = gmaps.LatLng(lat, lon);
      markers.add(
        gmaps.Marker(
          markerId: gmaps.MarkerId('${_instanceId}_via_$i'),
          position: origin,
          draggable: widget.onViaDragEnd != null,
          icon: viaIcon,
          alpha: 0.85,
          anchor: const Offset(0.5, 0.5),
          onDragEnd: (p) {
            _suppressMapTapUntilMs =
                DateTime.now().millisecondsSinceEpoch + 900;
            // If the marker barely moved, treat it as a tap → delete.
            final dLat = (p.latitude - origin.latitude).abs();
            final dLon = (p.longitude - origin.longitude).abs();
            if (dLat < 0.0002 && dLon < 0.0002) {
              widget.onViaTapDelete?.call(i);
              _hidePreview();
              return;
            }
            widget.onViaDragEnd?.call(i, p.latitude, p.longitude);
          },
          onTap: () {
            _suppressMapTapUntilMs =
                DateTime.now().millisecondsSinceEpoch + 900;
            widget.onViaTapDelete?.call(i);
            _hidePreview();
          },
        ),
      );
    }

    if (!mounted || seq != _rebuildSeq) return;
    setState(() {
      _markers = markers;
    });

    // Route + camera updates are async; ensure stale rebuilds don't win.
    await _updateRoutePolyline(seq: seq);
    if (!mounted || seq != _rebuildSeq) return;
    await _fitCamera();
    if (!mounted || seq != _rebuildSeq) return;
    _scheduleAdventureOverlayRefresh(force: true);
  }

  String _activeMapStyle() {
    final mode = _normalizeTransportMode(widget.transportMode);
    switch (mode) {
      case 'bike':
        return _bikeLayerStyleJson;
      case 'walk':
        return _walkLayerStyleJson;
      case 'hiking':
        return _hikingLayerStyleJson;
      case 'portaging':
        return _portagingLayerStyleJson;
      case 'plane':
        return _planeLayerStyleJson;
      case 'car':
      case 'train':
      case 'gas_stops':
      default:
        return _roadsOnlyStyleJson;
    }
  }

  String _metaContent(String name) {
    try {
      final meta = html.document.querySelector('meta[name="$name"]');
      return meta?.getAttribute('content')?.trim() ?? '';
    } catch (_) {
      return '';
    }
  }

  String _resolveOpenRouteServiceKey() {
    const fromDefine = String.fromEnvironment('OPENROUTESERVICE_API_KEY');
    if (fromDefine.isNotEmpty) return fromDefine;
    return _metaContent('openrouteservice-api-key');
  }

  String _resolveMapsApiKey() {
    const fromDefine = String.fromEnvironment('GOOGLE_MAPS_API_KEY');
    if (fromDefine.isNotEmpty) return fromDefine;
    return _metaContent('google-maps-api-key');
  }

  String _resolveGraphHopperKey() {
    const fromDefine = String.fromEnvironment('GRAPHHOPPER_API_KEY');
    if (fromDefine.isNotEmpty) return fromDefine;
    return _metaContent('graphhopper-api-key');
  }

  void _logRuntimeKeyPresence() {
    if (_didLogRuntimeKeyPresence) return;
    _didLogRuntimeKeyPresence = true;

    final mapsKey = _resolveMapsApiKey();
    final orsKey = _resolveOpenRouteServiceKey();
    final graphhopperKey = _resolveGraphHopperKey();
    debugPrint('MAPS_KEY present: ${mapsKey.isNotEmpty} len=${mapsKey.length}');
    debugPrint('ORS_KEY present: ${orsKey.isNotEmpty} len=${orsKey.length}');
    debugPrint(
      'GRAPHHOPPER_KEY present: ${graphhopperKey.isNotEmpty} len=${graphhopperKey.length}',
    );
    debugPrint('STRICT_ROUTING enabled: $_strictRouting');
    debugPrint('ROUTING_PROXY_URL: ${_resolveRoutingProxyUrl()}');
  }

  void _logLayerCounts({
    required String mode,
    required int routePolylines,
    required int trailSegments,
    required int campsiteMarkers,
    required int trailheadMarkers,
    required int gasMarkers,
  }) {
    debugPrint(
      'modeLayerCounts mode=$mode polylines=$routePolylines trail_segments=$trailSegments campsite_markers=$campsiteMarkers trailhead_markers=$trailheadMarkers gas_markers=$gasMarkers',
    );
  }

  void _setRouteComputing(bool value, {required int seq}) {
    if (!mounted || seq != _rebuildSeq) return;
    if (value) {
      _routeComputingHideTimer?.cancel();
      _routeComputingHideTimer = null;
      _routeComputingShownAt = DateTime.now();
      if (_isRouteComputing) {
        _scheduleRouteComputingOverlayRefresh();
        return;
      }
      setState(() => _isRouteComputing = true);
      widget.onRouteComputingChanged?.call(true);
      _scheduleRouteComputingOverlayRefresh(
        delay: const Duration(milliseconds: 140),
      );
      return;
    }

    if (!_isRouteComputing) {
      _routeComputingShownAt = null;
      return;
    }

    final shownAt = _routeComputingShownAt;
    final elapsed =
        shownAt == null
            ? _routeComputingMinVisible
            : DateTime.now().difference(shownAt);
    final remaining = _routeComputingMinVisible - elapsed;
    if (remaining > Duration.zero) {
      _routeComputingHideTimer?.cancel();
      _routeComputingHideTimer = Timer(remaining, () {
        if (!mounted) return;
        _routeComputingHideTimer = null;
        _routeComputingShownAt = null;
        if (!_isRouteComputing) return;
        setState(() {
          _isRouteComputing = false;
          _routeComputingStartOffset = null;
          _routeComputingTargetOffset = null;
        });
        widget.onRouteComputingChanged?.call(false);
      });
      return;
    }

    _routeComputingHideTimer?.cancel();
    _routeComputingHideTimer = null;
    _routeComputingShownAt = null;
    setState(() {
      _isRouteComputing = false;
      _routeComputingStartOffset = null;
      _routeComputingTargetOffset = null;
    });
    widget.onRouteComputingChanged?.call(false);
  }

  void _scheduleRouteComputingOverlayRefresh({
    Duration delay = const Duration(milliseconds: 60),
  }) {
    _routeComputingOverlayUpdateTimer?.cancel();
    if (!_isRouteComputing) return;
    _routeComputingOverlayUpdateTimer = Timer(delay, () {
      unawaited(_updateRouteComputingOverlayAnchors());
    });
  }

  void _clearRouteComputingOverlayAnchors({bool rebuild = true}) {
    _routeComputingOverlayUpdateTimer?.cancel();
    if (_routeComputingStartOffset == null &&
        _routeComputingTargetOffset == null) {
      return;
    }
    if (!rebuild || !mounted) {
      _routeComputingStartOffset = null;
      _routeComputingTargetOffset = null;
      return;
    }
    setState(() {
      _routeComputingStartOffset = null;
      _routeComputingTargetOffset = null;
    });
  }

  double _routeComputingSeedFor(gmaps.LatLng start, gmaps.LatLng target) {
    final basis =
        (start.latitude.abs() * 13.0) +
        (start.longitude.abs() * 7.0) +
        (target.latitude.abs() * 5.0) +
        (target.longitude.abs() * 11.0);
    final fractional = basis - basis.floorToDouble();
    return (fractional.clamp(0.14, 0.86) as num).toDouble();
  }

  Future<void> _updateRouteComputingOverlayAnchors() async {
    final c = _controller;
    if (c == null ||
        !mounted ||
        !_isRouteComputing ||
        _mapSize == Size.zero ||
        widget.points.length < 2) {
      _clearRouteComputingOverlayAnchors();
      return;
    }

    final startLat = _latOf(widget.points[0]);
    final startLon = _lonOf(widget.points[0]);
    final targetLat = _latOf(widget.points[1]);
    final targetLon = _lonOf(widget.points[1]);
    if (!startLat.isFinite ||
        !startLon.isFinite ||
        !targetLat.isFinite ||
        !targetLon.isFinite) {
      _clearRouteComputingOverlayAnchors();
      return;
    }

    try {
      final startLatLng = gmaps.LatLng(startLat, startLon);
      final targetLatLng = gmaps.LatLng(targetLat, targetLon);
      final startScreen = await c.getScreenCoordinate(startLatLng);
      final targetScreen = await c.getScreenCoordinate(targetLatLng);
      if (!mounted || !_isRouteComputing) return;

      final startOffset = Offset(
        startScreen.x.toDouble().clamp(18.0, _mapSize.width - 18.0),
        startScreen.y.toDouble().clamp(18.0, _mapSize.height - 18.0),
      );
      final targetOffset = Offset(
        targetScreen.x.toDouble().clamp(18.0, _mapSize.width - 18.0),
        targetScreen.y.toDouble().clamp(18.0, _mapSize.height - 18.0),
      );
      final nextSeed = _routeComputingSeedFor(startLatLng, targetLatLng);

      if (_routeComputingStartOffset == startOffset &&
          _routeComputingTargetOffset == targetOffset &&
          _routeComputingCurveSeed == nextSeed) {
        return;
      }

      setState(() {
        _routeComputingStartOffset = startOffset;
        _routeComputingTargetOffset = targetOffset;
        _routeComputingCurveSeed = nextSeed;
      });
    } catch (_) {
      _clearRouteComputingOverlayAnchors();
    }
  }

  void _startRouteComputingNativeAnimation() {
    _routeComputingAnimationTimer?.cancel();
    _routeComputingAnimationPhase = 0.0;
    _rebuildRouteComputingNativeOverlay();
    _routeComputingAnimationTimer = Timer.periodic(
      const Duration(milliseconds: 90),
      (_) {
        if (!mounted || !_isRouteComputing) {
          _routeComputingAnimationTimer?.cancel();
          _routeComputingAnimationTimer = null;
          return;
        }
        _routeComputingAnimationPhase =
            (_routeComputingAnimationPhase + 0.08) % 1.0;
        _rebuildRouteComputingNativeOverlay();
      },
    );
  }

  void _stopRouteComputingNativeAnimation() {
    _routeComputingAnimationTimer?.cancel();
    _routeComputingAnimationTimer = null;
    _routeComputingAnimationPhase = 0.0;
    if (_routeComputingMarkers.isEmpty && _routeComputingPolylines.isEmpty) {
      return;
    }
    setState(() {
      _routeComputingMarkers = const {};
      _routeComputingPolylines = const {};
    });
  }

  List<gmaps.LatLng> _routeComputingArcPoints(
    gmaps.LatLng start,
    gmaps.LatLng end,
  ) {
    final dx = end.longitude - start.longitude;
    final dy = end.latitude - start.latitude;
    final distance = math.sqrt((dx * dx) + (dy * dy));
    if (distance <= 0.000001) return [start, end];

    final normalX = -dy / distance;
    final normalY = dx / distance;
    final directionSign = _routeComputingCurveSeed >= 0.5 ? 1.0 : -1.0;
    final curveStrength = distance * (0.12 + (0.08 * _routeComputingCurveSeed));
    final control = gmaps.LatLng(
      ((start.latitude + end.latitude) / 2) + (normalY * curveStrength * directionSign),
      ((start.longitude + end.longitude) / 2) + (normalX * curveStrength * directionSign),
    );

    return List<gmaps.LatLng>.generate(24, (index) {
      final t = index / 23.0;
      final omt = 1.0 - t;
      return gmaps.LatLng(
        (omt * omt * start.latitude) +
            (2 * omt * t * control.latitude) +
            (t * t * end.latitude),
        (omt * omt * start.longitude) +
            (2 * omt * t * control.longitude) +
            (t * t * end.longitude),
      );
    });
  }

  gmaps.LatLng _interpolateLatLng(gmaps.LatLng a, gmaps.LatLng b, double t) {
    return gmaps.LatLng(
      a.latitude + ((b.latitude - a.latitude) * t),
      a.longitude + ((b.longitude - a.longitude) * t),
    );
  }

  List<gmaps.LatLng> _routeComputingBeamPoints(
    List<gmaps.LatLng> path,
    double progress,
  ) {
    if (path.length < 2) return path;
    final headPosition = (path.length - 1) * (0.14 + (0.82 * progress));
    final tailSpan = math.max(2.0, (path.length - 1) * 0.22);
    final startPosition = math.max(0.0, headPosition - tailSpan);
    final startIndex = startPosition.floor();
    final endIndex = math.min(path.length - 1, headPosition.ceil());
    final out = <gmaps.LatLng>[
      _interpolateLatLng(
        path[startIndex],
        path[math.min(path.length - 1, startIndex + 1)],
        startPosition - startIndex,
      ),
    ];
    for (var i = startIndex + 1; i <= endIndex; i++) {
      out.add(path[i]);
    }
    if (out.length == 1) {
      out.add(
        _interpolateLatLng(
          path[endIndex],
          path[math.min(path.length - 1, endIndex + 1)],
          headPosition - endIndex.floorToDouble(),
        ),
      );
    }
    return out;
  }

  void _rebuildRouteComputingNativeOverlay() {
    if (!mounted || !_isRouteComputing || widget.points.length < 2) {
      if (_routeComputingMarkers.isNotEmpty || _routeComputingPolylines.isNotEmpty) {
        setState(() {
          _routeComputingMarkers = const {};
          _routeComputingPolylines = const {};
        });
      }
      return;
    }

    final start = gmaps.LatLng(_latOf(widget.points[0]), _lonOf(widget.points[0]));
    final target = gmaps.LatLng(_latOf(widget.points[1]), _lonOf(widget.points[1]));
    final path = _routeComputingArcPoints(start, target);
    final beam = _routeComputingBeamPoints(path, _routeComputingAnimationPhase);
    final head = beam.isNotEmpty ? beam.last : target;

    final faintColor =
        Color.lerp(
          const Color(0x4438BDF8),
          const Color(0x3A2DD4BF),
          _routeComputingAnimationPhase.clamp(0.0, 1.0),
        )!;
    final glowColor =
        Color.lerp(
          const Color(0xFF38BDF8),
          const Color(0xFF2DD4BF),
          _routeComputingAnimationPhase.clamp(0.0, 1.0),
        )!;

    final polylines = <gmaps.Polyline>{
      gmaps.Polyline(
        polylineId: gmaps.PolylineId('${_instanceId}_route_probe_track'),
        points: path,
        color: faintColor,
        width: 4,
        zIndex: 990,
      ),
      if (beam.length >= 2)
        gmaps.Polyline(
          polylineId: gmaps.PolylineId('${_instanceId}_route_probe_beam'),
          points: beam,
          color: glowColor,
          width: 6,
          zIndex: 995,
        ),
    };

    final markers = <gmaps.Marker>{
      gmaps.Marker(
        markerId: gmaps.MarkerId('${_instanceId}_route_probe_start'),
        position: start,
        icon: gmaps.BitmapDescriptor.defaultMarkerWithHue(
          gmaps.BitmapDescriptor.hueAzure,
        ),
        zIndex: 990,
      ),
      gmaps.Marker(
        markerId: gmaps.MarkerId('${_instanceId}_route_probe_target'),
        position: target,
        icon: gmaps.BitmapDescriptor.defaultMarkerWithHue(
          gmaps.BitmapDescriptor.hueGreen,
        ),
        zIndex: 990,
      ),
      gmaps.Marker(
        markerId: gmaps.MarkerId('${_instanceId}_route_probe_head'),
        position: head,
        icon: gmaps.BitmapDescriptor.defaultMarkerWithHue(
          gmaps.BitmapDescriptor.hueCyan,
        ),
        zIndex: 999,
      ),
    };

    setState(() {
      _routeComputingPolylines = polylines;
      _routeComputingMarkers = markers;
    });
  }

  double _adventureOverlayMinZoom(String mode) {
    switch (_normalizeTransportMode(mode)) {
      case 'portaging':
        return 10.8;
      case 'hiking':
        return 11.5;
      default:
        return double.infinity;
    }
  }

  bool _shouldRenderAdventureOverlayMode(String mode) {
    final normalized = _normalizeTransportMode(mode);
    if (!_modeMatchesAnySegment(normalized)) return false;
    return _currentZoom >= _adventureOverlayMinZoom(normalized);
  }

  bool _canOfferAdventureOverlayLoad() {
    if (!widget.showNearbyContextOverlays) return false;
    return _shouldRenderAdventureOverlayMode('hiking') ||
        _shouldRenderAdventureOverlayMode('portaging');
  }

  bool _isAdventurePolylineId(String id) {
    return id.contains('_trail_') ||
        id.contains('_portage_water_') ||
        id.contains('_portage_trail_');
  }

  bool _isAdventureMarkerId(String id) {
    return id.contains('_camp_') ||
        id.contains('_trailhead_') ||
        id.contains('_p_camp_') ||
        id.contains('_p_access_');
  }

  Set<gmaps.Polyline> _existingAdventurePolylines() {
    return _modeSpecificPolylines.where((polyline) {
      return _isAdventurePolylineId(polyline.polylineId.value);
    }).toSet();
  }

  Set<gmaps.Marker> _existingAdventureMarkers() {
    return _modeSpecificMarkers.where((marker) {
      return _isAdventureMarkerId(marker.markerId.value);
    }).toSet();
  }

  Set<gmaps.Polyline> _existingNonAdventurePolylines() {
    return _modeSpecificPolylines.where((polyline) {
      return !_isAdventurePolylineId(polyline.polylineId.value);
    }).toSet();
  }

  Set<gmaps.Marker> _existingNonAdventureMarkers() {
    return _modeSpecificMarkers.where((marker) {
      return !_isAdventureMarkerId(marker.markerId.value);
    }).toSet();
  }

  void _clearAdventureOverlayLayers({bool resetLoadedSignature = false}) {
    final nextPolylines = _existingNonAdventurePolylines();
    final nextMarkers = _existingNonAdventureMarkers();
    if (!mounted) {
      if (resetLoadedSignature) {
        _lastAdventureOverlayCameraSig = '';
        _lastAdventureOverlayAutoLoadSig = '';
      }
      _pendingAdventureOverlayCameraSig = '';
      _showAdventureOverlayLoadButton = false;
      _isAdventureOverlayLoading = false;
      _modeSpecificPolylines = nextPolylines;
      _modeSpecificMarkers = nextMarkers;
      return;
    }
    setState(() {
      if (resetLoadedSignature) {
        _lastAdventureOverlayCameraSig = '';
        _lastAdventureOverlayAutoLoadSig = '';
      }
      _pendingAdventureOverlayCameraSig = '';
      _showAdventureOverlayLoadButton = false;
      _isAdventureOverlayLoading = false;
      _modeSpecificPolylines = nextPolylines;
      _modeSpecificMarkers = nextMarkers;
    });
  }

  Set<gmaps.Polyline> _existingHikingAdventurePolylines() {
    return _modeSpecificPolylines.where((polyline) {
      return polyline.polylineId.value.contains('_trail_');
    }).toSet();
  }

  Set<gmaps.Marker> _existingHikingAdventureMarkers() {
    return _modeSpecificMarkers.where((marker) {
      final id = marker.markerId.value;
      return id.contains('_camp_') || id.contains('_trailhead_');
    }).toSet();
  }

  Set<gmaps.Polyline> _existingPortagingAdventurePolylines() {
    return _modeSpecificPolylines.where((polyline) {
      final id = polyline.polylineId.value;
      return id.contains('_portage_water_') || id.contains('_portage_trail_');
    }).toSet();
  }

  Set<gmaps.Marker> _existingPortagingAdventureMarkers() {
    return _modeSpecificMarkers.where((marker) {
      final id = marker.markerId.value;
      return id.contains('_p_camp_') || id.contains('_p_access_');
    }).toSet();
  }

  int _countGasMarkers(Set<gmaps.Marker> markers) {
    return markers
        .where((marker) => marker.markerId.value.contains('_gas_'))
        .length;
  }

  gmaps.LatLng? _fallbackAdventureFocusPoint() {
    if (_markers.isNotEmpty) {
      return _markers.first.position;
    }
    final segments = _segmentGeometry.keys.toList()..sort();
    for (final seg in segments) {
      final path = _segmentGeometry[seg];
      if (path != null && path.isNotEmpty) {
        return path.first;
      }
    }
    return null;
  }

  Future<_AdventureViewportFocus?> _currentAdventureViewportFocus() async {
    final fallback = _fallbackAdventureFocusPoint();
    final c = _controller;
    if (c == null) {
      if (fallback == null) return null;
      return _AdventureViewportFocus(
        center: fallback,
        hikingAnchors: <gmaps.LatLng>[fallback],
        portagingPadDegrees: 0.12,
        signature:
            '${_hikingCacheKey(<gmaps.LatLng>[fallback])}|'
            '${_portagingFocusCacheKey(fallback, padDegrees: 0.12)}',
      );
    }

    try {
      final bounds = await c.getVisibleRegion();
      final sw = bounds.southwest;
      final ne = bounds.northeast;
      final center = gmaps.LatLng(
        (sw.latitude + ne.latitude) / 2.0,
        (sw.longitude + ne.longitude) / 2.0,
      );
      final latSpan = (ne.latitude - sw.latitude).abs();
      var lonSpan = (ne.longitude - sw.longitude).abs();
      if (lonSpan > 180.0) {
        lonSpan = 360.0 - lonSpan;
      }
      final portagingPadDegrees = _quantizedOverlayPadDegrees(
        (math.max(latSpan, lonSpan) * 0.75).clamp(0.08, 0.18).toDouble(),
      );
      final hikingAnchors = <gmaps.LatLng>[sw, center, ne];
      return _AdventureViewportFocus(
        center: center,
        hikingAnchors: hikingAnchors,
        portagingPadDegrees: portagingPadDegrees,
        signature:
            '${_hikingCacheKey(hikingAnchors)}|'
            '${_portagingFocusCacheKey(center, padDegrees: portagingPadDegrees)}',
      );
    } catch (_) {
      if (fallback == null) return null;
      return _AdventureViewportFocus(
        center: fallback,
        hikingAnchors: <gmaps.LatLng>[fallback],
        portagingPadDegrees: 0.12,
        signature:
            '${_hikingCacheKey(<gmaps.LatLng>[fallback])}|'
            '${_portagingFocusCacheKey(fallback, padDegrees: 0.12)}',
      );
    }
  }

  Future<void> _updateAdventureOverlayLoadPrompt({bool force = false}) async {
    final hasAdventureMode =
        _modeMatchesAnySegment('hiking') || _modeMatchesAnySegment('portaging');
    if (!widget.showNearbyContextOverlays || !hasAdventureMode) {
      if (_showAdventureOverlayLoadButton ||
          _pendingAdventureOverlayCameraSig.isNotEmpty ||
          _isAdventurePolylineIdSetVisible() ||
          _isAdventureMarkerIdSetVisible()) {
        _clearAdventureOverlayLayers(resetLoadedSignature: true);
      } else if (_lastAdventureOverlayCameraSig.isNotEmpty) {
        _lastAdventureOverlayCameraSig = '';
        _lastAdventureOverlayAutoLoadSig = '';
      }
      return;
    }

    final canOffer = _canOfferAdventureOverlayLoad();
    if (!canOffer) {
      if (!mounted) {
        _pendingAdventureOverlayCameraSig = '';
        _lastAdventureOverlayAutoLoadSig = '';
        _showAdventureOverlayLoadButton = false;
        return;
      }
      if (_showAdventureOverlayLoadButton ||
          _pendingAdventureOverlayCameraSig.isNotEmpty) {
        setState(() {
          _pendingAdventureOverlayCameraSig = '';
          _lastAdventureOverlayAutoLoadSig = '';
          _showAdventureOverlayLoadButton = false;
        });
      }
      return;
    }

    final viewport = await _currentAdventureViewportFocus();
    if (!mounted) return;
    final nextSig =
        '${_shouldRenderAdventureOverlayMode('hiking') ? 1 : 0}|'
        '${_shouldRenderAdventureOverlayMode('portaging') ? 1 : 0}|'
        '${viewport?.signature ?? 'none'}';
    final shouldOffer =
        viewport != null && nextSig != _lastAdventureOverlayCameraSig;
    final shouldAutoLoad =
        shouldOffer &&
        !_isAdventureOverlayLoading &&
        nextSig != _lastAdventureOverlayAutoLoadSig;
    if (!force &&
        nextSig == _pendingAdventureOverlayCameraSig &&
        _showAdventureOverlayLoadButton == (shouldOffer && !shouldAutoLoad)) {
      return;
    }
    setState(() {
      _pendingAdventureOverlayCameraSig = nextSig;
      _showAdventureOverlayLoadButton = shouldOffer && !shouldAutoLoad;
    });
    if (shouldAutoLoad) {
      _lastAdventureOverlayAutoLoadSig = nextSig;
      unawaited(_loadAdventureOverlaysForViewport());
    }
  }

  void _scheduleAdventureOverlayRefresh({bool force = false}) {
    _adventureOverlayRefreshTimer?.cancel();
    _adventureOverlayRefreshTimer = Timer(
      const Duration(milliseconds: 120),
      () {
        unawaited(_updateAdventureOverlayLoadPrompt(force: force));
      },
    );
  }

  bool _isAdventurePolylineIdSetVisible() {
    return _modeSpecificPolylines.any(
      (polyline) => _isAdventurePolylineId(polyline.polylineId.value),
    );
  }

  bool _isAdventureMarkerIdSetVisible() {
    return _modeSpecificMarkers.any(
      (marker) => _isAdventureMarkerId(marker.markerId.value),
    );
  }

  _PortagingOverlayCacheEntry? _nearestCachedPortagingFocusEntry(
    gmaps.LatLng focusPoint, {
    double maxDegreesDelta = 0.22,
  }) {
    _PortagingOverlayCacheEntry? bestEntry;
    var bestDistance = double.infinity;
    var bestFreshness = false;

    for (final cacheEntry in _portagingOverlayCache.entries) {
      final key = cacheEntry.key.trim();
      if (!key.startsWith('focus:')) continue;
      final value = cacheEntry.value;
      if (value.waterLines.isEmpty && value.portageLines.isEmpty) continue;
      final parts = key.split(':');
      if (parts.length < 3) continue;
      final latLon = parts[1].split(',');
      if (latLon.length != 2) continue;
      final lat = double.tryParse(latLon[0]);
      final lon = double.tryParse(latLon[1]);
      if (lat == null || lon == null) continue;
      final latDelta = (focusPoint.latitude - lat).abs();
      final lonDelta = (focusPoint.longitude - lon).abs();
      if (latDelta > maxDegreesDelta || lonDelta > maxDegreesDelta) {
        continue;
      }
      final distance = latDelta + lonDelta;
      final isFresh = _isFresh(value.fetchedAt, _overlayCacheTtl);
      final isBetter =
          bestEntry == null ||
          (isFresh && !bestFreshness) ||
          (isFresh == bestFreshness && distance < bestDistance);
      if (!isBetter) continue;
      bestEntry = value;
      bestDistance = distance;
      bestFreshness = isFresh;
    }

    return bestEntry;
  }

  void _primePortagingRouteCaches(
    _PortagingOverlayCacheEntry entry, {
    required bool preferFocusOnly,
  }) {
    _lastVisiblePortagingOverlayEntry = entry;
    if (preferFocusOnly) return;

    final primedKeys = <String>{};
    void primeKey(String key) {
      final trimmed = key.trim();
      if (trimmed.isEmpty || !primedKeys.add(trimmed)) return;
      _portagingOverlayCache[trimmed] = entry;
    }

    final routeAnchors = _anchorPathForMode('portaging');
    if (routeAnchors.length >= 2) {
      final baseKey = _portagingRouteCacheKey(routeAnchors);
      primeKey(baseKey);
      primeKey('$baseKey:route-lite');
    }

    for (var seg = 0; seg + 1 < widget.points.length; seg++) {
      if (_normalizeTransportMode(_segmentTransportModeFor(seg)) !=
          'portaging') {
        continue;
      }
      final segPoints = _segmentPoints(afterIndex: seg);
      final anchors = _segmentLatLngs(segPoints);
      if (anchors.length < 2) continue;
      final baseKey = _portagingRouteCacheKey(anchors);
      primeKey(baseKey);
      primeKey('$baseKey:route-lite');
    }
  }

  Future<void> _loadAdventureOverlaysForViewport() async {
    if (_isAdventureOverlayLoading || !_canOfferAdventureOverlayLoad()) return;
    if (mounted) {
      setState(() => _isAdventureOverlayLoading = true);
    }
    try {
      await _refreshAdventureOverlays(force: true);
      if (!mounted) return;
      if (widget.points.length > 1 &&
          (_modeMatchesAnySegment('hiking') ||
              _modeMatchesAnySegment('portaging'))) {
        _lastRouteCalcSig = '';
        await _updateRoutePolyline(seq: _rebuildSeq);
      }
    } finally {
      if (mounted) {
        setState(() => _isAdventureOverlayLoading = false);
      }
      unawaited(_updateAdventureOverlayLoadPrompt(force: true));
    }
  }

  Future<void> _refreshAdventureOverlays({bool force = false}) async {
    final showNearbyContextOverlays = widget.showNearbyContextOverlays;
    final showHiking =
        showNearbyContextOverlays &&
        _shouldRenderAdventureOverlayMode('hiking');
    final showPortaging =
        showNearbyContextOverlays &&
        _shouldRenderAdventureOverlayMode('portaging');
    final viewport =
        (showHiking || showPortaging)
            ? await _currentAdventureViewportFocus()
            : null;
    if (!mounted) return;

    final nextSig =
        '${showHiking ? 1 : 0}|${showPortaging ? 1 : 0}|'
        '${viewport?.signature ?? 'none'}';
    if (!force && _lastAdventureOverlayCameraSig == nextSig) {
      return;
    }

    final seq = _rebuildSeq;
    var overlayPolylines = _existingNonAdventurePolylines();
    var overlayMarkers = _existingNonAdventureMarkers();
    var campsiteOverlayMarkers = <gmaps.Marker>{};
    var trailSegmentCount = 0;
    var campsiteMarkerCount = 0;
    var trailheadMarkerCount = 0;
    final gasMarkerCount = _countGasMarkers(overlayMarkers);

    if (showHiking && viewport != null) {
      try {
        final hiking = await _buildHikingOverlays(
          _segmentGeometry,
          overlayAnchors: viewport.hikingAnchors,
        );
        if (!mounted || seq != _rebuildSeq) return;
        if (hiking.polylines.isEmpty && hiking.markers.isEmpty) {
          final previousTrailPolylines = _existingHikingAdventurePolylines();
          final previousTrailMarkers = _existingHikingAdventureMarkers();
          overlayPolylines = {...overlayPolylines, ...previousTrailPolylines};
          overlayMarkers = {...overlayMarkers, ...previousTrailMarkers};
          campsiteOverlayMarkers = {
            ...campsiteOverlayMarkers,
            ...previousTrailMarkers,
          };
          trailSegmentCount += previousTrailPolylines.length;
          campsiteMarkerCount +=
              previousTrailMarkers
                  .where((marker) => marker.markerId.value.contains('_camp_'))
                  .length;
          trailheadMarkerCount +=
              previousTrailMarkers
                  .where(
                    (marker) => marker.markerId.value.contains('_trailhead_'),
                  )
                  .length;
          if (previousTrailPolylines.isNotEmpty ||
              previousTrailMarkers.isNotEmpty) {
            debugPrint('hikingOverlays reused_previous_layers');
          }
        } else {
          overlayPolylines = {...overlayPolylines, ...hiking.polylines};
          overlayMarkers = {...overlayMarkers, ...hiking.markers};
          campsiteOverlayMarkers = {
            ...campsiteOverlayMarkers,
            ...hiking.markers,
          };
          trailSegmentCount += hiking.trailSegments;
          campsiteMarkerCount += hiking.campsiteMarkers;
          trailheadMarkerCount += hiking.trailheadMarkers;
        }
      } catch (e) {
        debugPrint('hikingOverlays camera_refresh_failed err=$e');
      }
    }

    if (showPortaging && viewport != null) {
      try {
        final portaging = await _buildPortagingOverlays(
          _segmentGeometry,
          focusPointOverride: viewport.center,
          focusPadDegreesOverride: viewport.portagingPadDegrees,
          preferFocusOnly: true,
        );
        if (!mounted || seq != _rebuildSeq) return;
        if (portaging.polylines.isEmpty && portaging.markers.isEmpty) {
          final previousPortagingPolylines =
              _existingPortagingAdventurePolylines();
          final previousPortagingMarkers = _existingPortagingAdventureMarkers();
          overlayPolylines = {
            ...overlayPolylines,
            ...previousPortagingPolylines,
          };
          overlayMarkers = {...overlayMarkers, ...previousPortagingMarkers};
          campsiteOverlayMarkers = {
            ...campsiteOverlayMarkers,
            ...previousPortagingMarkers,
          };
          trailSegmentCount += previousPortagingPolylines.length;
          campsiteMarkerCount +=
              previousPortagingMarkers
                  .where((marker) => marker.markerId.value.contains('_p_camp_'))
                  .length;
          trailheadMarkerCount +=
              previousPortagingMarkers
                  .where(
                    (marker) => marker.markerId.value.contains('_p_access_'),
                  )
                  .length;
          if (previousPortagingPolylines.isNotEmpty ||
              previousPortagingMarkers.isNotEmpty) {
            debugPrint('portagingOverlays reused_previous_layers');
          }
        } else {
          overlayPolylines = {...overlayPolylines, ...portaging.polylines};
          overlayMarkers = {...overlayMarkers, ...portaging.markers};
          campsiteOverlayMarkers = {
            ...campsiteOverlayMarkers,
            ...portaging.markers,
          };
          trailSegmentCount += portaging.trailSegments;
          campsiteMarkerCount += portaging.campsiteMarkers;
          trailheadMarkerCount += portaging.trailheadMarkers;
        }
      } catch (e) {
        debugPrint('portagingOverlays camera_refresh_failed err=$e');
      }
    }

    if (!showNearbyContextOverlays || (!showHiking && !showPortaging)) {
      _didAttemptCampsiteInfoOpen = false;
    }

    if (!mounted || seq != _rebuildSeq) return;
    setState(() {
      _modeSpecificPolylines = overlayPolylines;
      _modeSpecificMarkers = overlayMarkers;
      _pendingAdventureOverlayCameraSig = nextSig;
      _showAdventureOverlayLoadButton = false;
    });
    if (showNearbyContextOverlays && campsiteOverlayMarkers.isNotEmpty) {
      _maybeOpenCampsiteInfoWindow(campsiteOverlayMarkers);
    }
    _logLayerCounts(
      mode: _normalizeTransportMode(widget.transportMode),
      routePolylines: _polylines.length,
      trailSegments: trailSegmentCount,
      campsiteMarkers: campsiteMarkerCount,
      trailheadMarkers: trailheadMarkerCount,
      gasMarkers: gasMarkerCount,
    );
    _lastAdventureOverlayCameraSig = nextSig;
  }

  Never _strictRoutingHardError(String message) {
    final full = 'STRICT_ROUTING_HARD_ERROR $message';
    debugPrint(full);
    throw StateError(full);
  }

  String _resolveRoutingProxyUrl() {
    final fromDefine = _routingProxyUrlDefine.trim();
    if (fromDefine.isNotEmpty) return fromDefine;
    final fromMeta = _metaContent('routing-proxy-url');
    if (fromMeta.isNotEmpty) return fromMeta;
    return '/api/route';
  }

  Future<_RouteComputation?> _routeViaBackendProxy(
    List<Map<String, dynamic>> segPoints, {
    required String provider,
    required String profile,
    required String mode,
  }) async {
    if (segPoints.length < 2) return null;

    final coordinates = segPoints
        .map((p) => <double>[_lonOf(p), _latOf(p)])
        .toList(growable: false);

    Future<_RouteComputation?> directOrsFallback(String reason) async {
      if (provider != 'ors') return null;
      return _routeViaDirectOpenRouteService(
        coordinates,
        profile: profile,
        mode: mode,
        reason: reason,
      );
    }

    try {
      final uri = Uri.parse(_resolveRoutingProxyUrl());
      final uriKey = uri.toString();
      if (_routingProxyUnavailableUrls.contains(uriKey)) {
        debugPrint(
          'routeProxy skipped_unavailable provider=$provider profile=$profile mode=$mode url=$uriKey',
        );
        return directOrsFallback('proxy_unavailable');
      }
      final resp = await http
          .post(
            uri,
            headers: const <String, String>{'Content-Type': 'application/json'},
            body: jsonEncode(<String, dynamic>{
              'provider': provider,
              'profile': profile,
              'coordinates': coordinates,
            }),
          )
          .timeout(const Duration(seconds: 8));

      if (resp.statusCode != 200) {
        final msg =
            'routeProxy non_200 provider=$provider profile=$profile mode=$mode status=${resp.statusCode}';
        if (resp.statusCode == 404 ||
            resp.statusCode == 405 ||
            resp.statusCode == 501) {
          _routingProxyUnavailableUrls.add(uriKey);
        }
        if (_strictRouting) _strictRoutingHardError(msg);
        debugPrint(msg);
        return await directOrsFallback('proxy_status_${resp.statusCode}');
      }

      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final rawPath = (data['path'] as List<dynamic>?) ?? const [];
      final path = <gmaps.LatLng>[];
      for (final pair in rawPath) {
        if (pair is! List || pair.length < 2) continue;
        final lat = (pair[0] as num?)?.toDouble();
        final lon = (pair[1] as num?)?.toDouble();
        if (lat == null || lon == null) continue;
        path.add(gmaps.LatLng(lat, lon));
      }
      if (path.length < 2) {
        final msg =
            'routeProxy invalid_geometry provider=$provider profile=$profile mode=$mode';
        if (_strictRouting) _strictRoutingHardError(msg);
        debugPrint(msg);
        return null;
      }

      final instructions = <String>[];
      final rawInstructions = data['instructions'];
      if (rawInstructions is List) {
        for (final item in rawInstructions) {
          final text = item.toString().trim();
          if (text.isNotEmpty) instructions.add(text);
        }
      }

      return _RouteComputation(
        path: path,
        distanceMeters: (data['distanceMeters'] as num?)?.toDouble() ?? 0.0,
        durationSeconds: (data['durationSeconds'] as num?)?.toDouble() ?? 0.0,
        color: _standardRouteColor(mode),
        width: (mode == 'hiking' || mode == 'portaging') ? 6 : 5,
        zIndex: (mode == 'hiking' || mode == 'portaging') ? 18 : 12,
        instructions: instructions,
      );
    } catch (e) {
      final msg =
          'routeProxy request_failed provider=$provider profile=$profile mode=$mode err=$e';
      if (_strictRouting) _strictRoutingHardError(msg);
      debugPrint(msg);
      return directOrsFallback('proxy_request_failed');
    }
  }

  Future<_RouteComputation?> _routeViaDirectOpenRouteService(
    List<List<double>> coordinates, {
    required String profile,
    required String mode,
    required String reason,
  }) async {
    final key = _resolveOpenRouteServiceKey().trim();
    if (key.isEmpty || coordinates.length < 2) return null;

    final uri = Uri.parse(
      'https://api.openrouteservice.org/v2/directions/$profile/geojson',
    );
    try {
      final resp = await http
          .post(
            uri,
            headers: <String, String>{
              'Authorization': key,
              'Content-Type': 'application/json',
            },
            body: jsonEncode(<String, dynamic>{'coordinates': coordinates}),
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) {
        debugPrint(
          'routeProxy direct_ors_failed profile=$profile mode=$mode '
          'status=${resp.statusCode} reason=$reason',
        );
        return null;
      }

      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final features = (data['features'] as List<dynamic>?) ?? const [];
      if (features.isEmpty) return null;
      final feature = (features.first as Map).cast<String, dynamic>();
      final geometry =
          (feature['geometry'] as Map?)?.cast<String, dynamic>() ?? const {};
      final rawPath = (geometry['coordinates'] as List<dynamic>?) ?? const [];
      final path = <gmaps.LatLng>[];
      for (final pair in rawPath) {
        if (pair is! List || pair.length < 2) continue;
        final lon = (pair[0] as num?)?.toDouble();
        final lat = (pair[1] as num?)?.toDouble();
        if (lat == null || lon == null) continue;
        path.add(gmaps.LatLng(lat, lon));
      }
      if (path.length < 2) return null;

      final props =
          (feature['properties'] as Map?)?.cast<String, dynamic>() ?? const {};
      final summary =
          (props['summary'] as Map?)?.cast<String, dynamic>() ?? const {};
      final instructions = <String>[];
      final segments = (props['segments'] as List<dynamic>?) ?? const [];
      for (final segment in segments) {
        final segmentMap = (segment as Map?)?.cast<String, dynamic>();
        final steps = (segmentMap?['steps'] as List<dynamic>?) ?? const [];
        for (final step in steps) {
          final instruction =
              ((step as Map?)?['instruction'] ?? '').toString().trim();
          if (instruction.isNotEmpty) instructions.add(instruction);
        }
      }

      debugPrint(
        'routeProxy direct_ors_ok profile=$profile mode=$mode '
        'points=${path.length} reason=$reason',
      );
      return _RouteComputation(
        path: path,
        distanceMeters: (summary['distance'] as num?)?.toDouble() ?? 0.0,
        durationSeconds: (summary['duration'] as num?)?.toDouble() ?? 0.0,
        color: _standardRouteColor(mode),
        width: (mode == 'hiking' || mode == 'portaging') ? 6 : 5,
        zIndex: (mode == 'hiking' || mode == 'portaging') ? 18 : 12,
        instructions: instructions,
      );
    } catch (e) {
      debugPrint(
        'routeProxy direct_ors_error profile=$profile mode=$mode '
        'reason=$reason err=$e',
      );
      return null;
    }
  }

  String _routingQueryForPoint(Map<String, dynamic> point) {
    final candidates = <dynamic>[
      point['routing_query'],
      point['display_name'],
      point['formatted_address'],
      point['address'],
      point['vicinity'],
      point['name'],
    ];
    for (final raw in candidates) {
      final value = raw?.toString().trim() ?? '';
      if (value.isEmpty) continue;
      if (RegExp(r'^point\s+\d+$', caseSensitive: false).hasMatch(value)) {
        continue;
      }
      if (RegExp(r'^-?\d+(\.\d+)?\s*,\s*-?\d+(\.\d+)?$').hasMatch(value)) {
        continue;
      }
      return value;
    }
    return '';
  }

  List<gmaps.LatLng> _segmentLatLngs(List<Map<String, dynamic>> segPoints) {
    return segPoints.map((p) => gmaps.LatLng(_latOf(p), _lonOf(p))).toList();
  }

  bool _isFresh(DateTime fetchedAt, Duration ttl) {
    return DateTime.now().difference(fetchedAt) <= ttl;
  }

  double _roundToStep(double value, double step) {
    if (!value.isFinite || step <= 0) return value;
    return (value / step).roundToDouble() * step;
  }

  double _floorToStep(double value, double step) {
    if (!value.isFinite || step <= 0) return value;
    return (value / step).floorToDouble() * step;
  }

  double _ceilToStep(double value, double step) {
    if (!value.isFinite || step <= 0) return value;
    return (value / step).ceilToDouble() * step;
  }

  double _quantizedOverlayPadDegrees(double padDegrees) {
    final normalized = padDegrees.clamp(0.04, 0.24).toDouble();
    return _roundToStep(normalized, 0.02);
  }

  bool _isOverpassEndpointTemporarilyBlocked(String endpoint) {
    final until = _overpassEndpointCooldownUntil[endpoint];
    if (until == null) return false;
    if (DateTime.now().isAfter(until)) {
      _overpassEndpointCooldownUntil.remove(endpoint);
      return false;
    }
    return true;
  }

  void _markOverpassEndpointUnavailable(String endpoint) {
    _overpassUnavailableEndpoints.add(endpoint);
    _overpassEndpointCooldownUntil.remove(endpoint);
  }

  void _coolDownOverpassEndpoint(String endpoint, Duration duration) {
    if (_overpassUnavailableEndpoints.contains(endpoint) ||
        duration <= Duration.zero) {
      return;
    }
    final nextUntil = DateTime.now().add(duration);
    final existing = _overpassEndpointCooldownUntil[endpoint];
    if (existing == null || existing.isBefore(nextUntil)) {
      _overpassEndpointCooldownUntil[endpoint] = nextUntil;
    }
  }

  Duration _overpassCooldownForStatus(
    String endpoint,
    int statusCode, {
    required bool isProxy,
  }) {
    final lowerEndpoint = endpoint.toLowerCase();
    if (isProxy && (statusCode == 404 || statusCode == 405)) {
      _markOverpassEndpointUnavailable(endpoint);
      return Duration.zero;
    }
    if (lowerEndpoint.contains('maps.mail.ru') && statusCode == 403) {
      _markOverpassEndpointUnavailable(endpoint);
      return Duration.zero;
    }
    if (statusCode == 429) return const Duration(minutes: 3);
    if (statusCode == 408 || statusCode == 504) {
      return const Duration(minutes: 2);
    }
    if (statusCode >= 500) return const Duration(minutes: 1);
    if (statusCode == 403) return const Duration(minutes: 30);
    return const Duration(seconds: 45);
  }

  Duration _overpassCooldownForError(
    String endpoint,
    Object error, {
    required bool isProxy,
  }) {
    final err = error.toString();
    if (err.contains('TimeoutException')) return const Duration(minutes: 2);
    if (err.contains('Failed to fetch')) {
      if (isProxy) {
        _markOverpassEndpointUnavailable(endpoint);
        return Duration.zero;
      }
      return const Duration(minutes: 10);
    }
    return const Duration(minutes: 1);
  }

  String _routePointSignature() {
    final b = StringBuffer();
    for (final p in widget.points) {
      b
        ..write(_latOf(p).toStringAsFixed(6))
        ..write(',')
        ..write(_lonOf(p).toStringAsFixed(6))
        ..write(';');
    }
    return b.toString();
  }

  String _pointLabel(Map<String, dynamic> point, {String fallback = 'Stop'}) {
    final name = (point['name'] ?? point['title'] ?? '').toString().trim();
    if (name.isNotEmpty) return name;
    final lat = _latOf(point);
    final lon = _lonOf(point);
    if (lat == 0.0 && lon == 0.0) return fallback;
    return '${lat.toStringAsFixed(4)}, ${lon.toStringAsFixed(4)}';
  }

  String _portageInaccessibleMessage(List<Map<String, dynamic>> segPoints) {
    final startLabel =
        segPoints.isNotEmpty
            ? _pointLabel(segPoints.first, fallback: 'start point')
            : 'start point';
    final endLabel =
        segPoints.length >= 2
            ? _pointLabel(segPoints.last, fallback: 'destination')
            : 'destination';
    return 'Site inaccessible: no mapped waterway or portage connection could be found from $startLabel to $endLabel.';
  }

  void _emitRouteErrorOnce({
    required String signature,
    required String message,
  }) {
    if (signature.isEmpty || signature == _lastRouteErrorSig) return;
    _lastRouteErrorSig = signature;
    widget.onRouteError?.call(message);
  }

  String _routeCalculationSignature() {
    return [
      _routePointSignature(),
      _normalizeTransportMode(widget.transportMode),
      _segmentTransportSignature(widget.segmentTransportModes),
      _segmentRoutingSignature(widget.segmentRoutingTypes),
      _viaSignature(widget.routeVia),
    ].join('|');
  }

  Duration _segmentRouteTimeoutForMode(String mode) {
    final normalized = _normalizeTransportMode(mode);
    switch (normalized) {
      case 'portaging':
        return const Duration(seconds: 24);
      case 'hiking':
        return const Duration(seconds: 22);
      case 'train':
        return const Duration(seconds: 14);
      case 'walk':
      case 'bike':
        return const Duration(seconds: 12);
      case 'car':
      case 'gas_stops':
      default:
        return const Duration(seconds: 18);
    }
  }

  String _segmentRouteCacheKey({
    required String mode,
    required String segType,
    required List<Map<String, dynamic>> segPoints,
  }) {
    final b =
        StringBuffer()
          ..write(_normalizeTransportMode(mode))
          ..write('|')
          ..write(segType.trim().toLowerCase())
          ..write('|');
    for (final p in segPoints) {
      b
        ..write(_latOf(p).toStringAsFixed(6))
        ..write(',')
        ..write(_lonOf(p).toStringAsFixed(6))
        ..write(';');
    }
    return b.toString();
  }

  List<gmaps.LatLng> _downsampleLine(
    List<gmaps.LatLng> line, {
    int maxPoints = 220,
  }) {
    if (line.length <= maxPoints) return line;
    final sampled = <gmaps.LatLng>[];
    final step = math.max(1, line.length ~/ maxPoints);
    for (var i = 0; i < line.length; i += step) {
      sampled.add(line[i]);
    }
    if (sampled.isNotEmpty) {
      final tail = sampled.last;
      final last = line.last;
      if ((tail.latitude - last.latitude).abs() > 1e-8 ||
          (tail.longitude - last.longitude).abs() > 1e-8) {
        sampled.add(last);
      }
    }
    return sampled;
  }

  bool _shouldUseRelativeOverpassProxy(String endpoint) {
    final trimmed = endpoint.trim();
    if (!trimmed.startsWith('/')) return true;
    try {
      final location = html.window.location;
      final host = location.hostname.toString().trim().toLowerCase();
      final port = location.port.toString().trim();
      final isLocalHost = host == 'localhost' || host == '127.0.0.1';
      // `flutter run -d web-server` serves the app directly and does not apply
      // Firebase Hosting rewrites for `/api/*`, so the relative proxy 404s.
      if (isLocalHost && port == '3000') {
        return false;
      }
    } catch (_) {}
    return true;
  }

  Future<Map<String, dynamic>?> _fetchOverpassData({
    required String query,
    required String logPrefix,
    Duration requestTimeout = const Duration(seconds: 9),
    bool ignoreCooldown = false,
  }) async {
    final endpoints = <({String endpoint, bool isProxy})>[
      if (_overpassProxyUrlDefine.trim().isNotEmpty &&
          _shouldUseRelativeOverpassProxy(_overpassProxyUrlDefine))
        (endpoint: _overpassProxyUrlDefine, isProxy: true),
      (endpoint: 'https://overpass-api.de/api/interpreter', isProxy: false),
      (endpoint: 'https://lz4.overpass-api.de/api/interpreter', isProxy: false),
      (
        endpoint: 'https://overpass.private.coffee/api/interpreter',
        isProxy: false,
      ),
      (
        endpoint: 'https://overpass.kumi.systems/api/interpreter',
        isProxy: false,
      ),
    ];
    final deadline = DateTime.now().add(
      Duration(seconds: math.max(requestTimeout.inSeconds + 4, 14)),
    );
    var attemptedAny = false;

    for (final endpointConfig in endpoints) {
      final endpoint = endpointConfig.endpoint.trim();
      if (endpoint.isEmpty) continue;
      if (_overpassUnavailableEndpoints.contains(endpoint)) {
        debugPrint(
          '$logPrefix endpoint_skipped endpoint=$endpoint '
          'proxy=${endpointConfig.isProxy} reason=unavailable',
        );
        continue;
      }
      if (!ignoreCooldown && _isOverpassEndpointTemporarilyBlocked(endpoint)) {
        debugPrint(
          '$logPrefix endpoint_skipped endpoint=$endpoint '
          'proxy=${endpointConfig.isProxy} reason=cooldown',
        );
        continue;
      }

      final remaining = deadline.difference(DateTime.now());
      if (remaining <= const Duration(milliseconds: 250)) {
        break;
      }

      attemptedAny = true;
      final timeout = remaining < requestTimeout ? remaining : requestTimeout;
      final startedAt = DateTime.now();
      try {
        late final http.Response resp;
        if (endpointConfig.isProxy) {
          resp = await http
              .post(
                Uri.parse(endpoint),
                headers: const <String, String>{
                  'Content-Type': 'application/json',
                },
                body: jsonEncode(<String, dynamic>{'query': query}),
              )
              .timeout(timeout);
        } else {
          resp = await http
              .post(
                Uri.parse(endpoint),
                headers: const <String, String>{
                  'Content-Type': 'application/x-www-form-urlencoded',
                },
                body: 'data=${Uri.encodeQueryComponent(query)}',
              )
              .timeout(timeout);
        }
        final elapsedMs = DateTime.now().difference(startedAt).inMilliseconds;
        if (resp.statusCode != 200) {
          final cooldown = _overpassCooldownForStatus(
            endpoint,
            resp.statusCode,
            isProxy: endpointConfig.isProxy,
          );
          if (cooldown > Duration.zero) {
            _coolDownOverpassEndpoint(endpoint, cooldown);
          }
          debugPrint(
            '$logPrefix endpoint_failed endpoint=$endpoint '
            'proxy=${endpointConfig.isProxy} '
            'status=${resp.statusCode} elapsed_ms=$elapsedMs',
          );
          continue;
        }

        final decoded = jsonDecode(resp.body);
        if (decoded is Map<String, dynamic>) {
          debugPrint(
            '$logPrefix endpoint_ok endpoint=$endpoint '
            'proxy=${endpointConfig.isProxy} '
            'bytes=${resp.bodyBytes.length} elapsed_ms=$elapsedMs',
          );
          return decoded;
        }
        if (decoded is Map) {
          debugPrint(
            '$logPrefix endpoint_ok endpoint=$endpoint '
            'proxy=${endpointConfig.isProxy} '
            'bytes=${resp.bodyBytes.length} elapsed_ms=$elapsedMs',
          );
          return (decoded).cast<String, dynamic>();
        }
      } catch (e) {
        final elapsedMs = DateTime.now().difference(startedAt).inMilliseconds;
        final cooldown = _overpassCooldownForError(
          endpoint,
          e,
          isProxy: endpointConfig.isProxy,
        );
        if (cooldown > Duration.zero) {
          _coolDownOverpassEndpoint(endpoint, cooldown);
        }
        debugPrint(
          '$logPrefix endpoint_error endpoint=$endpoint '
          'proxy=${endpointConfig.isProxy} '
          'elapsed_ms=$elapsedMs err=$e',
        );
      }
    }

    debugPrint(
      attemptedAny
          ? '$logPrefix all_endpoints_failed'
          : '$logPrefix all_endpoints_unavailable',
    );
    return null;
  }

  double _adaptivePortageRoutePadDegrees(List<gmaps.LatLng> anchors) {
    if (anchors.isEmpty) return 0.04;
    var minLat = double.infinity;
    var maxLat = -double.infinity;
    var minLon = double.infinity;
    var maxLon = -double.infinity;
    for (final p in anchors) {
      minLat = math.min(minLat, p.latitude);
      maxLat = math.max(maxLat, p.latitude);
      minLon = math.min(minLon, p.longitude);
      maxLon = math.max(maxLon, p.longitude);
    }
    final span = math.max(maxLat - minLat, maxLon - minLon);
    // Keep route fetches compact, but give canoe/backcountry legs enough
    // breathing room to capture nearby lakes, carries, and shoreline detours.
    return (0.03 + (span * 0.22)).clamp(0.05, 0.12).toDouble();
  }

  gmaps.LatLng _routeBoundsCenter(List<gmaps.LatLng> anchors) {
    if (anchors.isEmpty) return const gmaps.LatLng(0, 0);
    var minLat = double.infinity;
    var maxLat = -double.infinity;
    var minLon = double.infinity;
    var maxLon = -double.infinity;
    for (final p in anchors) {
      minLat = math.min(minLat, p.latitude);
      maxLat = math.max(maxLat, p.latitude);
      minLon = math.min(minLon, p.longitude);
      maxLon = math.max(maxLon, p.longitude);
    }
    return gmaps.LatLng((minLat + maxLat) / 2.0, (minLon + maxLon) / 2.0);
  }

  double _routeFocusPadDegrees(
    List<gmaps.LatLng> anchors, {
    required double minPad,
    required double maxPad,
    required double edgePadding,
  }) {
    if (anchors.isEmpty) return minPad;
    var minLat = double.infinity;
    var maxLat = -double.infinity;
    var minLon = double.infinity;
    var maxLon = -double.infinity;
    for (final p in anchors) {
      minLat = math.min(minLat, p.latitude);
      maxLat = math.max(maxLat, p.latitude);
      minLon = math.min(minLon, p.longitude);
      maxLon = math.max(maxLon, p.longitude);
    }
    final span = math.max(maxLat - minLat, maxLon - minLon);
    return (edgePadding + (span / 2.0)).clamp(minPad, maxPad).toDouble();
  }

  _RouteComputation _straightRoute({
    required List<gmaps.LatLng> path,
    required String mode,
    required Color color,
    required int width,
    required List<gmaps.PatternItem> patterns,
    required bool geodesic,
    String? instruction,
  }) {
    var distance = 0.0;
    for (var i = 0; i + 1 < path.length; i++) {
      distance += _haversineMeters(path[i], path[i + 1]);
    }
    return _RouteComputation(
      path: path,
      distanceMeters: distance,
      durationSeconds: 0,
      color: color,
      width: width,
      zIndex: (mode == 'hiking' || mode == 'portaging') ? 16 : 12,
      geodesic: geodesic,
      patterns: patterns,
      instructions:
          instruction == null || instruction.trim().isEmpty
              ? const []
              : [instruction],
    );
  }

  double _polylineDistanceMeters(List<gmaps.LatLng> path) {
    if (path.length < 2) return 0.0;
    var meters = 0.0;
    for (var i = 0; i + 1 < path.length; i++) {
      meters += _haversineMeters(path[i], path[i + 1]);
    }
    return meters;
  }

  gmaps.LatLng _lerpLatLng(gmaps.LatLng a, gmaps.LatLng b, double t) {
    final clamped = t.clamp(0.0, 1.0);
    return gmaps.LatLng(
      a.latitude + (b.latitude - a.latitude) * clamped,
      a.longitude + (b.longitude - a.longitude) * clamped,
    );
  }

  bool _pointInPolygon(gmaps.LatLng point, List<gmaps.LatLng> polygon) {
    if (polygon.length < 4) return false;
    final x = point.longitude;
    final y = point.latitude;
    var inside = false;
    for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      final xi = polygon[i].longitude;
      final yi = polygon[i].latitude;
      final xj = polygon[j].longitude;
      final yj = polygon[j].latitude;
      final denom = (yj - yi).abs() < 1e-12 ? 1e-12 : (yj - yi);
      final intersects =
          ((yi > y) != (yj > y)) && (x < ((xj - xi) * (y - yi)) / denom + xi);
      if (intersects) inside = !inside;
    }
    return inside;
  }

  double _nearestDistanceToLinesMeters(
    gmaps.LatLng point,
    List<List<gmaps.LatLng>> lines,
  ) {
    if (lines.isEmpty) return double.infinity;
    var best = double.infinity;
    for (final line in lines) {
      if (line.isEmpty) continue;
      final meters = _distanceMetersToPath(point, line);
      if (meters < best) best = meters;
      if (best <= 1.0) break;
    }
    return best;
  }

  bool _isLikelyWaterPoint(
    gmaps.LatLng point,
    _PortagingOverlayCacheEntry entry, {
    double lineThresholdMeters = 140.0,
  }) {
    for (final polygon in entry.waterPolygons) {
      if (_pointInPolygon(point, polygon)) return true;
    }
    final nearestWaterLine = _nearestDistanceToLinesMeters(
      point,
      entry.waterLines,
    );
    if (nearestWaterLine <= lineThresholdMeters) return true;
    // Keep route endpoints usable around put-in/take-out points when polygon
    // coverage is sparse.
    final nearestPortageLine = _nearestDistanceToLinesMeters(
      point,
      entry.portageLines,
    );
    return nearestPortageLine <= 40.0;
  }

  bool _isOpenWaterLandingPoint(
    gmaps.LatLng point,
    _PortagingOverlayCacheEntry entry, {
    double lineThresholdMeters = 90.0,
  }) {
    for (final polygon in entry.waterPolygons) {
      if (_pointInPolygon(point, polygon)) return true;
    }
    return _nearestDistanceToLinesMeters(point, entry.waterLines) <=
        lineThresholdMeters;
  }

  bool _isValidPortageConnectorToGraphAnchor({
    required gmaps.LatLng anchor,
    required gmaps.LatLng graphAnchor,
    required _PortagingOverlayCacheEntry entry,
    required bool allowAccessStraightToWater,
  }) {
    final connectorMeters = _haversineMeters(anchor, graphAnchor);
    if (!connectorMeters.isFinite || connectorMeters < 0.0) return false;
    if (connectorMeters <= 6.0) return true;

    final anchorOnNetwork = _isLikelyWaterPoint(
      anchor,
      entry,
      lineThresholdMeters: 120.0,
    );
    if (anchorOnNetwork) {
      return _isWaterSafeDirectSegment(
        anchor,
        graphAnchor,
        entry,
        maxSamples: 18,
      );
    }

    if (!allowAccessStraightToWater &&
        _isLikelyWaterPoint(graphAnchor, entry, lineThresholdMeters: 90.0) &&
        connectorMeters <= 80.0) {
      return true;
    }
    if (!allowAccessStraightToWater) return false;
    if (!_isOpenWaterLandingPoint(graphAnchor, entry)) return false;
    return connectorMeters <= 1200.0;
  }

  bool _isWaterSafeDirectSegment(
    gmaps.LatLng from,
    gmaps.LatLng to,
    _PortagingOverlayCacheEntry entry, {
    int maxSamples = 40,
  }) {
    final directMeters = _haversineMeters(from, to);
    if (!directMeters.isFinite || directMeters <= 1.0) return true;
    if (!_isLikelyWaterPoint(from, entry, lineThresholdMeters: 170.0)) {
      return false;
    }
    final sampleCount = math.max(
      6,
      math.min(maxSamples, (directMeters / 120).round()),
    );
    for (var i = 0; i <= sampleCount; i++) {
      final t = i / sampleCount;
      final point = _lerpLatLng(from, to, t);
      final threshold = i == sampleCount ? 230.0 : 145.0;
      if (!_isLikelyWaterPoint(point, entry, lineThresholdMeters: threshold)) {
        return false;
      }
    }
    return true;
  }

  ({List<gmaps.LatLng> path, double distanceMeters})?
  _trimPortagingPathToWaterOffRamp({
    required List<gmaps.LatLng> path,
    required gmaps.LatLng destination,
    required _PortagingOverlayCacheEntry entry,
  }) {
    if (path.length < 2) return null;
    final originalMeters = _polylineDistanceMeters(path);
    if (!originalMeters.isFinite || originalMeters <= 0.0) return null;

    var traversed = 0.0;
    var bestSegment = -1;
    gmaps.LatLng? bestOffRamp;
    var bestOffRampToDest = double.infinity;
    var bestPrefixMeters = -double.infinity;

    for (var i = 0; i + 1 < path.length; i++) {
      final a = path[i];
      final b = path[i + 1];
      final segmentMeters = _haversineMeters(a, b);
      if (!segmentMeters.isFinite || segmentMeters <= 0.1) {
        continue;
      }
      final offRamp = _projectOnSegment(destination, a, b);
      final offRampToDest = _haversineMeters(offRamp, destination);
      final prefixMeters = traversed + _haversineMeters(a, offRamp);
      final remainingMeters = originalMeters - prefixMeters;
      traversed += segmentMeters;
      if (remainingMeters < 50.0) continue;
      if (!_isWaterSafeDirectSegment(offRamp, destination, entry)) continue;

      final better =
          offRampToDest + 0.5 < bestOffRampToDest ||
          ((offRampToDest - bestOffRampToDest).abs() <= 0.5 &&
              prefixMeters > bestPrefixMeters);
      if (!better) continue;
      bestSegment = i;
      bestOffRamp = offRamp;
      bestOffRampToDest = offRampToDest;
      bestPrefixMeters = prefixMeters;
    }

    if (bestSegment < 0 || bestOffRamp == null) return null;

    final trimmedPath = <gmaps.LatLng>[];
    void appendDistinct(gmaps.LatLng p) {
      if (trimmedPath.isNotEmpty) {
        final last = trimmedPath.last;
        if ((last.latitude - p.latitude).abs() < 1e-7 &&
            (last.longitude - p.longitude).abs() < 1e-7) {
          return;
        }
      }
      trimmedPath.add(p);
    }

    for (var i = 0; i <= bestSegment; i++) {
      appendDistinct(path[i]);
    }
    appendDistinct(bestOffRamp);
    appendDistinct(destination);

    final trimmedMeters = _polylineDistanceMeters(trimmedPath);
    if (!trimmedMeters.isFinite || trimmedMeters <= 0.0) return null;
    final savedMeters = originalMeters - trimmedMeters;
    if (savedMeters < 80.0) return null;
    return (path: trimmedPath, distanceMeters: trimmedMeters);
  }

  _RouteComputation _applyBackcountryDetourGuard({
    required _RouteComputation route,
    required List<gmaps.LatLng> anchors,
    required String mode,
    required String segType,
  }) {
    if (anchors.length < 2) return route;
    if (segType == 'direct') return route;
    final normalizedMode = _normalizeTransportMode(mode);
    if (normalizedMode != 'hiking' && normalizedMode != 'portaging') {
      return route;
    }

    final directMeters = _polylineDistanceMeters(anchors);
    if (!directMeters.isFinite || directMeters <= 0.0) return route;
    final routedMeters =
        route.distanceMeters > 0
            ? route.distanceMeters
            : _polylineDistanceMeters(route.path);
    if (!routedMeters.isFinite || routedMeters <= 0.0) return route;

    final ratio = routedMeters / directMeters;
    final excessMeters = routedMeters - directMeters;
    final ratioLimit = normalizedMode == 'portaging' ? 1.7 : 2.4;
    final minExcessMeters = normalizedMode == 'portaging' ? 800.0 : 1400.0;

    if (ratio <= ratioLimit || excessMeters <= minExcessMeters) return route;

    return _straightRoute(
      path: anchors,
      mode: mode,
      color: _standardRouteColor(mode),
      width: (mode == 'hiking' || mode == 'portaging') ? 6 : 5,
      patterns: const [],
      geodesic: false,
      instruction:
          'Direct fallback: network detour ${(routedMeters / 1000.0).toStringAsFixed(1)} km vs ${(directMeters / 1000.0).toStringAsFixed(1)} km',
    );
  }

  Future<_RouteComputation?> _routeViaGoogleDirections(
    List<Map<String, dynamic>> segPoints, {
    required String mode,
    required String googleMode,
    bool avoidHighways = false,
    bool avoidTolls = false,
  }) async {
    if (segPoints.length < 2) return null;
    try {
      final intermediates =
          segPoints.length > 2
              ? segPoints.sublist(1, segPoints.length - 1)
              : const <Map<String, dynamic>>[];
      final waypoints =
          intermediates.map((p) => [_latOf(p), _lonOf(p)]).toList();
      var result = await directions_web
          .getDirections(
            originLat: _latOf(segPoints.first),
            originLng: _lonOf(segPoints.first),
            destLat: _latOf(segPoints.last),
            destLng: _lonOf(segPoints.last),
            mode: googleMode,
            waypoints: waypoints.isEmpty ? null : waypoints,
            avoidHighways: avoidHighways,
            avoidTolls: avoidTolls,
          )
          .timeout(const Duration(seconds: 8), onTimeout: () => null);
      if (result == null) {
        final originQuery = _routingQueryForPoint(segPoints.first);
        final destQuery = _routingQueryForPoint(segPoints.last);
        final waypointQueries = intermediates
            .map(_routingQueryForPoint)
            .toList(growable: false);
        final hasQueryFallback =
            originQuery.isNotEmpty ||
            destQuery.isNotEmpty ||
            waypointQueries.any((q) => q.isNotEmpty);
        if (hasQueryFallback) {
          result = await directions_web
              .getDirections(
                originLat: _latOf(segPoints.first),
                originLng: _lonOf(segPoints.first),
                destLat: _latOf(segPoints.last),
                destLng: _lonOf(segPoints.last),
                mode: googleMode,
                waypoints: waypoints.isEmpty ? null : waypoints,
                originQuery: originQuery.isEmpty ? null : originQuery,
                destQuery: destQuery.isEmpty ? null : destQuery,
                waypointQueries: waypointQueries,
                avoidHighways: avoidHighways,
                avoidTolls: avoidTolls,
              )
              .timeout(const Duration(seconds: 8), onTimeout: () => null);
        }
      }
      if (result == null || result.polylinePoints.length < 2) return null;
      final path =
          result.polylinePoints.map((p) => gmaps.LatLng(p[0], p[1])).toList();
      return _RouteComputation(
        path: path,
        distanceMeters: result.distanceMeters,
        durationSeconds: result.durationSeconds,
        color: _standardRouteColor(mode),
        width: mode == 'gas_stops' ? 6 : 5,
        zIndex: 12,
        instructions: result.instructions,
        stepDetails: result.stepDetails,
        arrivalStop: result.transitArrivalStop,
      );
    } catch (e) {
      debugPrint('_routeViaGoogleDirections exception mode=$mode err=$e');
      return null;
    }
  }

  Future<_RouteComputation?> _routeViaOpenRouteService(
    List<Map<String, dynamic>> segPoints, {
    required String profile,
    required String mode,
  }) async {
    return _routeViaBackendProxy(
      segPoints,
      provider: 'ors',
      profile: profile,
      mode: mode,
    );
  }

  Future<_RouteComputation?> _routeViaGraphHopperHiking(
    List<Map<String, dynamic>> segPoints,
  ) async {
    return _routeViaBackendProxy(
      segPoints,
      provider: 'graphhopper',
      profile: 'hike',
      mode: 'hiking',
    );
  }

  Future<_RouteComputation?> _routeViaOsrm(
    List<Map<String, dynamic>> segPoints, {
    required String profile,
    required String mode,
  }) async {
    if (_strictRouting) {
      _strictRoutingHardError(
        'osrm_requested mode=$mode profile=$profile segments=${segPoints.length}',
      );
    }
    if (segPoints.length < 2) return null;
    try {
      final coords = segPoints
          .map((p) => '${_lonOf(p)},${_latOf(p)}')
          .join(';');
      final uri = Uri.parse(
        'https://router.project-osrm.org/route/v1/$profile/$coords?overview=full&geometries=geojson',
      );
      final resp = await http.get(uri).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return null;
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final routes = (data['routes'] as List<dynamic>?) ?? const [];
      if (routes.isEmpty) return null;
      final route0 = routes.first as Map<String, dynamic>;
      final dist = (route0['distance'] as num?)?.toDouble() ?? 0.0;
      final dur = (route0['duration'] as num?)?.toDouble() ?? 0.0;
      final geom = route0['geometry'] as Map<String, dynamic>?;
      final coordsList =
          (geom?['coordinates'] as List<dynamic>?)?.cast<List<dynamic>>();
      if (coordsList == null || coordsList.length < 2) return null;
      final path =
          coordsList
              .map(
                (c) => gmaps.LatLng(
                  (c[1] as num).toDouble(),
                  (c[0] as num).toDouble(),
                ),
              )
              .toList();
      return _RouteComputation(
        path: path,
        distanceMeters: dist,
        durationSeconds: dur,
        color: _standardRouteColor(mode),
        width: (mode == 'hiking' || mode == 'portaging') ? 6 : 5,
        zIndex: (mode == 'hiking' || mode == 'portaging') ? 18 : 12,
      );
    } catch (e) {
      if (_strictRouting) {
        _strictRoutingHardError(
          'osrm_request_failed mode=$mode profile=$profile err=$e',
        );
      }
      return null;
    }
  }

  Future<_RouteComputation?> _calculateRouteForSegment({
    required int segmentIndex,
    required List<Map<String, dynamic>> segPoints,
    required String mode,
    required String segType,
  }) async {
    final normalizedMode = _normalizeTransportMode(mode);
    final normalizedType = _normalizeSegmentRoutingType(
      segType,
      mode: normalizedMode,
    );
    final shouldMemoize =
        normalizedType != 'direct' && normalizedMode != 'plane';
    if (!shouldMemoize) {
      return _calculateRouteForSegmentUncached(
        segPoints: segPoints,
        mode: normalizedMode,
        segType: normalizedType,
      );
    }

    final cacheKey =
        '$segmentIndex|${_segmentRouteCacheKey(mode: normalizedMode, segType: normalizedType, segPoints: segPoints)}';
    final cached = _segmentRouteCache[cacheKey];
    if (cached != null && _isFresh(cached.fetchedAt, _segmentRouteCacheTtl)) {
      return cached.route;
    }
    final inFlight = _segmentRouteInFlight[cacheKey];
    if (inFlight != null) {
      return inFlight;
    }

    final future = _calculateRouteForSegmentUncached(
      segPoints: segPoints,
      mode: normalizedMode,
      segType: normalizedType,
    );
    _segmentRouteInFlight[cacheKey] = future;
    try {
      final route = await future;
      if (route != null) {
        _segmentRouteCache[cacheKey] = _SegmentRouteCacheEntry(
          fetchedAt: DateTime.now(),
          route: route,
        );
      }
      return route;
    } finally {
      final current = _segmentRouteInFlight[cacheKey];
      if (identical(current, future)) {
        _segmentRouteInFlight.remove(cacheKey);
      }
    }
  }

  Future<_RouteComputation?> _calculateRouteForSegmentUncached({
    required List<Map<String, dynamic>> segPoints,
    required String mode,
    required String segType,
  }) async {
    final segLatLngs = _segmentLatLngs(segPoints);
    if (segLatLngs.length < 2) return null;

    if (mode == 'plane') {
      final km =
          _straightRoute(
            path: segLatLngs,
            mode: mode,
            color: _standardRouteColor(mode),
            width: 4,
            patterns: [gmaps.PatternItem.dash(14), gmaps.PatternItem.gap(10)],
            geodesic: true,
          ).distanceMeters /
          1000.0;
      return _straightRoute(
        path: segLatLngs,
        mode: mode,
        color: _standardRouteColor(mode),
        width: 4,
        patterns: [gmaps.PatternItem.dash(14), gmaps.PatternItem.gap(10)],
        geodesic: true,
        instruction: 'Flight distance: ${km.toStringAsFixed(1)} km',
      );
    }

    if (segType == 'direct') {
      return _straightRoute(
        path: segLatLngs,
        mode: mode,
        color: _standardRouteColor(mode),
        width: (mode == 'hiking' || mode == 'portaging') ? 6 : 4,
        patterns: [gmaps.PatternItem.dash(18), gmaps.PatternItem.gap(10)],
        geodesic: true,
      );
    }

    if (mode == 'car' || mode == 'gas_stops') {
      return await _routeViaGoogleDirections(
            segPoints,
            mode: mode,
            googleMode: 'driving',
          ) ??
          await _routeViaOsrm(segPoints, profile: 'driving', mode: mode);
    }

    if (mode == 'train') {
      return await _routeViaGoogleDirections(
            segPoints,
            mode: mode,
            googleMode: 'transit',
          ) ??
          await _routeViaOpenRouteService(
            segPoints,
            profile: 'rail',
            mode: mode,
          ) ??
          await _routeViaOpenRouteService(
            segPoints,
            profile: 'driving-car',
            mode: mode,
          ) ??
          await _routeViaGoogleDirections(
            segPoints,
            mode: 'car',
            googleMode: 'driving',
          );
    }

    if (mode == 'walk') {
      return await _routeViaGoogleDirections(
            segPoints,
            mode: mode,
            googleMode: 'walking',
          ) ??
          await _routeViaOpenRouteService(
            segPoints,
            profile: 'foot-walking',
            mode: mode,
          );
    }

    if (mode == 'bike') {
      return await _routeViaGoogleDirections(
            segPoints,
            mode: mode,
            googleMode: 'bicycling',
            avoidHighways: true,
            avoidTolls: true,
          ) ??
          await _routeViaOpenRouteService(
            segPoints,
            profile: 'cycling',
            mode: mode,
          ) ??
          await _routeViaOpenRouteService(
            segPoints,
            profile: 'cycling-regular',
            mode: mode,
          ) ??
          await _routeViaOsrm(segPoints, profile: 'cycling', mode: mode) ??
          await _routeViaGoogleDirections(
            segPoints,
            mode: mode,
            googleMode: 'driving',
            avoidHighways: true,
            avoidTolls: true,
          );
    }

    if (mode == 'hiking') {
      if (segType == 'trails') {
        return _routeViaTrailGraph(segPoints, modeContext: mode);
      }
      _RouteComputation? route;
      final hasOrsKey = _resolveOpenRouteServiceKey().trim().isNotEmpty;
      final hasGraphHopperKey = _resolveGraphHopperKey().trim().isNotEmpty;

      if (hasOrsKey) {
        route =
            await _routeViaOpenRouteService(
              segPoints,
              profile: 'foot-hiking',
              mode: mode,
            ) ??
            await _routeViaOpenRouteService(
              segPoints,
              profile: 'foot-walking',
              mode: mode,
            );
        if (route != null) return route;
      }

      if (hasGraphHopperKey) {
        route = await _routeViaGraphHopperHiking(segPoints);
        if (route != null) return route;
      }

      return _routeViaTrailGraph(segPoints, modeContext: mode);
    }

    if (mode == 'portaging') {
      final networkRoute = await _routeViaPortageGraph(segPoints);
      if (networkRoute != null) return networkRoute;
      debugPrint(
        'portageRoute unavailable_after_network_only points=${segPoints.length}',
      );
      return null;
    }

    return await _routeViaGoogleDirections(
      segPoints,
      mode: 'car',
      googleMode: 'driving',
    );
  }

  String _pathSignature(List<gmaps.LatLng> path, {int sample = 14}) {
    if (path.isEmpty) return '';
    final step = math.max(1, path.length ~/ sample);
    final b = StringBuffer();
    for (var i = 0; i < path.length; i += step) {
      final p = path[i];
      b
        ..write(p.latitude.toStringAsFixed(4))
        ..write(',')
        ..write(p.longitude.toStringAsFixed(4))
        ..write(';');
    }
    final last = path.last;
    b
      ..write(last.latitude.toStringAsFixed(4))
      ..write(',')
      ..write(last.longitude.toStringAsFixed(4));
    return b.toString();
  }

  List<gmaps.LatLng> _flattenRouteForMode(
    Map<int, List<gmaps.LatLng>> segGeometry,
    String mode,
  ) {
    final wanted = _normalizeTransportMode(mode);
    final keys = segGeometry.keys.toList()..sort();
    final out = <gmaps.LatLng>[];
    for (final seg in keys) {
      if (_segmentTransportModeFor(seg) != wanted) continue;
      final path = segGeometry[seg] ?? const <gmaps.LatLng>[];
      for (final p in path) {
        if (out.isNotEmpty) {
          final last = out.last;
          if ((last.latitude - p.latitude).abs() < 1e-7 &&
              (last.longitude - p.longitude).abs() < 1e-7) {
            continue;
          }
        }
        out.add(p);
      }
    }
    return out;
  }

  List<gmaps.LatLng> _anchorPathForMode(String mode) {
    final target = _normalizeTransportMode(mode);
    final segments = widget.points.length > 1 ? widget.points.length - 1 : 0;
    final out = <gmaps.LatLng>[];
    for (var seg = 0; seg < segments; seg++) {
      if (_segmentTransportModeFor(seg) != target) continue;
      final segPoints = _segmentPoints(afterIndex: seg);
      for (final p in segPoints) {
        final lat = _latOf(p);
        final lon = _lonOf(p);
        if (!lat.isFinite || !lon.isFinite) continue;
        if (out.isNotEmpty) {
          final last = out.last;
          if ((last.latitude - lat).abs() < 1e-7 &&
              (last.longitude - lon).abs() < 1e-7) {
            continue;
          }
        }
        out.add(gmaps.LatLng(lat, lon));
      }
    }
    return out;
  }

  List<gmaps.LatLng> _hikingAnchorPath(
    Map<int, List<gmaps.LatLng>> segGeometry,
  ) {
    final routePath = _flattenRouteForMode(segGeometry, 'hiking');
    if (routePath.isNotEmpty) return routePath;

    final anchors = <gmaps.LatLng>[];
    for (final p in widget.points) {
      final lat = _latOf(p);
      final lon = _lonOf(p);
      if (!lat.isFinite || !lon.isFinite) continue;
      anchors.add(gmaps.LatLng(lat, lon));
    }
    return anchors;
  }

  double _trailRoutePadDegreesForMode(
    String modeContext, {
    bool expanded = false,
  }) {
    final normalized = _normalizeTransportMode(modeContext);
    if (normalized == 'portaging') {
      return expanded ? 0.16 : 0.10;
    }
    return expanded ? 0.14 : 0.08;
  }

  String _hikingCacheKey(
    List<gmaps.LatLng> routePath, {
    double padDegrees = 0.08,
  }) {
    var minLat = double.infinity;
    var maxLat = -double.infinity;
    var minLon = double.infinity;
    var maxLon = -double.infinity;
    for (final p in routePath) {
      minLat = math.min(minLat, p.latitude);
      maxLat = math.max(maxLat, p.latitude);
      minLon = math.min(minLon, p.longitude);
      maxLon = math.max(maxLon, p.longitude);
    }
    final bucketSize = math.max(0.02, padDegrees / 2.0);
    final south = _floorToStep(minLat - padDegrees, bucketSize);
    final west = _floorToStep(minLon - padDegrees, bucketSize);
    final north = _ceilToStep(maxLat + padDegrees, bucketSize);
    final east = _ceilToStep(maxLon + padDegrees, bucketSize);
    return '${south.toStringAsFixed(3)},${west.toStringAsFixed(3)},'
        '${north.toStringAsFixed(3)},${east.toStringAsFixed(3)}';
  }

  double _distanceMetersToPath(gmaps.LatLng point, List<gmaps.LatLng> path) {
    if (path.isEmpty) return double.infinity;
    if (path.length == 1) return _haversineMeters(point, path.first);
    var best = double.infinity;
    for (var i = 0; i + 1 < path.length; i++) {
      final projected = _projectOnSegment(point, path[i], path[i + 1]);
      final meters = _haversineMeters(point, projected);
      if (meters < best) best = meters;
    }
    return best;
  }

  double _distanceLineToPathMeters(
    List<gmaps.LatLng> line,
    List<gmaps.LatLng> path, {
    int maxSamples = 28,
  }) {
    if (line.isEmpty || path.isEmpty) return double.infinity;
    var best = double.infinity;
    final step = math.max(1, line.length ~/ maxSamples);
    for (var i = 0; i < line.length; i += step) {
      final d = _distanceMetersToPath(line[i], path);
      if (d < best) best = d;
      if (best <= 1.0) break;
    }
    final tail = line.last;
    final tailDist = _distanceMetersToPath(tail, path);
    if (tailDist < best) best = tailDist;
    return best;
  }

  _LineProjection? _nearestProjectionOnLine(
    gmaps.LatLng anchor,
    List<gmaps.LatLng> line, {
    double maxAnchorMeters = double.infinity,
  }) {
    if (line.length < 2) return null;
    _LineProjection? best;
    var bestMeters = double.infinity;
    for (var i = 0; i + 1 < line.length; i++) {
      final projected = _projectOnSegment(anchor, line[i], line[i + 1]);
      final meters = _haversineMeters(anchor, projected);
      if (!meters.isFinite || meters >= bestMeters) continue;
      bestMeters = meters;
      best = _LineProjection(
        point: projected,
        segmentIndex: i,
        anchorMeters: meters,
      );
    }
    if (best == null || best.anchorMeters > maxAnchorMeters) {
      return null;
    }
    return best;
  }

  List<gmaps.LatLng> _sliceLineBetweenProjections(
    List<gmaps.LatLng> line,
    _LineProjection start,
    _LineProjection end,
  ) {
    if (line.length < 2) return const <gmaps.LatLng>[];
    final out = <gmaps.LatLng>[];

    void appendDistinct(gmaps.LatLng point) {
      if (out.isNotEmpty) {
        final last = out.last;
        if ((last.latitude - point.latitude).abs() < 1e-7 &&
            (last.longitude - point.longitude).abs() < 1e-7) {
          return;
        }
      }
      out.add(point);
    }

    appendDistinct(start.point);
    if (start.segmentIndex == end.segmentIndex) {
      appendDistinct(end.point);
      return out;
    }

    if (start.segmentIndex < end.segmentIndex) {
      for (var i = start.segmentIndex + 1; i <= end.segmentIndex; i++) {
        appendDistinct(line[i]);
      }
      appendDistinct(end.point);
      return out;
    }

    for (var i = start.segmentIndex; i > end.segmentIndex; i--) {
      appendDistinct(line[i]);
    }
    appendDistinct(end.point);
    return out;
  }

  ({List<gmaps.LatLng> path, double distanceMeters})?
  _fastTrailRouteAlongSameLine({
    required gmaps.LatLng start,
    required gmaps.LatLng end,
    required List<List<gmaps.LatLng>> trailLines,
    double maxAnchorMeters = 1200.0,
    double maxLineDistanceMeters = 1600.0,
    double maxTotalMeters = 36000.0,
  }) {
    final directMeters = _haversineMeters(start, end);
    if (!directMeters.isFinite || directMeters <= 0.0) return null;

    ({List<gmaps.LatLng> path, double distanceMeters})? best;
    for (final line in trailLines) {
      if (line.length < 2) continue;
      final lineDistance = _distanceLineToPathMeters(line, <gmaps.LatLng>[
        start,
        end,
      ], maxSamples: 8);
      if (!lineDistance.isFinite || lineDistance > maxLineDistanceMeters) {
        continue;
      }

      final startProjection = _nearestProjectionOnLine(
        start,
        line,
        maxAnchorMeters: maxAnchorMeters,
      );
      if (startProjection == null) continue;
      final endProjection = _nearestProjectionOnLine(
        end,
        line,
        maxAnchorMeters: maxAnchorMeters,
      );
      if (endProjection == null) continue;

      final linePath = _sliceLineBetweenProjections(
        line,
        startProjection,
        endProjection,
      );
      if (linePath.length < 2) continue;

      final fullPath = <gmaps.LatLng>[];
      void appendDistinct(gmaps.LatLng point) {
        if (fullPath.isNotEmpty) {
          final last = fullPath.last;
          if ((last.latitude - point.latitude).abs() < 1e-7 &&
              (last.longitude - point.longitude).abs() < 1e-7) {
            return;
          }
        }
        fullPath.add(point);
      }

      appendDistinct(start);
      for (final point in linePath) {
        appendDistinct(point);
      }
      appendDistinct(end);

      final totalMeters = _polylineDistanceMeters(fullPath);
      if (!totalMeters.isFinite || totalMeters <= 0.0) continue;
      if (totalMeters > maxTotalMeters) continue;
      if (totalMeters > math.max(directMeters * 4.5, directMeters + 5000.0)) {
        continue;
      }

      if (best == null || totalMeters < best.distanceMeters) {
        best = (path: fullPath, distanceMeters: totalMeters);
      }
    }

    return best;
  }

  ({List<gmaps.LatLng> path, double distanceMeters, String lineKind})?
  _fastPortageRouteAlongSameLine({
    required gmaps.LatLng start,
    required gmaps.LatLng end,
    required List<List<gmaps.LatLng>> waterLines,
    required List<List<gmaps.LatLng>> portageLines,
    required _PortagingOverlayCacheEntry entry,
    double maxAnchorMeters = 2200.0,
    double maxLineDistanceMeters = 2800.0,
    double maxTotalMeters = 42000.0,
  }) {
    final directMeters = _haversineMeters(start, end);
    if (!directMeters.isFinite || directMeters <= 0.0) return null;

    ({List<gmaps.LatLng> path, double distanceMeters, String lineKind})? best;
    final sources = <({String kind, List<List<gmaps.LatLng>> lines})>[
      (kind: 'water', lines: waterLines),
      (kind: 'portage', lines: portageLines),
    ];

    for (final source in sources) {
      for (final line in source.lines) {
        if (line.length < 2) continue;
        final lineDistance = _distanceLineToPathMeters(line, <gmaps.LatLng>[
          start,
          end,
        ], maxSamples: 8);
        if (!lineDistance.isFinite || lineDistance > maxLineDistanceMeters) {
          continue;
        }

        final startProjection = _nearestProjectionOnLine(
          start,
          line,
          maxAnchorMeters: maxAnchorMeters,
        );
        if (startProjection == null) continue;
        final endProjection = _nearestProjectionOnLine(
          end,
          line,
          maxAnchorMeters: maxAnchorMeters,
        );
        if (endProjection == null) continue;

        if (startProjection.anchorMeters > 40.0 &&
            !_isWaterSafeDirectSegment(
              start,
              startProjection.point,
              entry,
              maxSamples: 14,
            )) {
          continue;
        }
        if (endProjection.anchorMeters > 40.0 &&
            !_isWaterSafeDirectSegment(
              endProjection.point,
              end,
              entry,
              maxSamples: 14,
            )) {
          continue;
        }

        final linePath = _sliceLineBetweenProjections(
          line,
          startProjection,
          endProjection,
        );
        if (linePath.length < 2) continue;

        final fullPath = <gmaps.LatLng>[];
        void appendDistinct(gmaps.LatLng point) {
          if (fullPath.isNotEmpty) {
            final last = fullPath.last;
            if ((last.latitude - point.latitude).abs() < 1e-7 &&
                (last.longitude - point.longitude).abs() < 1e-7) {
              return;
            }
          }
          fullPath.add(point);
        }

        appendDistinct(start);
        for (final point in linePath) {
          appendDistinct(point);
        }
        appendDistinct(end);

        final totalMeters = _polylineDistanceMeters(fullPath);
        if (!totalMeters.isFinite || totalMeters <= 0.0) continue;
        if (totalMeters > maxTotalMeters) continue;
        if (totalMeters > math.max(directMeters * 4.0, directMeters + 6000.0)) {
          continue;
        }

        if (best == null || totalMeters < best.distanceMeters) {
          best = (
            path: fullPath,
            distanceMeters: totalMeters,
            lineKind: source.kind,
          );
        }
      }
    }

    return best;
  }

  bool _isLikelyWaterEndpointForPortage(
    gmaps.LatLng point,
    _PortagingOverlayCacheEntry entry,
  ) {
    for (final polygon in entry.waterPolygons) {
      if (_pointInPolygon(point, polygon)) return true;
    }
    return _nearestDistanceToLinesMeters(point, entry.waterLines) <= 240.0;
  }

  List<({gmaps.LatLng point, double connectorMeters})>
  _portageWaterEntryCandidatesForAnchor({
    required gmaps.LatLng anchor,
    required gmaps.LatLng destination,
    required List<List<gmaps.LatLng>> waterLines,
    required _PortagingOverlayCacheEntry entry,
    int maxCandidates = 8,
    double maxAnchorMeters = 6500.0,
    double maxLineDistanceMeters = 9000.0,
  }) {
    final byKey = <String, ({gmaps.LatLng point, double connectorMeters})>{};

    void addCandidate(gmaps.LatLng point, double connectorMeters) {
      if (!connectorMeters.isFinite || connectorMeters < 0) return;
      if (connectorMeters > maxAnchorMeters) return;
      final key = _latLngMergeKey(point, decimals: 5);
      final existing = byKey[key];
      if (existing == null || connectorMeters < existing.connectorMeters) {
        byKey[key] = (point: point, connectorMeters: connectorMeters);
      }
    }

    if (_isLikelyWaterPoint(anchor, entry, lineThresholdMeters: 180.0)) {
      addCandidate(anchor, 0.0);
    }

    final shortlisted = <({List<gmaps.LatLng> line, double distance})>[];
    for (final line in waterLines) {
      if (line.length < 2) continue;
      final lineDistance = _distanceMetersToPath(anchor, line);
      if (!lineDistance.isFinite || lineDistance > maxLineDistanceMeters) {
        continue;
      }
      shortlisted.add((line: line, distance: lineDistance));
    }
    shortlisted.sort((a, b) => a.distance.compareTo(b.distance));

    final lineCap = math.max(maxCandidates * 2, 12);
    for (var i = 0; i < shortlisted.length && i < lineCap; i++) {
      final projection = _nearestProjectionOnLine(
        anchor,
        shortlisted[i].line,
        maxAnchorMeters: maxAnchorMeters,
      );
      if (projection == null) continue;
      addCandidate(projection.point, projection.anchorMeters);
    }

    final out = byKey.values.toList(growable: false)..sort((a, b) {
      final scoreA =
          a.connectorMeters + (_haversineMeters(a.point, destination) * 0.08);
      final scoreB =
          b.connectorMeters + (_haversineMeters(b.point, destination) * 0.08);
      return scoreA.compareTo(scoreB);
    });
    if (out.length > maxCandidates) {
      return out.sublist(0, maxCandidates);
    }
    return out;
  }

  ({List<gmaps.LatLng> path, double distanceMeters}) _combinePortageLegPaths(
    List<_PortageWaterFirstLegSolution> legs,
  ) {
    final combined = <gmaps.LatLng>[];
    var totalMeters = 0.0;

    void appendDistinct(gmaps.LatLng point) {
      if (combined.isNotEmpty) {
        final last = combined.last;
        if ((last.latitude - point.latitude).abs() < 1e-7 &&
            (last.longitude - point.longitude).abs() < 1e-7) {
          return;
        }
      }
      combined.add(point);
    }

    for (final leg in legs) {
      for (final point in leg.path) {
        appendDistinct(point);
      }
      totalMeters += leg.distanceMeters;
    }

    return (path: combined, distanceMeters: totalMeters);
  }

  _PortageWaterFirstLegSolution? _solveWaterFirstPortageLeg({
    required gmaps.LatLng start,
    required gmaps.LatLng end,
    required List<List<gmaps.LatLng>> waterLines,
    required List<List<gmaps.LatLng>> portageLines,
    required _PortagingOverlayCacheEntry entry,
  }) {
    final directMeters = _haversineMeters(start, end);
    if (!directMeters.isFinite || directMeters <= 0.0) return null;

    final filteredWaterLines = <List<gmaps.LatLng>>[
      for (final line in waterLines)
        if (line.length >= 2) line,
    ];
    final filteredPortageLines = <List<gmaps.LatLng>>[
      for (final line in portageLines)
        if (line.length >= 2 &&
            _isLikelyWaterEndpointForPortage(line.first, entry) &&
            _isLikelyWaterEndpointForPortage(line.last, entry))
          line,
    ];

    final startWaterEntries = _portageWaterEntryCandidatesForAnchor(
      anchor: start,
      destination: end,
      waterLines: filteredWaterLines,
      entry: entry,
    );
    final endWaterEntries = _portageWaterEntryCandidatesForAnchor(
      anchor: end,
      destination: start,
      waterLines: filteredWaterLines,
      entry: entry,
    );

    final networkLines = <List<gmaps.LatLng>>[
      ...filteredWaterLines,
      ...filteredPortageLines,
    ];
    if (networkLines.isEmpty) {
      if (startWaterEntries.isNotEmpty &&
          endWaterEntries.isNotEmpty &&
          _isWaterSafeDirectSegment(start, end, entry, maxSamples: 18)) {
        return _PortageWaterFirstLegSolution(
          path: <gmaps.LatLng>[start, end],
          distanceMeters: directMeters,
        );
      }
      return null;
    }

    final nodes = <gmaps.LatLng>[];
    final nodeIndexByKey = <String, int>{};
    final typedAdjacency = <List<_PortageWaterFirstEdge>>[];

    int ensureNode(gmaps.LatLng point) {
      final key = _trailNodeKey(point);
      final existing = nodeIndexByKey[key];
      if (existing != null) return existing;
      final nextIndex = nodes.length;
      nodes.add(point);
      nodeIndexByKey[key] = nextIndex;
      typedAdjacency.add(<_PortageWaterFirstEdge>[]);
      return nextIndex;
    }

    void addBidirectionalSegment(
      gmaps.LatLng fromPoint,
      gmaps.LatLng toPoint, {
      required bool isCarry,
    }) {
      final from = ensureNode(fromPoint);
      final to = ensureNode(toPoint);
      if (from == to) return;
      final meters = _haversineMeters(fromPoint, toPoint);
      if (!meters.isFinite || meters <= 0.5) return;
      typedAdjacency[from].add(
        _PortageWaterFirstEdge(
          to: to,
          meters: meters,
          path: <gmaps.LatLng>[fromPoint, toPoint],
          isCarry: isCarry,
        ),
      );
      typedAdjacency[to].add(
        _PortageWaterFirstEdge(
          to: from,
          meters: meters,
          path: <gmaps.LatLng>[toPoint, fromPoint],
          isCarry: isCarry,
        ),
      );
    }

    for (final line in filteredWaterLines) {
      var previous = line.first;
      ensureNode(previous);
      for (var i = 1; i < line.length; i++) {
        final current = line[i];
        addBidirectionalSegment(previous, current, isCarry: false);
        previous = current;
      }
    }
    for (final line in filteredPortageLines) {
      var previous = line.first;
      ensureNode(previous);
      for (var i = 1; i < line.length; i++) {
        final current = line[i];
        addBidirectionalSegment(previous, current, isCarry: true);
        previous = current;
      }
    }

    if (nodes.length < 2) {
      if (startWaterEntries.isNotEmpty &&
          endWaterEntries.isNotEmpty &&
          filteredPortageLines.isEmpty &&
          _isWaterSafeDirectSegment(start, end, entry, maxSamples: 18)) {
        return _PortageWaterFirstLegSolution(
          path: <gmaps.LatLng>[start, end],
          distanceMeters: directMeters,
        );
      }
      return null;
    }

    final weightedAdjacency = typedAdjacency
        .map(
          (edges) => edges
              .map(
                (edge) => _TrailEdge(
                  to: edge.to,
                  meters:
                      edge.isCarry ? (edge.meters * 1.55) + 120.0 : edge.meters,
                ),
              )
              .toList(growable: false),
        )
        .toList(growable: false);
    final spatialIndex = _TrailSpatialIndex.fromNodes(nodes);
    final accessCoords = <gmaps.LatLng>[
      for (final access in entry.accessPoints)
        if ((access['lat'] as num?)?.toDouble() != null &&
            (access['lon'] as num?)?.toDouble() != null)
          gmaps.LatLng(
            (access['lat'] as num).toDouble(),
            (access['lon'] as num).toDouble(),
          ),
    ];
    final startAnchor = _resolvePortagingGraphAnchor(
      start,
      nodes,
      spatialIndex,
      accessCoords,
    );
    final endAnchor = _resolvePortagingGraphAnchor(
      end,
      nodes,
      spatialIndex,
      accessCoords,
    );
    final candidateRadii = <double>[2500, 5000, 9000, 15000];
    final startCandidates = _mergePortageCandidateGroups([
      _portageGraphCandidatesForAnchor(
        anchor: start,
        nodes: nodes,
        spatialIndex: spatialIndex,
        accessPoints: accessCoords,
        entry: entry,
        limit: 5,
        radiiMeters: candidateRadii,
        maxGlobalFallbackMeters: 10000,
      ),
      _snapPortageCandidatesToSegments(
        anchor: start,
        lines: networkLines,
        nodeIndexByKey: nodeIndexByKey,
        entry: entry,
        limit: 5,
        maxAnchorMeters: 9500.0,
        maxLineDistanceMeters: 10000.0,
        maxAlongSegmentMeters: 20000.0,
        resolvedAnchor: startAnchor,
      ),
    ], softLimit: 10);
    final endCandidates = _mergePortageCandidateGroups([
      _portageGraphCandidatesForAnchor(
        anchor: end,
        nodes: nodes,
        spatialIndex: spatialIndex,
        accessPoints: accessCoords,
        entry: entry,
        limit: 5,
        radiiMeters: candidateRadii,
        maxGlobalFallbackMeters: 10000,
      ),
      _snapPortageCandidatesToSegments(
        anchor: end,
        lines: networkLines,
        nodeIndexByKey: nodeIndexByKey,
        entry: entry,
        limit: 5,
        maxAnchorMeters: 9500.0,
        maxLineDistanceMeters: 10000.0,
        maxAlongSegmentMeters: 20000.0,
        resolvedAnchor: endAnchor,
      ),
    ], softLimit: 10);

    if (startCandidates.isEmpty || endCandidates.isEmpty) {
      final sameLineRoute = _fastPortageRouteAlongSameLine(
        start: start,
        end: end,
        waterLines: filteredWaterLines,
        portageLines: filteredPortageLines,
        entry: entry,
        maxAnchorMeters: 3200.0,
        maxLineDistanceMeters: 3600.0,
        maxTotalMeters: math.max(directMeters * 4.0, directMeters + 7000.0),
      );
      if (sameLineRoute != null) {
        return _PortageWaterFirstLegSolution(
          path: sameLineRoute.path,
          distanceMeters: sameLineRoute.distanceMeters,
        );
      }
      if (filteredPortageLines.isEmpty &&
          startWaterEntries.isNotEmpty &&
          endWaterEntries.isNotEmpty &&
          _isWaterSafeDirectSegment(start, end, entry, maxSamples: 18)) {
        return _PortageWaterFirstLegSolution(
          path: <gmaps.LatLng>[start, end],
          distanceMeters: directMeters,
        );
      }
      return null;
    }

    List<int>? bestPrev;
    _PortageGraphCandidate? bestStartCandidate;
    _PortageGraphCandidate? bestEndCandidate;
    var bestStartNode = -1;
    var bestEndNode = -1;
    var bestWeightedScore = double.infinity;
    final endNodeSet =
        endCandidates.map((candidate) => candidate.index).toSet();

    for (final startCandidate in startCandidates) {
      final tree = _shortestTrailTreeFromSource(
        startCandidate.index,
        weightedAdjacency,
        stopNodes: endNodeSet,
      );
      for (final endCandidate in endCandidates) {
        final weightedMeters = tree.dist[endCandidate.index];
        if (!weightedMeters.isFinite) continue;
        final weightedScore =
            startCandidate.totalConnectorMeters +
            weightedMeters +
            endCandidate.totalConnectorMeters;
        if (weightedScore < bestWeightedScore) {
          bestWeightedScore = weightedScore;
          bestPrev = tree.prev;
          bestStartCandidate = startCandidate;
          bestEndCandidate = endCandidate;
          bestStartNode = startCandidate.index;
          bestEndNode = endCandidate.index;
        }
      }
    }

    if (bestPrev == null ||
        bestStartCandidate == null ||
        bestEndCandidate == null ||
        bestStartNode < 0 ||
        bestEndNode < 0) {
      final sameLineRoute = _fastPortageRouteAlongSameLine(
        start: start,
        end: end,
        waterLines: filteredWaterLines,
        portageLines: filteredPortageLines,
        entry: entry,
        maxAnchorMeters: 3200.0,
        maxLineDistanceMeters: 3600.0,
        maxTotalMeters: math.max(directMeters * 4.0, directMeters + 7000.0),
      );
      if (sameLineRoute != null) {
        return _PortageWaterFirstLegSolution(
          path: sameLineRoute.path,
          distanceMeters: sameLineRoute.distanceMeters,
        );
      }
      if (filteredPortageLines.isEmpty &&
          startWaterEntries.isNotEmpty &&
          endWaterEntries.isNotEmpty &&
          _isWaterSafeDirectSegment(start, end, entry, maxSamples: 18)) {
        return _PortageWaterFirstLegSolution(
          path: <gmaps.LatLng>[start, end],
          distanceMeters: directMeters,
        );
      }
      return null;
    }
    if (!_isValidPortageConnectorToGraphAnchor(
          anchor: start,
          graphAnchor: bestStartCandidate.graphAnchor,
          entry: entry,
          allowAccessStraightToWater: bestStartCandidate.usedAccess,
        ) ||
        !_isValidPortageConnectorToGraphAnchor(
          anchor: end,
          graphAnchor: bestEndCandidate.graphAnchor,
          entry: entry,
          allowAccessStraightToWater: bestEndCandidate.usedAccess,
        )) {
      return null;
    }

    final nodePath = _reconstructTrailNodePath(
      bestStartNode,
      bestEndNode,
      bestPrev,
    );
    if (nodePath == null || nodePath.isEmpty) return null;
    final graphPath = nodePath
        .map((nodeIndex) => nodes[nodeIndex])
        .toList(growable: false);
    final graphMeters = _polylineDistanceMeters(graphPath);
    if (!graphMeters.isFinite || graphMeters <= 0.0) return null;

    final path = <gmaps.LatLng>[];
    void appendDistinct(gmaps.LatLng point) {
      if (path.isNotEmpty) {
        final last = path.last;
        if ((last.latitude - point.latitude).abs() < 1e-7 &&
            (last.longitude - point.longitude).abs() < 1e-7) {
          return;
        }
      }
      path.add(point);
    }

    appendDistinct(start);
    if (_haversineMeters(start, bestStartCandidate.graphAnchor) > 5.0) {
      appendDistinct(bestStartCandidate.graphAnchor);
    }
    for (final point in graphPath) {
      appendDistinct(point);
    }
    if (_haversineMeters(bestEndCandidate.graphAnchor, end) > 5.0) {
      appendDistinct(bestEndCandidate.graphAnchor);
    }
    appendDistinct(end);

    final totalMeters =
        bestStartCandidate.totalConnectorMeters +
        graphMeters +
        bestEndCandidate.totalConnectorMeters;

    if (path.length < 2 || !totalMeters.isFinite || totalMeters <= 0.0) {
      return null;
    }

    final maxReasonableMeters = math.max(
      directMeters * 5.5,
      directMeters + 12000.0,
    );
    if (totalMeters > maxReasonableMeters) {
      return null;
    }

    return _PortageWaterFirstLegSolution(
      path: path,
      distanceMeters: totalMeters,
    );
  }

  double _segmentDistanceToPathMeters(
    gmaps.LatLng a,
    gmaps.LatLng b,
    List<gmaps.LatLng> path,
  ) {
    if (path.isEmpty) return double.infinity;
    final midpoint = gmaps.LatLng(
      (a.latitude + b.latitude) / 2.0,
      (a.longitude + b.longitude) / 2.0,
    );
    final startMeters = _distanceMetersToPath(a, path);
    final middleMeters = _distanceMetersToPath(midpoint, path);
    final endMeters = _distanceMetersToPath(b, path);
    return math.min(middleMeters, (startMeters + endMeters) / 2.0);
  }

  double _segmentDistanceToLineSetMeters(
    gmaps.LatLng a,
    gmaps.LatLng b,
    List<List<gmaps.LatLng>> lines,
  ) {
    if (lines.isEmpty) return double.infinity;
    var best = double.infinity;
    for (final line in lines) {
      if (line.length < 2) continue;
      final meters = _segmentDistanceToPathMeters(a, b, line);
      if (meters < best) best = meters;
      if (best <= 3.0) break;
    }
    return best;
  }

  List<List<gmaps.LatLng>> _routeLinesNearPath(
    List<List<gmaps.LatLng>> lines,
    List<gmaps.LatLng> path, {
    double maxDistanceMeters = 120.0,
  }) {
    if (lines.isEmpty || path.length < 2) return const [];
    final out = <List<gmaps.LatLng>>[];
    for (final line in lines) {
      if (line.length < 2) continue;
      final distance = _distanceLineToPathMeters(line, path, maxSamples: 20);
      if (distance <= maxDistanceMeters) {
        out.add(line);
      }
    }
    return out;
  }

  bool _isPortagingCarryEdge({
    required gmaps.LatLng start,
    required gmaps.LatLng end,
    required List<List<gmaps.LatLng>> nearbyPortageLines,
    required List<List<gmaps.LatLng>> nearbyWaterLines,
  }) {
    if (nearbyPortageLines.isEmpty) return false;
    final portageMeters = _segmentDistanceToLineSetMeters(
      start,
      end,
      nearbyPortageLines,
    );
    if (!portageMeters.isFinite || portageMeters > 45.0) return false;

    final waterMeters = _segmentDistanceToLineSetMeters(
      start,
      end,
      nearbyWaterLines,
    );
    if (!waterMeters.isFinite) return true;
    if (portageMeters <= 18.0 && portageMeters <= waterMeters + 4.0) {
      return true;
    }
    return portageMeters + 12.0 < waterMeters;
  }

  List<_StyledRouteSegment> _buildPortagingStyledSegments({
    required List<gmaps.LatLng> path,
    required _PortagingOverlayCacheEntry entry,
    required int width,
    required int zIndex,
  }) {
    if (path.length < 2) return const [];

    final nearbyPortageLines = _routeLinesNearPath(
      entry.portageLines,
      path,
      maxDistanceMeters: 140.0,
    );
    if (nearbyPortageLines.isEmpty) return const [];

    final nearbyWaterLines = _routeLinesNearPath(
      entry.waterLines,
      path,
      maxDistanceMeters: 140.0,
    );
    final waterColor = _standardRouteColor('portaging');
    final out = <_StyledRouteSegment>[];

    void commitSegment(List<gmaps.LatLng> points, bool isCarry) {
      if (points.length < 2) return;
      out.add(
        _StyledRouteSegment(
          path: List<gmaps.LatLng>.from(points),
          color: isCarry ? _portagingCarryRouteColor : waterColor,
          width: width,
          zIndex: isCarry ? zIndex + 1 : zIndex,
        ),
      );
    }

    var currentIsCarry = _isPortagingCarryEdge(
      start: path[0],
      end: path[1],
      nearbyPortageLines: nearbyPortageLines,
      nearbyWaterLines: nearbyWaterLines,
    );
    var currentPoints = <gmaps.LatLng>[path[0], path[1]];

    for (var i = 1; i + 1 < path.length; i++) {
      final nextIsCarry = _isPortagingCarryEdge(
        start: path[i],
        end: path[i + 1],
        nearbyPortageLines: nearbyPortageLines,
        nearbyWaterLines: nearbyWaterLines,
      );
      if (nextIsCarry == currentIsCarry) {
        currentPoints.add(path[i + 1]);
        continue;
      }

      commitSegment(currentPoints, currentIsCarry);
      currentIsCarry = nextIsCarry;
      currentPoints = <gmaps.LatLng>[path[i], path[i + 1]];
    }

    commitSegment(currentPoints, currentIsCarry);
    return out.length >= 2 ? out : const [];
  }

  List<List<gmaps.LatLng>> _selectGraphLinesForAnchors(
    List<List<gmaps.LatLng>> lines,
    List<gmaps.LatLng> anchors, {
    required int maxLines,
    required double bboxPadDegrees,
    required String debugLabel,
    int distanceSamples = 8,
  }) {
    if (lines.length <= maxLines || anchors.isEmpty || maxLines <= 0) {
      return lines;
    }

    var minLat = double.infinity;
    var maxLat = -double.infinity;
    var minLon = double.infinity;
    var maxLon = -double.infinity;
    for (final anchor in anchors) {
      if (anchor.latitude < minLat) minLat = anchor.latitude;
      if (anchor.latitude > maxLat) maxLat = anchor.latitude;
      if (anchor.longitude < minLon) minLon = anchor.longitude;
      if (anchor.longitude > maxLon) maxLon = anchor.longitude;
    }
    minLat -= bboxPadDegrees;
    maxLat += bboxPadDegrees;
    minLon -= bboxPadDegrees;
    maxLon += bboxPadDegrees;

    final inBox = <int>[];
    final outBox = <({int index, double dist})>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.length < 2) continue;
      var inside = false;
      for (final point in line) {
        if (point.latitude >= minLat &&
            point.latitude <= maxLat &&
            point.longitude >= minLon &&
            point.longitude <= maxLon) {
          inside = true;
          break;
        }
      }
      if (inside) {
        inBox.add(i);
      } else {
        outBox.add((
          index: i,
          dist: _distanceLineToPathMeters(
            line,
            anchors,
            maxSamples: distanceSamples,
          ),
        ));
      }
    }

    List<int> selectedInBox = inBox;
    if (selectedInBox.length > maxLines) {
      final scoredInBox = selectedInBox
        .map(
          (index) => (
            index: index,
            dist: _distanceLineToPathMeters(
              lines[index],
              anchors,
              maxSamples: distanceSamples,
            ),
          ),
        )
        .toList(growable: false)..sort((a, b) => a.dist.compareTo(b.dist));
      selectedInBox = [for (var i = 0; i < maxLines; i++) scoredInBox[i].index];
    }

    outBox.sort((a, b) => a.dist.compareTo(b.dist));
    final remaining = math.max(0, maxLines - selectedInBox.length);
    final selected = <List<gmaps.LatLng>>[
      for (final index in selectedInBox) lines[index],
      for (var i = 0; i < outBox.length && i < remaining; i++)
        lines[outBox[i].index],
    ];

    debugPrint(
      '$debugLabel selected_graph_lines used=${selected.length} '
      'inBox=${selectedInBox.length} total=${lines.length}',
    );
    return selected;
  }

  String _trailNodeKey(gmaps.LatLng point) {
    return '${point.latitude.toStringAsFixed(6)},${point.longitude.toStringAsFixed(6)}';
  }

  List<_TrailCandidate> _nearestTrailCandidates(
    gmaps.LatLng target,
    List<gmaps.LatLng> nodes, {
    _TrailSpatialIndex? spatialIndex,
    int limit = 6,
    double maxMeters = 3000.0,
  }) {
    final candidates = <_TrailCandidate>[];
    final indices =
        spatialIndex != null
            ? spatialIndex.indicesWithinRadius(target, maxMeters)
            : List<int>.generate(nodes.length, (i) => i);
    if (indices.isEmpty) return const [];
    for (final i in indices) {
      final meters = _haversineMeters(target, nodes[i]);
      if (meters <= maxMeters) {
        candidates.add(_TrailCandidate(index: i, meters: meters));
      }
    }
    if (candidates.isEmpty) return const [];
    candidates.sort((a, b) => a.meters.compareTo(b.meters));
    if (candidates.length > limit) {
      return candidates.sublist(0, limit);
    }
    return candidates;
  }

  List<_TrailCandidate> _nearestTrailCandidatesAdaptive(
    gmaps.LatLng target,
    List<gmaps.LatLng> nodes, {
    _TrailSpatialIndex? spatialIndex,
    int limit = 6,
    List<double> radiiMeters = const <double>[3000, 6000, 10000, 18000],
    bool allowGlobalFallback = true,
    double? maxGlobalFallbackMeters,
  }) {
    if (nodes.isEmpty) return const [];
    final byIndex = <int, _TrailCandidate>{};
    for (var ring = 0; ring < radiiMeters.length; ring++) {
      final radius = radiiMeters[ring];
      final candidates = _nearestTrailCandidates(
        target,
        nodes,
        spatialIndex: spatialIndex,
        limit: math.max(limit * 2, limit + 2),
        maxMeters: radius,
      );
      for (final c in candidates) {
        final existing = byIndex[c.index];
        if (existing == null || c.meters < existing.meters) {
          byIndex[c.index] = c;
        }
      }
      final hasEnough = byIndex.length >= limit;
      final checkedEnoughRings = radiiMeters.length <= 1 || ring >= 1;
      if (hasEnough && checkedEnoughRings) break;
    }
    if (byIndex.isNotEmpty) {
      final merged = byIndex.values.toList(growable: false)
        ..sort((a, b) => a.meters.compareTo(b.meters));
      if (merged.length > limit) {
        return merged.sublist(0, limit);
      }
      return merged;
    }
    if (!allowGlobalFallback) return const [];
    if (spatialIndex != null && maxGlobalFallbackMeters != null) {
      return _nearestTrailCandidates(
        target,
        nodes,
        spatialIndex: spatialIndex,
        limit: limit,
        maxMeters: maxGlobalFallbackMeters,
      );
    }
    final all = <_TrailCandidate>[];
    for (var i = 0; i < nodes.length; i++) {
      final meters = _haversineMeters(target, nodes[i]);
      all.add(_TrailCandidate(index: i, meters: meters));
    }
    all.sort((a, b) => a.meters.compareTo(b.meters));
    if (maxGlobalFallbackMeters != null &&
        all.isNotEmpty &&
        all.first.meters > maxGlobalFallbackMeters) {
      return const [];
    }
    if (all.length > limit) {
      return all.sublist(0, limit);
    }
    return all;
  }

  List<_TrailCandidate> _diversifyTrailCandidatesByComponent({
    required gmaps.LatLng anchor,
    required List<_TrailCandidate> baseCandidates,
    required List<gmaps.LatLng> nodes,
    required _TrailSpatialIndex spatialIndex,
    required List<int> componentIds,
    required List<int> componentSizes,
    required int limit,
    required double nearbyRadiusMeters,
    int maxNewComponents = 3,
  }) {
    if (baseCandidates.isEmpty ||
        componentIds.length != nodes.length ||
        componentSizes.isEmpty ||
        nearbyRadiusMeters <= 0) {
      return baseCandidates;
    }

    final merged = <_TrailCandidate>[...baseCandidates];
    final seenIndices = <int>{for (final c in baseCandidates) c.index};
    final seenComponents = <int>{
      for (final c in baseCandidates)
        if (c.index >= 0 && c.index < componentIds.length)
          componentIds[c.index],
    };

    final bestByComponent = <int, _TrailCandidate>{};
    final nearbyNodeIndices = spatialIndex.indicesWithinRadius(
      anchor,
      nearbyRadiusMeters,
    );
    for (final index in nearbyNodeIndices) {
      if (index < 0 || index >= nodes.length || seenIndices.contains(index)) {
        continue;
      }
      final componentId = componentIds[index];
      if (seenComponents.contains(componentId)) continue;
      final meters = _haversineMeters(anchor, nodes[index]);
      if (!meters.isFinite || meters > nearbyRadiusMeters) continue;
      final next = _TrailCandidate(index: index, meters: meters);
      final existing = bestByComponent[componentId];
      if (existing == null || next.meters < existing.meters) {
        bestByComponent[componentId] = next;
      }
    }

    if (bestByComponent.isEmpty) return baseCandidates;

    final rankedComponents = bestByComponent.keys.toList(growable: false)
      ..sort((a, b) {
        final sizeA =
            (a >= 0 && a < componentSizes.length) ? componentSizes[a] : 0;
        final sizeB =
            (b >= 0 && b < componentSizes.length) ? componentSizes[b] : 0;
        final sizeCmp = sizeB.compareTo(sizeA);
        if (sizeCmp != 0) return sizeCmp;
        return bestByComponent[a]!.meters.compareTo(bestByComponent[b]!.meters);
      });

    for (final componentId in rankedComponents) {
      if (merged.length >= limit + maxNewComponents) break;
      final candidate = bestByComponent[componentId];
      if (candidate == null) continue;
      merged.add(candidate);
      seenIndices.add(candidate.index);
      seenComponents.add(componentId);
    }

    merged.sort((a, b) => a.meters.compareTo(b.meters));
    if (merged.length > limit + maxNewComponents) {
      return merged.sublist(0, limit + maxNewComponents);
    }
    return merged;
  }

  double _anchorConnectorLimitMeters(String modeContext) {
    final mode = _normalizeTransportMode(modeContext);
    switch (mode) {
      case 'portaging':
        // Keep campsite anchor connectors short in portaging mode so route
        // geometry favors the water/portage network instead of cutting across
        // large land masses to touch a stop marker.
        return 320.0;
      case 'hiking':
        return 900.0;
      case 'walk':
        return 700.0;
      default:
        return 800.0;
    }
  }

  double _portageConnectorScore(double meters) {
    if (!meters.isFinite || meters < 0) return double.infinity;
    if (meters <= 80.0) return meters;
    if (meters <= 200.0) return meters * 1.3;
    if (meters <= 400.0) return meters * 2.4;
    if (meters <= 800.0) return meters * 4.5;
    return meters * 8.0;
  }

  int _comparePortageGraphCandidates(
    _PortageGraphCandidate a,
    _PortageGraphCandidate b,
  ) {
    final total = a.totalConnectorMeters.compareTo(b.totalConnectorMeters);
    if (total != 0) return total;
    final connector = a.connectorMeters.compareTo(b.connectorMeters);
    if (connector != 0) return connector;
    final search = a.searchMeters.compareTo(b.searchMeters);
    if (search != 0) return search;
    if (a.usedAccess != b.usedAccess) {
      return a.usedAccess ? 1 : -1;
    }
    return a.index.compareTo(b.index);
  }

  List<_PortageGraphCandidate> _mergePortageCandidateGroups(
    List<List<_PortageGraphCandidate>> groups, {
    int softLimit = 12,
  }) {
    final byIndex = <int, _PortageGraphCandidate>{};
    for (final group in groups) {
      for (final candidate in group) {
        final existing = byIndex[candidate.index];
        if (existing == null ||
            _comparePortageGraphCandidates(candidate, existing) < 0) {
          byIndex[candidate.index] = candidate;
        }
      }
    }

    final merged = byIndex.values.toList(growable: false)
      ..sort(_comparePortageGraphCandidates);
    if (softLimit > 0 && merged.length > softLimit) {
      return merged.sublist(0, softLimit);
    }
    return merged;
  }

  List<_PortageGraphCandidate> _snapPortageCandidatesToSegments({
    required gmaps.LatLng anchor,
    required List<List<gmaps.LatLng>> lines,
    required Map<String, int> nodeIndexByKey,
    required _PortagingOverlayCacheEntry entry,
    required int limit,
    double maxAnchorMeters = 12000.0,
    double maxLineDistanceMeters = 14000.0,
    double maxAlongSegmentMeters = 22000.0,
    ({gmaps.LatLng graphAnchor, double connectorMeters, bool usedAccess})?
    resolvedAnchor,
  }) {
    if (lines.isEmpty || nodeIndexByKey.isEmpty || limit <= 0) {
      return const <_PortageGraphCandidate>[];
    }

    final byIndex = <int, _PortageGraphCandidate>{};

    void scanSource(
      gmaps.LatLng sourcePoint, {
      required double baseConnectorMeters,
      required bool usedAccess,
    }) {
      final shortlisted = <({List<gmaps.LatLng> line, double distance})>[];
      for (final line in lines) {
        if (line.length < 2) continue;
        final lineDistance = _distanceMetersToPath(sourcePoint, line);
        if (!lineDistance.isFinite || lineDistance > maxLineDistanceMeters) {
          continue;
        }
        shortlisted.add((line: line, distance: lineDistance));
      }
      shortlisted.sort((a, b) => a.distance.compareTo(b.distance));

      final lineCap = math.max(limit * 3, 24);
      for (
        var lineIndex = 0;
        lineIndex < shortlisted.length && lineIndex < lineCap;
        lineIndex++
      ) {
        final line = shortlisted[lineIndex].line;
        for (var i = 0; i + 1 < line.length; i++) {
          final a = line[i];
          final b = line[i + 1];
          final startIndex = nodeIndexByKey[_trailNodeKey(a)];
          final endIndex = nodeIndexByKey[_trailNodeKey(b)];
          if (startIndex == null || endIndex == null) continue;

          final projected = _projectOnSegment(sourcePoint, a, b);
          final toProjected = _haversineMeters(sourcePoint, projected);
          if (!toProjected.isFinite || toProjected > maxAnchorMeters) {
            continue;
          }
          if (!_isValidPortageConnectorToGraphAnchor(
            anchor: sourcePoint,
            graphAnchor: projected,
            entry: entry,
            allowAccessStraightToWater: usedAccess,
          )) {
            continue;
          }

          final metersToStart = _haversineMeters(projected, a);
          if (metersToStart.isFinite &&
              metersToStart <= maxAlongSegmentMeters) {
            final candidate = _PortageGraphCandidate(
              index: startIndex,
              searchMeters: metersToStart,
              connectorMeters: baseConnectorMeters + toProjected,
              graphAnchor: projected,
              usedAccess: usedAccess,
            );
            final existing = byIndex[startIndex];
            if (existing == null ||
                _comparePortageGraphCandidates(candidate, existing) < 0) {
              byIndex[startIndex] = candidate;
            }
          }

          final metersToEnd = _haversineMeters(projected, b);
          if (metersToEnd.isFinite && metersToEnd <= maxAlongSegmentMeters) {
            final candidate = _PortageGraphCandidate(
              index: endIndex,
              searchMeters: metersToEnd,
              connectorMeters: baseConnectorMeters + toProjected,
              graphAnchor: projected,
              usedAccess: usedAccess,
            );
            final existing = byIndex[endIndex];
            if (existing == null ||
                _comparePortageGraphCandidates(candidate, existing) < 0) {
              byIndex[endIndex] = candidate;
            }
          }
        }
      }
    }

    scanSource(anchor, baseConnectorMeters: 0.0, usedAccess: false);
    if (resolvedAnchor != null && resolvedAnchor.usedAccess) {
      scanSource(
        resolvedAnchor.graphAnchor,
        baseConnectorMeters: resolvedAnchor.connectorMeters,
        usedAccess: true,
      );
    }

    final merged = byIndex.values.toList(growable: false)
      ..sort(_comparePortageGraphCandidates);
    final softLimit = math.max(limit * 2, limit + 4);
    if (merged.length > softLimit) {
      return merged.sublist(0, softLimit);
    }
    return merged;
  }

  bool _waypointShouldUseAnchor({
    required int anchorIndex,
    required int anchorCount,
    required double connectorLimitMeters,
    required List<double> startConnectorMetersByLeg,
    required List<double> endConnectorMetersByLeg,
  }) {
    if (anchorCount <= 0) return false;
    if (anchorIndex <= 0) {
      return startConnectorMetersByLeg.isNotEmpty &&
          startConnectorMetersByLeg.first <= connectorLimitMeters;
    }
    if (anchorIndex >= anchorCount - 1) {
      return endConnectorMetersByLeg.isNotEmpty &&
          endConnectorMetersByLeg.last <= connectorLimitMeters;
    }
    final prevLeg = anchorIndex - 1;
    final nextLeg = anchorIndex;
    if (prevLeg < 0 ||
        prevLeg >= endConnectorMetersByLeg.length ||
        nextLeg < 0 ||
        nextLeg >= startConnectorMetersByLeg.length) {
      return false;
    }
    return endConnectorMetersByLeg[prevLeg] <= connectorLimitMeters &&
        startConnectorMetersByLeg[nextLeg] <= connectorLimitMeters;
  }

  gmaps.LatLng? _nearestPortageAccessPoint(
    gmaps.LatLng target,
    List<gmaps.LatLng> accessPoints, {
    double maxMeters = 12000.0,
  }) {
    gmaps.LatLng? best;
    var bestMeters = double.infinity;
    for (final point in accessPoints) {
      final meters = _haversineMeters(target, point);
      if (meters > maxMeters) continue;
      if (meters < bestMeters) {
        bestMeters = meters;
        best = point;
      }
    }
    return best;
  }

  ({gmaps.LatLng graphAnchor, double connectorMeters, bool usedAccess})
  _resolvePortagingGraphAnchor(
    gmaps.LatLng anchor,
    List<gmaps.LatLng> nodes,
    _TrailSpatialIndex spatialIndex,
    List<gmaps.LatLng> accessPoints,
  ) {
    final direct = _nearestTrailCandidatesAdaptive(
      anchor,
      nodes,
      spatialIndex: spatialIndex,
      limit: 1,
      radiiMeters: const <double>[4000, 8000, 15000],
      maxGlobalFallbackMeters: 12000,
    );
    final directMeters =
        direct.isNotEmpty ? direct.first.meters : double.infinity;

    final access = _nearestPortageAccessPoint(
      anchor,
      accessPoints,
      maxMeters: 12000.0,
    );
    if (access == null) {
      return (graphAnchor: anchor, connectorMeters: 0.0, usedAccess: false);
    }

    final accessMeters = _haversineMeters(anchor, access);
    final directLooksGood = directMeters.isFinite && directMeters <= 220.0;
    final shouldUseAccess =
        !directMeters.isFinite ||
        accessMeters <= (directMeters * 0.95) ||
        (!directLooksGood && accessMeters <= (directMeters * 1.35)) ||
        directMeters > 900.0;
    if (!shouldUseAccess) {
      return (graphAnchor: anchor, connectorMeters: 0.0, usedAccess: false);
    }

    return (
      graphAnchor: access,
      connectorMeters: accessMeters,
      usedAccess: true,
    );
  }

  List<_PortageGraphCandidate> _portageGraphCandidatesForAnchor({
    required gmaps.LatLng anchor,
    required List<gmaps.LatLng> nodes,
    required _TrailSpatialIndex spatialIndex,
    required List<gmaps.LatLng> accessPoints,
    required _PortagingOverlayCacheEntry entry,
    required int limit,
    required List<double> radiiMeters,
    double? maxGlobalFallbackMeters,
    List<int>? componentIds,
    List<int>? componentSizes,
    double diversifyNearbyMeters = 0.0,
  }) {
    if (nodes.isEmpty || limit <= 0) return const <_PortageGraphCandidate>[];

    final byIndex = <int, _PortageGraphCandidate>{};
    void mergeCandidates(
      List<_TrailCandidate> candidates, {
      required double connectorMeters,
      required gmaps.LatLng graphAnchor,
      required bool usedAccess,
    }) {
      for (final candidate in candidates) {
        final next = _PortageGraphCandidate(
          index: candidate.index,
          searchMeters: candidate.meters,
          connectorMeters: connectorMeters,
          graphAnchor: graphAnchor,
          usedAccess: usedAccess,
        );
        final existing = byIndex[candidate.index];
        if (existing == null ||
            next.totalConnectorMeters < existing.totalConnectorMeters - 1e-6 ||
            ((next.totalConnectorMeters - existing.totalConnectorMeters)
                        .abs() <=
                    1e-6 &&
                !next.usedAccess &&
                existing.usedAccess)) {
          byIndex[candidate.index] = next;
        }
      }
    }

    if (_isLikelyWaterPoint(anchor, entry, lineThresholdMeters: 120.0)) {
      final directCandidates = _nearestTrailCandidatesAdaptive(
        anchor,
        nodes,
        spatialIndex: spatialIndex,
        limit: math.max(limit, 6),
        radiiMeters: radiiMeters,
        maxGlobalFallbackMeters: maxGlobalFallbackMeters,
      );
      mergeCandidates(
        directCandidates,
        connectorMeters: 0.0,
        graphAnchor: anchor,
        usedAccess: false,
      );
    }

    final accessAnchor = _resolvePortagingGraphAnchor(
      anchor,
      nodes,
      spatialIndex,
      accessPoints,
    );
    if (accessAnchor.usedAccess &&
        _isLikelyWaterPoint(
          accessAnchor.graphAnchor,
          entry,
          lineThresholdMeters: 120.0,
        )) {
      final accessCandidates = _nearestTrailCandidatesAdaptive(
        accessAnchor.graphAnchor,
        nodes,
        spatialIndex: spatialIndex,
        limit: math.max(limit, 6),
        radiiMeters: radiiMeters,
        maxGlobalFallbackMeters: maxGlobalFallbackMeters,
      );
      mergeCandidates(
        accessCandidates,
        connectorMeters: accessAnchor.connectorMeters,
        graphAnchor: accessAnchor.graphAnchor,
        usedAccess: true,
      );
    }

    if (byIndex.isEmpty) return const <_PortageGraphCandidate>[];

    final merged = byIndex.values.toList(growable: false)..sort((a, b) {
      final total = a.totalConnectorMeters.compareTo(b.totalConnectorMeters);
      if (total != 0) return total;
      if (a.usedAccess != b.usedAccess) {
        return a.usedAccess ? 1 : -1;
      }
      return a.index.compareTo(b.index);
    });

    if (componentIds != null &&
        componentSizes != null &&
        componentIds.length == nodes.length &&
        diversifyNearbyMeters > 0) {
      final seenComponents = <int>{
        for (final candidate in merged)
          if (candidate.index >= 0 && candidate.index < componentIds.length)
            componentIds[candidate.index],
      };
      final bestByComponent = <int, _PortageGraphCandidate>{};
      for (var i = 0; i < nodes.length; i++) {
        final cid = componentIds[i];
        if (seenComponents.contains(cid)) continue;
        final meters = _haversineMeters(anchor, nodes[i]);
        if (!meters.isFinite || meters > diversifyNearbyMeters) continue;
        final candidate = _PortageGraphCandidate(
          index: i,
          searchMeters: meters,
          connectorMeters: 0.0,
          graphAnchor: anchor,
          usedAccess: false,
        );
        final existing = bestByComponent[cid];
        if (existing == null ||
            candidate.totalConnectorMeters < existing.totalConnectorMeters) {
          bestByComponent[cid] = candidate;
        }
      }

      if (bestByComponent.isNotEmpty) {
        final largestNearbyComponents = bestByComponent.keys.toList(
          growable: false,
        )..sort((a, b) {
          final sizeCmp = componentSizes[b].compareTo(componentSizes[a]);
          if (sizeCmp != 0) return sizeCmp;
          return bestByComponent[a]!.totalConnectorMeters.compareTo(
            bestByComponent[b]!.totalConnectorMeters,
          );
        });
        for (final cid in largestNearbyComponents) {
          if (merged.length >= limit + 4) break;
          final candidate = bestByComponent[cid];
          if (candidate == null) continue;
          merged.add(candidate);
          seenComponents.add(cid);
          if (seenComponents.length >= 3) break;
        }

        final nearestNearbyComponents = bestByComponent.keys.toList(
          growable: false,
        )..sort(
          (a, b) => bestByComponent[a]!.totalConnectorMeters.compareTo(
            bestByComponent[b]!.totalConnectorMeters,
          ),
        );
        for (final cid in nearestNearbyComponents) {
          if (merged.length >= limit + 4) break;
          if (seenComponents.contains(cid)) continue;
          final candidate = bestByComponent[cid];
          if (candidate == null) continue;
          merged.add(candidate);
          seenComponents.add(cid);
        }

        merged.sort((a, b) {
          final total = a.totalConnectorMeters.compareTo(
            b.totalConnectorMeters,
          );
          if (total != 0) return total;
          if (a.usedAccess != b.usedAccess) {
            return a.usedAccess ? 1 : -1;
          }
          return a.index.compareTo(b.index);
        });
      }
    }

    final finalLimit = math.max(limit, limit + 4);
    if (merged.length > finalLimit) {
      return merged.sublist(0, finalLimit);
    }
    return merged;
  }

  List<_PortageGraphCandidate> _augmentPortageCandidatesViaOpenWater({
    required gmaps.LatLng anchor,
    required ({
      gmaps.LatLng graphAnchor,
      double connectorMeters,
      bool usedAccess,
    })
    resolvedAnchor,
    required List<_PortageGraphCandidate> baseCandidates,
    required List<gmaps.LatLng> nodes,
    required _TrailSpatialIndex spatialIndex,
    required _PortagingOverlayCacheEntry entry,
    required int maxExtraCandidates,
    required double maxReachMeters,
    List<int>? componentIds,
    List<int>? componentSizes,
  }) {
    if (nodes.isEmpty ||
        maxExtraCandidates <= 0 ||
        maxReachMeters <= 0 ||
        !_isLikelyWaterPoint(anchor, entry, lineThresholdMeters: 190.0) &&
            !resolvedAnchor.usedAccess) {
      return baseCandidates;
    }

    final byIndex = <int, _PortageGraphCandidate>{
      for (final candidate in baseCandidates) candidate.index: candidate,
    };
    final baseIndices = byIndex.keys.toSet();
    final representedComponents =
        componentIds != null &&
                componentSizes != null &&
                componentIds.length == nodes.length
            ? <int>{
              for (final candidate in baseCandidates)
                if (candidate.index >= 0 &&
                    candidate.index < componentIds.length)
                  componentIds[candidate.index],
            }
            : <int>{};
    final safetyCache = <String, bool>{};

    int compareCandidates(_PortageGraphCandidate a, _PortageGraphCandidate b) {
      if (componentIds != null &&
          componentSizes != null &&
          a.index >= 0 &&
          a.index < componentIds.length &&
          b.index >= 0 &&
          b.index < componentIds.length) {
        final cidA = componentIds[a.index];
        final cidB = componentIds[b.index];
        final sizeCmp = componentSizes[cidB].compareTo(componentSizes[cidA]);
        if (sizeCmp != 0) return sizeCmp;
      }
      final total = a.totalConnectorMeters.compareTo(b.totalConnectorMeters);
      if (total != 0) return total;
      if (a.usedAccess != b.usedAccess) {
        return a.usedAccess ? 1 : -1;
      }
      return a.index.compareTo(b.index);
    }

    bool isSafeDirect(gmaps.LatLng from, gmaps.LatLng to) {
      final key =
          '${from.latitude.toStringAsFixed(6)},${from.longitude.toStringAsFixed(6)}'
          '->'
          '${to.latitude.toStringAsFixed(6)},${to.longitude.toStringAsFixed(6)}';
      return safetyCache.putIfAbsent(
        key,
        () => _isWaterSafeDirectSegment(from, to, entry),
      );
    }

    final sources =
        <({gmaps.LatLng point, double connectorMeters, bool usedAccess})>[
          (point: anchor, connectorMeters: 0.0, usedAccess: false),
          if (resolvedAnchor.usedAccess)
            (
              point: resolvedAnchor.graphAnchor,
              connectorMeters: resolvedAnchor.connectorMeters,
              usedAccess: true,
            ),
        ];

    for (final source in sources) {
      if (!_isLikelyWaterPoint(
        source.point,
        entry,
        lineThresholdMeters: 190.0,
      )) {
        continue;
      }
      final nearbyNodeIndices = spatialIndex.indicesWithinRadius(
        source.point,
        maxReachMeters,
      );
      for (final i in nearbyNodeIndices) {
        final node = nodes[i];
        final meters = _haversineMeters(source.point, node);
        if (!meters.isFinite || meters <= 120.0 || meters > maxReachMeters) {
          continue;
        }
        if (!isSafeDirect(source.point, node)) continue;
        final next = _PortageGraphCandidate(
          index: i,
          searchMeters: meters,
          connectorMeters: source.connectorMeters,
          graphAnchor: source.point,
          usedAccess: source.usedAccess,
        );
        final existing = byIndex[i];
        if (existing == null ||
            next.totalConnectorMeters < existing.totalConnectorMeters - 1e-6 ||
            ((next.totalConnectorMeters - existing.totalConnectorMeters)
                        .abs() <=
                    1e-6 &&
                !next.usedAccess &&
                existing.usedAccess)) {
          byIndex[i] = next;
        }
      }
    }

    final extras =
        byIndex.values
            .where((candidate) => !baseIndices.contains(candidate.index))
            .toList()
          ..sort(compareCandidates);
    if (extras.isEmpty) return baseCandidates;

    final chosen = <_PortageGraphCandidate>[];
    if (componentIds != null &&
        componentSizes != null &&
        componentIds.length == nodes.length) {
      final bestByNewComponent = <int, _PortageGraphCandidate>{};
      for (final candidate in extras) {
        final cid = componentIds[candidate.index];
        if (representedComponents.contains(cid)) continue;
        final existing = bestByNewComponent[cid];
        if (existing == null || compareCandidates(candidate, existing) < 0) {
          bestByNewComponent[cid] = candidate;
        }
      }
      final diversified = bestByNewComponent.values.toList(growable: false)
        ..sort(compareCandidates);
      for (final candidate in diversified) {
        if (chosen.length >= maxExtraCandidates) break;
        chosen.add(candidate);
        representedComponents.add(componentIds[candidate.index]);
      }
    }

    for (final candidate in extras) {
      if (chosen.length >= maxExtraCandidates) break;
      if (chosen.any((selected) => selected.index == candidate.index)) continue;
      chosen.add(candidate);
    }

    if (chosen.isEmpty) return baseCandidates;

    final merged = <_PortageGraphCandidate>[...baseCandidates, ...chosen]
      ..sort(compareCandidates);
    final maxTotal = math.max(
      baseCandidates.length,
      math.min(nodes.length, baseCandidates.length + maxExtraCandidates),
    );
    if (merged.length > maxTotal) {
      return merged.sublist(0, maxTotal);
    }
    return merged;
  }

  ({List<int> componentIds, List<int> componentSizes}) _graphComponents(
    List<List<_TrailEdge>> adjacency,
  ) {
    final n = adjacency.length;
    final componentIds = List<int>.filled(n, -1);
    final componentSizes = <int>[];
    var nextComponent = 0;

    for (var start = 0; start < n; start++) {
      if (componentIds[start] != -1) continue;
      final queue = Queue<int>()..add(start);
      componentIds[start] = nextComponent;
      var size = 0;
      while (queue.isNotEmpty) {
        final node = queue.removeFirst();
        size++;
        for (final edge in adjacency[node]) {
          if (edge.to < 0 || edge.to >= n) continue;
          if (componentIds[edge.to] != -1) continue;
          componentIds[edge.to] = nextComponent;
          queue.add(edge.to);
        }
      }
      componentSizes.add(size);
      nextComponent++;
    }

    return (componentIds: componentIds, componentSizes: componentSizes);
  }

  ({List<double> dist, List<int> prev}) _shortestTrailTreeFromSource(
    int source,
    List<List<_TrailEdge>> adjacency, {
    Set<int>? stopNodes,
  }) {
    final n = adjacency.length;
    final dist = List<double>.filled(n, double.infinity);
    final prev = List<int>.filled(n, -1);

    if (source < 0 || source >= n) {
      return (dist: dist, prev: prev);
    }

    dist[source] = 0.0;
    final pendingStops = stopNodes != null ? Set<int>.from(stopNodes) : null;
    final heap = _MinNodeHeap()..add(_NodeDistance(source, 0.0));

    while (!heap.isEmpty) {
      final current = heap.removeFirst();
      final u = current.node;
      final best = current.meters;
      if (best > dist[u] + 1e-9) continue;

      if (pendingStops != null &&
          pendingStops.remove(u) &&
          pendingStops.isEmpty) {
        break;
      }

      for (final edge in adjacency[u]) {
        final alt = dist[u] + edge.meters;
        if (alt + 1e-9 < dist[edge.to]) {
          dist[edge.to] = alt;
          prev[edge.to] = u;
          heap.add(_NodeDistance(edge.to, alt));
        }
      }
    }

    return (dist: dist, prev: prev);
  }

  List<int>? _reconstructTrailNodePath(int start, int end, List<int> prev) {
    if (start < 0 || end < 0 || start >= prev.length || end >= prev.length) {
      return null;
    }
    final reversed = <int>[];
    var cursor = end;
    while (cursor >= 0) {
      reversed.add(cursor);
      if (cursor == start) break;
      cursor = prev[cursor];
      if (cursor < 0) return null;
    }
    return reversed.reversed.toList(growable: false);
  }

  _TrailPathResult? _shortestTrailPath(
    int start,
    int end,
    List<List<_TrailEdge>> adjacency,
  ) {
    final n = adjacency.length;
    if (start < 0 || start >= n || end < 0 || end >= n) return null;
    if (start == end) {
      return _TrailPathResult(nodePath: <int>[start], meters: 0.0);
    }

    final dist = List<double>.filled(n, double.infinity);
    final prev = List<int>.filled(n, -1);
    dist[start] = 0.0;
    final heap = _MinNodeHeap()..add(_NodeDistance(start, 0.0));

    while (!heap.isEmpty) {
      final current = heap.removeFirst();
      final u = current.node;
      final best = current.meters;
      if (best > dist[u] + 1e-9) continue;
      if (u == end) break;

      for (final edge in adjacency[u]) {
        final alt = dist[u] + edge.meters;
        if (alt + 1e-9 < dist[edge.to]) {
          dist[edge.to] = alt;
          prev[edge.to] = u;
          heap.add(_NodeDistance(edge.to, alt));
        }
      }
    }

    if (!dist[end].isFinite) return null;

    final reversed = <int>[];
    var cursor = end;
    while (cursor >= 0) {
      reversed.add(cursor);
      if (cursor == start) break;
      cursor = prev[cursor];
      if (cursor < 0) return null;
    }

    final nodePath = reversed.reversed.toList(growable: false);
    return _TrailPathResult(nodePath: nodePath, meters: dist[end]);
  }

  ({
    List<gmaps.LatLng> nodes,
    List<List<_TrailEdge>> adjacency,
    _TrailSpatialIndex spatialIndex,
  })
  _graphForLines(
    List<List<gmaps.LatLng>> lines, {
    required String cacheKey,
    double bridgeToleranceMeters = 0.0,
    bool allowLoopBridges = false,
    double maxLoopBridgeMeters = 0.0,
  }) {
    final fullCacheKey =
        '$cacheKey|bridge=${bridgeToleranceMeters.toStringAsFixed(1)}|loop=${allowLoopBridges ? 1 : 0}|loopMax=${maxLoopBridgeMeters.toStringAsFixed(1)}';
    final existing = _trailGraphCache[fullCacheKey];
    if (existing != null && _isFresh(existing.fetchedAt, _overlayCacheTtl)) {
      return (
        nodes: existing.nodes,
        adjacency: existing.adjacency,
        spatialIndex: existing.spatialIndex,
      );
    }
    final graph = _buildGraphFromLines(
      lines,
      bridgeToleranceMeters: bridgeToleranceMeters,
      allowLoopBridges: allowLoopBridges,
      maxLoopBridgeMeters: maxLoopBridgeMeters,
    );
    _trailGraphCache[fullCacheKey] = _TrailGraphCacheEntry(
      fetchedAt: DateTime.now(),
      nodes: graph.nodes,
      adjacency: graph.adjacency,
      spatialIndex: graph.spatialIndex,
    );
    return graph;
  }

  Future<_HikingOverlayCacheEntry?> _getHikingOverlayEntry({
    required String cacheKey,
    required List<gmaps.LatLng> routePath,
    double padDegrees = 0.08,
  }) async {
    final cached = _hikingOverlayCache[cacheKey];
    if (cached != null && _isFresh(cached.fetchedAt, _overlayCacheTtl)) {
      return cached;
    }
    final inFlight = _hikingOverlayInFlight[cacheKey];
    if (inFlight != null) {
      if (cached != null) {
        return cached;
      }
      return inFlight;
    }
    final future = _fetchHikingOverlayData(routePath, padDegrees: padDegrees);
    _hikingOverlayInFlight[cacheKey] = future;
    try {
      final entry = await future;
      if (entry != null) {
        _hikingOverlayCache[cacheKey] = entry;
        return entry;
      }
      if (cached != null) {
        debugPrint(
          'hikingOverpass stale_cache_fallback key=$cacheKey '
          'age_ms=${DateTime.now().difference(cached.fetchedAt).inMilliseconds}',
        );
      }
      return cached;
    } finally {
      final current = _hikingOverlayInFlight[cacheKey];
      if (identical(current, future)) {
        _hikingOverlayInFlight.remove(cacheKey);
      }
    }
  }

  Future<_PortagingOverlayCacheEntry?> _getPortagingOverlayEntry({
    required String cacheKey,
    required List<gmaps.LatLng> anchors,
    gmaps.LatLng? focusPoint,
    required double padDegrees,
    bool includeCampsites = true,
  }) async {
    final cached = _portagingOverlayCache[cacheKey];
    if (cached != null && _isFresh(cached.fetchedAt, _overlayCacheTtl)) {
      return cached;
    }
    final inFlight = _portagingOverlayInFlight[cacheKey];
    if (inFlight != null) {
      if (cached != null) {
        return cached;
      }
      return inFlight;
    }
    final future = _fetchPortagingOverlayData(
      anchors: anchors,
      focusPoint: focusPoint,
      padDegrees: padDegrees,
      includeCampsites: includeCampsites,
    );
    _portagingOverlayInFlight[cacheKey] = future;
    try {
      final entry = await future;
      if (entry != null) {
        _portagingOverlayCache[cacheKey] = entry;
        return entry;
      }
      if (cached != null) {
        debugPrint(
          'portagingOverpass stale_cache_fallback key=$cacheKey '
          'age_ms=${DateTime.now().difference(cached.fetchedAt).inMilliseconds}',
        );
      }
      return cached;
    } finally {
      final current = _portagingOverlayInFlight[cacheKey];
      if (identical(current, future)) {
        _portagingOverlayInFlight.remove(cacheKey);
      }
    }
  }

  String _latLngMergeKey(gmaps.LatLng point, {int decimals = 5}) {
    return '${point.latitude.toStringAsFixed(decimals)},'
        '${point.longitude.toStringAsFixed(decimals)}';
  }

  String _lineMergeKey(List<gmaps.LatLng> line, {int sample = 12}) {
    if (line.isEmpty) return '';
    final forward = _pathSignature(line, sample: sample);
    final reverse = _pathSignature(
      line.reversed.toList(growable: false),
      sample: sample,
    );
    return forward.compareTo(reverse) <= 0 ? forward : reverse;
  }

  List<gmaps.LatLng> _portagingOverlayFocusPoints({
    required List<gmaps.LatLng> routePath,
    required List<gmaps.LatLng> modeAnchors,
    gmaps.LatLng? focusPoint,
    int maxPoints = 5,
  }) {
    if (maxPoints <= 0) return const <gmaps.LatLng>[];

    final source = routePath.length >= 2 ? routePath : modeAnchors;
    final out = <gmaps.LatLng>[];
    final seen = <String>{};

    void addPoint(gmaps.LatLng point) {
      final key = _latLngMergeKey(point, decimals: 3);
      if (seen.add(key)) {
        out.add(point);
      }
    }

    if (focusPoint != null) {
      addPoint(focusPoint);
    }
    if (source.isNotEmpty) {
      addPoint(source.first);
      if (source.length > 2) {
        addPoint(source[source.length ~/ 2]);
      }
      for (final point in _samplePath(source, target: maxPoints)) {
        addPoint(point);
        if (out.length >= maxPoints) break;
      }
      addPoint(source.last);
    }

    if (out.length <= maxPoints) {
      return out;
    }

    final trimmed = <gmaps.LatLng>[];
    final trimmedSeen = <String>{};

    void keepPoint(gmaps.LatLng point) {
      final key = _latLngMergeKey(point, decimals: 3);
      if (!trimmedSeen.add(key)) return;
      if (trimmed.length < maxPoints) {
        trimmed.add(point);
      }
    }

    if (focusPoint != null) {
      keepPoint(focusPoint);
    }
    if (source.isNotEmpty) {
      for (final point in _samplePath(source, target: maxPoints)) {
        keepPoint(point);
      }
      keepPoint(source.last);
    }
    return trimmed;
  }

  _PortagingOverlayCacheEntry _mergePortagingOverlayEntries(
    List<_PortagingOverlayCacheEntry> entries,
  ) {
    final waterLines = <List<gmaps.LatLng>>[];
    final waterPolygons = <List<gmaps.LatLng>>[];
    final portageLines = <List<gmaps.LatLng>>[];
    final campsites = <Map<String, dynamic>>[];
    final accessPoints = <Map<String, dynamic>>[];
    final seenWaterLines = <String>{};
    final seenWaterPolygons = <String>{};
    final seenPortageLines = <String>{};
    final seenCampsites = <String>{};
    final seenAccessPoints = <String>{};
    var newestFetchedAt = entries.first.fetchedAt;

    for (final entry in entries) {
      if (entry.fetchedAt.isAfter(newestFetchedAt)) {
        newestFetchedAt = entry.fetchedAt;
      }

      for (final line in entry.waterLines) {
        final key = _lineMergeKey(line, sample: 10);
        if (key.isEmpty || !seenWaterLines.add(key)) continue;
        waterLines.add(line);
      }
      for (final polygon in entry.waterPolygons) {
        final key = _lineMergeKey(polygon, sample: 10);
        if (key.isEmpty || !seenWaterPolygons.add(key)) continue;
        waterPolygons.add(polygon);
      }
      for (final line in entry.portageLines) {
        final key = _lineMergeKey(line, sample: 10);
        if (key.isEmpty || !seenPortageLines.add(key)) continue;
        portageLines.add(line);
      }
      for (final camp in entry.campsites) {
        final lat = _toDouble(camp['lat']);
        final lon = _toDouble(camp['lon']);
        final key = '${lat.toStringAsFixed(5)},${lon.toStringAsFixed(5)}';
        if (!seenCampsites.add(key)) continue;
        campsites.add(Map<String, dynamic>.from(camp));
      }
      for (final access in entry.accessPoints) {
        final lat = _toDouble(access['lat']);
        final lon = _toDouble(access['lon']);
        final key = '${lat.toStringAsFixed(5)},${lon.toStringAsFixed(5)}';
        if (!seenAccessPoints.add(key)) continue;
        accessPoints.add(Map<String, dynamic>.from(access));
      }
    }

    return _PortagingOverlayCacheEntry(
      fetchedAt: newestFetchedAt,
      waterLines: waterLines,
      waterPolygons: waterPolygons,
      portageLines: portageLines,
      campsites: campsites,
      accessPoints: accessPoints,
      geoJson: _toGeoJson(
        <List<gmaps.LatLng>>[...waterLines, ...portageLines],
        campsites,
        accessPoints,
      ),
    );
  }

  Future<_PortagingOverlayCacheEntry?> _loadSegmentedPortagingOverlayEntry({
    required List<gmaps.LatLng> routePath,
    required List<gmaps.LatLng> modeAnchors,
    required gmaps.LatLng focusPoint,
    required double padDegrees,
    bool includeCampsites = true,
    int maxFocusQueries = 4,
    required String logPrefix,
  }) async {
    final focusPoints = _portagingOverlayFocusPoints(
      routePath: routePath,
      modeAnchors: modeAnchors,
      focusPoint: focusPoint,
      maxPoints: maxFocusQueries,
    );
    if (focusPoints.isEmpty) return null;

    final entries = <_PortagingOverlayCacheEntry>[];
    for (final point in focusPoints) {
      final cacheKey = _portagingFocusCacheKey(point, padDegrees: padDegrees);
      final entry = await _getPortagingOverlayEntry(
        cacheKey: cacheKey,
        anchors: <gmaps.LatLng>[point],
        focusPoint: point,
        padDegrees: padDegrees,
        includeCampsites: includeCampsites,
      );
      if (entry != null) {
        entries.add(entry);
      }
    }
    if (entries.isEmpty) return null;
    if (entries.length == 1) {
      debugPrint(
        '$logPrefix segmented_focus_single samples=${focusPoints.length} '
        'pad=${padDegrees.toStringAsFixed(2)}',
      );
      return entries.first;
    }

    final merged = _mergePortagingOverlayEntries(entries);
    debugPrint(
      '$logPrefix segmented_focus_merged samples=${entries.length} '
      'pad=${padDegrees.toStringAsFixed(2)} '
      'water=${merged.waterLines.length} '
      'portage=${merged.portageLines.length} '
      'campsites=${merged.campsites.length} '
      'access=${merged.accessPoints.length}',
    );
    return merged;
  }

  Future<_RouteComputation?> _routeViaTrailGraph(
    List<Map<String, dynamic>> segPoints, {
    String modeContext = 'hiking',
  }) async {
    if (segPoints.length < 2) return null;
    final anchors = _segmentLatLngs(segPoints);
    if (anchors.length < 2) return null;
    final normalizedMode = _normalizeTransportMode(modeContext);
    final cacheAnchors = anchors;

    _RouteComputation? solveWithEntry(
      _HikingOverlayCacheEntry entry, {
      required String graphCacheKey,
    }) {
      if (entry.trailLines.isEmpty) return null;
      final routeTrailLines = _selectGraphLinesForAnchors(
        entry.trailLines,
        anchors,
        maxLines: normalizedMode == 'portaging' ? 900 : 700,
        bboxPadDegrees: normalizedMode == 'portaging' ? 0.06 : 0.04,
        debugLabel: 'trailRoute',
      );
      if (routeTrailLines.isEmpty) return null;
      if (anchors.length == 2) {
        final sameLineRoute = _fastTrailRouteAlongSameLine(
          start: anchors.first,
          end: anchors.last,
          trailLines: routeTrailLines,
          maxAnchorMeters: normalizedMode == 'portaging' ? 1600.0 : 1200.0,
          maxLineDistanceMeters:
              normalizedMode == 'portaging' ? 2200.0 : 1600.0,
          maxTotalMeters: normalizedMode == 'portaging' ? 42000.0 : 36000.0,
        );
        if (sameLineRoute != null) {
          return _RouteComputation(
            path: sameLineRoute.path,
            distanceMeters: sameLineRoute.distanceMeters,
            durationSeconds: sameLineRoute.distanceMeters / 1.2,
            color: _standardRouteColor(normalizedMode),
            width: 6,
            zIndex: 26,
            instructions: <String>[
              'Trail-aligned route (${(sameLineRoute.distanceMeters / 1000.0).toStringAsFixed(1)} km)',
            ],
          );
        }
      }
      final bridgeToleranceMeters =
          normalizedMode == 'portaging' ? 280.0 : 180.0;
      final graph = _graphForLines(
        routeTrailLines,
        cacheKey: graphCacheKey,
        bridgeToleranceMeters: bridgeToleranceMeters,
      );
      final nodes = graph.nodes;
      final adjacency = graph.adjacency;
      final spatialIndex = graph.spatialIndex;
      if (nodes.length < 2) return null;
      if (nodes.length > 26000) {
        debugPrint('trailRoute skipped_too_large nodes=${nodes.length}');
        return null;
      }
      final graphComponents = _graphComponents(adjacency);

      final connectorLimitMeters = _anchorConnectorLimitMeters(normalizedMode);
      final radii =
          normalizedMode == 'portaging'
              ? const <double>[4000, 8000, 14000, 25000]
              : const <double>[3000, 6000, 10000, 18000];
      final expandedRadii =
          normalizedMode == 'portaging'
              ? const <double>[5000, 9000, 16000, 26000, 36000]
              : const <double>[4000, 8000, 14000, 22000, 30000];
      final globalFallbackCap =
          normalizedMode == 'portaging' ? 13000.0 : 9000.0;
      final expandedGlobalFallbackCap =
          normalizedMode == 'portaging' ? 22000.0 : 16000.0;
      final detourRetryThreshold = normalizedMode == 'portaging' ? 7.5 : 5.0;
      final nearbyComponentRadius =
          normalizedMode == 'portaging' ? 4200.0 : 2600.0;
      final expandedNearbyComponentRadius =
          normalizedMode == 'portaging' ? 7000.0 : 4500.0;
      final legs = <_TrailLegSolution>[];
      for (var leg = 0; leg + 1 < anchors.length; leg++) {
        final start = anchors[leg];
        final end = anchors[leg + 1];
        final startCandidates = _diversifyTrailCandidatesByComponent(
          anchor: start,
          baseCandidates: _nearestTrailCandidatesAdaptive(
            start,
            nodes,
            spatialIndex: spatialIndex,
            limit: 6,
            radiiMeters: radii,
            maxGlobalFallbackMeters: globalFallbackCap,
          ),
          nodes: nodes,
          spatialIndex: spatialIndex,
          componentIds: graphComponents.componentIds,
          componentSizes: graphComponents.componentSizes,
          limit: 6,
          nearbyRadiusMeters: nearbyComponentRadius,
        );
        final endCandidates = _diversifyTrailCandidatesByComponent(
          anchor: end,
          baseCandidates: _nearestTrailCandidatesAdaptive(
            end,
            nodes,
            spatialIndex: spatialIndex,
            limit: 6,
            radiiMeters: radii,
            maxGlobalFallbackMeters: globalFallbackCap,
          ),
          nodes: nodes,
          spatialIndex: spatialIndex,
          componentIds: graphComponents.componentIds,
          componentSizes: graphComponents.componentSizes,
          limit: 6,
          nearbyRadiusMeters: nearbyComponentRadius,
        );
        if (startCandidates.isEmpty || endCandidates.isEmpty) return null;

        _TrailPathResult? bestPath;
        _TrailCandidate? bestStart;
        _TrailCandidate? bestEnd;
        var bestLegScore = double.infinity;
        final treeCache = <int, ({List<double> dist, List<int> prev})>{};
        void considerCandidates(
          List<_TrailCandidate> starts,
          List<_TrailCandidate> ends,
        ) {
          if (starts.isEmpty || ends.isEmpty) return;
          for (final s in starts) {
            final tree = treeCache.putIfAbsent(
              s.index,
              () => _shortestTrailTreeFromSource(s.index, adjacency),
            );
            for (final e in ends) {
              final graphMeters = tree.dist[e.index];
              if (!graphMeters.isFinite) continue;
              final nodePath = _reconstructTrailNodePath(
                s.index,
                e.index,
                tree.prev,
              );
              if (nodePath == null || nodePath.isEmpty) continue;
              final score = s.meters + graphMeters + e.meters;
              if (score < bestLegScore) {
                bestLegScore = score;
                bestPath = _TrailPathResult(
                  nodePath: nodePath,
                  meters: graphMeters,
                );
                bestStart = s;
                bestEnd = e;
              }
            }
          }
        }

        considerCandidates(startCandidates, endCandidates);

        final directMeters = _haversineMeters(start, end);
        final shouldRetryWithExpandedCandidates =
            bestPath == null ||
            (directMeters > 1200.0 &&
                bestLegScore > directMeters * detourRetryThreshold);
        if (shouldRetryWithExpandedCandidates) {
          final expandedStart = _diversifyTrailCandidatesByComponent(
            anchor: start,
            baseCandidates: _nearestTrailCandidatesAdaptive(
              start,
              nodes,
              spatialIndex: spatialIndex,
              limit: 14,
              radiiMeters: expandedRadii,
              maxGlobalFallbackMeters: expandedGlobalFallbackCap,
            ),
            nodes: nodes,
            spatialIndex: spatialIndex,
            componentIds: graphComponents.componentIds,
            componentSizes: graphComponents.componentSizes,
            limit: 14,
            nearbyRadiusMeters: expandedNearbyComponentRadius,
            maxNewComponents: 5,
          );
          final expandedEnd = _diversifyTrailCandidatesByComponent(
            anchor: end,
            baseCandidates: _nearestTrailCandidatesAdaptive(
              end,
              nodes,
              spatialIndex: spatialIndex,
              limit: 14,
              radiiMeters: expandedRadii,
              maxGlobalFallbackMeters: expandedGlobalFallbackCap,
            ),
            nodes: nodes,
            spatialIndex: spatialIndex,
            componentIds: graphComponents.componentIds,
            componentSizes: graphComponents.componentSizes,
            limit: 14,
            nearbyRadiusMeters: expandedNearbyComponentRadius,
            maxNewComponents: 5,
          );
          if (expandedStart.isNotEmpty && expandedEnd.isNotEmpty) {
            considerCandidates(expandedStart, expandedEnd);
          }
        }
        if (bestPath == null || bestStart == null || bestEnd == null) {
          return null;
        }
        final legBestPath = bestPath!;
        final legBestStart = bestStart!;
        final legBestEnd = bestEnd!;
        legs.add(
          _TrailLegSolution(
            start: start,
            end: end,
            startCandidate: legBestStart,
            endCandidate: legBestEnd,
            nodePath: legBestPath.nodePath,
            graphMeters: legBestPath.meters,
          ),
        );
      }
      if (legs.isEmpty) return null;

      final startConnectorMetersByLeg = legs
          .map((leg) => leg.startCandidate.meters)
          .toList(growable: false);
      final endConnectorMetersByLeg = legs
          .map((leg) => leg.endCandidate.meters)
          .toList(growable: false);

      final path = <gmaps.LatLng>[];
      void appendDistinct(gmaps.LatLng p) {
        if (path.isNotEmpty) {
          final last = path.last;
          if ((last.latitude - p.latitude).abs() < 1e-7 &&
              (last.longitude - p.longitude).abs() < 1e-7) {
            return;
          }
        }
        path.add(p);
      }

      var totalMeters = 0.0;
      for (var legIndex = 0; legIndex < legs.length; legIndex++) {
        final leg = legs[legIndex];
        final includeStartAnchor = _waypointShouldUseAnchor(
          anchorIndex: legIndex,
          anchorCount: anchors.length,
          connectorLimitMeters: connectorLimitMeters,
          startConnectorMetersByLeg: startConnectorMetersByLeg,
          endConnectorMetersByLeg: endConnectorMetersByLeg,
        );
        final includeEndAnchor = _waypointShouldUseAnchor(
          anchorIndex: legIndex + 1,
          anchorCount: anchors.length,
          connectorLimitMeters: connectorLimitMeters,
          startConnectorMetersByLeg: startConnectorMetersByLeg,
          endConnectorMetersByLeg: endConnectorMetersByLeg,
        );

        if (legIndex == 0) {
          if (includeStartAnchor) {
            appendDistinct(leg.start);
          } else {
            appendDistinct(nodes[leg.startCandidate.index]);
          }
        } else {
          final prevLeg = legs[legIndex - 1];
          final prevEndNode = prevLeg.endCandidate.index;
          final currentStartNode = leg.startCandidate.index;
          if (includeStartAnchor) {
            appendDistinct(leg.start);
          } else if (prevEndNode != currentStartNode) {
            final bridge = _shortestTrailPath(
              prevEndNode,
              currentStartNode,
              adjacency,
            );
            if (bridge == null || bridge.nodePath.isEmpty) return null;
            for (final idx in bridge.nodePath) {
              appendDistinct(nodes[idx]);
            }
            totalMeters += bridge.meters;
          } else {
            appendDistinct(nodes[currentStartNode]);
          }
        }

        if (includeStartAnchor) {
          totalMeters += leg.startCandidate.meters;
        }
        for (final idx in leg.nodePath) {
          appendDistinct(nodes[idx]);
        }
        totalMeters += leg.graphMeters;
        if (includeEndAnchor) {
          appendDistinct(leg.end);
          totalMeters += leg.endCandidate.meters;
        }
      }

      if (path.length < 2) return null;

      final routeLabel =
          normalizedMode == 'portaging'
              ? 'Portage-trail route'
              : 'Trail-network route';

      return _RouteComputation(
        path: path,
        distanceMeters: totalMeters,
        durationSeconds: totalMeters / 1.2,
        color: _standardRouteColor(normalizedMode),
        width: 6,
        zIndex: 26,
        instructions: <String>[
          '$routeLabel (${(totalMeters / 1000.0).toStringAsFixed(1)} km)',
        ],
      );
    }

    final padAttempts = <double>[
      _trailRoutePadDegreesForMode(normalizedMode),
      _trailRoutePadDegreesForMode(normalizedMode, expanded: true),
    ];
    final attemptedCacheKeys = <String>{};
    for (
      var attemptIndex = 0;
      attemptIndex < padAttempts.length;
      attemptIndex++
    ) {
      final padDegrees = padAttempts[attemptIndex];
      final cacheKey = _hikingCacheKey(cacheAnchors, padDegrees: padDegrees);
      if (!attemptedCacheKeys.add(cacheKey)) continue;
      final entry = await _getHikingOverlayEntry(
        cacheKey: cacheKey,
        routePath: cacheAnchors,
        padDegrees: padDegrees,
      );
      final solved =
          entry == null
              ? null
              : solveWithEntry(
                entry,
                graphCacheKey:
                    'trail_route:$normalizedMode:$cacheKey:pad=${padDegrees.toStringAsFixed(2)}',
              );
      if (solved != null) {
        if (attemptIndex > 0) {
          debugPrint(
            'trailRoute expanded_bbox_success mode=$normalizedMode '
            'pad=${padDegrees.toStringAsFixed(2)} points=${solved.path.length}',
          );
        }
        return solved;
      }
    }

    final focusPadDegrees = _routeFocusPadDegrees(
      anchors,
      minPad: normalizedMode == 'portaging' ? 0.12 : 0.10,
      maxPad: normalizedMode == 'portaging' ? 0.24 : 0.20,
      edgePadding: normalizedMode == 'portaging' ? 0.08 : 0.06,
    );
    final focusCandidates = <gmaps.LatLng>[
      _routeBoundsCenter(anchors),
      anchors.last,
      anchors.first,
    ];
    final attemptedFocusKeys = <String>{};
    for (final focus in focusCandidates) {
      final focusPath = <gmaps.LatLng>[focus];
      final cacheKey = _hikingCacheKey(focusPath, padDegrees: focusPadDegrees);
      if (!attemptedFocusKeys.add(cacheKey)) continue;
      final entry = await _getHikingOverlayEntry(
        cacheKey: cacheKey,
        routePath: focusPath,
        padDegrees: focusPadDegrees,
      );
      final solved =
          entry == null
              ? null
              : solveWithEntry(
                entry,
                graphCacheKey:
                    'trail_route:$normalizedMode:$cacheKey:focus=${focusPadDegrees.toStringAsFixed(2)}',
              );
      if (solved != null) {
        debugPrint(
          'trailRoute focus_bbox_success mode=$normalizedMode '
          'pad=${focusPadDegrees.toStringAsFixed(2)} '
          'points=${solved.path.length}',
        );
        return solved;
      }
    }

    return null;
  }

  String _portagingRouteCacheKey(List<gmaps.LatLng> anchors) {
    return 'route:${_hikingCacheKey(anchors)}:portaging';
  }

  String _portagingFocusCacheKey(
    gmaps.LatLng focusPoint, {
    double padDegrees = 0.18,
  }) {
    final quantizedPad = _quantizedOverlayPadDegrees(padDegrees);
    final bucketSize = math.max(0.02, quantizedPad / 4.0);
    final lat = _roundToStep(focusPoint.latitude, bucketSize);
    final lon = _roundToStep(focusPoint.longitude, bucketSize);
    return 'focus:${lat.toStringAsFixed(3)},${lon.toStringAsFixed(3)}:'
        '${quantizedPad.toStringAsFixed(2)}';
  }

  ({
    List<gmaps.LatLng> nodes,
    List<List<_TrailEdge>> adjacency,
    _TrailSpatialIndex spatialIndex,
  })
  _buildGraphFromLines(
    List<List<gmaps.LatLng>> lines, {
    double bridgeToleranceMeters = 0.0,
    bool allowLoopBridges = false,
    double maxLoopBridgeMeters = 0.0,
  }) {
    final nodeByKey = <String, int>{};
    final nodes = <gmaps.LatLng>[];
    final adjacency = <List<_TrailEdge>>[];

    int ensureNode(gmaps.LatLng p) {
      final key = _trailNodeKey(p);
      final existing = nodeByKey[key];
      if (existing != null) return existing;
      final idx = nodes.length;
      nodeByKey[key] = idx;
      nodes.add(p);
      adjacency.add(<_TrailEdge>[]);
      return idx;
    }

    void addBidirectionalEdge(int a, int b) {
      if (a == b) return;
      final meters = _haversineMeters(nodes[a], nodes[b]);
      if (!meters.isFinite || meters <= 0.5) return;
      adjacency[a].add(_TrailEdge(to: b, meters: meters));
      adjacency[b].add(_TrailEdge(to: a, meters: meters));
    }

    for (final line in lines) {
      if (line.length < 2) continue;
      var prev = ensureNode(line.first);
      for (var i = 1; i < line.length; i++) {
        final cur = ensureNode(line[i]);
        addBidirectionalEdge(prev, cur);
        prev = cur;
      }
    }

    if (bridgeToleranceMeters > 0 && nodes.length >= 2) {
      _connectNearbyDeadEnds(
        nodes: nodes,
        adjacency: adjacency,
        maxBridgeMeters: bridgeToleranceMeters,
        allowLoopBridges: allowLoopBridges,
        maxLoopBridgeMeters: maxLoopBridgeMeters,
      );
    }

    return (
      nodes: nodes,
      adjacency: adjacency,
      spatialIndex: _TrailSpatialIndex.fromNodes(nodes),
    );
  }

  void _connectNearbyDeadEnds({
    required List<gmaps.LatLng> nodes,
    required List<List<_TrailEdge>> adjacency,
    required double maxBridgeMeters,
    bool allowLoopBridges = false,
    double maxLoopBridgeMeters = 0.0,
  }) {
    if (maxBridgeMeters <= 0 || nodes.length < 2) return;

    const minBridgeMeters = 10.0;
    const maxSyntheticEdgesPerNode = 3;
    final n = nodes.length;
    final neighbors = List<Set<int>>.generate(n, (_) => <int>{});
    for (var i = 0; i < adjacency.length; i++) {
      for (final edge in adjacency[i]) {
        if (edge.to < 0 || edge.to >= n) continue;
        neighbors[i].add(edge.to);
      }
    }
    final degree = List<int>.generate(n, (i) => neighbors[i].length);
    final endpointLike = <int>[
      for (var i = 0; i < n; i++)
        if (degree[i] <= 2) i,
    ];
    if (endpointLike.length < 2) return;

    var meanLat = 0.0;
    for (final p in nodes) {
      meanLat += p.latitude;
    }
    meanLat /= n;
    final lonScale = math
        .cos(meanLat * (math.pi / 180.0))
        .abs()
        .clamp(0.2, 1.0);
    const metersPerDeg = 111320.0;
    final projectedX = List<double>.filled(n, 0.0);
    final projectedY = List<double>.filled(n, 0.0);
    for (var i = 0; i < n; i++) {
      projectedX[i] = nodes[i].longitude * metersPerDeg * lonScale;
      projectedY[i] = nodes[i].latitude * metersPerDeg;
    }

    final cellSize = maxBridgeMeters;
    final buckets = <String, List<int>>{};
    for (final i in endpointLike) {
      final cx = (projectedX[i] / cellSize).floor();
      final cy = (projectedY[i] / cellSize).floor();
      final key = '$cx,$cy';
      buckets.putIfAbsent(key, () => <int>[]).add(i);
    }

    final maxSq = maxBridgeMeters * maxBridgeMeters;
    final minSq = minBridgeMeters * minBridgeMeters;
    final maxLoopSq =
        maxLoopBridgeMeters > 0
            ? maxLoopBridgeMeters * maxLoopBridgeMeters
            : 0.0;
    final syntheticCounts = List<int>.filled(n, 0);
    int syntheticLimitForNode(int node) {
      if (node < 0 || node >= degree.length) return 1;
      // Closed polygon vertices (degree=2) can create many accidental links.
      // Keep them to at most one synthetic bridge.
      if (degree[node] > 1) return 1;
      return maxSyntheticEdgesPerNode;
    }

    for (final i in endpointLike) {
      if (syntheticCounts[i] >= syntheticLimitForNode(i)) continue;
      final cx = (projectedX[i] / cellSize).floor();
      final cy = (projectedY[i] / cellSize).floor();
      final candidates = <(int node, double distSq)>[];

      for (var dx = -1; dx <= 1; dx++) {
        for (var dy = -1; dy <= 1; dy++) {
          final key = '${cx + dx},${cy + dy}';
          final list = buckets[key];
          if (list == null || list.isEmpty) continue;
          for (final j in list) {
            if (j <= i) continue;
            if (neighbors[i].contains(j)) continue;
            if (syntheticCounts[j] >= syntheticLimitForNode(j)) continue;
            final dxMeters = projectedX[i] - projectedX[j];
            final dyMeters = projectedY[i] - projectedY[j];
            final distSq = dxMeters * dxMeters + dyMeters * dyMeters;
            if (distSq < minSq || distSq > maxSq) continue;
            final bothLoopLike = degree[i] > 1 && degree[j] > 1;
            if (bothLoopLike) {
              if (!allowLoopBridges) continue;
              if (maxLoopSq <= 0.0 || distSq > maxLoopSq) continue;
            }
            candidates.add((j, distSq));
          }
        }
      }

      candidates.sort((a, b) => a.$2.compareTo(b.$2));
      for (final candidate in candidates) {
        if (syntheticCounts[i] >= syntheticLimitForNode(i)) break;
        final j = candidate.$1;
        if (syntheticCounts[j] >= syntheticLimitForNode(j)) continue;
        if (neighbors[i].contains(j)) continue;
        final meters = math.sqrt(candidate.$2);
        if (!meters.isFinite || meters <= 0.0) continue;
        adjacency[i].add(_TrailEdge(to: j, meters: meters));
        adjacency[j].add(_TrailEdge(to: i, meters: meters));
        neighbors[i].add(j);
        neighbors[j].add(i);
        syntheticCounts[i]++;
        syntheticCounts[j]++;
      }
    }
  }

  List<double> _dijkstraFromSources(
    List<int> sources,
    List<List<_TrailEdge>> adjacency,
  ) {
    final n = adjacency.length;
    final dist = List<double>.filled(n, double.infinity);
    final heap = _MinNodeHeap();
    for (final s in sources) {
      if (s < 0 || s >= n) continue;
      dist[s] = 0.0;
      heap.add(_NodeDistance(s, 0.0));
    }

    while (!heap.isEmpty) {
      final current = heap.removeFirst();
      final u = current.node;
      final best = current.meters;
      if (best > dist[u] + 1e-9) continue;

      for (final edge in adjacency[u]) {
        final alt = dist[u] + edge.meters;
        if (alt + 1e-9 < dist[edge.to]) {
          dist[edge.to] = alt;
          heap.add(_NodeDistance(edge.to, alt));
        }
      }
    }

    return dist;
  }

  Future<_PortagingOverlayCacheEntry?> _fetchPortagingOverlayData({
    required List<gmaps.LatLng> anchors,
    gmaps.LatLng? focusPoint,
    double padDegrees = 0.18,
    bool includeCampsites = true,
  }) async {
    if (anchors.isEmpty && focusPoint == null) return null;

    double south;
    double west;
    double north;
    double east;

    if (focusPoint != null) {
      south = focusPoint.latitude - padDegrees;
      west = focusPoint.longitude - padDegrees;
      north = focusPoint.latitude + padDegrees;
      east = focusPoint.longitude + padDegrees;
    } else {
      var minLat = double.infinity;
      var maxLat = -double.infinity;
      var minLon = double.infinity;
      var maxLon = -double.infinity;
      for (final p in anchors) {
        minLat = math.min(minLat, p.latitude);
        maxLat = math.max(maxLat, p.latitude);
        minLon = math.min(minLon, p.longitude);
        maxLon = math.max(maxLon, p.longitude);
      }
      south = minLat - padDegrees;
      west = minLon - padDegrees;
      north = maxLat + padDegrees;
      east = maxLon + padDegrees;
    }

    final campsiteQuery =
        includeCampsites
            ? '''
  node["tourism"~"camp_site|camp_pitch"]($south,$west,$north,$east);
  way["tourism"~"camp_site|camp_pitch"]($south,$west,$north,$east);
  relation["tourism"~"camp_site|camp_pitch"]($south,$west,$north,$east);
'''
            : '';
    final relationWaterQuery = '''
  relation["natural"="water"]($south,$west,$north,$east);
  relation["route"="canoe"]($south,$west,$north,$east);
''';
    final relationAccessQuery = '''
  relation["canoe"~"put_in|take_out|yes"]($south,$west,$north,$east);
  relation["portage"~"yes|put_in|take_out"]($south,$west,$north,$east);
  relation["name"~"access point|put[ -]?in|take[ -]?out|boat launch|canoe launch|landing",i]($south,$west,$north,$east);
''';

    final query = '''
[out:json][timeout:25];
(
  way["waterway"~"river|stream|canal|drain|ditch"]($south,$west,$north,$east);
  way["natural"="water"]($south,$west,$north,$east);
  way["route"="canoe"]($south,$west,$north,$east);
$relationWaterQuery
  way["highway"~"path|footway|track"]["canoe"~"portage|yes"]($south,$west,$north,$east);
  way["portage"~"yes|designated|official"]($south,$west,$north,$east);
  way["canoe"="portage"]($south,$west,$north,$east);
$campsiteQuery
  node["canoe"~"put_in|take_out|yes"]($south,$west,$north,$east);
  way["canoe"~"put_in|take_out|yes"]($south,$west,$north,$east);
  node["portage"~"yes|put_in|take_out"]($south,$west,$north,$east);
  way["portage"~"yes|put_in|take_out"]($south,$west,$north,$east);
  node["amenity"="boat_ramp"]($south,$west,$north,$east);
  way["amenity"="boat_ramp"]($south,$west,$north,$east);
  node["leisure"="slipway"]($south,$west,$north,$east);
  way["leisure"="slipway"]($south,$west,$north,$east);
  node["name"~"access point|put[ -]?in|take[ -]?out|boat launch|canoe launch|landing",i]($south,$west,$north,$east);
  way["name"~"access point|put[ -]?in|take[ -]?out|boat launch|canoe launch|landing",i]($south,$west,$north,$east);
$relationAccessQuery
);
out body geom;
''';

    var data = await _fetchOverpassData(
      query: query,
      logPrefix: 'portagingOverpass',
      requestTimeout: const Duration(seconds: 12),
    );
    if (data == null && focusPoint != null) {
      final litePadDegrees = math.min(padDegrees, 0.12);
      final liteSouth = focusPoint.latitude - litePadDegrees;
      final liteWest = focusPoint.longitude - litePadDegrees;
      final liteNorth = focusPoint.latitude + litePadDegrees;
      final liteEast = focusPoint.longitude + litePadDegrees;
      final liteCampsiteQuery =
          includeCampsites
              ? '''
  node["tourism"~"camp_site|camp_pitch"]($liteSouth,$liteWest,$liteNorth,$liteEast);
'''
              : '';
      final liteQuery = '''
[out:json][timeout:18];
(
  way["waterway"~"river|stream|canal|drain|ditch"]($liteSouth,$liteWest,$liteNorth,$liteEast);
  way["natural"="water"]($liteSouth,$liteWest,$liteNorth,$liteEast);
  way["route"="canoe"]($liteSouth,$liteWest,$liteNorth,$liteEast);
  way["highway"~"path|footway|track"]["canoe"~"portage|yes"]($liteSouth,$liteWest,$liteNorth,$liteEast);
  way["portage"~"yes|designated|official"]($liteSouth,$liteWest,$liteNorth,$liteEast);
  way["canoe"="portage"]($liteSouth,$liteWest,$liteNorth,$liteEast);
$liteCampsiteQuery
  node["canoe"~"put_in|take_out|yes"]($liteSouth,$liteWest,$liteNorth,$liteEast);
  way["canoe"~"put_in|take_out|yes"]($liteSouth,$liteWest,$liteNorth,$liteEast);
  node["portage"~"yes|put_in|take_out"]($liteSouth,$liteWest,$liteNorth,$liteEast);
  way["portage"~"yes|put_in|take_out"]($liteSouth,$liteWest,$liteNorth,$liteEast);
  node["amenity"="boat_ramp"]($liteSouth,$liteWest,$liteNorth,$liteEast);
  way["amenity"="boat_ramp"]($liteSouth,$liteWest,$liteNorth,$liteEast);
  node["leisure"="slipway"]($liteSouth,$liteWest,$liteNorth,$liteEast);
  way["leisure"="slipway"]($liteSouth,$liteWest,$liteNorth,$liteEast);
  node["name"~"access point|put[ -]?in|take[ -]?out|boat launch|canoe launch|landing",i]($liteSouth,$liteWest,$liteNorth,$liteEast);
  way["name"~"access point|put[ -]?in|take[ -]?out|boat launch|canoe launch|landing",i]($liteSouth,$liteWest,$liteNorth,$liteEast);
);
out body geom;
''';
      data = await _fetchOverpassData(
        query: liteQuery,
        logPrefix: 'portagingOverpassLite',
        requestTimeout: const Duration(seconds: 8),
        ignoreCooldown: true,
      );
    }
    if (data == null) return null;

    final elements = (data['elements'] as List<dynamic>?) ?? const [];
    final waterLines = <List<gmaps.LatLng>>[];
    final waterPolygons = <List<gmaps.LatLng>>[];
    final portageLines = <List<gmaps.LatLng>>[];
    final campsites = <Map<String, dynamic>>[];
    final accessPoints = <Map<String, dynamic>>[];
    final seenCampKeys = <String>{};
    final seenAccessKeys = <String>{};
    final seenWaterPolygonKeys = <String>{};

    for (final e in elements) {
      final m = (e as Map).cast<String, dynamic>();
      final type = (m['type'] ?? '').toString();
      final tags = (m['tags'] as Map?)?.cast<String, dynamic>() ?? const {};

      bool isPortageTags(Map<String, dynamic> t) {
        final portage = (t['portage'] ?? '').toString().toLowerCase();
        final canoe = (t['canoe'] ?? '').toString().toLowerCase();
        final route = (t['route'] ?? '').toString().toLowerCase();
        final highway = (t['highway'] ?? '').toString().toLowerCase();
        if (portage == 'yes' ||
            portage == 'designated' ||
            portage == 'official') {
          return true;
        }
        if (canoe == 'portage') return true;
        if (route == 'portage') return true;
        if ((highway == 'path' || highway == 'footway' || highway == 'track') &&
            (canoe.isNotEmpty || portage.isNotEmpty)) {
          return true;
        }
        return false;
      }

      bool isWaterTags(Map<String, dynamic> t) {
        final waterway = (t['waterway'] ?? '').toString().toLowerCase();
        final route = (t['route'] ?? '').toString().toLowerCase();
        final natural = (t['natural'] ?? '').toString().toLowerCase();
        final canoe = (t['canoe'] ?? '').toString().toLowerCase();
        if (waterway.isNotEmpty) return true;
        if (route == 'canoe') return true;
        if (natural == 'water') return true;
        if (canoe == 'yes') return true;
        return false;
      }

      bool isNaturalWaterTags(Map<String, dynamic> t) {
        final natural = (t['natural'] ?? '').toString().toLowerCase();
        return natural == 'water';
      }

      bool isCampTags(Map<String, dynamic> t) {
        final tourism = (t['tourism'] ?? '').toString().toLowerCase();
        return tourism == 'camp_site' || tourism == 'camp_pitch';
      }

      bool isAccessTags(Map<String, dynamic> t) {
        final canoeTag = (t['canoe'] ?? '').toString().toLowerCase();
        final portageTag = (t['portage'] ?? '').toString().toLowerCase();
        final amenity = (t['amenity'] ?? '').toString().toLowerCase();
        final leisure = (t['leisure'] ?? '').toString().toLowerCase();
        final name = (t['name'] ?? '').toString().toLowerCase();
        if (canoeTag == 'put_in' ||
            canoeTag == 'take_out' ||
            canoeTag == 'yes') {
          return true;
        }
        if (portageTag == 'put_in' ||
            portageTag == 'take_out' ||
            portageTag == 'yes') {
          return true;
        }
        if (amenity == 'boat_ramp' || leisure == 'slipway') {
          return true;
        }
        if (name.contains('access point') ||
            name.contains('put in') ||
            name.contains('put-in') ||
            name.contains('take out') ||
            name.contains('take-out') ||
            name.contains('boat launch') ||
            name.contains('canoe launch') ||
            name.contains('landing')) {
          return true;
        }
        return false;
      }

      List<gmaps.LatLng> geometryToLine(List<dynamic> geom) {
        final line = <gmaps.LatLng>[];
        for (final g in geom) {
          final gm = (g as Map).cast<String, dynamic>();
          final lat = (gm['lat'] as num?)?.toDouble();
          final lon = (gm['lon'] as num?)?.toDouble();
          if (lat == null || lon == null) continue;
          line.add(gmaps.LatLng(lat, lon));
        }
        return line;
      }

      List<gmaps.LatLng>? normalizeClosedWaterRing(List<gmaps.LatLng> ring) {
        if (ring.length < 4) return null;
        final first = ring.first;
        final last = ring.last;
        final closeMeters = _haversineMeters(first, last);
        if (!closeMeters.isFinite || closeMeters > 45.0) return null;
        final out = <gmaps.LatLng>[...ring];
        if (closeMeters > 2.0) {
          out.add(first);
        }
        if (out.length < 4) return null;
        final key = out
            .map(
              (p) =>
                  '${p.latitude.toStringAsFixed(4)},${p.longitude.toStringAsFixed(4)}',
            )
            .join(';');
        if (!seenWaterPolygonKeys.add(key)) return null;
        return out;
      }

      gmaps.LatLng? centroidFromLine(List<gmaps.LatLng> line) {
        if (line.isEmpty) return null;
        var latSum = 0.0;
        var lonSum = 0.0;
        for (final p in line) {
          latSum += p.latitude;
          lonSum += p.longitude;
        }
        return gmaps.LatLng(latSum / line.length, lonSum / line.length);
      }

      gmaps.LatLng? centroidFromMembers(List<dynamic> members) {
        var latSum = 0.0;
        var lonSum = 0.0;
        var count = 0;
        for (final member in members) {
          final mm = (member as Map).cast<String, dynamic>();
          final geom = (mm['geometry'] as List<dynamic>?) ?? const [];
          for (final g in geom) {
            final gm = (g as Map).cast<String, dynamic>();
            final lat = (gm['lat'] as num?)?.toDouble();
            final lon = (gm['lon'] as num?)?.toDouble();
            if (lat == null || lon == null) continue;
            latSum += lat;
            lonSum += lon;
            count++;
          }
        }
        if (count == 0) return null;
        return gmaps.LatLng(latSum / count, lonSum / count);
      }

      void addCamp({
        required String name,
        required double lat,
        required double lon,
        Map<String, dynamic> tags = const <String, dynamic>{},
        String sourceType = 'campsite',
      }) {
        final key = '${lat.toStringAsFixed(5)},${lon.toStringAsFixed(5)}';
        if (!seenCampKeys.add(key)) return;
        final camp = <String, dynamic>{
          'name': name,
          'lat': lat,
          'lon': lon,
          'sourceType': sourceType,
        };
        void copyTag(String sourceKey, String targetKey) {
          final value = (tags[sourceKey] ?? '').toString().trim();
          if (value.isNotEmpty) camp[targetKey] = value;
        }

        copyTag('operator', 'operator');
        copyTag('access', 'access');
        copyTag('capacity', 'capacity');
        copyTag('description', 'description');
        copyTag('website', 'website');
        copyTag('url', 'website');
        copyTag('park', 'park');
        copyTag('park:name', 'park');
        copyTag('addr:place', 'lakeName');
        copyTag('loc_name', 'lakeName');
        campsites.add(camp);
      }

      void addAccess({
        required String name,
        required double lat,
        required double lon,
      }) {
        final key = '${lat.toStringAsFixed(5)},${lon.toStringAsFixed(5)}';
        if (!seenAccessKeys.add(key)) return;
        accessPoints.add(<String, dynamic>{
          'name': name,
          'lat': lat,
          'lon': lon,
        });
      }

      if (type == 'way') {
        final geom = (m['geometry'] as List<dynamic>?) ?? const [];
        final line = geometryToLine(geom);
        if (line.length < 2) continue;
        final isPortage = isPortageTags(tags);
        final isWater = isWaterTags(tags);
        final isNaturalWater = isNaturalWaterTags(tags);
        if (isWater) waterLines.add(line);
        if (isNaturalWater) {
          final ring = normalizeClosedWaterRing(line);
          if (ring != null) waterPolygons.add(ring);
        }
        if (isPortage) portageLines.add(line);
        final center = centroidFromLine(line);
        if (center != null && isCampTags(tags)) {
          addCamp(
            name: (tags['name'] ?? 'Campsite').toString(),
            lat: center.latitude,
            lon: center.longitude,
            tags: tags,
            sourceType: type,
          );
        }
        if (center != null && isAccessTags(tags)) {
          addAccess(
            name: (tags['name'] ?? 'Portage access').toString(),
            lat: center.latitude,
            lon: center.longitude,
          );
        }
      } else if (type == 'relation') {
        final natural = (tags['natural'] ?? '').toString().toLowerCase();
        final route = (tags['route'] ?? '').toString().toLowerCase();
        final members = (m['members'] as List<dynamic>?) ?? const [];
        if (natural == 'water') {
          for (final member in members) {
            final mm = (member as Map).cast<String, dynamic>();
            final geom = (mm['geometry'] as List<dynamic>?) ?? const [];
            final line = geometryToLine(geom);
            if (line.length >= 2) waterLines.add(line);
            final ring = normalizeClosedWaterRing(line);
            if (ring != null) waterPolygons.add(ring);
          }
        }
        if (route == 'canoe') {
          for (final member in members) {
            final mm = (member as Map).cast<String, dynamic>();
            final geom = (mm['geometry'] as List<dynamic>?) ?? const [];
            final line = geometryToLine(geom);
            if (line.length >= 2) waterLines.add(line);
          }
        }
        final center = centroidFromMembers(members);
        if (center != null && isCampTags(tags)) {
          addCamp(
            name: (tags['name'] ?? 'Campsite').toString(),
            lat: center.latitude,
            lon: center.longitude,
            tags: tags,
            sourceType: type,
          );
        }
        if (center != null && isAccessTags(tags)) {
          addAccess(
            name: (tags['name'] ?? 'Portage access').toString(),
            lat: center.latitude,
            lon: center.longitude,
          );
        }
      } else if (type == 'node') {
        final lat = (m['lat'] as num?)?.toDouble();
        final lon = (m['lon'] as num?)?.toDouble();
        if (lat == null || lon == null) continue;
        if (isCampTags(tags)) {
          addCamp(
            name: (tags['name'] ?? 'Campsite').toString(),
            lat: lat,
            lon: lon,
            tags: tags,
            sourceType: type,
          );
        }
        if (isAccessTags(tags)) {
          addAccess(
            name: (tags['name'] ?? 'Portage access').toString(),
            lat: lat,
            lon: lon,
          );
        }
      }
    }

    final geoJson = _toGeoJson(
      <List<gmaps.LatLng>>[...waterLines, ...portageLines],
      campsites,
      accessPoints,
    );
    debugPrint(
      'portagingOverpass converted water=${waterLines.length} polygons=${waterPolygons.length} portage=${portageLines.length} campsites=${campsites.length} access=${accessPoints.length}',
    );
    return _PortagingOverlayCacheEntry(
      fetchedAt: DateTime.now(),
      waterLines: waterLines,
      waterPolygons: waterPolygons,
      portageLines: portageLines,
      campsites: campsites,
      accessPoints: accessPoints,
      geoJson: geoJson,
    );
  }

  Future<_RouteComputation?> _routeViaPortageGraph(
    List<Map<String, dynamic>> segPoints, {
    bool forceFocusLookup = false,
  }) async {
    if (segPoints.length < 2) return null;
    final routeStartedAt = DateTime.now();
    final anchors = _segmentLatLngs(segPoints);
    if (anchors.length < 2) return null;
    Future<_RouteComputation?> retryWithFocusLookup(String reason) async {
      if (forceFocusLookup) return null;
      debugPrint('portageRoute retry_focus_lookup reason=$reason');
      return _routeViaPortageGraph(segPoints, forceFocusLookup: true);
    }

    // Route each leg against a local graph envelope. Using the full trip anchor
    // set here causes very large graph builds on long canoe routes and can hang
    // the web tab before any route is committed.
    final routeFetchAnchors = anchors;
    final routeBaseCacheKey = _portagingRouteCacheKey(routeFetchAnchors);
    final cacheKey = '$routeBaseCacheKey:route-lite';
    final routePadDegrees = _adaptivePortageRoutePadDegrees(routeFetchAnchors);
    _PortagingOverlayCacheEntry? entry;
    if (!forceFocusLookup) {
      entry = await _getPortagingOverlayEntry(
        cacheKey: cacheKey,
        anchors: routeFetchAnchors,
        padDegrees: routePadDegrees,
        includeCampsites: true,
      );
      if (entry == null) {
        final cachedRouteEntry = _portagingOverlayCache[routeBaseCacheKey];
        if (cachedRouteEntry != null) {
          entry = cachedRouteEntry;
          debugPrint(
            'portageRoute using_overlay_route_cache key=$routeBaseCacheKey '
            'water=${entry.waterLines.length} portage=${entry.portageLines.length}',
          );
        }
      }
    }
    if (entry == null) {
      final focusPadDegrees = _routeFocusPadDegrees(
        anchors,
        minPad: 0.12,
        maxPad: 0.24,
        edgePadding: 0.08,
      );
      final focusCandidates = _portagingOverlayFocusPoints(
        routePath: anchors,
        modeAnchors: anchors,
        focusPoint: _routeBoundsCenter(anchors),
        maxPoints: 5,
      );
      final attemptedFocusKeys = <String>{cacheKey};
      for (final focus in focusCandidates) {
        final focusCacheKey = _portagingFocusCacheKey(
          focus,
          padDegrees: focusPadDegrees,
        );
        if (!attemptedFocusKeys.add(focusCacheKey)) continue;
        final focusEntry = await _getPortagingOverlayEntry(
          cacheKey: focusCacheKey,
          anchors: <gmaps.LatLng>[focus],
          focusPoint: focus,
          padDegrees: focusPadDegrees,
          includeCampsites: true,
        );
        if (focusEntry == null) continue;
        entry = focusEntry;
        debugPrint(
          'portageRoute using_focus_cache key=$focusCacheKey '
          'pad=${focusPadDegrees.toStringAsFixed(2)}',
        );
        break;
      }
    }
    if (entry == null && _lastVisiblePortagingOverlayEntry != null) {
      final visibleEntry = _lastVisiblePortagingOverlayEntry!;
      entry = visibleEntry;
      debugPrint(
        'portageRoute using_visible_overlay_cache '
        'water=${visibleEntry.waterLines.length} '
        'portage=${visibleEntry.portageLines.length} '
        'access=${visibleEntry.accessPoints.length}',
      );
    }
    if (entry == null) return null;

    final routeWaterLines = _selectGraphLinesForAnchors(
      entry.waterLines,
      anchors,
      maxLines: 260,
      bboxPadDegrees: 0.06,
      debugLabel: 'portageRouteWater',
    );
    final routePortageLines = _selectGraphLinesForAnchors(
      entry.portageLines,
      anchors,
      maxLines: 80,
      bboxPadDegrees: 0.04,
      debugLabel: 'portageRouteCarry',
      distanceSamples: 6,
    );
    final networkLines = <List<gmaps.LatLng>>[
      ...routeWaterLines,
      ...routePortageLines,
    ];
    if (networkLines.isEmpty) {
      return await retryWithFocusLookup('network_lines_empty');
    }

    if (anchors.length == 2) {
      final sameLineRoute = _fastPortageRouteAlongSameLine(
        start: anchors.first,
        end: anchors.last,
        waterLines: routeWaterLines,
        portageLines: routePortageLines,
        entry: entry,
      );
      if (sameLineRoute != null) {
        final elapsedMs =
            DateTime.now().difference(routeStartedAt).inMilliseconds;
        debugPrint(
          'portageRoute same_line_fallback kind=${sameLineRoute.lineKind} '
          'meters=${sameLineRoute.distanceMeters.toStringAsFixed(0)} '
          'ms=$elapsedMs',
        );
        final styledSegments = _buildPortagingStyledSegments(
          path: sameLineRoute.path,
          entry: entry,
          width: 6,
          zIndex: 28,
        );
        return _RouteComputation(
          path: sameLineRoute.path,
          distanceMeters: sameLineRoute.distanceMeters,
          durationSeconds: sameLineRoute.distanceMeters / 1.35,
          color: _standardRouteColor('portaging'),
          width: 6,
          zIndex: 28,
          styledSegments: styledSegments,
          instructions: <String>[
            'Portage-waterline route (${(sameLineRoute.distanceMeters / 1000.0).toStringAsFixed(1)} km)',
          ],
        );
      }
    }

    final waterFirstLegs = <_PortageWaterFirstLegSolution>[];
    var solvedWaterFirst = true;
    for (var leg = 0; leg + 1 < anchors.length; leg++) {
      final legAnchors = <gmaps.LatLng>[anchors[leg], anchors[leg + 1]];
      final legWaterLines = _selectGraphLinesForAnchors(
        routeWaterLines,
        legAnchors,
        maxLines: 120,
        bboxPadDegrees: 0.035,
        debugLabel: 'portageLegWater',
      );
      final legPortageLines = _selectGraphLinesForAnchors(
        routePortageLines,
        legAnchors,
        maxLines: 42,
        bboxPadDegrees: 0.03,
        debugLabel: 'portageLegCarry',
        distanceSamples: 5,
      );
      final legSolution = _solveWaterFirstPortageLeg(
        start: legAnchors.first,
        end: legAnchors.last,
        waterLines: legWaterLines,
        portageLines: legPortageLines,
        entry: entry,
      );
      if (legSolution == null) {
        solvedWaterFirst = false;
        break;
      }
      waterFirstLegs.add(legSolution);
      await Future<void>.delayed(Duration.zero);
    }

    if (solvedWaterFirst && waterFirstLegs.isNotEmpty) {
      final combined = _combinePortageLegPaths(waterFirstLegs);
      var solvedPath = combined.path;
      var solvedMeters = combined.distanceMeters;
      final offRamp =
          anchors.length == 2
              ? _trimPortagingPathToWaterOffRamp(
                path: solvedPath,
                destination: anchors.last,
                entry: entry,
              )
              : null;
      if (offRamp != null) {
        solvedPath = offRamp.path;
        solvedMeters = offRamp.distanceMeters;
      }

      final elapsedMs =
          DateTime.now().difference(routeStartedAt).inMilliseconds;
      debugPrint(
        'portageRoute solved_water_first legs=${waterFirstLegs.length} '
        'offRampApplied=${offRamp != null} ms=$elapsedMs',
      );
      final styledSegments = _buildPortagingStyledSegments(
        path: solvedPath,
        entry: entry,
        width: 6,
        zIndex: 28,
      );
      return _RouteComputation(
        path: solvedPath,
        distanceMeters: solvedMeters,
        durationSeconds: solvedMeters / 1.35,
        color: _standardRouteColor('portaging'),
        width: 6,
        zIndex: 28,
        styledSegments: styledSegments,
        instructions: <String>[
          'Portage-water route (${(solvedMeters / 1000.0).toStringAsFixed(1)} km)',
        ],
      );
    }

    final graph = _graphForLines(
      networkLines,
      cacheKey: 'portage_route:$cacheKey',
      bridgeToleranceMeters: 320.0,
      allowLoopBridges: true,
      maxLoopBridgeMeters: 140.0,
    );
    final nodes = graph.nodes;
    final adjacency = graph.adjacency;
    final spatialIndex = graph.spatialIndex;
    if (nodes.length < 2) {
      return await retryWithFocusLookup('graph_nodes_lt_2');
    }
    final nodeIndexByKey = <String, int>{
      for (var i = 0; i < nodes.length; i++) _trailNodeKey(nodes[i]): i,
    };
    // Skip routing on excessively large graphs (would hang the UI thread).
    if (nodes.length > 12000) {
      debugPrint('portageRoute skipped_too_large nodes=${nodes.length}');
      return null;
    }
    final accessCoords = <gmaps.LatLng>[];
    for (final access in entry.accessPoints) {
      final lat = (access['lat'] as num?)?.toDouble();
      final lon = (access['lon'] as num?)?.toDouble();
      if (lat == null || lon == null) continue;
      accessCoords.add(gmaps.LatLng(lat, lon));
    }

    final path = <gmaps.LatLng>[];
    void appendDistinct(gmaps.LatLng p) {
      if (path.isNotEmpty) {
        final last = path.last;
        if ((last.latitude - p.latitude).abs() < 1e-7 &&
            (last.longitude - p.longitude).abs() < 1e-7) {
          return;
        }
      }
      path.add(p);
    }

    const portageRadii = <double>[5000, 9000, 16000, 26000];
    const expandedPortageRadii = <double>[6000, 11000, 19000, 30000, 42000];
    const legTimeBudgetMs = 4500; // keep slow legs from freezing the web UI
    final legs = <_PortageLegSolution>[];
    for (var leg = 0; leg + 1 < anchors.length; leg++) {
      final legStopwatch = Stopwatch()..start();
      final start = anchors[leg];
      final end = anchors[leg + 1];
      final startAnchor = _resolvePortagingGraphAnchor(
        start,
        nodes,
        spatialIndex,
        accessCoords,
      );
      final endAnchor = _resolvePortagingGraphAnchor(
        end,
        nodes,
        spatialIndex,
        accessCoords,
      );

      var startCandidates = _portageGraphCandidatesForAnchor(
        anchor: start,
        nodes: nodes,
        spatialIndex: spatialIndex,
        accessPoints: accessCoords,
        entry: entry,
        limit: 6,
        radiiMeters: portageRadii,
        maxGlobalFallbackMeters: 13000,
      );
      startCandidates = _mergePortageCandidateGroups([
        startCandidates,
        _snapPortageCandidatesToSegments(
          anchor: start,
          lines: networkLines,
          nodeIndexByKey: nodeIndexByKey,
          entry: entry,
          limit: 6,
          maxAnchorMeters: 14000.0,
          maxLineDistanceMeters: 16000.0,
          maxAlongSegmentMeters: 24000.0,
          resolvedAnchor: startAnchor,
        ),
      ], softLimit: 12);
      startCandidates = _augmentPortageCandidatesViaOpenWater(
        anchor: start,
        resolvedAnchor: startAnchor,
        baseCandidates: startCandidates,
        nodes: nodes,
        spatialIndex: spatialIndex,
        entry: entry,
        maxExtraCandidates: 6,
        maxReachMeters: 7000.0,
      );
      var endCandidates = _portageGraphCandidatesForAnchor(
        anchor: end,
        nodes: nodes,
        spatialIndex: spatialIndex,
        accessPoints: accessCoords,
        entry: entry,
        limit: 6,
        radiiMeters: portageRadii,
        maxGlobalFallbackMeters: 13000,
      );
      endCandidates = _mergePortageCandidateGroups([
        endCandidates,
        _snapPortageCandidatesToSegments(
          anchor: end,
          lines: networkLines,
          nodeIndexByKey: nodeIndexByKey,
          entry: entry,
          limit: 6,
          maxAnchorMeters: 14000.0,
          maxLineDistanceMeters: 16000.0,
          maxAlongSegmentMeters: 24000.0,
          resolvedAnchor: endAnchor,
        ),
      ], softLimit: 12);
      endCandidates = _augmentPortageCandidatesViaOpenWater(
        anchor: end,
        resolvedAnchor: endAnchor,
        baseCandidates: endCandidates,
        nodes: nodes,
        spatialIndex: spatialIndex,
        entry: entry,
        maxExtraCandidates: 6,
        maxReachMeters: 7000.0,
      );
      if (startCandidates.isEmpty || endCandidates.isEmpty) {
        debugPrint(
          'portageRoute leg_unanchored leg=$leg '
          'startOptions=${startCandidates.length} endOptions=${endCandidates.length} '
          'startAccess=${startAnchor.usedAccess}(${startAnchor.connectorMeters.toStringAsFixed(0)}m) '
          'endAccess=${endAnchor.usedAccess}(${endAnchor.connectorMeters.toStringAsFixed(0)}m)',
        );
        return await retryWithFocusLookup('leg_${leg}_unanchored');
      }

      List<int>? bestPrev;
      _PortageGraphCandidate? bestStartCandidate;
      _PortageGraphCandidate? bestEndCandidate;
      var bestStartNode = -1;
      var bestEndNode = -1;
      var bestGraphMeters = double.infinity;
      var bestLegScore = double.infinity;
      List<gmaps.LatLng>? bestLegPathPoints;
      final waterSafePairCache = <String, bool>{};

      // Fewer samples for large datasets to keep each pair check fast.
      final waterSafeSamples =
          entry.waterLines.length > 150 || entry.waterPolygons.length > 60
              ? 12
              : 40;

      bool isSafeNodePair(int a, int b) {
        if (a < 0 ||
            b < 0 ||
            a >= nodes.length ||
            b >= nodes.length ||
            a == b) {
          return false;
        }
        final minIdx = math.min(a, b);
        final maxIdx = math.max(a, b);
        final key = '$minIdx:$maxIdx';
        return waterSafePairCache.putIfAbsent(
          key,
          () => _isWaterSafeDirectSegment(
            nodes[a],
            nodes[b],
            entry!,
            maxSamples: waterSafeSamples,
          ),
        );
      }

      var waterSafeChecksUsed = 0;
      // Budget more checks for large datasets since they have more
      // disconnected components that need direct-water bridges.
      final maxWaterSafeChecks =
          entry.waterLines.length > 150 || entry.waterPolygons.length > 60
              ? 20
              : 30;

      void considerCandidates(
        List<_PortageGraphCandidate> starts,
        List<_PortageGraphCandidate> ends,
      ) {
        final endNodeSet = ends.map((c) => c.index).toSet();
        for (final s in starts) {
          // Honour per-leg time budget.
          if (legStopwatch.elapsedMilliseconds > legTimeBudgetMs) break;

          final startConnectorScore = _portageConnectorScore(
            s.totalConnectorMeters,
          );
          final tree = _shortestTrailTreeFromSource(
            s.index,
            adjacency,
            stopNodes: endNodeSet,
          );
          for (final e in ends) {
            // Inner-loop time check so a single start iteration can't
            // consume the entire budget.
            if (legStopwatch.elapsedMilliseconds > legTimeBudgetMs) break;

            final endConnectorScore = _portageConnectorScore(
              e.totalConnectorMeters,
            );
            final graphMeters = tree.dist[e.index];
            if (graphMeters.isFinite) {
              final score =
                  startConnectorScore + graphMeters + endConnectorScore;
              if (score < bestLegScore) {
                bestLegScore = score;
                bestGraphMeters = graphMeters;
                bestPrev = tree.prev;
                bestLegPathPoints = null;
                bestStartCandidate = s;
                bestEndCandidate = e;
                bestStartNode = s.index;
                bestEndNode = e.index;
              }
            }

            // --- Direct-water shortcut (bridges disconnected components) ---
            // Do cheap distance/preference checks BEFORE the expensive
            // isSafeNodePair call to avoid O(n²) geometric overhead.
            final directWaterMeters = _haversineMeters(
              nodes[s.index],
              nodes[e.index],
            );
            if (!directWaterMeters.isFinite ||
                directWaterMeters <= 25.0 ||
                directWaterMeters > 16000.0) {
              continue;
            }
            // Check if direct water would even be worth it before paying
            // the expensive safety-check cost.
            final couldPreferDirectWater =
                !graphMeters.isFinite ||
                directWaterMeters + 40.0 < graphMeters * 0.88;
            if (!couldPreferDirectWater) continue;

            // Skip if we've exhausted the water-safety-check budget or
            // we're past 60% of the time budget with a valid route already.
            if (waterSafeChecksUsed >= maxWaterSafeChecks ||
                (bestPrev != null &&
                    legStopwatch.elapsedMilliseconds > legTimeBudgetMs * 0.6)) {
              continue;
            }
            waterSafeChecksUsed++;
            if (!isSafeNodePair(s.index, e.index)) {
              continue;
            }
            final score =
                startConnectorScore + directWaterMeters + endConnectorScore;
            if (score < bestLegScore) {
              bestLegScore = score;
              bestGraphMeters = directWaterMeters;
              bestPrev = null;
              bestLegPathPoints = <gmaps.LatLng>[
                nodes[s.index],
                nodes[e.index],
              ];
              bestStartCandidate = s;
              bestEndCandidate = e;
              bestStartNode = s.index;
              bestEndNode = e.index;
            }
          }
        }
      }

      considerCandidates(startCandidates, endCandidates);
      // Yield after initial candidate evaluation to keep the UI responsive.
      await Future<void>.delayed(Duration.zero);

      final directMeters = _haversineMeters(start, end);
      final shouldRetryWithExpandedCandidates =
          legStopwatch.elapsedMilliseconds < legTimeBudgetMs &&
          ((bestPrev == null && bestLegPathPoints == null) ||
              (directMeters > 1200.0 && bestLegScore > directMeters * 8.0));
      if (shouldRetryWithExpandedCandidates) {
        // Scale down candidate limits for large graphs to avoid O(n²) blowup.
        final largeGraph = nodes.length > 8000;
        final expandLimit = largeGraph ? 8 : 14;
        final augmentLimit = largeGraph ? 4 : 10;
        final augmentReach = largeGraph ? 8000.0 : 12000.0;

        final graphComponents = _graphComponents(adjacency);
        final expandedStartCandidates = _portageGraphCandidatesForAnchor(
          anchor: start,
          nodes: nodes,
          spatialIndex: spatialIndex,
          accessPoints: accessCoords,
          entry: entry,
          limit: expandLimit,
          radiiMeters: expandedPortageRadii,
          maxGlobalFallbackMeters: 22000,
          componentIds: graphComponents.componentIds,
          componentSizes: graphComponents.componentSizes,
          diversifyNearbyMeters: 3000.0,
        );
        final expandedStartWithSnaps = _mergePortageCandidateGroups([
          expandedStartCandidates,
          _snapPortageCandidatesToSegments(
            anchor: start,
            lines: networkLines,
            nodeIndexByKey: nodeIndexByKey,
            entry: entry,
            limit: expandLimit,
            maxAnchorMeters: 22000.0,
            maxLineDistanceMeters: 24000.0,
            maxAlongSegmentMeters: 30000.0,
            resolvedAnchor: startAnchor,
          ),
        ], softLimit: math.max(expandLimit + 6, 16));
        final expandedStartAugmented = _augmentPortageCandidatesViaOpenWater(
          anchor: start,
          resolvedAnchor: startAnchor,
          baseCandidates: expandedStartWithSnaps,
          nodes: nodes,
          spatialIndex: spatialIndex,
          entry: entry,
          maxExtraCandidates: augmentLimit,
          maxReachMeters: augmentReach,
          componentIds: graphComponents.componentIds,
          componentSizes: graphComponents.componentSizes,
        );
        final expandedEndCandidates = _portageGraphCandidatesForAnchor(
          anchor: end,
          nodes: nodes,
          spatialIndex: spatialIndex,
          accessPoints: accessCoords,
          entry: entry,
          limit: expandLimit,
          radiiMeters: expandedPortageRadii,
          maxGlobalFallbackMeters: 22000,
          componentIds: graphComponents.componentIds,
          componentSizes: graphComponents.componentSizes,
          diversifyNearbyMeters: 3000.0,
        );
        final expandedEndWithSnaps = _mergePortageCandidateGroups([
          expandedEndCandidates,
          _snapPortageCandidatesToSegments(
            anchor: end,
            lines: networkLines,
            nodeIndexByKey: nodeIndexByKey,
            entry: entry,
            limit: expandLimit,
            maxAnchorMeters: 22000.0,
            maxLineDistanceMeters: 24000.0,
            maxAlongSegmentMeters: 30000.0,
            resolvedAnchor: endAnchor,
          ),
        ], softLimit: math.max(expandLimit + 6, 16));
        final expandedEndAugmented = _augmentPortageCandidatesViaOpenWater(
          anchor: end,
          resolvedAnchor: endAnchor,
          baseCandidates: expandedEndWithSnaps,
          nodes: nodes,
          spatialIndex: spatialIndex,
          entry: entry,
          maxExtraCandidates: augmentLimit,
          maxReachMeters: augmentReach,
          componentIds: graphComponents.componentIds,
          componentSizes: graphComponents.componentSizes,
        );
        if (expandedStartAugmented.isNotEmpty &&
            expandedEndAugmented.isNotEmpty) {
          considerCandidates(expandedStartAugmented, expandedEndAugmented);
        }
      }

      if ((bestPrev == null && bestLegPathPoints == null) ||
          bestStartCandidate == null ||
          bestEndCandidate == null ||
          !bestGraphMeters.isFinite) {
        debugPrint(
          'portageRoute leg_unsolved leg=$leg ms=${legStopwatch.elapsedMilliseconds} '
          'startOptions=${startCandidates.length} endOptions=${endCandidates.length} '
          'expandedRetry=$shouldRetryWithExpandedCandidates directMeters=${directMeters.toStringAsFixed(0)}',
        );
        return await retryWithFocusLookup('leg_${leg}_unsolved');
      }
      final legStartCandidate = bestStartCandidate!;
      final legEndCandidate = bestEndCandidate!;
      final validStartConnector = _isValidPortageConnectorToGraphAnchor(
        anchor: start,
        graphAnchor: legStartCandidate.graphAnchor,
        entry: entry,
        allowAccessStraightToWater: legStartCandidate.usedAccess,
      );
      final validEndConnector = _isValidPortageConnectorToGraphAnchor(
        anchor: end,
        graphAnchor: legEndCandidate.graphAnchor,
        entry: entry,
        allowAccessStraightToWater: legEndCandidate.usedAccess,
      );
      if (!validStartConnector || !validEndConnector) {
        return await retryWithFocusLookup('leg_${leg}_invalid_connector');
      }
      final legPathPoints =
          bestLegPathPoints ??
          (() {
            final legPrev = bestPrev;
            if (legPrev == null) return const <gmaps.LatLng>[];
            final bestNodePath = _reconstructTrailNodePath(
              bestStartNode,
              bestEndNode,
              legPrev,
            );
            if (bestNodePath == null || bestNodePath.isEmpty) {
              return const <gmaps.LatLng>[];
            }
            return bestNodePath
                .map((nodeIndex) => nodes[nodeIndex])
                .toList(growable: false);
          })();
      if (legPathPoints.isEmpty) {
        return await retryWithFocusLookup('leg_${leg}_path_empty');
      }
      if (bestLegPathPoints != null) {
        debugPrint(
          'portageRoute leg_open_water_bridge leg=$leg '
          'startNode=$bestStartNode endNode=$bestEndNode '
          'meters=${bestGraphMeters.toStringAsFixed(0)}',
        );
      }
      legs.add(
        _PortageLegSolution(
          start: start,
          end: end,
          startOption: legStartCandidate,
          endOption: legEndCandidate,
          pathPoints: legPathPoints,
          graphMeters: bestGraphMeters,
        ),
      );
      // Yield between legs to keep the UI responsive.
      await Future<void>.delayed(Duration.zero);
    }
    if (legs.isEmpty) {
      return await retryWithFocusLookup('no_legs_solved');
    }

    bool isMeaningfullyDistinct(gmaps.LatLng a, gmaps.LatLng b) {
      return _haversineMeters(a, b) > 5.0;
    }

    var totalMeters = 0.0;
    for (final leg in legs) {
      appendDistinct(leg.start);
      if (isMeaningfullyDistinct(leg.start, leg.startOption.graphAnchor)) {
        appendDistinct(leg.startOption.graphAnchor);
      }
      for (final point in leg.pathPoints) {
        appendDistinct(point);
      }
      if (isMeaningfullyDistinct(leg.endOption.graphAnchor, leg.end)) {
        appendDistinct(leg.endOption.graphAnchor);
      }
      appendDistinct(leg.end);
      totalMeters += leg.startOption.totalConnectorMeters;
      totalMeters += leg.graphMeters;
      totalMeters += leg.endOption.totalConnectorMeters;
    }

    if (path.length < 2) {
      return await retryWithFocusLookup('path_lt_2');
    }
    var solvedPath = path;
    var solvedMeters = totalMeters;
    final offRamp =
        anchors.length == 2
            ? _trimPortagingPathToWaterOffRamp(
              path: path,
              destination: anchors.last,
              entry: entry,
            )
            : null;
    if (offRamp != null) {
      solvedPath = offRamp.path;
      solvedMeters = offRamp.distanceMeters;
    }

    final elapsedMs = DateTime.now().difference(routeStartedAt).inMilliseconds;
    debugPrint(
      'portageRoute solved legs=${anchors.length - 1} nodes=${nodes.length} access=${accessCoords.length} offRampApplied=${offRamp != null} ms=$elapsedMs',
    );
    final styledSegments = _buildPortagingStyledSegments(
      path: solvedPath,
      entry: entry,
      width: 6,
      zIndex: 28,
    );

    return _RouteComputation(
      path: solvedPath,
      distanceMeters: solvedMeters,
      durationSeconds: solvedMeters / 1.35,
      color: _standardRouteColor('portaging'),
      width: 6,
      zIndex: 28,
      styledSegments: styledSegments,
      instructions: <String>[
        'Portage-water network route (${(solvedMeters / 1000.0).toStringAsFixed(1)} km)',
      ],
    );
  }

  Future<_ModeOverlays> _buildPortagingOverlays(
    Map<int, List<gmaps.LatLng>> segGeometry, {
    gmaps.LatLng? focusPointOverride,
    double? focusPadDegreesOverride,
    bool preferFocusOnly = false,
  }) async {
    gmaps.LatLng? fallbackFocus;
    if (widget.points.isNotEmpty) {
      final lastRaw = widget.points.last;
      final focusLat = _latOf(lastRaw);
      final focusLon = _lonOf(lastRaw);
      fallbackFocus =
          focusLat.isFinite && focusLon.isFinite
              ? gmaps.LatLng(focusLat, focusLon)
              : null;
    }
    final focus = focusPointOverride ?? fallbackFocus;
    if (focus == null) return const _ModeOverlays();

    final fullRoutePath = _flattenRouteForMode(segGeometry, 'portaging');
    final routePath =
        fullRoutePath.isNotEmpty
            ? fullRoutePath
            : (preferFocusOnly && focusPointOverride != null
                ? <gmaps.LatLng>[focusPointOverride]
                : const <gmaps.LatLng>[]);
    final modeAnchors = _anchorPathForMode('portaging');
    final distancePath =
        routePath.isNotEmpty
            ? routePath
            : (modeAnchors.isNotEmpty ? modeAnchors : <gmaps.LatLng>[focus]);
    final routeMeters =
        distancePath.length >= 2 ? _polylineDistanceMeters(distancePath) : 0.0;
    final skipBroadOverlayQuery =
        !preferFocusOnly &&
        (widget.points.length >= 5 || routeMeters > 25000.0);
    final routeFetchAnchors =
        preferFocusOnly
            ? const <gmaps.LatLng>[]
            : modeAnchors.length >= 2
            ? modeAnchors
            : (routePath.length >= 2 ? routePath : const <gmaps.LatLng>[]);
    final routeCacheKey =
        routeFetchAnchors.length >= 2
            ? _portagingRouteCacheKey(routeFetchAnchors)
            : '';
    const routePadDegrees = 0.12;
    final focusPadDegrees = _quantizedOverlayPadDegrees(
      focusPadDegreesOverride ?? 0.18,
    );

    _PortagingOverlayCacheEntry? entry;
    var overlayGraphCacheKey =
        routeCacheKey.isNotEmpty
            ? routeCacheKey
            : _portagingFocusCacheKey(focus, padDegrees: focusPadDegrees);
    final shouldUseSegmentedFocusQuery =
        routePath.length >= 2 && (preferFocusOnly || skipBroadOverlayQuery);
    if (shouldUseSegmentedFocusQuery) {
      final segmentedPadDegrees = _quantizedOverlayPadDegrees(
        (focusPadDegrees * (preferFocusOnly ? 0.78 : 0.88))
            .clamp(0.08, 0.14)
            .toDouble(),
      );
      debugPrint(
        'portagingOverlays using_segmented_focus_query '
        'preferFocusOnly=$preferFocusOnly '
        'stops=${widget.points.length} '
        'route_km=${(routeMeters / 1000.0).toStringAsFixed(1)} '
        'pad=${segmentedPadDegrees.toStringAsFixed(2)}',
      );
      entry = await _loadSegmentedPortagingOverlayEntry(
        routePath: routePath,
        modeAnchors: modeAnchors,
        focusPoint: focus,
        padDegrees: segmentedPadDegrees,
        includeCampsites: true,
        maxFocusQueries: preferFocusOnly ? 4 : 5,
        logPrefix: 'portagingOverlays',
      );
      overlayGraphCacheKey =
          'segmented:${_pathSignature(_samplePath(distancePath, target: 6))}'
          ':pad=${segmentedPadDegrees.toStringAsFixed(2)}';
    } else if (routeCacheKey.isNotEmpty) {
      final routeCached = _portagingOverlayCache[routeCacheKey];
      debugPrint(
        'portagingOverpass cache_hit=${routeCached != null && _isFresh(routeCached.fetchedAt, _overlayCacheTtl)} key=$routeCacheKey',
      );
      entry = await _getPortagingOverlayEntry(
        cacheKey: routeCacheKey,
        anchors: routeFetchAnchors,
        padDegrees: routePadDegrees,
      );
    }
    if (entry == null) {
      final focusCacheKey = _portagingFocusCacheKey(
        focus,
        padDegrees: focusPadDegrees,
      );
      final focusCached = _portagingOverlayCache[focusCacheKey];
      debugPrint(
        'portagingOverpass focus_cache_hit=${focusCached != null && _isFresh(focusCached.fetchedAt, _overlayCacheTtl)} key=$focusCacheKey',
      );
      entry = await _getPortagingOverlayEntry(
        cacheKey: focusCacheKey,
        anchors: <gmaps.LatLng>[focus],
        focusPoint: focus,
        padDegrees: focusPadDegrees,
      );
      overlayGraphCacheKey = focusCacheKey;
    }
    if (entry == null) {
      final nearbyCached = _nearestCachedPortagingFocusEntry(
        focus,
        maxDegreesDelta: math.max(0.12, focusPadDegrees + 0.04),
      );
      if (nearbyCached != null) {
        entry = nearbyCached;
        overlayGraphCacheKey =
            'nearby_focus:${_roundToStep(focus.latitude, 0.02).toStringAsFixed(2)},'
            '${_roundToStep(focus.longitude, 0.02).toStringAsFixed(2)}';
        debugPrint(
          'portagingOverlays reused_nearby_focus_cache '
          'water=${nearbyCached.waterLines.length} '
          'portage=${nearbyCached.portageLines.length} '
          'campsites=${nearbyCached.campsites.length} '
          'access=${nearbyCached.accessPoints.length}',
        );
      }
    }
    if (entry != null && entry.campsites.isEmpty && routePath.isNotEmpty) {
      final focusCacheKey = _portagingFocusCacheKey(
        focus,
        padDegrees: focusPadDegrees,
      );
      final focusEntry = await _getPortagingOverlayEntry(
        cacheKey: focusCacheKey,
        anchors: <gmaps.LatLng>[focus],
        focusPoint: focus,
        padDegrees: focusPadDegrees,
      );
      if (focusEntry != null &&
          focusEntry.campsites.length > entry.campsites.length) {
        entry = focusEntry;
        overlayGraphCacheKey = focusCacheKey;
      }
    }
    if (entry == null) return const _ModeOverlays();
    _primePortagingRouteCaches(entry, preferFocusOnly: preferFocusOnly);

    // Debug visibility: render nearby raw water + portage network lines so we
    // can verify whether source geometry exists where routing fails.
    // Cap total overlay polylines to avoid crashing the browser with very
    // large Overpass responses (thousands of water features).
    const maxOverlayWaterPolylines = 400;
    const maxOverlayPortagePolylines = 60;
    final polylines = <gmaps.Polyline>{};
    final waterCandidates =
        <({int index, double dist, List<gmaps.LatLng> rendered})>[];
    for (var i = 0; i < entry.waterLines.length; i++) {
      final line = entry.waterLines[i];
      if (line.length < 2) continue;
      final nearRoute =
          routePath.isNotEmpty
              ? _distanceLineToPathMeters(line, routePath, maxSamples: 20)
              : _distanceMetersToPath(focus, line);
      if (routePath.isNotEmpty && nearRoute > 7000.0) continue;
      if (routePath.isEmpty && nearRoute > 35000.0) continue;
      final rendered = _downsampleLine(line, maxPoints: 280);
      if (rendered.length < 2) continue;
      waterCandidates.add((index: i, dist: nearRoute, rendered: rendered));
    }
    waterCandidates.sort((a, b) => a.dist.compareTo(b.dist));
    for (
      var j = 0;
      j < waterCandidates.length && j < maxOverlayWaterPolylines;
      j++
    ) {
      final c = waterCandidates[j];
      polylines.add(
        gmaps.Polyline(
          polylineId: gmaps.PolylineId(
            '${_instanceId}_portage_water_${c.index}',
          ),
          points: c.rendered,
          width: 3,
          color: const Color(0xFF1E88E5).withValues(alpha: 0.62),
          zIndex: 33,
        ),
      );
    }
    if (waterCandidates.length > maxOverlayWaterPolylines) {
      debugPrint(
        'portagingOverlays capped_water_polylines shown=$maxOverlayWaterPolylines total=${waterCandidates.length}',
      );
    }
    // Yield to prevent blocking the UI thread after heavy distance filtering.
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return const _ModeOverlays();
    final portageCandidates =
        <({int index, double dist, List<gmaps.LatLng> rendered})>[];
    for (var i = 0; i < entry.portageLines.length; i++) {
      final line = entry.portageLines[i];
      if (line.length < 2) continue;
      final nearRoute =
          routePath.isNotEmpty
              ? _distanceLineToPathMeters(line, routePath, maxSamples: 20)
              : _distanceMetersToPath(focus, line);
      if (routePath.isNotEmpty && nearRoute > 7000.0) continue;
      if (routePath.isEmpty && nearRoute > 35000.0) continue;
      final rendered = _downsampleLine(line, maxPoints: 320);
      if (rendered.length < 2) continue;
      portageCandidates.add((index: i, dist: nearRoute, rendered: rendered));
    }
    portageCandidates.sort((a, b) => a.dist.compareTo(b.dist));
    for (
      var j = 0;
      j < portageCandidates.length && j < maxOverlayPortagePolylines;
      j++
    ) {
      final c = portageCandidates[j];
      polylines.add(
        gmaps.Polyline(
          polylineId: gmaps.PolylineId(
            '${_instanceId}_portage_trail_${c.index}',
          ),
          points: c.rendered,
          width: 4,
          color: const Color(0xFF8D6E63).withValues(alpha: 0.92),
          zIndex: 35,
          patterns: <gmaps.PatternItem>[
            gmaps.PatternItem.dash(16),
            gmaps.PatternItem.gap(8),
          ],
        ),
      );
    }

    final nearbyWaterLinesForRanking = <List<gmaps.LatLng>>[
      for (
        var j = 0;
        j < waterCandidates.length &&
            j < math.min(maxOverlayWaterPolylines, 120);
        j++
      )
        entry.waterLines[waterCandidates[j].index],
    ];
    final nearbyPortageLinesForRanking = <List<gmaps.LatLng>>[
      for (
        var j = 0;
        j < portageCandidates.length &&
            j < math.min(maxOverlayPortagePolylines, 50);
        j++
      )
        entry.portageLines[portageCandidates[j].index],
    ];
    debugPrint(
      'portagingOverlays using_simple_ranking key=$overlayGraphCacheKey '
      'water=${nearbyWaterLinesForRanking.length} '
      'portage=${nearbyPortageLinesForRanking.length}',
    );

    double dpr = 1.0;
    try {
      dpr = View.of(context).devicePixelRatio;
    } catch (_) {
      dpr = 1.0;
    }
    gmaps.BitmapDescriptor campsiteIcon;
    try {
      campsiteIcon = await _markerIconCache.campsiteTriangle(dpr: dpr);
    } catch (_) {
      campsiteIcon = gmaps.BitmapDescriptor.defaultMarkerWithHue(
        gmaps.BitmapDescriptor.hueAzure,
      );
    }
    if (!mounted) return const _ModeOverlays();

    gmaps.BitmapDescriptor accessIcon;
    try {
      accessIcon = await _markerIconCache.portageAccessPin(dpr: dpr);
    } catch (_) {
      accessIcon = gmaps.BitmapDescriptor.defaultMarkerWithHue(
        gmaps.BitmapDescriptor.hueBlue,
      );
    }
    if (!mounted) return const _ModeOverlays();

    final campRows = entry.campsites
        .map((camp) {
          final point = gmaps.LatLng(
            (camp['lat'] as num).toDouble(),
            (camp['lon'] as num).toDouble(),
          );
          final distanceToKnownRoute = _distanceMetersToPath(
            point,
            distancePath,
          );
          final waterMeters = _nearestDistanceToLinesMeters(
            point,
            nearbyWaterLinesForRanking,
          );
          final portageMeters = _nearestDistanceToLinesMeters(
            point,
            nearbyPortageLinesForRanking,
          );
          final networkMeters = math.min(waterMeters, portageMeters);
          final effectiveMeters = math.min(networkMeters, distanceToKnownRoute);
          return <String, dynamic>{
            'camp': camp,
            'point': point,
            'networkMeters': networkMeters,
            'effectiveMeters': effectiveMeters,
            'distanceToKnownRoute': distanceToKnownRoute,
          };
        })
        .toList(growable: false);

    List<Map<String, dynamic>> selectCamps({
      required double maxEffectiveMeters,
      required double maxRouteMeters,
    }) {
      final selected = campRows
          .where((row) {
            final effective =
                (row['effectiveMeters'] as num?)?.toDouble() ?? double.infinity;
            final routeMeters =
                (row['distanceToKnownRoute'] as num?)?.toDouble() ??
                double.infinity;
            return effective <= maxEffectiveMeters &&
                routeMeters <= maxRouteMeters;
          })
          .toList(growable: false);
      selected.sort(
        (a, b) =>
            ((a['effectiveMeters'] as num?)?.toDouble() ?? double.infinity)
                .compareTo(
                  (b['effectiveMeters'] as num?)?.toDouble() ?? double.infinity,
                ),
      );
      return selected;
    }

    final hasRoutedPath = routePath.isNotEmpty;
    var sortedCamps = selectCamps(
      maxEffectiveMeters: hasRoutedPath ? 45000 : 70000,
      maxRouteMeters: hasRoutedPath ? 14000 : 38000,
    );
    if (sortedCamps.length < 12) {
      sortedCamps = selectCamps(
        maxEffectiveMeters: hasRoutedPath ? 60000 : 85000,
        maxRouteMeters: hasRoutedPath ? 24000 : 52000,
      );
    }
    if (sortedCamps.length < 8) {
      sortedCamps = selectCamps(
        maxEffectiveMeters: hasRoutedPath ? 75000 : 100000,
        maxRouteMeters: hasRoutedPath ? 36000 : 65000,
      );
    }
    if (sortedCamps.isEmpty && campRows.isNotEmpty) {
      final fallback = List<Map<String, dynamic>>.from(campRows);
      fallback.sort(
        (a, b) =>
            ((a['effectiveMeters'] as num?)?.toDouble() ?? double.infinity)
                .compareTo(
                  (b['effectiveMeters'] as num?)?.toDouble() ?? double.infinity,
                ),
      );
      sortedCamps = fallback;
    }

    final campMarkers = <gmaps.Marker>{};
    for (var i = 0; i < sortedCamps.length; i++) {
      if (campMarkers.length >= 120) break;
      final row = sortedCamps[i];
      final effectiveMeters =
          (row['effectiveMeters'] as num?)?.toDouble() ?? double.infinity;
      if (campMarkers.length >= 60 && effectiveMeters > 28000) continue;
      final camp = (row['camp'] as Map).cast<String, dynamic>();
      final point = row['point'] as gmaps.LatLng;
      final km = effectiveMeters / 1000.0;
      campMarkers.add(
        gmaps.Marker(
          markerId: gmaps.MarkerId('${_instanceId}_p_camp_$i'),
          position: point,
          icon: campsiteIcon,
          anchor: const Offset(0.5, 0.8),
          infoWindow: gmaps.InfoWindow(
            title: (camp['name'] ?? 'Campsite').toString(),
            snippet: '${km.toStringAsFixed(1)} km from route',
          ),
          onTap: () {
            _suppressMapTapUntilMs =
                DateTime.now().millisecondsSinceEpoch + 900;
            unawaited(_focusPoint(point));
            widget.onHikingCampsiteTap?.call(<String, dynamic>{
              ...camp,
              'name': (camp['name'] ?? 'Campsite').toString(),
              'lat': point.latitude,
              'lon': point.longitude,
              'distanceKmFromRoute': km,
              'mode': 'portaging',
            });
          },
        ),
      );
    }

    final sortedAccess = entry.accessPoints
      .map((head) {
        final point = gmaps.LatLng(
          (head['lat'] as num).toDouble(),
          (head['lon'] as num).toDouble(),
        );
        final km = _distanceMetersToPath(point, distancePath) / 1000.0;
        return <String, dynamic>{
          'head': head,
          'point': point,
          'distanceKm': km,
        };
      })
      .toList(growable: false)..sort(
      (a, b) => ((a['distanceKm'] as num?)?.toDouble() ?? double.infinity)
          .compareTo((b['distanceKm'] as num?)?.toDouble() ?? double.infinity),
    );

    final accessMarkers = <gmaps.Marker>{};
    final accessMarkerCap = hasRoutedPath ? 40 : 80;
    final accessDistanceCutoffKm = hasRoutedPath ? 25.0 : 80.0;
    final accessSoftCap = hasRoutedPath ? 20 : 40;
    for (var i = 0; i < sortedAccess.length; i++) {
      if (accessMarkers.length >= accessMarkerCap) break;
      final row = sortedAccess[i];
      final km = (row['distanceKm'] as num?)?.toDouble() ?? double.infinity;
      if (accessMarkers.length >= accessSoftCap &&
          km > accessDistanceCutoffKm) {
        continue;
      }
      final head = (row['head'] as Map).cast<String, dynamic>();
      final point = row['point'] as gmaps.LatLng;
      final title = (head['name'] ?? 'Portage access').toString();
      accessMarkers.add(
        gmaps.Marker(
          markerId: gmaps.MarkerId('${_instanceId}_p_access_$i'),
          position: point,
          icon: accessIcon,
          anchor: const Offset(0.5, 0.5),
          infoWindow: gmaps.InfoWindow(
            title: title,
            snippet:
                'Put-in / take-out candidate · ${km.toStringAsFixed(1)} km',
          ),
          onTap: () {
            _suppressMapTapUntilMs =
                DateTime.now().millisecondsSinceEpoch + 900;
            unawaited(_focusPoint(point));
            widget.onPortageAccessTap?.call(<String, dynamic>{
              ...head,
              'name': title,
              'lat': point.latitude,
              'lon': point.longitude,
              'distanceKmFromRoute': km,
              'mode': 'portaging',
            });
          },
        ),
      );
    }

    return _ModeOverlays(
      polylines: polylines,
      markers: <gmaps.Marker>{...campMarkers, ...accessMarkers},
      trailSegments: polylines.length,
      campsiteMarkers: campMarkers.length,
      trailheadMarkers: accessMarkers.length,
    );
  }

  Map<String, dynamic> _toGeoJson(
    List<List<gmaps.LatLng>> trails,
    List<Map<String, dynamic>> campsites,
    List<Map<String, dynamic>> trailheads,
  ) {
    final features = <Map<String, dynamic>>[];
    for (final line in trails) {
      if (line.length < 2) continue;
      features.add(<String, dynamic>{
        'type': 'Feature',
        'properties': <String, dynamic>{
          'layer': 'hiking_trail',
          'source': 'overpass',
        },
        'geometry': <String, dynamic>{
          'type': 'LineString',
          'coordinates':
              line.map((p) => <double>[p.longitude, p.latitude]).toList(),
        },
      });
    }
    for (final camp in campsites) {
      features.add(<String, dynamic>{
        'type': 'Feature',
        'properties': <String, dynamic>{
          'layer': 'camp_site',
          'name': camp['name'],
        },
        'geometry': <String, dynamic>{
          'type': 'Point',
          'coordinates': <double>[
            (camp['lon'] as num).toDouble(),
            (camp['lat'] as num).toDouble(),
          ],
        },
      });
    }
    for (final head in trailheads) {
      features.add(<String, dynamic>{
        'type': 'Feature',
        'properties': <String, dynamic>{
          'layer': 'trailhead',
          'name': head['name'],
        },
        'geometry': <String, dynamic>{
          'type': 'Point',
          'coordinates': <double>[
            (head['lon'] as num).toDouble(),
            (head['lat'] as num).toDouble(),
          ],
        },
      });
    }
    return <String, dynamic>{'type': 'FeatureCollection', 'features': features};
  }

  Future<_HikingOverlayCacheEntry?> _fetchHikingOverlayData(
    List<gmaps.LatLng> routePath, {
    double padDegrees = 0.08,
  }) async {
    if (routePath.isEmpty) return null;

    var minLat = double.infinity;
    var maxLat = -double.infinity;
    var minLon = double.infinity;
    var maxLon = -double.infinity;
    for (final p in routePath) {
      minLat = math.min(minLat, p.latitude);
      maxLat = math.max(maxLat, p.latitude);
      minLon = math.min(minLon, p.longitude);
      maxLon = math.max(maxLon, p.longitude);
    }
    final south = minLat - padDegrees;
    final west = minLon - padDegrees;
    final north = maxLat + padDegrees;
    final east = maxLon + padDegrees;

    final query = '''
[out:json][timeout:25];
(
  way["highway"="path"]($south,$west,$north,$east);
  way["highway"="footway"]($south,$west,$north,$east);
  way["route"="hiking"]($south,$west,$north,$east);
  relation["route"="hiking"]($south,$west,$north,$east);
  node["tourism"~"camp_site|camp_pitch"]($south,$west,$north,$east);
  way["tourism"~"camp_site|camp_pitch"]($south,$west,$north,$east);
  relation["tourism"~"camp_site|camp_pitch"]($south,$west,$north,$east);
  node["tourism"="information"]["information"~"trailhead|guidepost"]($south,$west,$north,$east);
  way["tourism"="information"]["information"~"trailhead|guidepost"]($south,$west,$north,$east);
  relation["tourism"="information"]["information"~"trailhead|guidepost"]($south,$west,$north,$east);
  node["trailhead"="yes"]($south,$west,$north,$east);
  way["trailhead"="yes"]($south,$west,$north,$east);
  relation["trailhead"="yes"]($south,$west,$north,$east);
);
out body geom;
''';

    final data = await _fetchOverpassData(
      query: query,
      logPrefix: 'hikingOverpass',
      requestTimeout: const Duration(seconds: 11),
    );
    if (data == null) return null;
    final elements = (data['elements'] as List<dynamic>?) ?? const [];
    final trails = <List<gmaps.LatLng>>[];
    final campsites = <Map<String, dynamic>>[];
    final trailheads = <Map<String, dynamic>>[];
    final seenCampKeys = <String>{};
    final seenTrailheadKeys = <String>{};

    bool isCampTags(Map<String, dynamic> tags) {
      final tourism = (tags['tourism'] ?? '').toString().toLowerCase();
      return tourism == 'camp_site' || tourism == 'camp_pitch';
    }

    bool isTrailheadTags(Map<String, dynamic> tags) {
      final tourism = (tags['tourism'] ?? '').toString().toLowerCase();
      final information = (tags['information'] ?? '').toString().toLowerCase();
      final trailhead = (tags['trailhead'] ?? '').toString().toLowerCase();
      return trailhead == 'yes' ||
          (tourism == 'information' &&
              (information == 'trailhead' || information == 'guidepost'));
    }

    bool isTrailTags(Map<String, dynamic> tags) {
      final highway = (tags['highway'] ?? '').toString().toLowerCase();
      final route = (tags['route'] ?? '').toString().toLowerCase();
      return highway == 'path' || highway == 'footway' || route == 'hiking';
    }

    List<gmaps.LatLng> geometryToLine(List<dynamic> geom) {
      final line = <gmaps.LatLng>[];
      for (final g in geom) {
        final gm = (g as Map).cast<String, dynamic>();
        final lat = (gm['lat'] as num?)?.toDouble();
        final lon = (gm['lon'] as num?)?.toDouble();
        if (lat == null || lon == null) continue;
        line.add(gmaps.LatLng(lat, lon));
      }
      return line;
    }

    gmaps.LatLng? centroidFromLine(List<gmaps.LatLng> line) {
      if (line.isEmpty) return null;
      var latSum = 0.0;
      var lonSum = 0.0;
      for (final point in line) {
        latSum += point.latitude;
        lonSum += point.longitude;
      }
      return gmaps.LatLng(latSum / line.length, lonSum / line.length);
    }

    gmaps.LatLng? centroidFromMembers(List<dynamic> members) {
      var latSum = 0.0;
      var lonSum = 0.0;
      var count = 0;
      for (final member in members) {
        final mm = (member as Map).cast<String, dynamic>();
        final geom = (mm['geometry'] as List<dynamic>?) ?? const [];
        for (final g in geom) {
          final gm = (g as Map).cast<String, dynamic>();
          final lat = (gm['lat'] as num?)?.toDouble();
          final lon = (gm['lon'] as num?)?.toDouble();
          if (lat == null || lon == null) continue;
          latSum += lat;
          lonSum += lon;
          count++;
        }
      }
      if (count == 0) return null;
      return gmaps.LatLng(latSum / count, lonSum / count);
    }

    void addCamp({
      required String name,
      required double lat,
      required double lon,
      Map<String, dynamic> tags = const <String, dynamic>{},
      String sourceType = 'campsite',
    }) {
      final key = '${lat.toStringAsFixed(5)},${lon.toStringAsFixed(5)}';
      if (!seenCampKeys.add(key)) return;
      final camp = <String, dynamic>{
        'name': name,
        'lat': lat,
        'lon': lon,
        'sourceType': sourceType,
      };
      void copyTag(String sourceKey, String targetKey) {
        final value = (tags[sourceKey] ?? '').toString().trim();
        if (value.isNotEmpty) camp[targetKey] = value;
      }

      copyTag('operator', 'operator');
      copyTag('access', 'access');
      copyTag('capacity', 'capacity');
      copyTag('description', 'description');
      copyTag('website', 'website');
      copyTag('url', 'website');
      copyTag('park', 'park');
      copyTag('park:name', 'park');
      copyTag('addr:place', 'lakeName');
      copyTag('loc_name', 'lakeName');
      campsites.add(camp);
    }

    void addTrailhead({
      required String name,
      required double lat,
      required double lon,
    }) {
      final key = '${lat.toStringAsFixed(5)},${lon.toStringAsFixed(5)}';
      if (!seenTrailheadKeys.add(key)) return;
      trailheads.add(<String, dynamic>{'name': name, 'lat': lat, 'lon': lon});
    }

    for (final e in elements) {
      final m = (e as Map).cast<String, dynamic>();
      final type = (m['type'] ?? '').toString();
      final tags = (m['tags'] as Map?)?.cast<String, dynamic>() ?? const {};

      if (type == 'way') {
        final geom = (m['geometry'] as List<dynamic>?) ?? const [];
        final line = geometryToLine(geom);
        if (line.length >= 2 && isTrailTags(tags)) {
          trails.add(line);
        }
        final center = centroidFromLine(line);
        if (center != null && isCampTags(tags)) {
          addCamp(
            name: (tags['name'] ?? 'Campsite').toString(),
            lat: center.latitude,
            lon: center.longitude,
            tags: tags,
            sourceType: type,
          );
        }
        if (center != null && isTrailheadTags(tags)) {
          addTrailhead(
            name: (tags['name'] ?? 'Trailhead').toString(),
            lat: center.latitude,
            lon: center.longitude,
          );
        }
      } else if (type == 'relation') {
        final members = (m['members'] as List<dynamic>?) ?? const [];
        if (isTrailTags(tags)) {
          for (final member in members) {
            final mm = (member as Map).cast<String, dynamic>();
            final geom = (mm['geometry'] as List<dynamic>?) ?? const [];
            final line = geometryToLine(geom);
            if (line.length >= 2) trails.add(line);
          }
        }
        final center = centroidFromMembers(members);
        if (center != null && isCampTags(tags)) {
          addCamp(
            name: (tags['name'] ?? 'Campsite').toString(),
            lat: center.latitude,
            lon: center.longitude,
            tags: tags,
            sourceType: type,
          );
        }
        if (center != null && isTrailheadTags(tags)) {
          addTrailhead(
            name: (tags['name'] ?? 'Trailhead').toString(),
            lat: center.latitude,
            lon: center.longitude,
          );
        }
      } else if (type == 'node') {
        final lat = (m['lat'] as num?)?.toDouble();
        final lon = (m['lon'] as num?)?.toDouble();
        if (lat == null || lon == null) continue;
        if (isCampTags(tags)) {
          addCamp(
            name: (tags['name'] ?? 'Campsite').toString(),
            lat: lat,
            lon: lon,
            tags: tags,
            sourceType: type,
          );
        } else if (isTrailheadTags(tags)) {
          addTrailhead(
            name: (tags['name'] ?? 'Trailhead').toString(),
            lat: lat,
            lon: lon,
          );
        }
      }
    }

    final geoJson = _toGeoJson(trails, campsites, trailheads);
    final featureCount =
        (geoJson['features'] as List<dynamic>? ?? const []).length;
    debugPrint(
      'hikingOverpass converted trails=${trails.length} campsites=${campsites.length} trailheads=${trailheads.length} geojson_features=$featureCount',
    );
    return _HikingOverlayCacheEntry(
      fetchedAt: DateTime.now(),
      trailLines: trails,
      campsites: campsites,
      trailheads: trailheads,
      geoJson: geoJson,
    );
  }

  Future<_ModeOverlays> _buildHikingOverlays(
    Map<int, List<gmaps.LatLng>> segGeometry, {
    List<gmaps.LatLng>? overlayAnchors,
  }) async {
    final routePath =
        overlayAnchors != null && overlayAnchors.isNotEmpty
            ? overlayAnchors
            : _hikingAnchorPath(segGeometry);
    if (routePath.isEmpty) return const _ModeOverlays();
    final cacheKey = _hikingCacheKey(routePath);

    final cached = _hikingOverlayCache[cacheKey];
    debugPrint(
      'hikingOverpass cache_hit=${cached != null && _isFresh(cached.fetchedAt, _overlayCacheTtl)} key=$cacheKey',
    );
    final entry = await _getHikingOverlayEntry(
      cacheKey: cacheKey,
      routePath: routePath,
    );
    if (entry == null) return const _ModeOverlays();

    final polylines = <gmaps.Polyline>{};
    for (var i = 0; i < entry.trailLines.length; i++) {
      final line = entry.trailLines[i];
      if (line.length < 2) continue;
      final rendered = _downsampleLine(line, maxPoints: 280);
      if (rendered.length < 2) continue;
      polylines.add(
        gmaps.Polyline(
          polylineId: gmaps.PolylineId('${_instanceId}_trail_$i'),
          points: rendered,
          width: 4,
          color: const Color(0xFF2E7D32),
          zIndex: 40,
        ),
      );
    }

    double dpr = 1.0;
    try {
      dpr = View.of(context).devicePixelRatio;
    } catch (_) {
      dpr = 1.0;
    }
    gmaps.BitmapDescriptor campsiteIcon;
    try {
      campsiteIcon = await _markerIconCache.campsiteTriangle(dpr: dpr);
    } catch (e) {
      debugPrint('campsiteIcon build_failed err=$e');
      campsiteIcon = gmaps.BitmapDescriptor.defaultMarkerWithHue(
        gmaps.BitmapDescriptor.hueOrange,
      );
    }
    if (!mounted) return const _ModeOverlays();

    gmaps.BitmapDescriptor trailheadIcon;
    try {
      trailheadIcon = await _markerIconCache.trailheadHikePin(dpr: dpr);
    } catch (e) {
      debugPrint('trailheadIcon build_failed err=$e');
      trailheadIcon = gmaps.BitmapDescriptor.defaultMarkerWithHue(
        gmaps.BitmapDescriptor.hueGreen,
      );
    }
    if (!mounted) return const _ModeOverlays();

    final sortedCamps = entry.campsites
      .map((camp) {
        final lat = (camp['lat'] as num).toDouble();
        final lon = (camp['lon'] as num).toDouble();
        final point = gmaps.LatLng(lat, lon);
        final km = _distanceMetersToPath(point, routePath) / 1000.0;
        return <String, dynamic>{
          'camp': camp,
          'point': point,
          'distanceKm': km,
        };
      })
      .toList(growable: false)..sort(
      (a, b) => ((a['distanceKm'] as num?)?.toDouble() ?? double.infinity)
          .compareTo((b['distanceKm'] as num?)?.toDouble() ?? double.infinity),
    );

    final campMarkers = <gmaps.Marker>{};
    for (var i = 0; i < sortedCamps.length; i++) {
      final row = sortedCamps[i];
      final camp = (row['camp'] as Map).cast<String, dynamic>();
      final point = row['point'] as gmaps.LatLng;
      final km = (row['distanceKm'] as num?)?.toDouble() ?? 0.0;
      campMarkers.add(
        gmaps.Marker(
          markerId: gmaps.MarkerId('${_instanceId}_camp_$i'),
          position: point,
          icon: campsiteIcon,
          anchor: const Offset(0.5, 0.8),
          infoWindow: gmaps.InfoWindow(
            title: (camp['name'] ?? 'Campsite').toString(),
            snippet: '${km.toStringAsFixed(1)} km from route',
          ),
          onTap: () {
            _suppressMapTapUntilMs =
                DateTime.now().millisecondsSinceEpoch + 900;
            unawaited(_focusPoint(point));
            widget.onHikingCampsiteTap?.call(<String, dynamic>{
              ...camp,
              'name': (camp['name'] ?? 'Campsite').toString(),
              'lat': point.latitude,
              'lon': point.longitude,
              'distanceKmFromRoute': km,
              'mode': 'hiking',
            });
          },
        ),
      );
    }

    final sortedTrailheads = entry.trailheads
      .map((head) {
        final lat = (head['lat'] as num).toDouble();
        final lon = (head['lon'] as num).toDouble();
        final point = gmaps.LatLng(lat, lon);
        final km = _distanceMetersToPath(point, routePath) / 1000.0;
        return <String, dynamic>{
          'head': head,
          'point': point,
          'distanceKm': km,
        };
      })
      .toList(growable: false)..sort(
      (a, b) => ((a['distanceKm'] as num?)?.toDouble() ?? double.infinity)
          .compareTo((b['distanceKm'] as num?)?.toDouble() ?? double.infinity),
    );

    final trailheadMarkers = <gmaps.Marker>{};
    for (var i = 0; i < sortedTrailheads.length; i++) {
      if (trailheadMarkers.length >= 40) break;
      final row = sortedTrailheads[i];
      final km = (row['distanceKm'] as num?)?.toDouble() ?? double.infinity;
      if (trailheadMarkers.length >= 16 && km > 2.5) continue;

      final head = (row['head'] as Map).cast<String, dynamic>();
      final point = row['point'] as gmaps.LatLng;
      trailheadMarkers.add(
        gmaps.Marker(
          markerId: gmaps.MarkerId('${_instanceId}_trailhead_$i'),
          position: point,
          icon: trailheadIcon,
          anchor: const Offset(0.5, 0.5),
          infoWindow: gmaps.InfoWindow(
            title: (head['name'] ?? 'Trailhead').toString(),
            snippet: '${km.toStringAsFixed(1)} km from route',
          ),
        ),
      );
    }

    final allMarkers = <gmaps.Marker>{...campMarkers, ...trailheadMarkers};

    return _ModeOverlays(
      polylines: polylines,
      markers: allMarkers,
      trailSegments: polylines.length,
      campsiteMarkers: campMarkers.length,
      trailheadMarkers: trailheadMarkers.length,
    );
  }

  Object? _mapsObject() {
    try {
      final google = js_util.getProperty(html.window, 'google');
      if (google == null) return null;
      return js_util.getProperty(google, 'maps');
    } catch (_) {
      return null;
    }
  }

  Future<Object?> _ensurePlacesService() async {
    if (_placesService != null) return _placesService;
    await maps_loader.ensureGoogleMapsLoaded();
    final maps = _mapsObject();
    if (maps == null) return null;
    try {
      final importLib = js_util.getProperty(maps, 'importLibrary');
      if (importLib != null) {
        final p = js_util.callMethod<Object?>(maps, 'importLibrary', const [
          'places',
        ]);
        if (p != null) {
          await js_util.promiseToFuture<Object?>(p as Object);
        }
      }
    } catch (_) {}

    _placesHost ??=
        html.DivElement()
          ..id = 'trypr-map-places-host'
          ..style.display = 'none';
    if (_placesHost!.parent == null) {
      html.document.body?.append(_placesHost!);
    }

    try {
      final places = js_util.getProperty(maps, 'places');
      final ctor = js_util.getProperty(places, 'PlacesService');
      _placesService = js_util.callConstructor(ctor, [_placesHost!]);
      return _placesService;
    } catch (_) {
      _placesService = null;
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> _nearbyGasStations(
    Object placesService,
    gmaps.LatLng center,
  ) async {
    final c = Completer<List<Map<String, dynamic>>>();
    final request = js_util.jsify(<String, dynamic>{
      'location': js_util.jsify(<String, dynamic>{
        'lat': center.latitude,
        'lng': center.longitude,
      }),
      'radius': 3200,
      'type': 'gas_station',
    });

    final callback = js_util.allowInterop((results, status, _) {
      final statusStr = (status ?? '').toString();
      if (statusStr != 'OK' || results is! List) {
        if (!c.isCompleted) c.complete(const []);
        return;
      }

      final out = <Map<String, dynamic>>[];
      for (final r in results) {
        try {
          final name = (js_util.getProperty(r, 'name') ?? '').toString().trim();
          final placeId =
              (js_util.getProperty(r, 'place_id') ?? '').toString().trim();
          final vicinity =
              (js_util.getProperty(r, 'vicinity') ?? '').toString().trim();
          final geometry = js_util.getProperty(r, 'geometry');
          final location = js_util.getProperty(geometry, 'location');
          final lat =
              (js_util.callMethod(location, 'lat', const []) as num?)
                  ?.toDouble();
          final lng =
              (js_util.callMethod(location, 'lng', const []) as num?)
                  ?.toDouble();
          if (lat == null || lng == null) continue;
          out.add(<String, dynamic>{
            'name': name.isNotEmpty ? name : 'Gas Station',
            'place_id': placeId,
            'vicinity': vicinity,
            'lat': lat,
            'lon': lng,
          });
        } catch (_) {
          continue;
        }
      }
      if (!c.isCompleted) c.complete(out);
    });

    try {
      js_util.callMethod(placesService, 'nearbySearch', [request, callback]);
      return await c.future.timeout(
        const Duration(seconds: 6),
        onTimeout: () {
          return const [];
        },
      );
    } catch (_) {
      return const [];
    }
  }

  List<gmaps.LatLng> _samplePath(List<gmaps.LatLng> path, {int target = 8}) {
    if (path.length <= target) return List<gmaps.LatLng>.from(path);
    final out = <gmaps.LatLng>[];
    final step = math.max(1, path.length ~/ target);
    for (var i = 0; i < path.length; i += step) {
      out.add(path[i]);
    }
    if (out.isEmpty ||
        (out.last.latitude - path.last.latitude).abs() > 1e-8 ||
        (out.last.longitude - path.last.longitude).abs() > 1e-8) {
      out.add(path.last);
    }
    return out;
  }

  Future<_ModeOverlays> _buildGasStopOverlays(
    Map<int, List<gmaps.LatLng>> segGeometry,
  ) async {
    final routePath = _flattenRouteForMode(segGeometry, 'gas_stops');
    if (routePath.length < 2) return const _ModeOverlays();
    final cacheKey = _pathSignature(routePath);

    var gas = _gasOverlayCache[cacheKey];
    if (gas == null) {
      final placesService = await _ensurePlacesService();
      if (placesService == null) return const _ModeOverlays();
      final samples = _samplePath(routePath, target: 8);
      final byPlace = <String, Map<String, dynamic>>{};
      for (final s in samples) {
        final nearby = await _nearbyGasStations(placesService, s);
        for (final item in nearby) {
          final placeId = (item['place_id'] ?? '').toString();
          final key =
              placeId.isEmpty
                  ? '${item['lat']},${item['lon']}'
                  : 'place:$placeId';
          byPlace[key] = item;
        }
      }
      gas = byPlace.values.toList(growable: false);
      for (final item in gas) {
        final p = gmaps.LatLng(
          (item['lat'] as num).toDouble(),
          (item['lon'] as num).toDouble(),
        );
        item['distanceMeters'] = _distanceMetersToPath(p, routePath);
      }
      gas.sort(
        (a, b) => ((a['distanceMeters'] as num?)?.toDouble() ?? double.infinity)
            .compareTo(
              (b['distanceMeters'] as num?)?.toDouble() ?? double.infinity,
            ),
      );
      if (gas.length > 20) {
        gas = gas.take(20).toList(growable: false);
      }
      _gasOverlayCache[cacheKey] = gas;
    }

    final markers = <gmaps.Marker>{};
    for (var i = 0; i < gas.length; i++) {
      final station = gas[i];
      final lat = (station['lat'] as num).toDouble();
      final lon = (station['lon'] as num).toDouble();
      final distKm =
          ((station['distanceMeters'] as num?)?.toDouble() ?? 0.0) / 1000.0;
      final vicinity = (station['vicinity'] ?? '').toString().trim();
      markers.add(
        gmaps.Marker(
          markerId: gmaps.MarkerId('${_instanceId}_gas_$i'),
          position: gmaps.LatLng(lat, lon),
          icon: gmaps.BitmapDescriptor.defaultMarkerWithHue(
            gmaps.BitmapDescriptor.hueOrange,
          ),
          infoWindow: gmaps.InfoWindow(
            title: (station['name'] ?? 'Gas Station').toString(),
            snippet:
                vicinity.isEmpty
                    ? '${distKm.toStringAsFixed(1)} km from route'
                    : '$vicinity · ${distKm.toStringAsFixed(1)} km from route',
          ),
        ),
      );
    }

    return _ModeOverlays(markers: markers, gasMarkers: markers.length);
  }

  gmaps.Marker? _findCampsiteMarkerById(
    Set<gmaps.Marker> markers,
    String markerId,
  ) {
    final wanted = markerId.trim();
    if (wanted.isEmpty) return null;
    for (final m in markers) {
      final id = m.markerId.value;
      if (id == wanted || id.endsWith(wanted) || id.endsWith('_$wanted')) {
        return m;
      }
    }
    return null;
  }

  void _maybeOpenCampsiteInfoWindow(Set<gmaps.Marker> markers) {
    final wanted = _campsiteInfoMarkerIdDefine.trim();
    if (wanted.isEmpty || _didAttemptCampsiteInfoOpen) return;
    _didAttemptCampsiteInfoOpen = true;

    final target = _findCampsiteMarkerById(markers, wanted);
    if (target == null) {
      debugPrint(
        'campsiteInfoWindow marker_not_found requested=$wanted available_count=${markers.length}',
      );
      return;
    }

    Future<void>.delayed(const Duration(milliseconds: 200), () async {
      if (!mounted || _controller == null) return;
      try {
        await _controller!.showMarkerInfoWindow(target.markerId);
        debugPrint(
          'campsiteInfoWindow opened requested=$wanted markerId=${target.markerId.value}',
        );
      } catch (e) {
        debugPrint(
          'campsiteInfoWindow open_failed requested=$wanted markerId=${target.markerId.value} err=$e',
        );
      }
    });
  }

  Future<_RouteComputation?> _retryAdventureRouteAfterCacheWarm({
    required List<Map<String, dynamic>> segPoints,
    required String mode,
    required String segType,
  }) async {
    if (segType == 'direct') return null;
    final normalizedMode = _normalizeTransportMode(mode);
    switch (normalizedMode) {
      case 'hiking':
        return _routeViaTrailGraph(segPoints, modeContext: normalizedMode);
      case 'portaging':
        return _routeViaPortageGraph(segPoints);
      default:
        return null;
    }
  }

  Future<void> _updateRoutePolyline({required int seq}) async {
    final calculationSig = _routeCalculationSignature();
    final basePts = widget.points;
    final expectedRoutePolylineCount =
        basePts.length > 1 ? basePts.length - 1 : 0;
    if (_lastRouteCalcSig == calculationSig &&
        (expectedRoutePolylineCount == 0 ||
            _polylines.length >= expectedRoutePolylineCount ||
            _lastRouteHadBlockingGaps)) {
      return;
    }
    if (_lastRouteCalcSig == calculationSig &&
        expectedRoutePolylineCount > 0 &&
        _polylines.length < expectedRoutePolylineCount) {
      debugPrint(
        'routeCalc signature matched but committed polylines='
        '${_polylines.length}/$expectedRoutePolylineCount; recomputing',
      );
    }
    if (_applyInitialRouteDataIfAvailable(seq: seq)) {
      return;
    }
    _setRouteComputing(true, seq: seq);
    try {
      final showNearbyContextOverlays = widget.showNearbyContextOverlays;
      if (basePts.length < 2) {
        _segmentGeometry = {};
        _emitRouteGeometry(<int, List<gmaps.LatLng>>{});
        final preservedAdventureMarkers = _existingAdventureMarkers();
        final preservedAdventurePolylines = _existingAdventurePolylines();

        if (!showNearbyContextOverlays ||
            (!_modeMatchesAnySegment('hiking') &&
                !_modeMatchesAnySegment('portaging'))) {
          _didAttemptCampsiteInfoOpen = false;
        }

        if (!mounted || seq != _rebuildSeq) return;
        setState(() {
          _polylines = const {};
          _modeSpecificMarkers = preservedAdventureMarkers;
          _modeSpecificPolylines = preservedAdventurePolylines;
        });
        _logLayerCounts(
          mode: _normalizeTransportMode(widget.transportMode),
          routePolylines: 0,
          trailSegments: 0,
          campsiteMarkers: 0,
          trailheadMarkers: 0,
          gasMarkers: 0,
        );
        widget.onRouteInstructions?.call(const []);
        widget.onRouteSegmentDetails?.call(const []);
        widget.onRouteSummary?.call(0, 0);
        _lastRouteCalcSig = calculationSig;
        _lastRouteHadBlockingGaps = false;
        _lastRouteErrorSig = '';
        return;
      }

      final outPolylines = <gmaps.Polyline>{};
      final segGeometry = <int, List<gmaps.LatLng>>{};
      final segmentDistanceMeters = <int, double>{};
      final segmentDurationSeconds = <int, double>{};
      final instructions = <String>[];
      final segmentDetails = <Map<String, dynamic>>[];
      var distSum = 0.0;
      var durSum = 0.0;
      Map<String, dynamic>? lastArrivalStop;
      // Track adventure segments that fell back to straight lines so we can
      // retry them after warming the relevant trail/water overlays.
      final straightLineFallbackSegs =
          <
            int,
            ({
              List<Map<String, dynamic>> segPoints,
              String mode,
              String segType,
            })
          >{};
      final unresolvedPortageSegs = <int, List<Map<String, dynamic>>>{};

      for (var seg = 0; seg < basePts.length - 1; seg++) {
        if (!mounted || seq != _rebuildSeq) return;
        final segPoints = _segmentPoints(afterIndex: seg);
        if (segPoints.length < 2) continue;
        final mode = _segmentTransportModeFor(seg);
        final normalizedMode = _normalizeTransportMode(mode);
        final segType = _segmentRoutingTypeFor(seg);
        final fallbackPath = _segmentLatLngs(segPoints);
        debugPrint(
          'segmentRoute computing segment=$seg mode=$mode segType=$segType points=${segPoints.length}',
        );

        _RouteComputation? route;
        try {
          route = await _calculateRouteForSegment(
            segmentIndex: seg,
            segPoints: segPoints,
            mode: mode,
            segType: segType,
          ).timeout(
            _segmentRouteTimeoutForMode(mode),
            onTimeout: () {
              debugPrint(
                'segmentRoute timeout segment=$seg mode=$mode segType=$segType',
              );
              return null;
            },
          );
        } catch (e) {
          debugPrint(
            'segmentRoute failed segment=$seg mode=$mode segType=$segType err=$e',
          );
          route = null;
        }
        if (!mounted || seq != _rebuildSeq) return;

        if (route == null) {
          debugPrint(
            'segmentRoute FALLBACK_TO_STRAIGHT_LINE segment=$seg mode=$mode segType=$segType',
          );
        } else {
          debugPrint(
            'segmentRoute SUCCESS segment=$seg mode=$mode pathLen=${route.path.length} dist=${route.distanceMeters}',
          );
        }

        if (route == null &&
            _strictRouting &&
            segType != 'direct' &&
            mode != 'plane') {
          _strictRoutingHardError(
            'segment_route_unavailable segment=$seg mode=$mode segType=$segType',
          );
        }
        final hidePortageFallback =
            route == null &&
            normalizedMode == 'portaging' &&
            segType != 'direct';

        final computed =
            route ??
            _straightRoute(
              path: fallbackPath,
              mode: mode,
              color: _standardRouteColor(mode).withOpacity(0.72),
              width: 4,
              patterns: const [],
              geodesic: mode == 'plane',
            );
        if (route == null &&
            (normalizedMode == 'portaging' || normalizedMode == 'hiking') &&
            segType != 'direct') {
          straightLineFallbackSegs[seg] = (
            segPoints: segPoints,
            mode: mode,
            segType: segType,
          );
        }
        if (hidePortageFallback) {
          unresolvedPortageSegs[seg] = List<Map<String, dynamic>>.from(
            segPoints,
          );
          segGeometry[seg] = fallbackPath;
          continue;
        }

        if (computed.styledSegments.isNotEmpty) {
          for (
            var styleIndex = 0;
            styleIndex < computed.styledSegments.length;
            styleIndex++
          ) {
            final styled = computed.styledSegments[styleIndex];
            if (styled.path.length < 2) continue;
            outPolylines.add(
              gmaps.Polyline(
                polylineId: gmaps.PolylineId(
                  '${_instanceId}_seg_${seg}_style_$styleIndex',
                ),
                points: styled.path,
                color: styled.color,
                width: styled.width,
                zIndex: styled.zIndex,
                geodesic: styled.geodesic,
                patterns: styled.patterns,
              ),
            );
          }
        } else {
          outPolylines.add(
            gmaps.Polyline(
              polylineId: gmaps.PolylineId('${_instanceId}_seg_$seg'),
              points: computed.path,
              color: computed.color,
              width: computed.width,
              zIndex: computed.zIndex,
              geodesic: computed.geodesic,
              patterns: computed.patterns,
            ),
          );
        }
        segGeometry[seg] = computed.path;
        segmentDistanceMeters[seg] = computed.distanceMeters;
        segmentDurationSeconds[seg] = computed.durationSeconds;
        distSum += computed.distanceMeters;
        durSum += computed.durationSeconds;
        instructions.addAll(computed.instructions);
        if (computed.stepDetails.isNotEmpty) {
          segmentDetails.add({
            'segmentIndex': seg,
            'mode': _normalizeTransportMode(mode),
            'distanceMeters': computed.distanceMeters,
            'durationSeconds': computed.durationSeconds,
            'steps': computed.stepDetails,
            if (computed.arrivalStop != null)
              'arrivalStop': computed.arrivalStop,
          });
        }
        if (computed.arrivalStop != null) {
          lastArrivalStop = computed.arrivalStop;
        }
      }

      _segmentGeometry = segGeometry;
      _emitRouteGeometry(segGeometry);
      if (outPolylines.isEmpty &&
          basePts.length >= 2 &&
          unresolvedPortageSegs.isEmpty) {
        final fallbackMode = _normalizeTransportMode(widget.transportMode);
        final fallback = _straightRoute(
          path: basePts.map((p) => gmaps.LatLng(_latOf(p), _lonOf(p))).toList(),
          mode: fallbackMode,
          color: _standardRouteColor(fallbackMode).withOpacity(0.82),
          width:
              (fallbackMode == 'hiking' || fallbackMode == 'portaging') ? 6 : 4,
          patterns: const [],
          geodesic: fallbackMode == 'plane',
        );
        outPolylines.add(
          gmaps.Polyline(
            polylineId: gmaps.PolylineId('${_instanceId}_seg_fallback'),
            points: fallback.path,
            color: fallback.color,
            width: fallback.width,
            zIndex: fallback.zIndex,
            geodesic: fallback.geodesic,
            patterns: fallback.patterns,
          ),
        );
        segGeometry[0] = fallback.path;
        distSum = fallback.distanceMeters;
        durSum = fallback.durationSeconds;
        debugPrint(
          'routeCalc produced no segment polylines; drew global fallback '
          'points=${basePts.length} mode=$fallbackMode',
        );
      }
      var hasBlockingPortageGap = unresolvedPortageSegs.isNotEmpty;
      final deferRouteSummary =
          straightLineFallbackSegs.isNotEmpty || hasBlockingPortageGap;

      _lastInstructions = instructions.take(8).toList(growable: false);
      widget.onRouteInstructions?.call(_lastInstructions);
      widget.onRouteSegmentDetails?.call(
        segmentDetails.toList(growable: false),
      );
      widget.onTransitArrivalStop?.call(
        lastArrivalStop ?? const <String, dynamic>{},
      );

      if (!mounted || seq != _rebuildSeq) return;
      setState(() {
        _polylines = outPolylines;
      });

      if (!deferRouteSummary && distSum > 0) {
        widget.onRouteSummary?.call(distSum, durSum);
      }

      var overlayPolylines = <gmaps.Polyline>{};
      var overlayMarkers = <gmaps.Marker>{};
      var campsiteOverlayMarkers = <gmaps.Marker>{};
      var trailSegmentCount = 0;
      var campsiteMarkerCount = 0;
      var trailheadMarkerCount = 0;
      var gasMarkerCount = 0;

      if (showNearbyContextOverlays && _modeMatchesAnySegment('hiking')) {
        try {
          final hiking = await _buildHikingOverlays(segGeometry);
          if (!mounted || seq != _rebuildSeq) return;
          if (hiking.polylines.isEmpty && hiking.markers.isEmpty) {
            final previousTrailPolylines = _existingHikingAdventurePolylines();
            final previousTrailMarkers = _existingHikingAdventureMarkers();
            overlayPolylines = {...overlayPolylines, ...previousTrailPolylines};
            overlayMarkers = {...overlayMarkers, ...previousTrailMarkers};
            campsiteOverlayMarkers = {
              ...campsiteOverlayMarkers,
              ...previousTrailMarkers,
            };
            trailSegmentCount += previousTrailPolylines.length;
            campsiteMarkerCount +=
                previousTrailMarkers
                    .where((marker) => marker.markerId.value.contains('_camp_'))
                    .length;
            trailheadMarkerCount +=
                previousTrailMarkers
                    .where(
                      (marker) => marker.markerId.value.contains('_trailhead_'),
                    )
                    .length;
            if (previousTrailPolylines.isNotEmpty ||
                previousTrailMarkers.isNotEmpty) {
              debugPrint(
                'hikingOverlays reused_previous_layers during route refresh',
              );
            }
          } else {
            overlayPolylines = {...overlayPolylines, ...hiking.polylines};
            overlayMarkers = {...overlayMarkers, ...hiking.markers};
            campsiteOverlayMarkers = {
              ...campsiteOverlayMarkers,
              ...hiking.markers,
            };
            trailSegmentCount += hiking.trailSegments;
            campsiteMarkerCount += hiking.campsiteMarkers;
            trailheadMarkerCount += hiking.trailheadMarkers;
          }
        } catch (e) {
          debugPrint('hikingOverlays route_refresh_failed err=$e');
        }
      }

      if (showNearbyContextOverlays && _modeMatchesAnySegment('portaging')) {
        try {
          final portaging = await _buildPortagingOverlays(segGeometry);
          if (!mounted || seq != _rebuildSeq) return;
          if (portaging.polylines.isEmpty && portaging.markers.isEmpty) {
            final previousPortagingPolylines =
                _existingPortagingAdventurePolylines();
            final previousPortagingMarkers =
                _existingPortagingAdventureMarkers();
            overlayPolylines = {
              ...overlayPolylines,
              ...previousPortagingPolylines,
            };
            overlayMarkers = {...overlayMarkers, ...previousPortagingMarkers};
            campsiteOverlayMarkers = {
              ...campsiteOverlayMarkers,
              ...previousPortagingMarkers,
            };
            trailSegmentCount += previousPortagingPolylines.length;
            campsiteMarkerCount +=
                previousPortagingMarkers
                    .where(
                      (marker) => marker.markerId.value.contains('_p_camp_'),
                    )
                    .length;
            trailheadMarkerCount +=
                previousPortagingMarkers
                    .where(
                      (marker) => marker.markerId.value.contains('_p_access_'),
                    )
                    .length;
            if (previousPortagingPolylines.isNotEmpty ||
                previousPortagingMarkers.isNotEmpty) {
              debugPrint(
                'portagingOverlays reused_previous_layers during route refresh',
              );
            }
          } else {
            overlayPolylines = {...overlayPolylines, ...portaging.polylines};
            overlayMarkers = {...overlayMarkers, ...portaging.markers};
            campsiteOverlayMarkers = {
              ...campsiteOverlayMarkers,
              ...portaging.markers,
            };
            trailSegmentCount += portaging.trailSegments;
            campsiteMarkerCount += portaging.campsiteMarkers;
            trailheadMarkerCount += portaging.trailheadMarkers;
          }
        } catch (e) {
          debugPrint('portagingOverlays route_refresh_failed err=$e');
        }
      }

      // Retry hiking/portaging segments once more after the initial routing
      // pass. The first attempt may have populated route/focus caches that
      // make a second pass resolvable without user-visible changes.
      if (straightLineFallbackSegs.isNotEmpty) {
        var retriedAny = false;
        for (final entry in straightLineFallbackSegs.entries) {
          if (!mounted || seq != _rebuildSeq) break;
          final seg = entry.key;
          final info = entry.value;
          _RouteComputation? retried;
          final normalizedMode = _normalizeTransportMode(info.mode);
          try {
            retried = await _retryAdventureRouteAfterCacheWarm(
              segPoints: info.segPoints,
              mode: info.mode,
              segType: info.segType,
            ).timeout(const Duration(seconds: 10), onTimeout: () => null);
          } catch (e) {
            debugPrint(
              'adventureRetry failed segment=$seg mode=$normalizedMode err=$e',
            );
          }
          if (retried == null || !mounted || seq != _rebuildSeq) {
            if (normalizedMode == 'portaging') {
              unresolvedPortageSegs[seg] = List<Map<String, dynamic>>.from(
                info.segPoints,
              );
            }
            continue;
          }
          debugPrint(
            'adventureRetry resolved segment=$seg mode=$normalizedMode '
            'points=${retried.path.length} '
            'meters=${retried.distanceMeters.toStringAsFixed(0)}',
          );
          // Replace the straight-line polyline with the resolved route.
          outPolylines.removeWhere(
            (p) =>
                p.polylineId.value == '${_instanceId}_seg_$seg' ||
                p.polylineId.value.startsWith(
                  '${_instanceId}_seg_${seg}_style_',
                ),
          );
          distSum -= segmentDistanceMeters[seg] ?? 0.0;
          durSum -= segmentDurationSeconds[seg] ?? 0.0;
          segGeometry[seg] = retried.path;
          segmentDistanceMeters[seg] = retried.distanceMeters;
          segmentDurationSeconds[seg] = retried.durationSeconds;
          distSum += retried.distanceMeters;
          durSum += retried.durationSeconds;
          if (retried.styledSegments.isNotEmpty) {
            for (var si = 0; si < retried.styledSegments.length; si++) {
              final styled = retried.styledSegments[si];
              if (styled.path.length < 2) continue;
              outPolylines.add(
                gmaps.Polyline(
                  polylineId: gmaps.PolylineId(
                    '${_instanceId}_seg_${seg}_style_$si',
                  ),
                  points: styled.path,
                  color: styled.color,
                  width: styled.width,
                  zIndex: styled.zIndex,
                  geodesic: styled.geodesic,
                  patterns: styled.patterns,
                ),
              );
            }
          } else {
            outPolylines.add(
              gmaps.Polyline(
                polylineId: gmaps.PolylineId('${_instanceId}_seg_$seg'),
                points: retried.path,
                color: retried.color,
                width: retried.width,
                zIndex: retried.zIndex,
                geodesic: retried.geodesic,
                patterns: retried.patterns,
              ),
            );
          }
          unresolvedPortageSegs.remove(seg);
          retriedAny = true;
        }
        if (retriedAny && mounted && seq == _rebuildSeq) {
          _segmentGeometry = segGeometry;
          _emitRouteGeometry(segGeometry);
          setState(() {
            _polylines = outPolylines;
          });
        }
      }

      hasBlockingPortageGap = unresolvedPortageSegs.isNotEmpty;
      if (hasBlockingPortageGap) {
        final unresolvedSegments = unresolvedPortageSegs.keys.toList()..sort();
        final firstSeg = unresolvedSegments.first;
        final failedSegPoints = unresolvedPortageSegs[firstSeg]!;
        _emitRouteErrorOnce(
          signature: '$calculationSig:portage:$firstSeg',
          message: _portageInaccessibleMessage(failedSegPoints),
        );
      } else {
        _lastRouteErrorSig = '';
      }

      if (deferRouteSummary &&
          !hasBlockingPortageGap &&
          mounted &&
          seq == _rebuildSeq &&
          distSum > 0) {
        widget.onRouteSummary?.call(distSum, durSum);
      }

      if (!showNearbyContextOverlays ||
          (!_modeMatchesAnySegment('hiking') &&
              !_modeMatchesAnySegment('portaging'))) {
        _didAttemptCampsiteInfoOpen = false;
      }

      if (showNearbyContextOverlays && _modeMatchesAnySegment('gas_stops')) {
        try {
          final gas = await _buildGasStopOverlays(segGeometry);
          if (!mounted || seq != _rebuildSeq) return;
          overlayPolylines = {...overlayPolylines, ...gas.polylines};
          overlayMarkers = {...overlayMarkers, ...gas.markers};
          gasMarkerCount += gas.gasMarkers;
        } catch (e) {
          debugPrint('gasStopOverlays failed err=$e');
        }
      }

      if (!mounted || seq != _rebuildSeq) return;
      setState(() {
        _modeSpecificPolylines = overlayPolylines;
        _modeSpecificMarkers = overlayMarkers;
      });
      if (showNearbyContextOverlays && campsiteOverlayMarkers.isNotEmpty) {
        _maybeOpenCampsiteInfoWindow(campsiteOverlayMarkers);
      }
      _logLayerCounts(
        mode: _normalizeTransportMode(widget.transportMode),
        routePolylines: outPolylines.length,
        trailSegments: trailSegmentCount,
        campsiteMarkers: campsiteMarkerCount,
        trailheadMarkers: trailheadMarkerCount,
        gasMarkers: gasMarkerCount,
      );
      _lastRouteCalcSig = calculationSig;
      _lastRouteHadBlockingGaps = hasBlockingPortageGap;
    } finally {
      _setRouteComputing(false, seq: seq);
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

  Future<void> _focusPoint(gmaps.LatLng point) async {
    final c = _controller;
    if (c == null) return;
    final targetZoom = 14.0.clamp(widget.minZoom, widget.maxZoom).toDouble();
    try {
      await c.animateCamera(
        gmaps.CameraUpdate.newLatLngZoom(point, targetZoom),
      );
    } catch (_) {
      try {
        await c.moveCamera(gmaps.CameraUpdate.newLatLngZoom(point, targetZoom));
      } catch (_) {}
    }
    _schedulePreviewUpdate();
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
    } catch (_) {
      if (!mounted) return;
      final fallbackLeft = ((_mapSize.width - _previewBubbleWidth) / 2).clamp(
        12.0,
        _mapSize.width - _previewBubbleWidth - 12.0,
      );
      setState(() {
        _previewOffset = Offset(fallbackLeft, 12);
      });
    }
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
      _currentZoom = 12;
      await c.moveCamera(gmaps.CameraUpdate.newLatLngZoom(only, 12));
      try {
        _currentZoom = await c.getZoomLevel();
      } catch (_) {}
      _scheduleRouteComputingOverlayRefresh();
      return;
    }

    await c.moveCamera(gmaps.CameraUpdate.newLatLngBounds(bounds, 48));
    try {
      _currentZoom = await c.getZoomLevel();
    } catch (_) {}
    _scheduleRouteComputingOverlayRefresh();
  }

  String _routeComputingHeadline() {
    final hasPortagingMode = _modeMatchesAnySegment('portaging');
    final hasHikingMode = _modeMatchesAnySegment('hiking');
    if (hasPortagingMode && !hasHikingMode) {
      return 'Tracing connected waterways';
    }
    if (hasHikingMode) {
      return 'Scanning trail network';
    }
    if (_modeMatchesAnySegment('train')) {
      return 'Linking transit segments';
    }
    return 'Locking route geometry';
  }

  String _routeComputingDetail() {
    final hasPortagingMode = _modeMatchesAnySegment('portaging');
    final hasHikingMode = _modeMatchesAnySegment('hiking');
    if (hasPortagingMode && !hasHikingMode) {
      return 'Sweeping for viable carries, shoreline landings, and uninterrupted water access.';
    }
    if (hasHikingMode) {
      return 'Matching your stops to mapped trails, campsites, and realistic backcountry connectors.';
    }
    if (_modeMatchesAnySegment('train')) {
      return 'Resolving the cleanest sequence of stations, transfers, and arrival timing.';
    }
    return 'Committing each leg, mode, and stop order into one continuous route.';
  }

  Widget _buildAdventureOverlayLoadButton() {
    if (!_showAdventureOverlayLoadButton && !_isAdventureOverlayLoading) {
      return const SizedBox.shrink();
    }
    final topOffset = (widget.routeComputingBannerTop < 0
            ? 16.0
            : widget.routeComputingBannerTop.toDouble() + 44.0)
        .clamp(16.0, 220.0);
    final hasHikingMode = _shouldRenderAdventureOverlayMode('hiking');
    final hasPortagingMode = _shouldRenderAdventureOverlayMode('portaging');
    final idleLabel =
        hasPortagingMode && !hasHikingMode
            ? 'View nearby portage routes & campsites'
            : 'View nearby trails & campsites';
    final loadingLabel =
        hasPortagingMode && !hasHikingMode
            ? 'Loading portage routes...'
            : 'Loading trails & campsites...';
    final label = _isAdventureOverlayLoading ? loadingLabel : idleLabel;

    return Positioned(
      top: topOffset,
      left: 0,
      right: 0,
      child: Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xF2FFFFFF),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: const Color(0x14000000)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x24000000),
                blurRadius: 20,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap:
                  _isAdventureOverlayLoading
                      ? null
                      : () {
                        unawaited(_loadAdventureOverlaysForViewport());
                      },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_isAdventureOverlayLoading)
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      const Icon(
                        Icons.terrain,
                        size: 18,
                        color: Colors.black87,
                      ),
                    const SizedBox(width: 8),
                    Text(
                      label,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Colors.black87,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_mapsReady) {
      return const Center(
        child: SizedBox(
          width: 32,
          height: 32,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    final initialTarget =
        _markers.isNotEmpty
            ? _markers.first.position
            : const gmaps.LatLng(0, 0);
    final mapStyle = _activeMapStyle();
    final markersForMap = {
      ..._markers,
      ..._modeSpecificMarkers,
      ..._focusedStepMarkers,
    };
    final polylinesForMap = {
      ..._polylines,
      ..._modeSpecificPolylines,
      ..._focusedStepPolylines,
    };

    final mapType =
        _usesTerrainMap() ? gmaps.MapType.terrain : gmaps.MapType.normal;

    return LayoutBuilder(
      builder: (ctx, constraints) {
        _mapSize = Size(constraints.maxWidth, constraints.maxHeight);
        final showGhost = _ghostViaLatLng != null || _isDraggingGhost;
        return MouseRegion(
          cursor:
              _isDraggingGhost
                  ? SystemMouseCursors.grabbing
                  : showGhost
                  ? SystemMouseCursors.grab
                  : SystemMouseCursors.basic,
          onExit: (_) {
            if (!_isDraggingGhost) _hideGhostVia();
          },
          child: Listener(
            onPointerHover: (event) => _handlePointerHover(event.localPosition),
            child: Stack(
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
                  style: mapStyle,
                  minMaxZoomPreference: gmaps.MinMaxZoomPreference(
                    widget.minZoom,
                    widget.maxZoom,
                  ),
                  onMapCreated: (c) {
                    _controller = c;
                    _controllerKeySig = _mapKeySig();
                    _fitCamera();
                    _schedulePreviewUpdate();
                    _scheduleRouteComputingOverlayRefresh(
                      delay: const Duration(milliseconds: 180),
                    );
                  },
                  markers: markersForMap,
                  polylines: polylinesForMap,
                  onCameraMove: (pos) {
                    _currentZoom = pos.zoom;
                    _schedulePreviewUpdate();
                    _scheduleRouteComputingOverlayRefresh();
                    // Hide ghost during panning/zooming to avoid stale position.
                    if (!_isDraggingGhost) _hideGhostVia();
                  },
                  onCameraIdle: () {
                    _scheduleAdventureOverlayRefresh();
                    _scheduleRouteComputingOverlayRefresh();
                  },
                  onTap: (p) {
                    _hidePreview();
                    if (widget.disableGestures) return;
                    if (DateTime.now().millisecondsSinceEpoch <
                        _suppressMapTapUntilMs) {
                      return;
                    }

                    // Garmin-style: if a ghost handle is visible, use its
                    // polyline-snapped position for pin-point accuracy.
                    if (_ghostViaLatLng != null &&
                        _ghostViaSegAfterIndex >= 0 &&
                        widget.onRouteTapAddVia != null) {
                      final ghost = _ghostViaLatLng!;
                      final seg = _ghostViaSegAfterIndex;
                      _hideGhostVia();
                      widget.onRouteTapAddVia?.call(
                        seg,
                        ghost.latitude,
                        ghost.longitude,
                      );
                      return;
                    }

                    if (widget.onRouteTapAddVia != null &&
                        widget.points.length >= 2) {
                      final after = _nearestSegmentAfterIndex(p);
                      if (after >= 0) {
                        widget.onRouteTapAddVia?.call(
                          after,
                          p.latitude,
                          p.longitude,
                        );
                        return;
                      }
                      // Tap was too far from the route – fall through to normal map tap.
                    }
                    widget.onMapTap?.call(p.latitude, p.longitude);
                  },
                  zoomControlsEnabled:
                      widget.zoomControlsEnabled && !widget.disableDefaultUi,
                  zoomGesturesEnabled:
                      !widget.disableGestures && !_isDraggingGhost,
                  scrollGesturesEnabled:
                      !widget.disableGestures && !_isDraggingGhost,
                  mapToolbarEnabled: false,
                  myLocationButtonEnabled: false,
                  rotateGesturesEnabled: false,
                  tiltGesturesEnabled: false,
                  compassEnabled: false,
                ),
                if (_isRouteComputing)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: _RouteComputingOverlay(
                        headline: _routeComputingHeadline(),
                        detail: _routeComputingDetail(),
                        topOffset:
                            widget.routeComputingBannerTop < 0
                                ? 16
                                : widget.routeComputingBannerTop,
                        start: _routeComputingStartOffset,
                        target: _routeComputingTargetOffset,
                        curveSeed: _routeComputingCurveSeed,
                      ),
                    ),
                  ),
                _buildAdventureOverlayLoadButton(),
                _buildGhostViaOverlay(),
                _buildPreviewOverlay(),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _RouteComputingOverlay extends StatefulWidget {
  final String headline;
  final String detail;
  final double topOffset;
  final Offset? start;
  final Offset? target;
  final double curveSeed;

  const _RouteComputingOverlay({
    required this.headline,
    required this.detail,
    required this.topOffset,
    required this.start,
    required this.target,
    required this.curveSeed,
  });

  @override
  State<_RouteComputingOverlay> createState() => _RouteComputingOverlayState();
}

class _RouteComputingOverlayState extends State<_RouteComputingOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final pulse = 0.45 + (0.55 * math.sin(_controller.value * math.pi * 2));
        return RepaintBoundary(
          child: Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _RouteBeamPainter(
                    progress: _controller.value,
                    start: widget.start,
                    target: widget.target,
                    curveSeed: widget.curveSeed,
                  ),
                ),
              ),
              Positioned(
                top: widget.topOffset.toDouble(),
                left: 16,
                right: 16,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 320),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xE0162431),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: const Color(0x3367E8D9)),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x30000000),
                            blurRadius: 18,
                            offset: Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 9,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Color.lerp(
                                  const Color(0xFF38BDF8),
                                  const Color(0xFF2DD4BF),
                                  pulse.clamp(0.0, 1.0),
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(
                                      0xFF38BDF8,
                                    ).withValues(alpha: 0.35),
                                    blurRadius: 12,
                                    spreadRadius: 2,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    widget.headline,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w800,
                                      fontSize: 13,
                                    ),
                                  ),
                                  Text(
                                    widget.detail,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Color(0xFFD0D9E4),
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _RouteBeamPainter extends CustomPainter {
  final double progress;
  final Offset? start;
  final Offset? target;
  final double curveSeed;

  const _RouteBeamPainter({
    required this.progress,
    required this.start,
    required this.target,
    required this.curveSeed,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final origin = start;
    final destination = target;
    if (origin == null || destination == null) return;

    final delta = destination - origin;
    final distance = delta.distance;
    if (distance < 18) return;

    final mid = Offset(
      (origin.dx + destination.dx) / 2,
      (origin.dy + destination.dy) / 2,
    );
    final normal = Offset(-delta.dy, delta.dx);
    final normalLength = normal.distance;
    if (normalLength <= 0.0001) return;
    final normalUnit = Offset(
      normal.dx / normalLength,
      normal.dy / normalLength,
    );
    final directionSign = curveSeed >= 0.5 ? -1.0 : 1.0;
    final arcHeight = (distance * (0.16 + (0.12 * curveSeed))).clamp(
      30.0,
      104.0,
    );
    var control = mid + (normalUnit * (arcHeight * directionSign));
    final maxControlY = math.min(origin.dy, destination.dy) - 26.0;
    if (control.dy > maxControlY) {
      control = Offset(control.dx, maxControlY);
    }

    final path =
        Path()
          ..moveTo(origin.dx, origin.dy)
          ..quadraticBezierTo(
            control.dx,
            control.dy,
            destination.dx,
            destination.dy,
          );

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..color = const Color(0x33FFFFFF),
    );

    final metrics = path.computeMetrics();
    if (metrics.isEmpty) return;
    final metric = metrics.first;
    if (metric.length <= 1) return;

    final head = metric.length * (0.14 + (0.82 * progress));
    final tail = math.max(36.0, metric.length * 0.22);
    final segment = metric.extractPath(
      math.max(0.0, head - tail),
      math.min(metric.length, head),
    );
    canvas.drawPath(
      segment,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 9
        ..strokeCap = StrokeCap.round
        ..color = const Color(0x4438BDF8),
    );
    canvas.drawPath(
      segment,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.6
        ..strokeCap = StrokeCap.round
        ..shader = const LinearGradient(
          colors: [Color(0x0038BDF8), Color(0xFF38BDF8), Color(0xFF2DD4BF)],
        ).createShader(Offset.zero & size),
    );

    final tangent = metric.getTangentForOffset(head);
    if (tangent != null) {
      canvas.drawCircle(
        tangent.position,
        6,
        Paint()..color = const Color(0xCC67E8F9),
      );
      canvas.drawCircle(
        tangent.position,
        12,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = const Color(0x4467E8F9),
      );
    }

    final pulse = 0.5 + (0.5 * math.sin(progress * math.pi * 2));
    final targetStroke =
        Color.lerp(
          const Color(0x6638BDF8),
          const Color(0xAA2DD4BF),
          pulse.clamp(0.0, 1.0),
        )!;
    final startStroke =
        Color.lerp(
          const Color(0x6638BDF8),
          const Color(0x8838BDF8),
          pulse.clamp(0.0, 1.0),
        )!;
    canvas.drawCircle(origin, 5, Paint()..color = const Color(0xFF38BDF8));
    canvas.drawCircle(
      origin,
      12 + (pulse * 4),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = startStroke,
    );
    canvas.drawCircle(destination, 6, Paint()..color = const Color(0xFF2DD4BF));
    canvas.drawCircle(
      destination,
      14 + (pulse * 5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = targetStroke,
    );
    canvas.drawCircle(
      destination,
      24 + (pulse * 8),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = targetStroke.withValues(alpha: 0.38),
    );
  }

  @override
  bool shouldRepaint(covariant _RouteBeamPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.start != start ||
        oldDelegate.target != target ||
        oldDelegate.curveSeed != curveSeed;
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
  late html.Element _element;
  late html.IFrameElement _iframeElement;
  late html.DivElement _titleElement;
  late html.DivElement _regionElement;
  late html.DivElement _mapWrap;

  static bool _styleInjected = false;

  static const double _mapWidthPx = _previewBubbleWidth;
  static const double _mapHeightPx = _previewMapHeight;

  String _resolveApiKey() {
    const fromDefine = String.fromEnvironment('GOOGLE_MAPS_API_KEY');
    if (fromDefine.isNotEmpty) return fromDefine;

    try {
      final meta = html.document.querySelector(
        'meta[name="google-maps-api-key"]',
      );
      return meta?.getAttribute('content')?.trim() ?? '';
    } catch (_) {
      return '';
    }
  }

  String _buildEmbedUrl() {
    final lat = widget.lat;
    final lon = widget.lon;
    const span = 0.01;
    final left = lon - span;
    final right = lon + span;
    final bottom = lat - span;
    final top = lat + span;

    return Uri.https('www.openstreetmap.org', '/export/embed.html', {
      'bbox': '$left,$bottom,$right,$top',
      'layer': 'mapnik',
      'marker': '$lat,$lon',
    }).toString();
  }

  void _updateIframeSrc() {
    _iframeElement.src = _buildEmbedUrl();
  }

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
    // Keep preview above map tiles/markers without competing with app-level overlays.
    container.style.zIndex = '2';

    _mapWrap = html.DivElement();
    _mapWrap.className = 'trypr-map3d-view';
    _mapWrap.style.width = '100%';
    _mapWrap.style.height = '${_mapHeightPx}px';

    // Use Maps Embed API iframe for satellite view
    _iframeElement = html.IFrameElement();
    _iframeElement.src = _buildEmbedUrl();
    _iframeElement.style.width = '100%';
    _iframeElement.style.height = '100%';
    _iframeElement.style.border = '0';
    _iframeElement.style.borderRadius = '12px 12px 8px 8px';
    _iframeElement.style.pointerEvents = 'none';
    _iframeElement.setAttribute('loading', 'lazy');

    _mapWrap.append(_iframeElement);

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
      ..append(_mapWrap)
      ..append(info);

    _element = container;

    ui_web.platformViewRegistry.registerViewFactory(
      _viewType,
      (int viewId) => _element,
    );
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
  background: #1a3a5c;
}
.trypr-map3d-view > iframe {
  width: 100%;
  height: 100%;
  display: block;
  border: 0;
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
      _updateIframeSrc();
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

  Future<gmaps.BitmapDescriptor> _memoized(
    String key,
    Future<gmaps.BitmapDescriptor> Function() builder,
  ) {
    final cached = _cache[key];
    if (cached != null) return cached;
    final future = builder();
    _cache[key] = future;
    future.then<void>(
      (_) {},
      onError: (_) {
        _cache.remove(key);
      },
    );
    return future;
  }

  Future<gmaps.BitmapDescriptor> viaDot({required double dpr}) {
    return _memoized(
      'viaDot:${Colors.green.value}:$dpr',
      () => _buildCircleBadge(
        dpr: dpr,
        logicalSize: 24.0,
        background: const Color(0xFF1565C0),
        foreground: Colors.white,
        icon: null,
        text: null,
        borderWidthLogical: 3.0,
      ),
    );
  }

  Future<gmaps.BitmapDescriptor> campsiteTriangle({required double dpr}) {
    return _memoized(
      'campTri:${const Color(0xFFEF6C00).value}:$dpr',
      () => _buildTriangleBadge(
        dpr: dpr,
        logicalWidth: 16.0,
        logicalHeight: 18.0,
        fill: const Color(0xFFEF6C00),
        stroke: Colors.white,
      ),
    );
  }

  Future<gmaps.BitmapDescriptor> trailheadHikePin({required double dpr}) {
    return _memoized(
      'trailHead:${const Color(0xFF00897B).value}:$dpr',
      () => _buildCircleBadge(
        dpr: dpr,
        logicalSize: 20.0,
        background: const Color(0xFF00897B),
        foreground: Colors.white,
        icon: Icons.terrain,
        text: null,
        borderWidthLogical: 2.0,
      ),
    );
  }

  Future<gmaps.BitmapDescriptor> portageAccessPin({required double dpr}) {
    return _memoized(
      'portageAccess:${const Color(0xFF1565C0).value}:$dpr',
      () => _buildCircleBadge(
        dpr: dpr,
        logicalSize: 22.0,
        background: const Color(0xFF1565C0),
        foreground: Colors.white,
        icon: Icons.kayaking,
        text: null,
        borderWidthLogical: 2.2,
      ),
    );
  }

  Future<gmaps.BitmapDescriptor> numbered({
    required int number,
    required Color color,
    required double dpr,
  }) {
    return _memoized(
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
    return _memoized(
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
    try {
      final pixelSize = math.max(8, (logicalSize * dpr).round());

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
    } catch (e) {
      debugPrint('markerCircleBadge build_failed err=$e');
      return gmaps.BitmapDescriptor.defaultMarker;
    }
  }

  Future<gmaps.BitmapDescriptor> _buildTriangleBadge({
    required double dpr,
    required double logicalWidth,
    required double logicalHeight,
    required Color fill,
    required Color stroke,
  }) async {
    try {
      final pixelWidth = math.max(8, (logicalWidth * dpr).round());
      final pixelHeight = math.max(8, (logicalHeight * dpr).round());

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final size = ui.Size(pixelWidth.toDouble(), pixelHeight.toDouble());

      final p0 = ui.Offset(size.width / 2, 1.2 * dpr);
      final p1 = ui.Offset(size.width - (1.2 * dpr), size.height - (1.2 * dpr));
      final p2 = ui.Offset(1.2 * dpr, size.height - (1.2 * dpr));
      final path =
          ui.Path()
            ..moveTo(p0.dx, p0.dy)
            ..lineTo(p1.dx, p1.dy)
            ..lineTo(p2.dx, p2.dy)
            ..close();

      final fillPaint =
          ui.Paint()
            ..color = fill
            ..style = ui.PaintingStyle.fill;
      final strokePaint =
          ui.Paint()
            ..color = stroke.withOpacity(0.9)
            ..style = ui.PaintingStyle.stroke
            ..strokeWidth = (1.8 * dpr).clamp(1.5, 4.0);

      canvas.drawPath(path, fillPaint);
      canvas.drawPath(path, strokePaint);

      final picture = recorder.endRecording();
      final image = await picture.toImage(pixelWidth, pixelHeight);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) {
        return gmaps.BitmapDescriptor.defaultMarker;
      }
      final bytes = data.buffer.asUint8List();
      return gmaps.BitmapDescriptor.fromBytes(
        bytes,
        size: ui.Size(logicalWidth, logicalHeight),
      );
    } catch (e) {
      debugPrint('markerTriangleBadge build_failed err=$e');
      return gmaps.BitmapDescriptor.defaultMarkerWithHue(
        gmaps.BitmapDescriptor.hueOrange,
      );
    }
  }
}
