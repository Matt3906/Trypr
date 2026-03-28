import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:trypr/utils/trypr_snackbar.dart';
import 'package:trypr/widgets/map_embed.dart';
import 'package:trypr/widgets/globe_3d_embed.dart';
import 'package:trypr/screens/destination_detail_screen.dart';
import 'package:trypr/screens/trip_planning_screen.dart';
import 'package:trypr/services/geocode.dart';
import 'package:flutter/foundation.dart';
import 'package:trypr/widgets/web_interceptor.dart';
import 'package:trypr/widgets/trip_chat_dialog_clean.dart';
import 'package:trypr/widgets/trip_expenses_dialog.dart';
import 'package:trypr/widgets/share_trip_dialog.dart';
import 'package:trypr/widgets/transit_leg_tabs_card.dart';
import 'package:trypr/services/name_lookup.dart';
import 'package:trypr/utils/route_cache.dart';
import 'dart:async';
import 'dart:ui' show ImageFilter;

enum _TripDetailMapMode { map2d, globe3d }

enum _TripDetailQuickAction { plan, packing, expenses, chat, share }

class _TransportOption {
  final String mode;
  final String label;
  final String emoji;

  const _TransportOption(this.mode, this.label, this.emoji);
}

const List<_TransportOption> _transportOptions = [
  _TransportOption('driving', 'Car', '🚗'),
  _TransportOption('flying', 'Flight', '✈️'),
  _TransportOption('transit', 'Train', '🚆'),
  _TransportOption('walking', 'Walk', '🚶'),
  _TransportOption('biking', 'Bike', '🚲'),
  _TransportOption('portaging', 'Portaging', '🛶'),
  _TransportOption('hiking', 'Hiking', '🥾'),
];

class TripDetailScreen extends StatefulWidget {
  final String docId;
  final Map<String, dynamic> data;

  /// When true the screen is purely read-only (e.g. unauthenticated share-link
  /// viewer). All edit controls, chat, packing, expenses and share buttons are
  /// hidden and a sign-in banner is shown instead.
  final bool readOnly;
  const TripDetailScreen({
    super.key,
    required this.docId,
    required this.data,
    this.readOnly = false,
  });

  @override
  State<TripDetailScreen> createState() => _TripDetailScreenState();
}

class _TripDetailScreenState extends State<TripDetailScreen> {
  static const double _mobileRouteSheetCollapsedSize = 0.18;
  static const double _mobileRouteSheetPreviewSize = 0.40;
  static const double _mobileRouteSheetMaxSize = 0.75;

  int _days = 1;
  bool _saving = false;
  bool _editing = false;
  late List<Map<String, dynamic>> _waypoints;
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _placeSuggestions = [];
  Timer? _debounce;
  Timer? _routeCachePersistDebounce;
  bool _searchingPlaces = false;
  Map<String, dynamic> _liveData = {};
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _docSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _localDocSub;
  String? _currentSubscribedPath;

  String _transportMode = 'driving';
  List<Map<String, dynamic>> _routeVia = const [];
  List<String> _routeInstructions = const [];
  List<Map<String, dynamic>> _routeGeometry3d = const [];
  List<Map<String, dynamic>> _routeSegmentDetails = const [];
  Map<String, dynamic>? _selectedMapPoint;
  Map<String, dynamic>? _focusedTransitStep;
  int _focusedTransitStepRequestId = 0;

  List<String> _segmentRoutingTypes = const [];
  List<String> _segmentTransportModes = const [];
  Map<String, dynamic>? _transitArrivalStop;

  bool _suspendMapTap = false;
  _TripDetailMapMode _mapMode = _TripDetailMapMode.map2d;
  final DraggableScrollableController _mobileRouteSheetController =
      DraggableScrollableController();
  double _mobileRouteSheetExtent = _mobileRouteSheetCollapsedSize;

  User? get _user => FirebaseAuth.instance.currentUser;

  void _handleMobileRouteSheetChanged() {
    if (!_mobileRouteSheetController.isAttached || !mounted) return;
    final next = _mobileRouteSheetController.size;
    if ((_mobileRouteSheetExtent - next).abs() < 0.005) return;
    setState(() => _mobileRouteSheetExtent = next);
  }

  Future<T?> _withMapTapSuspended<T>(Future<T?> Function() action) async {
    if (!mounted) return null;
    setState(() => _suspendMapTap = true);
    try {
      return await action();
    } finally {
      if (mounted) setState(() => _suspendMapTap = false);
    }
  }

  bool _isAdventureMode(String mode) {
    final m = mode.trim().toLowerCase();
    return m == 'hiking' ||
        m == 'portaging' ||
        m == 'backpacking' ||
        m == 'bikepacking';
  }

  String _emojiForPackingItem(String raw) {
    final name = raw.trim().toLowerCase();
    if (name.isEmpty) return '🎒';
    if (name.contains('underwear') || name.contains('brief')) return '🩲';
    if (name.contains('sock')) return '🧦';
    if (name.contains('shoe') || name.contains('boot')) return '👟';
    if (name.contains('jacket') || name.contains('coat')) return '🧥';
    if (name.contains('hat') || name.contains('cap')) return '🧢';
    if (name.contains('shirt') ||
        name.contains('tee') ||
        name.contains('t-shirt')) {
      return '👕';
    }
    if (name.contains('pants') ||
        name.contains('jeans') ||
        name.contains('short')) {
      return '👖';
    }
    if (name.contains('dress')) return '👗';
    if (name.contains('swim') || name.contains('bikini')) return '👙';
    if (name.contains('tooth')) return '🪥';
    if (name.contains('soap') || name.contains('shampoo')) return '🧴';
    if (name.contains('sunscreen') || name.contains('sun screen')) return '🧴';
    if (name.contains('phone') ||
        name.contains('charger') ||
        name.contains('cable')) {
      return '🔌';
    }
    if (name.contains('camera')) return '📷';
    if (name.contains('passport')) return '🛂';
    if (name.contains('ticket') || name.contains('boarding')) return '🎫';
    if (name.contains('water') || name.contains('bottle')) return '💧';
    if (name.contains('snack') || name.contains('food')) return '🥪';
    if (name.contains('med') ||
        name.contains('pill') ||
        name.contains('first aid')) {
      return '💊';
    }
    if (name.contains('laptop') || name.contains('tablet')) return '💻';
    if (name.contains('map')) return '🗺️';
    if (name.contains('tent')) return '⛺';
    if (name.contains('sleeping bag')) return '🛌';
    return '🎒';
  }

  String _normalizeTransportMode(String raw) {
    var m = raw.trim().toLowerCase();
    if (m == 'car' || m == 'driving') m = 'driving';
    if (m == 'plane' || m == 'flight' || m == 'flying') m = 'flying';
    if (m == 'train' ||
        m == 'rail' ||
        m == 'public_transit' ||
        m == 'public transit') {
      m = 'transit';
    }
    if (m == 'walk') m = 'walking';
    if (m == 'bike' ||
        m == 'bicycling' ||
        m == 'cycling' ||
        m == 'bikepacking') {
      m = 'biking';
    }
    if (m == 'hiking' || m == 'backpacking') m = 'hiking';
    if (m == 'portage' || m == 'portaging' || m == 'canoe' || m == 'canoeing') {
      m = 'portaging';
    }
    if (m == 'gas_stops' || m == 'gas' || m == 'gas/stops') m = 'driving';
    for (final opt in _transportOptions) {
      if (opt.mode == m) return m;
    }
    return 'driving';
  }

  List<String> _coerceSegmentRoutingTypes(
    List<dynamic> raw, {
    int? segmentCount,
  }) {
    final out =
        raw
            .map((e) => e.toString().trim().toLowerCase())
            .map((v) => v == 'direct' ? 'direct' : 'calculated')
            .toList();
    if (segmentCount == null) return out;
    if (out.length > segmentCount) return out.take(segmentCount).toList();
    if (out.length < segmentCount) {
      return [...out, ...List.filled(segmentCount - out.length, 'calculated')];
    }
    return out;
  }

  List<String> _coerceSegmentTransportModes(
    List<dynamic> raw, {
    required int segmentCount,
    String? fallbackMode,
  }) {
    final fallback = _normalizeTransportMode(fallbackMode ?? _transportMode);
    final out = raw.map((e) => _normalizeTransportMode(e.toString())).toList();
    if (out.length > segmentCount) return out.take(segmentCount).toList();
    if (out.length < segmentCount) {
      return [...out, ...List.filled(segmentCount - out.length, fallback)];
    }
    return out;
  }

  String _segmentTransportModeAt(int segmentIndex) {
    if (segmentIndex < 0) return _normalizeTransportMode(_transportMode);
    if (segmentIndex >= _segmentTransportModes.length) {
      return _normalizeTransportMode(_transportMode);
    }
    return _normalizeTransportMode(_segmentTransportModes[segmentIndex]);
  }

  bool get _hasTransitModeInRoute {
    final segments = _waypoints.length > 1 ? _waypoints.length - 1 : 0;
    if (segments == 0) {
      return _normalizeTransportMode(_transportMode) == 'transit';
    }
    for (var i = 0; i < segments; i++) {
      if (_segmentTransportModeAt(i) == 'transit') return true;
    }
    return false;
  }

  bool _requiresGearListForModes(List<String> segmentModes, String fallback) {
    for (final mode in segmentModes) {
      if (_isAdventureMode(mode)) return true;
    }
    return _isAdventureMode(fallback);
  }

  void _syncSegmentDataWithWaypoints() {
    final segmentCount = _waypoints.length > 1 ? _waypoints.length - 1 : 0;
    _segmentRoutingTypes = _coerceSegmentRoutingTypes(
      _segmentRoutingTypes,
      segmentCount: segmentCount,
    );
    _segmentTransportModes = _coerceSegmentTransportModes(
      _segmentTransportModes,
      segmentCount: segmentCount,
      fallbackMode: _transportMode,
    );
    _routeVia =
        _routeVia
            .where((v) {
              final after = (v['afterIndex'] as num?)?.toInt();
              return after != null && after >= 0 && after < segmentCount;
            })
            .map((v) => Map<String, dynamic>.from(v))
            .toList();
  }

