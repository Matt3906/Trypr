import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:trypr/utils/trypr_snackbar.dart';
import 'package:trypr/services/geocode.dart';
import 'package:trypr/services/pick_image_data_url.dart';
import 'package:trypr/services/route_options.dart';
import 'package:trypr/widgets/map_embed.dart';

class VerifiedTripBuilderScreen extends StatefulWidget {
  final String? existingTripId;
  final Map<String, dynamic>? existingTripData;

  const VerifiedTripBuilderScreen({
    super.key,
    this.existingTripId,
    this.existingTripData,
  });

  @override
  State<VerifiedTripBuilderScreen> createState() =>
      _VerifiedTripBuilderScreenState();

  static Route<void> route({
    String? existingTripId,
    Map<String, dynamic>? existingTripData,
  }) {
    return MaterialPageRoute<void>(
      builder:
          (_) => VerifiedTripBuilderScreen(
            existingTripId: existingTripId,
            existingTripData: existingTripData,
          ),
    );
  }
}

class _Waypoint {
  final String name;
  final double lat;
  final double lon;
  int days;

  _Waypoint({
    required this.name,
    required this.lat,
    required this.lon,
    this.days = 2,
  });
}

class _TransportOption {
  final String mode;
  final String label;
  final String emoji;

  const _TransportOption(this.mode, this.label, this.emoji);
}

class _VerifiedTripBuilderScreenState extends State<VerifiedTripBuilderScreen> {
  final _formKey = GlobalKey<FormState>();

  static const List<_TransportOption> _transportOptions = [
    _TransportOption('car', 'Car', '🚗'),
    _TransportOption('plane', 'Plane', '✈️'),
    _TransportOption('train', 'Train', '🚆'),
    _TransportOption('walk', 'Walk', '🚶'),
    _TransportOption('bike', 'Bike', '🚲'),
    _TransportOption('portaging', 'Portaging', '🛶'),
    _TransportOption('hiking', 'Hiking', '🥾'),
    _TransportOption('gas_stops', 'Gas/Stops', '⛽'),
  ];

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

  static const List<String> _portageKeywords = <String>[
    'portage',
    'carry',
    'canoe carry',
    'put-in',
    'put in',
    'take-out',
    'take out',
    'carry trail',
  ];

  // Travel-themed categories with colors for activities
  static const travelCategories = {
    'Hiking': Color(0xFF2E7D32),
    'Biking': Color(0xFF1565C0),
    'Walking': Color(0xFF00796B),
    'Museum': Color(0xFF6A1B9A),
    'Sightseeing': Color(0xFFF57C00),
    'Exploring': Color(0xFFC62828),
    'Restaurant': Color(0xFFD32F2F),
    'Shopping': Color(0xFF7B1FA2),
    'Photography': Color(0xFF0277BD),
    'Adventure': Color(0xFFFBC02D),
    'Driving': Colors.blueAccent,
  };

  final _titleCtl = TextEditingController();
  final _subtitleCtl = TextEditingController();
  final _descCtl = TextEditingController();
  String _coverImage = '';

  final _searchCtl = TextEditingController();
  Timer? _searchDebounce;
  List<Map<String, dynamic>> _searchResults = [];

  final List<String> _photoUrls = [];
  final List<_Waypoint> _waypoints = [];

  // Per-day itinerary for verified trips.
  // Stored as: [{'title': 'Day 1', 'notes': '', 'activities': [{'time':'', 'title':'', 'description':''}, ...]}, ...]
  final List<Map<String, dynamic>> _itinerary = [];

  String _transportMode = 'car';
  bool _adjustRoute = false;
  List<Map<String, dynamic>> _routeVia = [];
  List<String> _routeInstructions = [];
  List<String> _segmentRoutingTypes = [];
  List<String> _segmentTransportModes = [];
  int _activeSegmentIndex = 0;
  double? _roadDistanceKm;
  double? _routeDurationMin;

  final Map<int, List<Map<String, dynamic>>> _segmentRouteOptionsCache = {};
  final Map<int, Map<String, dynamic>> _segmentRoutePreferences = {};

  bool _saving = false;

  bool _suspendMapTap = false;

  Future<T?> _withMapTapSuspended<T>(Future<T?> Function() action) async {
    if (!mounted) return null;
    setState(() => _suspendMapTap = true);
    try {
      return await action();
    } finally {
      if (mounted) setState(() => _suspendMapTap = false);
    }
  }

  @override
  void dispose() {
    _titleCtl.dispose();
    _subtitleCtl.dispose();
    _descCtl.dispose();
    _searchDebounce?.cancel();
    _searchCtl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _populateFromExistingTrip();
  }

  void _populateFromExistingTrip() {
    final data = widget.existingTripData;
    if (data == null) return;

    _titleCtl.text = data['title']?.toString() ?? '';
    _subtitleCtl.text = data['subtitle']?.toString() ?? '';
    _descCtl.text = data['description']?.toString() ?? '';
    _coverImage = data['coverImage']?.toString() ?? '';
    _transportMode = _normalizeTransportMode(
      data['transportMode']?.toString() ?? 'car',
    );

    // Populate photos
    final photos = data['photos'];
    if (photos is List) {
      _photoUrls.clear();
      for (final p in photos) {
        if (p is String && p.isNotEmpty) {
          _photoUrls.add(p);
        }
      }
    }

    // Populate waypoints
    final waypoints = data['waypoints'];
    if (waypoints is List) {
      _waypoints.clear();
      for (final w in waypoints) {
        if (w is Map) {
          final name = w['name']?.toString() ?? '';
          final lat = (w['lat'] is num) ? (w['lat'] as num).toDouble() : 0.0;
          final lon = (w['lon'] is num) ? (w['lon'] as num).toDouble() : 0.0;
          final days = (w['days'] is num) ? (w['days'] as num).toInt() : 2;
          if (name.isNotEmpty) {
            _waypoints.add(
              _Waypoint(name: name, lat: lat, lon: lon, days: days),
            );
          }
        }
      }
    }

    // Populate itinerary
    final itinerary = data['itinerary'];
    if (itinerary is List) {
      _itinerary.clear();
      for (final day in itinerary) {
        if (day is Map) {
          final dayMap = <String, dynamic>{
            'title': day['title']?.toString() ?? '',
            'notes': day['notes']?.toString() ?? '',
            'activities': <Map<String, dynamic>>[],
          };
          final activities = day['activities'];
          if (activities is List) {
            for (final a in activities) {
              if (a is Map) {
                (dayMap['activities'] as List).add({
                  'time': a['time']?.toString() ?? '',
                  'title': a['title']?.toString() ?? '',
                  'description': a['description']?.toString() ?? '',
                });
              }
            }
          }
          _itinerary.add(dayMap);
        }
      }
    }

    final routeVia = data['routeVia'];
    if (routeVia is List) {
      _routeVia =
          routeVia
              .whereType<Map>()
              .map((v) => Map<String, dynamic>.from(v.cast<String, dynamic>()))
              .toList();
    }

    final segmentRoutingTypes = data['segmentRoutingTypes'];
    if (segmentRoutingTypes is List) {
      _segmentRoutingTypes =
          segmentRoutingTypes.map((v) => v.toString()).toList();
    }

    final segmentTransportModes = data['segmentTransportModes'];
    if (segmentTransportModes is List) {
      _segmentTransportModes =
          segmentTransportModes.map((v) => v.toString()).toList();
    }

    _segmentRoutePreferences.clear();
    final segmentRoutePreferences = data['segmentRoutePreferences'];
    if (segmentRoutePreferences is List) {
      for (final raw in segmentRoutePreferences) {
        if (raw is! Map) continue;
        final map = Map<String, dynamic>.from(raw.cast<String, dynamic>());
        final segmentIndex = (map['segmentIndex'] as num?)?.toInt();
        if (segmentIndex == null || segmentIndex < 0) continue;
        _segmentRoutePreferences[segmentIndex] = map;
      }
    }

    _syncRoutingStateWithWaypoints();
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
    if (m == 'canoe' || m == 'canoeing' || m == 'portage') m = 'portaging';
    if (m == 'backpacking') m = 'hiking';
    if (m == 'gas/stops' || m == 'gas-stops' || m == 'gasstops') {
      m = 'gas_stops';
    }
    for (final opt in _transportOptions) {
      if (opt.mode == m) return m;
    }
    return 'car';
  }

