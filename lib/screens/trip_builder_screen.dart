import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:trypr/utils/trypr_snackbar.dart';
import 'package:trypr/widgets/web_interceptor.dart';
import 'package:trypr/widgets/top_taskbar.dart';
import 'package:trypr/widgets/map_embed.dart';
import 'package:trypr/widgets/globe_3d_embed.dart';
import 'package:trypr/services/geocode.dart';
import 'package:trypr/services/location_display.dart';
import 'package:trypr/widgets/activity_finder_modal.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:trypr/utils/route_cache.dart';
import 'package:trypr/widgets/share_trip_dialog.dart';

class TripBuilderScreen extends StatefulWidget {
  const TripBuilderScreen({super.key});

  @override
  State<TripBuilderScreen> createState() => _TripBuilderScreenState();
}

class _Waypoint {
  final String name;
  final double lat;
  final double lon;
  int nights = 1;
  _Waypoint(this.name, this.lat, this.lon);
}

class _TransportOption {
  final String mode;
  final String label;
  final String emoji;

  const _TransportOption(this.mode, this.label, this.emoji);
}

String activeRoutingMode = 'car';
const bool _verificationAutoloadTrip = bool.fromEnvironment(
  'VERIFICATION_AUTOLOAD_TRIP',
  defaultValue: false,
);
const String _verificationTripStopsDefine = String.fromEnvironment(
  'VERIFICATION_TRIP_STOPS',
  defaultValue: 'banff,calgary,banff',
);

const List<_TransportOption> _transportOptions = [
  _TransportOption('car', 'Car', '🚗'),
  _TransportOption('plane', 'Plane', '✈️'),
  _TransportOption('train', 'Train', '🚆'),
  _TransportOption('walk', 'Walk', '🚶'),
  _TransportOption('bike', 'Bike', '🚲'),
  _TransportOption('portaging', 'Portaging', '🛶'),
  _TransportOption('hiking', 'Hiking', '🥾'),
  _TransportOption('gas_stops', 'Gas/Stops', '⛽'),
];

enum _TripBuilderMapMode { map2d, globe3d }

class _TripBuilderScreenState extends State<TripBuilderScreen> {
  final TextEditingController _tripNameCtrl = TextEditingController();
  final TextEditingController _tripDatesCtrl = TextEditingController();
  final TextEditingController _searchCtrl = TextEditingController();
  final ScrollController _panelScrollCtrl = ScrollController();

  final List<_Waypoint> _waypoints = [];
  DateTimeRange? _tripRange;
  List<Map<String, dynamic>> _searchResults = [];
  StreamSubscription<User?>? _authSub;
  Timer? _searchDebounce;
  Timer? _autoSaveTimer;
  Timer? _routeCachePersistDebounce;
  double? _roadDistanceKm;
  double? _routeDurationMin;
  User? _currentUser;
  bool _isSaving = false;
  bool _autoSaveInFlight = false;
  String _lastPersistedSignature = '';
  DocumentReference<Map<String, dynamic>>? _lastSavedTripRef;

  String _transportMode = 'car';
  bool _adjustRoute = false;
  List<Map<String, dynamic>> _routeVia = [];
  List<String> _routeInstructions = [];
  List<Map<String, dynamic>> _routeGeometry3d = const [];

  List<String> _segmentRoutingTypes = [];
  List<String> _segmentTransportModes = [];
  Map<String, dynamic>? _transitArrivalStop;
  int _activeSegmentIndex = 0;

  bool _suspendMapTap = false;
  int _mapTapLockUntilMs = 0;
  bool _didShowOnboarding = false;
  bool _isRenamingTripName = false;
  _TripBuilderMapMode _mapMode = _TripBuilderMapMode.map2d;
  final FocusNode _renameTripNameFocus = FocusNode();

  static const List<String> _hikingSearchKeywords = <String>[
    'trail',
    'trailhead',
    'hiking',
    'hike',
    'backcountry',
    'camp_site',
    'camp site',
    'campsite',
    'campground',
    'portage',
    'provincial park',
    'national park',
    'conservation area',
    'wilderness',
    'forest',
    'trek',
    'footpath',
    'loop',
    'summit',
    'lookout',
    'canoe',
    'paddle',
  ];

  void _applyVerificationAutoloadTrip() {
    if (!_verificationAutoloadTrip) return;
    if (_hasTripBasics || _waypoints.isNotEmpty) return;

    final stopKeys = _verificationTripStopsDefine
        .split(',')
        .map((s) => s.trim().toLowerCase())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    final selected = <_Waypoint>[];
    for (final key in stopKeys) {
      final sample = _sampleLookup[key];
      if (sample == null) continue;
      selected.add(_Waypoint(sample.name, sample.lat, sample.lon));
    }
    if (selected.length < 2) return;

    final start = _stripTime(DateTime.now());
    final end = start.add(Duration(days: math.max(3, selected.length)));
    final totalDays = end.difference(start).inDays + 1;
    final base = totalDays ~/ selected.length;
    var remainder = totalDays % selected.length;
    for (final wp in selected) {
      wp.nights = math.max(1, base + (remainder > 0 ? 1 : 0));
      if (remainder > 0) remainder--;
    }

    _tripNameCtrl.text = 'Verification Route';
    _tripRange = DateTimeRange(start: start, end: end);
    _syncTripDatesText();
    _waypoints
      ..clear()
      ..addAll(selected);

    final segments = math.max(0, _waypoints.length - 1);
    _segmentRoutingTypes = List<String>.filled(segments, 'calculated');
    _segmentTransportModes = List<String>.filled(
      segments,
      _normalizeTransportMode(_transportMode),
    );
    debugPrint(
      'verificationAutoloadTrip enabled stops=${selected.length} tripRange=$_tripRange',
    );
  }

  String _tripStartDateYmd() {
    final r = _tripRange;
    if (r == null) return '';
    return _ymd(_stripTime(r.start));
  }

  String _tripEndDateYmd() {
    final r = _tripRange;
    if (r == null) return '';
    return _ymd(_stripTime(r.end));
  }

  Future<(double, double)?> _geocodeSuggestionLatLon(
    Map<String, dynamic> suggestion,
  ) async {
    final name = (suggestion['name'] ?? '').toString().trim();
    final address = (suggestion['address'] ?? '').toString().trim();
    final query = [name, address].where((s) => s.trim().isNotEmpty).join(' ');
    if (query.isEmpty) return null;
    final res = await searchNominatim(query);
    if (res.isEmpty) return null;
    final first = res.first;
    final lat = (first['lat'] as num?)?.toDouble() ?? 0.0;
    final lon = (first['lon'] as num?)?.toDouble() ?? 0.0;
    if (!lat.isFinite || !lon.isFinite) return null;
    return (lat, lon);
  }