  int _waypointNightCount(Map<String, dynamic> waypoint) {
    final raw = waypoint['nights'];
    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString() ?? '') ?? 0;
  }

  bool _canEditWaypointRole(
    int waypointIndex, {
    List<Map<String, dynamic>>? waypoints,
  }) {
    final items = waypoints ?? _waypoints;
    return waypointIndex > 0 && waypointIndex < items.length - 1;
  }

  bool _waypointIsStop(
    int waypointIndex, {
    List<Map<String, dynamic>>? waypoints,
  }) {
    final items = waypoints ?? _waypoints;
    if (waypointIndex < 0 || waypointIndex >= items.length) return false;
    if (!_canEditWaypointRole(waypointIndex, waypoints: items)) return false;
    final raw = items[waypointIndex]['isStop'];
    if (raw is bool) return raw;
    return _waypointNightCount(items[waypointIndex]) > 0;
  }

  String _waypointRoleLabel(
    int waypointIndex, {
    List<Map<String, dynamic>>? waypoints,
  }) {
    final items = waypoints ?? _waypoints;
    if (waypointIndex <= 0) return 'Start point';
    if (waypointIndex >= items.length - 1) return 'End point';
    return _waypointIsStop(waypointIndex, waypoints: items)
        ? 'Stay stop'
        : 'Waypoint';
  }

  bool _isWaypointOnly(
    int waypointIndex, {
    List<Map<String, dynamic>>? waypoints,
  }) {
    return _canEditWaypointRole(waypointIndex, waypoints: waypoints) &&
        !_waypointIsStop(waypointIndex, waypoints: waypoints);
  }

  List<Map<String, dynamic>> _syncedWaypointsForSave() {
    return _waypoints
        .asMap()
        .entries
        .map((entry) {
          final idx = entry.key;
          final waypoint = Map<String, dynamic>.from(entry.value);
          final isStop = _waypointIsStop(idx);
          waypoint['isStop'] = isStop;
          waypoint['nights'] =
              isStop
                  ? (_waypointNightCount(waypoint) > 0
                      ? _waypointNightCount(waypoint)
                      : 1)
                  : 0;
          return waypoint;
        })
        .toList(growable: false);
  }

  void _syncLiveWaypointsFromState() {
    _liveData['waypoints'] =
        _waypoints.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  void _setWaypointRole(int waypointIndex, bool isStop) {
    if (!_canEditWaypointRole(waypointIndex)) return;
    setState(() {
      final waypoint = _waypoints[waypointIndex];
      waypoint['isStop'] = isStop;
      waypoint['nights'] =
          isStop
              ? (_waypointNightCount(waypoint) > 0
                  ? _waypointNightCount(waypoint)
                  : 1)
              : 0;
      _syncLiveWaypointsFromState();
    });
  }

  void _applyCachedRouteStateFromLiveData() {
    _routeGeometry3d = readRouteGeometry(_liveData['routeGeometry3d']);
    _routeInstructions = readRouteInstructions(_liveData['routeInstructions']);
    _routeSegmentDetails = readRouteSegmentDetails(
      _liveData['routeSegmentDetails'],
    );
  }

  bool _sameRouteInstructions(List<String> next) {
    if (_routeInstructions.length != next.length) return false;
    for (var i = 0; i < next.length; i++) {
      if (_routeInstructions[i] != next[i]) return false;
    }
    return true;
  }

  bool _sameRouteGeometry(List<Map<String, dynamic>> next) {
    if (_routeGeometry3d.length != next.length) return false;
    for (var i = 0; i < next.length; i++) {
      final a = _routeGeometry3d[i];
      final b = next[i];
      final aLat = (a['lat'] as num?)?.toDouble() ?? 0.0;
      final aLon = ((a['lon'] ?? a['lng']) as num?)?.toDouble() ?? 0.0;
      final bLat = (b['lat'] as num?)?.toDouble() ?? 0.0;
      final bLon = ((b['lon'] ?? b['lng']) as num?)?.toDouble() ?? 0.0;
      if ((aLat - bLat).abs() > 1e-7 || (aLon - bLon).abs() > 1e-7) {
        return false;
      }
    }
    return true;
  }

  bool _sameRouteSegmentDetails(List<Map<String, dynamic>> next) {
    if (_routeSegmentDetails.length != next.length) return false;
    for (var i = 0; i < next.length; i++) {
      final current = _routeSegmentDetails[i];
      final candidate = next[i];
      final currentIndex = (current['segmentIndex'] as num?)?.toInt() ?? -1;
      final candidateIndex = (candidate['segmentIndex'] as num?)?.toInt() ?? -1;
      if (currentIndex != candidateIndex) return false;
      if ((current['mode'] ?? '').toString() !=
          (candidate['mode'] ?? '').toString()) {
        return false;
      }
      final currentSteps = current['steps'];
      final candidateSteps = candidate['steps'];
      if (currentSteps is! List || candidateSteps is! List) return false;
      if (currentSteps.length != candidateSteps.length) return false;
      for (var stepIndex = 0; stepIndex < candidateSteps.length; stepIndex++) {
        final a = currentSteps[stepIndex];
        final b = candidateSteps[stepIndex];
        if (a is! Map || b is! Map) return false;
        const keys = ['mode', 'tabLabel', 'headline', 'detail', 'caption'];
        for (final key in keys) {
          if ((a[key] ?? '').toString() != (b[key] ?? '').toString()) {
            return false;
          }
        }
      }
    }
    return true;
  }

  List<Map<String, dynamic>> _legacyTransitStepsFromInstructions() {
    return _routeInstructions
        .map((line) {
          final text = line.trim();
          if (text.isEmpty) return const <String, dynamic>{};
          final lower = text.toLowerCase();
          if (lower.startsWith('walk')) {
            return {'mode': 'walking', 'tabLabel': 'Walk', 'headline': text};
          }
          if (lower.startsWith('bike')) {
            return {'mode': 'biking', 'tabLabel': 'Bike', 'headline': text};
          }
          return {'mode': 'transit', 'tabLabel': 'Train', 'headline': text};
        })
        .where((step) => step.isNotEmpty)
        .take(6)
        .toList(growable: false);
  }

  Map<String, dynamic>? _transitSegmentDetailAt(int segmentIndex) {
    for (final detail in _routeSegmentDetails) {
      final index = (detail['segmentIndex'] as num?)?.toInt();
      final mode = _normalizeTransportMode((detail['mode'] ?? '').toString());
      final steps = detail['steps'];
      if (index == segmentIndex && mode == 'transit' && steps is List) {
        return detail;
      }
    }

    final transitSegments = <int>[];
    for (var i = 0; i < _waypoints.length - 1; i++) {
      if (_segmentTransportModeAt(i) == 'transit') {
        transitSegments.add(i);
      }
    }
    if (transitSegments.length == 1 &&
        transitSegments.first == segmentIndex &&
        _routeInstructions.isNotEmpty) {
      return {
        'segmentIndex': segmentIndex,
        'mode': 'transit',
        'steps': _legacyTransitStepsFromInstructions(),
        if (_transitArrivalStop != null) 'arrivalStop': _transitArrivalStop,
      };
    }
    return null;
  }

  String _currentRouteCacheKey() {
    return buildRouteCacheKey(
      waypoints: _waypoints,
      transportMode: _transportMode,
      segmentTransportModes: _segmentTransportModes,
      segmentRoutingTypes: _segmentRoutingTypes,
      routeVia: _routeVia,
    );
  }

  bool get _canUseCachedRoute {
    final stored = (_liveData['routeCacheKey'] ?? '').toString().trim();
    return stored.isNotEmpty &&
        stored == _currentRouteCacheKey() &&
        _routeGeometry3d.length >= 2 &&
        (!_hasTransitModeInRoute || _routeSegmentDetails.isNotEmpty);
  }

  Map<String, dynamic> _routeCachePayload() {
    return {
      'routeCacheKey': _currentRouteCacheKey(),
      'routeGeometry3d': simplifyRouteGeometry(_routeGeometry3d),
      'routeInstructions': _routeInstructions.take(8).toList(growable: false),
      'routeSegmentDetails': _routeSegmentDetails,
    };
  }

  void _scheduleRouteCachePersist() {
    _routeCachePersistDebounce?.cancel();
    _routeCachePersistDebounce = Timer(const Duration(milliseconds: 600), () {
      unawaited(_persistRouteCacheIfPossible());
    });
  }

  Future<void> _persistRouteCacheIfPossible() async {
    final me = _user;
    if (me == null) return;
    final tripRef = _resolveTripRefForView(me);
    final ownerUid = _ownerUidFromTripRefPath(tripRef.path);
    if (ownerUid != me.uid) return;

    final payload = _routeCachePayload();
    try {
      await tripRef.set(payload, SetOptions(merge: true));
      if (!mounted) return;
      setState(() => _liveData.addAll(payload));
    } catch (_) {
      // Route cache persistence is non-fatal.
    }
  }

  @override
  void initState() {
    super.initState();
    _mobileRouteSheetController.addListener(_handleMobileRouteSheetChanged);
    // Use a mutable local copy of the trip data. If this trip points to a
    // remote `tripRef`, subscribe to that document so the UI updates in
    // realtime when the owner makes changes.
    _liveData = Map<String, dynamic>.from(widget.data);
    final d = _liveData['totalDays'];
    if (d is num) _days = d.toInt();
    // copy waypoints into mutable list for editing
    final wAny = _liveData['waypoints'];
    final w = (wAny is List) ? wAny : const <dynamic>[];
    _waypoints =
        w.map<Map<String, dynamic>>((e) {
          if (e is Map<String, dynamic>) return Map<String, dynamic>.from(e);
          if (e is Map) {
            return Map<String, dynamic>.from(e.cast<String, dynamic>());
          }
          return <String, dynamic>{};
        }).toList();

    _transportMode = _normalizeTransportMode(
      ((_liveData['transportMode'] ?? 'driving') as Object?).toString(),
    );
    final viaAny = _liveData['routeVia'];
    final viaRaw = (viaAny is List) ? viaAny : const <dynamic>[];
    _routeVia =
        viaRaw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e.cast<String, dynamic>()))
            .toList();

    final segments = _waypoints.length > 1 ? _waypoints.length - 1 : 0;
    final segAny = _liveData['segmentRoutingTypes'];
    final segRaw = (segAny is List) ? segAny : const <dynamic>[];
    _segmentRoutingTypes = _coerceSegmentRoutingTypes(
      segRaw,
      segmentCount: segments,
    );
    final segModeAny = _liveData['segmentTransportModes'];
    final segModeRaw = (segModeAny is List) ? segModeAny : const <dynamic>[];
    _segmentTransportModes = _coerceSegmentTransportModes(
      segModeRaw,
      segmentCount: segments,
      fallbackMode: _transportMode,
    );
    final arrivalRaw = _liveData['transitArrivalStop'];
    if (arrivalRaw is Map) {
      _transitArrivalStop = Map<String, dynamic>.from(
        arrivalRaw.cast<String, dynamic>(),
      );
    }
    _syncSegmentDataWithWaypoints();
    _applyCachedRouteStateFromLiveData();

    // If we have a remote tripRef, listen for live updates and merge them
    // into `_liveData` so the UI updates when the owner edits the trip.
    try {
      final tripRefAny = _liveData['tripRef'] ?? widget.data['tripRef'];
      String? tripRefPath;
      if (tripRefAny is String) {
        tripRefPath = tripRefAny;
      } else if (tripRefAny is DocumentReference) {
        tripRefPath = tripRefAny.path;
      } else {
        final s = (tripRefAny as Object?)?.toString().trim();
        tripRefPath = (s == null || s.isEmpty) ? null : s;
      }
      if (tripRefPath != null && tripRefPath.isNotEmpty) {
        final docRef = FirebaseFirestore.instance.doc(tripRefPath);
        if (kDebugMode) {
          print('TripDetail: initial owner subscription -> $tripRefPath');
        }
        _currentSubscribedPath = tripRefPath;
        _docSub = docRef.snapshots().listen(
          (snapshot) {
            if (!snapshot.exists) {
              if (mounted) {
                ScaffoldMessenger.of(context).showTryprSnackBar(
                  const SnackBar(
                    content: Text('This trip was removed by the owner'),
                  ),
                );
              }
              return;
            }
            final remote = snapshot.data() ?? {};
            // Merge remote fields into _liveData but keep local metadata such as `tripRef` and `sharedFrom`.
            setState(() {
              _liveData.addAll(remote);
              // ensure tripRef remains
              _liveData['tripRef'] = tripRefPath;
              // update waypoints list for map and editing UI
              final rwAny = _liveData['waypoints'];
              final rw = (rwAny is List) ? rwAny : const <dynamic>[];
              _waypoints =
                  rw.map<Map<String, dynamic>>((e) {
                    if (e is Map<String, dynamic>) {
                      return Map<String, dynamic>.from(e);
                    }
                    if (e is Map) {
                      return Map<String, dynamic>.from(
                        e.cast<String, dynamic>(),
                      );
                    }
                    return <String, dynamic>{};
                  }).toList();
              // update days if present
              final td = _liveData['totalDays'];
              if (td is num) _days = td.toInt();

              _transportMode = _normalizeTransportMode(
                ((_liveData['transportMode'] ?? 'driving') as Object?)
                    .toString(),
              );
              final viaAny = _liveData['routeVia'];
              final viaRaw = (viaAny is List) ? viaAny : const <dynamic>[];
              _routeVia =
                  viaRaw
                      .whereType<Map>()
                      .map(
                        (e) => Map<String, dynamic>.from(
                          e.cast<String, dynamic>(),
                        ),
                      )
                      .toList();

              final segments =
                  _waypoints.length > 1 ? _waypoints.length - 1 : 0;
              final segAny = _liveData['segmentRoutingTypes'];
              final segRaw = (segAny is List) ? segAny : const <dynamic>[];
              _segmentRoutingTypes = _coerceSegmentRoutingTypes(
                segRaw,
                segmentCount: segments,
              );
              final segModeAny = _liveData['segmentTransportModes'];
              final segModeRaw =
                  (segModeAny is List) ? segModeAny : const <dynamic>[];
              _segmentTransportModes = _coerceSegmentTransportModes(
                segModeRaw,
                segmentCount: segments,
                fallbackMode: _transportMode,
              );
              final arrivalRaw = _liveData['transitArrivalStop'];
              if (arrivalRaw is Map) {
                _transitArrivalStop = Map<String, dynamic>.from(
                  arrivalRaw.cast<String, dynamic>(),
                );
              }
              _syncSegmentDataWithWaypoints();
              _applyCachedRouteStateFromLiveData();
            });
          },
          onError: (e) {
            // Swallow permission-denied or network errors on the realtime
            // listener so they don't crash the app with an unhandled exception.
            // ignore: avoid_print
            print('TripDetail: owner snapshot error: $e');
          },
        );
      }
    } catch (_) {}

    // Also subscribe to the local trip doc (the one inside the current user's `trips` collection)
    // This lets us detect when a `tripRef` is added or changed (for example after Accept).
    try {
      final me = _user;
      if (me != null) {
        final localRef = FirebaseFirestore.instance
            .collection('users')
            .doc(me.uid)
            .collection('trips')
            .doc(widget.docId);
        if (kDebugMode) {
          print('TripDetail: subscribing to local trip doc ${localRef.path}');
        }
        _localDocSub = localRef.snapshots().listen(
          (snap) {
            if (!snap.exists) return;
            final data = snap.data() ?? {};
            // If local doc now contains a tripRef and we are not yet subscribed to it, (re)subscribe.
            final newRefAny = data['tripRef'];
            final newRef =
                (newRefAny is String)
                    ? newRefAny
                    : (newRefAny is DocumentReference)
                    ? newRefAny.path
                    : (newRefAny as Object?)?.toString() ?? '';
            if (newRef.isNotEmpty && newRef != _currentSubscribedPath) {
              try {
                _docSub?.cancel();
                final ownerRef = FirebaseFirestore.instance.doc(newRef);
                if (kDebugMode) {
                  print('TripDetail: switching owner subscription -> $newRef');
                }
                _currentSubscribedPath = newRef;
                _docSub = ownerRef.snapshots().listen(
                  (snapshot) {
                    if (!snapshot.exists) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showTryprSnackBar(
                          const SnackBar(
                            content: Text('This trip was removed by the owner'),
                          ),
                        );
                      }
                      return;
                    }
                    final remote = snapshot.data() ?? {};
                    if (mounted) {
                      setState(() {
                        _liveData.addAll(remote);
                        _liveData['tripRef'] = newRef;
                        final rwAny = _liveData['waypoints'];
                        final rw = (rwAny is List) ? rwAny : const <dynamic>[];
                        _waypoints =
                            rw.map<Map<String, dynamic>>((e) {
                              if (e is Map<String, dynamic>) {
                                return Map<String, dynamic>.from(e);
                              }
                              if (e is Map) {
                                return Map<String, dynamic>.from(
                                  e.cast<String, dynamic>(),
                                );
                              }
                              return <String, dynamic>{};
                            }).toList();
                        final td = _liveData['totalDays'];
                        if (td is num) _days = td.toInt();

                        _transportMode = _normalizeTransportMode(
                          ((_liveData['transportMode'] ?? 'driving') as Object?)
                              .toString(),
                        );
                        final viaAny = _liveData['routeVia'];
                        final viaRaw =
                            (viaAny is List) ? viaAny : const <dynamic>[];
                        _routeVia =
                            viaRaw
                                .whereType<Map>()
                                .map(
                                  (e) => Map<String, dynamic>.from(
                                    e.cast<String, dynamic>(),
                                  ),
                                )
                                .toList();

                        final segments =
                            _waypoints.length > 1 ? _waypoints.length - 1 : 0;
                        final segAny = _liveData['segmentRoutingTypes'];
                        final segRaw =
                            (segAny is List) ? segAny : const <dynamic>[];
                        _segmentRoutingTypes = _coerceSegmentRoutingTypes(
                          segRaw,
                          segmentCount: segments,
                        );
                        final segModeAny = _liveData['segmentTransportModes'];
                        final segModeRaw =
                            (segModeAny is List)
                                ? segModeAny
                                : const <dynamic>[];
                        _segmentTransportModes = _coerceSegmentTransportModes(
                          segModeRaw,
                          segmentCount: segments,
                          fallbackMode: _transportMode,
                        );
                        final arrivalRaw = _liveData['transitArrivalStop'];
                        if (arrivalRaw is Map) {
                          _transitArrivalStop = Map<String, dynamic>.from(
                            arrivalRaw.cast<String, dynamic>(),
                          );
                        }
                        _syncSegmentDataWithWaypoints();
                        _applyCachedRouteStateFromLiveData();
                      });
                    }
                  },
                  onError: (e) {
                    // ignore: avoid_print
                    print('TripDetail: switched owner snapshot error: $e');
                  },
                );
              } catch (_) {}
            } else {
              // Merge local data to reflect user's own metadata quickly
              if (mounted) setState(() => _liveData.addAll(data));
            }
          },
          onError: (e) {
            // ignore: avoid_print
            print('TripDetail: local doc snapshot error: $e');
          },
        );
      }
    } catch (_) {}

    _searchController.addListener(() {
      final v = _searchController.text.trim();
      if (_debounce?.isActive ?? false) _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 400), () {
        if (v.isNotEmpty) {
          _searchPlaces(v);
        } else {
          setState(() => _placeSuggestions = []);
        }
      });
    });
  }

  // ignore: unused_element
  int _calculateDayCount(Map<String, dynamic> destination) {
    final startDate = destination['startDate'] as String? ?? '';
    final endDate = destination['endDate'] as String? ?? '';

    // Try to calculate from dates first
    if (startDate.isNotEmpty && endDate.isNotEmpty) {
      try {
        final start = DateTime.parse(startDate);
        final end = DateTime.parse(endDate);
        final days = end.difference(start).inDays + 1;
        return days > 0 ? days : 0;
      } catch (e) {
        // If parsing fails, fall back to itinerary count
      }
    }

    // Fall back to itinerary count
    return (destination['itinerary'] as List?)?.length ?? 0;
  }

  String? _tripRefPathFromAny(dynamic raw) {
    if (raw is String) {
      final value = raw.trim();
      return value.isEmpty ? null : value;
    }
    if (raw is DocumentReference) return raw.path;
    final value = raw?.toString().trim();
    if (value == null || value.isEmpty) return null;
    return value;
  }

  String? _currentTripRefPath() {
    return _tripRefPathFromAny(_liveData['tripRef'] ?? widget.data['tripRef']);
  }

  List<dynamic> _sharedWithList() {
    final raw = _liveData['sharedWith'] ?? widget.data['sharedWith'];
    return raw is List ? raw : const <dynamic>[];
  }

  DocumentReference<Map<String, dynamic>> _resolveTripRefForView(User me) {
    final refPath = _currentTripRefPath();
    if (refPath != null && refPath.isNotEmpty) {
      return FirebaseFirestore.instance.doc(refPath);
    }
    return FirebaseFirestore.instance
        .collection('users')
        .doc(me.uid)
        .collection('trips')
        .doc(widget.docId);
  }

  String _ownerUidFromTripRefPath(String path) {
    try {
      final p = path.split('/');
      if (p.length >= 2 && p[0] == 'users') return p[1];
    } catch (_) {}
    return '';
  }

  Future<void> _setTransportMode(String mode) async {
    final me = _user;
    if (me == null) return;
    final normalized = _normalizeTransportMode(mode);
    final segments = _waypoints.length > 1 ? _waypoints.length - 1 : 0;
    final updatedModes = List<String>.filled(segments, normalized);
    final updatedRouteVia =
        normalized == 'transit' ? <Map<String, dynamic>>[] : _routeVia;

    setState(() {
      _transportMode = normalized;
      _segmentTransportModes = updatedModes;
      _routeVia = updatedRouteVia;
      _routeInstructions = const [];
      _routeGeometry3d = const [];
      _routeSegmentDetails = const [];
      _focusedTransitStep = null;
      if (!_hasTransitModeInRoute) {
        _transitArrivalStop = null;
      }
    });

    final tripRef = _resolveTripRefForView(me);
    final ownerUid = _ownerUidFromTripRefPath(tripRef.path);
    if (ownerUid != me.uid) return;

    try {
      await tripRef.update({
        'transportMode': normalized,
        'segmentTransportModes': updatedModes,
        'routeVia': updatedRouteVia,
        'requires_gear_list': _requiresGearListForModes(
          updatedModes,
          normalized,
        ),
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showTryprSnackBar(
          SnackBar(content: Text('Failed to update mode: $e')),
        );
      }
    }
  }

  Future<void> _upsertViaPoint({
    required int afterIndex,
    required double lat,
    required double lon,
  }) async {
    final me = _user;
    if (me == null) return;

    final tripRef = _resolveTripRefForView(me);
    final ownerUid = _ownerUidFromTripRefPath(tripRef.path);
    if (ownerUid != me.uid) return;

    final updated = List<Map<String, dynamic>>.from(_routeVia);
    final next = {'afterIndex': afterIndex, 'lat': lat, 'lon': lon};

    // Allow multiple route corrections between the same two primary points.
    // Insert the new via point after existing vias for this segment (or keep
    // the list roughly grouped by `afterIndex` when none exist yet).
    var insertAt = -1;
    for (var i = 0; i < updated.length; i++) {
      final ai = (updated[i]['afterIndex'] as num?)?.toInt() ?? -1;
      if (ai == afterIndex) {
        insertAt = i;
      }
    }

    if (insertAt >= 0) {
      updated.insert(insertAt + 1, next);
    } else {
      var lastBefore = -1;
      for (var i = 0; i < updated.length; i++) {
        final ai = (updated[i]['afterIndex'] as num?)?.toInt() ?? -1;
        if (ai <= afterIndex) {
          lastBefore = i;
        }
      }
      updated.insert(lastBefore + 1, next);
    }

    setState(() => _routeVia = updated);
    try {
      await tripRef.update({'routeVia': updated});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showTryprSnackBar(
          SnackBar(content: Text('Failed to update route: $e')),
        );
      }
    }
  }

  Future<void> _setSegmentRoutingType(int segmentIndex, String type) async {
    final me = _user;
    if (me == null) return;

    final tripRef = _resolveTripRefForView(me);
    final ownerUid = _ownerUidFromTripRefPath(tripRef.path);
    if (ownerUid != me.uid) return;

    final normalized =
        type.trim().toLowerCase() == 'direct' ? 'direct' : 'calculated';

    final segments = _waypoints.length - 1;
    final desiredLen = segments < 0 ? 0 : segments;

    final updated = List<String>.from(_segmentRoutingTypes);
    if (updated.length > desiredLen) {
      updated.removeRange(desiredLen, updated.length);
    }
    while (updated.length < desiredLen) {
      updated.add('calculated');
    }
    if (segmentIndex < 0 || segmentIndex >= updated.length) return;
    updated[segmentIndex] = normalized;

    setState(() => _segmentRoutingTypes = updated);
    try {
      await tripRef.update({'segmentRoutingTypes': updated});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showTryprSnackBar(
          SnackBar(content: Text('Failed to update routing type: $e')),
        );
      }
    }
  }

  Future<void> _setSegmentTransportMode(int segmentIndex, String mode) async {
    final me = _user;
    if (me == null) return;

    final tripRef = _resolveTripRefForView(me);
    final ownerUid = _ownerUidFromTripRefPath(tripRef.path);
    if (ownerUid != me.uid) return;

    final normalized = _normalizeTransportMode(mode);
    final segments = _waypoints.length > 1 ? _waypoints.length - 1 : 0;
    final updated = _coerceSegmentTransportModes(
      _segmentTransportModes,
      segmentCount: segments,
      fallbackMode: _transportMode,
    );
    if (segmentIndex < 0 || segmentIndex >= updated.length) return;
    updated[segmentIndex] = normalized;
    final nextRouteVia =
        normalized == 'transit'
            ? _routeVia.where((v) {
              final after = (v['afterIndex'] as num?)?.toInt();
              return after != segmentIndex;
            }).toList()
            : _routeVia;

    setState(() {
      _segmentTransportModes = updated;
      _routeVia = nextRouteVia;
      _routeInstructions = const [];
      _routeGeometry3d = const [];
      _routeSegmentDetails = const [];
      _focusedTransitStep = null;
      if (!_hasTransitModeInRoute) {
        _transitArrivalStop = null;
      }
    });

    try {
      await tripRef.update({
        'segmentTransportModes': updated,
        'routeVia': nextRouteVia,
        'requires_gear_list': _requiresGearListForModes(
          updated,
          _transportMode,
        ),
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showTryprSnackBar(
          SnackBar(content: Text('Failed to update segment mode: $e')),
        );
      }
    }
  }

  Future<void> _persistTransitArrivalStop(Map<String, dynamic> stop) async {
    final me = _user;
    if (me == null) return;
    final tripRef = _resolveTripRefForView(me);
    final ownerUid = _ownerUidFromTripRefPath(tripRef.path);
    if (ownerUid != me.uid) return;

    try {
      if (stop.isEmpty) {
        await tripRef.update({'transitArrivalStop': FieldValue.delete()});
      } else {
        await tripRef.update({'transitArrivalStop': stop});
      }
    } catch (_) {
      // non-fatal
    }
  }

  Future<void> _moveViaPoint({
    required int viaIndex,
    required double lat,
    required double lon,
  }) async {
    final me = _user;
    if (me == null) return;

    final tripRef = _resolveTripRefForView(me);
    final ownerUid = _ownerUidFromTripRefPath(tripRef.path);
    if (ownerUid != me.uid) return;

    final updated = List<Map<String, dynamic>>.from(_routeVia);
    if (viaIndex < 0 || viaIndex >= updated.length) return;
    final old = updated[viaIndex];
    updated[viaIndex] = {
      'afterIndex': (old['afterIndex'] as num?)?.toInt() ?? 0,
      'lat': lat,
      'lon': lon,
    };

    setState(() => _routeVia = updated);
    try {
      await tripRef.update({'routeVia': updated});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showTryprSnackBar(
          SnackBar(content: Text('Failed to update route: $e')),
        );
      }
    }
  }

  Future<void> _deleteViaPoint({required int viaIndex}) async {
    final me = _user;
    if (me == null) return;

    final tripRef = _resolveTripRefForView(me);
    final ownerUid = _ownerUidFromTripRefPath(tripRef.path);
    if (ownerUid != me.uid) return;

    final updated = List<Map<String, dynamic>>.from(_routeVia);
    if (viaIndex < 0 || viaIndex >= updated.length) return;
    updated.removeAt(viaIndex);

    setState(() => _routeVia = updated);
    try {
      await tripRef.update({'routeVia': updated});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showTryprSnackBar(
          SnackBar(content: Text('Failed to update route: $e')),
        );
      }
    }
  }

  Future<void> _shareTrip() async {
    final me = _user;
    if (me == null) return;

    // Determine tripRef path
    final refPath = _currentTripRefPath();
    final String tripRefPath;
    if (refPath != null && refPath.isNotEmpty) {
      tripRefPath = refPath;
    } else {
      tripRefPath = 'users/${me.uid}/trips/${widget.docId}';
    }

    final tripName =
        (_liveData['name'] ?? widget.data['name'] ?? '').toString();

    await _withMapTapSuspended(
      () => ShareTripDialog.show(
        context,
        tripRefPath: tripRefPath,
        tripId: widget.docId,
        tripName: tripName,
      ),
    );
  }

  @override
  void dispose() {
    _mobileRouteSheetController.removeListener(_handleMobileRouteSheetChanged);
    _mobileRouteSheetController.dispose();
    _searchController.dispose();
    _debounce?.cancel();
    _routeCachePersistDebounce?.cancel();
    _docSub?.cancel();
    _localDocSub?.cancel();
    super.dispose();
  }

  Future<void> _searchPlaces(String query) async {
    final q = query.trim();
    if (q.isEmpty) {
      if (mounted) {
        setState(() {
          _placeSuggestions = [];
          _searchingPlaces = false;
        });
      }
      return;
    }

    setState(() {
      _searchingPlaces = true;
    });
    try {
      final list = await searchNominatim(q);
      if (!mounted) return;
      setState(() => _placeSuggestions = list.take(6).toList());
    } catch (_) {
      setState(() => _placeSuggestions = []);
    } finally {
      if (mounted) setState(() => _searchingPlaces = false);
    }
  }

  Future<void> _saveDays() async {
    final u = _user;
    if (u == null) return;
    setState(() => _saving = true);
    try {
      // If this trip was opened from a shared tripRef, write back to that ref so edits sync to owner
      DocumentReference<Map<String, dynamic>> targetRef;
      final targetPath = _currentTripRefPath();
      if (targetPath != null && targetPath.isNotEmpty) {
        targetRef = FirebaseFirestore.instance.doc(targetPath);
      } else {
        targetRef = FirebaseFirestore.instance
            .collection('users')
            .doc(u.uid)
            .collection('trips')
            .doc(widget.docId);
      }

      final segmentCount = _waypoints.length > 1 ? _waypoints.length - 1 : 0;
      final nextSegmentRouting = _coerceSegmentRoutingTypes(
        _segmentRoutingTypes,
        segmentCount: segmentCount,
      );
      final nextSegmentModes = _coerceSegmentTransportModes(
        _segmentTransportModes,
        segmentCount: segmentCount,
        fallbackMode: _transportMode,
      );
      final nextRouteVia =
          _routeVia
              .where((v) {
                final after = (v['afterIndex'] as num?)?.toInt();
                return after != null && after >= 0 && after < segmentCount;
              })
              .map((v) => Map<String, dynamic>.from(v))
              .toList();
      final syncedWaypoints = _syncedWaypointsForSave();
      setState(() {
        _waypoints = syncedWaypoints;
        _syncLiveWaypointsFromState();
        _segmentRoutingTypes = nextSegmentRouting;
        _segmentTransportModes = nextSegmentModes;
        _routeVia = nextRouteVia;
      });

      await targetRef.update({
        'totalDays': _days,
        'waypoints': syncedWaypoints,
        'segmentRoutingTypes': nextSegmentRouting,
        'segmentTransportModes': nextSegmentModes,
        'routeVia': nextRouteVia,
        'requires_gear_list': _requiresGearListForModes(
          nextSegmentModes,
          _transportMode,
        ),
      });
      ScaffoldMessenger.of(
        context,
      ).showTryprSnackBar(const SnackBar(content: Text('Saved')));
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showTryprSnackBar(SnackBar(content: Text('Save failed: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveAll() async {
    // same as _saveDays but used when editing waypoints too
    await _saveDays();
    if (mounted) setState(() => _editing = false);
  }

  Future<void> _openPackingList() async {
    final me = _user;
    if (me == null) return;
    DocumentReference<Map<String, dynamic>> tripRef;
    final refPath = _currentTripRefPath();
    if (refPath != null && refPath.isNotEmpty) {
      tripRef = FirebaseFirestore.instance.doc(refPath);
    } else {
      tripRef = FirebaseFirestore.instance
          .collection('users')
          .doc(me.uid)
          .collection('trips')
          .doc(widget.docId);
    }
    // Build a list of participant UIDs: owner (if available), sharedWith, and current user
    List<String> collectParticipants() {
      final parts = <String>{};
      // If tripRef is a path like users/{owner}/trips/{id}, extract owner
      try {
        final p = tripRef.path.split('/');
        if (p.length >= 2 && p[0] == 'users') {
          parts.add(p[1]);
        }
      } catch (_) {}
      final shared = _sharedWithList();
      for (final s in shared) {
        try {
          parts.add(s.toString());
        } catch (_) {}
      }
      if (me.uid.isNotEmpty) parts.add(me.uid);
      return parts.toList();
    }

    final nameCache = <String, String>{};

    final participants = collectParticipants();
    await ensureNameCache(
      nameCache,
      participants,
      currentUidForFriendsFallback: me.uid,
    );

    await _withMapTapSuspended(
      () => showDialog<void>(
        context: context,
        builder: (ctx) {
          String scopeView = 'group'; // 'group' or 'private'
          final addCtl = TextEditingController();
          final qtyCtl = TextEditingController(text: '1');
          String? addAssignee;

          return StatefulBuilder(
            builder: (ctx2, setState2) {
              final dialogHeight =
                  (MediaQuery.sizeOf(ctx2).height * 0.8)
                      .clamp(360.0, 620.0)
                      .toDouble();
              return AlertDialog(
                title: const Text('Packing list'),
                content: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: SizedBox(
                    width: double.maxFinite,
                    height: dialogHeight,
                    child: Column(
                      children: [
                        Row(
                          children: [
                            ChoiceChip(
                              label: const Text('Group'),
                              selected: scopeView == 'group',
                              onSelected:
                                  (v) => setState2(() => scopeView = 'group'),
                            ),
                            const SizedBox(width: 8),
                            ChoiceChip(
                              label: const Text('Private'),
                              selected: scopeView == 'private',
                              onSelected:
                                  (v) => setState2(() => scopeView = 'private'),
                            ),
                            const Spacer(),
                            Text('Participants: ${participants.length}'),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: StreamBuilder<
                            QuerySnapshot<Map<String, dynamic>>
                          >(
                            stream:
                                tripRef
                                    .collection('packing')
                                    .orderBy('createdAt')
                                    .snapshots(),
                            builder: (ctx3, snap) {
                              if (!snap.hasData) {
                                return const Center(
                                  child: CircularProgressIndicator(),
                                );
                              }
                              final docs = snap.data!.docs;
                              final visible =
                                  docs.where((d) {
                                    final data = d.data();
                                    final pTo = data['privateTo'];
                                    if (scopeView == 'group') {
                                      return pTo == null;
                                    }
                                    return pTo != null && pTo == me.uid;
                                  }).toList();
                              if (visible.isEmpty) {
                                return const Center(
                                  child: Text('No packing items'),
                                );
                              }
                              return ListView.separated(
                                itemCount: visible.length,
                                separatorBuilder:
                                    (_, __) => const Divider(height: 1),
                                itemBuilder: (ctx4, i) {
                                  final d = visible[i];
                                  final data = d.data();
                                  final name = (data['name'] ?? '').toString();
                                  final emojiRaw =
                                      (data['emoji'] ?? '').toString();
                                  final emoji =
                                      emojiRaw.isNotEmpty
                                          ? emojiRaw
                                          : _emojiForPackingItem(name);
                                  final qtyRaw = data['quantity'];
                                  final qty =
                                      (qtyRaw is num)
                                          ? qtyRaw.toInt()
                                          : (int.tryParse(
                                                qtyRaw?.toString() ?? '',
                                              ) ??
                                              1);
                                  final checkedBy = List<String>.from(
                                    data['checkedBy'] ?? [],
                                  );
                                  final checked = checkedBy.contains(me.uid);
                                  final assignee =
                                      (data['assigneeUid'] ?? '').toString();
                                  final privateToRaw = data['privateTo'];
                                  final privateTo = privateToRaw?.toString();
                                  final canEdit =
                                      (scopeView == 'group') ||
                                      (privateTo == me.uid);
                                  final assigneeName =
                                      assignee.isNotEmpty
                                          ? (nameCache[assignee] ?? assignee)
                                          : '';

                                  return CheckboxListTile(
                                    value: checked,
                                    onChanged: (v) async {
                                      if (v == true) {
                                        await d.reference.update({
                                          'checkedBy': FieldValue.arrayUnion([
                                            me.uid,
                                          ]),
                                        });
                                      } else {
                                        await d.reference.update({
                                          'checkedBy': FieldValue.arrayRemove([
                                            me.uid,
                                          ]),
                                        });
                                      }
                                    },
                                    title: Row(
                                      children: [
                                        Text(
                                          emoji,
                                          style: const TextStyle(fontSize: 18),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(child: Text(name)),
                                        if (qty > 1)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              left: 8.0,
                                            ),
                                            child: Chip(label: Text('x$qty')),
                                          ),
                                        if (assigneeName.isNotEmpty)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              left: 8.0,
                                            ),
                                            child: Chip(
                                              label: Text(assigneeName),
                                            ),
                                          ),
                                      ],
                                    ),
                                    subtitle:
                                        canEdit
                                            ? Row(
                                              children: [
                                                TextButton.icon(
                                                  onPressed: () async {
                                                    // open assignee editor
                                                    final chosen = await _withMapTapSuspended(
                                                      () => showDialog<String?>(
                                                        context: ctx2,
                                                        builder: (ctx3) {
                                                          String? sel =
                                                              assignee.isNotEmpty
                                                                  ? assignee
                                                                  : null;
                                                          return AlertDialog(
                                                            title: const Text(
                                                              'Assign item',
                                                            ),
                                                            content: SizedBox(
                                                              width: 360,
                                                              child: StatefulBuilder(
                                                                builder: (
                                                                  ctx4,
                                                                  setState4,
                                                                ) {
                                                                  return Column(
                                                                    mainAxisSize:
                                                                        MainAxisSize
                                                                            .min,
                                                                    children: [
                                                                      DropdownButton<
                                                                        String?
                                                                      >(
                                                                        value:
                                                                            sel,
                                                                        hint: const Text(
                                                                          'Unassigned',
                                                                        ),
                                                                        isExpanded:
                                                                            true,
                                                                        items: [
                                                                          const DropdownMenuItem<
                                                                            String?
                                                                          >(
                                                                            value:
                                                                                null,
                                                                            child: Text(
                                                                              'Unassigned',
                                                                            ),
                                                                          ),
                                                                          ...participants.map(
                                                                            (
                                                                              u,
                                                                            ) => DropdownMenuItem(
                                                                              value:
                                                                                  u,
                                                                              child: Text(
                                                                                nameCache[u] ??
                                                                                    u,
                                                                              ),
                                                                            ),
                                                                          ),
                                                                        ],
                                                                        onChanged:
                                                                            (
                                                                              v,
                                                                            ) => setState4(
                                                                              () =>
                                                                                  sel =
                                                                                      v,
                                                                            ),
                                                                      ),
                                                                    ],
                                                                  );
                                                                },
                                                              ),
                                                            ),
                                                            actions: [
                                                              TextButton(
                                                                onPressed:
                                                                    () =>
                                                                        Navigator.of(
                                                                          ctx3,
                                                                        ).pop(
                                                                          null,
                                                                        ),
                                                                child:
                                                                    const Text(
                                                                      'Cancel',
                                                                    ),
                                                              ),
                                                              TextButton(
                                                                onPressed:
                                                                    () =>
                                                                        Navigator.of(
                                                                          ctx3,
                                                                        ).pop(
                                                                          sel,
                                                                        ),
                                                                child:
                                                                    const Text(
                                                                      'Save',
                                                                    ),
                                                              ),
                                                            ],
                                                          );
                                                        },
                                                      ),
                                                    );
                                                    if (chosen != null) {
                                                      await d.reference.update({
                                                        'assigneeUid': chosen,
                                                      });
                                                      if (mounted) {
                                                        setState2(() {});
                                                      }
                                                    }
                                                  },
                                                  icon: const Icon(
                                                    Icons.person_outline,
                                                  ),
                                                  label: Text(
                                                    assigneeName.isNotEmpty
                                                        ? 'Assigned: $assigneeName'
                                                        : 'Assign',
                                                  ),
                                                ),
                                              ],
                                            )
                                            : null,
                                  );
                                },
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: addCtl,
                                decoration: const InputDecoration(
                                  hintText: 'Add item',
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 92,
                              child: TextField(
                                controller: qtyCtl,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  hintText: 'Qty',
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            DropdownButton<String?>(
                              value: addAssignee,
                              hint: const Text('Assignee'),
                              items: [
                                const DropdownMenuItem<String?>(
                                  value: null,
                                  child: Text('Unassigned'),
                                ),
                                ...participants.map(
                                  (u) => DropdownMenuItem<String?>(
                                    value: u,
                                    child: Text(nameCache[u] ?? u),
                                  ),
                                ),
                              ],
                              onChanged:
                                  (v) => setState2(() => addAssignee = v),
                            ),
                            const SizedBox(width: 8),
                            ElevatedButton(
                              onPressed: () async {
                                final t = addCtl.text.trim();
                                if (t.isEmpty) return;
                                final q = int.tryParse(qtyCtl.text.trim());
                                final data = <String, dynamic>{
                                  'name': t,
                                  'emoji': _emojiForPackingItem(t),
                                  'createdAt': FieldValue.serverTimestamp(),
                                  'checkedBy': [],
                                };
                                if (q != null && q > 1) {
                                  data['quantity'] = q;
                                }
                                if (scopeView == 'private') {
                                  data['privateTo'] = me.uid;
                                }
                                if (addAssignee != null) {
                                  data['assigneeUid'] = addAssignee;
                                  data['assigneeName'] =
                                      nameCache[addAssignee] ?? addAssignee;
                                }
                                if (kDebugMode) {
                                  print(
                                    'Packing add -> target: ${tripRef.path} data: $data',
                                  );
                                }
                                await tripRef.collection('packing').add(data);
                                addCtl.clear();
                                qtyCtl.text = '1';
                                addAssignee = null;
                                if (mounted) setState2(() {});
                              },
                              child: const Text('Add'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('Close'),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _openTripChat() async {
    final me = _user;
    if (me == null) return;
    DocumentReference<Map<String, dynamic>> tripRef;
    final refPath = _currentTripRefPath();
    if (refPath != null && refPath.isNotEmpty) {
      tripRef = FirebaseFirestore.instance.doc(refPath);
    } else {
      tripRef = FirebaseFirestore.instance
          .collection('users')
          .doc(me.uid)
          .collection('trips')
          .doc(widget.docId);
    }
    await _withMapTapSuspended(
      () => TripChatDialog.show(context: context, tripRef: tripRef, me: me),
    );
  }

  Future<void> _openExpensesDialog() async {
    final me = _user;
    if (me == null) return;

    DocumentReference<Map<String, dynamic>> tripRef;
    final refPath = _currentTripRefPath();
    if (refPath != null && refPath.isNotEmpty) {
      tripRef = FirebaseFirestore.instance.doc(refPath);
    } else {
      tripRef = FirebaseFirestore.instance
          .collection('users')
          .doc(me.uid)
          .collection('trips')
          .doc(widget.docId);
    }

    List<String> collectParticipants() {
      final parts = <String>{};
      try {
        final p = tripRef.path.split('/');
        if (p.length >= 2 && p[0] == 'users') {
          parts.add(p[1]);
        }
      } catch (_) {}

      final shared = _sharedWithList();
      for (final s in shared) {
        try {
          parts.add(s.toString());
        } catch (_) {}
      }

      if (me.uid.isNotEmpty) parts.add(me.uid);
      return parts.toList();
    }

    await _withMapTapSuspended(
      () => TripExpensesDialog.show(
        context: context,
        tripRef: tripRef,
        currentUid: me.uid,
        participants: collectParticipants(),
      ),
    );
  }

  void _toggleEditing() {
    setState(() => _editing = !_editing);
  }

  void _addWaypointFromTap(double lat, double lon) async {
    setState(() {
      final idx = _waypoints.length + 1;
      _waypoints.add({
        'lat': lat,
        'lon': lon,
        'name': 'Point $idx',
        'isStop': false,
        'nights': 0,
      });
      _syncSegmentDataWithWaypoints();
      _syncLiveWaypointsFromState();
    });
  }

  /// Open the unified Trip Planning Workspace.
  /// [focusWaypointIndex] scrolls the itinerary to the first day at that stop.
  Future<void> _openTripPlanning({
    int? focusWaypointIndex,
    int initialTab = 0,
  }) async {
    String tripRefPath = _currentTripRefPath() ?? '';
    if (tripRefPath.isEmpty) {
      final user = _user;
      if (user == null) {
        ScaffoldMessenger.of(
          context,
        ).showTryprSnackBar(const SnackBar(content: Text('Not logged in')));
        return;
      }
      tripRefPath = 'users/${user.uid}/trips/${widget.docId}';
    }

    // Compute which day to focus on based on the waypoint's startDate
    int? focusDayIndex;
    if (focusWaypointIndex != null && focusWaypointIndex < _waypoints.length) {
      final wpStart =
          (_waypoints[focusWaypointIndex]['startDate'] ?? '').toString();
      final tripStart = (_liveData['startDate'] ?? '').toString();
      if (wpStart.isNotEmpty && tripStart.isNotEmpty) {
        try {
          final ws = DateTime.parse(wpStart);
          final ts = DateTime.parse(tripStart);
          focusDayIndex = ws.difference(ts).inDays;
          if (focusDayIndex < 0) focusDayIndex = 0;
        } catch (_) {}
      }
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (_) => TripPlanningScreen(
              tripId: widget.docId,
              tripRefPath: tripRefPath,
              tripData: Map<String, dynamic>.from(_liveData),
              initialTab: initialTab,
              focusDayIndex: focusDayIndex,
            ),
      ),
    );
  }

  Future<void> _openDestinationDetail(
    int index,
    Map<String, dynamic> destination, {
    int initialTabIndex = 0,
    int? initialDayIndex,
  }) async {
    // Initialize destination data structure if not present
    final dest = Map<String, dynamic>.from(destination);
    dest['accommodations'] ??= [];
    dest['itinerary'] ??= [];
    dest['things_to_do'] ??= [];
    dest['startDate'] ??= '';
    dest['endDate'] ??= '';

    // Determine trip reference path: use explicit tripRef if available,
    // otherwise construct path for personal trip
    String tripRefPath = _currentTripRefPath() ?? '';

    if (tripRefPath.isEmpty) {
      // For personal trips, construct the path from user ID and trip ID
      final user = _user;
      if (user == null) {
        ScaffoldMessenger.of(
          context,
        ).showTryprSnackBar(const SnackBar(content: Text('Not logged in')));
        return;
      }
      tripRefPath = 'users/${user.uid}/trips/${widget.docId}';
    }

    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder:
            (_) => DestinationDetailScreen(
              tripId: widget.docId,
              destinationIndex: index,
              destination: dest,
              tripRef: tripRefPath,
              userId: _user?.uid ?? '',
              initialTabIndex: initialTabIndex,
              initialDayIndex: initialDayIndex,
            ),
      ),
    );

    // Refresh waypoints if destination was updated
    if (result != null && mounted) {
      setState(() {
        if (index >= 0 && index < _waypoints.length) {
          _waypoints[index] = result;
          _syncLiveWaypointsFromState();
        }
      });
    }
  }

  Future<void> _editWaypointDialog(int index) async {
    // Provide a search/autocomplete UI when editing a waypoint so users
    // don't have to touch raw coordinates. Selecting a suggestion updates
    // both name and lat/lon. If the user prefers just renaming, they can
    // type a new name and press Save.
    final current = Map<String, dynamic>.from(_waypoints[index]);
    final localNameCtrl = TextEditingController(
      text: current['name']?.toString() ?? '',
    );
    final searchCtrl = TextEditingController();
    Timer? localDebounce;
    List<Map<String, dynamic>> localSuggestions = [];
    bool localLoading = false;

    Future<void> doSearch(String q) async {
      final query = q.trim();
      if (query.isEmpty) {
        localSuggestions = [];
        if (mounted) setState(() {});
        return;
      }
      localLoading = true;
      if (mounted) setState(() {});
      try {
        final list = await searchNominatim(query);
        localSuggestions = list.take(6).toList();
      } catch (_) {
        localSuggestions = [];
      } finally {
        localLoading = false;
        if (mounted) setState(() {});
      }
    }

    final res = await _withMapTapSuspended(
      () => showDialog<bool>(
        context: context,
        builder: (ctx) {
          return StatefulBuilder(
            builder: (ctx2, setStateDialog) {
              return AlertDialog(
                title: const Text('Edit waypoint'),
                content: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: SizedBox(
                    width: double.maxFinite,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Name field (allows quick rename)
                        TextField(
                          controller: localNameCtrl,
                          decoration: const InputDecoration(labelText: 'Name'),
                        ),
                        const SizedBox(height: 8),
                        // Search box for picking a place (updates coords automatically)
                        TextField(
                          controller: searchCtrl,
                          decoration: InputDecoration(
                            prefixIcon: const Icon(Icons.search),
                            hintText: 'Search place to update location',
                            suffix:
                                localLoading
                                    ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                    : null,
                          ),
                          onChanged: (v) {
                            if (localDebounce?.isActive ?? false) {
                              localDebounce?.cancel();
                            }
                            localDebounce = Timer(
                              const Duration(milliseconds: 350),
                              () async {
                                await doSearch(v);
                                setStateDialog(() {});
                              },
                            );
                          },
                        ),
                        if (localSuggestions.isNotEmpty)
                          Container(
                            constraints: const BoxConstraints(maxHeight: 200),
                            margin: const EdgeInsets.only(top: 8),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              border: Border.all(color: Colors.grey.shade300),
                              borderRadius: BorderRadius.circular(8),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.06),
                                  blurRadius: 8,
                                ),
                              ],
                            ),
                            child: ListView.builder(
                              shrinkWrap: true,
                              itemCount: localSuggestions.length,
                              itemBuilder: (sctx, i) {
                                final p = localSuggestions[i];
                                final display =
                                    (p['display_name'] ?? '') as String;
                                return ListTile(
                                  title: Text(
                                    display,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onTap: () {
                                    final lat =
                                        double.tryParse(
                                          (p['lat'] ?? '').toString(),
                                        ) ??
                                        current['lat'] ??
                                        0.0;
                                    final lon =
                                        double.tryParse(
                                          (p['lon'] ?? '').toString(),
                                        ) ??
                                        current['lon'] ??
                                        0.0;
                                    // update waypoint immediately and close
                                    _waypoints[index]['name'] = display;
                                    _waypoints[index]['routing_query'] =
                                        display;
                                    _waypoints[index]['lat'] = lat;
                                    _waypoints[index]['lon'] = lon;
                                    _syncLiveWaypointsFromState();
                                    if (mounted) setState(() {});
                                    Navigator.of(ctx).pop(true);
                                  },
                                );
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () {
                      localDebounce?.cancel();
                      Navigator.of(ctx).pop(false);
                    },
                    child: const Text('Cancel'),
                  ),
                  ElevatedButton(
                    onPressed: () {
                      // If user changed just the name, update that and close
                      _waypoints[index]['name'] = localNameCtrl.text;
                      _syncLiveWaypointsFromState();
                      localDebounce?.cancel();
                      Navigator.of(ctx).pop(true);
                    },
                    child: const Text('Save'),
                  ),
                ],
              );
            },
          );
        },
      ),
    );

    // Clean up any local debounce timer
    // (if dialog closed via selection, localDebounce may already be cancelled)
    try {
      localDebounce?.cancel();
    } catch (_) {}

    if (res == true) {
      if (mounted) setState(() {});
    }
  }

  void _removeWaypoint(int index) {
    setState(() {
      _waypoints.removeAt(index);
      _syncSegmentDataWithWaypoints();
      _syncLiveWaypointsFromState();
    });
  }

  Widget _webSafeMenuItemText(String text) {
    final t = Text(text);
    if (!kIsWeb) return t;
    return WebInterceptor(
      child: Container(
        width: double.infinity,
        alignment: Alignment.centerLeft,
        child: t,
      ),
    );
  }

  String _segmentTypeAt(int segmentIndex) {
    if (segmentIndex < 0) return 'calculated';
    if (segmentIndex >= _segmentRoutingTypes.length) return 'calculated';
    final v = _segmentRoutingTypes[segmentIndex].trim().toLowerCase();
    return v == 'direct' ? 'direct' : 'calculated';
  }

  Future<void> _clearRouteCorrections({required bool canWriteTrip}) async {
    if (!canWriteTrip) return;
    final me = _user;
    if (me == null) return;

    final tripRef = _resolveTripRefForView(me);
    final ownerUid = _ownerUidFromTripRefPath(tripRef.path);
    if (ownerUid != me.uid) return;

    setState(() {
      _routeVia = const [];
      _routeInstructions = const [];
      _routeGeometry3d = const [];
      _routeSegmentDetails = const [];
    });
    try {
      await tripRef.update({'routeVia': []});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showTryprSnackBar(
          SnackBar(content: Text('Failed to clear corrections: $e')),
        );
      }
    }
  }

  Future<void> _openDirectionsDialog() async {
    await _withMapTapSuspended(
      () => showDialog<void>(
        context: context,
        builder: (ctx) {
          final isTransit = _hasTransitModeInRoute;
          final arrivalName =
              (_transitArrivalStop?['name'] ?? _transitArrivalStop?['label'])
                  ?.toString()
                  .trim();
          final arrivalLine =
              (arrivalName != null && arrivalName.isNotEmpty)
                  ? 'Arrive at: $arrivalName'
                  : null;
          final lines = _routeInstructions;

          final dialogHeight =
              (MediaQuery.sizeOf(ctx).height * 0.75)
                  .clamp(320.0, 640.0)
                  .toDouble();

          return AlertDialog(
            title: const Text('Directions'),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: SizedBox(
                width: double.maxFinite,
                height: dialogHeight,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (isTransit && arrivalLine != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8.0),
                        child: Text(
                          arrivalLine,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            color: Colors.black87,
                          ),
                        ),
                      ),
                    Expanded(
                      child:
                          lines.isEmpty
                              ? const Center(
                                child: Text(
                                  'No directions yet. Add stops or wait for routing to load.',
                                ),
                              )
                              : ListView.separated(
                                itemCount: lines.length,
                                separatorBuilder:
                                    (_, __) => const Divider(height: 1),
                                itemBuilder: (ctx2, i) {
                                  final s = lines[i];
                                  return ListTile(
                                    dense: true,
                                    leading: Text(
                                      '${i + 1}',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    title: Text(s),
                                  );
                                },
                              ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Close'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _openSegmentRoutingDialog({required bool canWriteTrip}) async {
    if (!canWriteTrip) return;
    final segments = _waypoints.length - 1;
    if (segments <= 0) return;

    await _withMapTapSuspended(
      () => showDialog<void>(
        context: context,
        builder: (ctx) {
          return StatefulBuilder(
            builder: (ctx2, setState2) {
              final dialogHeight =
                  (MediaQuery.sizeOf(ctx2).height * 0.75)
                      .clamp(320.0, 680.0)
                      .toDouble();

              return AlertDialog(
                title: const Text('Segment settings'),
                content: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: SizedBox(
                    width: double.maxFinite,
                    height: dialogHeight,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Set travel mode per leg. Calculated follows roads/trails; Direct draws a straight line.',
                          style: TextStyle(color: Colors.black54),
                        ),
                        const SizedBox(height: 10),
                        Expanded(
                          child: ListView.separated(
                            itemCount: segments,
                            separatorBuilder:
                                (_, __) => const Divider(height: 1),
                            itemBuilder: (ctx3, i) {
                              final a =
                                  (_waypoints[i]['name'] ?? 'Stop ${i + 1}')
                                      .toString();
                              final b =
                                  (_waypoints[i + 1]['name'] ?? 'Stop ${i + 2}')
                                      .toString();
                              final current = _segmentTypeAt(i);
                              final currentMode = _segmentTransportModeAt(i);

                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 10,
                                ),
                                child: LayoutBuilder(
                                  builder: (context, constraints) {
                                    final isCompact =
                                        constraints.maxWidth < 460;
                                    final segmentText = Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '${i + 1} → ${i + 2}',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          '$a → $b',
                                          maxLines: isCompact ? 3 : 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Colors.black54,
                                          ),
                                        ),
                                      ],
                                    );
                                    final controls = Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        DropdownButtonFormField<String>(
                                          initialValue: currentMode,
                                          isExpanded: true,
                                          decoration: const InputDecoration(
                                            isDense: true,
                                            labelText: 'Mode',
                                            border: OutlineInputBorder(),
                                          ),
                                          items:
                                              _transportOptions
                                                  .map(
                                                    (opt) => DropdownMenuItem(
                                                      value: opt.mode,
                                                      child: Text(
                                                        '${opt.emoji} ${opt.label}',
                                                      ),
                                                    ),
                                                  )
                                                  .toList(),
                                          onChanged: (value) async {
                                            if (value == null) return;
                                            await _setSegmentTransportMode(
                                              i,
                                              value,
                                            );
                                            setState2(() {});
                                          },
                                        ),
                                        const SizedBox(height: 8),
                                        Wrap(
                                          spacing: 8,
                                          runSpacing: 8,
                                          children: [
                                            ChoiceChip(
                                              label: const Text('Calculated'),
                                              selected: current == 'calculated',
                                              onSelected: (v) async {
                                                if (!v) return;
                                                await _setSegmentRoutingType(
                                                  i,
                                                  'calculated',
                                                );
                                                setState2(() {});
                                              },
                                            ),
                                            ChoiceChip(
                                              label: const Text('Direct'),
                                              selected: current == 'direct',
                                              onSelected: (v) async {
                                                if (!v) return;
                                                await _setSegmentRoutingType(
                                                  i,
                                                  'direct',
                                                );
                                                setState2(() {});
                                              },
                                            ),
                                          ],
                                        ),
                                      ],
                                    );

                                    if (isCompact) {
                                      return Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          segmentText,
                                          const SizedBox(height: 12),
                                          controls,
                                        ],
                                      );
                                    }

                                    return Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Expanded(child: segmentText),
                                        const SizedBox(width: 10),
                                        SizedBox(width: 210, child: controls),
                                      ],
                                    );
                                  },
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('Close'),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _maybePointerIntercept(Widget child) {
    if (!kIsWeb) return child;
    return WebInterceptor(child: child);
  }

  Widget _glassCard({
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(12),
    BorderRadiusGeometry borderRadius = const BorderRadius.all(
      Radius.circular(16),
    ),
    Color backgroundColor = const Color(0xE6FFFFFF),
  }) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: borderRadius,
            boxShadow: const [
              BoxShadow(
                color: Color(0x24000000),
                blurRadius: 16,
                offset: Offset(0, 6),
              ),
            ],
            border: Border.all(color: Color(0x14FFFFFF)),
          ),
          child: child,
        ),
      ),
    );
  }

  void _onSelectPlaceSuggestion(Map<String, dynamic> p) {
    final display = (p['display_name'] ?? '') as String;
    final lat = double.tryParse((p['lat'] ?? '').toString()) ?? 0.0;
    final lon = double.tryParse((p['lon'] ?? '').toString()) ?? 0.0;
    if (display.trim().isEmpty) return;

    setState(() {
      _waypoints.add({
        'lat': lat,
        'lon': lon,
        'name': display,
        'routing_query': display,
        'isStop': false,
        'nights': 0,
      });
      _placeSuggestions = [];
      _searchController.clear();
      _syncSegmentDataWithWaypoints();
      _syncLiveWaypointsFromState();
    });
  }

  Widget _buildOmniboxPanel(
    BuildContext context, {
    double maxWidth = 720,
  }) {
    final field = TextField(
      controller: _searchController,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        isDense: true,
        border: InputBorder.none,
        hintText: 'Search locations, hotels, or activities...',
        prefixIcon: const Icon(Icons.search),
        suffixIcon:
            _searchingPlaces
                ? const Padding(
                  padding: EdgeInsets.all(10),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
                : (_searchController.text.trim().isNotEmpty
                    ? IconButton(
                      tooltip: 'Clear',
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        setState(() {
                          _searchController.clear();
                          _placeSuggestions = [];
                        });
                      },
                    )
                    : null),
      ),
      onSubmitted: (_) {
        // Keep suggestions open; selection adds stops.
        FocusScope.of(context).unfocus();
      },
    );

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _maybePointerIntercept(
            _glassCard(
              borderRadius: BorderRadius.circular(999),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: field,
            ),
          ),
          if (_placeSuggestions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _maybePointerIntercept(
                _glassCard(
                  padding: EdgeInsets.zero,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 320),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: _placeSuggestions.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (ctx, i) {
                        final p = _placeSuggestions[i];
                        final display = (p['display_name'] ?? '') as String;
                        return ListTile(
                          dense: true,
                          title: Text(
                            display,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => _onSelectPlaceSuggestion(p),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildOmnibox(BuildContext context) {
    // Hide the search bar entirely for read-only viewers.
    if (widget.readOnly) return const SizedBox.shrink();

    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: 16),
        child: _buildOmniboxPanel(context),
      ),
    );
  }

  IconData _iconForStop(Map<String, dynamic> wp) {
    // Heuristic: show a "hotel" icon if accommodations exist.
    final accs = (wp['accommodations'] as List?)?.length ?? 0;
    if (accs > 0) return Icons.hotel;
    return Icons.location_city;
  }

  Widget _buildWaypointRoleChip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0x22000000)),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
      ),
    );
  }

  Widget _buildWaypointRoleButton(int index) {
    final isStop = _waypointIsStop(index);
    return PopupMenuButton<bool>(
      tooltip: 'Change destination type',
      onSelected: (value) => _setWaypointRole(index, value),
      itemBuilder:
          (_) => const [
            PopupMenuItem<bool>(value: true, child: Text('Stop')),
            PopupMenuItem<bool>(value: false, child: Text('Waypoint')),
          ],
      child: _buildWaypointRoleChip(isStop ? 'Stop' : 'Waypoint'),
    );
  }

  Widget _buildRouteTileActionButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 34,
        height: 34,
        child: Material(
          color: Colors.white.withValues(alpha: 0.72),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: Color(0x22000000)),
          ),
          child: IconButton(
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            iconSize: 18,
            tooltip: tooltip,
            onPressed: onPressed,
            icon: Icon(icon, color: Colors.black87),
          ),
        ),
      ),
    );
  }

  Widget _buildRouteTileDragHandle(int index) {
    return ReorderableDragStartListener(
      index: index,
      child: SizedBox(
        width: 34,
        height: 34,
        child: Material(
          color: Colors.white.withValues(alpha: 0.72),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: Color(0x22000000)),
          ),
          child: const Center(
            child: Icon(Icons.drag_handle, size: 18, color: Colors.black87),
          ),
        ),
      ),
    );
  }

  Widget _buildRouteTileActions(int index) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        _buildRouteTileActionButton(
          tooltip: 'Edit destination',
          icon: Icons.tune,
          onPressed: () => _editWaypointDialog(index),
        ),
        _buildRouteTileActionButton(
          tooltip: 'Remove destination',
          icon: Icons.delete,
          onPressed: () => _removeWaypoint(index),
        ),
        _buildRouteTileDragHandle(index),
      ],
    );
  }

  Widget _buildStopTile({
    required int index,
    required Map<String, dynamic> wp,
    required bool isLast,
    required VoidCallback? onTap,
    Widget? roleWidget,
    Widget? actions,
  }) {
    final name = (wp['name'] ?? 'Stop ${index + 1}').toString();
    final roleLabel = _waypointRoleLabel(index);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 34,
              child: Stack(
                children: [
                  Positioned(
                    left: 16,
                    top: 26,
                    bottom: 0,
                    child:
                        isLast
                            ? const SizedBox.shrink()
                            : Container(
                              width: 2,
                              color: const Color(0x33000000),
                            ),
                  ),
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: const Color(0x22000000)),
                    ),
                    child: Center(
                      child:
                          _isWaypointOnly(index)
                              ? const Icon(
                                Icons.alt_route,
                                size: 17,
                                color: Colors.black87,
                              )
                              : Text(
                                '${index + 1}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(_iconForStop(wp), size: 18, color: Colors.black87),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [roleWidget ?? _buildWaypointRoleChip(roleLabel)],
                  ),
                  if (actions != null) ...[const SizedBox(height: 8), actions],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTransitSegmentCard(int segmentIndex) {
    if (segmentIndex < 0 || segmentIndex + 1 >= _waypoints.length) {
      return const SizedBox.shrink();
    }
    if (_segmentTransportModeAt(segmentIndex) != 'transit') {
      return const SizedBox.shrink();
    }
    final detail = _transitSegmentDetailAt(segmentIndex);
    if (detail == null) return const SizedBox.shrink();
    final steps =
        (detail['steps'] as List?)
            ?.whereType<Map>()
            .map(
              (step) => Map<String, dynamic>.from(step.cast<String, dynamic>()),
            )
            .toList(growable: false) ??
        const <Map<String, dynamic>>[];
    if (steps.isEmpty) return const SizedBox.shrink();
    final arrivalStop = detail['arrivalStop'];
    final arrivalName =
        arrivalStop is Map
            ? (arrivalStop['name'] ?? arrivalStop['label'] ?? '').toString()
            : '';

    return Padding(
      padding: const EdgeInsets.fromLTRB(44, 0, 0, 6),
      child: TransitLegTabsCard(
        originName:
            (_waypoints[segmentIndex]['name'] ?? 'Stop ${segmentIndex + 1}')
                .toString(),
        destinationName:
            (_waypoints[segmentIndex + 1]['name'] ?? 'Stop ${segmentIndex + 2}')
                .toString(),
        arrivalStopName: arrivalName,
        steps: steps,
        onStepSelected: _focusTransitStepOnMap,
      ),
    );
  }

  void _focusTransitStepOnMap(Map<String, dynamic> step) {
    setState(() {
      _focusedTransitStep = {
        ...step,
        'requestId': ++_focusedTransitStepRequestId,
      };
    });
  }

  Widget _buildRouteControls({required bool canWriteTrip}) {
    final waypoints = _waypoints;
    final transportChips = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children:
            _transportOptions.map((opt) {
              final mode = opt.mode;
              final selected = _transportMode == mode;
              return Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text(opt.emoji, style: const TextStyle(fontSize: 14)),
                  selected: selected,
                  showCheckmark: false,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 2),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 2,
                  ),
                  onSelected:
                      (!canWriteTrip)
                          ? null
                          : (v) {
                            if (!v) return;
                            _setTransportMode(mode);
                          },
                ),
              );
            }).toList(),
      ),
    );

    final quickActions = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        OutlinedButton.icon(
          onPressed: _openDirectionsDialog,
          icon: const Icon(Icons.list_alt, size: 18),
          label: Text('Directions (${_routeInstructions.length})'),
        ),
        OutlinedButton.icon(
          onPressed:
              (!canWriteTrip || waypoints.length < 2)
                  ? null
                  : () => _openSegmentRoutingDialog(canWriteTrip: canWriteTrip),
          icon: const Icon(Icons.alt_route, size: 18),
          label: const Text('Segments'),
        ),
        if (canWriteTrip && _routeVia.isNotEmpty)
          OutlinedButton.icon(
            onPressed: () => _clearRouteCorrections(canWriteTrip: canWriteTrip),
            icon: const Icon(Icons.clear, size: 18),
            label: Text('Clear (${_routeVia.length})'),
          ),
      ],
    );

    return Column(
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final isCompact = constraints.maxWidth < 440;
            if (isCompact) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.directions, size: 18, color: Colors.black87),
                      SizedBox(width: 8),
                      Text(
                        'Default transport',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  transportChips,
                ],
              );
            }

            return Row(
              children: [
                const Icon(Icons.directions, size: 18, color: Colors.black87),
                const SizedBox(width: 8),
                const Text(
                  'Default',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
                ),
                const SizedBox(width: 10),
                Expanded(child: transportChips),
              ],
            );
          },
        ),
        const Padding(
          padding: EdgeInsets.only(top: 4.0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Set per-leg modes from Segments.',
              style: TextStyle(fontSize: 11, color: Colors.black54),
            ),
          ),
        ),
        if (_requiresGearListForModes(_segmentTransportModes, _transportMode))
          Padding(
            padding: const EdgeInsets.only(top: 8.0),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: const [
                Chip(
                  label: Text('Trail routing on'),
                  avatar: Icon(Icons.terrain, size: 18),
                ),
                Chip(
                  label: Text('High-vis line'),
                  avatar: Icon(Icons.show_chart, size: 18),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        Align(alignment: Alignment.centerLeft, child: quickActions),
      ],
    );
  }

  Widget _buildRouteDock(BuildContext context, {required bool canWriteTrip}) {
    final waypoints = _waypoints;

    final header = Row(
      children: [
        const Text(
          'Route',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
        ),
        const SizedBox(width: 10),
        Text(
          '${waypoints.length} destinations',
          style: const TextStyle(fontSize: 12, color: Colors.black54),
        ),
        const Spacer(),
        if (!widget.readOnly)
          IconButton(
            tooltip: _editing ? 'Done' : 'Edit',
            icon: Icon(_editing ? Icons.check : Icons.edit),
            onPressed: canWriteTrip ? _toggleEditing : null,
          ),
        if (_editing && !widget.readOnly)
          IconButton(
            tooltip: 'Save',
            icon: const Icon(Icons.save),
            onPressed: _saving ? null : _saveAll,
          ),
      ],
    );

    final list =
        _editing
            ? ReorderableListView(
              buildDefaultDragHandles: false,
              onReorder: (oldIndex, newIndex) {
                setState(() {
                  if (newIndex > oldIndex) newIndex -= 1;
                  final item = _waypoints.removeAt(oldIndex);
                  _waypoints.insert(newIndex, item);
                  _syncSegmentDataWithWaypoints();
                  _syncLiveWaypointsFromState();
                });
              },
              children: [
                for (final e in waypoints.asMap().entries)
                  Container(
                    key: ValueKey('dock-wp-${e.key}'),
                    margin: const EdgeInsets.symmetric(vertical: 2),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: const Color(0x08FFFFFF),
                    ),
                    child: _buildStopTile(
                      index: e.key,
                      wp: e.value,
                      isLast: e.key == waypoints.length - 1,
                      onTap: null,
                      roleWidget:
                          _canEditWaypointRole(e.key)
                              ? _buildWaypointRoleButton(e.key)
                              : null,
                      actions: _buildRouteTileActions(e.key),
                    ),
                  ),
              ],
            )
            : ListView.builder(
              itemCount: waypoints.length,
              itemBuilder: (ctx, i) {
                final wp = waypoints[i];
                return Column(
                  children: [
                    _buildStopTile(
                      index: i,
                      wp: wp,
                      isLast: i == waypoints.length - 1,
                      onTap:
                          widget.readOnly
                              ? null
                              : () => _openTripPlanning(focusWaypointIndex: i),
                    ),
                    if (i < waypoints.length - 1) _buildTransitSegmentCard(i),
                  ],
                );
              },
            );

    return _maybePointerIntercept(
      _glassCard(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          children: [
            header,
            const SizedBox(height: 8),
            _buildRouteControls(canWriteTrip: canWriteTrip),
            const SizedBox(height: 8),
            _buildMapPointInsightCard(),
            const SizedBox(height: 8),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: list,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMobileRouteSheet(
    BuildContext context, {
    required bool canWriteTrip,
  }) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: _maybePointerIntercept(
        DraggableScrollableSheet(
          controller: _mobileRouteSheetController,
          initialChildSize: _mobileRouteSheetCollapsedSize,
          minChildSize: _mobileRouteSheetCollapsedSize,
          maxChildSize: _mobileRouteSheetMaxSize,
          snap: true,
          snapSizes: const <double>[_mobileRouteSheetPreviewSize],
          builder: (ctx, scrollController) {
            final waypoints = _waypoints;
            final sheetHeader = Column(
              children: [
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Text(
                      'Route',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '${waypoints.length} destinations',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.black54,
                      ),
                    ),
                    const Spacer(),
                    if (!widget.readOnly)
                      IconButton(
                        tooltip: _editing ? 'Done' : 'Edit',
                        icon: Icon(_editing ? Icons.check : Icons.edit),
                        onPressed: canWriteTrip ? _toggleEditing : null,
                      ),
                    if (_editing && !widget.readOnly)
                      IconButton(
                        tooltip: 'Save',
                        icon: const Icon(Icons.save),
                        onPressed: _saving ? null : _saveAll,
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                _buildRouteControls(canWriteTrip: canWriteTrip),
                const SizedBox(height: 8),
                _buildMapPointInsightCard(),
                const SizedBox(height: 8),
              ],
            );
            return _glassCard(
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(18),
                topRight: Radius.circular(18),
              ),
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              child:
                  _editing
                      ? ReorderableListView(
                        scrollController: scrollController,
                        buildDefaultDragHandles: false,
                        padding: EdgeInsets.zero,
                        header: sheetHeader,
                        footer: const SizedBox(height: 16),
                        onReorder: (oldIndex, newIndex) {
                          setState(() {
                            if (newIndex > oldIndex) newIndex -= 1;
                            final item = _waypoints.removeAt(oldIndex);
                            _waypoints.insert(newIndex, item);
                            _syncSegmentDataWithWaypoints();
                            _syncLiveWaypointsFromState();
                          });
                        },
                        children: [
                          for (final e in waypoints.asMap().entries)
                            Container(
                              key: ValueKey('sheet-wp-${e.key}'),
                              margin: const EdgeInsets.symmetric(vertical: 2),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                color: const Color(0x08FFFFFF),
                              ),
                              child: _buildStopTile(
                                index: e.key,
                                wp: e.value,
                                isLast: e.key == waypoints.length - 1,
                                onTap: null,
                                roleWidget:
                                    _canEditWaypointRole(e.key)
                                        ? _buildWaypointRoleButton(e.key)
                                        : null,
                                actions: _buildRouteTileActions(e.key),
                              ),
                            ),
                        ],
                      )
                      : ListView(
                        controller: scrollController,
                        padding: EdgeInsets.zero,
                        children: [
                          sheetHeader,
                          for (final entry in waypoints.asMap().entries) ...[
                            _buildStopTile(
                              index: entry.key,
                              wp: entry.value,
                              isLast: entry.key == waypoints.length - 1,
                              onTap:
                                  widget.readOnly
                                      ? null
                                      : () => _openTripPlanning(
                                        focusWaypointIndex: entry.key,
                                      ),
                            ),
                            if (entry.key < waypoints.length - 1)
                              _buildTransitSegmentCard(entry.key),
                          ],
                          const SizedBox(height: 16),
                        ],
                      ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildActionCluster(BuildContext context, {required num totalKm}) {
    final waypoints = _waypoints;
    final isNarrow = MediaQuery.sizeOf(context).width < 760;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final bottomOffset =
        isNarrow
            ? ((screenHeight * _mobileRouteSheetExtent) + 12.0)
                .clamp(108.0, screenHeight * 0.78)
            : 24.0;

    final statsText =
        '${waypoints.length} Destinations | ${totalKm.toStringAsFixed(0)} km';

    final statsPill = _glassCard(
      borderRadius: BorderRadius.circular(999),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Text(
        statsText,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
    );

    final saveButton =
        widget.readOnly
            ? null
            : ElevatedButton(
              onPressed: _saving ? null : _saveAll,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF111827),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_saving)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  else
                    const Icon(Icons.auto_awesome, size: 18),
                  const SizedBox(width: 8),
                  Text(_saving ? 'Saving…' : 'Save Trip'),
                ],
              ),
            );

    if (isNarrow) {
      return AnimatedPositioned(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        left: 16,
        right: 16,
        bottom: bottomOffset,
        child: Align(
          alignment: Alignment.center,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: _maybePointerIntercept(
              _glassCard(
                borderRadius: BorderRadius.circular(24),
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.center,
                      child: statsPill,
                    ),
                    if (saveButton != null) ...[
                      const SizedBox(height: 10),
                      SizedBox(width: double.infinity, child: saveButton),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Positioned(
      right: 24,
      bottom: bottomOffset,
      child: _maybePointerIntercept(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            statsPill,
            const SizedBox(width: 12),
            if (saveButton != null) saveButton,
          ],
        ),
      ),
    );
  }

  void _handleQuickAction(_TripDetailQuickAction action) {
    switch (action) {
      case _TripDetailQuickAction.plan:
        _openTripPlanning();
        break;
      case _TripDetailQuickAction.packing:
        _openPackingList();
        break;
      case _TripDetailQuickAction.expenses:
        _openExpensesDialog();
        break;
      case _TripDetailQuickAction.chat:
        _openTripChat();
        break;
      case _TripDetailQuickAction.share:
        _shareTrip();
        break;
    }
  }

  Widget _buildReadOnlyBanner(BuildContext context, {bool compact = false}) {
    if (compact) {
      return _maybePointerIntercept(
        _glassCard(
          borderRadius: BorderRadius.circular(18),
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.lock_outline, size: 16),
                  SizedBox(width: 8),
                  Text(
                    'Read-only preview',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.of(context).pushNamed('/sign-in');
                  },
                  icon: const Icon(Icons.login, size: 16),
                  label: const Text('Sign in to join'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF111827),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999),
                    ),
                    textStyle: const TextStyle(fontSize: 13),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return _maybePointerIntercept(
      _glassCard(
        borderRadius: BorderRadius.circular(999),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline, size: 16),
            const SizedBox(width: 8),
            const Text(
              'Read-only preview',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
            const SizedBox(width: 12),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.of(context).pushNamed('/sign-in');
              },
              icon: const Icon(Icons.login, size: 16),
              label: const Text('Sign in to join'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF111827),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(999),
                ),
                textStyle: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMapModeToggleControl() {
    final twoDSelected = _mapMode == _TripDetailMapMode.map2d;
    return _glassCard(
      borderRadius: BorderRadius.circular(999),
      padding: const EdgeInsets.all(4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _MapModeToggleButton(
            label: '2D',
            icon: Icons.map_outlined,
            selected: twoDSelected,
            onTap: () => _setMapMode(_TripDetailMapMode.map2d),
          ),
          const SizedBox(width: 6),
          _MapModeToggleButton(
            label: '3D',
            icon: Icons.public,
            selected: !twoDSelected,
            onTap: () => _setMapMode(_TripDetailMapMode.globe3d),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileTopChrome(
    BuildContext context,
    String title,
  ) {
    return Positioned(
      left: 12,
      right: 12,
      top: 12,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _maybePointerIntercept(
            Row(
              children: [
                _glassCard(
                  borderRadius: BorderRadius.circular(999),
                  padding: EdgeInsets.zero,
                  child: IconButton(
                    tooltip: 'Back',
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _glassCard(
                    borderRadius: BorderRadius.circular(999),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
                if (!widget.readOnly) ...[
                  const SizedBox(width: 8),
                  _glassCard(
                    borderRadius: BorderRadius.circular(999),
                    padding: EdgeInsets.zero,
                    child: PopupMenuButton<_TripDetailQuickAction>(
                      tooltip: 'Trip actions',
                      icon: const Icon(Icons.more_horiz),
                      onSelected: _handleQuickAction,
                      itemBuilder:
                          (_) => const [
                            PopupMenuItem<_TripDetailQuickAction>(
                              value: _TripDetailQuickAction.plan,
                              child: Text('Plan trip'),
                            ),
                            PopupMenuItem<_TripDetailQuickAction>(
                              value: _TripDetailQuickAction.packing,
                              child: Text('Packing list'),
                            ),
                            PopupMenuItem<_TripDetailQuickAction>(
                              value: _TripDetailQuickAction.expenses,
                              child: Text('Expenses'),
                            ),
                            PopupMenuItem<_TripDetailQuickAction>(
                              value: _TripDetailQuickAction.chat,
                              child: Text('Chat'),
                            ),
                            PopupMenuItem<_TripDetailQuickAction>(
                              value: _TripDetailQuickAction.share,
                              child: Text('Share trip'),
                            ),
                          ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (!widget.readOnly) ...[
            const SizedBox(height: 8),
            _buildOmniboxPanel(context, maxWidth: double.infinity),
          ],
          if (widget.readOnly) ...[
            const SizedBox(height: 8),
            _buildReadOnlyBanner(context, compact: true),
          ],
          if (kIsWeb) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: _maybePointerIntercept(_buildMapModeToggleControl()),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTopLeftNav(BuildContext context, String title) {
    return Positioned(
      left: 24,
      top: 16,
      child: _maybePointerIntercept(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _glassCard(
              borderRadius: BorderRadius.circular(999),
              padding: EdgeInsets.zero,
              child: IconButton(
                tooltip: 'Back',
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
            const SizedBox(width: 12),
            _glassCard(
              borderRadius: BorderRadius.circular(999),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 280),
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _setMapMode(_TripDetailMapMode mode) {
    if (_mapMode == mode) return;
    setState(() => _mapMode = mode);
  }

  Widget _buildMapModeToggleOverlay(BuildContext context) {
    if (!kIsWeb) return const SizedBox.shrink();
    return Positioned(
      right: 24,
      top: 80,
      child: _maybePointerIntercept(
        _buildMapModeToggleControl(),
      ),
    );
  }

  Widget _buildTopRightActions(BuildContext context) {
    // Read-only visitors (e.g. unauthenticated share-link viewers) see no
    // action buttons — they get a sign-in banner instead.
    if (widget.readOnly) return const SizedBox.shrink();

    return Positioned(
      right: 24,
      top: 16,
      child: _maybePointerIntercept(
        _glassCard(
          borderRadius: BorderRadius.circular(999),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Plan trip',
                icon: const Icon(Icons.edit_note),
                onPressed: () => _openTripPlanning(),
              ),
              IconButton(
                tooltip: 'Packing list',
                icon: const Icon(Icons.list),
                onPressed: _openPackingList,
              ),
              IconButton(
                tooltip: 'Expenses',
                icon: const Icon(Icons.pie_chart),
                onPressed: _openExpensesDialog,
              ),
              IconButton(
                tooltip: 'Chat',
                icon: const Icon(Icons.chat),
                onPressed: _openTripChat,
              ),
              IconButton(
                tooltip: 'Share trip',
                icon: const Icon(Icons.share),
                onPressed: _shareTrip,
              ),
            ],
          ),
        ),
      ),
    );
  }

  double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? double.nan;
    return double.nan;
  }

  bool _isValidLatLon(double lat, double lon) {
    return lat.isFinite &&
        lon.isFinite &&
        lat >= -90 &&
        lat <= 90 &&
        lon >= -180 &&
        lon <= 180;
  }

  List<Map<String, dynamic>> _mapList(dynamic raw) {
    if (raw is! List) return const [];
    return raw.map<Map<String, dynamic>>((e) {
      if (e is Map<String, dynamic>) return Map<String, dynamic>.from(e);
      if (e is Map) return Map<String, dynamic>.from(e.cast<String, dynamic>());
      return <String, dynamic>{};
    }).toList();
  }

  String _normalizedLabel(String raw) {
    return raw
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  bool _labelsMatch(String a, String b) {
    final na = _normalizedLabel(a);
    final nb = _normalizedLabel(b);
    return na.isNotEmpty && na == nb;
  }

  String _mapPointKind(Map<String, dynamic> point) {
    final raw =
        (point['kind'] ?? point['pointType'] ?? '')
            .toString()
            .trim()
            .toLowerCase();
    if (raw.isNotEmpty) return raw;
    if (point['waypointIndex'] != null) return 'waypoint';
    return 'location';
  }

  String _mapPointTitle(Map<String, dynamic> point) {
    final name = (point['name'] ?? point['title'] ?? '').toString().trim();
    if (name.isNotEmpty) return name;
    final waypointIndex = (point['waypointIndex'] as num?)?.toInt();
    if (waypointIndex != null && waypointIndex >= 0) {
      return 'Stop ${waypointIndex + 1}';
    }
    return 'Selected place';
  }

  List<Map<String, dynamic>> _activitiesForWaypoint(
    int waypointIndex, {
    String? waypointName,
  }) {
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    final safeWaypointName = (waypointName ?? '').toString();

    void appendActivities(dynamic raw) {
      for (final a in _mapList(raw)) {
        final key = [
          (a['title'] ?? '').toString().trim().toLowerCase(),
          (a['startTime'] ?? '').toString().trim(),
          (a['location'] ?? '').toString().trim().toLowerCase(),
          (a['category'] ?? '').toString().trim().toLowerCase(),
        ].join('|');
        if (!seen.add(key)) continue;
        out.add(a);
      }
    }

    if (waypointIndex >= 0 && waypointIndex < _waypoints.length) {
      final waypoint = _waypoints[waypointIndex];
      final legacyItinerary = _mapList(waypoint['itinerary']);
      for (final day in legacyItinerary) {
        appendActivities(day['activities']);
      }
    }

    final unifiedCandidates = [
      _liveData['tripItinerary'],
      _liveData['itinerary'],
      widget.data['tripItinerary'],
      widget.data['itinerary'],
    ];

    for (final rawDays in unifiedCandidates) {
      for (final day in _mapList(rawDays)) {
        final dayWaypoint = (day['waypointIndex'] as num?)?.toInt();
        final dayLocation = (day['locationName'] ?? '').toString();
        final matchesWaypoint =
            waypointIndex >= 0 && dayWaypoint == waypointIndex;
        final matchesName =
            safeWaypointName.isNotEmpty &&
            _labelsMatch(dayLocation, safeWaypointName);
        if (!matchesWaypoint && !matchesName) continue;
        appendActivities(day['activities']);
      }
    }

    return out;
  }

  List<String> _topActivityCategories(
    Iterable<Map<String, dynamic>> activities, {
    int max = 6,
  }) {
    final counts = <String, int>{};
    for (final a in activities) {
      final raw = (a['category'] ?? '').toString().trim();
      if (raw.isEmpty) continue;
      counts[raw] = (counts[raw] ?? 0) + 1;
    }
    final entries =
        counts.entries.toList()..sort((a, b) {
          final byCount = b.value.compareTo(a.value);
          if (byCount != 0) return byCount;
          return a.key.compareTo(b.key);
        });
    return entries.take(max).map((e) => e.key).toList(growable: false);
  }

  List<String> _categoriesForMapPoint(Map<String, dynamic> point) {
    final kind = _mapPointKind(point);
    final pointCategory = (point['category'] ?? '').toString().trim();

    if (kind == 'activity') {
      final out = <String>[];
      if (pointCategory.isNotEmpty) out.add(pointCategory);
      final dayIndex = (point['dayIndex'] as num?)?.toInt();
      if (dayIndex != null && dayIndex >= 0) {
        final itinerary = _mapList(
          _liveData['tripItinerary'] ?? _liveData['itinerary'],
        );
        if (dayIndex < itinerary.length) {
          final dayCategories = _topActivityCategories(
            _mapList(itinerary[dayIndex]['activities']),
          );
          for (final category in dayCategories) {
            if (!out.contains(category)) out.add(category);
          }
        }
      }
      return out.take(6).toList(growable: false);
    }

    final waypointIndex = (point['waypointIndex'] as num?)?.toInt() ?? -1;
    final waypointName = (point['name'] ?? '').toString();
    final waypointActivities = _activitiesForWaypoint(
      waypointIndex,
      waypointName: waypointName,
    );
    final categories = _topActivityCategories(waypointActivities);
    if (categories.isNotEmpty) return categories;
    if (pointCategory.isNotEmpty) return [pointCategory];
    return const [];
  }

  String _mapPointSubtitle(Map<String, dynamic> point) {
    final kind = _mapPointKind(point);
    final category = (point['category'] ?? '').toString().trim();
    final dayIndex = (point['dayIndex'] as num?)?.toInt();
    if (kind == 'activity') {
      final parts = <String>[];
      if (dayIndex != null && dayIndex >= 0) {
        parts.add('Day ${dayIndex + 1}');
      }
      if (category.isNotEmpty) parts.add(category);
      return parts.join(' • ');
    }
    if (kind == 'accommodation') {
      return 'Accommodation';
    }
    final waypointIndex = (point['waypointIndex'] as num?)?.toInt();
    if (waypointIndex != null && waypointIndex >= 0) {
      return 'Stop ${waypointIndex + 1}';
    }
    return 'Map selection';
  }

  String _vibeForCategory(String category) {
    switch (category.trim().toLowerCase()) {
      case 'hiking':
      case 'walking':
      case 'adventure':
        return 'outdoor exploration';
      case 'museum':
      case 'sightseeing':
      case 'photography':
        return 'landmark and culture stops';
      case 'restaurant':
        return 'local food experiences';
      case 'shopping':
        return 'city-style wandering';
      default:
        return 'balanced sightseeing';
    }
  }

  String _aiSummaryForMapPoint(
    Map<String, dynamic> point,
    List<String> categories,
  ) {
    final kind = _mapPointKind(point);
    final title = _mapPointTitle(point);

    if (kind == 'activity') {
      final dayIndex = (point['dayIndex'] as num?)?.toInt();
      final when =
          dayIndex != null && dayIndex >= 0
              ? 'on Day ${dayIndex + 1}'
              : 'in your plan';
      final category = (point['category'] ?? '').toString().trim();
      final vibe = _vibeForCategory(
        category.isNotEmpty
            ? category
            : (categories.isNotEmpty ? categories.first : ''),
      );
      return '$title is scheduled $when and fits $vibe. Keep this stop near nearby items to avoid extra transit time.';
    }

    if (kind == 'accommodation') {
      final nearbyFocus =
          categories.isEmpty
              ? 'your planned activities'
              : categories.take(3).join(', ');
      return '$title looks like your base for this stop. Nearby focus areas: $nearbyFocus.';
    }

    final waypointIndex = (point['waypointIndex'] as num?)?.toInt() ?? -1;
    final activities = _activitiesForWaypoint(
      waypointIndex,
      waypointName: title,
    );
    final activityCount = activities.length;
    final dayCount =
        (waypointIndex >= 0 && waypointIndex < _waypoints.length)
            ? _mapList(_waypoints[waypointIndex]['itinerary']).length
            : 0;
    if (activityCount == 0) {
      return '$title is currently a route anchor with no planned activities yet. Add a few stops to generate stronger recommendations.';
    }
    final categoryText =
        categories.isEmpty ? 'mixed activities' : categories.take(3).join(', ');
    final dayText =
        dayCount > 0
            ? '$dayCount planned day${dayCount == 1 ? '' : 's'}'
            : 'this stop';
    return '$title has $activityCount planned activit${activityCount == 1 ? 'y' : 'ies'} across $dayText, with a focus on $categoryText.';
  }

  void _handleMapPointTap(Map<String, dynamic> point) {
    if (!mounted) return;
    setState(() {
      _selectedMapPoint = Map<String, dynamic>.from(point);
    });
  }

  Widget _buildMapPointInsightCard() {
    final point = _selectedMapPoint;
    if (point == null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.78),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0x12000000)),
        ),
        child: const Text(
          'Tap any map pin to see a place summary.',
          style: TextStyle(fontSize: 12, color: Colors.black54),
        ),
      );
    }

    final title = _mapPointTitle(point);
    final subtitle = _mapPointSubtitle(point);
    final categories = _categoriesForMapPoint(point);
    final summary = _aiSummaryForMapPoint(point, categories);
    final kind = _mapPointKind(point);
    final icon =
        kind == 'activity'
            ? Icons.local_activity
            : kind == 'accommodation'
            ? Icons.hotel
            : Icons.place;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x16000000)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: Colors.black87),
              const SizedBox(width: 6),
              const Text(
                'Place Insight',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              const Icon(Icons.auto_awesome, size: 14, color: Colors.black54),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          if (subtitle.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ],
          const SizedBox(height: 8),
          const Text(
            'AI Summary',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            summary,
            style: const TextStyle(fontSize: 12, color: Colors.black87),
          ),
          if (categories.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text(
              'Activity Categories',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: categories
                  .take(6)
                  .map(
                    (c) => Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        c,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  )
                  .toList(growable: false),
            ),
          ],
        ],
      ),
    );
  }

  List<Map<String, dynamic>> _mapRoutePoints(
    List<Map<String, dynamic>> waypoints,
  ) {
    final out = <Map<String, dynamic>>[];
    for (final entry in waypoints.asMap().entries) {
      final w = entry.value;
      final lat = _toDouble(w['lat'] ?? w['latitude']);
      final lon = _toDouble(w['lon'] ?? w['longitude'] ?? w['lng']);
      if (!_isValidLatLon(lat, lon)) continue;
      out.add({
        'lat': lat,
        'lon': lon,
        'name': (w['name'] ?? '').toString(),
        'pointType': 'waypoint',
        'waypointIndex': entry.key,
      });
    }
    return out;
  }

  List<Map<String, dynamic>> _legacyWaypointMarkers(
    List<Map<String, dynamic>> waypoints,
  ) {
    final out = <Map<String, dynamic>>[];

    for (final wEntry in waypoints.asMap().entries) {
      final wIndex = wEntry.key;
      final w = wEntry.value;

      final accsAny = w['accommodations'];
      final accs = accsAny is List ? accsAny : const [];
      for (final accEntry in accs.asMap().entries) {
        final accRaw = accEntry.value;
        if (accRaw is! Map) continue;
        final acc = Map<String, dynamic>.from(accRaw.cast<String, dynamic>());
        final lat = _toDouble(acc['lat'] ?? acc['locationLat']);
        final lon = _toDouble(acc['lon'] ?? acc['locationLon'] ?? acc['lng']);
        if (!_isValidLatLon(lat, lon)) continue;
        out.add({
          'lat': lat,
          'lon': lon,
          'kind': 'accommodation',
          'category': 'Accommodation',
          'name': (acc['name'] ?? 'Accommodation').toString(),
          'waypointIndex': wIndex,
          'accommodationIndex': accEntry.key,
        });
      }

      final itineraryAny = w['itinerary'];
      final itinerary = itineraryAny is List ? itineraryAny : const [];
      for (final dayEntry in itinerary.asMap().entries) {
        final dayRaw = dayEntry.value;
        if (dayRaw is! Map) continue;
        final day = Map<String, dynamic>.from(dayRaw.cast<String, dynamic>());
        final actsAny = day['activities'];
        final acts = actsAny is List ? actsAny : const [];
        for (final actEntry in acts.asMap().entries) {
          final actRaw = actEntry.value;
          if (actRaw is! Map) continue;
          final act = Map<String, dynamic>.from(actRaw.cast<String, dynamic>());
          final lat = _toDouble(act['locationLat']);
          final lon = _toDouble(act['locationLon']);
          if (!_isValidLatLon(lat, lon)) continue;
          out.add({
            'lat': lat,
            'lon': lon,
            'kind': 'activity',
            'category': (act['category'] ?? 'Exploring').toString(),
            'name': (act['title'] ?? 'Activity').toString(),
            'waypointIndex': wIndex,
            'dayIndex': dayEntry.key,
            'activityIndex': actEntry.key,
            'source': 'waypointItinerary',
          });
        }
      }
    }

    return out;
  }

  List<Map<String, dynamic>> _unifiedTripItineraryMarkers() {
    final out = <Map<String, dynamic>>[];
    final candidates = [
      _liveData['tripItinerary'],
      _liveData['itinerary'],
      widget.data['tripItinerary'],
      widget.data['itinerary'],
    ];

    for (final raw in candidates) {
      if (raw is! List) continue;
      for (final dayEntry in raw.asMap().entries) {
        final dayRaw = dayEntry.value;
        if (dayRaw is! Map) continue;
        final day = Map<String, dynamic>.from(dayRaw.cast<String, dynamic>());
        final actsAny = day['activities'];
        final acts = actsAny is List ? actsAny : const [];
        for (final actEntry in acts.asMap().entries) {
          final actRaw = actEntry.value;
          if (actRaw is! Map) continue;
          final act = Map<String, dynamic>.from(actRaw.cast<String, dynamic>());
          final lat = _toDouble(act['locationLat']);
          final lon = _toDouble(act['locationLon']);
          if (!_isValidLatLon(lat, lon)) continue;
          out.add({
            'lat': lat,
            'lon': lon,
            'kind': 'activity',
            'category': (act['category'] ?? 'Exploring').toString(),
            'name': (act['title'] ?? 'Activity').toString(),
            'dayIndex': dayEntry.key,
            'activityIndex': actEntry.key,
            'source': 'tripItinerary',
          });
        }
      }
    }

    return out;
  }

  List<Map<String, dynamic>> _dedupeMarkers(List<Map<String, dynamic>> input) {
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final p in input) {
      final lat = _toDouble(p['lat']).toStringAsFixed(5);
      final lon = _toDouble(p['lon']).toStringAsFixed(5);
      final kind = (p['kind'] ?? '').toString();
      final category = (p['category'] ?? '').toString();
      final name = (p['name'] ?? '').toString();
      final key = '$lat|$lon|$kind|$category|$name';
      if (!seen.add(key)) continue;
      out.add(p);
    }
    return out;
  }

  List<Map<String, dynamic>> _mapSecondaryPoints(
    List<Map<String, dynamic>> waypoints,
  ) {
    return _dedupeMarkers([
      ..._legacyWaypointMarkers(waypoints),
      ..._unifiedTripItineraryMarkers(),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final data = _liveData;
    final name = (data['name'] ?? 'Untitled Trip').toString();
    final waypoints = _waypoints;
    final totalKm = _toDouble(data['totalKm']);

    final me = _user;
    final tripRefForView = me == null ? null : _resolveTripRefForView(me);
    // Owner or sharedWith members can write to the trip.
    final bool canWriteTrip;
    if (me == null || tripRefForView == null) {
      canWriteTrip = false;
    } else {
      final ownerUid = _ownerUidFromTripRefPath(tripRefForView.path);
      final sharedAny = _liveData['sharedWith'] ?? widget.data['sharedWith'];
      final sharedWith = sharedAny is List ? sharedAny : const <dynamic>[];
      canWriteTrip = ownerUid == me.uid || sharedWith.contains(me.uid);
    }
    final isNarrow = MediaQuery.sizeOf(context).width < 760;
    final mapPoints = _mapRoutePoints(waypoints);
    final secondaryPoints = _mapSecondaryPoints(waypoints);
    final showMapLayer = !(widget.readOnly && !canWriteTrip);

    final Widget backgroundLayer =
        !showMapLayer
            ? Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFFF8FAFC), Color(0xFFEFF4FA)],
                ),
              ),
            )
            : (kIsWeb && _mapMode == _TripDetailMapMode.globe3d)
            ? Globe3DEmbed(
              points: mapPoints,
              secondaryPoints: secondaryPoints,
              routeGeometry: _routeGeometry3d,
              transportMode: _transportMode.toUpperCase(),
              onMapTap:
                  _editing ? (lat, lon) => _addWaypointFromTap(lat, lon) : null,
            )
            : MapEmbed(
              points: mapPoints,
              transportMode: _transportMode,
              segmentTransportModes: _segmentTransportModes,
              routeVia: _routeVia,
              segmentRoutingTypes: _segmentRoutingTypes,
              initialRouteGeometry: _routeGeometry3d,
              initialRouteInstructions: _routeInstructions,
              initialRouteSegmentDetails: _routeSegmentDetails,
              preferInitialRouteData: _canUseCachedRoute,
              onRouteInstructions: (lines) {
                if (!mounted) return;
                final nextLines = lines
                    .map((line) => line.trim())
                    .where((line) => line.isNotEmpty)
                    .take(8)
                    .toList(growable: false);
                if (_sameRouteInstructions(nextLines) &&
                    (_liveData['routeCacheKey'] ?? '').toString().trim() ==
                        _currentRouteCacheKey()) {
                  return;
                }
                setState(() {
                  _routeInstructions = nextLines;
                  _liveData['routeInstructions'] = nextLines;
                  _liveData['routeCacheKey'] = _currentRouteCacheKey();
                });
                _scheduleRouteCachePersist();
              },
              onRouteSegmentDetails: (segments) {
                if (!mounted) return;
                final nextSegments = readRouteSegmentDetails(segments);
                if (_sameRouteSegmentDetails(nextSegments) &&
                    (_liveData['routeCacheKey'] ?? '').toString().trim() ==
                        _currentRouteCacheKey()) {
                  return;
                }
                setState(() {
                  _routeSegmentDetails = nextSegments;
                  _liveData['routeSegmentDetails'] = nextSegments;
                  _liveData['routeCacheKey'] = _currentRouteCacheKey();
                });
                _scheduleRouteCachePersist();
              },
              onRouteGeometry: (geometry) {
                if (!mounted) return;
                final simplified = simplifyRouteGeometry(geometry);
                if (_sameRouteGeometry(simplified) &&
                    (_liveData['routeCacheKey'] ?? '').toString().trim() ==
                        _currentRouteCacheKey()) {
                  return;
                }
                setState(() {
                  _routeGeometry3d = simplified;
                  _liveData['routeGeometry3d'] = simplified;
                  _liveData['routeCacheKey'] = _currentRouteCacheKey();
                });
                _scheduleRouteCachePersist();
              },
              onTransitArrivalStop: (arrivalStop) {
                if (!mounted) return;
                final resolvedStop =
                    arrivalStop.isEmpty ? null : arrivalStop;
                setState(() => _transitArrivalStop = resolvedStop);
                if (_hasTransitModeInRoute) {
                  _persistTransitArrivalStop(resolvedStop ?? const {});
                }
              },
              focusedRouteStep: _focusedTransitStep,
              secondaryPoints: secondaryPoints,
              onPointTap: _handleMapPointTap,
              showNearbyContextOverlays: false,
              onMapTap:
                  _editing ? (lat, lon) => _addWaypointFromTap(lat, lon) : null,
              onRouteTapAddVia:
                  (!_editing && canWriteTrip)
                      ? (afterIndex, lat, lon) => _upsertViaPoint(
                        afterIndex: afterIndex,
                        lat: lat,
                        lon: lon,
                      )
                      : null,
              onViaDragEnd:
                  (!_editing && canWriteTrip)
                      ? (viaIndex, lat, lon) =>
                          _moveViaPoint(viaIndex: viaIndex, lat: lat, lon: lon)
                      : null,
              onViaTapDelete:
                  (!_editing && canWriteTrip)
                      ? (viaIndex) => _deleteViaPoint(viaIndex: viaIndex)
                      : null,
              routeComputingBannerTop: isNarrow ? 164 : 112,
            );

    return Scaffold(
      body: Stack(
        children: [
          // Full-screen background map.
          Positioned.fill(
            child: IgnorePointer(
              ignoring: _suspendMapTap,
              child: backgroundLayer,
            ),
          ),
          if (kIsWeb && _suspendMapTap)
            Positioned.fill(
              child: WebInterceptor(child: const SizedBox.expand()),
            ),

          // Floating UI layer.
          SafeArea(
            child: Stack(
              children: [
                if (isNarrow)
                  _buildMobileTopChrome(context, name.toString())
                else ...[
                  _buildOmnibox(context),
                  _buildTopLeftNav(context, name.toString()),
                  _buildTopRightActions(context),
                  _buildMapModeToggleOverlay(context),
                ],
                if (!isNarrow)
                  Positioned(
                    left: 24,
                    top: 88,
                    bottom: 24,
                    width: 340,
                    child: _buildRouteDock(context, canWriteTrip: canWriteTrip),
                  )
                else
                  _buildMobileRouteSheet(context, canWriteTrip: canWriteTrip),
                _buildActionCluster(context, totalKm: totalKm),

                // Read-only sign-in banner for unauthenticated share-link viewers.
                if (widget.readOnly && !isNarrow)
                  Positioned(
                    top: 16,
                    right: 24,
                    child: _buildReadOnlyBanner(context),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MapModeToggleButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _MapModeToggleButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF111827) : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: selected ? Colors.white : Colors.black87,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: selected ? Colors.white : Colors.black87,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
