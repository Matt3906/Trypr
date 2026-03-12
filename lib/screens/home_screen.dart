import 'package:flutter/material.dart';
import 'package:trypr/utils/trypr_snackbar.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:trypr/models/trip_model.dart';
import 'package:trypr/services/firestore_service.dart';
import 'package:trypr/services/ai_suggestions.dart';
import 'package:trypr/services/premium_access.dart';
import 'package:trypr/services/geocode.dart';
import 'package:trypr/screens/trip_detail_screen.dart';
import 'package:trypr/screens/verified_trip_map_screen.dart';
import 'package:trypr/theme/app_theme.dart';
import 'package:trypr/widgets/top_taskbar.dart';
import 'package:trypr/widgets/web_interceptor.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:intl/intl.dart';
import 'package:trypr/utils/platform_view_registry.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  final ScrollController _scrollController = ScrollController();
  // Continuous progress value [0..1] representing dock animation progress.
  double _dockProgress = 0.0;

  // Globe state
  Map<String, dynamic>? _selectedTrip;
  bool _showOpenButton = false;
  bool _openingTrip = false;
  late AnimationController _buttonAnimController;
  late Animation<double> _buttonAnimation;
  static const String _mapViewType = 'trypr-3d-map-view';
  bool _mapFactoryRegistered = false;
  bool _mapLoaded = false;
  bool _globeReady = false;
  html.IFrameElement? _mapIFrame;
  int _selectedStopIndex = 0;
  bool _showStopNavigator = false;
  bool _showPoiInsightCard = false;
  final Map<String, Map<String, dynamic>> _poiInsightCache = {};
  final Set<String> _poiInsightLoading = <String>{};
  final Map<String, String> _stopCityCache = {};
  bool? _hasPremiumAccess;
  Future<bool>? _premiumAccessFuture;
  Timer? _introFocusTimer;
  Timer? _mapReadyFallbackTimer;
  int _tripAnimationToken = 0;
  String? _lastAnimatedTripKey;
  static const bool _enableStreetViewGallery = bool.fromEnvironment(
    'ENABLE_STREET_VIEW_GALLERY',
    defaultValue: false,
  );

  String _mapPostTargetOrigin() {
    try {
      final origin = Uri.base.origin;
      if (origin.isNotEmpty && origin != 'null') return origin;
    } catch (_) {}
    return '*';
  }

  bool _isTrustedMapMessage(html.MessageEvent event) {
    try {
      final origin = Uri.base.origin;
      if (origin.isNotEmpty &&
          origin != 'null' &&
          event.origin.isNotEmpty &&
          event.origin != origin) {
        return false;
      }
    } catch (_) {}

    return true;
  }

  String _resolvedMapsKey() {
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

  String? _messageType(dynamic data) {
    if (data == null) return null;
    if (data is Map) {
      final t = data['type'];
      if (t != null) return t.toString();
      return null;
    }
    if (data is String) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map) {
          final t = decoded['type'];
          if (t != null) return t.toString();
        }
      } catch (_) {}
      return null;
    }
    try {
      final dynamic dynamicData = data;
      final t = dynamicData['type'];
      if (t != null) return t.toString();
    } catch (_) {}
    return null;
  }

  @override
  void initState() {
    super.initState();

    // Button animation for globe
    _buttonAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _buttonAnimation = CurvedAnimation(
      parent: _buttonAnimController,
      curve: Curves.easeOutBack,
    );

    _scrollController.addListener(() {
      if (!mounted) return;
      // Start and end offsets (relative to viewport height) where the dock transition occurs.
      final h = MediaQuery.of(context).size.height;
      final start = h * 0.4; // begin transition when ~40% scrolled
      final end = h * 0.75; // fully docked by ~75%
      final raw = (_scrollController.offset - start) / (end - start);
      final progress = raw.clamp(0.0, 1.0);
      if ((progress - _dockProgress).abs() > 0.01) {
        setState(() => _dockProgress = progress);
      }
    });
    _initializeMapFrame();
    unawaited(_primePremiumAccess());
  }

  @override
  void dispose() {
    _introFocusTimer?.cancel();
    _mapReadyFallbackTimer?.cancel();
    _scrollController.dispose();
    _buttonAnimController.dispose();
    super.dispose();
  }

  Future<void> _primePremiumAccess() async {
    await _premiumAccessEnabled();
  }

  Future<bool> _premiumAccessEnabled() {
    final cached = _hasPremiumAccess;
    if (cached != null) return Future<bool>.value(cached);

    final pending = _premiumAccessFuture;
    if (pending != null) return pending;

    _premiumAccessFuture = PremiumAccessService()
        .canAccessPremium()
        .then((enabled) {
          _hasPremiumAccess = enabled;
          if (mounted) setState(() {});
          return enabled;
        })
        .catchError((_) {
          _hasPremiumAccess = false;
          if (mounted) setState(() {});
          return false;
        })
        .whenComplete(() {
          _premiumAccessFuture = null;
        });
    return _premiumAccessFuture!;
  }

  // Globe trip selection handlers
  void _onTripSelected(Map<String, dynamic> trip) {
    final selectedId = (_selectedTrip?['id'] ?? '').toString();
    final incomingId = (trip['id'] ?? '').toString();
    if (selectedId.isNotEmpty &&
        incomingId.isNotEmpty &&
        selectedId == incomingId &&
        _canEditSelectedTrip(trip)) {
      _openTrip();
      return;
    }

    _introFocusTimer?.cancel();
    _lastAnimatedTripKey = null;
    setState(() {
      _selectedTrip = trip;
      _showOpenButton = false;
      _openingTrip = false;
      _selectedStopIndex = 0;
      _showStopNavigator = false;
      _showPoiInsightCard = false;
    });

    Future.delayed(const Duration(milliseconds: 1600), () {
      if (mounted &&
          _selectedTrip?['id'] == trip['id'] &&
          _canEditSelectedTrip(_selectedTrip)) {
        setState(() => _showOpenButton = true);
        _buttonAnimController.forward(from: 0);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _sendTripsToMap(animateCamera: true);
    });
  }

  void _clearSelection() {
    _introFocusTimer?.cancel();
    _tripAnimationToken++;
    setState(() {
      _selectedTrip = null;
      _showOpenButton = false;
      _openingTrip = false;
      _selectedStopIndex = 0;
      _showStopNavigator = false;
      _showPoiInsightCard = false;
    });
    _buttonAnimController.reset();
    // Clear the route from the globe
    if (kIsWeb && _mapIFrame?.contentWindow != null) {
      _mapIFrame!.contentWindow!.postMessage({
        'type': 'clearRoute',
      }, _mapPostTargetOrigin());
    }
  }

  bool _canEditSelectedTrip(Map<String, dynamic>? trip) {
    return trip?['canEdit'] == true;
  }

  void _openTrip() async {
    if (_openingTrip) return;
    final trip = _selectedTrip;
    if (!_canEditSelectedTrip(trip)) return;

    final tripId = trip?['id']?.toString() ?? '';
    if (tripId.isEmpty) return;

    setState(() => _openingTrip = true);
    try {
      Map<String, dynamic> resolvedData = {
        'name': (trip?['title'] ?? 'Trip').toString(),
        'title': (trip?['title'] ?? 'Trip').toString(),
        'waypoints':
            trip?['waypoints'] is List
                ? List<dynamic>.from(trip?['waypoints'] as List)
                : const <dynamic>[],
        if (trip?['startDate'] != null) 'startDate': trip?['startDate'],
        if (trip?['endDate'] != null) 'endDate': trip?['endDate'],
        if (trip?['distance'] != null) 'totalKm': trip?['distance'],
        if (trip?['transportMode'] != null)
          'transportMode': trip?['transportMode'],
        if (trip?['segmentTransportModes'] is List)
          'segmentTransportModes': List<dynamic>.from(
            trip?['segmentTransportModes'] as List,
          ),
        if (trip?['segmentRoutingTypes'] is List)
          'segmentRoutingTypes': List<dynamic>.from(
            trip?['segmentRoutingTypes'] as List,
          ),
      };

      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        try {
          final doc = await FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .collection('trips')
              .doc(tripId)
              .get()
              .timeout(const Duration(seconds: 6));

          if (doc.exists) {
            final local = doc.data() ?? <String, dynamic>{};
            try {
              resolvedData = await _resolveTripDataForOpen(
                user.uid,
                tripId,
                local,
              ).timeout(const Duration(seconds: 6));
            } catch (_) {
              resolvedData = local;
            }
          }
        } catch (_) {
          // Fall back to selected-card data when Firestore read is slow/unavailable.
        }
      }

      if (!mounted) return;

      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TripDetailScreen(docId: tripId, data: resolvedData),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showTryprSnackBar(SnackBar(content: Text('Could not open trip: $e')));
    } finally {
      if (mounted) {
        setState(() => _openingTrip = false);
      }
    }
  }

  String? _tripRefPathFromData(Map<String, dynamic> data) {
    final raw = data['tripRef'];
    if (raw is String) {
      final v = raw.trim();
      return v.isEmpty ? null : v;
    }
    if (raw is DocumentReference) return raw.path;
    final v = raw?.toString().trim();
    if (v == null || v.isEmpty) return null;
    return v;
  }

  Future<Map<String, dynamic>> _resolveTripDataForOpen(
    String userUid,
    String tripId,
    Map<String, dynamic> local,
  ) async {
    final hasWaypoints =
        local['waypoints'] is List && (local['waypoints'] as List).isNotEmpty;
    final tripRefPath = _tripRefPathFromData(local);
    if (tripRefPath == null) return local;

    final needsHydration =
        !hasWaypoints ||
        local['transportMode'] == null ||
        local['segmentTransportModes'] == null ||
        local['segmentRoutingTypes'] == null ||
        local['routeVia'] == null;
    if (!needsHydration) return local;

    try {
      final remoteDoc = await FirebaseFirestore.instance.doc(tripRefPath).get();
      if (!remoteDoc.exists) return local;
      final remote = remoteDoc.data() ?? <String, dynamic>{};
      final merged = Map<String, dynamic>.from(remote)..addAll(local);
      final syncPayload = <String, dynamic>{};

      final remoteWaypoints = remote['waypoints'] ?? remote['stops'];
      if (!hasWaypoints &&
          remoteWaypoints is List &&
          remoteWaypoints.isNotEmpty) {
        merged['waypoints'] = remoteWaypoints;
        syncPayload['waypoints'] = remoteWaypoints;
      }

      if (local['startDate'] == null && remote['startDate'] != null) {
        merged['startDate'] = remote['startDate'];
        syncPayload['startDate'] = remote['startDate'];
      }
      if (local['endDate'] == null && remote['endDate'] != null) {
        merged['endDate'] = remote['endDate'];
        syncPayload['endDate'] = remote['endDate'];
      }
      if (local['totalKm'] == null && remote['totalKm'] != null) {
        merged['totalKm'] = remote['totalKm'];
        syncPayload['totalKm'] = remote['totalKm'];
      }
      if (local['transportMode'] == null && remote['transportMode'] != null) {
        merged['transportMode'] = remote['transportMode'];
        syncPayload['transportMode'] = remote['transportMode'];
      }
      if (local['segmentTransportModes'] == null &&
          remote['segmentTransportModes'] is List) {
        merged['segmentTransportModes'] = remote['segmentTransportModes'];
        syncPayload['segmentTransportModes'] = remote['segmentTransportModes'];
      }
      if (local['segmentRoutingTypes'] == null &&
          remote['segmentRoutingTypes'] is List) {
        merged['segmentRoutingTypes'] = remote['segmentRoutingTypes'];
        syncPayload['segmentRoutingTypes'] = remote['segmentRoutingTypes'];
      }
      if (local['routeVia'] == null && remote['routeVia'] is List) {
        merged['routeVia'] = remote['routeVia'];
        syncPayload['routeVia'] = remote['routeVia'];
      }
      if (local['transitArrivalStop'] == null &&
          remote['transitArrivalStop'] != null) {
        merged['transitArrivalStop'] = remote['transitArrivalStop'];
        syncPayload['transitArrivalStop'] = remote['transitArrivalStop'];
      }

      if (syncPayload.isNotEmpty) {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(userUid)
            .collection('trips')
            .doc(tripId)
            .set(syncPayload, SetOptions(merge: true));
      }
      merged['tripRef'] = tripRefPath;
      return merged;
    } catch (_) {
      return local;
    }
  }

  void _initializeMapFrame() {
    if (!kIsWeb || _mapFactoryRegistered) return;

    final mapsKey = _resolvedMapsKey();
    final earthSrc = _earthAssetUrl(mapsKey: mapsKey);

    _mapIFrame =
        html.IFrameElement()
          ..src = earthSrc
          ..style.border = '0'
          ..style.width = '100%'
          ..style.height = '100%'
          ..style.display = 'block'
          // Keep the globe visual-only on this screen so overlay UI receives taps.
          ..style.pointerEvents = 'none'
          ..title = 'Trypr 3D Globe'
          ..allow = 'fullscreen';
    _mapIFrame!.onLoad.listen((_) => _handleMapIFrameLoaded());

    // Listen for postMessage events from the Earth iframe (map_ready, etc.)
    html.window.addEventListener('message', (html.Event event) {
      if (event is html.MessageEvent) {
        if (!_isTrustedMapMessage(event)) return;
        if (_messageType(event.data) == 'map_ready') {
          if (!_globeReady) {
            _globeReady = true;
            // The 3D globe is now ready — send the route if a trip is selected
            _sendTripsToMap(animateCamera: true);
          }
        }
      }
    });

    if (kIsWeb) {
      registerHtmlElementViewFactory(_mapViewType, (int viewId) => _mapIFrame!);
    }
    _mapFactoryRegistered = true;
  }

  static String _earthAssetUrl({required String mapsKey}) {
    final encodedKey = Uri.encodeQueryComponent(mapsKey);
    final cacheBust = DateTime.now().millisecondsSinceEpoch;
    return mapsKey.isEmpty
        ? '/earth/index.html?embed=true&cb=$cacheBust'
        : '/earth/index.html?embed=true&gmapsKey=$encodedKey&cb=$cacheBust';
  }

  void _handleMapIFrameLoaded() {
    if (_mapLoaded) return;
    _mapLoaded = true;
    _sendTestPing();
    // Don't send route yet — wait for 'map_ready' from the Earth 3D globe
    _mapReadyFallbackTimer?.cancel();
    _mapReadyFallbackTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted || _globeReady) return;
      _globeReady = true;
      _sendTripsToMap(animateCamera: true);
    });
  }

  void _sendTestPing() {
    if (!kIsWeb || _mapIFrame?.contentWindow == null) return;
    _mapIFrame!.contentWindow!.postMessage({
      'type': 'flutter_ping',
      'timestamp': DateTime.now().toIso8601String(),
    }, _mapPostTargetOrigin());
  }

  double _toDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? double.nan;
    return double.nan;
  }

  List<Map<String, dynamic>> _normalizedWaypointsFromTrip(
    Map<String, dynamic> trip,
  ) {
    final raw = trip['waypoints'];
    if (raw is! List) return const [];
    final out = <Map<String, dynamic>>[];
    for (final e in raw) {
      if (e is! Map) continue;
      final m = Map<String, dynamic>.from(e.cast<String, dynamic>());
      final lat = _toDouble(m['lat'] ?? m['latitude']);
      final lon = _toDouble(m['lon'] ?? m['lng'] ?? m['longitude']);
      if (!lat.isFinite || !lon.isFinite) continue;
      m['lat'] = lat;
      m['lon'] = lon;
      m['name'] = (m['name'] ?? m['title'] ?? '').toString();
      out.add(m);
    }
    return out;
  }

  ({double lat, double lon, double range}) _overviewCameraForTrip(
    List<Map<String, dynamic>> waypoints,
  ) {
    final first = waypoints.first;
    double minLat = first['lat'] as double;
    double maxLat = minLat;
    double minLon = first['lon'] as double;
    double maxLon = minLon;

    for (final p in waypoints) {
      final lat = p['lat'] as double;
      final lon = p['lon'] as double;
      if (lat < minLat) minLat = lat;
      if (lat > maxLat) maxLat = lat;
      if (lon < minLon) minLon = lon;
      if (lon > maxLon) maxLon = lon;
    }

    final centerLat = (minLat + maxLat) / 2;
    final centerLon = (minLon + maxLon) / 2;
    final spread = math.max((maxLat - minLat).abs(), (maxLon - minLon).abs());
    final normalizedSpread = spread < 0.45 ? 0.45 : spread;
    final range = (normalizedSpread * 111000 * 3).clamp(80000.0, 2200000.0);

    return (lat: centerLat, lon: centerLon, range: range.toDouble());
  }

  double _bearingDegrees({
    required double fromLat,
    required double fromLon,
    required double toLat,
    required double toLon,
  }) {
    final phi1 = fromLat * math.pi / 180.0;
    final phi2 = toLat * math.pi / 180.0;
    final deltaLambda = (toLon - fromLon) * math.pi / 180.0;
    final y = math.sin(deltaLambda) * math.cos(phi2);
    final x =
        math.cos(phi1) * math.sin(phi2) -
        math.sin(phi1) * math.cos(phi2) * math.cos(deltaLambda);
    return (math.atan2(y, x) * 180.0 / math.pi + 360.0) % 360.0;
  }

  void _postFlyTo({
    required double lat,
    required double lon,
    required double range,
    double tilt = 55,
    double heading = 0,
  }) {
    if (!kIsWeb || _mapIFrame?.contentWindow == null) return;
    _mapIFrame!.contentWindow!.postMessage({
      'type': 'flyTo',
      'lat': lat,
      'lng': lon,
      'range': range,
      'tilt': tilt,
      'heading': heading,
    }, _mapPostTargetOrigin());
  }

  void _focusStopIndex(
    int index, {
    List<Map<String, dynamic>>? explicitWaypoints,
  }) {
    final waypoints =
        explicitWaypoints ??
        (_selectedTrip == null
            ? const <Map<String, dynamic>>[]
            : _normalizedWaypointsFromTrip(_selectedTrip!));
    if (waypoints.isEmpty) return;

    final count = waypoints.length;
    final normalizedIndex = ((index % count) + count) % count;
    final stop = waypoints[normalizedIndex];

    if (mounted) {
      setState(() {
        _selectedStopIndex = normalizedIndex;
        _showStopNavigator = count > 1;
        _showPoiInsightCard = true;
      });
    }
    unawaited(_ensurePoiInsightForStop(stop, normalizedIndex));

    final closeRange = count > 1 ? 1800.0 : 1400.0;
    double heading = 0.0;
    if (count > 1) {
      final targetIndex =
          normalizedIndex < count - 1
              ? normalizedIndex + 1
              : normalizedIndex - 1;
      final target = waypoints[targetIndex];
      heading = _bearingDegrees(
        fromLat: stop['lat'] as double,
        fromLon: stop['lon'] as double,
        toLat: target['lat'] as double,
        toLon: target['lon'] as double,
      );
    }
    _postFlyTo(
      lat: (stop['lat'] as double),
      lon: (stop['lon'] as double),
      range: closeRange,
      tilt: 76,
      heading: heading,
    );
  }

  void _focusNextStop() {
    _focusStopIndex(_selectedStopIndex + 1);
  }

  void _focusPreviousStop() {
    _focusStopIndex(_selectedStopIndex - 1);
  }

  void _runTripIntroAnimation(
    String tripKey,
    List<Map<String, dynamic>> waypoints,
  ) {
    if (waypoints.isEmpty) return;
    _tripAnimationToken++;
    final token = _tripAnimationToken;
    _introFocusTimer?.cancel();
    if (mounted && _showStopNavigator) {
      setState(() => _showStopNavigator = false);
    }

    final overview = _overviewCameraForTrip(waypoints);
    _postFlyTo(
      lat: overview.lat,
      lon: overview.lon,
      range: overview.range,
      tilt: 52,
      heading: 0,
    );

    _introFocusTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted || token != _tripAnimationToken) return;
      _focusStopIndex(0, explicitWaypoints: waypoints);
      _lastAnimatedTripKey = tripKey;
    });
  }

  void _sendTripsToMap({bool animateCamera = false}) {
    if (!kIsWeb ||
        _mapIFrame?.contentWindow == null ||
        !_globeReady ||
        _selectedTrip == null) {
      return;
    }

    final trip = _selectedTrip!;
    final waypoints = _normalizedWaypointsFromTrip(trip);

    if (waypoints.isEmpty) {
      _mapIFrame!.contentWindow!.postMessage({
        'type': 'clearRoute',
      }, _mapPostTargetOrigin());
      return;
    }

    // Extract origin, destination, and waypoint stops
    final origin =
        waypoints.isNotEmpty
            ? {
              'lat': waypoints[0]['lat'] as double,
              'lng': waypoints[0]['lon'] as double,
              'name': waypoints[0]['name'] as String,
            }
            : null;

    final destination =
        waypoints.length > 1
            ? {
              'lat': waypoints[waypoints.length - 1]['lat'] as double,
              'lng': waypoints[waypoints.length - 1]['lon'] as double,
              'name': waypoints[waypoints.length - 1]['name'] as String,
            }
            : origin;

    final middleWaypoints =
        waypoints.length > 2
            ? [
              for (int i = 1; i < waypoints.length - 1; i++)
                {
                  'lat': waypoints[i]['lat'] as double,
                  'lng': waypoints[i]['lon'] as double,
                  'name': waypoints[i]['name'] as String,
                },
            ]
            : <Map<String, dynamic>>[];

    if (origin == null || destination == null) return;

    // Send route message to iframe
    String tripDates = '';
    try {
      if (trip['startDate'] is Timestamp) {
        tripDates = DateFormat(
          'MMM d',
        ).format((trip['startDate'] as Timestamp).toDate());
      }
    } catch (_) {}

    final payload = {
      'type': 'route',
      'origin': origin,
      'destination': destination,
      'waypoints': middleWaypoints,
      'tripInfo': {
        'name': trip['title'] ?? 'Trip',
        'dates': tripDates,
        'distance': trip['distance'] is num ? trip['distance'] : null,
        'stops': waypoints.length,
      },
    };

    _mapIFrame!.contentWindow!.postMessage(payload, _mapPostTargetOrigin());

    final tripKey = '${trip['id'] ?? trip['title'] ?? ''}|${waypoints.length}';
    if (animateCamera && _lastAnimatedTripKey != tripKey) {
      _runTripIntroAnimation(tripKey, waypoints);
    }
  }

  String _focusedStopKey(Map<String, dynamic> stop) {
    final lat = (stop['lat'] as num?)?.toDouble() ?? 0.0;
    final lon = (stop['lon'] as num?)?.toDouble() ?? 0.0;
    final name = (stop['name'] ?? stop['title'] ?? '').toString().trim();
    return '${lat.toStringAsFixed(6)}|${lon.toStringAsFixed(6)}|${name.toLowerCase()}';
  }

  Map<String, dynamic>? _poiInsightForStop(Map<String, dynamic> stop) {
    return _poiInsightCache[_focusedStopKey(stop)];
  }

  bool _isPoiInsightLoading(Map<String, dynamic> stop) {
    return _poiInsightLoading.contains(_focusedStopKey(stop));
  }

  bool _looksRegionLabel(String value) {
    final lower = value.trim().toLowerCase();
    if (lower.isEmpty) return false;
    const exact = {
      'golden horseshoe',
      'greater toronto area',
      'gta',
      'ontario',
      'canada',
      'united states',
      'usa',
      'north america',
    };
    if (exact.contains(lower)) return true;
    return lower.contains(' region') ||
        lower.contains(' county') ||
        lower.contains(' district') ||
        lower.contains(' province') ||
        lower.contains(' state');
  }

  bool _looksPoiLabel(String value) {
    final lower = value.trim().toLowerCase();
    if (lower.isEmpty) return false;
    const poiTokens = [
      'church',
      'cathedral',
      'mosque',
      'temple',
      'museum',
      'gallery',
      'park',
      'hotel',
      'resort',
      'restaurant',
      'cafe',
      'mall',
      'plaza',
      'school',
      'university',
      'college',
      'station',
      'airport',
      'hospital',
      'clinic',
      'arena',
      'stadium',
      'library',
      'theatre',
      'theater',
    ];
    for (final token in poiTokens) {
      if (lower.contains(token)) return true;
    }
    return false;
  }

  String _trimAddressNoise(String raw) {
    final input = raw.trim();
    if (input.isEmpty) return '';
    final parts = input
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    if (parts.isEmpty) return input;

    bool looksLikeAddressDetail(String segment) {
      final s = segment.toLowerCase();
      if (RegExp(r'\d').hasMatch(s)) return true;
      const roadTokens = [
        'road',
        'rd',
        'street',
        'st',
        'avenue',
        'ave',
        'drive',
        'dr',
        'blvd',
        'boulevard',
        'highway',
        'hwy',
        'route',
        'lane',
        'ln',
      ];
      for (final token in roadTokens) {
        if (s.contains(token)) return true;
      }
      return false;
    }

    bool isRegionOrCountry(String segment) {
      final s = segment.toLowerCase();
      const ignored = [
        'canada',
        'united states',
        'usa',
        'golden horseshoe',
        'greater toronto area',
        'gta',
        'ontario',
        'quebec',
        'british columbia',
        'alberta',
        'manitoba',
        'saskatchewan',
        'nova scotia',
        'new brunswick',
        'newfoundland and labrador',
        'pei',
        'prince edward island',
      ];
      if (ignored.contains(s)) return true;
      return s.contains('region') ||
          s.contains('county') ||
          s.contains('district') ||
          s.contains('province') ||
          s.contains('state');
    }

    for (var i = parts.length - 1; i >= 0; i--) {
      final segment = parts[i];
      if (segment.length < 2) continue;
      if (_looksRegionLabel(segment)) continue;
      if (isRegionOrCountry(segment)) continue;
      if (looksLikeAddressDetail(segment)) continue;
      return segment;
    }

    if (parts.first.isNotEmpty && !_looksRegionLabel(parts.first)) {
      return parts.first;
    }
    return _looksRegionLabel(input) ? '' : input;
  }

  String _extractCityFromAddress(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return '';
    final parts = value
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    if (parts.isEmpty) return '';

    bool looksStreet(String segment) {
      final s = segment.toLowerCase();
      if (RegExp(r'\d').hasMatch(s)) return true;
      return s.contains(' street') ||
          s.endsWith(' st') ||
          s.contains(' road') ||
          s.endsWith(' rd') ||
          s.contains(' avenue') ||
          s.endsWith(' ave') ||
          s.contains(' boulevard') ||
          s.endsWith(' blvd') ||
          s.contains(' drive') ||
          s.endsWith(' dr') ||
          s.contains(' highway') ||
          s.endsWith(' hwy');
    }

    for (final segment in parts) {
      if (segment.length < 2) continue;
      if (_looksRegionLabel(segment)) continue;
      if (looksStreet(segment)) continue;
      final cleaned = _trimAddressNoise(segment);
      if (cleaned.isNotEmpty &&
          !_looksRegionLabel(cleaned) &&
          !_looksPoiLabel(cleaned)) {
        return cleaned;
      }
    }
    return '';
  }

  String _cityFromStopFields(Map<String, dynamic> stop) {
    for (final key in const [
      'city',
      'locality',
      'town',
      'municipality',
      'village',
      'hamlet',
    ]) {
      final raw = (stop[key] ?? '').toString().trim();
      if (raw.isNotEmpty && !_looksRegionLabel(raw) && !_looksPoiLabel(raw)) {
        final cleaned = _trimAddressNoise(raw);
        if (cleaned.isNotEmpty &&
            !_looksRegionLabel(cleaned) &&
            !_looksPoiLabel(cleaned)) {
          return cleaned;
        }
      }
    }

    for (final key in const [
      'formattedAddress',
      'formatted_address',
      'display_name',
      'address',
    ]) {
      final fromAddress = _extractCityFromAddress((stop[key] ?? '').toString());
      if (fromAddress.isNotEmpty) return fromAddress;
    }

    final itinerary = stop['itinerary'];
    if (itinerary is List) {
      for (final day in itinerary) {
        if (day is! Map) continue;
        final dayCity = _extractCityFromAddress(
          (day['location'] ?? day['address'] ?? '').toString(),
        );
        if (dayCity.isNotEmpty) return dayCity;

        final activities = day['activities'];
        if (activities is! List) continue;
        for (final activity in activities) {
          if (activity is! Map) continue;
          final activityCity = _extractCityFromAddress(
            (activity['address'] ??
                    activity['location'] ??
                    activity['formattedAddress'] ??
                    '')
                .toString(),
          );
          if (activityCity.isNotEmpty) return activityCity;
        }
      }
    }

    return '';
  }

  Future<String> _focusedStopCitySeed(
    Map<String, dynamic> stop,
    int stopNumber,
  ) async {
    final key = _focusedStopKey(stop);
    final cached = (_stopCityCache[key] ?? '').trim();
    if (cached.isNotEmpty) return cached;

    final fromFields = _cityFromStopFields(stop);
    if (fromFields.isNotEmpty) {
      _stopCityCache[key] = fromFields;
      return fromFields;
    }

    final lat = (stop['lat'] as num?)?.toDouble();
    final lon = (stop['lon'] as num?)?.toDouble();
    if (lat != null && lon != null && lat.isFinite && lon.isFinite) {
      try {
        final reverseAddress = await reverseNominatim(
          lat,
          lon,
        ).timeout(const Duration(seconds: 6));
        final fromReverse = _extractCityFromAddress(reverseAddress ?? '');
        if (fromReverse.isNotEmpty) {
          _stopCityCache[key] = fromReverse;
          return fromReverse;
        }
      } catch (_) {
        // Ignore reverse-geocode failures and use local fallback.
      }

      try {
        final locality = await reverseLocality(
          lat,
          lon,
        ).timeout(const Duration(seconds: 5));
        final cleaned = _trimAddressNoise(locality ?? '');
        if (cleaned.isNotEmpty &&
            !_looksRegionLabel(cleaned) &&
            !_looksPoiLabel(cleaned)) {
          _stopCityCache[key] = cleaned;
          return cleaned;
        }
      } catch (_) {
        // Ignore reverse-locality failures and use local fallback.
      }
    }

    final fallbackLabel = _focusedStopTownSeed(stop, stopNumber);
    if (!_looksRegionLabel(fallbackLabel) && !_looksPoiLabel(fallbackLabel)) {
      _stopCityCache[key] = fallbackLabel;
      return fallbackLabel;
    }

    const generic = 'Nearby City';
    _stopCityCache[key] = generic;
    return generic;
  }

  String _focusedStopTownSeed(Map<String, dynamic> stop, int stopNumber) {
    final explicit = (stop['name'] ?? stop['title'] ?? '').toString().trim();
    final cleaned = _trimAddressNoise(explicit);
    if (cleaned.isNotEmpty && !_looksPoiLabel(cleaned)) return cleaned;
    return 'Stop $stopNumber';
  }

  String _normalizeTransportModeForInsights(String raw) {
    var mode = raw.trim().toLowerCase();
    if (mode == 'car' || mode == 'driving') mode = 'car';
    if (mode == 'plane' || mode == 'flying' || mode == 'flight') {
      mode = 'plane';
    }
    if (mode == 'train' ||
        mode == 'rail' ||
        mode == 'public_transit' ||
        mode == 'public transit' ||
        mode == 'transit') {
      mode = 'train';
    }
    if (mode == 'walk' || mode == 'walking') mode = 'walk';
    if (mode == 'bike' ||
        mode == 'biking' ||
        mode == 'bicycling' ||
        mode == 'cycling' ||
        mode == 'bikepacking') {
      mode = 'bike';
    }
    if (mode == 'hiking' || mode == 'backpacking') mode = 'hiking';
    if (mode == 'portaging' ||
        mode == 'portage' ||
        mode == 'canoe' ||
        mode == 'canoeing') {
      mode = 'portaging';
    }
    return mode;
  }

  bool _isBackcountryMode(String mode) {
    final normalized = _normalizeTransportModeForInsights(mode);
    return normalized == 'hiking' || normalized == 'portaging';
  }

  bool _selectedTripUsesBackcountryMode() {
    final trip = _selectedTrip;
    if (trip == null) return false;

    final titleSignals = [
      (trip['title'] ?? '').toString(),
      (trip['name'] ?? '').toString(),
      (trip['description'] ?? '').toString(),
    ].join(' ');
    if (_isBackcountryToken(titleSignals)) return true;

    final waypoints = trip['waypoints'];
    if (waypoints is List) {
      for (final rawStop in waypoints) {
        if (rawStop is! Map) continue;
        final stop = Map<String, dynamic>.from(rawStop.cast<String, dynamic>());
        final stopSignals = [
          (stop['name'] ?? '').toString(),
          (stop['title'] ?? '').toString(),
          (stop['display_name'] ?? '').toString(),
          (stop['formattedAddress'] ?? '').toString(),
          (stop['formatted_address'] ?? '').toString(),
          (stop['address'] ?? '').toString(),
        ].join(' ');
        if (_isBackcountryToken(stopSignals)) return true;
      }
    }

    final baseMode = _normalizeTransportModeForInsights(
      (trip['transportMode'] ?? '').toString(),
    );
    if (_isBackcountryMode(baseMode)) return true;

    final segmentModes = trip['segmentTransportModes'];
    if (segmentModes is List) {
      for (final raw in segmentModes) {
        if (_isBackcountryMode(raw.toString())) return true;
      }
    }
    return false;
  }

  bool _isBackcountryToken(String raw) {
    final text = raw.trim().toLowerCase();
    if (text.isEmpty) return false;
    const tokens = <String>[
      'portage',
      'canoe',
      'paddle',
      'backcountry',
      'campsite',
      'camp site',
      'campground',
      'trail',
      'trailhead',
      'hiking',
      'trek',
      'put in',
      'take out',
      'lake',
      'river',
      'island',
      'bay',
      'unorganized',
    ];
    for (final token in tokens) {
      if (text.contains(token)) return true;
    }
    return false;
  }

  bool _isBackcountryStop(Map<String, dynamic> stop) {
    final name = (stop['name'] ?? stop['title'] ?? '').toString();
    if (_isBackcountryToken(name)) return true;

    final displayName =
        (stop['display_name'] ??
                stop['formattedAddress'] ??
                stop['formatted_address'] ??
                stop['address'] ??
                '')
            .toString();
    if (_isBackcountryToken(displayName)) return true;

    final categories = stop['activityCategories'] ?? stop['categories'];
    if (categories is List) {
      for (final raw in categories) {
        if (_isBackcountryToken(raw.toString())) return true;
      }
    } else if (categories is String && _isBackcountryToken(categories)) {
      return true;
    }

    return _selectedTripUsesBackcountryMode();
  }

  bool _shouldShowAiForStop(Map<String, dynamic> stop) {
    if (_hasPremiumAccess != true) return false;
    return !_isBackcountryStop(stop);
  }

  String _formatDateForAi(dynamic raw, {required String fallback}) {
    if (raw is Timestamp) return DateFormat('yyyy-MM-dd').format(raw.toDate());
    final s = raw?.toString().trim() ?? '';
    if (s.isEmpty) return fallback;
    try {
      return DateFormat('yyyy-MM-dd').format(DateTime.parse(s));
    } catch (_) {
      return s.length >= 10 ? s.substring(0, 10) : fallback;
    }
  }

  List<String> _topCategoriesFromSuggestions(
    List<Map<String, dynamic>> suggestions, {
    int max = 6,
  }) {
    final counts = <String, int>{};
    for (final suggestion in suggestions) {
      final category = (suggestion['category'] ?? '').toString().trim();
      if (category.isEmpty) continue;
      counts[category] = (counts[category] ?? 0) + 1;
    }
    final sorted =
        counts.entries.toList()..sort((a, b) {
          final byCount = b.value.compareTo(a.value);
          if (byCount != 0) return byCount;
          return a.key.compareTo(b.key);
        });
    return sorted.take(max).map((entry) => entry.key).toList(growable: false);
  }

  String _poiSummaryFromSuggestions(
    String displayName,
    List<String> categories,
    List<Map<String, dynamic>> suggestions,
  ) {
    final placeNames = <String>[];
    for (final suggestion in suggestions) {
      final raw = (suggestion['name'] ?? '').toString().trim();
      if (raw.isEmpty) continue;
      var clean = raw;
      if (clean.toLowerCase().startsWith(displayName.toLowerCase())) {
        clean = clean.substring(displayName.length).trimLeft();
      }
      clean = clean.replaceFirst(RegExp(r'^[\-\u2013\u2014:]+'), '').trim();
      if (clean.isEmpty) continue;
      if (!placeNames.contains(clean)) placeNames.add(clean);
      if (placeNames.length >= 3) break;
    }
    final categoryText =
        categories.isEmpty
            ? 'sightseeing and local experiences'
            : categories.take(3).join(', ').toLowerCase();
    final highlights =
        placeNames.isEmpty
            ? 'a mix of curated local spots'
            : placeNames.join(', ');
    return '$displayName is a strong base for $categoryText, with highlights like $highlights.';
  }

  List<Map<String, dynamic>> _activityRecommendationsFromSuggestions(
    List<Map<String, dynamic>> suggestions, {
    int max = 5,
  }) {
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};

    for (final suggestion in suggestions) {
      final name =
          (suggestion['name'] ?? suggestion['title'] ?? '').toString().trim();
      if (name.isEmpty) continue;
      final key = name.toLowerCase();
      if (!seen.add(key)) continue;

      final category = (suggestion['category'] ?? '').toString().trim();
      final rating = _toDouble(suggestion['rating']);
      final estimatedPrice = _toDouble(
        suggestion['estimatedPrice'] ??
            suggestion['price_estimate'] ??
            suggestion['price'],
      );

      out.add({
        'name': name,
        if (category.isNotEmpty) 'category': category,
        if (rating.isFinite) 'rating': rating,
        if (estimatedPrice.isFinite && estimatedPrice >= 0)
          'estimatedPrice': estimatedPrice.roundToDouble(),
      });

      if (out.length >= max) break;
    }

    return out;
  }

  List<Map<String, dynamic>> _fallbackActivityRecommendations(
    String title,
    List<String> categories, {
    int max = 5,
  }) {
    final seeds =
        categories.isNotEmpty
            ? categories
            : _fallbackActivitiesForTown(title).take(max).toList();
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};

    for (final category in seeds) {
      final cleanCategory = category.trim();
      if (cleanCategory.isEmpty) continue;
      final normalizedCategory = cleanCategory.toLowerCase();
      if (!seen.add(normalizedCategory)) continue;

      out.add({
        'name': '$cleanCategory around $title',
        'category': cleanCategory,
      });
      if (out.length >= max) break;
    }

    if (out.isEmpty) {
      out.add({
        'name': 'Explore the top local highlights around $title',
        'category': 'Sightseeing',
      });
    }
    return out;
  }

  Future<void> _ensurePoiInsightForStop(
    Map<String, dynamic> stop,
    int stopIndex,
  ) async {
    final key = _focusedStopKey(stop);
    final existing = _poiInsightCache[key];
    if (existing != null) {
      final cachedLabel =
          (existing['cityName'] ?? existing['displayName'] ?? '')
              .toString()
              .trim();
      if (cachedLabel.isNotEmpty && !_looksRegionLabel(cachedLabel)) {
        return;
      }
      _poiInsightCache.remove(key);
    }
    if (_poiInsightLoading.contains(key)) {
      return;
    }
    final lat = (stop['lat'] as num?)?.toDouble();
    final lon = (stop['lon'] as num?)?.toDouble();
    if (lat == null || lon == null || !lat.isFinite || !lon.isFinite) return;

    if (mounted) {
      setState(() => _poiInsightLoading.add(key));
    } else {
      _poiInsightLoading.add(key);
    }

    final quickSeed = _focusedStopTownSeed(stop, stopIndex + 1);
    Map<String, dynamic> localFallbackInsight(
      String seed, {
      bool includePlanningDetails = true,
    }) {
      final categories = _fallbackActivitiesForTown(seed);
      final summary =
          includePlanningDetails
              ? '$seed is a strong stop for ${categories.take(3).join(', ').toLowerCase()}.'
              : seed;
      return {
        'displayName': seed,
        'cityName': seed,
        'summary': summary,
        'categories': includePlanningDetails ? categories : const <String>[],
        'activityRecommendations':
            includePlanningDetails
                ? _fallbackActivityRecommendations(seed, categories)
                : const <Map<String, dynamic>>[],
      };
    }

    // Render immediately with a local fallback so the card feels responsive
    // while the callable request is still in flight.
    if (_poiInsightCache[key] == null) {
      final instantInsight = localFallbackInsight(quickSeed);
      if (mounted) {
        setState(() => _poiInsightCache[key] = instantInsight);
      } else {
        _poiInsightCache[key] = instantInsight;
      }
    }
    final citySeed = await _focusedStopCitySeed(stop, stopIndex + 1);
    final premiumEnabled = await _premiumAccessEnabled();
    final allowAiForStop = premiumEnabled && !_isBackcountryStop(stop);

    if (!allowAiForStop) {
      final displaySeed = _focusedStopTownSeed(stop, stopIndex + 1);
      if (!mounted) return;
      setState(() {
        _poiInsightCache[key] = localFallbackInsight(
          displaySeed,
          includePlanningDetails: false,
        );
        _poiInsightLoading.remove(key);
      });
      return;
    }

    try {
      final now = DateTime.now();
      final fallbackStart = DateFormat('yyyy-MM-dd').format(now);
      final fallbackEnd = DateFormat(
        'yyyy-MM-dd',
      ).format(now.add(const Duration(days: 2)));
      final selected = _selectedTrip;
      final startDate = _formatDateForAi(
        selected?['startDate'],
        fallback: fallbackStart,
      );
      final endDate = _formatDateForAi(
        selected?['endDate'],
        fallback: fallbackEnd,
      );
      final suggestions = await AiSuggestionsService()
          .suggestItinerary(
            destinationName: citySeed,
            lat: lat,
            lon: lon,
            startDate: startDate,
            endDate: endDate,
            preferences: const {
              'activityType': 'sightseeing',
              'maxTravelMinutes': 30,
              'scope': 'nearby',
            },
          )
          .timeout(const Duration(seconds: 16));
      final categories = _topCategoriesFromSuggestions(suggestions);
      final displayName = _trimAddressNoise(citySeed);
      final summary = _poiSummaryFromSuggestions(
        displayName.isEmpty ? citySeed : displayName,
        categories,
        suggestions,
      );
      final activityRecommendations = _activityRecommendationsFromSuggestions(
        suggestions,
      );

      if (!mounted) return;
      setState(() {
        _poiInsightCache[key] = {
          'displayName': displayName.isEmpty ? citySeed : displayName,
          'cityName': displayName.isEmpty ? citySeed : displayName,
          'summary': summary,
          'categories': categories,
          'activityRecommendations':
              activityRecommendations.isNotEmpty
                  ? activityRecommendations
                  : _fallbackActivityRecommendations(
                    displayName.isEmpty ? citySeed : displayName,
                    categories,
                  ),
        };
      });
    } on PremiumRequiredException {
      if (!mounted) return;
      setState(() => _poiInsightCache[key] = localFallbackInsight(citySeed));
    } catch (_) {
      if (!mounted) return;
      setState(() => _poiInsightCache[key] = localFallbackInsight(citySeed));
    } finally {
      if (mounted) {
        setState(() => _poiInsightLoading.remove(key));
      } else {
        _poiInsightLoading.remove(key);
      }
    }
  }

  String _focusedStopTitle(Map<String, dynamic> stop, int stopNumber) {
    final explicit = (stop['name'] ?? stop['title'] ?? '').toString().trim();
    final cleanedExplicit = _trimAddressNoise(explicit);
    if (_isBackcountryStop(stop) && cleanedExplicit.isNotEmpty) {
      return cleanedExplicit;
    }
    if (cleanedExplicit.isNotEmpty &&
        !_looksRegionLabel(cleanedExplicit) &&
        !_looksPoiLabel(cleanedExplicit)) {
      return cleanedExplicit;
    }

    final aiCity =
        (_poiInsightForStop(stop)?['cityName'] ?? '').toString().trim();
    if (aiCity.isNotEmpty) return aiCity;
    final aiName =
        (_poiInsightForStop(stop)?['displayName'] ?? '').toString().trim();
    if (aiName.isNotEmpty) return aiName;
    final fromFields = _cityFromStopFields(stop);
    if (fromFields.isNotEmpty) return fromFields;
    if (cleanedExplicit.isNotEmpty) return cleanedExplicit;
    return 'Stop $stopNumber';
  }

  String _focusedStopImageUrl(Map<String, dynamic> stop, String title) {
    final gallery = _focusedStopImageUrls(stop, title);
    if (gallery.isNotEmpty) return gallery.first;
    return _fallbackTownImageUrl(title);
  }

  bool _isRemoteImageUrl(String value) {
    return value.startsWith('https://') || value.startsWith('http://');
  }

  bool _isNatureAreaLabel(String value) {
    final lower = value.toLowerCase();
    const tokens = [
      'park',
      'forest',
      'trail',
      'falls',
      'waterfall',
      'lake',
      'river',
      'beach',
      'mountain',
      'valley',
      'reserve',
      'national',
      'conservation',
    ];
    for (final token in tokens) {
      if (lower.contains(token)) return true;
    }
    return false;
  }

  String _normalizePhotoTag(String value) {
    final cleaned =
        value
            .toLowerCase()
            .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
    if (cleaned.isEmpty) return 'travel';
    final parts = cleaned
        .split(' ')
        .where((part) => part.length >= 3)
        .take(2)
        .toList(growable: false);
    if (parts.isEmpty) return 'travel';
    return parts.join(',');
  }

  String _realisticFallbackPhotoUrl(
    String seed, {
    required int index,
    bool? natureBias,
  }) {
    final looksNature = natureBias ?? _isNatureAreaLabel(seed);
    final baseTags =
        looksNature ? 'nature,landscape,travel' : 'city,travel,landmark';
    final locationTag = _normalizePhotoTag(seed);
    final lock =
        seed.codeUnits.fold<int>(0, (acc, c) => (acc + c) % 100000) +
        (index * 37);
    return 'https://loremflickr.com/900/520/$baseTags,$locationTag?lock=${lock.abs()}';
  }

  void _addImageCandidate(
    List<String> out,
    Set<String> seen,
    dynamic rawValue,
  ) {
    if (rawValue == null) return;
    if (rawValue is String) {
      final value = rawValue.trim();
      if (!_isRemoteImageUrl(value)) return;
      final key = value.toLowerCase();
      if (seen.add(key)) out.add(value);
      return;
    }
    if (rawValue is List) {
      for (final entry in rawValue) {
        _addImageCandidate(out, seen, entry);
      }
      return;
    }
    if (rawValue is Map) {
      for (final key in const ['url', 'imageUrl', 'photoUrl', 'src']) {
        _addImageCandidate(out, seen, rawValue[key]);
      }
    }
  }

  List<String> _streetViewGallery(Map<String, dynamic> stop) {
    if (!_enableStreetViewGallery) return const [];
    final lat = (stop['lat'] as num?)?.toDouble();
    final lon = (stop['lon'] as num?)?.toDouble();
    final mapsKey = _resolvedMapsKey();
    if (mapsKey.isEmpty || lat == null || lon == null) return const [];

    final location = Uri.encodeQueryComponent(
      '${lat.toStringAsFixed(6)},${lon.toStringAsFixed(6)}',
    );
    final escapedKey = Uri.encodeQueryComponent(mapsKey);
    const headings = [0, 70, 140, 210, 280];
    return headings
        .map(
          (heading) =>
              'https://maps.googleapis.com/maps/api/streetview?size=900x520&location=$location&heading=$heading&fov=92&pitch=4&key=$escapedKey',
        )
        .toList(growable: false);
  }

  List<String> _focusedStopImageUrls(Map<String, dynamic> stop, String title) {
    final out = <String>[];
    final seen = <String>{};

    for (final key in const [
      'imageUrl',
      'photoUrl',
      'coverImage',
      'thumbnailUrl',
      'heroImage',
    ]) {
      _addImageCandidate(out, seen, stop[key]);
    }

    for (final key in const [
      'photos',
      'images',
      'photoUrls',
      'imageUrls',
      'gallery',
      'galleryImages',
      'pictures',
    ]) {
      _addImageCandidate(out, seen, stop[key]);
    }

    final itinerary = stop['itinerary'];
    if (itinerary is List) {
      for (final day in itinerary) {
        if (day is! Map) continue;
        _addImageCandidate(out, seen, day['imageUrl']);
        _addImageCandidate(out, seen, day['photoUrl']);
        final activities = day['activities'];
        if (activities is! List) continue;
        for (final activity in activities) {
          if (activity is! Map) continue;
          _addImageCandidate(out, seen, activity['imageUrl']);
          _addImageCandidate(out, seen, activity['photoUrl']);
          _addImageCandidate(out, seen, activity['images']);
        }
      }
    }

    for (final url in _streetViewGallery(stop)) {
      _addImageCandidate(out, seen, url);
    }

    final fallbackSeedBase = title.isEmpty ? 'travel-town' : title;
    final fallbackSeeds = <String>[
      fallbackSeedBase,
      '$fallbackSeedBase-overlook',
      '$fallbackSeedBase-travel',
      '$fallbackSeedBase-city',
      '$fallbackSeedBase-night',
      '$fallbackSeedBase-food',
      '$fallbackSeedBase-viewpoint',
    ];
    for (final seed in fallbackSeeds) {
      if (out.length >= 7) break;
      _addImageCandidate(
        out,
        seen,
        _realisticFallbackPhotoUrl(seed, index: out.length),
      );
    }

    return out.take(7).toList(growable: false);
  }

  String _fallbackTownImageUrl(String title) {
    final querySeed = title.isEmpty ? 'travel-city' : title;
    final query = Uri.encodeQueryComponent(
      '${_normalizePhotoTag(querySeed).replaceAll(',', ' ')}, travel',
    );
    return 'https://source.unsplash.com/900x520/?$query';
  }

  List<String> _fallbackActivitiesForTown(String title) {
    final lower = title.toLowerCase();
    final out = <String>{};

    bool hasAny(List<String> keys) {
      for (final key in keys) {
        if (lower.contains(key)) return true;
      }
      return false;
    }

    void addWhen(List<String> keys, List<String> activities) {
      if (hasAny(keys)) out.addAll(activities);
    }

    addWhen(
      const ['banff'],
      const ['Hiking', 'Camping', 'Skiing/Snowboarding'],
    );
    addWhen(
      const ['niagara'],
      const ['Waterfall', 'Casino', 'Vineyards', 'Boat Tours'],
    );
    addWhen(
      const ['mountain', 'alps', 'rockies', 'peak', 'ridge'],
      const ['Hiking', 'Scenic Views', 'Camping'],
    );
    addWhen(
      const ['beach', 'coast', 'island', 'bay'],
      const ['Beach', 'Boating', 'Sunset Views'],
    );
    addWhen(
      const ['falls', 'waterfall', 'lake', 'river'],
      const ['Waterfront Walks', 'Photography', 'Boat Tours'],
    );
    addWhen(
      const ['city', 'downtown', 'old town', 'village', 'metro'],
      const ['Walking Tours', 'Food', 'Museums'],
    );
    addWhen(
      const ['wine', 'vineyard', 'napa'],
      const ['Vineyards', 'Wine Tasting', 'Local Food'],
    );
    addWhen(const ['vegas', 'casino'], const ['Casino', 'Nightlife', 'Shows']);
    addWhen(
      const ['park', 'forest', 'trail'],
      const ['Hiking', 'Wildlife', 'Camping'],
    );
    addWhen(
      const ['ski', 'snow'],
      const ['Skiing/Snowboarding', 'Lodges', 'Mountain Views'],
    );

    if (out.isEmpty) {
      out.addAll(const ['Sightseeing', 'Local Food', 'Photography']);
    }
    return out.take(6).toList(growable: false);
  }

  List<String> _focusedStopActivities(Map<String, dynamic> stop) {
    final out = <String>[];
    final seen = <String>{};

    void addCategory(String value) {
      final clean = value.trim();
      if (clean.isEmpty) return;
      final key = clean.toLowerCase();
      if (!seen.add(key)) return;
      out.add(clean);
    }

    final aiCategories = _poiInsightForStop(stop)?['categories'];
    if (aiCategories is List) {
      for (final category in aiCategories) {
        addCategory(category.toString());
      }
      if (out.isNotEmpty) {
        return out.take(6).toList(growable: false);
      }
    }

    final rawCategories = stop['activityCategories'] ?? stop['categories'];
    if (rawCategories is List) {
      for (final entry in rawCategories) {
        addCategory(entry.toString());
      }
    } else if (rawCategories is String) {
      for (final part in rawCategories.split(',')) {
        addCategory(part);
      }
    }

    final itinerary = stop['itinerary'];
    if (itinerary is List) {
      final counts = <String, int>{};
      for (final day in itinerary) {
        if (day is! Map) continue;
        final activities = day['activities'];
        if (activities is! List) continue;
        for (final activity in activities) {
          if (activity is! Map) continue;
          final category = (activity['category'] ?? '').toString().trim();
          if (category.isEmpty) continue;
          counts[category] = (counts[category] ?? 0) + 1;
        }
      }
      final sorted =
          counts.entries.toList()..sort((a, b) {
            final byCount = b.value.compareTo(a.value);
            if (byCount != 0) return byCount;
            return a.key.compareTo(b.key);
          });
      for (final category in sorted.map((entry) => entry.key)) {
        addCategory(category);
      }
    }

    if (out.isEmpty) {
      final title = _focusedStopTitle(stop, 1);
      for (final category in _fallbackActivitiesForTown(title)) {
        addCategory(category);
      }
    }

    return out.take(6).toList(growable: false);
  }

  List<Map<String, dynamic>> _focusedStopActivityRecommendations(
    Map<String, dynamic> stop,
    String title,
    List<String> activities,
  ) {
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};

    void addRecommendation({
      required String name,
      String? category,
      dynamic rating,
      dynamic estimatedPrice,
    }) {
      final cleanName = name.trim();
      if (cleanName.isEmpty) return;
      final key = cleanName.toLowerCase();
      if (!seen.add(key)) return;

      final parsedRating = _toDouble(rating);
      final parsedPrice = _toDouble(estimatedPrice);

      out.add({
        'name': cleanName,
        if (category != null && category.trim().isNotEmpty)
          'category': category.trim(),
        if (parsedRating.isFinite) 'rating': parsedRating,
        if (parsedPrice.isFinite && parsedPrice >= 0)
          'estimatedPrice': parsedPrice.roundToDouble(),
      });
    }

    final aiRecommendations =
        _poiInsightForStop(stop)?['activityRecommendations'];
    if (aiRecommendations is List) {
      for (final recommendation in aiRecommendations) {
        if (recommendation is! Map) continue;
        addRecommendation(
          name:
              (recommendation['name'] ?? recommendation['title'] ?? '')
                  .toString(),
          category: (recommendation['category'] ?? '').toString(),
          rating: recommendation['rating'],
          estimatedPrice:
              recommendation['estimatedPrice'] ??
              recommendation['price_estimate'] ??
              recommendation['price'],
        );
      }
      if (out.isNotEmpty) return out.take(5).toList(growable: false);
    }

    final itinerary = stop['itinerary'];
    if (itinerary is List) {
      for (final day in itinerary) {
        if (day is! Map) continue;
        final activitiesRaw = day['activities'];
        if (activitiesRaw is! List) continue;
        for (final activity in activitiesRaw) {
          if (activity is! Map) continue;
          addRecommendation(
            name: (activity['name'] ?? activity['title'] ?? '').toString(),
            category: (activity['category'] ?? '').toString(),
            rating: activity['rating'],
            estimatedPrice:
                activity['estimatedPrice'] ??
                activity['price_estimate'] ??
                activity['price'],
          );
        }
      }
      if (out.isNotEmpty) return out.take(5).toList(growable: false);
    }

    return _fallbackActivityRecommendations(
      title,
      activities.isNotEmpty ? activities : _fallbackActivitiesForTown(title),
    );
  }

  String _activityRecommendationMeta(Map<String, dynamic> recommendation) {
    final parts = <String>[];
    final category = (recommendation['category'] ?? '').toString().trim();
    if (category.isNotEmpty) parts.add(category);

    final rating = _toDouble(recommendation['rating']);
    if (rating.isFinite) parts.add('⭐ ${rating.toStringAsFixed(1)}');

    final estimatedPrice = _toDouble(
      recommendation['estimatedPrice'] ??
          recommendation['price_estimate'] ??
          recommendation['price'],
    );
    if (estimatedPrice.isFinite && estimatedPrice > 0) {
      parts.add('\$${estimatedPrice.round()}');
    }

    return parts.join(' • ');
  }

  String _focusedStopAiSummary(
    Map<String, dynamic> stop,
    String title,
    List<String> activities,
  ) {
    final aiSummary =
        (_poiInsightForStop(stop)?['summary'] ?? '').toString().trim();
    if (aiSummary.isNotEmpty) return aiSummary;

    final itinerary = stop['itinerary'];
    var dayCount = 0;
    var activityCount = 0;
    if (itinerary is List) {
      for (final day in itinerary) {
        if (day is! Map) continue;
        dayCount++;
        final activitiesForDay = day['activities'];
        if (activitiesForDay is List) activityCount += activitiesForDay.length;
      }
    }

    final focus =
        activities.isEmpty
            ? 'sightseeing and local exploration'
            : activities.take(3).join(', ').toLowerCase();
    if (activityCount > 0) {
      final dayText =
          dayCount > 0
              ? '$dayCount day${dayCount == 1 ? '' : 's'}'
              : 'this stop';
      return '$title has $activityCount planned activit${activityCount == 1 ? 'y' : 'ies'} across $dayText, centered on $focus.';
    }
    return '$title is a strong stop for $focus. Keep nearby points grouped together here for a smoother day plan.';
  }

  String _activityEmoji(String label) {
    final lower = label.toLowerCase();
    if (lower.contains('hiking') || lower.contains('trail')) return '🥾';
    if (lower.contains('camp')) return '⛺';
    if (lower.contains('ski') || lower.contains('snow')) return '🎿';
    if (lower.contains('waterfall')) return '💧';
    if (lower.contains('boat')) return '🚤';
    if (lower.contains('vineyard') || lower.contains('wine')) return '🍷';
    if (lower.contains('casino')) return '🎰';
    if (lower.contains('museum')) return '🏛️';
    if (lower.contains('food') || lower.contains('restaurant')) return '🍽️';
    if (lower.contains('photo')) return '📸';
    if (lower.contains('walk')) return '🚶';
    return '📌';
  }

  Widget _buildFocusedStopInsightCard({
    required Map<String, dynamic> stop,
    required int stopNumber,
    required int totalStops,
    required double maxWidth,
    required double maxHeight,
    double minHeight = 360,
  }) {
    final title = _focusedStopTitle(stop, stopNumber);
    final fallbackImageUrl = _fallbackTownImageUrl(title);
    final showAiPanels = _shouldShowAiForStop(stop);
    final imageUrls = _focusedStopImageUrls(stop, title);
    final activities =
        showAiPanels ? _focusedStopActivities(stop) : const <String>[];
    final summary =
        showAiPanels ? _focusedStopAiSummary(stop, title, activities) : '';
    final recommendations =
        showAiPanels
            ? _focusedStopActivityRecommendations(stop, title, activities)
            : const <Map<String, dynamic>>[];
    final isLoading = showAiPanels && _isPoiInsightLoading(stop);
    final isBackcountry = _isBackcountryStop(stop);
    final gallery =
        imageUrls.isNotEmpty
            ? imageUrls
            : <String>[_focusedStopImageUrl(stop, title)];
    final normalizedMinHeight = minHeight.clamp(220.0, 780.0).toDouble();
    final cardHeight = maxHeight.clamp(normalizedMinHeight, 820.0).toDouble();

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: cardHeight),
      child: SizedBox(
        height: cardHeight,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.9),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: Colors.white.withOpacity(0.6),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.22),
                blurRadius: 22,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  if (gallery.length <= 1) {
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: SizedBox(
                        height: 188,
                        width: double.infinity,
                        child: Image.network(
                          gallery.first,
                          fit: BoxFit.cover,
                          errorBuilder:
                              (_, __, ___) => Image.network(
                                fallbackImageUrl,
                                fit: BoxFit.cover,
                                errorBuilder:
                                    (_, __, ___) => Container(
                                      color: const Color(0x11000000),
                                      alignment: Alignment.center,
                                      child: const Icon(
                                        Icons.landscape,
                                        size: 28,
                                        color: Color(0x99000000),
                                      ),
                                    ),
                              ),
                        ),
                      ),
                    );
                  }

                  final previewCount = math.min(gallery.length, 9);
                  final columnCount = gallery.length <= 4 ? 2 : 3;
                  final gridHeight =
                      previewCount <= columnCount
                          ? 108.0
                          : previewCount <= columnCount * 2
                          ? 180.0
                          : 224.0;

                  return ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      height: gridHeight,
                      width: double.infinity,
                      child: GridView.builder(
                        padding: EdgeInsets.zero,
                        physics:
                            previewCount > columnCount * 2
                                ? const BouncingScrollPhysics()
                                : const NeverScrollableScrollPhysics(),
                        itemCount: previewCount,
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columnCount,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                          childAspectRatio: 1.45,
                        ),
                        itemBuilder: (context, index) {
                          final imageUrl = gallery[index];
                          final remaining = gallery.length - previewCount;
                          final showRemaining =
                              remaining > 0 && index == previewCount - 1;

                          return Stack(
                            fit: StackFit.expand,
                            children: [
                              Image.network(
                                imageUrl,
                                fit: BoxFit.cover,
                                errorBuilder:
                                    (_, __, ___) => Image.network(
                                      fallbackImageUrl,
                                      fit: BoxFit.cover,
                                      errorBuilder:
                                          (_, __, ___) => Container(
                                            color: const Color(0x11000000),
                                            alignment: Alignment.center,
                                            child: const Icon(
                                              Icons.landscape,
                                              size: 24,
                                              color: Color(0x99000000),
                                            ),
                                          ),
                                    ),
                              ),
                              if (index == 0)
                                Positioned(
                                  left: 8,
                                  bottom: 8,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withOpacity(0.55),
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Text(
                                      '${gallery.length} photos',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ),
                              if (showRemaining)
                                Container(
                                  alignment: Alignment.center,
                                  color: Colors.black.withOpacity(0.45),
                                  child: Text(
                                    '+$remaining',
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w800,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  const Icon(
                    Icons.location_city,
                    size: 16,
                    color: Colors.black87,
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    'Location Insight',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  Text(
                    'Stop $stopNumber/$totalStops',
                    style: const TextStyle(fontSize: 11, color: Colors.black54),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Scrollbar(
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.only(right: 2),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (!showAiPanels) ...[
                          Text(
                            isBackcountry
                                ? 'Backcountry stop preview'
                                : 'Stop preview',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'Showing stop name and related photos only.',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: Colors.black87,
                            ),
                          ),
                          if (_hasPremiumAccess != true) ...[
                            const SizedBox(height: 8),
                            const Text(
                              'Upgrade to Premium to unlock AI summaries.',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: Colors.black54,
                              ),
                            ),
                          ],
                        ] else ...[
                          const Text(
                            'AI Summary',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          if (isLoading) ...[
                            Row(
                              children: const [
                                SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                                SizedBox(width: 6),
                                Text(
                                  'Generating with Gemini...',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.black54,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                          ],
                          Text(
                            summary,
                            style: const TextStyle(
                              fontSize: 12.5,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            'Activities',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: activities
                                .take(8)
                                .map(
                                  (activity) => Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 5,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withOpacity(0.06),
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Text(
                                      '${_activityEmoji(activity)} $activity',
                                      style: const TextStyle(
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                )
                                .toList(growable: false),
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'AI Activity Recommendations',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 6),
                          if (recommendations.isEmpty && isLoading)
                            Row(
                              children: const [
                                SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                                SizedBox(width: 6),
                                Text(
                                  'Generating activity recommendations...',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.black54,
                                  ),
                                ),
                              ],
                            )
                          else
                            Column(
                              children: [
                                for (final recommendation in recommendations
                                    .take(4)) ...[
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 8,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withOpacity(0.045),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const Padding(
                                          padding: EdgeInsets.only(top: 1),
                                          child: Icon(
                                            Icons.auto_awesome,
                                            size: 14,
                                            color: Colors.black87,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                (recommendation['name'] ?? '')
                                                    .toString()
                                                    .trim(),
                                                style: const TextStyle(
                                                  fontSize: 12.5,
                                                  fontWeight: FontWeight.w700,
                                                  color: Colors.black87,
                                                ),
                                              ),
                                              Builder(
                                                builder: (context) {
                                                  final meta =
                                                      _activityRecommendationMeta(
                                                        recommendation,
                                                      );
                                                  if (meta.isEmpty) {
                                                    return const SizedBox.shrink();
                                                  }
                                                  return Padding(
                                                    padding:
                                                        const EdgeInsets.only(
                                                          top: 2,
                                                        ),
                                                    child: Text(
                                                      meta,
                                                      style: const TextStyle(
                                                        fontSize: 11.5,
                                                        color: Colors.black54,
                                                      ),
                                                    ),
                                                  );
                                                },
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 7),
                                ],
                              ],
                            ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMapView() {
    if (!kIsWeb) {
      return Container(
        color: TryprColors.surfaceVariant,
        child: const Center(
          child: Text(
            'Trypr 3D map is available in the browser.',
            style: TextStyle(color: Colors.white70),
          ),
        ),
      );
    }
    if (!_mapFactoryRegistered) {
      return const Center(child: CircularProgressIndicator());
    }
    return HtmlElementView(viewType: _mapViewType);
  }

  // Verified trip previews use a dedicated widget to match My Trips sizing
  // and support cycling through uploaded photos.

  Widget _buildValueCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String description,
    String? tag,
  }) {
    return Container(
      padding: const EdgeInsets.all(TryprSpacing.lg),
      decoration: BoxDecoration(
        color: TryprColors.surface,
        borderRadius: BorderRadius.circular(TryprRadius.lg),
        boxShadow: TryprColors.softShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: TryprColors.primary.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(TryprRadius.md),
                ),
                child: Icon(icon, color: TryprColors.primary, size: 20),
              ),
              const SizedBox(width: TryprSpacing.md),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: TryprColors.textPrimary,
                    fontSize: 16,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: TryprSpacing.md),
          Text(
            description,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: TryprColors.textSecondary,
              height: 1.45,
            ),
          ),
          if (tag != null && tag.trim().isNotEmpty) ...[
            const SizedBox(height: TryprSpacing.sm),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: TryprSpacing.sm,
                vertical: 4,
              ),
              decoration: BoxDecoration(
                color: TryprColors.surfaceVariant,
                borderRadius: BorderRadius.circular(TryprRadius.sm),
              ),
              child: Text(
                tag,
                style: const TextStyle(
                  color: TryprColors.textTertiary,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: TopTaskbar(dockProgress: _dockProgress),
      extendBodyBehindAppBar: true,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isPhone = constraints.maxWidth < 760;
          final isNarrow = constraints.maxWidth < 420;
          final overlayPadding = isPhone ? 12.0 : 32.0;
          final contentHorizontalPadding =
              isNarrow ? TryprSpacing.lg : TryprSpacing.xxl;
          final selectedChipMaxWidth =
              math
                  .max(120.0, constraints.maxWidth - (overlayPadding * 2) - 56)
                  .toDouble();
          // The AppBar is drawn on top of the hero (extendBodyBehindAppBar = true),
          // so increase the hero height by the app bar height so the visible
          // portion fills the full viewport without the next section peeking in.
          const double appBarHeight = 64.0;
          final viewportHeight = MediaQuery.sizeOf(context).height;
          final heroBaseHeight =
              isPhone
                  ? (viewportHeight * 0.78).clamp(420.0, 760.0).toDouble()
                  : viewportHeight;
          final heroHeight = heroBaseHeight + appBarHeight;
          if (kIsWeb && _mapIFrame != null) {
            _mapIFrame!.style.pointerEvents = 'none';
          }
          final selectedWaypoints =
              _selectedTrip == null
                  ? const <Map<String, dynamic>>[]
                  : _normalizedWaypointsFromTrip(_selectedTrip!);
          final selectedStopCount = selectedWaypoints.length;
          final hasSelectedStops = selectedStopCount > 0;
          final normalizedStopIndex =
              hasSelectedStops
                  ? ((_selectedStopIndex % selectedStopCount) +
                          selectedStopCount) %
                      selectedStopCount
                  : -1;
          final selectedStopNumber =
              hasSelectedStops ? normalizedStopIndex + 1 : 0;
          final focusedStop =
              hasSelectedStops ? selectedWaypoints[normalizedStopIndex] : null;
          final showStopNavigator =
              _selectedTrip != null &&
              _showStopNavigator &&
              selectedStopCount > 1;
          final showFocusedStopCard =
              _selectedTrip != null &&
              focusedStop != null &&
              _showPoiInsightCard;
          final showDesktopOverlayPoiCard = showFocusedStopCard && !isPhone;
          final showMobileInlinePoiCard = showFocusedStopCard && isPhone;
          final mobileEditButtonTop =
              appBarHeight + (showStopNavigator ? 112.0 : 72.0);
          final dockHeight =
              isPhone
                  ? _SavedTripsDock.mobileHeight
                  : _SavedTripsDock.desktopHeight;
          final desktopPoiCardMaxHeight = math.min(
            760.0,
            math.max(
              420.0,
              constraints.maxHeight - (appBarHeight + dockHeight + 44),
            ),
          );
          final mobilePoiCardMaxHeight = math.min(
            560.0,
            math.max(300.0, viewportHeight * 0.64),
          );
          final mobilePoiCardMaxWidth =
              math
                  .max(
                    280.0,
                    constraints.maxWidth - (contentHorizontalPadding * 2),
                  )
                  .toDouble();
          return SingleChildScrollView(
            controller: _scrollController,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 3D Globe hero section – ClipRect prevents the iframe
                // from visually overflowing into the AppBar during scroll.
                ClipRect(
                  child: Container(
                    height: heroHeight,
                    decoration: const BoxDecoration(
                      // Match the Earth app's light background
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color(0xFFF8FAFC),
                          Color(0xFFE2E8F0),
                          Color(0xFFF1F5F9),
                        ],
                      ),
                    ),
                    child: Stack(
                      children: [
                        // 3D Globe
                        Positioned.fill(child: _buildMapView()),

                        // Transparent barrier over the AppBar area so the
                        // taskbar receives pointer events above the iframe.
                        if (kIsWeb)
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            height:
                                appBarHeight +
                                MediaQuery.of(context).padding.top,
                            child: WebInterceptor(
                              child: const SizedBox.expand(),
                            ),
                          ),

                        // "Open & Edit Trip" floating button
                        if (_showOpenButton &&
                            _selectedTrip != null &&
                            _canEditSelectedTrip(_selectedTrip))
                          Positioned(
                            top:
                                isPhone
                                    ? mobileEditButtonTop
                                    : appBarHeight + 72,
                            right: overlayPadding,
                            child: ScaleTransition(
                              scale: _buttonAnimation,
                              child: WebInterceptor(
                                child: Material(
                                  color: Colors.transparent,
                                  child: _GlassmorphicButton(
                                    label:
                                        _openingTrip ? 'Opening…' : 'Edit Trip',
                                    icon:
                                        _openingTrip
                                            ? Icons.hourglass_top_rounded
                                            : Icons.edit_road,
                                    onTap: _openTrip,
                                  ),
                                ),
                              ),
                            ),
                          ),

                        // Clear selection button
                        if (_selectedTrip != null)
                          Positioned(
                            top: appBarHeight + 16,
                            right: overlayPadding,
                            child: WebInterceptor(
                              child: _GlassmorphicIconButton(
                                icon: Icons.close,
                                onTap: _clearSelection,
                              ),
                            ),
                          ),

                        // Selected trip info overlay
                        if (_selectedTrip != null)
                          Positioned(
                            top: appBarHeight + 16,
                            left: overlayPadding,
                            child: WebInterceptor(
                              child: _GlassmorphicChip(
                                text: _selectedTrip!['title'] ?? 'Trip',
                                maxWidth: selectedChipMaxWidth,
                              ),
                            ),
                          ),

                        if (showStopNavigator)
                          Positioned(
                            top: appBarHeight + 64,
                            left: overlayPadding,
                            child: WebInterceptor(
                              child: _GlassmorphicStopNavigator(
                                currentStop: selectedStopNumber,
                                totalStops: selectedStopCount,
                                onPrevious: _focusPreviousStop,
                                onNext: _focusNextStop,
                              ),
                            ),
                          ),

                        if (showDesktopOverlayPoiCard)
                          Positioned.fill(
                            child: Padding(
                              padding: EdgeInsets.only(
                                top: appBarHeight + (isPhone ? 84 : 20),
                                bottom: dockHeight + (isPhone ? 10 : 18),
                                right: overlayPadding,
                                left: isPhone ? overlayPadding : 0,
                              ),
                              child: Align(
                                alignment:
                                    isPhone
                                        ? Alignment.bottomCenter
                                        : Alignment.centerRight,
                                child: WebInterceptor(
                                  child: _buildFocusedStopInsightCard(
                                    stop: focusedStop,
                                    stopNumber: selectedStopNumber,
                                    totalStops: selectedStopCount,
                                    maxWidth:
                                        isPhone
                                            ? math.max(
                                              280.0,
                                              constraints.maxWidth -
                                                  (overlayPadding * 2),
                                            )
                                            : math.min(
                                              560.0,
                                              constraints.maxWidth * 0.5,
                                            ),
                                    maxHeight: desktopPoiCardMaxHeight,
                                  ),
                                ),
                              ),
                            ),
                          ),

                        // Saved Trips dock at bottom of globe section
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: WebInterceptor(
                            child: _SavedTripsDock(
                              compact: isPhone,
                              selectedTripId: _selectedTrip?['id'],
                              onTripSelected: _onTripSelected,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // White content area with rounded top corners
                Container(
                  width: double.infinity,
                  decoration: const BoxDecoration(
                    color: TryprColors.background,
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(TryprRadius.xxl),
                    ),
                  ),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: contentHorizontalPadding,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: TryprSpacing.xxl),
                        if (showMobileInlinePoiCard) ...[
                          Text(
                            'Selected Stop Insight',
                            style: Theme.of(
                              context,
                            ).textTheme.titleMedium?.copyWith(
                              color: TryprColors.textPrimary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: TryprSpacing.md),
                          _buildFocusedStopInsightCard(
                            stop: focusedStop,
                            stopNumber: selectedStopNumber,
                            totalStops: selectedStopCount,
                            maxWidth: mobilePoiCardMaxWidth,
                            maxHeight: mobilePoiCardMaxHeight,
                            minHeight: 280.0,
                          ),
                          const SizedBox(height: TryprSpacing.xxl),
                        ],
                        const SectionHeader(
                          title: 'Recommended Trips',
                          seeAllText: 'View all',
                        ),
                        const SizedBox(height: TryprSpacing.lg),
                        // Famous trips == Verified Trips
                        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                          stream:
                              FirebaseFirestore.instance
                                  .collection('verifiedTrips')
                                  .orderBy('createdAt', descending: true)
                                  .limit(3)
                                  .snapshots(),
                          builder: (ctx, snap) {
                            if (snap.hasError) {
                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                child: Text(
                                  'Famous trips failed to load: ${snap.error}',
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(color: Colors.black54),
                                ),
                              );
                            }
                            if (!snap.hasData) {
                              return const Padding(
                                padding: EdgeInsets.symmetric(vertical: 24),
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              );
                            }

                            final docs = snap.data!.docs;
                            if (docs.isEmpty) {
                              return const Padding(
                                padding: EdgeInsets.symmetric(vertical: 12),
                                child: Text(
                                  'No famous trips yet — check back soon.',
                                ),
                              );
                            }

                            return LayoutBuilder(
                              builder: (ctx2, box) {
                                final cards =
                                    docs.map((d) {
                                      final data = d.data();
                                      final title =
                                          (data['title'] ?? '').toString();
                                      final cover =
                                          (data['coverImage'] ?? '').toString();
                                      final photosRaw = data['photos'];
                                      final photos =
                                          photosRaw is List
                                              ? photosRaw
                                                  .map((e) => e.toString())
                                                  .where(
                                                    (s) => s.trim().isNotEmpty,
                                                  )
                                                  .toList()
                                              : <String>[];
                                      final images = <String>[
                                        if (cover.trim().isNotEmpty)
                                          cover.trim(),
                                        ...photos.where(
                                          (p) =>
                                              p.trim().isNotEmpty &&
                                              p.trim() != cover.trim(),
                                        ),
                                      ];

                                      final daysRaw =
                                          data['recommendedDays'] ??
                                          data['days'];
                                      final days =
                                          daysRaw is num
                                              ? daysRaw.toInt()
                                              : int.tryParse(
                                                daysRaw?.toString() ?? '',
                                              );

                                      int? stops;
                                      final wps = data['waypoints'];
                                      if (wps is List) {
                                        stops = wps.length;
                                      }

                                      final points = <Map<String, dynamic>>[];
                                      if (wps is List) {
                                        for (final w in wps) {
                                          if (w is Map) {
                                            final lat = w['lat'];
                                            final lon = w['lon'];
                                            if (lat is num && lon is num) {
                                              points.add({
                                                'name':
                                                    (w['name'] ?? '')
                                                        .toString(),
                                                'lat': lat.toDouble(),
                                                'lon': lon.toDouble(),
                                              });
                                            }
                                          }
                                        }
                                      }

                                      final subtitle =
                                          days != null
                                              ? '$days days'
                                              : 'Verified trip';
                                      final subtitleWithStops =
                                          stops != null
                                              ? '$subtitle • $stops stops'
                                              : subtitle;

                                      return _VerifiedTripPreviewCard(
                                        key: ValueKey(d.id),
                                        title: title,
                                        subtitle: subtitleWithStops,
                                        images:
                                            images.isNotEmpty
                                                ? images
                                                : const [
                                                  'images/mainScreenPic.jpg',
                                                ],
                                        onTap:
                                            points.isEmpty
                                                ? null
                                                : () {
                                                  Navigator.of(context).push(
                                                    VerifiedTripMapScreen.route(
                                                      title: title,
                                                      points: points,
                                                    ),
                                                  );
                                                },
                                      );
                                    }).toList();

                                if (box.maxWidth >= 900 && cards.length == 3) {
                                  return Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(child: cards[0]),
                                      const SizedBox(width: 12),
                                      Expanded(child: cards[1]),
                                      const SizedBox(width: 12),
                                      Expanded(child: cards[2]),
                                    ],
                                  );
                                }

                                return Column(
                                  children: [
                                    for (final c in cards) ...[
                                      c,
                                      const SizedBox(height: 12),
                                    ],
                                  ],
                                );
                              },
                            );
                          },
                        ),

                        const SizedBox(height: TryprSpacing.xxl),

                        // Features section
                        SoftCard(
                          padding: const EdgeInsets.all(TryprSpacing.xl),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(
                                      TryprSpacing.sm,
                                    ),
                                    decoration: BoxDecoration(
                                      color: TryprColors.primary.withOpacity(
                                        0.1,
                                      ),
                                      borderRadius: BorderRadius.circular(
                                        TryprRadius.md,
                                      ),
                                    ),
                                    child: const Icon(
                                      Icons.auto_awesome,
                                      color: TryprColors.primary,
                                      size: 20,
                                    ),
                                  ),
                                  const SizedBox(width: TryprSpacing.md),
                                  Expanded(
                                    child: Text(
                                      'What You Can Do Today',
                                      maxLines: isNarrow ? 2 : 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w600,
                                        color: TryprColors.textPrimary,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: TryprSpacing.lg),
                              _FeatureItem(
                                icon: Icons.map_outlined,
                                text:
                                    'Build multi-stop trips with date ranges, destination sequencing, and route context.',
                              ),
                              _FeatureItem(
                                icon: Icons.group_outlined,
                                text:
                                    'Collaborate in one place with shared trips, shared packing lists, and built-in trip chat.',
                              ),
                              _FeatureItem(
                                icon: Icons.calendar_today_outlined,
                                text:
                                    'Plan each destination day-by-day with arrival/departure dates, activities, and notes.',
                              ),
                              _FeatureItem(
                                icon: Icons.hotel_outlined,
                                text:
                                    'Track practical details including accommodations, activities, and planning progress.',
                              ),
                              _FeatureItem(
                                icon: Icons.share_outlined,
                                text:
                                    'Share trip links so participants and guests can view the same source of truth.',
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: TryprSpacing.xxl),

                        const SectionHeader(title: 'Why Teams Choose Trypr'),
                        const SizedBox(height: TryprSpacing.lg),
                        // Three-up value cards (responsive)
                        LayoutBuilder(
                          builder: (ctx, box) {
                            if (box.maxWidth >= 900) {
                              return Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: _buildValueCard(
                                      context,
                                      icon: Icons.schedule_outlined,
                                      title: 'Trip Logic Stays Coherent',
                                      description:
                                          'When dates or stop lengths change, your itinerary structure stays organized instead of drifting out of sync.',
                                      tag: 'Planning accuracy',
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: _buildValueCard(
                                      context,
                                      icon: Icons.groups_outlined,
                                      title: 'Collaboration Without Clutter',
                                      description:
                                          'Shared trips, chat, and packing lists keep everyone aligned without scattered group-message planning.',
                                      tag: 'Team coordination',
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: _buildValueCard(
                                      context,
                                      icon: Icons.route_outlined,
                                      title: 'From Plan to Execution',
                                      description:
                                          'Destination-level stays, activities, and day plans make it easier to move from rough ideas to real bookings.',
                                      tag: 'Execution ready',
                                    ),
                                  ),
                                ],
                              );
                            } else {
                              return Column(
                                children: [
                                  _buildValueCard(
                                    context,
                                    icon: Icons.schedule_outlined,
                                    title: 'Trip Logic Stays Coherent',
                                    description:
                                        'When dates or stop lengths change, your itinerary structure stays organized instead of drifting out of sync.',
                                    tag: 'Planning accuracy',
                                  ),
                                  const SizedBox(height: 12),
                                  _buildValueCard(
                                    context,
                                    icon: Icons.groups_outlined,
                                    title: 'Collaboration Without Clutter',
                                    description:
                                        'Shared trips, chat, and packing lists keep everyone aligned without scattered group-message planning.',
                                    tag: 'Team coordination',
                                  ),
                                  const SizedBox(height: 12),
                                  _buildValueCard(
                                    context,
                                    icon: Icons.route_outlined,
                                    title: 'From Plan to Execution',
                                    description:
                                        'Destination-level stays, activities, and day plans make it easier to move from rough ideas to real bookings.',
                                    tag: 'Execution ready',
                                  ),
                                ],
                              );
                            }
                          },
                        ),

                        const SizedBox(height: TryprSpacing.xxxl),
                      ],
                    ),
                  ),
                ),

                Container(
                  padding: const EdgeInsets.symmetric(
                    vertical: TryprSpacing.xl,
                  ),
                  color: TryprColors.surfaceVariant,
                  child: Center(
                    child: Text(
                      '© Trypr 2026 • Practical trip planning for real groups',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: TryprColors.textTertiary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _FeatureItem extends StatelessWidget {
  final IconData icon;
  final String text;

  const _FeatureItem({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: TryprSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: TryprColors.primary),
          const SizedBox(width: TryprSpacing.md),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 14,
                color: TryprColors.textSecondary,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _VerifiedTripPreviewCard extends StatefulWidget {
  final String title;
  final String subtitle;
  final List<String> images;
  final VoidCallback? onTap;

  const _VerifiedTripPreviewCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.images,
    this.onTap,
  });

  @override
  State<_VerifiedTripPreviewCard> createState() =>
      _VerifiedTripPreviewCardState();
}

class _VerifiedTripPreviewCardState extends State<_VerifiedTripPreviewCard> {
  int _idx = 0;
  bool _isHovered = false;

  Widget _imageFromSource(String src) {
    final s = src.trim();
    if (s.isEmpty) return const SizedBox.shrink();
    if (s.startsWith('data:image')) {
      if (kIsWeb) {
        return Image.network(
          s,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
        );
      }
      try {
        final bytes = base64Decode(s.split(',').last);
        return Image.memory(
          bytes,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
        );
      } catch (_) {
        return const SizedBox.shrink();
      }
    }
    if (s.startsWith('http')) {
      return Image.network(
        s,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      );
    }
    return Image.asset(
      s,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final images =
        widget.images.isNotEmpty
            ? widget.images
            : const ['images/mainScreenPic.jpg'];
    final clampedIdx = (_idx % images.length);
    final current = images[clampedIdx];

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedScale(
        duration: const Duration(milliseconds: 200),
        scale: _isHovered ? 1.02 : 1.0,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.only(
            right: TryprSpacing.md,
            bottom: TryprSpacing.md,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(TryprRadius.xl),
            color: TryprColors.surface,
            boxShadow:
                _isHovered
                    ? TryprColors.elevatedShadow
                    : TryprColors.softShadow,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(TryprRadius.xl),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: widget.onTap,
                child: AspectRatio(
                  aspectRatio: 4 / 3,
                  child: LayoutBuilder(
                    builder: (ctx, constraints) {
                      final available =
                          constraints.maxHeight.isFinite
                              ? constraints.maxHeight
                              : 320.0;
                      final footerHeight = (available * 0.25).clamp(
                        56.0,
                        100.0,
                      );
                      final imageHeight = (available - footerHeight).clamp(
                        40.0,
                        double.infinity,
                      );

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            height: imageHeight,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                _imageFromSource(current),
                                // Subtle gradient overlay at bottom
                                Positioned(
                                  bottom: 0,
                                  left: 0,
                                  right: 0,
                                  height: 40,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                        colors: [
                                          Colors.transparent,
                                          Colors.black.withOpacity(0.1),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                                if (images.length > 1)
                                  Positioned(
                                    top: TryprSpacing.md,
                                    right: TryprSpacing.md,
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: Colors.white.withOpacity(0.9),
                                        borderRadius: BorderRadius.circular(
                                          TryprRadius.full,
                                        ),
                                        boxShadow: TryprColors.softShadow,
                                      ),
                                      child: Material(
                                        color: Colors.transparent,
                                        child: InkWell(
                                          borderRadius: BorderRadius.circular(
                                            TryprRadius.full,
                                          ),
                                          onTap:
                                              () => setState(
                                                () => _idx = _idx + 1,
                                              ),
                                          child: const Padding(
                                            padding: EdgeInsets.all(
                                              TryprSpacing.sm,
                                            ),
                                            child: Icon(
                                              Icons.chevron_right_rounded,
                                              color: TryprColors.textPrimary,
                                              size: 20,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                // Image counter pills
                                if (images.length > 1)
                                  Positioned(
                                    bottom: TryprSpacing.md,
                                    left: 0,
                                    right: 0,
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: List.generate(
                                        images.length.clamp(0, 5),
                                        (i) => Container(
                                          width: i == clampedIdx ? 16 : 6,
                                          height: 6,
                                          margin: const EdgeInsets.symmetric(
                                            horizontal: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color:
                                                i == clampedIdx
                                                    ? Colors.white
                                                    : Colors.white.withOpacity(
                                                      0.5,
                                                    ),
                                            borderRadius: BorderRadius.circular(
                                              3,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Container(
                            height: footerHeight,
                            padding: const EdgeInsets.symmetric(
                              horizontal: TryprSpacing.lg,
                              vertical: TryprSpacing.sm,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(
                                  child: Text(
                                    widget.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: TryprColors.textPrimary,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Flexible(
                                  child: Text(
                                    widget.subtitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: TryprColors.textSecondary,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Horizontal scrolling "Saved Trips" dock with glassmorphism cards
class _SavedTripsDock extends StatelessWidget {
  final String? selectedTripId;
  final void Function(Map<String, dynamic> trip) onTripSelected;
  final bool compact;

  static const double desktopHeight = 340;
  static const double mobileHeight = 236;

  const _SavedTripsDock({
    required this.selectedTripId,
    required this.onTripSelected,
    this.compact = false,
  });

  String _formatDistance(double? km) {
    if (km == null) return '';
    if (km < 1) return '${(km * 1000).round()} m';
    return '${km.toStringAsFixed(0)} km';
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final rowHorizontalPadding = compact ? 14.0 : 24.0;
    final rowVerticalPadding = compact ? 5.0 : 8.0;
    final listHorizontalPadding = compact ? 10.0 : 16.0;
    final rowLabelSize = compact ? 12.0 : 13.0;
    final userTripsHeight = compact ? 100.0 : 150.0;

    return Container(
      height: compact ? mobileHeight : desktopHeight,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black.withOpacity(0.10)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Your Trips row ──
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: rowHorizontalPadding,
              vertical: rowVerticalPadding,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.bookmark_outline,
                  size: 16,
                  color: Colors.white.withOpacity(0.6),
                ),
                const SizedBox(width: 8),
                Text(
                  'Your Trips',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.7),
                    fontSize: rowLabelSize,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: userTripsHeight,
            child:
                user == null
                    ? Center(
                      child: Text(
                        'Sign in to see your trips',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.5),
                          fontSize: 13,
                        ),
                      ),
                    )
                    : StreamBuilder<List<TripModel>>(
                      stream: FirestoreService().getTripsStream(),
                      builder: (context, snapshot) {
                        if (snapshot.hasError) {
                          return Center(
                            child: Text(
                              'Could not load trips',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.5),
                                fontSize: 13,
                              ),
                            ),
                          );
                        }
                        if (!snapshot.hasData) {
                          return const Center(
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white54,
                            ),
                          );
                        }

                        final trips = snapshot.data ?? [];

                        if (trips.isEmpty) {
                          return Center(
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.add_circle_outline,
                                  color: Colors.white.withOpacity(0.4),
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'No trips yet — start planning!',
                                  style: TextStyle(
                                    color: Colors.white.withOpacity(0.5),
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          );
                        }

                        return ListView.builder(
                          scrollDirection: Axis.horizontal,
                          padding: EdgeInsets.symmetric(
                            horizontal: listHorizontalPadding,
                          ),
                          itemCount: trips.length,
                          itemBuilder: (context, index) {
                            final tripModel = trips[index];

                            // Convert TripModel.Stop to waypoint format
                            final waypoints =
                                tripModel.stops
                                    .map(
                                      (stop) => {
                                        'lat': stop.latitude,
                                        'lon': stop.longitude,
                                        'name': stop.placeName,
                                      },
                                    )
                                    .toList();

                            final trip = {
                              'id': tripModel.id,
                              'title': tripModel.tripName,
                              'waypoints': waypoints,
                              'stops': waypoints.length,
                              'distance': tripModel.distance,
                              'startDate': tripModel.startDate,
                              'endDate': tripModel.endDate,
                              'description': tripModel.description,
                              if (tripModel.transportMode != null)
                                'transportMode': tripModel.transportMode,
                              if (tripModel.segmentTransportModes != null)
                                'segmentTransportModes':
                                    tripModel.segmentTransportModes,
                              if (tripModel.segmentRoutingTypes != null)
                                'segmentRoutingTypes':
                                    tripModel.segmentRoutingTypes,
                              'canEdit': true,
                            };

                            final isSelected = selectedTripId == tripModel.id;

                            return _TripCard(
                              compact: compact,
                              title: tripModel.tripName,
                              stops: tripModel.stops.length,
                              distance: _formatDistance(tripModel.distance),
                              date: tripModel.formattedDates,
                              isSelected: isSelected,
                              onTap: () => onTripSelected(trip),
                            );
                          },
                        );
                      },
                    ),
          ),

          // ── Verified Trips row ──
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: rowHorizontalPadding,
              vertical: compact ? 3 : 4,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.verified_outlined,
                  size: 16,
                  color: Colors.white.withOpacity(0.6),
                ),
                const SizedBox(width: 8),
                Text(
                  'Verified Trips',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.7),
                    fontSize: rowLabelSize,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream:
                  FirebaseFirestore.instance
                      .collection('verifiedTrips')
                      .orderBy('createdAt', descending: true)
                      .limit(10)
                      .snapshots(),
              builder: (context, snap) {
                if (!snap.hasData || snap.data!.docs.isEmpty) {
                  return Center(
                    child: Text(
                      'No verified trips yet',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.5),
                        fontSize: 13,
                      ),
                    ),
                  );
                }
                final docs = snap.data!.docs;
                return ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: EdgeInsets.symmetric(
                    horizontal: listHorizontalPadding,
                  ),
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    final data = docs[index].data();
                    final title = (data['title'] ?? 'Verified Trip').toString();
                    final wps = data['waypoints'];
                    final stops = wps is List ? wps.length : 0;
                    final daysRaw = data['recommendedDays'] ?? data['days'];
                    final days =
                        daysRaw is num ? '${daysRaw.toInt()} days' : '';

                    return _TripCard(
                      compact: compact,
                      title: title,
                      stops: stops,
                      distance: days,
                      date: '',
                      isSelected: false,
                      onTap: () {
                        // Build waypoints for the globe preview
                        final points = <Map<String, dynamic>>[];
                        if (wps is List) {
                          for (final w in wps) {
                            if (w is Map) {
                              final lat = w['lat'];
                              final lon = w['lon'];
                              if (lat is num && lon is num) {
                                points.add({
                                  'lat': lat.toDouble(),
                                  'lon': lon.toDouble(),
                                  'name': (w['name'] ?? '').toString(),
                                });
                              }
                            }
                          }
                        }
                        if (points.isNotEmpty) {
                          onTripSelected({
                            'id': docs[index].id,
                            'title': title,
                            'waypoints': points,
                            'stops': stops,
                            if (data['transportMode'] != null)
                              'transportMode': data['transportMode'],
                            if (data['segmentTransportModes'] is List)
                              'segmentTransportModes':
                                  data['segmentTransportModes'],
                            if (data['segmentRoutingTypes'] is List)
                              'segmentRoutingTypes':
                                  data['segmentRoutingTypes'],
                            'canEdit': false,
                          });
                        }
                      },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Trip card for the dock – warm, travel-inspired design
class _TripCard extends StatefulWidget {
  final bool compact;
  final String title;
  final int stops;
  final String distance;
  final String date;
  final bool isSelected;
  final VoidCallback onTap;

  const _TripCard({
    this.compact = false,
    required this.title,
    required this.stops,
    required this.distance,
    required this.date,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_TripCard> createState() => _TripCardState();
}

class _TripCardState extends State<_TripCard> {
  bool _isHovered = false;

  /// Pick a fun emoji based on the trip title
  String get _tripEmoji {
    final t = widget.title.toLowerCase();
    if (t.contains('beach') || t.contains('island') || t.contains('coast')) {
      return '🏖️';
    }
    if (t.contains('mountain') || t.contains('hiking') || t.contains('trek')) {
      return '⛰️';
    }
    if (t.contains('city') ||
        t.contains('urban') ||
        t.contains('york') ||
        t.contains('london') ||
        t.contains('paris') ||
        t.contains('tokyo')) {
      return '🏙️';
    }
    if (t.contains('road') || t.contains('drive')) return '🚗';
    if (t.contains('camp')) return '⛺';
    if (t.contains('ski') || t.contains('snow')) return '🎿';
    if (t.contains('safari') ||
        t.contains('jungle') ||
        t.contains('wildlife')) {
      return '🦁';
    }
    if (t.contains('cruise') || t.contains('sail') || t.contains('boat')) {
      return '🚢';
    }
    if (t.contains('europe')) return '🇪🇺';
    if (t.contains('asia')) return '🌏';
    if (t.contains('africa')) return '🌍';
    // Cycle through fun travel emojis for variety
    final emojis = ['✈️', '🌎', '🗺️', '🧳', '🌴', '🏔️', '🌅', '🎒'];
    return emojis[widget.title.hashCode.abs() % emojis.length];
  }

  /// Pastel gradient palette per card – warm & inviting
  List<Color> get _cardGradient {
    final palettes = [
      [const Color(0xFF667eea), const Color(0xFF764ba2)], // Violet dream
      [const Color(0xFFf093fb), const Color(0xFFf5576c)], // Pink coral
      [const Color(0xFF4facfe), const Color(0xFF00f2fe)], // Ocean blue
      [const Color(0xFF43e97b), const Color(0xFF38f9d7)], // Mint fresh
      [const Color(0xFFfa709a), const Color(0xFFfee140)], // Sunset glow
      [const Color(0xFFa18cd1), const Color(0xFFfbc2eb)], // Lavender haze
      [const Color(0xFFffecd2), const Color(0xFFfcb69f)], // Peach warmth
      [const Color(0xFF89f7fe), const Color(0xFF66a6ff)], // Sky breeze
    ];
    return palettes[widget.title.hashCode.abs() % palettes.length];
  }

  @override
  Widget build(BuildContext context) {
    final gradColors = _cardGradient;
    final cardWidth = widget.compact ? 140.0 : 160.0;
    final cardPadding = widget.compact ? 8.0 : 10.0;
    final titleFontSize = widget.compact ? 11.0 : 12.0;
    final metaFontSize = widget.compact ? 8.0 : 9.0;
    final emojiSize = widget.compact ? 16.0 : 18.0;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          width: cardWidth,
          margin: const EdgeInsets.only(right: 12, bottom: 12),
          transform:
              _isHovered || widget.isSelected
                  ? (Matrix4.identity()..translate(0.0, -4.0))
                  : Matrix4.identity(),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                gradColors[0].withOpacity(widget.isSelected ? 0.85 : 0.65),
                gradColors[1].withOpacity(widget.isSelected ? 0.85 : 0.65),
              ],
            ),
            border: Border.all(
              color:
                  widget.isSelected
                      ? Colors.white.withOpacity(0.7)
                      : Colors.white.withOpacity(_isHovered ? 0.35 : 0.15),
              width: widget.isSelected ? 2 : 1,
            ),
            boxShadow: [
              BoxShadow(
                color: gradColors[0].withOpacity(
                  widget.isSelected ? 0.4 : (_isHovered ? 0.3 : 0.15),
                ),
                blurRadius: widget.isSelected ? 24 : 12,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Padding(
              padding: EdgeInsets.all(cardPadding),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Emoji badge
                  Text(_tripEmoji, style: TextStyle(fontSize: emojiSize)),
                  const SizedBox(height: 3),
                  // Title
                  Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: titleFontSize,
                      fontWeight: FontWeight.w700,
                      shadows: const [
                        Shadow(color: Color(0x40000000), blurRadius: 4),
                      ],
                    ),
                  ),
                  const SizedBox(height: 3),
                  // Stops & distance
                  Row(
                    children: [
                      Icon(
                        Icons.place,
                        size: widget.compact ? 9 : 10,
                        color: Colors.white70,
                      ),
                      const SizedBox(width: 2),
                      Text(
                        '${widget.stops} stops',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: metaFontSize,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (widget.distance.isNotEmpty) ...[
                        const SizedBox(width: 4),
                        Text(
                          '·',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.5),
                            fontSize: metaFontSize,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            widget.distance,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: metaFontSize,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  // Date pill
                  if (widget.date.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        widget.date,
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: metaFontSize,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Glassmorphism floating button
class _GlassmorphicButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  const _GlassmorphicButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  State<_GlassmorphicButton> createState() => _GlassmorphicButtonState();
}

class _GlassmorphicButtonState extends State<_GlassmorphicButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(50),
            color: Colors.white.withOpacity(_isHovered ? 0.92 : 0.82),
            border: Border.all(
              color: Colors.white.withOpacity(_isHovered ? 0.95 : 0.7),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(_isHovered ? 0.2 : 0.14),
                blurRadius: _isHovered ? 20 : 14,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(50),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(widget.icon, color: const Color(0xFF0F172A), size: 18),
                  const SizedBox(width: 8),
                  Text(
                    widget.label,
                    style: const TextStyle(
                      color: Color(0xFF0F172A),
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Small glassmorphic icon button
class _GlassmorphicIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _GlassmorphicIconButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(50),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withOpacity(0.1),
              border: Border.all(color: Colors.white.withOpacity(0.2)),
            ),
            child: Icon(icon, color: Colors.white.withOpacity(0.8), size: 18),
          ),
        ),
      ),
    );
  }
}

/// Glassmorphic info chip
class _GlassmorphicChip extends StatelessWidget {
  final String text;
  final double? maxWidth;

  const _GlassmorphicChip({required this.text, this.maxWidth});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          constraints:
              maxWidth == null ? null : BoxConstraints(maxWidth: maxWidth!),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: Colors.white.withOpacity(0.1),
            border: Border.all(color: Colors.white.withOpacity(0.2)),
          ),
          child: Row(
            mainAxisSize:
                maxWidth == null ? MainAxisSize.min : MainAxisSize.max,
            children: [
              Icon(
                Icons.map_outlined,
                size: 14,
                color: Colors.white.withOpacity(0.8),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.9),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GlassmorphicStopNavigator extends StatelessWidget {
  final int currentStop;
  final int totalStops;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  const _GlassmorphicStopNavigator({
    required this.currentStop,
    required this.totalStops,
    required this.onPrevious,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            color: Colors.white.withOpacity(0.14),
            border: Border.all(color: Colors.white.withOpacity(0.22)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _StopNavButton(label: '<', onTap: onPrevious),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  'Stop $currentStop/$totalStops',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.92),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              _StopNavButton(label: '>', onTap: onNext),
            ],
          ),
        ),
      ),
    );
  }
}

class _StopNavButton extends StatefulWidget {
  final String label;
  final VoidCallback onTap;

  const _StopNavButton({required this.label, required this.onTap});

  @override
  State<_StopNavButton> createState() => _StopNavButtonState();
}

class _StopNavButtonState extends State<_StopNavButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withOpacity(_hovered ? 0.28 : 0.18),
            border: Border.all(color: Colors.white.withOpacity(0.25)),
          ),
          child: Text(
            widget.label,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 14,
            ),
          ),
        ),
      ),
    );
  }
}