  Future<void> _smartSuggestNextStop() async {
    if (_tripRange == null) {
      ScaffoldMessenger.of(context).showTryprSnackBar(
        const SnackBar(content: Text('Select a trip date range first')),
      );
      return;
    }
    if (_waypoints.isEmpty) {
      ScaffoldMessenger.of(context).showTryprSnackBar(
        const SnackBar(content: Text('Add a waypoint first')),
      );
      return;
    }
    final last = _waypoints.last;
    final startDate = _tripStartDateYmd();
    final endDate = _tripEndDateYmd();

    await showSmartRouteModal(
      context,
      title: '✨ Suggest Next Stay Stop',
      destinationName: formatLocationDisplay(raw: last.name).title,
      lat: last.lat,
      lon: last.lon,
      startDate: startDate,
      endDate: endDate,
      routeFromName: formatLocationDisplay(raw: last.name).title,
      onAddStop: (suggestion) async {
        final coords = await _geocodeSuggestionLatLon(suggestion);
        if (coords == null) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showTryprSnackBar(
            const SnackBar(content: Text('Could not locate that stop')),
          );
          return;
        }

        final pn = (suggestion['name'] ?? '').toString().trim();
        final addr = (suggestion['address'] ?? '').toString().trim();
        final raw =
            [pn, addr].where((s) => s.trim().isNotEmpty).join(', ').trim();
        await _addWaypointWithPrompt(
          raw.isNotEmpty ? raw : 'Suggested stop',
          coords.$1,
          coords.$2,
        );
      },
    );
  }

  Future<void> _smartFindStopBetween({required int afterIndex}) async {
    if (_tripRange == null) {
      ScaffoldMessenger.of(context).showTryprSnackBar(
        const SnackBar(content: Text('Select a trip date range first')),
      );
      return;
    }
    if (_waypoints.length < 2) {
      ScaffoldMessenger.of(context).showTryprSnackBar(
        const SnackBar(content: Text('Add at least two waypoints')),
      );
      return;
    }
    if (afterIndex < 0 || afterIndex >= _waypoints.length - 1) return;
    final a = _waypoints[afterIndex];
    final b = _waypoints[afterIndex + 1];
    final midLat = (a.lat + b.lat) / 2;
    final midLon = (a.lon + b.lon) / 2;

    final startDate = _tripStartDateYmd();
    final endDate = _tripEndDateYmd();

    await showSmartRouteModal(
      context,
      title: '✨ Find Stay Stop Between',
      destinationName:
          'Between ${formatLocationDisplay(raw: a.name).title} and ${formatLocationDisplay(raw: b.name).title}',
      lat: midLat,
      lon: midLon,
      startDate: startDate,
      endDate: endDate,
      routeFromName: formatLocationDisplay(raw: a.name).title,
      routeToName: formatLocationDisplay(raw: b.name).title,
      onAddStop: (suggestion) async {
        final coords = await _geocodeSuggestionLatLon(suggestion);
        if (coords == null) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showTryprSnackBar(
            const SnackBar(content: Text('Could not locate that stop')),
          );
          return;
        }

        // Add as a route via point so route timing updates without changing
        // overnight nights allocation.
        if (!mounted) return;
        setState(() {
          _adjustRoute = true;
          _upsertViaPoint(
            afterIndex: afterIndex,
            lat: coords.$1,
            lon: coords.$2,
          );
        });

        ScaffoldMessenger.of(context).showTryprSnackBar(
          SnackBar(
            content: Text(
              'Added a stay stop between ${formatLocationDisplay(raw: a.name).title} and ${formatLocationDisplay(raw: b.name).title}',
            ),
          ),
        );
      },
    );
  }

  Widget _surfaceCard({required Widget child, EdgeInsetsGeometry? padding}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Material(
        color: Colors.white,
        elevation: 4,
        child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
      ),
    );
  }

  Widget _footerBox({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(12.0),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
      ),
      child: child,
    );
  }

  Widget _webSafeMenuItemText(String text) {
    final t = SizedBox(width: double.infinity, child: Text(text));
    return kIsWeb ? WebInterceptor(child: t) : t;
  }

  bool _isAdventureMode(String mode) {
    final m = mode.trim().toLowerCase();
    return m == 'hiking' || m == 'portaging';
  }

  String _normalizeTransportMode(String raw) {
    var m = raw.trim().toLowerCase();
    if (m == 'driving') m = 'car';
    if (m == 'flying' || m == 'flight') m = 'plane';
    if (m == 'rail' || m == 'public_transit' || m == 'public transit') {
      m = 'train';
    }
    if (m == 'walking') m = 'walk';
    if (m == 'bicycling' || m == 'biking' || m == 'bikepacking') m = 'bike';
    if (m == 'canoe' || m == 'portage' || m == 'canoeing') m = 'portaging';
    if (m == 'backpacking') m = 'hiking';
    if (m == 'gas/stops' || m == 'gas-stops' || m == 'gasstops') {
      m = 'gas_stops';
    }
    for (final opt in _transportOptions) {
      if (opt.mode == m) return m;
    }
    return 'car';
  }

  String _segmentTransportModeAt(int segmentIndex) {
    if (segmentIndex < 0) return _normalizeTransportMode(_transportMode);
    if (segmentIndex >= _segmentTransportModes.length) {
      return _normalizeTransportMode(_transportMode);
    }
    return _normalizeTransportMode(_segmentTransportModes[segmentIndex]);
  }

  int? get _selectedSegmentIndex {
    final segments = math.max(0, _waypoints.length - 1);
    if (segments <= 0) return null;
    if (_activeSegmentIndex < 0 || _activeSegmentIndex >= segments) return 0;
    return _activeSegmentIndex;
  }

  void _clampActiveSegmentIndex() {
    final segments = math.max(0, _waypoints.length - 1);
    if (segments <= 0) {
      _activeSegmentIndex = 0;
      return;
    }
    if (_activeSegmentIndex < 0 || _activeSegmentIndex >= segments) {
      _activeSegmentIndex = 0;
    }
  }

  void _setActiveSegmentIndex(int segmentIndex) {
    final segments = math.max(0, _waypoints.length - 1);
    if (segments <= 0) return;
    final clamped = segmentIndex.clamp(0, segments - 1);
    if (_activeSegmentIndex == clamped) return;
    setState(() => _activeSegmentIndex = clamped);
  }

  bool _containsHikingKeyword(String raw) {
    final text = raw.trim().toLowerCase();
    if (text.isEmpty) return false;
    for (final keyword in _hikingSearchKeywords) {
      if (text.contains(keyword)) return true;
    }
    return false;
  }

  bool _isHikingTrailSegment(int segmentIndex) {
    if (segmentIndex < 0 || segmentIndex + 1 >= _waypoints.length) {
      return false;
    }
    final from = _waypoints[segmentIndex].name;
    final to = _waypoints[segmentIndex + 1].name;
    if (_containsHikingKeyword(from) || _containsHikingKeyword(to)) {
      return true;
    }
    final mode = _segmentTransportModeAt(segmentIndex);
    return mode == 'hiking' || mode == 'portaging';
  }

  bool _isCarModeBlockedForSegment(int segmentIndex) {
    return _isHikingTrailSegment(segmentIndex);
  }

  void _coerceBlockedCarModesToHiking() {
    for (var i = 0; i < _segmentTransportModes.length; i++) {
      final mode = _normalizeTransportMode(_segmentTransportModes[i]);
      if (mode == 'car' && _isCarModeBlockedForSegment(i)) {
        _segmentTransportModes[i] = 'portaging';
      } else {
        _segmentTransportModes[i] = mode;
      }
    }
  }

  void _showCarDisabledOnTrailMessage() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showTryprSnackBar(
      const SnackBar(
        content: Text(
          'Car mode is disabled on backcountry legs. Using portaging mode instead.',
        ),
      ),
    );
  }

  bool get _hasAnyTransitSegment {
    if (_waypoints.length < 2) {
      return _normalizeTransportMode(_transportMode) == 'train';
    }
    for (var i = 0; i < _waypoints.length - 1; i++) {
      if (_segmentTransportModeAt(i) == 'train') return true;
    }
    return false;
  }

  void _ensureSegmentRoutingTypesLength() {
    final segments = math.max(0, _waypoints.length - 1);
    if (_segmentRoutingTypes.length == segments) return;
    if (!mounted) return;
    setState(() {
      if (_segmentRoutingTypes.length > segments) {
        _segmentRoutingTypes = _segmentRoutingTypes.take(segments).toList();
      } else {
        _segmentRoutingTypes = [
          ..._segmentRoutingTypes,
          ...List.filled(segments - _segmentRoutingTypes.length, 'calculated'),
        ];
      }
    });
  }

  void _ensureSegmentTransportModesLength() {
    final segments = math.max(0, _waypoints.length - 1);
    if (_segmentTransportModes.length == segments) return;
    if (!mounted) return;
    setState(() {
      if (_segmentTransportModes.length > segments) {
        _segmentTransportModes = _segmentTransportModes.take(segments).toList();
      } else {
        _segmentTransportModes = [
          ..._segmentTransportModes,
          ...List.filled(
            segments - _segmentTransportModes.length,
            _normalizeTransportMode(_transportMode),
          ),
        ];
      }
      _segmentTransportModes =
          _segmentTransportModes.map(_normalizeTransportMode).toList();
      _coerceBlockedCarModesToHiking();
      _clampActiveSegmentIndex();
    });
  }

  Future<T?> _withMapTapSuspended<T>(Future<T?> Function() action) async {
    if (!mounted) return null;
    setState(() => _suspendMapTap = true);
    try {
      return await action();
    } finally {
      if (mounted) {
        _blockMapTapFor(milliseconds: 700);
        setState(() => _suspendMapTap = false);
      }
    }
  }

  void _blockMapTapFor({int milliseconds = 900}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final safeMs = milliseconds.clamp(0, 60000);
    final until = now + safeMs;
    if (until > _mapTapLockUntilMs) {
      _mapTapLockUntilMs = until;
    }
  }

  bool get _isMapTapBlocked {
    final now = DateTime.now().millisecondsSinceEpoch;
    return _suspendMapTap || now < _mapTapLockUntilMs;
  }

  Future<void> _addDroppedPinFromMapTap(double lat, double lon) async {
    if (_isMapTapBlocked) return;
    if (_tripRange == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showTryprSnackBar(
        const SnackBar(content: Text('Select a trip date range first')),
      );
      return;
    }

    String name = 'Dropped Pin';
    try {
      final resolved = await reverseNominatim(lat, lon);
      if (resolved != null && resolved.trim().isNotEmpty) {
        name = resolved;
      }
    } catch (_) {}

    if (!mounted) return;
    await _addWaypointWithPrompt(name, lat, lon);
  }

  int get _totalTripDays {
    final r = _tripRange;
    if (r == null) return 0;
    return r.end.difference(r.start).inDays + 1;
  }

  bool _countsTowardTripDays(int waypointIndex) {
    if (waypointIndex < 0 || waypointIndex >= _waypoints.length) return false;
    final count = _waypoints.length;
    if (count <= 1) return false;
    return waypointIndex > 0 && waypointIndex < count - 1;
  }

  int _effectiveWaypointNights(int waypointIndex) {
    if (!_countsTowardTripDays(waypointIndex)) return 0;
    final raw = _waypoints[waypointIndex].nights;
    return raw <= 0 ? 1 : raw;
  }

  int _offsetDaysBeforeWaypoint(int waypointIndex) {
    var total = 0;
    for (var i = 0; i < waypointIndex && i < _waypoints.length; i++) {
      total += _effectiveWaypointNights(i);
    }
    return total;
  }

  int get _assignedNights {
    var total = 0;
    for (var i = 0; i < _waypoints.length; i++) {
      total += _effectiveWaypointNights(i);
    }
    return total;
  }

  int get _remainingNights {
    final total = _totalTripDays;
    if (total == 0) return 0;
    return total - _assignedNights;
  }

  bool get _hasValidAllocation {
    final total = _totalTripDays;
    if (total == 0) return true;
    return _assignedNights == total;
  }

  bool get _hasTripBasics {
    return _tripNameCtrl.text.trim().isNotEmpty && _tripRange != null;
  }

  DateTime _stripTime(DateTime dt) => DateTime(dt.year, dt.month, dt.day);

  String _ymd(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  void _syncTripDatesText() {
    final range = _tripRange;
    if (range == null) {
      _tripDatesCtrl.text = '';
      return;
    }
    _tripDatesCtrl.text = '${_ymd(range.start)} → ${_ymd(range.end)}';
  }

  Future<DateTimeRange?> _pickTripDateRange() async {
    final now = DateTime.now();
    DateTime localStart = _tripRange?.start ?? _stripTime(now);
    DateTime localEnd =
        _tripRange?.end ?? _stripTime(now.add(const Duration(days: 3)));
    if (localEnd.isBefore(localStart)) {
      localEnd = localStart;
    }

    return _withMapTapSuspended(
      () => showDialog<DateTimeRange>(
        context: context,
        builder: (ctx) {
          return StatefulBuilder(
            builder: (ctx2, setState2) {
              return AlertDialog(
                title: const Text('Trip dates'),
                content: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final picked = await _pickSingleTripDate(
                              initialDate: localStart,
                              lastDate: localEnd,
                            );
                            if (picked == null) return;
                            setState2(() => localStart = picked);
                          },
                          icon: const Icon(Icons.event),
                          label: Text(_ymd(localStart)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Icon(Icons.arrow_forward, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final picked = await _pickSingleTripDate(
                              initialDate: localEnd,
                              firstDate: localStart,
                            );
                            if (picked == null) return;
                            setState2(() => localEnd = picked);
                          },
                          icon: const Icon(Icons.event_available),
                          label: Text(_ymd(localEnd)),
                        ),
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx2).pop(),
                    child: const Text('Cancel'),
                  ),
                  TextButton(
                    onPressed:
                        () => Navigator.of(
                          ctx2,
                        ).pop(DateTimeRange(start: localStart, end: localEnd)),
                    child: const Text('Apply'),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Future<DateTime?> _pickSingleTripDate({
    required DateTime initialDate,
    DateTime? firstDate,
    DateTime? lastDate,
  }) async {
    final now = DateTime.now();
    final first = firstDate ?? DateTime(now.year - 1);
    final last = lastDate ?? DateTime(now.year + 5);
    final safeInitial =
        initialDate.isBefore(first)
            ? first
            : (initialDate.isAfter(last) ? last : initialDate);
    final picked = await showDatePicker(
      context: context,
      initialDate: _stripTime(safeInitial),
      firstDate: _stripTime(first),
      lastDate: _stripTime(last),
    );
    if (picked == null) return null;
    return _stripTime(picked);
  }

  Future<void> _maybeShowOnboarding() async {
    if (_didShowOnboarding) return;
    _didShowOnboarding = true;
    if (_hasTripBasics) return;
    await _showTripBasicsDialog();
  }

  Future<void> _showTripBasicsDialog() async {
    final localName = TextEditingController(text: _tripNameCtrl.text.trim());
    final now = _stripTime(DateTime.now());
    DateTime localStart = _tripRange?.start ?? now;
    DateTime localEnd = _tripRange?.end ?? now.add(const Duration(days: 3));
    if (localEnd.isBefore(localStart)) {
      localEnd = localStart;
    }

    await _withMapTapSuspended(
      () => showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          return StatefulBuilder(
            builder: (ctx2, setState2) {
              final hasName = localName.text.trim().isNotEmpty;
              final hasDates = !localEnd.isBefore(localStart);
              final canContinue = hasName && hasDates;

              return AlertDialog(
                title: const Text('Start your trip'),
                content: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        controller: localName,
                        decoration: const InputDecoration(
                          labelText: 'Trip name',
                          prefixIcon: Icon(Icons.title),
                        ),
                        onChanged: (_) => setState2(() {}),
                      ),
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Trip dates',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: Colors.grey.shade700,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () async {
                                final picked = await _pickSingleTripDate(
                                  initialDate: localStart,
                                  lastDate: localEnd,
                                );
                                if (picked == null) return;
                                setState2(() => localStart = picked);
                              },
                              icon: const Icon(Icons.event),
                              label: Text(_ymd(localStart)),
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Icon(Icons.arrow_forward, size: 16),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () async {
                                final picked = await _pickSingleTripDate(
                                  initialDate: localEnd,
                                  firstDate: localStart,
                                );
                                if (picked == null) return;
                                setState2(() => localEnd = picked);
                              },
                              icon: const Icon(Icons.event_available),
                              label: Text(_ymd(localEnd)),
                            ),
                          ),
                        ],
                      ),
                      if (!hasDates)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            'Dates are required to plan your itinerary.',
                            style: TextStyle(color: Colors.red.shade700),
                          ),
                        ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed:
                        canContinue
                            ? () {
                              Navigator.of(ctx2).pop();
                            }
                            : null,
                    child: const Text('Continue'),
                  ),
                ],
              );
            },
          );
        },
      ),
    );

    final resolvedName = localName.text.trim();
    localName.dispose();

    if (!mounted) return;
    if (resolvedName.isNotEmpty && !localEnd.isBefore(localStart)) {
      setState(() {
        _tripNameCtrl.text = resolvedName;
        _tripRange = DateTimeRange(start: localStart, end: localEnd);
        _syncTripDatesText();
      });
    }
  }

  bool get _canPersistCurrentTripDraft {
    return _currentUser != null &&
        _tripRange != null &&
        _waypoints.isNotEmpty &&
        _tripNameCtrl.text.trim().isNotEmpty;
  }

  String _currentTripSignature() {
    final map = <String, dynamic>{
      'name': _tripNameCtrl.text.trim(),
      'transportMode': _transportMode,
      'rangeStart': _tripRange == null ? '' : _ymd(_tripRange!.start),
      'rangeEnd': _tripRange == null ? '' : _ymd(_tripRange!.end),
      'waypoints':
          _waypoints
              .map(
                (w) => {
                  'name': w.name,
                  'lat': w.lat,
                  'lon': w.lon,
                  'nights': w.nights,
                },
              )
              .toList(),
      'segmentRoutingTypes': _segmentRoutingTypes,
      'segmentTransportModes': _segmentTransportModes,
      'routeVia': _routeVia,
      'transitArrivalStop': _transitArrivalStop,
    };
    return map.toString();
  }

  List<Map<String, dynamic>> _currentWaypointMaps() {
    return _waypoints
        .map(
          (w) => {
            'name': w.name,
            'lat': w.lat,
            'lon': w.lon,
            'nights': w.nights,
          },
        )
        .toList(growable: false);
  }

  String _currentRouteCacheKey() {
    return buildRouteCacheKey(
      waypoints: _currentWaypointMaps(),
      transportMode: _transportMode,
      segmentTransportModes: _segmentTransportModes,
      segmentRoutingTypes: _segmentRoutingTypes,
      routeVia: _routeVia,
    );
  }

  Map<String, dynamic> _routeCachePayload() {
    final cachedGeometry = simplifyRouteGeometry(_routeGeometry3d);
    return {
      'routeCacheKey': _currentRouteCacheKey(),
      'routeGeometry3d': cachedGeometry,
      'routeInstructions': _routeInstructions.take(8).toList(growable: false),
    };
  }

  void _scheduleRouteCachePersist() {
    _routeCachePersistDebounce?.cancel();
    _routeCachePersistDebounce = Timer(const Duration(milliseconds: 600), () {
      unawaited(_persistRouteCacheIfAvailable());
    });
  }

  Future<void> _persistRouteCacheIfAvailable() async {
    final ref = _lastSavedTripRef;
    if (ref == null) return;
    try {
      await ref.set(_routeCachePayload(), SetOptions(merge: true));
    } catch (_) {
      // Cache persistence is non-fatal.
    }
  }

  Map<String, dynamic> _buildTripPayload({required bool includeCreatedAt}) {
    final range = _tripRange!;
    final tripStart = range.start;
    final tripEnd = range.end;
    final segmentCount = math.max(0, _waypoints.length - 1);
    final segmentRoutingTypes =
        _segmentRoutingTypes.take(segmentCount).map((v) {
          final n = v.trim().toLowerCase();
          return n == 'direct' ? 'direct' : 'calculated';
        }).toList();
    if (segmentRoutingTypes.length < segmentCount) {
      segmentRoutingTypes.addAll(
        List.filled(segmentCount - segmentRoutingTypes.length, 'calculated'),
      );
    }
    final segmentTransportModes =
        _segmentTransportModes
            .take(segmentCount)
            .map(_normalizeTransportMode)
            .toList();
    if (segmentTransportModes.length < segmentCount) {
      segmentTransportModes.addAll(
        List.filled(
          segmentCount - segmentTransportModes.length,
          _normalizeTransportMode(_transportMode),
        ),
      );
    }
    final filteredRouteVia =
        _routeVia
            .where((v) {
              final after = (v['afterIndex'] as num?)?.toInt();
              return after != null && after >= 0 && after < segmentCount;
            })
            .map((v) => Map<String, dynamic>.from(v))
            .toList();
    final requiresGearList =
        segmentTransportModes.any(_isAdventureMode) ||
        _isAdventureMode(_transportMode);
    final hasTransitMode =
        segmentTransportModes.any((m) => m.trim().toLowerCase() == 'train') ||
        (_transportMode == 'train' && segmentCount == 0);

    final payload = <String, dynamic>{
      'name': _tripNameCtrl.text.trim(),
      'days': _totalTripDays,
      'totalDays': _totalTripDays,
      'startDate': _ymd(tripStart),
      'endDate': _ymd(tripEnd),
      'updatedAt': FieldValue.serverTimestamp(),
      'totalKm': _totalKm,
      'transportMode': _transportMode,
      'routeVia': filteredRouteVia,
      'requires_gear_list': requiresGearList,
      'segmentRoutingTypes': segmentRoutingTypes,
      'segmentTransportModes': segmentTransportModes,
      ..._routeCachePayload(),
      'waypoints':
          _waypoints.asMap().entries.map((e) {
            final idx = e.key;
            final w = e.value;
            final nights = _effectiveWaypointNights(idx);
            final offset = _offsetDaysBeforeWaypoint(idx);
            final start = tripStart.add(Duration(days: offset));
            final end = start.add(Duration(days: math.max(0, nights - 1)));
            return {
              'name': w.name,
              'lat': w.lat,
              'lon': w.lon,
              'nights': nights,
              'startDate': _ymd(start),
              'endDate': _ymd(end),
            };
          }).toList(),
      if (hasTransitMode && _transitArrivalStop != null)
        'transitArrivalStop': _transitArrivalStop,
    };
    if (includeCreatedAt) {
      payload['createdAt'] = FieldValue.serverTimestamp();
    }
    return payload;
  }

  Future<bool> _persistTrip({required bool showFeedback}) async {
    if (!_canPersistCurrentTripDraft) return false;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;

    if (showFeedback) {
      if (_isSaving) return false;
      setState(() => _isSaving = true);
    } else {
      if (_autoSaveInFlight || _isSaving) return false;
      _autoSaveInFlight = true;
    }

    try {
      final payload = _buildTripPayload(
        includeCreatedAt: _lastSavedTripRef == null,
      );
      if (_lastSavedTripRef == null) {
        final ref = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .collection('trips')
            .add(payload);
        _lastSavedTripRef = ref;
      } else {
        await _lastSavedTripRef!.set(payload, SetOptions(merge: true));
      }

      _lastPersistedSignature = _currentTripSignature();
      if (showFeedback && mounted) {
        ScaffoldMessenger.of(context).showTryprSnackBar(
          const SnackBar(content: Text('Trip saved to My Trips')),
        );
      }
      return true;
    } catch (e) {
      if (showFeedback && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showTryprSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
      return false;
    } finally {
      if (showFeedback) {
        if (mounted) setState(() => _isSaving = false);
      } else {
        _autoSaveInFlight = false;
      }
    }
  }

  Future<void> _autoSaveTick() async {
    if (!_canPersistCurrentTripDraft) return;
    if (_isSaving || _autoSaveInFlight) return;
    final signature = _currentTripSignature();
    if (signature == _lastPersistedSignature) return;
    await _persistTrip(showFeedback: false);
  }

  void _finishTripNameRename() {
    if (!mounted) return;
    setState(() => _isRenamingTripName = false);
  }

  Future<int?> _promptNights({
    required String locationName,
    required int max,
    int? initialValue,
  }) async {
    if (!mounted) return null;
    final maxNights = math.max(1, max);
    int value = (initialValue ?? 1).clamp(1, maxNights);

    return _withMapTapSuspended(
      () => showDialog<int>(
        context: context,
        builder: (ctx) {
          return AlertDialog(
            title: const Text('How many nights?'),
            content: StatefulBuilder(
              builder: (ctx2, setState2) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      locationName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Text('Nights:'),
                        const SizedBox(width: 12),
                        Expanded(
                          child: DropdownButton<int>(
                            value: value,
                            isExpanded: true,
                            items: List.generate(
                              maxNights,
                              (i) => DropdownMenuItem(
                                value: i + 1,
                                child: Text(
                                  '${i + 1} night${i == 0 ? '' : 's'}',
                                ),
                              ),
                            ),
                            onChanged: (v) {
                              if (v == null) return;
                              setState2(() => value = v);
                            },
                          ),
                        ),
                      ],
                    ),
                    if (_tripRange != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8.0),
                        child: Text(
                          'Remaining nights in trip: ${_remainingNights.clamp(0, 999)}',
                          style: const TextStyle(color: Colors.black54),
                        ),
                      ),
                  ],
                );
              },
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(null),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(value),
                child: const Text('Add'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _addWaypointWithPrompt(
    String name,
    double lat,
    double lon,
  ) async {
    if (!mounted) return;

    final range = _tripRange;
    if (range == null) {
      ScaffoldMessenger.of(context).showTryprSnackBar(
        const SnackBar(content: Text('Select a trip date range first')),
      );
      return;
    }

    final remaining = _remainingNights;
    if (remaining <= 0) {
      ScaffoldMessenger.of(context).showTryprSnackBar(
        const SnackBar(
          content: Text('No nights left in the selected date range'),
        ),
      );
      return;
    }

    final nights = await _promptNights(locationName: name, max: remaining);
    if (nights == null) return;

    if (!mounted) return;
    setState(() {
      final wp = _Waypoint(name, lat, lon);
      wp.nights = nights;
      _waypoints.add(wp);

      final segments = math.max(0, _waypoints.length - 1);
      if (_segmentRoutingTypes.length < segments) {
        _segmentRoutingTypes = [
          ..._segmentRoutingTypes,
          ...List.filled(segments - _segmentRoutingTypes.length, 'calculated'),
        ];
      }
      if (_segmentTransportModes.length < segments) {
        _segmentTransportModes = [
          ..._segmentTransportModes,
          ...List.filled(
            segments - _segmentTransportModes.length,
            _normalizeTransportMode(_transportMode),
          ),
        ];
      }
      _coerceBlockedCarModesToHiking();
      _clampActiveSegmentIndex();

      _searchResults = [];
      _searchCtrl.clear();
    });
  }

  double? _coerceCoordinate(dynamic raw) {
    if (raw is num) return raw.toDouble();
    if (raw is String) return double.tryParse(raw);
    return null;
  }

  Future<void> _onHikingCampsiteTap(Map<String, dynamic> campsite) async {
    final lat = _coerceCoordinate(campsite['lat']);
    final lon = _coerceCoordinate(campsite['lon']);
    if (lat == null || lon == null || !lat.isFinite || !lon.isFinite) return;

    final name = (campsite['name'] ?? 'Campsite').toString().trim();
    final safeName = name.isEmpty ? 'Campsite' : name;
    final fromRouteKm =
        (campsite['distanceKmFromRoute'] as num?)?.toDouble() ?? 0.0;

    double? fromLastKm;
    String? lastStopName;
    if (_waypoints.isNotEmpty) {
      final last = _waypoints.last;
      fromLastKm = _haversine(last.lat, last.lon, lat, lon);
      lastStopName = formatLocationDisplay(raw: last.name).title;
    }

    final distanceLabel =
        fromLastKm != null
            ? '${fromLastKm.toStringAsFixed(1)} km from last point${lastStopName == null ? '' : ' ($lastStopName)'}'
            : '${fromRouteKm.toStringAsFixed(1)} km from your route';

    final shouldAdd = await _withMapTapSuspended(
      () => showDialog<bool>(
        context: context,
        builder: (ctx) {
          return AlertDialog(
            title: Text(safeName),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(distanceLabel),
                const SizedBox(height: 8),
                Text(
                  'Lat ${lat.toStringAsFixed(5)}, Lon ${lon.toStringAsFixed(5)}',
                  style: const TextStyle(color: Colors.black54, fontSize: 12),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Add to stay'),
              ),
            ],
          );
        },
      ),
    );

    if (shouldAdd != true) return;
    await _addWaypointWithPrompt(safeName, lat, lon);
  }

  // Small sample lookup so we don't need external geocoding packages
  final Map<String, _Waypoint> _sampleLookup = {
    'banff': _Waypoint('Banff, AB', 51.1784, -115.5708),
    'calgary': _Waypoint('Calgary, AB', 51.0447, -114.0719),
    'vancouver': _Waypoint('Vancouver, BC', 49.2827, -123.1207),
    'victoria': _Waypoint('Victoria, BC', 48.4284, -123.3656),
    'tofino': _Waypoint('Tofino, BC', 49.1526, -125.9033),
  };

  List<Map<String, dynamic>> _fallbackSearchResults(String q) {
    final query = q.trim().toLowerCase();
    if (query.isEmpty) return const [];
    return _sampleLookup.entries
        .where((e) => e.key.toLowerCase().contains(query))
        .map(
          (e) => {
            'name': e.value.name,
            'display_name': e.value.name,
            'lat': e.value.lat,
            'lon': e.value.lon,
          },
        )
        .toList();
  }

  bool get _isHikingSearchMode {
    final selectedSeg = _selectedSegmentIndex;
    if (selectedSeg != null) {
      final mode = _segmentTransportModeAt(selectedSeg);
      return mode == 'hiking' || mode == 'portaging';
    }
    final mode = _normalizeTransportMode(_transportMode);
    return mode == 'hiking' || mode == 'portaging';
  }

  String _hikingBiasedQuery(String q) {
    final trimmed = q.trim();
    if (trimmed.isEmpty) return trimmed;
    final lowered = trimmed.toLowerCase();
    for (final keyword in _hikingSearchKeywords) {
      if (lowered.contains(keyword)) return trimmed;
    }
    return '$trimmed hiking trail campsite portage canoe';
  }

  String _searchResultText(Map<String, dynamic> result) {
    final name = (result['name'] ?? '').toString().trim();
    final display = (result['display_name'] ?? '').toString().trim();
    final address = (result['address'] ?? '').toString().trim();
    return [
      name,
      display,
      address,
    ].where((part) => part.isNotEmpty).join(' ').toLowerCase();
  }

  bool _looksLikeHikingResult(Map<String, dynamic> result) {
    final text = _searchResultText(result);
    if (text.isEmpty) return false;
    for (final keyword in _hikingSearchKeywords) {
      if (text.contains(keyword)) return true;
    }
    return false;
  }

  List<Map<String, dynamic>> _filterHikingSearchResults(
    List<Map<String, dynamic>> results,
  ) {
    if (results.isEmpty) return const [];
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final result in results) {
      if (!_looksLikeHikingResult(result)) continue;
      final lat =
          (result['lat'] is num)
              ? (result['lat'] as num).toDouble()
              : double.tryParse(result['lat']?.toString() ?? '');
      final lon =
          (result['lon'] is num)
              ? (result['lon'] as num).toDouble()
              : double.tryParse(result['lon']?.toString() ?? '');
      if (lat == null || lon == null || !lat.isFinite || !lon.isFinite) {
        continue;
      }
      final key = '${lat.toStringAsFixed(5)},${lon.toStringAsFixed(5)}';
      if (!seen.add(key)) continue;
      out.add(result);
      if (out.length >= 8) break;
    }
    return out;
  }

  Future<List<Map<String, dynamic>>> _searchResultsForUi(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];

    var results = await searchNominatim(q);
    if (results.isEmpty) {
      results = _fallbackSearchResults(q);
    }

    if (!_isHikingSearchMode) return results;

    var filtered = _filterHikingSearchResults(results);
    if (filtered.isNotEmpty) return filtered;

    final focusedQuery = _hikingBiasedQuery(q);
    if (focusedQuery != q) {
      final focusedResults = await searchNominatim(focusedQuery);
      filtered = _filterHikingSearchResults(focusedResults);
      if (filtered.isNotEmpty) return filtered;
    }

    return const [];
  }

  String _rawLocationFromResult(Map<String, dynamic> r, String fallbackQuery) {
    final name = (r['name'] ?? '').toString().trim();
    final display = (r['display_name'] ?? r['address'] ?? '').toString().trim();

    if (name.isEmpty && display.isEmpty) return fallbackQuery;
    if (display.isEmpty) return name;
    if (name.isEmpty) return display;

    // If display already contains the name, keep display as the canonical raw.
    final dl = display.toLowerCase();
    final nl = name.toLowerCase();
    if (dl.contains(nl)) return display;

    // Otherwise combine so we keep both place name + street/city.
    return '$name, $display';
  }

  LocationDisplay _displayFromResult(Map<String, dynamic> r, String fallback) {
    final name = (r['name'] ?? '').toString().trim();
    final raw = _rawLocationFromResult(r, fallback);
    return formatLocationDisplay(placeName: name, raw: raw);
  }

  double get _totalKm {
    double total = 0.0;
    for (var i = 1; i < _waypoints.length; i++) {
      total += _haversine(
        _waypoints[i - 1].lat,
        _waypoints[i - 1].lon,
        _waypoints[i].lat,
        _waypoints[i].lon,
      );
    }
    return total;
  }

  Future<void> _showShareDialog(BuildContext context) async {
    if (_lastSavedTripRef == null) return;
    final me = FirebaseAuth.instance.currentUser;
    if (me == null) return;
    await _withMapTapSuspended(
      () => ShareTripDialog.show(
        context,
        tripRefPath: _lastSavedTripRef!.path,
        tripId: _lastSavedTripRef!.id,
        tripName: _tripNameCtrl.text.trim(),
      ),
    );
  }

  static double _haversine(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371.0; // km
    final dLat = _deg2rad(lat2 - lat1);
    final dLon = _deg2rad(lon2 - lon1);
    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_deg2rad(lat1)) *
            math.cos(_deg2rad(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return r * c;
  }

  static double _deg2rad(double deg) => deg * (math.pi / 180);

  void _addWaypointFromLookup(String key) {
    final k = key.toLowerCase().trim();
    final s = _sampleLookup[k];
    if (s != null) {
      _addWaypointWithPrompt(s.name, s.lat, s.lon);
    }
  }

  void _removeWaypoint(int index) {
    setState(() {
      if (index >= 0 && index < _waypoints.length) _waypoints.removeAt(index);

      final segments = math.max(0, _waypoints.length - 1);
      if (_segmentRoutingTypes.length > segments) {
        _segmentRoutingTypes = _segmentRoutingTypes.take(segments).toList();
      } else if (_segmentRoutingTypes.length < segments) {
        _segmentRoutingTypes = [
          ..._segmentRoutingTypes,
          ...List.filled(segments - _segmentRoutingTypes.length, 'calculated'),
        ];
      }
      if (_segmentTransportModes.length > segments) {
        _segmentTransportModes = _segmentTransportModes.take(segments).toList();
      } else if (_segmentTransportModes.length < segments) {
        _segmentTransportModes = [
          ..._segmentTransportModes,
          ...List.filled(
            segments - _segmentTransportModes.length,
            _normalizeTransportMode(_transportMode),
          ),
        ];
      }
      _coerceBlockedCarModesToHiking();
      _clampActiveSegmentIndex();

      // Via points are indexed by segment; safest is to clear.
      _routeVia = [];
    });
  }

  @override
  void initState() {
    super.initState();
    _applyVerificationAutoloadTrip();
    _syncTripDatesText();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _maybeShowOnboarding();
      }
    });
    // Listen to auth changes so the Save button enables/disables reactively.
    try {
      _authSub = FirebaseAuth.instance.authStateChanges().listen((u) {
        setState(() => _currentUser = u);
      });
    } catch (_) {
      // ignore in non-supported environments
    }
    _lastPersistedSignature = _currentTripSignature();
    _autoSaveTimer = Timer.periodic(
      const Duration(seconds: 6),
      (_) => _autoSaveTick(),
    );
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _searchDebounce?.cancel();
    _autoSaveTimer?.cancel();
    _routeCachePersistDebounce?.cancel();
    _tripNameCtrl.dispose();
    _tripDatesCtrl.dispose();
    _searchCtrl.dispose();
    _panelScrollCtrl.dispose();
    _renameTripNameFocus.dispose();
    super.dispose();
  }

  void _setTransportMode(String mode) {
    final m = _normalizeTransportMode(mode);
    final selectedSegment = _selectedSegmentIndex;
    if (selectedSegment != null) {
      _setSegmentTransportMode(selectedSegment, m, updateDefaultMode: true);
      return;
    }

    setState(() {
      _transportMode = m;
      activeRoutingMode = m;
      debugPrint('activeRoutingMode=$activeRoutingMode');
      _routeInstructions = [];
      if (!_hasAnyTransitSegment) {
        _transitArrivalStop = null;
      }
    });
  }

  void _setSegmentTransportMode(
    int segmentIndex,
    String mode, {
    bool updateDefaultMode = false,
  }) {
    final normalized = _normalizeTransportMode(mode);
    var didCoerceCarToHiking = false;
    setState(() {
      final segments = math.max(0, _waypoints.length - 1);
      if (_segmentTransportModes.length > segments) {
        _segmentTransportModes = _segmentTransportModes.take(segments).toList();
      } else if (_segmentTransportModes.length < segments) {
        _segmentTransportModes = [
          ..._segmentTransportModes,
          ...List.filled(
            segments - _segmentTransportModes.length,
            _normalizeTransportMode(_transportMode),
          ),
        ];
      }
      _clampActiveSegmentIndex();
      if (segmentIndex < 0 || segmentIndex >= _segmentTransportModes.length) {
        return;
      }
      _activeSegmentIndex = segmentIndex;
      var resolvedMode = normalized;
      if (resolvedMode == 'car' && _isCarModeBlockedForSegment(segmentIndex)) {
        resolvedMode = 'portaging';
        didCoerceCarToHiking = true;
      }
      _segmentTransportModes[segmentIndex] = resolvedMode;
      if (updateDefaultMode) {
        _transportMode = resolvedMode;
        activeRoutingMode = resolvedMode;
        debugPrint('activeRoutingMode=$activeRoutingMode');
      }
      if (resolvedMode == 'train' || resolvedMode == 'plane') {
        // Clear road-shaping corrections for this segment when switching to
        // rail/air to avoid preserving road-biased geometry.
        _routeVia =
            _routeVia.where((v) {
              final after = (v['afterIndex'] as num?)?.toInt();
              return after != segmentIndex;
            }).toList();
      }
      _routeInstructions = [];
      if (!_hasAnyTransitSegment) {
        _transitArrivalStop = null;
      }
    });
    if (didCoerceCarToHiking) {
      _showCarDisabledOnTrailMessage();
    }
  }

  void _setMapMode(_TripBuilderMapMode mode) {
    if (_mapMode == mode) return;
    final wasAdjustingRoute = _adjustRoute;
    setState(() {
      _mapMode = mode;
      if (mode == _TripBuilderMapMode.globe3d && _adjustRoute) {
        _adjustRoute = false;
      }
    });
    if (mode == _TripBuilderMapMode.globe3d && wasAdjustingRoute && mounted) {
      ScaffoldMessenger.of(context).showTryprSnackBar(
        const SnackBar(
          content: Text('Route line adjustments are available in 2D map mode.'),
        ),
      );
    }
  }

  void _upsertViaPoint({
    required int afterIndex,
    required double lat,
    required double lon,
  }) {
    setState(() {
      final idx = _routeVia.indexWhere(
        (v) =>
            (v['afterIndex'] as Object?)?.toString() == afterIndex.toString(),
      );
      final entry = {'afterIndex': afterIndex, 'lat': lat, 'lon': lon};
      if (idx >= 0) {
        _routeVia[idx] = entry;
      } else {
        _routeVia = [..._routeVia, entry];
      }
    });
  }

  Future<void> _onRouteTapped({
    required int afterIndex,
    required double lat,
    required double lon,
  }) async {
    if (!mounted) return;
    _setActiveSegmentIndex(afterIndex);

    await _withMapTapSuspended(
      () => showDialog<void>(
        context: context,
        builder: (ctx) {
          return AlertDialog(
            title: const Text('Route Options'),
            content: Text(
              'Between stop ${afterIndex + 1} and ${afterIndex + 2}',
              style: const TextStyle(color: Colors.black54),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  _upsertViaPoint(afterIndex: afterIndex, lat: lat, lon: lon);
                },
                child: const Text('Drop pin here'),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00897B),
                  foregroundColor: Colors.white,
                ),
                onPressed: () async {
                  Navigator.of(ctx).pop();
                  await _smartFindStopBetween(afterIndex: afterIndex);
                },
                icon: const Text('✨'),
                label: const Text('Find Stay Stop Between'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _moveViaPoint({
    required int viaIndex,
    required double lat,
    required double lon,
  }) {
    if (viaIndex < 0 || viaIndex >= _routeVia.length) return;
    setState(() {
      final current = Map<String, dynamic>.from(_routeVia[viaIndex]);
      current['lat'] = lat;
      current['lon'] = lon;
      _routeVia[viaIndex] = current;
    });
  }

  void _deleteViaPoint({required int viaIndex}) {
    if (viaIndex < 0 || viaIndex >= _routeVia.length) return;
    setState(() {
      final next = List<Map<String, dynamic>>.from(_routeVia);
      next.removeAt(viaIndex);
      _routeVia = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    final user = _currentUser ?? FirebaseAuth.instance.currentUser;

    Future<void> addFromFirstSearchResultOrLookup() async {
      if (_tripRange == null) {
        ScaffoldMessenger.of(context).showTryprSnackBar(
          const SnackBar(content: Text('Select a trip date range first')),
        );
        return;
      }

      final q = _searchCtrl.text.trim();
      if (q.isEmpty) return;

      if (_searchResults.isNotEmpty) {
        final r = _searchResults.first;
        final raw = _rawLocationFromResult(r, q);
        await _addWaypointWithPrompt(
          raw,
          (r['lat'] is num)
              ? (r['lat'] as num).toDouble()
              : double.tryParse(r['lat']?.toString() ?? '') ?? 0.0,
          (r['lon'] is num)
              ? (r['lon'] as num).toDouble()
              : double.tryParse(r['lon']?.toString() ?? '') ?? 0.0,
        );
        if (!mounted) return;
        setState(() => _searchResults = []);
        _searchCtrl.clear();
        return;
      }

      if (_isHikingSearchMode) {
        final results = await _searchResultsForUi(q);
        if (results.isNotEmpty) {
          final first = results.first;
          final raw = _rawLocationFromResult(first, q);
          await _addWaypointWithPrompt(
            raw,
            (first['lat'] is num)
                ? (first['lat'] as num).toDouble()
                : double.tryParse(first['lat']?.toString() ?? '') ?? 0.0,
            (first['lon'] is num)
                ? (first['lon'] as num).toDouble()
                : double.tryParse(first['lon']?.toString() ?? '') ?? 0.0,
          );
          if (!mounted) return;
          setState(() => _searchResults = []);
          _searchCtrl.clear();
          return;
        }
        ScaffoldMessenger.of(context).showTryprSnackBar(
          const SnackBar(
            content: Text('No trail or campsite matches found for that search'),
          ),
        );
        return;
      }

      // Fallback to sample lookup if user typed one of the predefined keys.
      _addWaypointFromLookup(q);
      _searchCtrl.clear();
    }

    Widget tripInfoPanel() {
      Widget stopItem(int i) {
        if (_segmentRoutingTypes.length != math.max(0, _waypoints.length - 1)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _ensureSegmentRoutingTypesLength();
          });
        }
        if (_segmentTransportModes.length !=
            math.max(0, _waypoints.length - 1)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _ensureSegmentTransportModesLength();
          });
        }

        final isFirst = i == 0;
        final isLast = i == _waypoints.length - 1;
        final next = (i + 1 < _waypoints.length) ? _waypoints[i + 1] : null;
        double segKm = 0.0;
        if (next != null) {
          segKm = _haversine(
            _waypoints[i].lat,
            _waypoints[i].lon,
            next.lat,
            next.lon,
          );
        }
        final countsTowardTripDays = _countsTowardTripDays(i);
        final nights = _waypoints[i].nights;
        final effectiveNights = _effectiveWaypointNights(i);
        final display = formatLocationDisplay(raw: _waypoints[i].name);

        final offsetDays = _offsetDaysBeforeWaypoint(i);
        String dateStr = '';
        if (_tripRange != null) {
          final start = _tripRange!.start.add(Duration(days: offsetDays));
          final end = start.add(
            Duration(days: math.max(0, effectiveNights - 1)),
          );
          dateStr = '${_ymd(start)} → ${_ymd(end)}';
        }

        final maxNightsForRow =
            _tripRange == null
                ? 30
                : math.max(
                  1,
                  _totalTripDays - (_assignedNights - effectiveNights),
                );

        final isSegmentRow = !isLast;
        final selectedSegment = _selectedSegmentIndex;
        final isActiveSegment =
            isSegmentRow && selectedSegment != null && selectedSegment == i;
        final carModeBlockedForSegment =
            isSegmentRow && _isCarModeBlockedForSegment(i);
        final segType =
            (isSegmentRow && i < _segmentRoutingTypes.length)
                ? _segmentRoutingTypes[i]
                : 'calculated';
        final segTypeNorm = segType.trim().toLowerCase();
        final segMode = _segmentTransportModeAt(i);

        final indicator = SizedBox(
          width: 26,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const SizedBox.expand(),
              Positioned(
                left: 12,
                top: 0,
                bottom: isLast ? 20 : 0,
                child: Container(width: 2, color: Colors.grey.shade300),
              ),
              Positioned(
                left: 4,
                top: 2,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: Colors.grey.shade400, width: 2),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      '${i + 1}',
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );

        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                indicator,
                const SizedBox(width: 8),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap:
                        isSegmentRow ? () => _setActiveSegmentIndex(i) : null,
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color:
                              isActiveSegment
                                  ? Theme.of(
                                    context,
                                  ).colorScheme.primary.withOpacity(0.45)
                                  : Colors.grey.shade200,
                          width: isActiveSegment ? 1.5 : 1.0,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Text(
                                  display.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              countsTowardTripDays
                                  ? SizedBox(
                                    width: 82,
                                    child: InputDecorator(
                                      decoration: const InputDecoration(
                                        labelText: 'Nights',
                                        isDense: true,
                                        contentPadding: EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 8,
                                        ),
                                      ),
                                      child: DropdownButtonHideUnderline(
                                        child: DropdownButton<int>(
                                          value: nights.clamp(
                                            1,
                                            maxNightsForRow,
                                          ),
                                          isDense: true,
                                          isExpanded: true,
                                          onTap: () {
                                            _blockMapTapFor(milliseconds: 2500);
                                          },
                                          items: List.generate(
                                            maxNightsForRow,
                                            (idx) => DropdownMenuItem(
                                              value: idx + 1,
                                              child: Text('${idx + 1}'),
                                            ),
                                          ),
                                          onChanged: (v) {
                                            if (v == null) return;
                                            _blockMapTapFor();
                                            setState(
                                              () => _waypoints[i].nights = v,
                                            );
                                          },
                                        ),
                                      ),
                                    ),
                                  )
                                  : Container(
                                    width: 82,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 10,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.grey.shade100,
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: Colors.grey.shade300,
                                      ),
                                    ),
                                    child: Text(
                                      isFirst ? 'Start' : 'End',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.grey.shade700,
                                      ),
                                    ),
                                  ),
                              const SizedBox(width: 6),
                              IconButton(
                                tooltip: 'Remove stop',
                                visualDensity: VisualDensity.compact,
                                constraints: const BoxConstraints.tightFor(
                                  width: 36,
                                  height: 36,
                                ),
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () => _removeWaypoint(i),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          if (display.subtitle.trim().isNotEmpty) ...[
                            Text(
                              display.subtitle,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.black54,
                              ),
                            ),
                            const SizedBox(height: 6),
                          ],
                          Text(
                            _tripRange == null
                                ? countsTowardTripDays
                                    ? '$nights night${nights == 1 ? '' : 's'}'
                                    : (isFirst ? 'Start point' : 'End point')
                                : countsTowardTripDays
                                ? '$nights night${nights == 1 ? '' : 's'} · $dateStr'
                                : '${isFirst ? 'Start point' : 'End point'} · $dateStr',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.black54,
                            ),
                          ),
                          const SizedBox(height: 8),
                          if (isSegmentRow)
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${segKm.toStringAsFixed(2)} km to next',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.black54,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Wrap(
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    const Text(
                                      'Mode:',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    SizedBox(
                                      width: 72,
                                      child: InputDecorator(
                                        decoration: const InputDecoration(
                                          isDense: true,
                                          contentPadding: EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 2,
                                          ),
                                          border: OutlineInputBorder(),
                                        ),
                                        child: DropdownButtonHideUnderline(
                                          child: DropdownButton<String>(
                                            value: segMode,
                                            isDense: true,
                                            isExpanded: true,
                                            onTap: () {
                                              _setActiveSegmentIndex(i);
                                              _blockMapTapFor(
                                                milliseconds: 2500,
                                              );
                                            },
                                            items:
                                                _transportOptions
                                                    .map(
                                                      (opt) => DropdownMenuItem(
                                                        value: opt.mode,
                                                        enabled:
                                                            !carModeBlockedForSegment ||
                                                            opt.mode != 'car',
                                                        child: Text(
                                                          opt.emoji,
                                                          style: TextStyle(
                                                            fontSize: 18,
                                                            color:
                                                                carModeBlockedForSegment &&
                                                                        opt.mode ==
                                                                            'car'
                                                                    ? Colors
                                                                        .grey
                                                                        .shade400
                                                                    : null,
                                                          ),
                                                        ),
                                                      ),
                                                    )
                                                    .toList(),
                                            onChanged: (value) {
                                              if (value == null) return;
                                              _setActiveSegmentIndex(i);
                                              _blockMapTapFor();
                                              _setSegmentTransportMode(
                                                i,
                                                value,
                                              );
                                            },
                                          ),
                                        ),
                                      ),
                                    ),
                                    const Text(
                                      'Routing:',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    ChoiceChip(
                                      visualDensity: VisualDensity.compact,
                                      label: const Text(
                                        'Calculated',
                                        style: TextStyle(fontSize: 12),
                                      ),
                                      selected: segTypeNorm == 'calculated',
                                      onSelected: (_) {
                                        _setActiveSegmentIndex(i);
                                        setState(() {
                                          if (i >= 0 &&
                                              i < _segmentRoutingTypes.length) {
                                            _segmentRoutingTypes[i] =
                                                'calculated';
                                          }
                                        });
                                      },
                                    ),
                                    ChoiceChip(
                                      visualDensity: VisualDensity.compact,
                                      label: const Text(
                                        'Direct',
                                        style: TextStyle(fontSize: 12),
                                      ),
                                      selected: segTypeNorm == 'direct',
                                      onSelected: (_) {
                                        _setActiveSegmentIndex(i);
                                        setState(() {
                                          if (i >= 0 &&
                                              i < _segmentRoutingTypes.length) {
                                            _segmentRoutingTypes[i] = 'direct';
                                          }
                                        });
                                      },
                                    ),
                                    TextButton.icon(
                                      style: TextButton.styleFrom(
                                        visualDensity: VisualDensity.compact,
                                        foregroundColor: const Color(
                                          0xFF00897B,
                                        ),
                                      ),
                                      onPressed: () {
                                        _setActiveSegmentIndex(i);
                                        _smartFindStopBetween(afterIndex: i);
                                      },
                                      icon: const Text('✨'),
                                      label: const Text(
                                        'Find Stay Stop',
                                        style: TextStyle(fontSize: 12),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            )
                          else
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Last stop',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.black54,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: TextButton.icon(
                                    style: TextButton.styleFrom(
                                      visualDensity: VisualDensity.compact,
                                      foregroundColor: const Color(0xFF00897B),
                                    ),
                                    onPressed: _smartSuggestNextStop,
                                    icon: const Text('✨'),
                                    label: const Text('Suggest Next Stay Stop'),
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }

      final selectedSegment = _selectedSegmentIndex;
      final selectedLegMode =
          selectedSegment == null
              ? _normalizeTransportMode(_transportMode)
              : _segmentTransportModeAt(selectedSegment);
      final selectedLegLabel =
          selectedSegment == null
              ? 'No leg selected yet'
              : 'Leg ${selectedSegment + 1}';

      final content = Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Stops & routing',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Text(
                  'Leg mode ($selectedLegLabel)',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children:
                          _transportOptions.map((opt) {
                            final mode = opt.mode;
                            final selected = selectedLegMode == mode;
                            final blockedForSelectedLeg =
                                selectedSegment != null &&
                                mode == 'car' &&
                                _isCarModeBlockedForSegment(selectedSegment);
                            return Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: ChoiceChip(
                                label: Text(
                                  opt.emoji,
                                  style: TextStyle(
                                    fontSize: 18,
                                    color:
                                        blockedForSelectedLeg
                                            ? Colors.grey.shade500
                                            : null,
                                  ),
                                ),
                                selected: selected,
                                showCheckmark: false,
                                visualDensity: VisualDensity.compact,
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                labelPadding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 2,
                                ),
                                selectedColor:
                                    Theme.of(context).colorScheme.primary,
                                backgroundColor: Colors.grey.shade200,
                                onSelected:
                                    blockedForSelectedLeg
                                        ? null
                                        : (v) {
                                          if (!v) return;
                                          _setTransportMode(mode);
                                        },
                              ),
                            );
                          }).toList(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'Top pills only set the selected leg. Tap a stop card to change which leg is active.',
              style: TextStyle(fontSize: 11, color: Colors.black54),
            ),
            if (_waypoints.length >= 2) ...[
              const SizedBox(height: 14),
              Row(
                children: [
                  Switch(
                    value: _adjustRoute,
                    onChanged: (v) {
                      setState(() => _adjustRoute = v);
                    },
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Adjust route line',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  if (_adjustRoute && _routeVia.isNotEmpty)
                    TextButton.icon(
                      onPressed: () {
                        setState(() => _routeVia = []);
                      },
                      icon: const Icon(Icons.clear),
                      label: const Text('Clear'),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 14),
            if (_tripRange != null)
              Text(
                'Nights assigned (stay stops only): $_assignedNights / $_totalTripDays',
                style: TextStyle(
                  fontSize: 13,
                  color:
                      _hasValidAllocation
                          ? Colors.black54
                          : Colors.red.shade700,
                  fontWeight: FontWeight.w700,
                ),
              ),
            if (_tripRange != null && !_hasValidAllocation)
              Padding(
                padding: const EdgeInsets.only(top: 4.0),
                child: Text(
                  'Adjust nights so they match the trip length.',
                  style: TextStyle(fontSize: 12, color: Colors.red.shade700),
                ),
              ),
            if (_tripRange != null && _waypoints.length >= 2)
              const Padding(
                padding: EdgeInsets.only(top: 4.0),
                child: Text(
                  'Start and end points are transit-only and do not count toward nights.',
                  style: TextStyle(fontSize: 11, color: Colors.black54),
                ),
              ),
            const SizedBox(height: 10),
            Text(
              'Total: ${((_roadDistanceKm ?? _totalKm)).toStringAsFixed(2)} km',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
            if (_routeDurationMin != null)
              Padding(
                padding: const EdgeInsets.only(top: 6.0),
                child: Text(
                  'Estimated time: ${_routeDurationMin!.toStringAsFixed(0)} min',
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ),
            if (_hasAnyTransitSegment && _routeInstructions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Train (suggested lines):',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    ..._routeInstructions.take(4).map((s) => Text('• $s')),
                  ],
                ),
              ),
            const SizedBox(height: 14),
            const Text('Stops', style: TextStyle(fontWeight: FontWeight.w900)),
            const SizedBox(height: 10),
            if (_waypoints.isEmpty)
              const Text('No stops yet. Search above or click the map to add.')
            else
              Column(
                children: [
                  for (var i = 0; i < _waypoints.length; i++) stopItem(i),
                ],
              ),
            const SizedBox(height: 8),
            if (user == null)
              const Padding(
                padding: EdgeInsets.only(bottom: 8.0),
                child: Text(
                  'Sign in to save trips',
                  style: TextStyle(color: Colors.black54),
                ),
              ),
            ElevatedButton.icon(
              onPressed:
                  (user == null ||
                          _tripRange == null ||
                          _waypoints.isEmpty ||
                          !_hasValidAllocation ||
                          _isSaving)
                      ? null
                      : () => _persistTrip(showFeedback: true),
              icon:
                  _isSaving
                      ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                      : const Icon(Icons.save),
              label: Text(_isSaving ? 'Saving...' : 'Save Trip'),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed:
                      _lastSavedTripRef == null
                          ? null
                          : () => _showShareDialog(context),
                  icon: const Icon(Icons.share),
                  label: const Text('Share'),
                ),
              ],
            ),
          ],
        ),
      );

      final scrollable = Scrollbar(
        controller: _panelScrollCtrl,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _panelScrollCtrl,
          child: content,
        ),
      );

      final card = ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Material(
          color: Colors.white,
          elevation: 18,
          shadowColor: Colors.black54,
          child: scrollable,
        ),
      );

      return kIsWeb ? WebInterceptor(child: card) : card;
    }

    return Scaffold(
      appBar: const TopTaskbar(dockProgress: 1.0),
      body: LayoutBuilder(
        builder: (ctx, box) {
          final maxW = box.maxWidth;
          final maxH = box.maxHeight;

          final sidePadding = (maxW < 520) ? 12.0 : 20.0;
          final topPadding = (maxH < 520) ? 12.0 : 20.0;
          final overlayTop = (maxH < 520) ? 12.0 : 16.0;
          final compactTopLayout = maxW < 980;
          final searchResultsMaxHeight = math.max(
            160.0,
            math.min(320.0, maxH * (compactTopLayout ? 0.34 : 0.42)),
          );
          final panelWidth = math.min(
            400.0,
            math.max(280.0, maxW - 2 * sidePadding),
          );

          Widget glassPill({required Widget child}) {
            // No PointerInterceptor here — the parent card/island already
            // wraps in PointerInterceptor.  Nesting platform-views inside
            // platform-views complicates CanvasKit compositing layers and
            // can break z-ordering.
            return ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: Material(
                color: Colors.white,
                elevation: 14,
                shadowColor: Colors.black45,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: child,
                ),
              ),
            );
          }

          const fieldRadius = 12.0;

          InputDecoration deco({
            required String hint,
            Widget? prefix,
            Widget? suffix,
          }) {
            return InputDecoration(
              isDense: true,
              hintText: hint,
              prefixIcon: prefix,
              suffixIcon: suffix,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(fieldRadius),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
            );
          }

          Widget tripDetailsIsland({required double maxWidth}) {
            final w = math.min(520.0, maxWidth);
            final name = _tripNameCtrl.text.trim();
            final range = _tripRange;
            final dateText =
                range == null
                    ? 'Select dates'
                    : '${_ymd(range.start)} → ${_ymd(range.end)}';

            final namePill = GestureDetector(
              onDoubleTap: () {
                if (_isRenamingTripName) return;
                setState(() => _isRenamingTripName = true);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) {
                    FocusScope.of(context).requestFocus(_renameTripNameFocus);
                  }
                });
              },
              child: glassPill(
                child:
                    _isRenamingTripName
                        ? SizedBox(
                          width: 190,
                          child: TextField(
                            controller: _tripNameCtrl,
                            focusNode: _renameTripNameFocus,
                            decoration: const InputDecoration(
                              isDense: true,
                              border: InputBorder.none,
                              hintText: 'Trip name',
                            ),
                            onEditingComplete: _finishTripNameRename,
                            onSubmitted: (_) => _finishTripNameRename(),
                          ),
                        )
                        : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.title, size: 16),
                            const SizedBox(width: 6),
                            Text(
                              name.isEmpty ? 'Trip name' : name,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
              ),
            );

            final datesPill = GestureDetector(
              onTap: () async {
                final picked = await _pickTripDateRange();
                if (picked == null || !mounted) return;
                setState(() {
                  _tripRange = picked;
                  _syncTripDatesText();
                });
              },
              child: glassPill(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.date_range, size: 16),
                    const SizedBox(width: 6),
                    Text(
                      dateText,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            );

            final content = Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [namePill, datesPill],
            );

            final card = ConstrainedBox(
              constraints: BoxConstraints(maxWidth: w),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Material(
                  color: Colors.white,
                  elevation: 18,
                  shadowColor: Colors.black26,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: content,
                  ),
                ),
              ),
            );

            return kIsWeb ? WebInterceptor(child: card) : card;
          }

          Widget searchIsland({required double maxWidth}) {
            final suffix = SizedBox(
              width: 104,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Add',
                    onPressed: addFromFirstSearchResultOrLookup,
                    icon: const Icon(Icons.add),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Add from list',
                    onOpened: () {
                      if (mounted) setState(() => _suspendMapTap = true);
                    },
                    onCanceled: () {
                      if (mounted) setState(() => _suspendMapTap = false);
                    },
                    onSelected: (v) {
                      debugPrint(
                        'addFromList onSelected value=$v tripRange_set=${_tripRange != null}',
                      );
                      if (mounted) setState(() => _suspendMapTap = false);
                      if (_tripRange == null) {
                        debugPrint(
                          'addFromList blocked_missing_tripRange value=$v',
                        );
                        ScaffoldMessenger.of(context).showTryprSnackBar(
                          const SnackBar(
                            content: Text('Select a trip date range first'),
                          ),
                        );
                        return;
                      }
                      // Defer one tick so the popup route fully dismisses before
                      // we attempt to open the nights prompt dialog.
                      Future<void>.delayed(Duration.zero, () {
                        if (!mounted) return;
                        debugPrint('addFromList dispatch_lookup value=$v');
                        _addWaypointFromLookup(v);
                      });
                    },
                    enabled: _tripRange != null,
                    itemBuilder:
                        (_) =>
                            _sampleLookup.keys
                                .map(
                                  (k) => PopupMenuItem(
                                    value: k,
                                    child: _webSafeMenuItemText(k),
                                  ),
                                )
                                .toList(),
                    child: const Icon(Icons.list),
                  ),
                ],
              ),
            );

            final locationSearchField = Semantics(
              label: 'Location search',
              textField: true,
              child: TextField(
                controller: _searchCtrl,
                textInputAction: TextInputAction.search,
                decoration: deco(
                  hint:
                      _isHikingSearchMode
                          ? 'Search trails, campsites & portages'
                          : 'Search locations',
                  prefix: const Icon(Icons.search),
                  suffix: suffix,
                ),
                onChanged: (v) {
                  if (!mounted) return;
                  setState(() {});
                  _searchDebounce?.cancel();
                  _searchDebounce = Timer(
                    const Duration(milliseconds: 400),
                    () async {
                      final q = _searchCtrl.text.trim();
                      if (q.isEmpty) {
                        if (mounted) setState(() => _searchResults = []);
                        return;
                      }
                      final results = await _searchResultsForUi(q);
                      if (mounted) setState(() => _searchResults = results);
                    },
                  );
                },
                onSubmitted: (v) async {
                  if (_tripRange == null) {
                    ScaffoldMessenger.of(context).showTryprSnackBar(
                      const SnackBar(
                        content: Text('Select a trip date range first'),
                      ),
                    );
                    return;
                  }

                  final q = v.trim();
                  if (q.isEmpty) return;

                  final results = await _searchResultsForUi(q);
                  if (results.isEmpty) {
                    if (_isHikingSearchMode) {
                      ScaffoldMessenger.of(context).showTryprSnackBar(
                        const SnackBar(
                          content: Text(
                            'Try a trail, campsite, or portage name in backcountry mode',
                          ),
                        ),
                      );
                    } else {
                      final match = _sampleLookup.keys.firstWhere(
                        (k) => k.toLowerCase().contains(q.toLowerCase()),
                        orElse: () => '',
                      );
                      if (match.isNotEmpty) {
                        _addWaypointFromLookup(match);
                      }
                    }
                    return;
                  }
                  final r = results.first;
                  final raw = _rawLocationFromResult(r, q);
                  await _addWaypointWithPrompt(
                    raw,
                    (r['lat'] is num)
                        ? (r['lat'] as num).toDouble()
                        : double.tryParse(r['lat'].toString()) ?? 0.0,
                    (r['lon'] is num)
                        ? (r['lon'] as num).toDouble()
                        : double.tryParse(r['lon'].toString()) ?? 0.0,
                  );
                },
              ),
            );

            final resultsList =
                _searchResults.isEmpty
                    ? const SizedBox.shrink()
                    : Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: Material(
                          color: Colors.white,
                          elevation: 16,
                          shadowColor: Colors.black26,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight: searchResultsMaxHeight,
                            ),
                            child: ListView.separated(
                              shrinkWrap: true,
                              itemCount: _searchResults.length,
                              separatorBuilder:
                                  (_, __) => const Divider(height: 1),
                              itemBuilder: (ctx2, i) {
                                final r = _searchResults[i];
                                final display = _displayFromResult(
                                  r,
                                  'Result ${i + 1}',
                                );
                                final raw = _rawLocationFromResult(
                                  r,
                                  display.title,
                                );
                                final lat =
                                    (r['lat'] is num)
                                        ? (r['lat'] as num).toDouble()
                                        : double.tryParse(
                                              r['lat'].toString(),
                                            ) ??
                                            0.0;
                                final lon =
                                    (r['lon'] is num)
                                        ? (r['lon'] as num).toDouble()
                                        : double.tryParse(
                                              r['lon'].toString(),
                                            ) ??
                                            0.0;
                                return ListTile(
                                  dense: true,
                                  title: Text(
                                    display.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  subtitle: Text(
                                    display.subtitle.isNotEmpty
                                        ? display.subtitle
                                        : '${lat.toStringAsFixed(4)}, ${lon.toStringAsFixed(4)}',
                                  ),
                                  onTap: () async {
                                    if (_tripRange == null) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showTryprSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            'Select a trip date range first',
                                          ),
                                        ),
                                      );
                                      return;
                                    }
                                    await _addWaypointWithPrompt(raw, lat, lon);
                                    if (mounted) {
                                      setState(() => _searchResults = []);
                                      _searchCtrl.clear();
                                    }
                                  },
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                    );

            final w = math.min(600.0, maxWidth);
            final content = Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [locationSearchField, resultsList],
            );

            final card = ConstrainedBox(
              constraints: BoxConstraints(maxWidth: w),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Material(
                  color: Colors.white,
                  elevation: 18,
                  shadowColor: Colors.black26,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: content,
                  ),
                ),
              ),
            );

            return kIsWeb ? WebInterceptor(child: card) : card;
          }

          Widget mapModeIsland() {
            final twoDSelected = _mapMode == _TripBuilderMapMode.map2d;
            final card = ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: Material(
                color: Colors.white,
                elevation: 16,
                shadowColor: Colors.black26,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 6,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ChoiceChip(
                        label: const Text('2D Map'),
                        selected: twoDSelected,
                        onSelected:
                            (_) => _setMapMode(_TripBuilderMapMode.map2d),
                        visualDensity: VisualDensity.compact,
                        showCheckmark: false,
                      ),
                      const SizedBox(width: 6),
                      ChoiceChip(
                        label: const Text('3D Globe'),
                        selected: !twoDSelected,
                        onSelected:
                            (_) => _setMapMode(_TripBuilderMapMode.globe3d),
                        visualDensity: VisualDensity.compact,
                        showCheckmark: false,
                      ),
                    ],
                  ),
                ),
              ),
            );
            return kIsWeb ? WebInterceptor(child: card) : card;
          }

          final contentMaxWidth = maxW - (2 * sidePadding);
          final tripDetailsMaxWidth =
              compactTopLayout
                  ? contentMaxWidth
                  : math.min(520.0, contentMaxWidth * 0.45);
          final searchMaxWidth =
              compactTopLayout
                  ? contentMaxWidth
                  : math.min(640.0, contentMaxWidth * 0.56);
          final topControls =
              compactTopLayout
                  ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      tripDetailsIsland(maxWidth: tripDetailsMaxWidth),
                      const SizedBox(height: 10),
                      searchIsland(maxWidth: searchMaxWidth),
                      if (kIsWeb) ...[
                        const SizedBox(height: 10),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: mapModeIsland(),
                        ),
                      ],
                    ],
                  )
                  : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Flexible(
                        fit: FlexFit.loose,
                        child: tripDetailsIsland(maxWidth: tripDetailsMaxWidth),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: searchIsland(maxWidth: searchMaxWidth),
                        ),
                      ),
                      if (kIsWeb) ...[
                        const SizedBox(width: 12),
                        mapModeIsland(),
                      ],
                    ],
                  );

          return Stack(
            children: [
              // Map background – direct child (no nested Stack) for proper
              // platform-view compositing on Flutter web.
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: _suspendMapTap,
                  child:
                      (kIsWeb && _mapMode == _TripBuilderMapMode.globe3d)
                          ? Globe3DEmbed(
                            points:
                                _waypoints
                                    .map(
                                      (w) => {
                                        'name': w.name,
                                        'lat': w.lat,
                                        'lon': w.lon,
                                      },
                                    )
                                    .toList(),
                            routeGeometry: _routeGeometry3d,
                            transportMode: _transportMode,
                            onRouteSummary: (distanceMeters, durationSeconds) {
                              if (!mounted) return;
                              setState(() {
                                _roadDistanceKm = distanceMeters / 1000.0;
                                _routeDurationMin = durationSeconds / 60.0;
                              });
                            },
                            onMapTap:
                                (!_adjustRoute)
                                    ? (lat, lon) async =>
                                        _addDroppedPinFromMapTap(lat, lon)
                                    : null,
                          )
                          : MapEmbed(
                            points:
                                _waypoints
                                    .map(
                                      (w) => {
                                        'name': w.name,
                                        'lat': w.lat,
                                        'lon': w.lon,
                                      },
                                    )
                                    .toList(),
                            transportMode: _transportMode,
                            segmentTransportModes: _segmentTransportModes,
                            routeVia: _routeVia,
                            segmentRoutingTypes: _segmentRoutingTypes,
                            onRouteInstructions: (lines) {
                              if (!mounted) return;
                              setState(() => _routeInstructions = lines);
                              _scheduleRouteCachePersist();
                            },
                            onRouteGeometry: (geometry) {
                              if (!mounted) return;
                              setState(() => _routeGeometry3d = geometry);
                              _scheduleRouteCachePersist();
                            },
                            onTransitArrivalStop: (arrivalStop) {
                              if (!mounted) return;
                              setState(() => _transitArrivalStop = arrivalStop);
                            },
                            onRouteSummary: (distanceMeters, durationSeconds) {
                              if (!mounted) return;
                              setState(() {
                                _roadDistanceKm = distanceMeters / 1000.0;
                                _routeDurationMin = durationSeconds / 60.0;
                              });
                            },
                            onHikingCampsiteTap: _onHikingCampsiteTap,
                            onMapTap:
                                (!_adjustRoute)
                                    ? (lat, lon) async =>
                                        _addDroppedPinFromMapTap(lat, lon)
                                    : null,
                            onRouteTapAddVia:
                                (_adjustRoute)
                                    ? (afterIndex, lat, lon) {
                                      if (_isMapTapBlocked) return;
                                      _onRouteTapped(
                                        afterIndex: afterIndex,
                                        lat: lat,
                                        lon: lon,
                                      );
                                    }
                                    : null,
                            onViaDragEnd:
                                (_adjustRoute)
                                    ? (viaIndex, lat, lon) {
                                      if (_isMapTapBlocked) return;
                                      _moveViaPoint(
                                        viaIndex: viaIndex,
                                        lat: lat,
                                        lon: lon,
                                      );
                                    }
                                    : null,
                            onViaTapDelete:
                                (_adjustRoute)
                                    ? (viaIndex) {
                                      if (_isMapTapBlocked) return;
                                      _deleteViaPoint(viaIndex: viaIndex);
                                    }
                                    : null,
                            routeComputingBannerTop:
                                compactTopLayout ? 148 : 108,
                          ),
                ),
              ),

              // Transparent barrier – blocks map taps when a dialog / popup is open
              if (kIsWeb && _suspendMapTap)
                Positioned.fill(
                  child: WebInterceptor(child: const SizedBox.expand()),
                ),
              Positioned.fill(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    sidePadding,
                    overlayTop,
                    sidePadding,
                    topPadding,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Listener(
                        onPointerDown:
                            (_) => _blockMapTapFor(milliseconds: 1200),
                        child: topControls,
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: Listener(
                            onPointerDown:
                                (_) => _blockMapTapFor(milliseconds: 1200),
                            child: SizedBox(
                              width: panelWidth,
                              child: tripInfoPanel(),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