  int get _segmentCount => math.max(0, _waypoints.length - 1);

  int? get _selectedSegmentIndex {
    if (_segmentCount <= 0) return null;
    if (_activeSegmentIndex < 0 || _activeSegmentIndex >= _segmentCount) {
      return 0;
    }
    return _activeSegmentIndex;
  }

  void _clampActiveSegmentIndex() {
    if (_segmentCount <= 0) {
      _activeSegmentIndex = 0;
      return;
    }
    if (_activeSegmentIndex < 0 || _activeSegmentIndex >= _segmentCount) {
      _activeSegmentIndex = 0;
    }
  }

  void _setActiveSegmentIndex(int segmentIndex) {
    if (_segmentCount <= 0) return;
    final clamped = segmentIndex.clamp(0, _segmentCount - 1);
    if (_activeSegmentIndex == clamped) return;
    setState(() => _activeSegmentIndex = clamped);
  }

  String _segmentTransportModeAt(int segmentIndex) {
    if (segmentIndex < 0 || segmentIndex >= _segmentTransportModes.length) {
      return _normalizeTransportMode(_transportMode);
    }
    return _normalizeTransportMode(_segmentTransportModes[segmentIndex]);
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
    // Only block car mode on segments when the primary trip mode is
    // hiking or portaging.  For car/train/etc. trips, users should always
    // be able to pick car even if a waypoint name contains outdoor keywords.
    final primaryMode = _normalizeTransportMode(_transportMode);
    if (primaryMode != 'hiking' && primaryMode != 'portaging') return false;
    return _isHikingTrailSegment(segmentIndex);
  }

  void _coerceBlockedCarModesToHiking() {
    // Only auto-coerce segments when the primary trip mode is hiking or
    // portaging.  Car trips should never have segments silently converted
    // to portaging just because a waypoint name contains an outdoor keyword.
    final primaryMode = _normalizeTransportMode(_transportMode);
    if (primaryMode != 'hiking' && primaryMode != 'portaging') return;

    for (var i = 0; i < _segmentTransportModes.length; i++) {
      final mode = _normalizeTransportMode(_segmentTransportModes[i]);
      if (mode == 'car' && _isCarModeBlockedForSegment(i)) {
        _segmentTransportModes[i] = 'portaging';
      } else {
        _segmentTransportModes[i] = mode;
      }
    }
  }

