import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:trypr/widgets/web_interceptor.dart';
import 'package:trypr/theme/app_theme.dart';
import 'package:trypr/widgets/top_taskbar.dart';
import 'package:trypr/widgets/map_embed.dart';
import 'package:trypr/widgets/globe_3d_embed.dart';
import 'package:trypr/services/geocode.dart';
import 'package:trypr/services/location_display.dart';
import 'package:trypr/widgets/activity_finder_modal.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

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
  double? _roadDistanceKm;
  double? _routeDurationMin;
  User? _currentUser;
  bool _isSaving = false;
  DocumentReference<Map<String, dynamic>>? _lastSavedTripRef;

  String _transportMode = 'driving';
  bool _adjustRoute = false;
  List<Map<String, dynamic>> _routeVia = [];
  List<String> _routeInstructions = [];

  List<String> _segmentRoutingTypes = [];
  Map<String, dynamic>? _transitArrivalStop;

  bool _suspendMapTap = false;
  bool _didShowOnboarding = false;
  bool _isRenamingTripName = false;
  final FocusNode _renameTripNameFocus = FocusNode();

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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a trip date range first')),
      );
      return;
    }
    if (_waypoints.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Add a waypoint first')));
      return;
    }
    final last = _waypoints.last;
    final startDate = _tripStartDateYmd();
    final endDate = _tripEndDateYmd();

    await showSmartRouteModal(
      context,
      title: '✨ Suggest Next',
      destinationName: formatLocationDisplay(raw: last.name).title,
      lat: last.lat,
      lon: last.lon,
      startDate: startDate,
      endDate: endDate,
      onAddStop: (suggestion) async {
        final coords = await _geocodeSuggestionLatLon(suggestion);
        if (coords == null) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a trip date range first')),
      );
      return;
    }
    if (_waypoints.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
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
      title: '✨ Find Stop Between',
      destinationName: '${a.name} → ${b.name}',
      lat: midLat,
      lon: midLon,
      startDate: startDate,
      endDate: endDate,
      onAddStop: (suggestion) async {
        final coords = await _geocodeSuggestionLatLon(suggestion);
        if (coords == null) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not locate that stop')),
          );
          return;
        }

        // Add as a route via point so it doesn't affect nights allocation.
        if (!mounted) return;
        setState(() {
          _adjustRoute = true;
          _upsertViaPoint(
            afterIndex: afterIndex,
            lat: coords.$1,
            lon: coords.$2,
          );
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Added a stop between ${a.name} and ${b.name}'),
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
    return m == 'bikepacking' || m == 'backpacking';
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

  Future<T?> _withMapTapSuspended<T>(Future<T?> Function() action) async {
    if (!mounted) return null;
    setState(() => _suspendMapTap = true);
    try {
      return await action();
    } finally {
      if (mounted) setState(() => _suspendMapTap = false);
    }
  }

  int get _totalTripDays {
    final r = _tripRange;
    if (r == null) return 0;
    return r.end.difference(r.start).inDays + 1;
  }

  int get _assignedNights {
    var total = 0;
    for (final w in _waypoints) {
      total += w.nights;
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
    final initial =
        _tripRange ??
        DateTimeRange(
          start: _stripTime(now),
          end: _stripTime(now.add(const Duration(days: 3))),
        );
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
      initialDateRange: initial,
    );
    if (picked == null) return null;
    return DateTimeRange(
      start: _stripTime(picked.start),
      end: _stripTime(picked.end),
    );
  }

  Future<void> _maybeShowOnboarding() async {
    if (_didShowOnboarding) return;
    _didShowOnboarding = true;
    if (_hasTripBasics) return;
    await _showTripBasicsDialog();
  }

  Future<void> _showTripBasicsDialog() async {
    final localName = TextEditingController(text: _tripNameCtrl.text.trim());
    DateTimeRange? localRange = _tripRange;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx2, setState2) {
            final hasName = localName.text.trim().isNotEmpty;
            final hasDates = localRange != null;
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
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              final picked = await _pickTripDateRange();
                              if (picked == null) return;
                              setState2(() => localRange = picked);
                            },
                            icon: const Icon(Icons.date_range),
                            label: Text(
                              localRange == null
                                  ? 'Select dates'
                                  : '${_ymd(localRange!.start)} → ${_ymd(localRange!.end)}',
                            ),
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
    );

    localName.dispose();

    if (!mounted) return;
    if (localName.text.trim().isNotEmpty && localRange != null) {
      setState(() {
        _tripNameCtrl.text = localName.text.trim();
        _tripRange = localRange;
        _syncTripDatesText();
      });
    }
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

    return showDialog<int>(
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
                              child: Text('${i + 1} night${i == 0 ? '' : 's'}'),
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a trip date range first')),
      );
      return;
    }

    final remaining = _remainingNights;
    if (remaining <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
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

      _searchResults = [];
      _searchCtrl.clear();
    });
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
    final meDoc =
        await FirebaseFirestore.instance.collection('users').doc(me.uid).get();
    final friendsRaw = meDoc.data()?['friends'] as List<dynamic>? ?? [];
    final friends =
        friendsRaw.map<Map<String, dynamic>>((f) {
          if (f is Map) return Map<String, dynamic>.from(f);
          return {'id': f.toString()};
        }).toList();

    final selected = <String>{};
    await _withMapTapSuspended(
      () => showDialog<void>(
        context: context,
        builder: (ctx) {
          return AlertDialog(
            title: const Text('Share trip with friends'),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: SizedBox(
                width: double.maxFinite,
                child: StatefulBuilder(
                  builder: (ctx2, setState) {
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (friends.isEmpty)
                          const Text('No friends to share with'),
                        if (friends.isNotEmpty)
                          SizedBox(
                            height: 280,
                            child: ListView.builder(
                              itemCount: friends.length,
                              itemBuilder: (ctx3, i) {
                                final f = friends[i];
                                final uid = (f['uid'] ?? f['id'])?.toString();
                                final label =
                                    (f['displayName'] ??
                                            f['name'] ??
                                            f['email'] ??
                                            uid ??
                                            'Friend')
                                        .toString();
                                return CheckboxListTile(
                                  value: uid != null && selected.contains(uid),
                                  onChanged: (v) {
                                    if (uid == null) return;
                                    setState(() {
                                      if (v == true) {
                                        selected.add(uid);
                                      } else {
                                        selected.remove(uid);
                                      }
                                    });
                                  },
                                  title: Text(label),
                                  subtitle: Text((f['email'] ?? '').toString()),
                                );
                              },
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () async {
                  Navigator.of(ctx).pop();
                  if (selected.isEmpty) return;
                  try {
                    final tripId = _lastSavedTripRef!.id;
                    await _lastSavedTripRef!.update({
                      'sharedWith': FieldValue.arrayUnion(selected.toList()),
                    });
                    for (final uid in selected) {
                      final dest = FirebaseFirestore.instance
                          .collection('users')
                          .doc(uid)
                          .collection('sharedTrips')
                          .doc(tripId);
                      await dest.set({
                        'ownerUid': me.uid,
                        'ownerName': me.displayName ?? me.email ?? me.uid,
                        'tripRef': _lastSavedTripRef!.path,
                        'tripName': _tripNameCtrl.text.trim(),
                        'createdAt': FieldValue.serverTimestamp(),
                      });
                    }
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Trip shared')),
                      );
                    }
                  } catch (err) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Failed to share: $err')),
                      );
                    }
                  }
                },
                child: const Text('Share'),
              ),
            ],
          );
        },
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

      // Via points are indexed by segment; safest is to clear.
      _routeVia = [];
    });
  }

  @override
  void initState() {
    super.initState();
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
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _searchDebounce?.cancel();
    _tripNameCtrl.dispose();
    _tripDatesCtrl.dispose();
    _searchCtrl.dispose();
    _panelScrollCtrl.dispose();
    _renameTripNameFocus.dispose();
    super.dispose();
  }

  void _setTransportMode(String mode) {
    final m = mode.trim().toLowerCase();
    if (m == _transportMode) return;
    setState(() {
      _transportMode = m;
      _routeInstructions = [];
      if (_transportMode != 'transit') {
        _transitArrivalStop = null;
      }
    });
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

    await showDialog<void>(
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
              label: const Text('Find Stop Between'),
            ),
          ],
        );
      },
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
        ScaffoldMessenger.of(context).showSnackBar(
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
        final nights = _waypoints[i].nights;
        final display = formatLocationDisplay(raw: _waypoints[i].name);

        int offsetDays = 0;
        for (var j = 0; j < i; j++) {
          offsetDays += _waypoints[j].nights;
        }
        String dateStr = '';
        if (_tripRange != null) {
          final start = _tripRange!.start.add(Duration(days: offsetDays));
          final end = start.add(Duration(days: math.max(0, nights - 1)));
          dateStr = '${_ymd(start)} → ${_ymd(end)}';
        }

        final maxNightsForRow =
            _tripRange == null
                ? 30
                : math.max(1, _totalTripDays - (_assignedNights - nights));

        final isSegmentRow = !isLast;
        final segType =
            (isSegmentRow && i < _segmentRoutingTypes.length)
                ? _segmentRoutingTypes[i]
                : 'calculated';
        final segTypeNorm = segType.trim().toLowerCase();

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
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.grey.shade200),
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
                                    value: nights.clamp(1, maxNightsForRow),
                                    isDense: true,
                                    isExpanded: true,
                                    items: List.generate(
                                      maxNightsForRow,
                                      (idx) => DropdownMenuItem(
                                        value: idx + 1,
                                        child: Text('${idx + 1}'),
                                      ),
                                    ),
                                    onChanged: (v) {
                                      if (v == null) return;
                                      setState(() => _waypoints[i].nights = v);
                                    },
                                  ),
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
                              ? '$nights night${nights == 1 ? '' : 's'}'
                              : '$nights night${nights == 1 ? '' : 's'} · $dateStr',
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
                                      foregroundColor: const Color(0xFF00897B),
                                    ),
                                    onPressed:
                                        () => _smartFindStopBetween(
                                          afterIndex: i,
                                        ),
                                    icon: const Text('✨'),
                                    label: const Text(
                                      'Find Stop Between',
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
                                  label: const Text('Suggest Next'),
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }

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
                const Text(
                  'Transportation',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children:
                          [
                            {'mode': 'driving', 'label': 'Car', 'emoji': '🚗'},
                            {
                              'mode': 'flying',
                              'label': 'Flight',
                              'emoji': '✈️',
                            },
                            {
                              'mode': 'transit',
                              'label': 'Train',
                              'emoji': '🚆',
                            },
                            {'mode': 'walking', 'label': 'Walk', 'emoji': '🚶'},
                            {'mode': 'biking', 'label': 'Bike', 'emoji': '🚲'},
                            {
                              'mode': 'bikepacking',
                              'label': 'Bikepack',
                              'emoji': '🚵',
                            },
                            {
                              'mode': 'backpacking',
                              'label': 'Backpack',
                              'emoji': '🎒',
                            },
                          ].map((opt) {
                            final mode = opt['mode'] as String;
                            final selected = _transportMode == mode;
                            return Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: ChoiceChip(
                                label: Text(
                                  opt['emoji'] as String,
                                  style: const TextStyle(fontSize: 14),
                                ),
                                selected: selected,
                                showCheckmark: false,
                                visualDensity: VisualDensity.compact,
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                labelPadding: const EdgeInsets.symmetric(
                                  horizontal: 2,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 2,
                                ),
                                selectedColor:
                                    Theme.of(context).colorScheme.primary,
                                backgroundColor: Colors.grey.shade200,
                                onSelected: (v) {
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
                'Nights assigned: $_assignedNights / $_totalTripDays',
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
            if (_transportMode == 'transit' && _routeInstructions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Transit (suggested lines):',
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
                      : () async {
                        if (_waypoints.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Add at least one waypoint'),
                            ),
                          );
                          return;
                        }
                        if (_tripRange == null) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Select a trip date range first'),
                            ),
                          );
                          return;
                        }
                        if (!_hasValidAllocation) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Adjust nights to match the trip length',
                              ),
                            ),
                          );
                          return;
                        }
                        setState(() => _isSaving = true);
                        final name = _tripNameCtrl.text.trim();
                        final range = _tripRange!;
                        final tripStart = range.start;
                        final tripEnd = range.end;
                        final data = {
                          'name': name,
                          'days': _totalTripDays,
                          'totalDays': _totalTripDays,
                          'startDate': _ymd(tripStart),
                          'endDate': _ymd(tripEnd),
                          'createdAt': FieldValue.serverTimestamp(),
                          'totalKm': _totalKm,
                          'transportMode': _transportMode,
                          'routeVia': _routeVia,
                          'waypoints':
                              _waypoints.asMap().entries.map((e) {
                                final idx = e.key;
                                final w = e.value;
                                int offset = 0;
                                for (var j = 0; j < idx; j++) {
                                  offset += _waypoints[j].nights;
                                }
                                final start = tripStart.add(
                                  Duration(days: offset),
                                );
                                final end = start.add(
                                  Duration(days: math.max(0, w.nights - 1)),
                                );
                                final m = {
                                  'name': w.name,
                                  'lat': w.lat,
                                  'lon': w.lon,
                                  'nights': w.nights,
                                  'startDate': _ymd(start),
                                  'endDate': _ymd(end),
                                };
                                return m;
                              }).toList(),
                        };
                        try {
                          final uid = FirebaseAuth.instance.currentUser!.uid;
                          final requiresGearList = _isAdventureMode(
                            _transportMode,
                          );
                          final ref = await FirebaseFirestore.instance
                              .collection('users')
                              .doc(uid)
                              .collection('trips')
                              .add({
                                ...data,
                                'requires_gear_list': requiresGearList,
                                'segmentRoutingTypes': _segmentRoutingTypes,
                                if (_transportMode == 'transit' &&
                                    _transitArrivalStop != null)
                                  'transitArrivalStop': _transitArrivalStop,
                              });
                          _lastSavedTripRef = ref;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Trip saved to My Trips'),
                            ),
                          );
                        } catch (e) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Save failed: $e')),
                          );
                        } finally {
                          setState(() => _isSaving = false);
                        }
                      },
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
                      if (mounted) setState(() => _suspendMapTap = false);
                      if (_tripRange == null) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Select a trip date range first'),
                          ),
                        );
                        return;
                      }
                      _addWaypointFromLookup(v);
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
                  hint: 'Search locations',
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
                      var results = await searchNominatim(q);
                      if (results.isEmpty) {
                        results = _fallbackSearchResults(q);
                      }
                      if (mounted) setState(() => _searchResults = results);
                    },
                  );
                },
                onSubmitted: (v) async {
                  if (_tripRange == null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Select a trip date range first'),
                      ),
                    );
                    return;
                  }

                  final q = v.trim();
                  if (q.isEmpty) return;

                  var results = await searchNominatim(q);
                  if (results.isEmpty) {
                    results = _fallbackSearchResults(q);
                  }
                  if (results.isEmpty) {
                    final match = _sampleLookup.keys.firstWhere(
                      (k) => k.toLowerCase().contains(q.toLowerCase()),
                      orElse: () => '',
                    );
                    if (match.isNotEmpty) {
                      _addWaypointFromLookup(match);
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
                            constraints: const BoxConstraints(maxHeight: 320),
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
                                      ).showSnackBar(
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

          final overlayTop = (maxH < 520) ? 12.0 : 16.0;
          final mapLeft = sidePadding + panelWidth + 12.0;
          final showTripMetaInMap = (maxW - mapLeft) > 260;
          final islandsEstimatedHeight = (maxW < 520) ? 140.0 : 78.0;
          final panelTop = overlayTop + islandsEstimatedHeight + 12.0;

          return Stack(
            children: [
              // Map background – direct child (no nested Stack) for proper
              // platform-view compositing on Flutter web.
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: _suspendMapTap,
                  child:
                      kIsWeb
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
                                    ? (lat, lon) async {
                                      if (_tripRange == null) {
                                        if (!mounted) return;
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              'Select a trip date range first',
                                            ),
                                          ),
                                        );
                                        return;
                                      }

                                      String name = 'Dropped Pin';
                                      try {
                                        final resolved = await reverseNominatim(
                                          lat,
                                          lon,
                                        );
                                        if (resolved != null &&
                                            resolved.trim().isNotEmpty) {
                                          name = resolved;
                                        }
                                      } catch (_) {}

                                      await _addWaypointWithPrompt(
                                        name,
                                        lat,
                                        lon,
                                      );
                                    }
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
                            routeVia: _routeVia,
                            segmentRoutingTypes: _segmentRoutingTypes,
                            onRouteInstructions: (lines) {
                              if (!mounted) return;
                              setState(() => _routeInstructions = lines);
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
                            onMapTap:
                                (!_adjustRoute)
                                    ? (lat, lon) async {
                                      if (_tripRange == null) {
                                        if (!mounted) return;
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              'Select a trip date range first',
                                            ),
                                          ),
                                        );
                                        return;
                                      }

                                      String name = 'Dropped Pin';
                                      try {
                                        final resolved = await reverseNominatim(
                                          lat,
                                          lon,
                                        );
                                        if (resolved != null &&
                                            resolved.trim().isNotEmpty) {
                                          name = resolved;
                                        }
                                      } catch (_) {}

                                      await _addWaypointWithPrompt(
                                        name,
                                        lat,
                                        lon,
                                      );
                                    }
                                    : null,
                            onRouteTapAddVia:
                                (_adjustRoute)
                                    ? (afterIndex, lat, lon) => _onRouteTapped(
                                      afterIndex: afterIndex,
                                      lat: lat,
                                      lon: lon,
                                    )
                                    : null,
                            onViaDragEnd:
                                (_adjustRoute)
                                    ? (viaIndex, lat, lon) => _moveViaPoint(
                                      viaIndex: viaIndex,
                                      lat: lat,
                                      lon: lon,
                                    )
                                    : null,
                            onViaTapDelete:
                                (_adjustRoute)
                                    ? (viaIndex) =>
                                        _deleteViaPoint(viaIndex: viaIndex)
                                    : null,
                          ),
                ),
              ),

              // Transparent barrier – blocks map taps when a dialog / popup is open
              if (kIsWeb && _suspendMapTap)
                Positioned.fill(
                  child: WebInterceptor(child: const SizedBox.expand()),
                ),

              Positioned(
                left: sidePadding,
                top: math.max(topPadding, panelTop),
                bottom: topPadding,
                width: panelWidth,
                child: tripInfoPanel(),
              ),

              // Island #1: Trip details (top-left)
              Positioned(
                left: sidePadding,
                top: overlayTop,
                child: tripDetailsIsland(maxWidth: maxW - 2 * sidePadding),
              ),

              // Island #2: Search (top-center)
              Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: EdgeInsets.only(top: overlayTop),
                  child: searchIsland(maxWidth: maxW - 2 * sidePadding),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
