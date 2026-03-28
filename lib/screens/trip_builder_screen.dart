import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:trypr/utils/trypr_snackbar.dart';
import 'package:trypr/widgets/web_interceptor.dart';
import 'package:trypr/widgets/top_taskbar.dart';
import 'package:trypr/widgets/map_embed.dart';
import 'package:trypr/widgets/globe_3d_embed.dart';
import 'package:trypr/widgets/transit_leg_tabs_card.dart';
import 'package:trypr/services/geocode.dart';
import 'package:trypr/services/location_display.dart';
import 'package:trypr/widgets/activity_finder_modal.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:trypr/models/trip_model.dart';
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
  int nights;
  bool isStop;

  _Waypoint(
    this.name,
    this.lat,
    this.lon, {
    this.nights = 1,
    this.isStop = true,
  });
}

class _TransportOption {
  final String mode;
  final String label;
  final String emoji;

  const _TransportOption(this.mode, this.label, this.emoji);
}

class _TripTypeOption {
  final String id;
  final String label;
  final String emoji;
  final String summary;

  const _TripTypeOption(this.id, this.label, this.emoji, this.summary);
}

class _ExperienceOption {
  final String id;
  final String label;
  final String summary;

  const _ExperienceOption(this.id, this.label, this.summary);
}

class _DestinationDraft {
  final String name;
  final bool isStop;
  final int nights;
  final String routingType;

  const _DestinationDraft({
    required this.name,
    required this.isStop,
    required this.nights,
    required this.routingType,
  });
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
  _TransportOption('car', 'Road', '🚗'),
  _TransportOption('plane', 'Flight', '✈️'),
  _TransportOption('train', 'Rail', '🚆'),
  _TransportOption('walk', 'Walk', '🚶'),
  _TransportOption('bike', 'Bike', '🚲'),
  _TransportOption('portaging', 'Paddle / Portage', '🛶'),
  _TransportOption('hiking', 'Hiking', '🥾'),
  _TransportOption('gas_stops', 'Road Stops', '⛽'),
];

const List<_TripTypeOption> _tripTypeOptions = [
  _TripTypeOption(
    'road',
    'Road Trip',
    '🚗',
    'Drive between towns, parks, hotels, and regular stops.',
  ),
  _TripTypeOption(
    'portage',
    'Portage / Canoe',
    '🏕️',
    'Start at an access point, then plan campsites along water and portage routes.',
  ),
  _TripTypeOption(
    'hiking',
    'Hiking / Backpacking',
    '🥾',
    'Build a trail-first itinerary with campsites and trailheads.',
  ),
  _TripTypeOption(
    'mixed',
    'Mixed Mode',
    '🧭',
    'Combine road, rail, hiking, and backcountry legs in one trip.',
  ),
];

