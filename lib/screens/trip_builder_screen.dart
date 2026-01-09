import 'dart:math' as math;
import 'dart:convert';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:trypr/widgets/top_taskbar.dart';
import 'package:trypr/widgets/map_embed.dart';
import 'package:trypr/services/geocode.dart';
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
  final TextEditingController _searchCtrl = TextEditingController();

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

  String _ymd(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }

  DateTime _stripTime(DateTime d) => DateTime(d.year, d.month, d.day);

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
    _searchCtrl.dispose();
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

    Widget tripInfoPanel({required bool collapsible, required bool isMobile}) {
      final content = Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!collapsible)
              const Text(
                'Trip Information',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
            if (!collapsible) const SizedBox(height: 8),
            TextField(
              controller: _tripNameCtrl,
              decoration: const InputDecoration(labelText: 'Trip Name'),
            ),
            const SizedBox(height: 8),
            InputDecorator(
              decoration: const InputDecoration(labelText: 'Trip date range'),
              child: InkWell(
                onTap: () async {
                  final now = _stripTime(DateTime.now());
                  final initial =
                      _tripRange ??
                      DateTimeRange(
                        start: now,
                        end: now.add(const Duration(days: 6)),
                      );
                  final picked = await _withMapTapSuspended(
                    () => showDateRangePicker(
                      context: context,
                      firstDate: DateTime(now.year - 5),
                      lastDate: DateTime(now.year + 5),
                      initialDateRange: initial,
                    ),
                  );
                  if (picked != null && mounted) {
                    final r = DateTimeRange(
                      start: _stripTime(picked.start),
                      end: _stripTime(picked.end),
                    );
                    setState(() => _tripRange = r);
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12.0),
                  child: Text(
                    _tripRange == null
                        ? 'Select start and end dates'
                        : '${_ymd(_tripRange!.start)} → ${_ymd(_tripRange!.end)} ($_totalTripDays days)',
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('Transportation:'),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButton<String>(
                    value:
                        ({
                              'driving',
                              'biking',
                              'bikepacking',
                              'backpacking',
                              'walking',
                              'transit',
                            }.contains(_transportMode))
                            ? _transportMode
                            : 'driving',
                    isExpanded: true,
                    items: [
                      DropdownMenuItem(
                        value: 'driving',
                        child:
                            kIsWeb
                                ? PointerInterceptor(
                                  child: const SizedBox(
                                    width: double.infinity,
                                    child: Text('Car'),
                                  ),
                                )
                                : const Text('Car'),
                      ),
                      DropdownMenuItem(
                        value: 'biking',
                        child:
                            kIsWeb
                                ? PointerInterceptor(
                                  child: const SizedBox(
                                    width: double.infinity,
                                    child: Text('Biking'),
                                  ),
                                )
                                : const Text('Biking'),
                      ),
                      DropdownMenuItem(
                        value: 'bikepacking',
                        child:
                            kIsWeb
                                ? PointerInterceptor(
                                  child: const SizedBox(
                                    width: double.infinity,
                                    child: Text('Bikepacking'),
                                  ),
                                )
                                : const Text('Bikepacking'),
                      ),
                      DropdownMenuItem(
                        value: 'backpacking',
                        child:
                            kIsWeb
                                ? PointerInterceptor(
                                  child: const SizedBox(
                                    width: double.infinity,
                                    child: Text('Backpacking'),
                                  ),
                                )
                                : const Text('Backpacking'),
                      ),
                      DropdownMenuItem(
                        value: 'transit',
                        child:
                            kIsWeb
                                ? PointerInterceptor(
                                  child: const SizedBox(
                                    width: double.infinity,
                                    child: Text('Public transport'),
                                  ),
                                )
                                : const Text('Public transport'),
                      ),
                      DropdownMenuItem(
                        value: 'walking',
                        child:
                            kIsWeb
                                ? PointerInterceptor(
                                  child: const SizedBox(
                                    width: double.infinity,
                                    child: Text('Walking'),
                                  ),
                                )
                                : const Text('Walking'),
                      ),
                    ],
                    onChanged: (v) {
                      if (v == null) return;
                      _setTransportMode(v);
                    },
                  ),
                ),
              ],
            ),
            if (_transportMode == 'transit' && _routeInstructions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Transit (suggested lines):',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    ..._routeInstructions.take(4).map((s) => Text('• $s')),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            if (_tripRange != null)
              Text(
                'Nights assigned: $_assignedNights / $_totalTripDays',
                style: TextStyle(
                  fontSize: 13,
                  color:
                      _hasValidAllocation
                          ? Colors.black54
                          : Colors.red.shade700,
                  fontWeight: FontWeight.w600,
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
            const SizedBox(height: 12),
            Text(
              'Total: ${((_roadDistanceKm ?? _totalKm)).toStringAsFixed(2)} km',
              style: const TextStyle(fontSize: 16),
            ),
            if (_routeDurationMin != null)
              Padding(
                padding: const EdgeInsets.only(top: 6.0),
                child: Text(
                  'Estimated drive time: ${_routeDurationMin!.toStringAsFixed(0)} min',
                  style: const TextStyle(fontSize: 13, color: Colors.black54),
                ),
              ),
            const SizedBox(height: 12),
            const Text(
              'Segments (kms between):',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            if (_waypoints.isEmpty)
              const Text(
                'No points yet. Use the search in the main pane to add locations.',
              )
            else
              SizedBox(
                height: isMobile ? 220 : 260,
                child: ListView.builder(
                  itemCount: _waypoints.length,
                  itemBuilder: (ctx, i) {
                    if (_segmentRoutingTypes.length !=
                        math.max(0, _waypoints.length - 1)) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) _ensureSegmentRoutingTypesLength();
                      });
                    }

                    final next =
                        i + 1 < _waypoints.length ? _waypoints[i + 1] : null;
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
                    int offsetDays = 0;
                    for (var j = 0; j < i; j++) {
                      offsetDays += _waypoints[j].nights;
                    }
                    String dateStr = '';
                    if (_tripRange != null) {
                      final start = _tripRange!.start.add(
                        Duration(days: offsetDays),
                      );
                      final end = start.add(
                        Duration(days: math.max(0, nights - 1)),
                      );
                      dateStr = ' — ${_ymd(start)} → ${_ymd(end)}';
                    }

                    final maxNightsForRow =
                        _tripRange == null
                            ? 30
                            : math.max(
                              1,
                              _totalTripDays - (_assignedNights - nights),
                            );

                    final isSegmentRow = next != null;
                    final segType =
                        (isSegmentRow && i < _segmentRoutingTypes.length)
                            ? _segmentRoutingTypes[i]
                            : 'calculated';
                    return ListTile(
                      dense: true,
                      leading: CircleAvatar(child: Text('${i + 1}')),
                      title: Text(_waypoints[i].name),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '$nights night${nights == 1 ? '' : 's'}$dateStr — ${next != null ? '${segKm.toStringAsFixed(2)} km to next' : 'Last point'}',
                          ),
                          if (isSegmentRow)
                            Padding(
                              padding: const EdgeInsets.only(top: 6.0),
                              child: Row(
                                children: [
                                  const Text(
                                    'Routing:',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: DropdownButton<String>(
                                      value:
                                          ({'calculated', 'direct'}.contains(
                                                segType.trim().toLowerCase(),
                                              ))
                                              ? segType
                                              : 'calculated',
                                      isExpanded: true,
                                      items: [
                                        DropdownMenuItem(
                                          value: 'calculated',
                                          child:
                                              kIsWeb
                                                  ? PointerInterceptor(
                                                    child: const SizedBox(
                                                      width: double.infinity,
                                                      child: Text('Calculated'),
                                                    ),
                                                  )
                                                  : const Text('Calculated'),
                                        ),
                                        DropdownMenuItem(
                                          value: 'direct',
                                          child:
                                              kIsWeb
                                                  ? PointerInterceptor(
                                                    child: const SizedBox(
                                                      width: double.infinity,
                                                      child: Text('Direct'),
                                                    ),
                                                  )
                                                  : const Text('Direct'),
                                        ),
                                      ],
                                      onChanged: (v) {
                                        if (v == null) return;
                                        setState(() {
                                          if (i >= 0 &&
                                              i < _segmentRoutingTypes.length) {
                                            _segmentRoutingTypes[i] = v;
                                          }
                                        });
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 110,
                            child: OutlinedButton(
                              onPressed: () async {
                                final v = await _promptNights(
                                  locationName: _waypoints[i].name,
                                  max: maxNightsForRow,
                                  initialValue: nights,
                                );
                                if (v == null) return;
                                if (!mounted) return;
                                setState(() => _waypoints[i].nights = v);
                              },
                              child: Text(
                                '$nights night${nights == 1 ? '' : 's'}',
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _removeWaypoint(i),
                          ),
                        ],
                      ),
                    );
                  },
                ),
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

      if (!collapsible) {
        return Container(
          width: 340,
          decoration: BoxDecoration(
            color: Colors.grey.shade50,
            border: Border(right: BorderSide(color: Colors.grey.shade200)),
          ),
          child: content,
        );
      }

      return ExpansionTile(
        initiallyExpanded: false,
        title: const Text(
          'Trip Information',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        children: [content],
      );
    }

    Widget searchToolbar() {
      return LayoutBuilder(
        builder: (ctx, box) {
          final narrow = box.maxWidth < 520;
          if (!narrow) {
            return Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Search locations',
                    ),
                    onChanged: (v) {
                      _searchDebounce?.cancel();
                      _searchDebounce = Timer(
                        const Duration(milliseconds: 400),
                        () async {
                          final q = _searchCtrl.text.trim();
                          if (q.isEmpty) {
                            setState(() => _searchResults = []);
                            return;
                          }
                          final results = await searchNominatim(q);
                          setState(() => _searchResults = results);
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
                      List<Map<String, dynamic>> results =
                          await searchNominatim(v);
                      if (results.isEmpty) {
                        final match = _sampleLookup.keys.firstWhere(
                          (k) => k.toLowerCase().contains(v.toLowerCase()),
                          orElse: () => '',
                        );
                        if (match.isNotEmpty) {
                          _addWaypointFromLookup(match);
                        }
                        return;
                      }
                      final r = results.first;
                      await _addWaypointWithPrompt(
                        (r['name'] ?? v).toString(),
                        (r['lat'] ?? 0.0) as double,
                        (r['lon'] ?? 0.0) as double,
                      );
                    },
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed:
                      _tripRange == null
                          ? null
                          : () {
                            _addWaypointFromLookup(_searchCtrl.text);
                            _searchCtrl.clear();
                          },
                  child: const Text('Add'),
                ),
                const SizedBox(width: 8),
                PopupMenuButton<String>(
                  onOpened: () {
                    if (mounted) setState(() => _suspendMapTap = true);
                  },
                  onCanceled: () {
                    if (mounted) setState(() => _suspendMapTap = false);
                  },
                  onSelected: (v) {
                    if (mounted) setState(() => _suspendMapTap = false);
                    _addWaypointFromLookup(v);
                  },
                  enabled: _tripRange != null,
                  itemBuilder:
                      (_) =>
                          _sampleLookup.keys
                              .map(
                                (k) => PopupMenuItem(value: k, child: Text(k)),
                              )
                              .toList(),
                  child: ElevatedButton(
                    onPressed: null,
                    child: const Text('Add from list'),
                  ),
                ),
              ],
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _searchCtrl,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Search locations',
                ),
                onChanged: (v) {
                  _searchDebounce?.cancel();
                  _searchDebounce = Timer(
                    const Duration(milliseconds: 400),
                    () async {
                      final q = _searchCtrl.text.trim();
                      if (q.isEmpty) {
                        setState(() => _searchResults = []);
                        return;
                      }
                      final results = await searchNominatim(q);
                      setState(() => _searchResults = results);
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
                  List<Map<String, dynamic>> results = await searchNominatim(v);
                  if (results.isEmpty) {
                    final match = _sampleLookup.keys.firstWhere(
                      (k) => k.toLowerCase().contains(v.toLowerCase()),
                      orElse: () => '',
                    );
                    if (match.isNotEmpty) {
                      _addWaypointFromLookup(match);
                    }
                    return;
                  }
                  final r = results.first;
                  await _addWaypointWithPrompt(
                    (r['name'] ?? v).toString(),
                    (r['lat'] ?? 0.0) as double,
                    (r['lon'] ?? 0.0) as double,
                  );
                },
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ElevatedButton(
                    onPressed:
                        _tripRange == null
                            ? null
                            : () {
                              _addWaypointFromLookup(_searchCtrl.text);
                              _searchCtrl.clear();
                            },
                    child: const Text('Add'),
                  ),
                  PopupMenuButton<String>(
                    onOpened: () {
                      if (mounted) setState(() => _suspendMapTap = true);
                    },
                    onCanceled: () {
                      if (mounted) setState(() => _suspendMapTap = false);
                    },
                    onSelected: (v) {
                      if (mounted) setState(() => _suspendMapTap = false);
                      _addWaypointFromLookup(v);
                    },
                    enabled: _tripRange != null,
                    itemBuilder:
                        (_) =>
                            _sampleLookup.keys
                                .map(
                                  (k) => PopupMenuItem(
                                    value: k,
                                    child:
                                        kIsWeb
                                            ? PointerInterceptor(
                                              child: SizedBox(
                                                width: double.infinity,
                                                child: Text(k),
                                              ),
                                            )
                                            : Text(k),
                                  ),
                                )
                                .toList(),
                    child: ElevatedButton(
                      onPressed: null,
                      child: const Text('Add from list'),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      );
    }

    Widget mainPane() {
      return Column(
        children: [
          Padding(padding: const EdgeInsets.all(12.0), child: searchToolbar()),

          if (_waypoints.length >= 2)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12.0),
              child: Row(
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
                      'Adjust route line (tap route to add a via point)',
                    ),
                  ),
                ],
              ),
            ),

          _searchResults.isEmpty
              ? const SizedBox.shrink()
              : Container(
                height: 160,
                margin: const EdgeInsets.symmetric(horizontal: 12.0),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  itemCount: _searchResults.length,
                  itemBuilder: (ctx, i) {
                    final r = _searchResults[i];
                    return ListTile(
                      title: Text(
                        r['name'] ?? r['display_name'] ?? 'Result ${i + 1}',
                      ),
                      subtitle: Text('${r['lat'] ?? '-'}, ${r['lon'] ?? '-'}'),
                      trailing: TextButton(
                        onPressed:
                            _tripRange == null
                                ? null
                                : () async {
                                  await _addWaypointWithPrompt(
                                    (r['name'] ?? 'Point').toString(),
                                    (r['lat'] ?? 0.0) as double,
                                    (r['lon'] ?? 0.0) as double,
                                  );
                                },
                        child: const Text('Add'),
                      ),
                    );
                  },
                ),
              ),

          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: IgnorePointer(
                  ignoring: _suspendMapTap,
                  child: Stack(
                    children: [
                      MapEmbed(
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
                                    ScaffoldMessenger.of(context).showSnackBar(
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

                                  await _addWaypointWithPrompt(name, lat, lon);
                                }
                                : null,
                        onRouteTapAddVia:
                            (_adjustRoute)
                                ? (afterIndex, lat, lon) => _upsertViaPoint(
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
                      if (kIsWeb && _suspendMapTap)
                        Positioned.fill(
                          child: PointerInterceptor(
                            child: const SizedBox.expand(),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    return Scaffold(
      appBar: const TopTaskbar(dockProgress: 1.0),
      body: LayoutBuilder(
        builder: (ctx, box) {
          final isMobile = box.maxWidth < 900;
          if (isMobile) {
            return Column(
              children: [
                tripInfoPanel(collapsible: true, isMobile: true),
                Expanded(child: mainPane()),
              ],
            );
          }

          return Row(
            children: [
              tripInfoPanel(collapsible: false, isMobile: false),
              Expanded(child: mainPane()),
            ],
          );
        },
      ),
    );
  }
}