  void _syncRoutingStateWithWaypoints() {
    final fallbackMode = _normalizeTransportMode(_transportMode);

    if (_segmentRoutingTypes.length > _segmentCount) {
      _segmentRoutingTypes = _segmentRoutingTypes.take(_segmentCount).toList();
    } else if (_segmentRoutingTypes.length < _segmentCount) {
      _segmentRoutingTypes = [
        ..._segmentRoutingTypes,
        ...List.filled(
          _segmentCount - _segmentRoutingTypes.length,
          'calculated',
        ),
      ];
    }
    _segmentRoutingTypes =
        _segmentRoutingTypes.map((v) {
          final norm = v.trim().toLowerCase();
          return norm == 'direct' ? 'direct' : 'calculated';
        }).toList();

    if (_segmentTransportModes.length > _segmentCount) {
      _segmentTransportModes =
          _segmentTransportModes.take(_segmentCount).toList();
    } else if (_segmentTransportModes.length < _segmentCount) {
      _segmentTransportModes = [
        ..._segmentTransportModes,
        ...List.filled(
          _segmentCount - _segmentTransportModes.length,
          fallbackMode,
        ),
      ];
    }
    _segmentTransportModes =
        _segmentTransportModes.map(_normalizeTransportMode).toList();
    _coerceBlockedCarModesToHiking();
    _clampActiveSegmentIndex();

    _routeVia =
        _routeVia
            .where((v) {
              final after = (v['afterIndex'] as num?)?.toInt();
              return after != null && after >= 0 && after < _segmentCount;
            })
            .map((v) => Map<String, dynamic>.from(v))
            .toList();

    _segmentRoutePreferences.removeWhere(
      (segmentIndex, _) => segmentIndex < 0 || segmentIndex >= _segmentCount,
    );
    _segmentRouteOptionsCache.removeWhere(
      (segmentIndex, _) => segmentIndex < 0 || segmentIndex >= _segmentCount,
    );
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
      if (out.length >= 10) break;
    }
    return out;
  }

  Future<List<Map<String, dynamic>>> _searchResultsForUi(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];

    var results = await searchNominatim(q);
    if (!_isHikingSearchMode) return results;

    var filtered = _filterHikingSearchResults(results);
    if (filtered.isNotEmpty) return filtered;

    final focusedQuery = _hikingBiasedQuery(q);
    if (focusedQuery != q) {
      results = await searchNominatim(focusedQuery);
      filtered = _filterHikingSearchResults(results);
      if (filtered.isNotEmpty) return filtered;
    }
    return const [];
  }

  bool _isPortageInstruction(String raw) {
    final text = raw.trim().toLowerCase();
    if (text.isEmpty) return false;
    for (final keyword in _portageKeywords) {
      if (text.contains(keyword)) return true;
    }
    if (text.contains('trail') &&
        (text.contains('lake') ||
            text.contains('canoe') ||
            text.contains('paddle'))) {
      return true;
    }
    return false;
  }

  double _instructionDistanceKm(String raw) {
    final match = RegExp(
      r'(\d+(?:[.,]\d+)?)\s*(km|m|mi|ft)\b',
      caseSensitive: false,
    ).firstMatch(raw);
    if (match == null) return 0;
    final value = double.tryParse((match.group(1) ?? '').replaceAll(',', '.'));
    if (value == null || !value.isFinite || value <= 0) return 0;
    final unit = (match.group(2) ?? '').toLowerCase();
    switch (unit) {
      case 'km':
        return value;
      case 'm':
        return value / 1000.0;
      case 'mi':
        return value * 1.60934;
      case 'ft':
        return value * 0.0003048;
      default:
        return 0;
    }
  }

  Map<String, dynamic> _analyzePortages(List<String> instructions) {
    var portageCount = 0;
    var portageDistanceKm = 0.0;
    var longestPortageKm = 0.0;
    final snippets = <String>[];

    for (final instruction in instructions) {
      if (!_isPortageInstruction(instruction)) continue;
      portageCount++;
      final distanceKm = _instructionDistanceKm(instruction);
      if (distanceKm > 0) {
        portageDistanceKm += distanceKm;
        if (distanceKm > longestPortageKm) {
          longestPortageKm = distanceKm;
        }
      }
      if (snippets.length < 3) snippets.add(instruction);
    }

    return {
      'portageCount': portageCount,
      'portageDistanceKm': portageDistanceKm,
      'longestPortageKm': longestPortageKm,
      'portageSnippets': snippets,
    };
  }

  double _routeOptionScore(TravelRouteOption option) {
    final durationMins =
        option.durationSeconds > 0 ? option.durationSeconds / 60.0 : 100000.0;
    return durationMins;
  }

  String _formatDurationShort(double seconds) {
    if (seconds <= 0) return '';
    final totalMinutes = (seconds / 60).round();
    final hours = totalMinutes ~/ 60;
    final minutes = totalMinutes % 60;
    if (hours <= 0) return '${minutes}m';
    if (minutes <= 0) return '${hours}h';
    return '${hours}h ${minutes}m';
  }

  String _routeOptionsModeForSegment(int segmentIndex) {
    final mode = _segmentTransportModeAt(segmentIndex);
    switch (mode) {
      case 'car':
      case 'gas_stops':
      case 'plane':
        return 'driving';
      case 'train':
        return 'transit';
      case 'walk':
        return 'walking';
      case 'bike':
        return 'biking';
      case 'hiking':
        return 'hiking';
      case 'portaging':
        return 'portaging';
      default:
        return 'driving';
    }
  }

  Future<List<Map<String, dynamic>>> _loadRouteChoicesForSegment(
    int segmentIndex, {
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh) {
      final cached = _segmentRouteOptionsCache[segmentIndex];
      if (cached != null && cached.isNotEmpty) return cached;
    }
    if (segmentIndex < 0 || segmentIndex + 1 >= _waypoints.length) {
      return const [];
    }

    final from = _waypoints[segmentIndex];
    final to = _waypoints[segmentIndex + 1];
    final mode = _routeOptionsModeForSegment(segmentIndex);

    final options = await getRouteOptions(
      originLat: from.lat,
      originLng: from.lon,
      destLat: to.lat,
      destLng: to.lon,
      mode: mode,
      avoidHighways: mode == 'biking',
      maxOptions: 5,
    );

    final ranked =
        options.asMap().entries.map((entry) {
            final option = entry.value;
            final portage = _analyzePortages(option.instructions);
            return {
              ...option.toMap(),
              'sourceIndex': entry.key,
              'score': _routeOptionScore(option),
              ...portage,
            };
          }).toList()
          ..sort(
            (a, b) => (a['score'] as double).compareTo(b['score'] as double),
          );

    for (var i = 0; i < ranked.length; i++) {
      ranked[i]['rank'] = i + 1;
      ranked[i]['portagePattern'] = '';
    }

    var singleLongIndex = -1;
    var singleLongBestKm = -1.0;
    var multiShortIndex = -1;
    var multiShortCount = -1;
    var multiShortLongest = double.infinity;

    for (var i = 0; i < ranked.length; i++) {
      final portageCount = (ranked[i]['portageCount'] as num?)?.toInt() ?? 0;
      final longest =
          (ranked[i]['longestPortageKm'] as num?)?.toDouble() ?? 0.0;
      if (portageCount == 1 && longest > singleLongBestKm) {
        singleLongBestKm = longest;
        singleLongIndex = i;
      }
      if (portageCount >= 2 &&
          (portageCount > multiShortCount ||
              (portageCount == multiShortCount &&
                  longest < multiShortLongest))) {
        multiShortCount = portageCount;
        multiShortLongest = longest;
        multiShortIndex = i;
      }
    }

    if (singleLongIndex >= 0) {
      ranked[singleLongIndex]['portagePattern'] = 'single_long';
    }
    if (multiShortIndex >= 0) {
      ranked[multiShortIndex]['portagePattern'] = 'multi_short';
    }

    _segmentRouteOptionsCache[segmentIndex] = ranked;
    return ranked;
  }

  void _setTransportMode(String mode) {
    final normalized = _normalizeTransportMode(mode);
    final selectedSegment = _selectedSegmentIndex;
    if (selectedSegment != null) {
      _setSegmentTransportMode(selectedSegment, normalized);
      return;
    }
    setState(() {
      _transportMode = normalized;
      _syncRoutingStateWithWaypoints();
    });
  }

  void _setSegmentTransportMode(int segmentIndex, String mode) {
    final normalized = _normalizeTransportMode(mode);
    if (segmentIndex < 0 || segmentIndex >= _segmentCount) return;
    setState(() {
      _activeSegmentIndex = segmentIndex;
      _segmentTransportModes[segmentIndex] = normalized;
      _transportMode = normalized;
      if (normalized == 'train' || normalized == 'plane') {
        _routeVia =
            _routeVia.where((v) {
              final after = (v['afterIndex'] as num?)?.toInt();
              return after != segmentIndex;
            }).toList();
      }
      _segmentRouteOptionsCache.remove(segmentIndex);
      _routeInstructions = [];
      _syncRoutingStateWithWaypoints();
    });
  }

  void _upsertViaPoint({
    required int afterIndex,
    required double lat,
    required double lon,
  }) {
    if (afterIndex < 0 || afterIndex >= _segmentCount) return;
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
      _activeSegmentIndex = afterIndex.clamp(0, math.max(0, _segmentCount - 1));
    });
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

  Future<void> _showSegmentRouteChoicesDialog({
    required int segmentIndex,
    double? tappedLat,
    double? tappedLon,
  }) async {
    if (segmentIndex < 0 || segmentIndex >= _segmentCount) return;
    _setActiveSegmentIndex(segmentIndex);

    Future<List<Map<String, dynamic>>> routeOptionsFuture =
        _loadRouteChoicesForSegment(segmentIndex);

    await _withMapTapSuspended(
      () => showDialog<void>(
        context: context,
        builder: (ctx) {
          return StatefulBuilder(
            builder: (ctx2, setStateDialog) {
              return AlertDialog(
                title: Text('Leg ${segmentIndex + 1} route options'),
                content: SizedBox(
                  width: 520,
                  child: FutureBuilder<List<Map<String, dynamic>>>(
                    future: routeOptionsFuture,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      final options = snapshot.data ?? const [];
                      if (options.isEmpty) {
                        return const Text(
                          'No live route alternatives found right now. You can still drop a pin to force a preferred lake or portage line.',
                        );
                      }
                      final hasSingleLong = options.any(
                        (option) =>
                            (option['portagePattern'] ?? '').toString() ==
                            'single_long',
                      );
                      final hasMultiShort = options.any(
                        (option) =>
                            (option['portagePattern'] ?? '').toString() ==
                            'multi_short',
                      );

                      return SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Choose your preferred portage style for this leg.',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.black54,
                              ),
                            ),
                            if (hasSingleLong && hasMultiShort)
                              const Padding(
                                padding: EdgeInsets.only(top: 4),
                                child: Text(
                                  'Detected both styles: one long carry vs multiple short carries.',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF00695C),
                                  ),
                                ),
                              ),
                            const SizedBox(height: 10),
                            ...options.map((option) {
                              final distanceKm =
                                  ((option['distanceMeters'] as num?)
                                          ?.toDouble() ??
                                      0.0) /
                                  1000.0;
                              final duration = _formatDurationShort(
                                (option['durationSeconds'] as num?)
                                        ?.toDouble() ??
                                    0.0,
                              );
                              final portageCount =
                                  (option['portageCount'] as num?)?.toInt() ??
                                  0;
                              final portageDistanceKm =
                                  (option['portageDistanceKm'] as num?)
                                      ?.toDouble() ??
                                  0.0;
                              final pattern =
                                  (option['portagePattern'] ?? '').toString();
                              final sourceIndex =
                                  (option['sourceIndex'] as num?)?.toInt() ??
                                  -1;
                              final selected =
                                  (_segmentRoutePreferences[segmentIndex]?['sourceIndex']
                                          as num?)
                                      ?.toInt() ==
                                  sourceIndex;
                              final snippets =
                                  (option['portageSnippets'] as List<dynamic>?)
                                      ?.map((s) => s.toString())
                                      .toList() ??
                                  const <String>[];

                              return Container(
                                width: double.infinity,
                                margin: const EdgeInsets.only(bottom: 8),
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color:
                                      selected
                                          ? Theme.of(context)
                                              .colorScheme
                                              .primary
                                              .withValues(alpha: 0.08)
                                          : Colors.white,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color:
                                        selected
                                            ? Theme.of(
                                              context,
                                            ).colorScheme.primary
                                            : Colors.grey.shade300,
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            (option['summary'] ??
                                                    'Route option')
                                                .toString(),
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                        if (pattern == 'single_long')
                                          _patternChip('1 long portage')
                                        else if (pattern == 'multi_short')
                                          _patternChip('multi short portages'),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 4,
                                      children: [
                                        Text(
                                          '${distanceKm.toStringAsFixed(1)} km',
                                        ),
                                        if (duration.isNotEmpty) Text(duration),
                                        Text(
                                          portageCount > 0
                                              ? '$portageCount portage${portageCount == 1 ? '' : 's'}'
                                              : 'no explicit portage steps',
                                        ),
                                        if (portageDistanceKm > 0)
                                          Text(
                                            '~${portageDistanceKm.toStringAsFixed(1)} km carry',
                                          ),
                                      ],
                                    ),
                                    if (snippets.isNotEmpty) ...[
                                      const SizedBox(height: 6),
                                      ...snippets
                                          .take(2)
                                          .map(
                                            (line) => Text(
                                              '• $line',
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 12,
                                                color: Colors.black54,
                                              ),
                                            ),
                                          ),
                                    ],
                                    const SizedBox(height: 8),
                                    Align(
                                      alignment: Alignment.centerRight,
                                      child: OutlinedButton(
                                        onPressed: () {
                                          setState(() {
                                            _segmentRoutePreferences[segmentIndex] =
                                                {
                                                  ...option,
                                                  'segmentIndex': segmentIndex,
                                                  'selectedAt':
                                                      DateTime.now()
                                                          .toIso8601String(),
                                                };
                                          });
                                          Navigator.of(ctx2).pop();
                                          if (!mounted) return;
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showTryprSnackBar(
                                            SnackBar(
                                              content: Text(
                                                'Saved leg ${segmentIndex + 1} route preference.',
                                              ),
                                            ),
                                          );
                                        },
                                        child: Text(
                                          selected ? 'Selected' : 'Choose',
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            }),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx2).pop(),
                    child: const Text('Close'),
                  ),
                  if (tappedLat != null && tappedLon != null)
                    TextButton(
                      onPressed: () {
                        Navigator.of(ctx2).pop();
                        _upsertViaPoint(
                          afterIndex: segmentIndex,
                          lat: tappedLat,
                          lon: tappedLon,
                        );
                      },
                      child: const Text('Drop pin at tap'),
                    ),
                  TextButton(
                    onPressed: () {
                      setStateDialog(() {
                        routeOptionsFuture = _loadRouteChoicesForSegment(
                          segmentIndex,
                          forceRefresh: true,
                        );
                      });
                    },
                    child: const Text('Refresh'),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _onRouteTapped({
    required int afterIndex,
    required double lat,
    required double lon,
  }) async {
    await _showSegmentRouteChoicesDialog(
      segmentIndex: afterIndex,
      tappedLat: lat,
      tappedLon: lon,
    );
  }

  Widget _patternChip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFF00897B).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: Color(0xFF00695C),
        ),
      ),
    );
  }

  String _trim(String v) => v.trim();

  ({Uint8List bytes, String contentType})? _decodeDataUrl(String dataUrl) {
    final raw = dataUrl.trim();
    if (!raw.startsWith('data:')) return null;
    final comma = raw.indexOf(',');
    if (comma <= 0) return null;

    final header = raw.substring(0, comma); // data:image/png;base64
    final payload = raw.substring(comma + 1);

    String contentType = 'image/jpeg';
    if (header.startsWith('data:')) {
      final meta = header.substring(5);
      final parts = meta.split(';');
      if (parts.isNotEmpty && parts.first.trim().isNotEmpty) {
        contentType = parts.first.trim();
      }
    }

    try {
      return (bytes: base64Decode(payload), contentType: contentType);
    } catch (_) {
      return null;
    }
  }

  String _extForContentType(String contentType) {
    final ct = contentType.toLowerCase();
    if (ct.contains('png')) return 'png';
    if (ct.contains('webp')) return 'webp';
    if (ct.contains('gif')) return 'gif';
    return 'jpg';
  }

  Future<String> _uploadVerifiedTripImage({
    required String tripId,
    required String label,
    required String dataUrl,
  }) async {
    final decoded = _decodeDataUrl(dataUrl);
    if (decoded == null) {
      throw Exception('Unsupported image format');
    }

    final ts = DateTime.now().millisecondsSinceEpoch;
    final ext = _extForContentType(decoded.contentType);
    final ref = FirebaseStorage.instance.ref(
      'verifiedTrips/$tripId/${label}_$ts.$ext',
    );

    final meta = SettableMetadata(contentType: decoded.contentType);
    final task = await ref.putData(decoded.bytes, meta);
    return task.ref.getDownloadURL();
  }

  int get _recommendedDays {
    var total = 0;
    for (final w in _waypoints) {
      total += w.days;
    }
    return total;
  }

  Map<String, dynamic> _newDay(int dayNumber) {
    return {
      'title': 'Day $dayNumber',
      'notes': '',
      'activities': <Map<String, dynamic>>[],
    };
  }

  void _ensureItineraryLength(int dayCount) {
    final desired = dayCount < 0 ? 0 : dayCount;
    while (_itinerary.length < desired) {
      _itinerary.add(_newDay(_itinerary.length + 1));
    }
    while (_itinerary.length > desired) {
      _itinerary.removeLast();
    }
    // Keep titles sane if days were added/removed.
    for (var i = 0; i < _itinerary.length; i++) {
      final day = _itinerary[i];
      day['title'] =
          (day['title'] as String?)?.trim().isNotEmpty == true
              ? day['title']
              : 'Day ${i + 1}';
    }
  }

  Future<Map<String, String>?> _promptActivity({
    required String dayTitle,
    Map<String, dynamic>? initial,
  }) async {
    final timeCtl = TextEditingController(
      text: (initial?['time'] ?? '').toString(),
    );
    final titleCtl = TextEditingController(
      text: (initial?['title'] ?? '').toString(),
    );
    final descCtl = TextEditingController(
      text: (initial?['description'] ?? '').toString(),
    );
    final locationCtl = TextEditingController(
      text: (initial?['location'] ?? '').toString(),
    );

    String selectedCategory =
        (initial?['category'] ?? '').toString().isEmpty
            ? 'Sightseeing'
            : (initial?['category'] ?? 'Sightseeing').toString();

    List<Map<String, dynamic>> locationSuggestions = [];
    Map<String, dynamic>? selectedLocation;
    bool searchingLocation = false;
    Timer? locationDebounce;

    return showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              title: const Text('Edit Activity'),
              content: SingleChildScrollView(
                child: SizedBox(
                  width: 480,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          dayTitle,
                          style: Theme.of(ctx).textTheme.bodySmall,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: timeCtl,
                        decoration: const InputDecoration(
                          labelText: 'Time (e.g. 9:00 AM)',
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: titleCtl,
                        decoration: const InputDecoration(labelText: 'Title'),
                      ),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<String>(
                        initialValue: selectedCategory,
                        decoration: const InputDecoration(
                          labelText: 'Category',
                          prefixIcon: Icon(Icons.category),
                        ),
                        items:
                            travelCategories.keys.map((cat) {
                              return DropdownMenuItem(
                                value: cat,
                                child: Row(
                                  children: [
                                    Container(
                                      width: 16,
                                      height: 16,
                                      margin: const EdgeInsets.only(right: 8),
                                      decoration: BoxDecoration(
                                        color: travelCategories[cat],
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    Text(cat),
                                  ],
                                ),
                              );
                            }).toList(),
                        onChanged: (v) {
                          setStateDialog(() {
                            selectedCategory = v ?? 'Sightseeing';
                          });
                        },
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: locationCtl,
                        decoration: InputDecoration(
                          labelText: 'Location (optional - add to map)',
                          prefixIcon: const Icon(Icons.place),
                          suffixIcon:
                              searchingLocation
                                  ? const Padding(
                                    padding: EdgeInsets.all(12),
                                    child: SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  )
                                  : null,
                        ),
                        onChanged: (v) {
                          locationDebounce?.cancel();
                          if (v.trim().isEmpty) {
                            setStateDialog(() {
                              locationSuggestions = [];
                              selectedLocation = null;
                            });
                            return;
                          }
                          locationDebounce = Timer(
                            const Duration(milliseconds: 400),
                            () async {
                              setStateDialog(() => searchingLocation = true);
                              try {
                                final results = await searchNominatim(v.trim());
                                setStateDialog(() {
                                  locationSuggestions = results;
                                  searchingLocation = false;
                                });
                              } catch (e) {
                                setStateDialog(() {
                                  locationSuggestions = [];
                                  searchingLocation = false;
                                });
                              }
                            },
                          );
                        },
                      ),
                      if (locationSuggestions.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Container(
                          constraints: const BoxConstraints(maxHeight: 150),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey.shade300),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: ListView.builder(
                            shrinkWrap: true,
                            itemCount: locationSuggestions.length,
                            itemBuilder: (ctx, i) {
                              final s = locationSuggestions[i];
                              final name = (s['name'] ?? '').toString();
                              return ListTile(
                                dense: true,
                                title: Text(name),
                                onTap: () {
                                  setStateDialog(() {
                                    locationCtl.text = name;
                                    selectedLocation = s;
                                    locationSuggestions = [];
                                  });
                                },
                              );
                            },
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      TextField(
                        controller: descCtl,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          labelText: 'Description (optional)',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(null),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () {
                    final title = titleCtl.text.trim();
                    if (title.isEmpty) return;
                    Navigator.of(ctx).pop({
                      'time': timeCtl.text.trim(),
                      'title': title,
                      'description': descCtl.text.trim(),
                      'location': locationCtl.text.trim(),
                      'category': selectedCategory,
                      'lat': selectedLocation?['lat']?.toString() ?? '',
                      'lon': selectedLocation?['lon']?.toString() ?? '',
                    });
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    ).then((result) {
      locationDebounce?.cancel();
      return result;
    });
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

  double _degToRad(double d) => d * math.pi / 180.0;

  double _haversine(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371.0;
    final dLat = _degToRad(lat2 - lat1);
    final dLon = _degToRad(lon2 - lon1);
    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_degToRad(lat1)) *
            math.cos(_degToRad(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return r * c;
  }

  Widget _imagePreview(String url, {double? height}) {
    final u = url.trim();
    if (u.isEmpty) {
      return SizedBox(height: height);
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child:
          u.startsWith('data:image')
              ? (kIsWeb
                  ? Image.network(
                    u,
                    height: height,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    errorBuilder:
                        (_, __, ___) => Container(
                          height: height,
                          alignment: Alignment.center,
                          color: Colors.black12,
                          child: const Text('Image failed to load'),
                        ),
                  )
                  : _dataUrlImage(u, height: height))
              : (u.startsWith('http')
                  ? Image.network(
                    u,
                    height: height,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    errorBuilder:
                        (_, __, ___) => Container(
                          height: height,
                          alignment: Alignment.center,
                          color: Colors.black12,
                          child: const Text('Image failed to load'),
                        ),
                  )
                  : Image.asset(
                    u,
                    height: height,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    errorBuilder:
                        (_, __, ___) => Container(
                          height: height,
                          alignment: Alignment.center,
                          color: Colors.black12,
                          child: const Text('Image failed to load'),
                        ),
                  )),
    );
  }

  Widget _dataUrlImage(String dataUrl, {double? height}) {
    try {
      final parts = dataUrl.split(',');
      if (parts.length < 2) {
        return Container(
          height: height,
          alignment: Alignment.center,
          color: Colors.black12,
          child: const Text('Image failed to load'),
        );
      }
      final bytes = base64Decode(parts.last);
      return Image.memory(
        bytes,
        height: height,
        width: double.infinity,
        fit: BoxFit.cover,
        errorBuilder:
            (_, __, ___) => Container(
              height: height,
              alignment: Alignment.center,
              color: Colors.black12,
              child: const Text('Image failed to load'),
            ),
      );
    } catch (_) {
      return Container(
        height: height,
        alignment: Alignment.center,
        color: Colors.black12,
        child: const Text('Image failed to load'),
      );
    }
  }

  Future<void> _uploadCover() async {
    final dataUrl = await pickImageDataUrl();
    if (dataUrl == null || dataUrl.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showTryprSnackBar(
          const SnackBar(
            content: Text('Photo upload is currently available on web only.'),
          ),
        );
      }
      return;
    }
    if (!mounted) return;
    setState(() => _coverImage = dataUrl);
  }

  Future<void> _addPhotoUpload() async {
    final dataUrl = await pickImageDataUrl();
    if (dataUrl == null || dataUrl.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showTryprSnackBar(
          const SnackBar(
            content: Text('Photo upload is currently available on web only.'),
          ),
        );
      }
      return;
    }
    if (!mounted) return;
    setState(() => _photoUrls.add(dataUrl));
  }

  Future<int?> _promptDays({
    required String locationName,
    int initialValue = 2,
  }) async {
    var value = initialValue.clamp(1, 21);
    return _withMapTapSuspended(
      () => showDialog<int>(
        context: context,
        builder: (ctx) {
          return AlertDialog(
            title: const Text('Recommended days here'),
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
                        const Text('Days:'),
                        const SizedBox(width: 12),
                        Expanded(
                          child: DropdownButton<int>(
                            value: value,
                            isExpanded: true,
                            items: List.generate(
                              21,
                              (i) => DropdownMenuItem(
                                value: i + 1,
                                child: Text('${i + 1} day${i == 0 ? '' : 's'}'),
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

  Future<void> _addWaypointFromResult({
    required String name,
    required double lat,
    required double lon,
  }) async {
    final days = await _promptDays(locationName: name);
    if (days == null) return;
    if (!mounted) return;
    setState(() {
      _waypoints.add(_Waypoint(name: name, lat: lat, lon: lon, days: days));
      _ensureItineraryLength(_recommendedDays);
      _syncRoutingStateWithWaypoints();
      _searchResults = [];
      _searchCtl.clear();
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

    final rawName = (campsite['name'] ?? 'Campsite').toString().trim();
    final name = rawName.isEmpty ? 'Campsite' : rawName;
    final distanceFromRouteKm =
        (campsite['distanceKmFromRoute'] as num?)?.toDouble() ?? 0.0;

    final shouldAdd = await _withMapTapSuspended(
      () => showDialog<bool>(
        context: context,
        builder: (ctx) {
          return AlertDialog(
            title: Text(name),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${distanceFromRouteKm.toStringAsFixed(1)} km from route'),
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
                child: const Text('Add as stop'),
              ),
            ],
          );
        },
      ),
    );

    if (shouldAdd != true) return;
    await _addWaypointFromResult(name: name, lat: lat, lon: lon);
  }

  Future<void> _save() async {
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) {
      ScaffoldMessenger.of(context).showTryprSnackBar(
        const SnackBar(
          content: Text('You must be signed in to create a verified trip.'),
        ),
      );
      return;
    }

    if (!(_formKey.currentState?.validate() ?? false)) {
      ScaffoldMessenger.of(context).showTryprSnackBar(
        const SnackBar(content: Text('Please fix the highlighted fields.')),
      );
      return;
    }

    if (_waypoints.isEmpty) {
      ScaffoldMessenger.of(context).showTryprSnackBar(
        const SnackBar(
          content: Text('Add at least one location to build the trip.'),
        ),
      );
      return;
    }

    final title = _trim(_titleCtl.text);
    final subtitle = _trim(_subtitleCtl.text);
    final description = _trim(_descCtl.text);
    final coverCandidate =
        _coverImage.trim().isNotEmpty
            ? _coverImage.trim()
            : (_photoUrls.isNotEmpty ? _photoUrls.first.trim() : '');

    setState(() => _saving = true);
    try {
      final recommendedDays = _recommendedDays;
      final totalKm = _totalKm;

      final bool isEditing = widget.existingTripId != null;
      final docRef =
          isEditing
              ? FirebaseFirestore.instance
                  .collection('verifiedTrips')
                  .doc(widget.existingTripId)
              : FirebaseFirestore.instance.collection('verifiedTrips').doc();
      final tripId = docRef.id;

      String coverImage = coverCandidate;
      final uploadedPhotos = <String>[];

      // Upload cover image (only if it's a data URL).
      if (coverImage.trim().startsWith('data:image')) {
        coverImage = await _uploadVerifiedTripImage(
          tripId: tripId,
          label: 'cover',
          dataUrl: coverImage.trim(),
        );
      }

      // Upload photos (only data URLs). Keep any existing http(s)/asset refs as-is.
      for (var i = 0; i < _photoUrls.length; i++) {
        final p = _photoUrls[i].trim();
        if (p.isEmpty) continue;
        if (p.startsWith('data:image')) {
          final url = await _uploadVerifiedTripImage(
            tripId: tripId,
            label: 'photo_$i',
            dataUrl: p,
          );
          uploadedPhotos.add(url);
        } else {
          uploadedPhotos.add(p);
        }
      }

      // If there was no cover, fall back to first uploaded photo.
      if (coverImage.trim().isEmpty && uploadedPhotos.isNotEmpty) {
        coverImage = uploadedPhotos.first;
      }

      // Avoid duplicates.
      final uniquePhotos = <String>[];
      final seen = <String>{};
      for (final p in uploadedPhotos) {
        final s = p.trim();
        if (s.isEmpty) continue;
        if (seen.add(s)) uniquePhotos.add(s);
      }

      final segmentCount = math.max(0, _waypoints.length - 1);
      final segmentRoutingTypes =
          _segmentRoutingTypes.take(segmentCount).map((v) {
            final norm = v.trim().toLowerCase();
            return norm == 'direct' ? 'direct' : 'calculated';
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

      final segmentRoutePreferences =
          _segmentRoutePreferences.entries
              .where((entry) => entry.key >= 0 && entry.key < segmentCount)
              .map((entry) {
                final pref = Map<String, dynamic>.from(entry.value);
                pref['segmentIndex'] = entry.key;
                return pref;
              })
              .toList();

      final tripData = <String, dynamic>{
        'title': title,
        'subtitle': subtitle,
        'description': description,
        'coverImage': coverImage,
        'recommendedDays': recommendedDays,
        // Back-compat
        'days': recommendedDays,
        'itinerary': _itinerary,
        'photos': uniquePhotos,
        'transportMode': _normalizeTransportMode(_transportMode),
        'segmentRoutingTypes': segmentRoutingTypes,
        'segmentTransportModes': segmentTransportModes,
        'routeVia': filteredRouteVia,
        'segmentRoutePreferences': segmentRoutePreferences,
        'routeInstructions': _routeInstructions.take(8).toList(),
        'waypoints':
            _waypoints
                .map(
                  (w) => {
                    'name': w.name,
                    'lat': w.lat,
                    'lon': w.lon,
                    'days': w.days,
                  },
                )
                .toList(),
        'totalStops': _waypoints.length,
        'totalKm': _roadDistanceKm ?? totalKm,
      };

      if (isEditing) {
        // Update existing trip - preserve createdAt/createdByUid, add updatedAt
        tripData['updatedAt'] = FieldValue.serverTimestamp();
        tripData['updatedByUid'] = u.uid;
        await docRef.update(tripData);
      } else {
        // Create new trip
        tripData['createdAt'] = FieldValue.serverTimestamp();
        tripData['createdByUid'] = u.uid;
        await docRef.set(tripData);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showTryprSnackBar(
          SnackBar(
            content: Text(
              isEditing ? 'Verified trip updated' : 'Verified trip created',
            ),
          ),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showTryprSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final mapHeight = (screenWidth * 0.55).clamp(220.0, 340.0);

    final cover =
        _coverImage.trim().isNotEmpty
            ? _coverImage.trim()
            : (_photoUrls.isNotEmpty ? _photoUrls.first : '');
    final km = _roadDistanceKm ?? _totalKm;
    final selectedSegment = _selectedSegmentIndex;
    final selectedLegMode =
        selectedSegment == null
            ? _normalizeTransportMode(_transportMode)
            : _segmentTransportModeAt(selectedSegment);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.existingTripId != null
              ? 'Edit verified trip'
              : 'New verified trip',
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child:
                _saving
                    ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : const Text('Save'),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (cover.isNotEmpty) ...[
              _imagePreview(cover, height: 220),
              const SizedBox(height: 12),
            ],

            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    TextFormField(
                      controller: _titleCtl,
                      decoration: const InputDecoration(labelText: 'Title'),
                      validator:
                          (v) =>
                              _trim(v ?? '').isEmpty
                                  ? 'Title is required'
                                  : null,
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _subtitleCtl,
                      decoration: const InputDecoration(
                        labelText: 'Subtitle (optional)',
                      ),
                    ),
                    const SizedBox(height: 8),
                    InputDecorator(
                      decoration: const InputDecoration(
                        labelText: 'Cover photo',
                      ),
                      child: Text(
                        _coverImage.isNotEmpty ? 'Uploaded' : 'None',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        OutlinedButton.icon(
                          onPressed: _saving ? null : _uploadCover,
                          icon: const Icon(Icons.upload),
                          label: const Text('Upload cover'),
                        ),
                        const SizedBox(width: 8),
                        if (_coverImage.isNotEmpty)
                          TextButton(
                            onPressed:
                                _saving
                                    ? null
                                    : () => setState(() => _coverImage = ''),
                            child: const Text('Remove cover'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _descCtl,
                      maxLines: 6,
                      decoration: const InputDecoration(
                        labelText: 'Description',
                      ),
                      validator:
                          (v) =>
                              _trim(v ?? '').isEmpty
                                  ? 'Description is required'
                                  : null,
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Recommended: $_recommendedDays days',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        Text(
                          '${_waypoints.length} stops'
                          '${_waypoints.length > 1 ? ' • ${km.toStringAsFixed(0)} km' : ''}'
                          '${_routeDurationMin != null ? ' • ${_routeDurationMin!.round()} min' : ''}',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: Colors.black54),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 12),

            Text(
              'Build the route',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),

            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    if (_segmentCount > 0) ...[
                      Row(
                        children: [
                          Text(
                            'Leg mode (${selectedSegment == null ? 'No leg selected' : 'Leg ${selectedSegment + 1}'})',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children:
                                    _transportOptions.map((opt) {
                                      final blocked =
                                          selectedSegment != null &&
                                          opt.mode == 'car' &&
                                          _isCarModeBlockedForSegment(
                                            selectedSegment,
                                          );
                                      return Padding(
                                        padding: const EdgeInsets.only(
                                          right: 6,
                                        ),
                                        child: ChoiceChip(
                                          label: Text(
                                            opt.emoji,
                                            style: TextStyle(
                                              fontSize: 18,
                                              color:
                                                  blocked
                                                      ? Colors.grey.shade500
                                                      : null,
                                            ),
                                          ),
                                          selected: selectedLegMode == opt.mode,
                                          showCheckmark: false,
                                          visualDensity: VisualDensity.compact,
                                          onSelected:
                                              blocked
                                                  ? null
                                                  : (v) {
                                                    if (!v) return;
                                                    _setTransportMode(opt.mode);
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
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Tap a stop row to change the active leg. For portage routing, use hiking mode.',
                          style: TextStyle(fontSize: 11, color: Colors.black54),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Switch(
                            value: _adjustRoute,
                            onChanged:
                                _saving
                                    ? null
                                    : (value) =>
                                        setState(() => _adjustRoute = value),
                          ),
                          const SizedBox(width: 6),
                          const Expanded(
                            child: Text(
                              'Adjust route line (tap route to compare options or drop via pins)',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                          ),
                          if (_adjustRoute && _routeVia.isNotEmpty)
                            TextButton.icon(
                              onPressed:
                                  _saving
                                      ? null
                                      : () => setState(() => _routeVia = []),
                              icon: const Icon(Icons.clear),
                              label: const Text('Clear pins'),
                            ),
                        ],
                      ),
                      if (_routeInstructions.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              _routeInstructions.take(3).join(' • '),
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.black54,
                              ),
                            ),
                          ),
                        ),
                    ],
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _searchCtl,
                            decoration: InputDecoration(
                              prefixIcon: const Icon(Icons.search),
                              hintText:
                                  _isHikingSearchMode
                                      ? 'Search hiking trails, campsites, portages'
                                      : 'Search locations',
                            ),
                            onChanged: (v) {
                              _searchDebounce?.cancel();
                              _searchDebounce = Timer(
                                const Duration(milliseconds: 400),
                                () async {
                                  final q = _searchCtl.text.trim();
                                  if (q.isEmpty) {
                                    if (mounted) {
                                      setState(() => _searchResults = []);
                                    }
                                    return;
                                  }
                                  final results = await _searchResultsForUi(q);
                                  if (!mounted) return;
                                  setState(() => _searchResults = results);
                                },
                              );
                            },
                            onSubmitted: (v) async {
                              final q = v.trim();
                              if (q.isEmpty) return;
                              final results = await _searchResultsForUi(q);
                              if (results.isEmpty) return;
                              final r = results.first;
                              final lat =
                                  (r['lat'] is num)
                                      ? (r['lat'] as num).toDouble()
                                      : double.tryParse(
                                            r['lat']?.toString() ?? '',
                                          ) ??
                                          0.0;
                              final lon =
                                  (r['lon'] is num)
                                      ? (r['lon'] as num).toDouble()
                                      : double.tryParse(
                                            r['lon']?.toString() ?? '',
                                          ) ??
                                          0.0;
                              await _addWaypointFromResult(
                                name: (r['name'] ?? q).toString(),
                                lat: lat,
                                lon: lon,
                              );
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed:
                              _saving
                                  ? null
                                  : () async {
                                    final q = _searchCtl.text.trim();
                                    if (q.isEmpty) return;
                                    final results = await _searchResultsForUi(
                                      q,
                                    );
                                    if (results.isEmpty) return;
                                    final r = results.first;
                                    final lat =
                                        (r['lat'] is num)
                                            ? (r['lat'] as num).toDouble()
                                            : double.tryParse(
                                                  r['lat']?.toString() ?? '',
                                                ) ??
                                                0.0;
                                    final lon =
                                        (r['lon'] is num)
                                            ? (r['lon'] as num).toDouble()
                                            : double.tryParse(
                                                  r['lon']?.toString() ?? '',
                                                ) ??
                                                0.0;
                                    await _addWaypointFromResult(
                                      name: (r['name'] ?? q).toString(),
                                      lat: lat,
                                      lon: lon,
                                    );
                                  },
                          child: const Text('Add'),
                        ),
                      ],
                    ),
                    if (_searchResults.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Container(
                        height: 160,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          border: Border.all(color: Colors.grey.shade300),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: ListView.builder(
                          itemCount: _searchResults.length,
                          itemBuilder: (ctx, i) {
                            final r = _searchResults[i];
                            final name =
                                (r['name'] ?? 'Result ${i + 1}').toString();
                            final lat =
                                (r['lat'] is num)
                                    ? (r['lat'] as num).toDouble()
                                    : double.tryParse(
                                          r['lat']?.toString() ?? '',
                                        ) ??
                                        0.0;
                            final lon =
                                (r['lon'] is num)
                                    ? (r['lon'] as num).toDouble()
                                    : double.tryParse(
                                          r['lon']?.toString() ?? '',
                                        ) ??
                                        0.0;
                            return ListTile(
                              title: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '${lat.toStringAsFixed(4)}, ${lon.toStringAsFixed(4)}',
                              ),
                              trailing: TextButton(
                                onPressed:
                                    _saving
                                        ? null
                                        : () => _addWaypointFromResult(
                                          name: name,
                                          lat: lat,
                                          lon: lon,
                                        ),
                                child: const Text('Add'),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    SizedBox(
                      height: mapHeight,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Material(
                          color: Theme.of(context).colorScheme.surface,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.grey.shade300),
                            ),
                            child: IgnorePointer(
                              ignoring: _suspendMapTap,
                              child: MapEmbed(
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
                                segmentRoutingTypes: _segmentRoutingTypes,
                                routeVia: _routeVia,
                                onRouteSummary: (
                                  distanceMeters,
                                  durationSeconds,
                                ) {
                                  if (!mounted) return;
                                  setState(() {
                                    _roadDistanceKm = distanceMeters / 1000.0;
                                    _routeDurationMin = durationSeconds / 60.0;
                                  });
                                },
                                onRouteInstructions: (lines) {
                                  if (!mounted) return;
                                  setState(() => _routeInstructions = lines);
                                },
                                onHikingCampsiteTap: _onHikingCampsiteTap,
                                onRouteTapAddVia:
                                    (_adjustRoute)
                                        ? (afterIndex, lat, lon) {
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
                                          _deleteViaPoint(viaIndex: viaIndex);
                                        }
                                        : null,
                                secondaryPoints:
                                    _itinerary.asMap().entries.expand((
                                      dayEntry,
                                    ) {
                                      final dayIndex = dayEntry.key;
                                      final day = dayEntry.value;
                                      final acts =
                                          (day['activities']
                                              as List<dynamic>?) ??
                                          [];
                                      return acts
                                          .asMap()
                                          .entries
                                          .where(
                                            (a) =>
                                                (a.value
                                                        as Map)['locationLat'] !=
                                                    null &&
                                                (a.value
                                                        as Map)['locationLon'] !=
                                                    null,
                                          )
                                          .map(
                                            (a) => {
                                              'lat':
                                                  (a.value
                                                      as Map)['locationLat'],
                                              'lon':
                                                  (a.value
                                                      as Map)['locationLon'],
                                              'kind': 'activity',
                                              'category':
                                                  (a.value
                                                      as Map)['category'] ??
                                                  'Sightseeing',
                                              'dayIndex': dayIndex,
                                              'activityIndex': a.key,
                                            },
                                          );
                                    }).toList(),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 12),

            if (_waypoints.isEmpty)
              const Text(
                'No stops yet — search a location to start building the verified trip.',
              ),

            if (_waypoints.isNotEmpty) ...[
              Row(
                children: [
                  Text(
                    'Stops',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    'Total: $_recommendedDays days',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: Colors.black54),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Card(
                child: ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _waypoints.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (ctx, i) {
                    final w = _waypoints[i];
                    final isSegmentRow = i < (_waypoints.length - 1);
                    final next = isSegmentRow ? _waypoints[i + 1] : null;
                    final segKm =
                        next == null
                            ? 0.0
                            : _haversine(w.lat, w.lon, next.lat, next.lon);
                    final segType =
                        (i < _segmentRoutingTypes.length)
                            ? _segmentRoutingTypes[i]
                            : 'calculated';
                    final segMode = _segmentTransportModeAt(i);
                    final selectedSeg = _selectedSegmentIndex;
                    final isActiveSegment =
                        isSegmentRow && selectedSeg != null && selectedSeg == i;
                    final routePref = _segmentRoutePreferences[i];
                    final routePrefSummary =
                        (routePref?['summary'] ?? '').toString().trim();
                    final routePrefPortageCount =
                        (routePref?['portageCount'] as num?)?.toInt() ?? 0;
                    final routePrefCarryKm =
                        (routePref?['portageDistanceKm'] as num?)?.toDouble() ??
                        0.0;
                    final carBlocked =
                        isSegmentRow && _isCarModeBlockedForSegment(i);

                    return InkWell(
                      onTap:
                          isSegmentRow ? () => _setActiveSegmentIndex(i) : null,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color:
                              isActiveSegment
                                  ? Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: 0.08)
                                  : null,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        w.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '${w.lat.toStringAsFixed(4)}, ${w.lon.toStringAsFixed(4)}',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: Colors.black54,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                SizedBox(
                                  width: 72,
                                  child: OutlinedButton(
                                    onPressed:
                                        _saving
                                            ? null
                                            : () async {
                                              final v = await _promptDays(
                                                locationName: w.name,
                                                initialValue: w.days,
                                              );
                                              if (v == null) return;
                                              if (!mounted) return;
                                              setState(() {
                                                w.days = v;
                                                _ensureItineraryLength(
                                                  _recommendedDays,
                                                );
                                              });
                                            },
                                    child: Text('${w.days}d'),
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Remove stop',
                                  onPressed:
                                      _saving
                                          ? null
                                          : () => setState(() {
                                            _waypoints.removeAt(i);
                                            _ensureItineraryLength(
                                              _recommendedDays,
                                            );
                                            _syncRoutingStateWithWaypoints();
                                          }),
                                  icon: const Icon(Icons.delete_outline),
                                ),
                              ],
                            ),
                            if (isSegmentRow) ...[
                              const SizedBox(height: 8),
                              Text(
                                '${segKm.toStringAsFixed(2)} km to next stop',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.black54,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  SizedBox(
                                    width: 92,
                                    child: InputDecorator(
                                      decoration: const InputDecoration(
                                        labelText: 'Mode',
                                        isDense: true,
                                        border: OutlineInputBorder(),
                                        contentPadding: EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4,
                                        ),
                                      ),
                                      child: DropdownButtonHideUnderline(
                                        child: DropdownButton<String>(
                                          value: segMode,
                                          isDense: true,
                                          isExpanded: true,
                                          items:
                                              _transportOptions.map((opt) {
                                                return DropdownMenuItem(
                                                  value: opt.mode,
                                                  enabled:
                                                      !carBlocked ||
                                                      opt.mode != 'car',
                                                  child: Text(
                                                    opt.emoji,
                                                    style: TextStyle(
                                                      fontSize: 18,
                                                      color:
                                                          carBlocked &&
                                                                  opt.mode ==
                                                                      'car'
                                                              ? Colors
                                                                  .grey
                                                                  .shade500
                                                              : null,
                                                    ),
                                                  ),
                                                );
                                              }).toList(),
                                          onChanged: (value) {
                                            if (value == null) return;
                                            _setSegmentTransportMode(i, value);
                                          },
                                        ),
                                      ),
                                    ),
                                  ),
                                  ChoiceChip(
                                    label: const Text('Calculated'),
                                    selected:
                                        segType.trim().toLowerCase() ==
                                        'calculated',
                                    visualDensity: VisualDensity.compact,
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
                                    label: const Text('Direct'),
                                    selected:
                                        segType.trim().toLowerCase() ==
                                        'direct',
                                    visualDensity: VisualDensity.compact,
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
                                    onPressed:
                                        _saving
                                            ? null
                                            : () =>
                                                _showSegmentRouteChoicesDialog(
                                                  segmentIndex: i,
                                                ),
                                    icon: const Icon(Icons.alt_route),
                                    label: const Text('Portage choices'),
                                  ),
                                ],
                              ),
                              if (routePrefSummary.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                Text(
                                  'Preferred: $routePrefSummary'
                                  '${routePrefPortageCount > 0 ? ' • $routePrefPortageCount portage${routePrefPortageCount == 1 ? '' : 's'}' : ''}'
                                  '${routePrefCarryKm > 0 ? ' • ~${routePrefCarryKm.toStringAsFixed(1)} km carry' : ''}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.black54,
                                  ),
                                ),
                              ],
                            ],
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],

            if (_waypoints.isNotEmpty) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  Text(
                    'Itinerary (by day)',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${_itinerary.length} days',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: Colors.black54),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Card(
                child: ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _itinerary.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (ctx, dayIndex) {
                    final day = _itinerary[dayIndex];
                    final title =
                        (day['title'] ?? 'Day ${dayIndex + 1}').toString();
                    final notes = (day['notes'] ?? '').toString();
                    final activities = List<Map<String, dynamic>>.from(
                      (day['activities'] as List<dynamic>? ?? const []).map(
                        (a) => Map<String, dynamic>.from(a as Map),
                      ),
                    );

                    return ExpansionTile(
                      title: Text(title),
                      subtitle:
                          notes.trim().isEmpty
                              ? Text(
                                '${activities.length} activit${activities.length == 1 ? 'y' : 'ies'}',
                              )
                              : Text(
                                notes,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      children: [
                        TextField(
                          enabled: !_saving,
                          decoration: const InputDecoration(
                            labelText: 'Day notes (optional)',
                          ),
                          controller: TextEditingController(text: notes)
                            ..selection = TextSelection.collapsed(
                              offset: notes.length,
                            ),
                          onChanged: (v) {
                            setState(() {
                              day['notes'] = v;
                            });
                          },
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            OutlinedButton.icon(
                              onPressed:
                                  _saving
                                      ? null
                                      : () async {
                                        final res = await _promptActivity(
                                          dayTitle: title,
                                        );
                                        if (res == null) return;
                                        setState(() {
                                          // Parse lat/lon first
                                          final lat = double.tryParse(
                                            res['lat'] ?? '',
                                          );
                                          final lon = double.tryParse(
                                            res['lon'] ?? '',
                                          );

                                          final list =
                                              List<Map<String, dynamic>>.from(
                                                day['activities']
                                                        as List<dynamic>? ??
                                                    const [],
                                              );
                                          list.add({
                                            'time': res['time'] ?? '',
                                            'title': res['title'] ?? '',
                                            'description':
                                                res['description'] ?? '',
                                            'location': res['location'] ?? '',
                                            'category':
                                                res['category'] ??
                                                'Sightseeing',
                                            'locationLat': lat,
                                            'locationLon': lon,
                                          });
                                          day['activities'] = list;
                                        });
                                      },
                              icon: const Icon(Icons.add),
                              label: const Text('Add activity'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        if (activities.isEmpty)
                          const Text('No activities yet.'),
                        if (activities.isNotEmpty)
                          ListView.separated(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: activities.length,
                            separatorBuilder:
                                (_, __) => const Divider(height: 1),
                            itemBuilder: (ctx2, aIndex) {
                              final a = activities[aIndex];
                              final aTime = (a['time'] ?? '').toString();
                              final aTitle = (a['title'] ?? '').toString();
                              final aDesc = (a['description'] ?? '').toString();
                              final aLocation =
                                  (a['location'] ?? '').toString();
                              final aCategory =
                                  (a['category'] ?? '').toString();

                              return ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading:
                                    aLocation.trim().isNotEmpty
                                        ? Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            if (aCategory.isNotEmpty &&
                                                travelCategories.containsKey(
                                                  aCategory,
                                                ))
                                              Container(
                                                width: 12,
                                                height: 12,
                                                margin: const EdgeInsets.only(
                                                  right: 6,
                                                ),
                                                decoration: BoxDecoration(
                                                  color:
                                                      travelCategories[aCategory],
                                                  shape: BoxShape.circle,
                                                ),
                                              ),
                                            const Icon(Icons.place, size: 20),
                                          ],
                                        )
                                        : null,
                                title: Text(
                                  aTitle.isEmpty ? 'Activity' : aTitle,
                                ),
                                subtitle:
                                    (aTime.trim().isEmpty &&
                                            aDesc.trim().isEmpty &&
                                            aLocation.trim().isEmpty)
                                        ? null
                                        : Text(
                                          [
                                            if (aTime.trim().isNotEmpty)
                                              aTime.trim(),
                                            if (aLocation.trim().isNotEmpty)
                                              '📍 ${aLocation.trim()}',
                                            if (aDesc.trim().isNotEmpty)
                                              aDesc.trim(),
                                          ].join(' • '),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      tooltip: 'Edit activity',
                                      onPressed:
                                          _saving
                                              ? null
                                              : () async {
                                                final res =
                                                    await _promptActivity(
                                                      dayTitle: title,
                                                      initial: a,
                                                    );
                                                if (res == null) return;
                                                setState(() {
                                                  // Parse lat/lon first
                                                  final lat = double.tryParse(
                                                    res['lat'] ?? '',
                                                  );
                                                  final lon = double.tryParse(
                                                    res['lon'] ?? '',
                                                  );

                                                  final list = List<
                                                    Map<String, dynamic>
                                                  >.from(
                                                    day['activities']
                                                            as List<dynamic>? ??
                                                        const [],
                                                  );
                                                  list[aIndex] = {
                                                    'time': res['time'] ?? '',
                                                    'title': res['title'] ?? '',
                                                    'description':
                                                        res['description'] ??
                                                        '',
                                                    'location':
                                                        res['location'] ?? '',
                                                    'category':
                                                        res['category'] ??
                                                        'Sightseeing',
                                                    'locationLat': lat,
                                                    'locationLon': lon,
                                                  };
                                                  day['activities'] = list;
                                                });
                                              },
                                      icon: const Icon(Icons.edit_outlined),
                                    ),
                                    IconButton(
                                      tooltip: 'Delete activity',
                                      onPressed:
                                          _saving
                                              ? null
                                              : () {
                                                setState(() {
                                                  final list = List<
                                                    Map<String, dynamic>
                                                  >.from(
                                                    day['activities']
                                                            as List<dynamic>? ??
                                                        const [],
                                                  );
                                                  list.removeAt(aIndex);
                                                  day['activities'] = list;
                                                });
                                              },
                                      icon: const Icon(Icons.delete_outline),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                      ],
                    );
                  },
                ),
              ),
            ],

            const SizedBox(height: 12),

            Row(
              children: [
                Text(
                  'Photo log',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                OutlinedButton.icon(
                  onPressed: _saving ? null : _addPhotoUpload,
                  icon: const Icon(Icons.add),
                  label: const Text('Add photo'),
                ),
              ],
            ),
            const SizedBox(height: 8),

            if (_photoUrls.isEmpty)
              const Text(
                'No photos yet. Upload a few images to make this feel premium.',
              ),

            if (_photoUrls.isNotEmpty)
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 1.3,
                ),
                itemCount: _photoUrls.length,
                itemBuilder: (ctx, i) {
                  final url = _photoUrls[i];
                  return Stack(
                    children: [
                      Positioned.fill(child: _imagePreview(url)),
                      Positioned(
                        top: 6,
                        right: 6,
                        child: Material(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(16),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap:
                                _saving
                                    ? null
                                    : () =>
                                        setState(() => _photoUrls.removeAt(i)),
                            child: const Padding(
                              padding: EdgeInsets.all(6),
                              child: Icon(Icons.close, color: Colors.white),
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}