const List<_ExperienceOption> _experienceOptions = [
  _ExperienceOption(
    'beginner',
    'Beginner',
    'First-time or short, lower-commitment routes.',
  ),
  _ExperienceOption(
    'intermediate',
    'Intermediate',
    'Some outdoor experience and comfort with longer days.',
  ),
  _ExperienceOption(
    'advanced',
    'Advanced',
    'Remote, technical, or high-effort itineraries.',
  ),
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
  Timer? _routeLoadingHideTimer;
  double? _roadDistanceKm;
  double? _routeDurationMin;
  User? _currentUser;
  bool _isSaving = false;
  bool _autoSaveInFlight = false;
  String _lastPersistedSignature = '';
  DocumentReference<Map<String, dynamic>>? _lastSavedTripRef;

  String _tripType = 'road';
  String _experienceLevel = 'beginner';
  String _transportMode = 'car';
  bool _adjustRoute = false;
  List<Map<String, dynamic>> _routeVia = [];
  List<String> _routeInstructions = [];
  List<Map<String, dynamic>> _routeGeometry3d = const [];
  List<Map<String, dynamic>> _routeSegmentDetails = const [];

  List<String> _segmentRoutingTypes = [];
  List<String> _segmentTransportModes = [];
  Map<String, dynamic>? _transitArrivalStop;
  Map<String, dynamic>? _focusedTransitStep;
  int _focusedTransitStepRequestId = 0;
  int _activeSegmentIndex = 0;

  bool _suspendMapTap = false;
  int _mapTapLockUntilMs = 0;
  bool _didShowOnboarding = false;
  bool _isRenamingTripName = false;
  bool _isRouteComputing = false;
  _TripBuilderMapMode _mapMode = _TripBuilderMapMode.map2d;
  final FocusNode _renameTripNameFocus = FocusNode();
  DateTime? _routeLoadingShownAt;

  static const Duration _routeLoadingMinVisible = Duration(milliseconds: 1100);

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
    final totalNights = math.max(1, end.difference(start).inDays);
    final base = totalNights ~/ selected.length;
    var remainder = totalNights % selected.length;
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
    _segmentTransportModes = List<String>.filled(
      segments,
      _normalizeTransportMode(_transportMode),
    );
    _segmentRoutingTypes = List<String>.generate(
      segments,
      (index) => _defaultRoutingTypeForMode(_segmentTransportModes[index]),
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
    final legMode =
        _waypoints.length >= 2
            ? _segmentTransportModeAt(_waypoints.length - 2)
            : _transportMode;
    final startDate = _tripStartDateYmd();
    final endDate = _tripEndDateYmd();

    await showSmartRouteModal(
      context,
      title:
          _isAdventureMode(legMode)
              ? '✨ Suggest Next Campsite'
              : '✨ Suggest Next Stay Stop',
      destinationName: formatLocationDisplay(raw: last.name).title,
      lat: last.lat,
      lon: last.lon,
      startDate: startDate,
      endDate: endDate,
      routeFromName: formatLocationDisplay(raw: last.name).title,
      routeMode: legMode,
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
          segmentModeOverride: legMode,
          preferredRoutingType: _defaultRoutingTypeForMode(legMode),
          preferStop: true,
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
    final legMode = _segmentTransportModeAt(afterIndex);

    final startDate = _tripStartDateYmd();
    final endDate = _tripEndDateYmd();

    await showSmartRouteModal(
      context,
      title:
          _isAdventureMode(legMode)
              ? '✨ Find Campsite Between'
              : '✨ Find Stay Stop Between',
      destinationName:
          'Between ${formatLocationDisplay(raw: a.name).title} and ${formatLocationDisplay(raw: b.name).title}',
      lat: midLat,
      lon: midLon,
      startDate: startDate,
      endDate: endDate,
      routeFromName: formatLocationDisplay(raw: a.name).title,
      routeToName: formatLocationDisplay(raw: b.name).title,
      routeMode: legMode,
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
          insertIndex: afterIndex + 1,
          segmentModeOverride: legMode,
          preferredRoutingType: _segmentRoutingTypeAt(afterIndex),
          preferStop: true,
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

  String get _normalizedTripType => normalizeTripType(
    _tripType,
    transportMode: _transportMode,
    segmentTransportModes: _segmentTransportModes,
  );

  bool get _isPortageTrip => _normalizedTripType == 'portage';

  bool get _isHikingTrip => _normalizedTripType == 'hiking';

  bool get _isMixedTrip => _normalizedTripType == 'mixed';

  bool get _isAdventureTrip => isAdventureTripType(_normalizedTripType);

  bool get _allowsCustomMapDrops => !_isPortageTrip;

  String _defaultTransportModeForTripType(String tripType) {
    switch (normalizeTripType(tripType)) {
      case 'portage':
        return 'portaging';
      case 'hiking':
        return 'hiking';
      case 'mixed':
        return 'car';
      default:
        return 'car';
    }
  }

  List<_TransportOption> _availableTransportOptionsForTripType(
    String tripType,
  ) {
    final normalized = normalizeTripType(tripType);
    switch (normalized) {
      case 'portage':
        return _transportOptions
            .where(
              (opt) =>
                  opt.mode == 'portaging' ||
                  opt.mode == 'hiking' ||
                  opt.mode == 'walk',
            )
            .toList(growable: false);
      case 'hiking':
        return _transportOptions
            .where(
              (opt) =>
                  opt.mode == 'hiking' ||
                  opt.mode == 'walk' ||
                  opt.mode == 'bike',
            )
            .toList(growable: false);
      case 'mixed':
        return _transportOptions;
      default:
        return _transportOptions
            .where(
              (opt) =>
                  opt.mode == 'car' ||
                  opt.mode == 'plane' ||
                  opt.mode == 'train' ||
                  opt.mode == 'walk' ||
                  opt.mode == 'bike' ||
                  opt.mode == 'gas_stops',
            )
            .toList(growable: false);
    }
  }

  String _normalizedExperienceLevel([String? raw]) {
    final fallback = raw ?? _experienceLevel;
    final normalized = normalizeTripExperienceLevel(fallback);
    return normalized.isEmpty ? 'beginner' : normalized;
  }

  String _tripTypeSummary([String? raw]) {
    final normalized = normalizeTripType(raw ?? _tripType);
    for (final option in _tripTypeOptions) {
      if (option.id == normalized) return option.summary;
    }
    return 'Plan your route with the right transport and overnight context from the start.';
  }

  String _tripTypeSearchHint() {
    if (_isPortageTrip && _waypoints.isEmpty) {
      return 'Search access points, put-ins & canoe launches';
    }
    if (_isPortageTrip) {
      return 'Search campsites, lakes & portages';
    }
    if (_isHikingTrip) {
      return 'Search trailheads, campsites & trails';
    }
    if (_isMixedTrip) {
      return 'Search locations, campsites & transfer points';
    }
    return 'Search locations';
  }

  String _tripTypeGuideTitle() {
    if (_isPortageTrip && _waypoints.isEmpty) {
      return 'Step 1: Choose your access point';
    }
    if (_isPortageTrip) {
      return 'Step 2: Add reachable campsites';
    }
    if (_isHikingTrip) {
      return 'Trail-first trip planning';
    }
    if (_isMixedTrip) {
      return 'Blend modes as needed';
    }
    return 'Add towns, parks, and stays';
  }

  String _tripTypeGuideBody() {
    if (_isPortageTrip && _waypoints.isEmpty) {
      return 'Portage trips usually begin at an access point or boat launch. Try Brent Access Point, Shall Lake, or Magnetawan Lake, or click a blue access marker on the map.';
    }
    if (_isPortageTrip) {
      return 'Now add mapped campsites reachable from your access point, or use Suggested to get the next realistic stay stop. You can also click campsite and access-point markers on the map.';
    }
    if (_isHikingTrip) {
      return 'Start with a trailhead or campsite, then add only the overnight stops that should use your trip nights.';
    }
    if (_isMixedTrip) {
      return 'Pick the main trip type here, then switch individual legs below when a segment should be rail, road, or backcountry.';
    }
    return 'Search naturally for towns, parks, and addresses, or click the map to add a custom stop.';
  }

  String _modeSelectionHelperText() {
    if (_isPortageTrip) {
      return 'Portage trips default to waterway routing. Change a leg to Hiking if it should follow a trail instead.';
    }
    if (_isHikingTrip) {
      return 'Hiking trips default to trail routing. Change the selected leg only if one segment needs a different surface.';
    }
    if (_isMixedTrip) {
      return 'Top pills set the selected leg. Use Mixed Mode when one itinerary genuinely combines road, rail, and backcountry travel.';
    }
    return 'Top pills only set the selected leg. Tap a destination card to change which leg is active.';
  }

  String _currentDifficultyLabel() {
    return inferTripDifficultyLabel(
      tripType: _normalizedTripType,
      experienceLevel: _experienceLevel,
      distanceKm: _roadDistanceKm ?? _totalKm,
      estimatedDurationMin: _routeDurationMin,
      stopCount: _waypoints.length,
      segmentTransportModes: _segmentTransportModes,
    );
  }

  List<String> _currentRequiredSkills() {
    return inferTripRequiredSkills(
      tripType: _normalizedTripType,
      segmentTransportModes: _segmentTransportModes,
    );
  }

  bool get _isPortageAccessSearchStage => _isPortageTrip && _waypoints.isEmpty;

  bool _looksLikePortageAccessPointResult(Map<String, dynamic> result) {
    final text = _searchResultText(result);
    if (text.isEmpty) return false;
    const keywords = <String>[
      'access point',
      'put in',
      'put-in',
      'take out',
      'take-out',
      'boat launch',
      'canoe launch',
      'landing',
      'boat ramp',
      'dock',
      'launch',
    ];
    return keywords.any(text.contains);
  }

  String _portageAccessBiasedQuery(String q) {
    final trimmed = q.trim();
    if (trimmed.isEmpty) return trimmed;
    final lowered = trimmed.toLowerCase();
    if (_looksLikePortageAccessPointResult({
      'name': lowered,
      'display_name': lowered,
    })) {
      return trimmed;
    }
    return '$trimmed access point canoe launch boat launch put in landing';
  }

  List<Map<String, dynamic>> _filterPortageAccessResults(
    List<Map<String, dynamic>> results,
  ) {
    if (results.isEmpty) return const [];
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final result in results) {
      if (!_looksLikePortageAccessPointResult(result)) continue;
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

  ({String label, IconData icon, Color color}) _searchResultCategory(
    Map<String, dynamic> result,
  ) {
    final text = _searchResultText(result);
    if (_looksLikePortageAccessPointResult(result)) {
      return (
        label: 'Access point',
        icon: Icons.directions_boat_filled_outlined,
        color: const Color(0xFF1565C0),
      );
    }
    if (text.contains('campsite') ||
        text.contains('campground') ||
        text.contains('camp site')) {
      return (
        label: 'Campsite',
        icon: Icons.forest_outlined,
        color: const Color(0xFF2E7D32),
      );
    }
    if (text.contains('portage') ||
        text.contains('trail') ||
        text.contains('trailhead')) {
      return (
        label: 'Trail / portage',
        icon: Icons.alt_route,
        color: const Color(0xFF6D4C41),
      );
    }
    return (
      label: 'Location',
      icon: Icons.place_outlined,
      color: Colors.deepOrange.shade400,
    );
  }

  String _adventureDifficultyForDistance(double? distanceKm, String mode) {
    final km = distanceKm ?? 0.0;
    final normalizedMode = _normalizeTransportMode(mode);
    if (normalizedMode == 'portaging') {
      if (km >= 10) return 'Advanced';
      if (km >= 5) return 'Intermediate';
      return 'Beginner-friendly';
    }
    if (normalizedMode == 'hiking') {
      if (km >= 16) return 'Advanced';
      if (km >= 8) return 'Intermediate';
      return 'Beginner-friendly';
    }
    return km >= 12 ? 'Intermediate' : 'Beginner-friendly';
  }

  String _adventureEstimatedTimeForDistance(double? distanceKm, String mode) {
    final km = distanceKm ?? 0.0;
    final normalizedMode = _normalizeTransportMode(mode);
    final speedKmh = normalizedMode == 'portaging' ? 3.2 : 4.2;
    if (km <= 0) return 'Route time updates after you add it';
    final hours = km / speedKmh;
    if (hours < 1) {
      final minutes = math.max(20, (hours * 60).round());
      return '$minutes min';
    }
    final wholeHours = hours.floor();
    final minutes = ((hours - wholeHours) * 60).round();
    if (minutes == 0) return '$wholeHours hr';
    return '$wholeHours hr ${minutes.toString().padLeft(2, '0')} min';
  }

  String? _adventureWarningForDistance(double? distanceKm, String mode) {
    final km = distanceKm ?? 0.0;
    final normalizedMode = _normalizeTransportMode(mode);
    if (normalizedMode == 'portaging' && km >= 10) {
      return 'This is a long backcountry leg. Make sure your group is comfortable with a full day of paddling and portaging.';
    }
    if (normalizedMode == 'hiking' && km >= 18) {
      return 'This is a long hiking leg. Double-check daylight, pack weight, and campsite spacing before saving.';
    }
    return null;
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

  String _transportLabelForMode(String mode) {
    final normalized = _normalizeTransportMode(mode);
    for (final option in _transportOptions) {
      if (option.mode == normalized) return option.label;
    }
    return 'Route';
  }

  String _normalizeSegmentRoutingType(String raw, {String? mode}) {
    final normalizedMode = _normalizeTransportMode(mode ?? _transportMode);
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

  String _segmentRoutingTypeAt(int segmentIndex) {
    final mode = _segmentTransportModeAt(segmentIndex);
    if (segmentIndex < 0 || segmentIndex >= _segmentRoutingTypes.length) {
      return _defaultRoutingTypeForMode(mode);
    }
    return _normalizeSegmentRoutingType(
      _segmentRoutingTypes[segmentIndex],
      mode: mode,
    );
  }

  String _primaryRoutingLabelForMode(String mode) {
    switch (_normalizeTransportMode(mode)) {
      case 'hiking':
        return 'Trail';
      case 'portaging':
        return 'Waterway';
      default:
        return 'Calculated';
    }
  }

  String _routingDescriptionForSelection(String routingType, String mode) {
    final normalizedType = _normalizeSegmentRoutingType(
      routingType,
      mode: mode,
    );
    final normalizedMode = _normalizeTransportMode(mode);
    if (normalizedType == 'direct') {
      return 'Straight-line preview. Fast for rough planning, but it ignores mapped routes.';
    }
    switch (normalizedMode) {
      case 'hiking':
        return 'Follows mapped trails and trail connectors for a more realistic hiking line.';
      case 'portaging':
        return 'Follows mapped waterways and portage links instead of a crow-flies shortcut.';
      default:
        return 'Uses the normal routed path for this leg instead of a straight line.';
    }
  }

  String _defaultMapTapWaypointName() {
    final selectedSegment = _selectedSegmentIndex;
    final mode =
        selectedSegment == null
            ? _transportMode
            : _segmentTransportModeAt(selectedSegment);
    return _isAdventureMode(mode) ? 'Campsite' : 'Dropped Pin';
  }

  String _modeForWaypointInsert({int? insertIndex, String? override}) {
    if (override != null && override.trim().isNotEmpty) {
      return _normalizeTransportMode(override);
    }
    if (insertIndex != null &&
        insertIndex > 0 &&
        insertIndex < _waypoints.length) {
      return _segmentTransportModeAt(insertIndex - 1);
    }
    return _normalizeTransportMode(_transportMode);
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
      if (index == segmentIndex && mode == 'train' && steps is List) {
        return detail;
      }
    }

    final transitSegments = <int>[];
    for (var i = 0; i < _waypoints.length - 1; i++) {
      if (_segmentTransportModeAt(i) == 'train') {
        transitSegments.add(i);
      }
    }
    if (transitSegments.length == 1 &&
        transitSegments.first == segmentIndex &&
        _routeInstructions.isNotEmpty) {
      return {
        'segmentIndex': segmentIndex,
        'mode': 'train',
        'steps': _legacyTransitStepsFromInstructions(),
        if (_transitArrivalStop != null) 'arrivalStop': _transitArrivalStop,
      };
    }
    return null;
  }

  Widget _buildTransitLegCard(int segmentIndex) {
    if (segmentIndex < 0 || segmentIndex + 1 >= _waypoints.length) {
      return const SizedBox.shrink();
    }
    if (_segmentTransportModeAt(segmentIndex) != 'train') {
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
      padding: const EdgeInsets.only(left: 34),
      child: TransitLegTabsCard(
        originName: _waypoints[segmentIndex].name,
        destinationName: _waypoints[segmentIndex + 1].name,
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
          ...List<String>.generate(segments - _segmentRoutingTypes.length, (
            offset,
          ) {
            final segmentIndex = _segmentRoutingTypes.length + offset;
            final mode =
                segmentIndex < _segmentTransportModes.length
                    ? _segmentTransportModes[segmentIndex]
                    : _transportMode;
            return _defaultRoutingTypeForMode(mode);
          }),
        ];
      }
      _segmentRoutingTypes = List<String>.generate(segments, (index) {
        final raw =
            index < _segmentRoutingTypes.length
                ? _segmentRoutingTypes[index]
                : '';
        final mode =
            index < _segmentTransportModes.length
                ? _segmentTransportModes[index]
                : _transportMode;
        return _normalizeSegmentRoutingType(raw, mode: mode);
      });
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
    if (_isPortageTrip) {
      if (!mounted) return;
      final message =
          _isPortageAccessSearchStage
              ? 'Portage trips must start from a mapped access point. Click a blue access marker or search one by name.'
              : 'Portage trips only allow mapped campsites and access points. Click a campsite or access marker instead.';
      ScaffoldMessenger.of(
        context,
      ).showTryprSnackBar(SnackBar(content: Text(message)));
      return;
    }
    if (_tripRange == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showTryprSnackBar(
        const SnackBar(content: Text('Select a trip date range first')),
      );
      return;
    }

    String name = _defaultMapTapWaypointName();
    try {
      final resolved = await reverseNominatim(lat, lon);
      if (resolved != null && resolved.trim().isNotEmpty) {
        name = resolved;
      }
    } catch (_) {}

    if (!mounted) return;
    await _addWaypointWithPrompt(name, lat, lon);
  }

  void _handleRouteError(String message) {
    if (!mounted) return;
    setState(() {
      _roadDistanceKm = null;
      _routeDurationMin = null;
    });
    ScaffoldMessenger.of(
      context,
    ).showTryprSnackBar(SnackBar(content: Text(message)));
  }

  void _handleRouteComputingChanged(bool isComputing) {
    if (!mounted) return;

    if (isComputing) {
      _routeLoadingHideTimer?.cancel();
      _routeLoadingHideTimer = null;
      _routeLoadingShownAt = DateTime.now();
      if (_isRouteComputing) return;
      setState(() => _isRouteComputing = true);
      return;
    }

    if (!_isRouteComputing) {
      _routeLoadingShownAt = null;
      return;
    }

    final shownAt = _routeLoadingShownAt;
    final elapsed =
        shownAt == null
            ? _routeLoadingMinVisible
            : DateTime.now().difference(shownAt);
    final remaining = _routeLoadingMinVisible - elapsed;
    if (remaining > Duration.zero) {
      _routeLoadingHideTimer?.cancel();
      _routeLoadingHideTimer = Timer(remaining, () {
        if (!mounted) return;
        _routeLoadingHideTimer = null;
        _routeLoadingShownAt = null;
        if (_isRouteComputing) {
          setState(() => _isRouteComputing = false);
        }
      });
      return;
    }

    _routeLoadingHideTimer?.cancel();
    _routeLoadingHideTimer = null;
    _routeLoadingShownAt = null;
    setState(() => _isRouteComputing = false);
  }

  void _showMapHintSnackBar() {
    final message =
        _isPortageAccessSearchStage
            ? 'Tip: start your portage trip by clicking a blue access-point marker or searching one by name.'
            : _isPortageTrip
            ? 'Tip: portage trips only allow mapped campsites and access points. Click those markers on the map or search for them by name.'
            : _isAdventureTrip
            ? 'Tip: click the map to add a campsite, trail stop, or custom backcountry point.'
            : 'Tip: click the map to drop a custom stop anywhere on your route.';
    ScaffoldMessenger.of(
      context,
    ).showTryprSnackBar(SnackBar(content: Text(message)));
  }

  Widget _buildPlannerGuideCard() {
    final steps =
        _isPortageTrip
            ? <({String title, String detail, bool active, bool done})>[
              (
                title: 'Pick an access point',
                detail:
                    'Start from a real launch, put-in, or blue access marker.',
                active: _waypoints.isEmpty,
                done: _waypoints.isNotEmpty,
              ),
              (
                title: 'Add reachable campsites',
                detail:
                    'Stay on mapped waterways and portage links when building the route.',
                active: _waypoints.isNotEmpty && _waypoints.length < 2,
                done: _waypoints.length >= 2,
              ),
              (
                title: 'Tune each leg',
                detail:
                    'Only switch a leg away from water when it should truly become hiking.',
                active: _waypoints.length >= 2,
                done: false,
              ),
            ]
            : _isHikingTrip
            ? <({String title, String detail, bool active, bool done})>[
              (
                title: 'Start at a trailhead',
                detail:
                    'Choose the first trail access or campsite anchor for the trip.',
                active: _waypoints.isEmpty,
                done: _waypoints.isNotEmpty,
              ),
              (
                title: 'Stack overnight stops',
                detail:
                    'Add only the campsites that should count toward trip nights.',
                active: _waypoints.isNotEmpty && _waypoints.length < 2,
                done: _waypoints.length >= 2,
              ),
              (
                title: 'Refine the route',
                detail:
                    'Adjust leg mode and difficulty once the basic overnight flow exists.',
                active: _waypoints.length >= 2,
                done: false,
              ),
            ]
            : _isMixedTrip
            ? <({String title, String detail, bool active, bool done})>[
              (
                title: 'Drop in the anchors',
                detail: 'Start with the major places that define the trip.',
                active: _waypoints.isEmpty,
                done: _waypoints.isNotEmpty,
              ),
              (
                title: 'Switch leg modes',
                detail:
                    'Set the segments that should be rail, road, or backcountry.',
                active: _waypoints.isNotEmpty && _waypoints.length < 2,
                done: _waypoints.length >= 2,
              ),
              (
                title: 'Polish and save',
                detail:
                    'Check nights, tune routing, then save or share the itinerary.',
                active: _waypoints.length >= 2,
                done: false,
              ),
            ]
            : <({String title, String detail, bool active, bool done})>[
              (
                title: 'Add the first stop',
                detail:
                    'Search naturally for towns, parks, hotels, and addresses.',
                active: _waypoints.isEmpty,
                done: _waypoints.isNotEmpty,
              ),
              (
                title: 'Chain the route',
                detail:
                    'Stack more destinations to build the full road trip flow.',
                active: _waypoints.isNotEmpty && _waypoints.length < 2,
                done: _waypoints.length >= 2,
              ),
              (
                title: 'Adjust and save',
                detail:
                    'Fine-tune legs, route shape, and trip nights before saving.',
                active: _waypoints.length >= 2,
                done: false,
              ),
            ];
    final activeStep =
        steps.indexWhere((step) => step.active) >= 0
            ? steps.indexWhere((step) => step.active) + 1
            : steps.length;

    Widget buildStep(
      int index,
      ({String title, String detail, bool active, bool done}) step,
    ) {
      final accent =
          step.active
              ? const Color(0xFF0F766E)
              : step.done
              ? const Color(0xFF0284C7)
              : const Color(0xFF94A3B8);
      final badgeBg =
          step.active
              ? const Color(0xFFCCFBF1)
              : step.done
              ? const Color(0xFFE0F2FE)
              : const Color(0xFFFFFFFF);
      final titleColor =
          step.active ? const Color(0xFF0F172A) : const Color(0xFF334155);

      return Padding(
        padding: EdgeInsets.only(bottom: index == steps.length - 1 ? 0 : 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: badgeBg,
                shape: BoxShape.circle,
                border: Border.all(color: accent.withValues(alpha: 0.22)),
              ),
              child: Center(
                child:
                    step.done
                        ? Icon(Icons.check, size: 14, color: accent)
                        : Text(
                          '${index + 1}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w900,
                            color: accent,
                          ),
                        ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    step.title,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: titleColor,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    step.detail,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: Color(0xFF475569),
                      height: 1.32,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF0FDFA), Color(0xFFF8FAFC)],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0x33118A7E)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: const BoxDecoration(
                  color: Color(0xFFCCFBF1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.alt_route,
                  size: 17,
                  color: Color(0xFF0F766E),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Build Flow',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF0F766E),
                        letterSpacing: 0.3,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _tripTypeGuideTitle(),
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                '$activeStep/${steps.length}',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF0F766E),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _tripTypeGuideBody(),
            style: const TextStyle(
              fontSize: 11.5,
              color: Color(0xFF475569),
              height: 1.32,
            ),
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < steps.length; i++) buildStep(i, steps[i]),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF0F766E),
                  backgroundColor: Colors.white.withValues(alpha: 0.86),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                onPressed: () {
                  if (_waypoints.isEmpty) {
                    final message =
                        _isPortageAccessSearchStage
                            ? 'Choose your access point first, then Suggested will recommend the next campsite.'
                            : 'Add your first destination first, then Suggested can recommend the next stop.';
                    ScaffoldMessenger.of(
                      context,
                    ).showTryprSnackBar(SnackBar(content: Text(message)));
                    return;
                  }
                  _smartSuggestNextStop();
                },
                icon: const Icon(Icons.auto_awesome, size: 16),
                label: Text(
                  _isAdventureTrip ? 'Suggested next' : 'Suggested stop',
                ),
              ),
              if (_allowsCustomMapDrops)
                TextButton.icon(
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF0F766E),
                    backgroundColor: Colors.white.withValues(alpha: 0.7),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  onPressed: _showMapHintSnackBar,
                  icon: const Icon(Icons.touch_app_outlined, size: 16),
                  label: const Text('Map tip'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  int get _totalTripDays {
    final r = _tripRange;
    if (r == null) return 0;
    return r.end.difference(r.start).inDays + 1;
  }

  int get _totalTripNights {
    final r = _tripRange;
    if (r == null) return 0;
    return math.max(0, r.end.difference(r.start).inDays);
  }

  bool _canEditWaypointRole(int waypointIndex) {
    return waypointIndex >= 0 && waypointIndex < _waypoints.length;
  }

  bool _countsTowardTripDays(int waypointIndex) {
    if (!_canEditWaypointRole(waypointIndex)) return false;
    return _waypoints[waypointIndex].isStop;
  }

  int _effectiveWaypointNights(int waypointIndex) {
    if (!_countsTowardTripDays(waypointIndex)) return 0;
    final raw = _waypoints[waypointIndex].nights;
    return raw <= 0 ? 1 : raw;
  }

  int _maxNightsForWaypoint(int waypointIndex) {
    if (_tripRange == null) {
      final rawNights =
          waypointIndex >= 0 && waypointIndex < _waypoints.length
              ? _waypoints[waypointIndex].nights
              : 1;
      return math.max(1, rawNights);
    }
    final totalNights = _totalTripNights;
    if (totalNights <= 0) return 1;
    final effectiveNights = _effectiveWaypointNights(waypointIndex);
    return math.max(1, totalNights - (_assignedNights - effectiveNights));
  }

  void _setWaypointRole(int waypointIndex, bool isStop) {
    if (!_canEditWaypointRole(waypointIndex)) return;
    if (isStop && _tripRange != null && _totalTripNights <= 0) {
      ScaffoldMessenger.of(context).showTryprSnackBar(
        const SnackBar(
          content: Text(
            'Add at least one trip night before creating stay stops',
          ),
        ),
      );
      return;
    }
    setState(() {
      final waypoint = _waypoints[waypointIndex];
      waypoint.isStop = isStop;
      if (isStop) {
        final maxNights = _maxNightsForWaypoint(waypointIndex);
        waypoint.nights = math.max(1, math.min(waypoint.nights, maxNights));
      }
    });
  }

  void _setSegmentRoutingType(int segmentIndex, String routingType) {
    setState(() {
      final segments = math.max(0, _waypoints.length - 1);
      if (_segmentRoutingTypes.length > segments) {
        _segmentRoutingTypes = _segmentRoutingTypes.take(segments).toList();
      } else if (_segmentRoutingTypes.length < segments) {
        _segmentRoutingTypes = [
          ..._segmentRoutingTypes,
          ...List<String>.generate(segments - _segmentRoutingTypes.length, (
            offset,
          ) {
            final index = _segmentRoutingTypes.length + offset;
            final mode =
                index < _segmentTransportModes.length
                    ? _segmentTransportModes[index]
                    : _transportMode;
            return _defaultRoutingTypeForMode(mode);
          }),
        ];
      }
      if (segmentIndex < 0 || segmentIndex >= _segmentRoutingTypes.length) {
        return;
      }
      _segmentRoutingTypes[segmentIndex] = _normalizeSegmentRoutingType(
        routingType,
        mode: _segmentTransportModeAt(segmentIndex),
      );
      _resetComputedRouteState();
    });
    _scheduleRouteCachePersist();
  }

  bool _isWaypointOnly(int waypointIndex) {
    return _canEditWaypointRole(waypointIndex) &&
        !_countsTowardTripDays(waypointIndex);
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
    final total = _totalTripNights;
    if (total == 0) return 0;
    return total - _assignedNights;
  }

  bool get _hasValidAllocation {
    final total = _totalTripNights;
    if (total == 0) return true;
    return _assignedNights == total;
  }

  bool get _hasTripBasics {
    return _tripNameValidationMessage(_tripNameCtrl.text.trim()) == null &&
        _tripRange != null;
  }

  bool get _hasStayStops {
    for (var i = 0; i < _waypoints.length; i++) {
      if (_countsTowardTripDays(i)) return true;
    }
    return false;
  }

  bool _isPlaceholderWaypointName(String name) {
    final normalized = name.trim().toLowerCase();
    return normalized.isEmpty || normalized == 'dropped pin';
  }

  bool _looksLikeTestTripName(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized.isEmpty) return false;
    if (RegExp(
      r'^(test|testing|demo|sample|untitled|new trip|trip|my trip|asdf|qwer|zxcv)$',
    ).hasMatch(normalized)) {
      return true;
    }

    final tokens = normalized
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
    if (tokens.length != 1) return false;

    final token = tokens.first;
    if (RegExp(r'\d').hasMatch(token) && token.length <= 12) {
      return true;
    }

    final lettersOnly = token.replaceAll(RegExp(r'[^a-z]'), '');
    if (lettersOnly.length < 5) return false;

    if (!RegExp(r'[aeiouy]').hasMatch(lettersOnly)) {
      return true;
    }

    var longestConsonantRun = 0;
    var currentRun = 0;
    for (final rune in lettersOnly.runes) {
      final char = String.fromCharCode(rune);
      if ('aeiouy'.contains(char)) {
        currentRun = 0;
      } else {
        currentRun++;
        if (currentRun > longestConsonantRun) {
          longestConsonantRun = currentRun;
        }
      }
    }
    return lettersOnly.length >= 7 && longestConsonantRun >= 5;
  }

  String? _tripNameValidationMessage(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return 'Trip name is required.';
    if (trimmed.length < 3) {
      return 'Trip name must be at least 3 characters.';
    }
    if (_looksLikeTestTripName(trimmed)) {
      return 'Use a more descriptive trip name before saving.';
    }
    return null;
  }

  String? _waypointValidationMessage() {
    for (final waypoint in _waypoints) {
      if (_isPlaceholderWaypointName(waypoint.name)) {
        return 'Please name all your stops before saving.';
      }
    }
    return null;
  }

  String? _tripValidationMessage() {
    final nameMessage = _tripNameValidationMessage(_tripNameCtrl.text);
    if (nameMessage != null) return nameMessage;
    return _waypointValidationMessage();
  }

  Future<_DestinationDraft?> _showDestinationModal({
    required String initialName,
    required double lat,
    required double lon,
    required String segmentMode,
    String? preferredRoutingType,
    Map<String, dynamic>? campsiteData,
    bool preferStop = true,
    String confirmLabel = 'Add to Trip',
  }) async {
    if (!mounted || _tripRange == null) return null;

    final normalizedMode = _normalizeTransportMode(segmentMode);
    final suggestedName =
        _isPlaceholderWaypointName(initialName) ? '' : initialName.trim();
    var draftName = suggestedName;
    final details =
        campsiteData == null
            ? <String, dynamic>{}
            : Map<String, dynamic>.from(campsiteData);
    final primaryRoutingType = _defaultRoutingTypeForMode(normalizedMode);
    final totalTripNights = _totalTripNights;
    final availableNights = _remainingNights;
    final canCreateStayStop = totalTripNights > 0 && availableNights > 0;
    final distanceKm = (details['distanceKmFromRoute'] as num?)?.toDouble();
    final factRows = <MapEntry<String, String>>[];
    final routeDifficulty =
        (details['routeDifficulty'] ?? details['difficulty'])
            ?.toString()
            .trim() ??
        '';
    final estimatedTime = (details['estimatedTime'] ?? '').toString().trim();
    final accessibleFrom = (details['accessibleFrom'] ?? '').toString().trim();
    final routeWarning = (details['warning'] ?? '').toString().trim();

    void addFact(String label, dynamic raw) {
      final value = raw?.toString().trim() ?? '';
      if (value.isEmpty) return;
      factRows.add(MapEntry<String, String>(label, value));
    }

    addFact('Mode', _transportLabelForMode(normalizedMode));
    if (distanceKm != null && distanceKm.isFinite) {
      addFact('From route', '${distanceKm.toStringAsFixed(1)} km');
    }
    addFact(
      'Area',
      details['lakeName'] ??
          details['lake'] ??
          details['waterBody'] ??
          details['park'] ??
          details['region'],
    );
    addFact('Access', details['access']);
    addFact('Capacity', details['capacity']);
    addFact('Amenities', details['amenities']);
    addFact('Operator', details['operator']);
    addFact('Accessible from', accessibleFrom);
    addFact('Route fit', routeDifficulty);
    addFact('Est. time', estimatedTime);

    var isStop = preferStop && canCreateStayStop;
    var nights = canCreateStayStop ? 1 : 0;
    var routingType = _normalizeSegmentRoutingType(
      preferredRoutingType ?? primaryRoutingType,
      mode: normalizedMode,
    );

    return _withMapTapSuspended(
      () => showDialog<_DestinationDraft>(
        context: context,
        builder: (ctx) {
          final primaryRoutingLabel = _primaryRoutingLabelForMode(
            normalizedMode,
          );
          return StatefulBuilder(
            builder: (ctx2, setState2) {
              final trimmedName = draftName.trim();
              final nameError =
                  _isPlaceholderWaypointName(trimmedName)
                      ? 'Enter a custom stop name.'
                      : null;
              final previewRemaining = availableNights - (isStop ? nights : 0);
              final previewColor =
                  previewRemaining < 0
                      ? Colors.red.shade700
                      : previewRemaining == 0
                      ? const Color(0xFF2E7D32)
                      : Colors.black54;

              return AlertDialog(
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      details.isNotEmpty
                          ? 'Add campsite to trip'
                          : 'Add destination',
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Choose the stop type, nights, and routing in one place.',
                      style: TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                  ],
                ),
                content: SingleChildScrollView(
                  child: SizedBox(
                    width: 520,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextFormField(
                          initialValue: suggestedName,
                          autofocus: details.isEmpty,
                          textCapitalization: TextCapitalization.words,
                          decoration: InputDecoration(
                            labelText: 'Stop name',
                            hintText: 'Lake Louise Campground',
                            errorText: nameError,
                          ),
                          onChanged:
                              (value) => setState2(() => draftName = value),
                        ),
                        const SizedBox(height: 12),
                        if (factRows.isNotEmpty)
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: factRows
                                .map(
                                  (fact) => Chip(
                                    label: Text('${fact.key}: ${fact.value}'),
                                  ),
                                )
                                .toList(growable: false),
                          )
                        else
                          Text(
                            'Lat ${lat.toStringAsFixed(5)}, Lon ${lon.toStringAsFixed(5)}',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.black54,
                            ),
                          ),
                        const SizedBox(height: 18),
                        const Text(
                          'How should we treat this stop?',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 8),
                        RadioListTile<bool>(
                          value: true,
                          groupValue: isStop,
                          onChanged:
                              canCreateStayStop
                                  ? (_) => setState2(() {
                                    isStop = true;
                                    if (nights <= 0) nights = 1;
                                  })
                                  : null,
                          title: const Text('Stay stop'),
                          subtitle: Text(
                            canCreateStayStop
                                ? 'Overnight stay that uses trip nights and gets dated automatically.'
                                : 'No trip nights are left yet, so overnight stays are disabled for now.',
                          ),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                        RadioListTile<bool>(
                          value: false,
                          groupValue: isStop,
                          onChanged: (_) => setState2(() => isStop = false),
                          title: const Text('Waypoint'),
                          subtitle: const Text(
                            'Transit-only stop for navigation, resupply, or route shaping. Uses no nights.',
                          ),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                        const SizedBox(height: 10),
                        if (isStop) ...[
                          DropdownButtonFormField<int>(
                            initialValue: math.max(1, nights),
                            decoration: const InputDecoration(
                              labelText: 'How many nights here?',
                            ),
                            items: List.generate(
                                  math.max(1, availableNights),
                                  (index) => index + 1,
                                )
                                .map((value) {
                                  return DropdownMenuItem<int>(
                                    value: value,
                                    child: Text(
                                      '$value night${value == 1 ? '' : 's'}',
                                    ),
                                  );
                                })
                                .toList(growable: false),
                            onChanged:
                                canCreateStayStop
                                    ? (value) {
                                      if (value == null) return;
                                      setState2(() => nights = value);
                                    }
                                    : null,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Remaining nights after this stop: ${previewRemaining.clamp(0, 999)}${previewRemaining == 0 ? '  Perfect fit.' : ''}',
                            style: TextStyle(
                              fontSize: 12,
                              color: previewColor,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ] else
                          Text(
                            totalTripNights <= 0
                                ? 'This trip currently has 0 overnight nights, so new destinations will stay as waypoints until the date range changes.'
                                : 'Waypoints skip night allocation and only shape the route.',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.black54,
                            ),
                          ),
                        const SizedBox(height: 18),
                        const Text(
                          'Routing for this leg',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 8),
                        RadioListTile<String>(
                          value: primaryRoutingType,
                          groupValue: routingType,
                          onChanged:
                              (_) => setState2(
                                () => routingType = primaryRoutingType,
                              ),
                          title: Text(
                            '$primaryRoutingLabel routing (recommended)',
                          ),
                          subtitle: Text(
                            _routingDescriptionForSelection(
                              primaryRoutingType,
                              normalizedMode,
                            ),
                          ),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                        RadioListTile<String>(
                          value: 'direct',
                          groupValue: routingType,
                          onChanged:
                              (_) => setState2(() => routingType = 'direct'),
                          title: const Text('Direct line'),
                          subtitle: Text(
                            _routingDescriptionForSelection(
                              'direct',
                              normalizedMode,
                            ),
                          ),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                        if (routeWarning.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFF4E5),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: const Color(0xFFFFCC80),
                              ),
                            ),
                            child: Text(
                              routeWarning,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF8A5A00),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx2).pop(),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed:
                        nameError == null
                            ? () => Navigator.of(ctx2).pop(
                              _DestinationDraft(
                                name: trimmedName,
                                isStop: isStop,
                                nights: isStop ? math.max(1, nights) : 0,
                                routingType: routingType,
                              ),
                            )
                            : null,
                    child: Text(confirmLabel),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  void _insertWaypointAt({
    required int insertIndex,
    required _Waypoint waypoint,
    required String segmentMode,
    required String routingType,
  }) {
    final int targetIndex = insertIndex.clamp(0, _waypoints.length);
    final normalizedMode = _normalizeTransportMode(segmentMode);
    final normalizedRouting = _normalizeSegmentRoutingType(
      routingType,
      mode: normalizedMode,
    );

    setState(() {
      final existingSegmentCount = math.max(0, _waypoints.length - 1);
      final segmentModes = List<String>.generate(existingSegmentCount, (index) {
        if (index < _segmentTransportModes.length) {
          return _normalizeTransportMode(_segmentTransportModes[index]);
        }
        return _normalizeTransportMode(_transportMode);
      });
      final segmentRouting = List<String>.generate(existingSegmentCount, (
        index,
      ) {
        final mode =
            index < segmentModes.length ? segmentModes[index] : _transportMode;
        final raw =
            index < _segmentRoutingTypes.length
                ? _segmentRoutingTypes[index]
                : _defaultRoutingTypeForMode(mode);
        return _normalizeSegmentRoutingType(raw, mode: mode);
      });

      _waypoints.insert(targetIndex, waypoint);

      if (_waypoints.length > 1) {
        if (targetIndex > 0 && targetIndex < _waypoints.length - 1) {
          final splitIndex = targetIndex - 1;
          final inheritedMode =
              splitIndex < segmentModes.length
                  ? segmentModes[splitIndex]
                  : normalizedMode;
          segmentModes.insert(targetIndex, inheritedMode);
          if (splitIndex < segmentRouting.length) {
            segmentRouting[splitIndex] = normalizedRouting;
            segmentRouting.insert(targetIndex, normalizedRouting);
          } else {
            segmentRouting.add(normalizedRouting);
          }
        } else {
          final segmentIndex = targetIndex == 0 ? 0 : targetIndex - 1;
          segmentModes.insert(segmentIndex, normalizedMode);
          segmentRouting.insert(segmentIndex, normalizedRouting);
        }
      }

      _segmentTransportModes = segmentModes;
      _segmentRoutingTypes = segmentRouting;
      _normalizeWaypointStructureAfterMutation();
      _activeSegmentIndex = math.max(
        0,
        math.min(
          targetIndex == 0 ? 0 : targetIndex - 1,
          math.max(0, _waypoints.length - 2),
        ),
      );
      _resetComputedRouteState();
      _searchResults = [];
      _searchCtrl.clear();
    });
    _scheduleRouteCachePersist();
  }

  DateTime _minimumTripDate() => DateTime(1900, 1, 1);

  DateTime _maximumTripDate() => DateTime(2100, 12, 31);

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
                            );
                            if (picked == null) return;
                            setState2(() {
                              localStart = picked;
                              if (localEnd.isBefore(localStart)) {
                                localEnd = localStart;
                              }
                            });
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
                            );
                            if (picked == null) return;
                            setState2(() {
                              localEnd = picked;
                              if (localEnd.isBefore(localStart)) {
                                localStart = localEnd;
                              }
                            });
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
    final first = _stripTime(firstDate ?? _minimumTripDate());
    final last = _stripTime(lastDate ?? _maximumTripDate());
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
    var localTripType = _normalizedTripType;
    var localExperienceLevel = _normalizedExperienceLevel();
    var confirmed = false;
    if (localEnd.isBefore(localStart)) {
      localEnd = localStart;
    }

    await _withMapTapSuspended(
      () => showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (ctx) {
          return StatefulBuilder(
            builder: (ctx2, setState2) {
              final nameError = _tripNameValidationMessage(localName.text);
              final hasName = nameError == null;
              final hasDates = !localEnd.isBefore(localStart);
              final canContinue = hasName && hasDates;
              final selectedTripTypeLabel = tripTypeDisplayLabel(localTripType);
              final selectedTripSummary = _tripTypeSummary(localTripType);
              final showAdventureExperience =
                  normalizeTripType(localTripType) == 'portage' ||
                  normalizeTripType(localTripType) == 'hiking';

              return AlertDialog(
                title: Row(
                  children: [
                    const Expanded(child: Text('Start your trip')),
                    IconButton(
                      tooltip: 'Close',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => Navigator.of(ctx2).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                content: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '1. Choose a trip style',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: Colors.grey.shade700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _tripTypeOptions
                              .map((option) {
                                final selected =
                                    normalizeTripType(localTripType) ==
                                    option.id;
                                return ChoiceChip(
                                  label: Text(
                                    '${option.emoji} ${option.label}',
                                  ),
                                  selected: selected,
                                  showCheckmark: false,
                                  onSelected: (_) {
                                    setState2(() {
                                      localTripType = option.id;
                                      if (option.id == 'portage' ||
                                          option.id == 'hiking') {
                                        localExperienceLevel =
                                            _normalizedExperienceLevel(
                                              localExperienceLevel,
                                            );
                                      }
                                    });
                                  },
                                );
                              })
                              .toList(growable: false),
                        ),
                        const SizedBox(height: 10),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF8FAFC),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: const Color(0xFFE2E8F0)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                selectedTripTypeLabel,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                selectedTripSummary,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.black54,
                                ),
                              ),
                              if (normalizeTripType(localTripType) ==
                                  'portage') ...[
                                const SizedBox(height: 10),
                                const Text(
                                  'Portage trips start at access points like Brent Access Point, Shall Lake, or Magnetawan Lake. After that, search for campsites and portages reachable from your launch.',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                              if (normalizeTripType(localTripType) ==
                                  'hiking') ...[
                                const SizedBox(height: 10),
                                const Text(
                                  'Hiking trips work best when you start at a trailhead or campsite, then add only the overnights that should consume trip nights.',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (showAdventureExperience) ...[
                          const SizedBox(height: 16),
                          Text(
                            '2. Choose your experience level',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Colors.grey.shade700,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: _experienceOptions
                                .map((option) {
                                  final selected =
                                      _normalizedExperienceLevel(
                                        localExperienceLevel,
                                      ) ==
                                      option.id;
                                  return ChoiceChip(
                                    label: Text(option.label),
                                    selected: selected,
                                    showCheckmark: false,
                                    onSelected:
                                        (_) => setState2(
                                          () =>
                                              localExperienceLevel = option.id,
                                        ),
                                  );
                                })
                                .toList(growable: false),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _experienceOptions
                                .firstWhere(
                                  (option) =>
                                      option.id ==
                                      _normalizedExperienceLevel(
                                        localExperienceLevel,
                                      ),
                                  orElse: () => _experienceOptions.first,
                                )
                                .summary,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.black54,
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        TextField(
                          controller: localName,
                          textCapitalization: TextCapitalization.words,
                          decoration: InputDecoration(
                            labelText: 'Trip name',
                            prefixIcon: const Icon(Icons.title),
                            errorText: nameError,
                          ),
                          onChanged: (_) => setState2(() {}),
                        ),
                        const SizedBox(height: 12),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '3. Trip dates',
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
                                  );
                                  if (picked == null) return;
                                  setState2(() {
                                    localStart = picked;
                                    if (localEnd.isBefore(localStart)) {
                                      localEnd = localStart;
                                    }
                                  });
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
                                  );
                                  if (picked == null) return;
                                  setState2(() {
                                    localEnd = picked;
                                    if (localEnd.isBefore(localStart)) {
                                      localStart = localEnd;
                                    }
                                  });
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
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx2).pop(),
                    child: const Text('Not now'),
                  ),
                  TextButton(
                    onPressed:
                        canContinue
                            ? () {
                              confirmed = true;
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
    if (confirmed &&
        _tripNameValidationMessage(resolvedName) == null &&
        !localEnd.isBefore(localStart)) {
      setState(() {
        _tripNameCtrl.text = resolvedName;
        _tripRange = DateTimeRange(start: localStart, end: localEnd);
        _tripType = normalizeTripType(localTripType);
        _experienceLevel = _normalizedExperienceLevel(localExperienceLevel);
        if (_waypoints.isEmpty) {
          _transportMode = _defaultTransportModeForTripType(_tripType);
          activeRoutingMode = _transportMode;
        }
        _searchResults = [];
        _searchCtrl.clear();
        _syncTripDatesText();
        _resetComputedRouteState();
      });
    }
  }

  bool get _canPersistCurrentTripDraft {
    return _currentUser != null &&
        _tripRange != null &&
        _waypoints.isNotEmpty &&
        _tripValidationMessage() == null;
  }

  String _currentTripSignature() {
    final map = <String, dynamic>{
      'name': _tripNameCtrl.text.trim(),
      'tripType': _tripType,
      'experienceLevel': _experienceLevel,
      'transportMode': _transportMode,
      'rangeStart': _tripRange == null ? '' : _ymd(_tripRange!.start),
      'rangeEnd': _tripRange == null ? '' : _ymd(_tripRange!.end),
      'waypoints':
          _waypoints.asMap().entries.map((entry) {
            final idx = entry.key;
            final w = entry.value;
            return {
              'name': w.name,
              'lat': w.lat,
              'lon': w.lon,
              'nights': w.nights,
              'isStop': _countsTowardTripDays(idx),
            };
          }).toList(),
      'segmentRoutingTypes': _segmentRoutingTypes,
      'segmentTransportModes': _segmentTransportModes,
      'routeVia': _routeVia,
      'transitArrivalStop': _transitArrivalStop,
    };
    return map.toString();
  }

  List<Map<String, dynamic>> _currentWaypointMaps() {
    return _waypoints
        .asMap()
        .entries
        .map((entry) {
          final idx = entry.key;
          final w = entry.value;
          return {
            'name': w.name,
            'lat': w.lat,
            'lon': w.lon,
            'nights': w.nights,
            'isStop': _countsTowardTripDays(idx),
          };
        })
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
      'routeSegmentDetails': _routeSegmentDetails,
    };
  }

  void _resetComputedRouteState() {
    _routeInstructions = [];
    _routeGeometry3d = const [];
    _routeSegmentDetails = const [];
    _roadDistanceKm = null;
    _routeDurationMin = null;
    _transitArrivalStop = null;
    _focusedTransitStep = null;
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
    final segmentRoutingTypes = List<String>.generate(segmentCount, (index) {
      final raw =
          index < _segmentRoutingTypes.length
              ? _segmentRoutingTypes[index]
              : '';
      return _normalizeSegmentRoutingType(
        raw,
        mode: segmentTransportModes[index],
      );
    });
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
      'totalNights': _totalTripNights,
      'startDate': _ymd(tripStart),
      'endDate': _ymd(tripEnd),
      'updatedAt': FieldValue.serverTimestamp(),
      'totalKm': _waypoints.length >= 2 ? _totalKm : null,
      'estimatedDurationMin': _routeDurationMin,
      'tripType': _normalizedTripType,
      'experienceLevel': _normalizedExperienceLevel(),
      'difficultyLabel': _currentDifficultyLabel(),
      'requiredSkills': _currentRequiredSkills(),
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
            final stayEnd = start.add(Duration(days: math.max(0, nights - 1)));
            final checkout = start.add(Duration(days: math.max(0, nights)));
            return {
              'name': w.name,
              'lat': w.lat,
              'lon': w.lon,
              'nights': nights,
              'durationNights': nights,
              'isStop': _countsTowardTripDays(idx),
              'startDate': _ymd(start),
              'endDate': _ymd(stayEnd),
              'checkoutDate': _ymd(checkout),
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
    final validationMessage = _tripValidationMessage();
    if (validationMessage != null) {
      if (showFeedback && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showTryprSnackBar(SnackBar(content: Text(validationMessage)));
      }
      return false;
    }
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

  Future<void> _addWaypointWithPrompt(
    String name,
    double lat,
    double lon, {
    int? insertIndex,
    String? segmentModeOverride,
    String? preferredRoutingType,
    Map<String, dynamic>? campsiteData,
    bool preferStop = true,
  }) async {
    if (!mounted) return;

    final range = _tripRange;
    if (range == null) {
      ScaffoldMessenger.of(context).showTryprSnackBar(
        const SnackBar(content: Text('Select a trip date range first')),
      );
      return;
    }

    final resolvedInsertIndex = insertIndex ?? _waypoints.length;
    final segmentMode = _modeForWaypointInsert(
      insertIndex: resolvedInsertIndex,
      override: segmentModeOverride,
    );
    final draft = await _showDestinationModal(
      initialName: name,
      lat: lat,
      lon: lon,
      segmentMode: segmentMode,
      preferredRoutingType: preferredRoutingType,
      campsiteData: campsiteData,
      preferStop: preferStop,
    );
    if (draft == null || !mounted) return;

    final waypoint = _Waypoint(
      draft.name,
      lat,
      lon,
      nights: draft.isStop ? math.max(1, draft.nights) : 1,
      isStop: draft.isStop,
    );
    _insertWaypointAt(
      insertIndex: resolvedInsertIndex,
      waypoint: waypoint,
      segmentMode: segmentMode,
      routingType: draft.routingType,
    );
    if (!mounted) return;
    if (!draft.isStop) {
      ScaffoldMessenger.of(context).showTryprSnackBar(
        const SnackBar(
          content: Text(
            'Added as a waypoint. Toggle it to Stop if it should use trip nights.',
          ),
        ),
      );
    }
  }

  void _normalizeWaypointStructureAfterMutation() {
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
    _segmentTransportModes =
        _segmentTransportModes.map(_normalizeTransportMode).toList();
    _coerceBlockedCarModesToHiking();
    _segmentRoutingTypes = List<String>.generate(segments, (index) {
      final raw =
          index < _segmentRoutingTypes.length
              ? _segmentRoutingTypes[index]
              : '';
      return _normalizeSegmentRoutingType(
        raw,
        mode: _segmentTransportModes[index],
      );
    });
    for (final waypoint in _waypoints) {
      waypoint.nights = math.max(1, waypoint.nights);
    }
    _clampActiveSegmentIndex();
  }

  double? _coerceCoordinate(dynamic raw) {
    if (raw is num) return raw.toDouble();
    if (raw is String) return double.tryParse(raw);
    return null;
  }

  void _setBoundaryWaypointFromAccessPoint({
    required bool isStart,
    required String name,
    required double lat,
    required double lon,
  }) {
    final boundary = _Waypoint(name, lat, lon, nights: 1, isStop: false);
    setState(() {
      if (_waypoints.isEmpty) {
        _waypoints.add(boundary);
      } else if (_waypoints.length == 1) {
        final existing = _waypoints.first;
        final otherBoundary = _Waypoint(
          existing.name,
          existing.lat,
          existing.lon,
          nights: math.max(1, existing.nights),
          isStop: existing.isStop,
        );
        _waypoints
          ..clear()
          ..addAll(
            isStart ? [boundary, otherBoundary] : [otherBoundary, boundary],
          );
      } else if (isStart) {
        _waypoints[0] = boundary;
      } else {
        _waypoints[_waypoints.length - 1] = boundary;
      }

      _normalizeWaypointStructureAfterMutation();
      _resetComputedRouteState();
    });
    _scheduleRouteCachePersist();
  }

  Future<void> _onPortageAccessTap(Map<String, dynamic> accessPoint) async {
    final lat = _coerceCoordinate(accessPoint['lat']);
    final lon = _coerceCoordinate(accessPoint['lon']);
    if (lat == null || lon == null || !lat.isFinite || !lon.isFinite) return;

    if (_tripRange == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showTryprSnackBar(
        const SnackBar(content: Text('Select a trip date range first')),
      );
      return;
    }

    final name = (accessPoint['name'] ?? 'Portage access').toString().trim();
    final safeName = name.isEmpty ? 'Portage access' : name;
    final routeKm =
        (accessPoint['distanceKmFromRoute'] as num?)?.toDouble() ?? 0.0;
    if (_waypoints.isEmpty) {
      setState(() {
        _tripType = 'portage';
        _transportMode = 'portaging';
        activeRoutingMode = _transportMode;
      });
      _setBoundaryWaypointFromAccessPoint(
        isStart: true,
        name: safeName,
        lat: lat,
        lon: lon,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showTryprSnackBar(
        SnackBar(
          content: Text(
            '$safeName set as your launch point. Next, add campsites or portages.',
          ),
        ),
      );
      return;
    }
    final hasStart = _waypoints.isNotEmpty;
    final hasEnd = _waypoints.length >= 2;
    final startLabel =
        !hasStart
            ? 'Add as start point'
            : (_waypoints.length == 1
                ? 'Insert as start point'
                : 'Replace start point');
    final endLabel =
        !hasEnd
            ? 'Add as end point'
            : (_waypoints.length == 1
                ? 'Insert as end point'
                : 'Replace end point');
    final currentStart =
        hasStart ? formatLocationDisplay(raw: _waypoints.first.name).title : '';
    final currentEnd =
        hasEnd ? formatLocationDisplay(raw: _waypoints.last.name).title : '';

    final choice = await _withMapTapSuspended(
      () => showDialog<String>(
        context: context,
        builder: (ctx) {
          return AlertDialog(
            title: Text(safeName),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Use this portage access point as your trip boundary.'),
                const SizedBox(height: 8),
                Text(
                  'About ${routeKm.toStringAsFixed(1)} km from the visible route network',
                ),
                const SizedBox(height: 8),
                Text(
                  'Lat ${lat.toStringAsFixed(5)}, Lon ${lon.toStringAsFixed(5)}',
                  style: const TextStyle(color: Colors.black54, fontSize: 12),
                ),
                if (currentStart.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Current start: $currentStart',
                    style: const TextStyle(color: Colors.black54, fontSize: 12),
                  ),
                ],
                if (currentEnd.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Current end: $currentEnd',
                    style: const TextStyle(color: Colors.black54, fontSize: 12),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop('start'),
                child: Text(startLabel),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop('end'),
                child: Text(endLabel),
              ),
            ],
          );
        },
      ),
    );

    if (choice != 'start' && choice != 'end') return;
    final isStart = choice == 'start';
    _setBoundaryWaypointFromAccessPoint(
      isStart: isStart,
      name: safeName,
      lat: lat,
      lon: lon,
    );

    if (!mounted) return;
    final boundaryLabel = isStart ? 'start point' : 'end point';
    ScaffoldMessenger.of(context).showTryprSnackBar(
      SnackBar(content: Text('$safeName set as your $boundaryLabel')),
    );
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
    final campsiteMode = _modeForWaypointInsert(
      override: (campsite['mode'] ?? '').toString(),
    );
    final routeDistanceKm = fromLastKm ?? fromRouteKm;
    await _addWaypointWithPrompt(
      safeName,
      lat,
      lon,
      segmentModeOverride: (campsite['mode'] ?? '').toString(),
      preferredRoutingType: _defaultRoutingTypeForMode(campsiteMode),
      campsiteData: <String, dynamic>{
        ...Map<String, dynamic>.from(campsite),
        'distanceKmFromRoute': routeDistanceKm,
        'access': campsite['access'] ?? distanceLabel,
        if (lastStopName != null && lastStopName.isNotEmpty)
          'accessibleFrom': lastStopName,
        'routeDifficulty': _adventureDifficultyForDistance(
          routeDistanceKm,
          campsiteMode,
        ),
        'estimatedTime': _adventureEstimatedTimeForDistance(
          routeDistanceKm,
          campsiteMode,
        ),
        'warning': _adventureWarningForDistance(routeDistanceKm, campsiteMode),
      },
      preferStop: true,
    );
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

    if (_isPortageAccessSearchStage) {
      var results = await searchNominatim(q);
      if (results.isEmpty) {
        results = _fallbackSearchResults(q);
      }

      var filtered = _filterPortageAccessResults(results);
      if (filtered.isNotEmpty) return filtered;

      final focusedQuery = _portageAccessBiasedQuery(q);
      if (focusedQuery != q) {
        final focusedResults = await searchNominatim(focusedQuery);
        filtered = _filterPortageAccessResults(focusedResults);
        if (filtered.isNotEmpty) return filtered;
      }

      return const [];
    }

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

  Future<void> _handleSearchResultSelection(
    Map<String, dynamic> result,
    String fallbackQuery,
  ) async {
    if (_tripRange == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showTryprSnackBar(
        const SnackBar(content: Text('Select a trip date range first')),
      );
      return;
    }

    final raw = _rawLocationFromResult(result, fallbackQuery);
    final lat =
        (result['lat'] is num)
            ? (result['lat'] as num).toDouble()
            : double.tryParse(result['lat']?.toString() ?? '') ?? 0.0;
    final lon =
        (result['lon'] is num)
            ? (result['lon'] as num).toDouble()
            : double.tryParse(result['lon']?.toString() ?? '') ?? 0.0;

    if (_isPortageAccessSearchStage) {
      if (!_looksLikePortageAccessPointResult(result)) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showTryprSnackBar(
          const SnackBar(
            content: Text(
              'Portage trips usually start at an access point. Search an access point first, then add campsites.',
            ),
          ),
        );
        return;
      }
      await _onPortageAccessTap({
        ...result,
        'name': raw,
        'lat': lat,
        'lon': lon,
      });
      return;
    }

    await _addWaypointWithPrompt(raw, lat, lon);
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
      _normalizeWaypointStructureAfterMutation();

      // Via points are indexed by segment; safest is to clear.
      _routeVia = [];
      _resetComputedRouteState();
    });
    _scheduleRouteCachePersist();
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
    _routeLoadingHideTimer?.cancel();
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
      if (_waypoints.isEmpty && !_isMixedTrip) {
        _tripType = normalizeTripType(
          _tripType,
          transportMode: m,
          segmentTransportModes: const <String>[],
        );
      }
      activeRoutingMode = m;
      debugPrint('activeRoutingMode=$activeRoutingMode');
      _resetComputedRouteState();
    });
    _scheduleRouteCachePersist();
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
      if (_segmentRoutingTypes.length > segments) {
        _segmentRoutingTypes = _segmentRoutingTypes.take(segments).toList();
      } else if (_segmentRoutingTypes.length < segments) {
        _segmentRoutingTypes = [
          ..._segmentRoutingTypes,
          ...List<String>.generate(segments - _segmentRoutingTypes.length, (
            offset,
          ) {
            final index = _segmentRoutingTypes.length + offset;
            final mode =
                index < _segmentTransportModes.length
                    ? _segmentTransportModes[index]
                    : _transportMode;
            return _defaultRoutingTypeForMode(mode);
          }),
        ];
      }
      _activeSegmentIndex = segmentIndex;
      var resolvedMode = normalized;
      if (resolvedMode == 'car' && _isCarModeBlockedForSegment(segmentIndex)) {
        resolvedMode = 'portaging';
        didCoerceCarToHiking = true;
      }
      _segmentTransportModes[segmentIndex] = resolvedMode;
      final keepDirect =
          segmentIndex < _segmentRoutingTypes.length &&
          _segmentRoutingTypes[segmentIndex].trim().toLowerCase() == 'direct';
      _segmentRoutingTypes[segmentIndex] =
          keepDirect ? 'direct' : _defaultRoutingTypeForMode(resolvedMode);
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
      _resetComputedRouteState();
    });
    _scheduleRouteCachePersist();
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
      _resetComputedRouteState();
    });
    _scheduleRouteCachePersist();
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
      _resetComputedRouteState();
    });
    _scheduleRouteCachePersist();
  }

  void _deleteViaPoint({required int viaIndex}) {
    if (viaIndex < 0 || viaIndex >= _routeVia.length) return;
    setState(() {
      final next = List<Map<String, dynamic>>.from(_routeVia);
      next.removeAt(viaIndex);
      _routeVia = next;
      _resetComputedRouteState();
    });
    _scheduleRouteCachePersist();
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
        await _handleSearchResultSelection(r, q);
        if (!mounted) return;
        setState(() => _searchResults = []);
        _searchCtrl.clear();
        return;
      }

      if (_isHikingSearchMode) {
        final results = await _searchResultsForUi(q);
        if (results.isNotEmpty) {
          final first = results.first;
          await _handleSearchResultSelection(first, q);
          if (!mounted) return;
          setState(() => _searchResults = []);
          _searchCtrl.clear();
          return;
        }
        ScaffoldMessenger.of(context).showTryprSnackBar(
          SnackBar(
            content: Text(
              _isPortageAccessSearchStage
                  ? 'No access-point matches found. Try Brent Access Point, Shall Lake, or click a blue access marker.'
                  : 'No trail or campsite matches found for that search',
            ),
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
        final isStop = _waypoints[i].isStop;
        final nights = _waypoints[i].nights;
        final effectiveNights = _effectiveWaypointNights(i);
        final display = formatLocationDisplay(raw: _waypoints[i].name);
        final boundaryLabel =
            isFirst && isLast
                ? 'Start / End'
                : isFirst
                ? 'Start'
                : isLast
                ? 'End'
                : null;

        String dateStr = '';
        if (_tripRange != null && countsTowardTripDays) {
          final offsetDays = _offsetDaysBeforeWaypoint(i);
          final start = _tripRange!.start.add(Duration(days: offsetDays));
          final checkout = start.add(
            Duration(days: math.max(0, effectiveNights)),
          );
          dateStr = '${_ymd(start)} → ${_ymd(checkout)}';
        }

        final maxNightsForRow =
            _tripRange == null ? 30 : _maxNightsForWaypoint(i);

        String staySummary;
        if (countsTowardTripDays) {
          staySummary =
              '$effectiveNights night${effectiveNights == 1 ? '' : 's'}';
        } else if (boundaryLabel != null) {
          staySummary = '$boundaryLabel · No stay';
        } else {
          staySummary = 'Waypoint · No stay';
        }
        final staySummaryWithDates =
            _tripRange == null || dateStr.isEmpty
                ? staySummary
                : '$staySummary · $dateStr';

        final isSegmentRow = !isLast;
        final selectedSegment = _selectedSegmentIndex;
        final isActiveSegment =
            isSegmentRow && selectedSegment != null && selectedSegment == i;
        final carModeBlockedForSegment =
            isSegmentRow && _isCarModeBlockedForSegment(i);
        final segType = isSegmentRow ? _segmentRoutingTypeAt(i) : 'calculated';
        final segTypeNorm = segType.trim().toLowerCase();
        final segMode = _segmentTransportModeAt(i);
        final primaryRoutingType = _defaultRoutingTypeForMode(segMode);
        final primaryRoutingLabel = _primaryRoutingLabelForMode(segMode);

        final indicator = SizedBox(
          width: 26,
          child: Column(
            children: [
              const SizedBox(height: 2),
              Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: Colors.grey.shade400, width: 2),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child:
                      _isWaypointOnly(i)
                          ? Icon(
                            Icons.alt_route,
                            size: 11,
                            color: Colors.grey.shade700,
                          )
                          : Text(
                            '${i + 1}',
                            style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                ),
              ),
              if (!isLast) ...[
                const SizedBox(height: 2),
                Container(width: 2, height: 88, color: Colors.grey.shade300),
              ],
            ],
          ),
        );

        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              indicator,
              const SizedBox(width: 8),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: isSegmentRow ? () => _setActiveSegmentIndex(i) : null,
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
                            SizedBox(
                              width: 122,
                              child: Column(
                                children: [
                                  if (boundaryLabel != null) ...[
                                    Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 6,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.grey.shade100,
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(
                                          color: Colors.grey.shade300,
                                        ),
                                      ),
                                      child: Text(
                                        boundaryLabel,
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                          color: Colors.grey.shade700,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                  ],
                                  InputDecorator(
                                    decoration: const InputDecoration(
                                      labelText: 'Type',
                                      isDense: true,
                                      contentPadding: EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 8,
                                      ),
                                    ),
                                    child: DropdownButtonHideUnderline(
                                      child: DropdownButton<bool>(
                                        value: isStop,
                                        isDense: true,
                                        isExpanded: true,
                                        onTap: () {
                                          _blockMapTapFor(milliseconds: 2500);
                                        },
                                        items: const [
                                          DropdownMenuItem<bool>(
                                            value: true,
                                            child: Text('Stop'),
                                          ),
                                          DropdownMenuItem<bool>(
                                            value: false,
                                            child: Text('Waypoint'),
                                          ),
                                        ],
                                        onChanged: (value) {
                                          if (value == null) return;
                                          _blockMapTapFor();
                                          _setWaypointRole(i, value);
                                        },
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  if (isStop)
                                    InputDecorator(
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
                                          value: math.max(
                                            1,
                                            math.min(nights, maxNightsForRow),
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
                                    )
                                  else
                                    Container(
                                      width: double.infinity,
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
                                        'No stay',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                          color: Colors.grey.shade700,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 6),
                            IconButton(
                              tooltip: 'Remove destination',
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
                          staySummaryWithDates,
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
                                    width: 150,
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
                                            _blockMapTapFor(milliseconds: 2500);
                                          },
                                          items:
                                              _availableTransportOptionsForTripType(
                                                    _normalizedTripType,
                                                  )
                                                  .map(
                                                    (opt) => DropdownMenuItem(
                                                      value: opt.mode,
                                                      enabled:
                                                          !carModeBlockedForSegment ||
                                                          opt.mode != 'car',
                                                      child: Text(
                                                        '${opt.emoji} ${opt.label}',
                                                        style: TextStyle(
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
                                            _setSegmentTransportMode(i, value);
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
                                    label: Text(
                                      primaryRoutingLabel,
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                    selected: segTypeNorm == primaryRoutingType,
                                    onSelected: (_) {
                                      _setActiveSegmentIndex(i);
                                      _setSegmentRoutingType(
                                        i,
                                        primaryRoutingType,
                                      );
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
                                      _setSegmentRoutingType(i, 'direct');
                                    },
                                  ),
                                  TextButton.icon(
                                    style: TextButton.styleFrom(
                                      visualDensity: VisualDensity.compact,
                                      foregroundColor: const Color(0xFF00897B),
                                    ),
                                    onPressed: () {
                                      _setActiveSegmentIndex(i);
                                      _smartFindStopBetween(afterIndex: i);
                                    },
                                    icon: const Text('✨'),
                                    label: Text(
                                      _isAdventureMode(segMode)
                                          ? 'Find Campsite'
                                          : 'Find Stay Stop',
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                _routingDescriptionForSelection(
                                  segTypeNorm,
                                  segMode,
                                ),
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.black54,
                                ),
                              ),
                            ],
                          )
                        else
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Last destination',
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
                                  label: Text(
                                    _isAdventureMode(
                                          _waypoints.length >= 2
                                              ? _segmentTransportModeAt(
                                                _waypoints.length - 2,
                                              )
                                              : _transportMode,
                                        )
                                        ? 'Suggest Next Campsite'
                                        : 'Suggest Next Stay Stop',
                                  ),
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
              'Destinations & routing',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Chip(
                  avatar: Text(tripTypeEmoji(_normalizedTripType)),
                  label: Text(tripTypeBadgeLabel(_normalizedTripType)),
                ),
                if (_isAdventureTrip)
                  Chip(
                    avatar: const Icon(Icons.tune, size: 18),
                    label: Text(_currentDifficultyLabel()),
                  ),
                if (_isAdventureTrip)
                  Chip(
                    avatar: const Icon(Icons.school_outlined, size: 18),
                    label: Text(
                      'Experience: ${tripExperienceDisplayLabel(_experienceLevel)}',
                    ),
                  ),
              ],
            ),
            if (_isAdventureTrip) ...[
              const SizedBox(height: 8),
              Text(
                'Required skills: ${_currentRequiredSkills().join(', ')}',
                style: const TextStyle(fontSize: 12, color: Colors.black54),
              ),
              const SizedBox(height: 12),
            ],
            LayoutBuilder(
              builder: (context, constraints) {
                final visibleTransportOptions =
                    _availableTransportOptionsForTripType(_normalizedTripType);
                final transportChips = SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children:
                        visibleTransportOptions.map((opt) {
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
                                '${opt.emoji} ${opt.label}',
                                style: TextStyle(
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
                );
                final isCompact = constraints.maxWidth < 430;

                if (isCompact) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Leg mode ($selectedLegLabel)',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      transportChips,
                    ],
                  );
                }

                return Row(
                  children: [
                    Text(
                      'Leg mode ($selectedLegLabel)',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: transportChips),
                  ],
                );
              },
            ),
            const SizedBox(height: 4),
            Text(
              _modeSelectionHelperText(),
              style: TextStyle(fontSize: 11, color: Colors.black54),
            ),
            if (_waypoints.length >= 2 && !_isPortageTrip) ...[
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
                        setState(() {
                          _routeVia = [];
                          _resetComputedRouteState();
                        });
                        _scheduleRouteCachePersist();
                      },
                      icon: const Icon(Icons.clear),
                      label: const Text('Clear'),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 14),
            if (_tripRange != null && _hasStayStops)
              Text(
                'Nights assigned (stay stops only): $_assignedNights / $_totalTripNights',
                style: TextStyle(
                  fontSize: 13,
                  color:
                      _hasValidAllocation
                          ? Colors.black54
                          : Colors.red.shade700,
                  fontWeight: FontWeight.w700,
                ),
              ),
            if (_tripRange != null && _hasStayStops && !_hasValidAllocation)
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
                  'Only destinations marked as Stop count toward trip nights. Waypoints stay transit-only.',
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
            const SizedBox(height: 14),
            const Text(
              'Destinations',
              style: TextStyle(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 10),
            if (_waypoints.isEmpty)
              Text(
                _isPortageTrip
                    ? 'No destinations yet. Start with an access point above or click a blue access marker on the map.'
                    : 'No destinations yet. Search above or click the map to add.',
              )
            else
              Column(
                children: [
                  for (var i = 0; i < _waypoints.length; i++) ...[
                    stopItem(i),
                    if (i < _waypoints.length - 1) _buildTransitLegCard(i),
                  ],
                ],
              ),
            const SizedBox(height: 8),
            if ((_tripNameCtrl.text.trim().isNotEmpty ||
                    _waypoints.isNotEmpty) &&
                _tripValidationMessage() != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: Text(
                  _tripValidationMessage()!,
                  style: TextStyle(
                    color: Colors.red.shade700,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
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
                          _tripValidationMessage() != null ||
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
        thumbVisibility: false,
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

            final profilePill = GestureDetector(
              onTap: _showTripBasicsDialog,
              child: glassPill(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(tripTypeEmoji(_normalizedTripType)),
                    const SizedBox(width: 6),
                    Text(
                      tripTypeDisplayLabel(_normalizedTripType),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            );

            final difficultyPill = glassPill(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.tune, size: 16),
                  const SizedBox(width: 6),
                  Text(
                    'Difficulty: ${_currentDifficultyLabel()}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            );

            final content = Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                namePill,
                datesPill,
                profilePill,
                if (_isAdventureTrip) difficultyPill,
              ],
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
                  hint: _tripTypeSearchHint(),
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
                    if (_isPortageAccessSearchStage) {
                      ScaffoldMessenger.of(context).showTryprSnackBar(
                        const SnackBar(
                          content: Text(
                            'Search an access point or click a blue access marker to start a portage trip',
                          ),
                        ),
                      );
                    } else if (_isHikingSearchMode) {
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
                  await _handleSearchResultSelection(r, q);
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
                                final category = _searchResultCategory(r);
                                return ListTile(
                                  dense: true,
                                  leading: Icon(
                                    category.icon,
                                    color: category.color,
                                  ),
                                  title: Text(
                                    display.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  subtitle: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        category.label,
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                          color: category.color,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        display.subtitle.isNotEmpty
                                            ? display.subtitle
                                            : '${lat.toStringAsFixed(4)}, ${lon.toStringAsFixed(4)}',
                                      ),
                                    ],
                                  ),
                                  onTap: () async {
                                    await _handleSearchResultSelection(r, raw);
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
              children: [
                locationSearchField,
                if (_isAdventureTrip) ...[
                  const SizedBox(height: 8),
                  Text(
                    _isPortageAccessSearchStage
                        ? 'Search results are filtered to access points first so your route starts from a real launch location.'
                        : _isPortageTrip
                        ? 'Backcountry results include campsites and portage lines. On the map, add stops by clicking campsite or access-point markers.'
                        : 'Backcountry results include campsites, trails, and portage lines. Need a custom stop? Click the map.',
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ],
                resultsList,
              ],
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

          Widget plannerGuideIsland({required double maxWidth}) {
            final card = ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: _buildPlannerGuideCard(),
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
          final tripDetailsControl = Listener(
            onPointerDown: (_) => _blockMapTapFor(milliseconds: 1200),
            child: tripDetailsIsland(
              maxWidth: compactTopLayout ? tripDetailsMaxWidth : panelWidth,
            ),
          );
          final searchControl = Listener(
            onPointerDown: (_) => _blockMapTapFor(milliseconds: 1200),
            child: searchIsland(maxWidth: searchMaxWidth),
          );
          final mapModeControl =
              kIsWeb
                  ? Listener(
                    onPointerDown: (_) => _blockMapTapFor(milliseconds: 1200),
                    child: mapModeIsland(),
                  )
                  : const SizedBox.shrink();
          final plannerGuideControl =
              _isAdventureTrip
                  ? Listener(
                    onPointerDown: (_) => _blockMapTapFor(milliseconds: 1200),
                    child: SizedBox(
                      width: panelWidth,
                      child: plannerGuideIsland(maxWidth: panelWidth),
                    ),
                  )
                  : const SizedBox.shrink();
          final itineraryControl = Listener(
            onPointerDown: (_) => _blockMapTapFor(milliseconds: 1200),
            child: SizedBox(width: panelWidth, child: tripInfoPanel()),
          );
          final overlayContent =
              compactTopLayout
                  ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      tripDetailsControl,
                      const SizedBox(height: 10),
                      searchControl,
                      if (kIsWeb) ...[
                        const SizedBox(height: 10),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: mapModeControl,
                        ),
                      ],
                      if (_isAdventureTrip) ...[
                        const SizedBox(height: 12),
                        plannerGuideControl,
                      ],
                      const SizedBox(height: 12),
                      Expanded(
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: itineraryControl,
                        ),
                      ),
                    ],
                  )
                  : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: panelWidth,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            tripDetailsControl,
                            if (_isAdventureTrip) ...[
                              const SizedBox(height: 12),
                              plannerGuideControl,
                            ],
                            const SizedBox(height: 12),
                            Expanded(
                              child: Align(
                                alignment: Alignment.topLeft,
                                child: itineraryControl,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Align(
                                alignment: Alignment.topCenter,
                                child: searchControl,
                              ),
                            ),
                            if (kIsWeb) ...[
                              const SizedBox(width: 12),
                              mapModeControl,
                            ],
                          ],
                        ),
                      ),
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
                                        'isStop': w.isStop,
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
                                (!_adjustRoute && _allowsCustomMapDrops)
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
                                        'isStop': w.isStop,
                                      },
                                    )
                                    .toList(),
                            transportMode: _transportMode,
                            segmentTransportModes: _segmentTransportModes,
                            routeVia: _isPortageTrip ? const [] : _routeVia,
                            segmentRoutingTypes: _segmentRoutingTypes,
                            onRouteInstructions: (lines) {
                              if (!mounted) return;
                              setState(() => _routeInstructions = lines);
                              _scheduleRouteCachePersist();
                            },
                            onRouteSegmentDetails: (segments) {
                              if (!mounted) return;
                              setState(
                                () =>
                                    _routeSegmentDetails =
                                        readRouteSegmentDetails(segments),
                              );
                              _scheduleRouteCachePersist();
                            },
                            onRouteGeometry: (geometry) {
                              if (!mounted) return;
                              setState(() => _routeGeometry3d = geometry);
                              _scheduleRouteCachePersist();
                            },
                            onTransitArrivalStop: (arrivalStop) {
                              if (!mounted) return;
                              setState(
                                () =>
                                    _transitArrivalStop =
                                        arrivalStop.isEmpty
                                            ? null
                                            : arrivalStop,
                              );
                            },
                            onRouteComputingChanged:
                                _handleRouteComputingChanged,
                            onRouteError: _handleRouteError,
                            focusedRouteStep: _focusedTransitStep,
                            onRouteSummary: (distanceMeters, durationSeconds) {
                              if (!mounted) return;
                              setState(() {
                                _roadDistanceKm = distanceMeters / 1000.0;
                                _routeDurationMin = durationSeconds / 60.0;
                              });
                            },
                            onHikingCampsiteTap: _onHikingCampsiteTap,
                            onPortageAccessTap: _onPortageAccessTap,
                            onMapTap:
                                (!_adjustRoute && _allowsCustomMapDrops)
                                    ? (lat, lon) async =>
                                        _addDroppedPinFromMapTap(lat, lon)
                                    : null,
                            onRouteTapAddVia:
                                (_adjustRoute && !_isPortageTrip)
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
                                (_adjustRoute && !_isPortageTrip)
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
                                (_adjustRoute && !_isPortageTrip)
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
                  child: overlayContent,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
