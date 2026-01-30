import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:trypr/widgets/map_embed.dart';
import 'package:trypr/screens/destination_detail_screen.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:trypr/widgets/trip_chat_dialog_clean.dart';
import 'package:trypr/widgets/trip_expenses_dialog.dart';
import 'package:trypr/services/name_lookup.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:ui' show ImageFilter;

class TripDetailScreen extends StatefulWidget {
  final String docId;
  final Map<String, dynamic> data;
  const TripDetailScreen({super.key, required this.docId, required this.data});

  @override
  State<TripDetailScreen> createState() => _TripDetailScreenState();
}

class _TripDetailScreenState extends State<TripDetailScreen> {
  int _days = 1;
  bool _saving = false;
  bool _editing = false;
  late List<Map<String, dynamic>> _waypoints;
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _placeSuggestions = [];
  Timer? _debounce;
  bool _searchingPlaces = false;
  Map<String, dynamic> _liveData = {};
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _docSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _localDocSub;
  String? _currentSubscribedPath;

  String _transportMode = 'driving';
  List<Map<String, dynamic>> _routeVia = const [];
  List<String> _routeInstructions = const [];

  List<String> _segmentRoutingTypes = const [];
  Map<String, dynamic>? _transitArrivalStop;

  bool _suspendMapTap = false;

  User? get _user => FirebaseAuth.instance.currentUser;

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
    return m == 'bikepacking' || m == 'backpacking';
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
        name.contains('t-shirt'))
      return '👕';
    if (name.contains('pants') ||
        name.contains('jeans') ||
        name.contains('short'))
      return '👖';
    if (name.contains('dress')) return '👗';
    if (name.contains('swim') || name.contains('bikini')) return '👙';
    if (name.contains('tooth')) return '🪥';
    if (name.contains('soap') || name.contains('shampoo')) return '🧴';
    if (name.contains('sunscreen') || name.contains('sun screen')) return '🧴';
    if (name.contains('phone') ||
        name.contains('charger') ||
        name.contains('cable'))
      return '🔌';
    if (name.contains('camera')) return '📷';
    if (name.contains('passport')) return '🛂';
    if (name.contains('ticket') || name.contains('boarding')) return '🎫';
    if (name.contains('water') || name.contains('bottle')) return '💧';
    if (name.contains('snack') || name.contains('food')) return '🥪';
    if (name.contains('med') ||
        name.contains('pill') ||
        name.contains('first aid'))
      return '💊';
    if (name.contains('laptop') || name.contains('tablet')) return '💻';
    if (name.contains('map')) return '🗺️';
    if (name.contains('tent')) return '⛺';
    if (name.contains('sleeping bag')) return '🛌';
    return '🎒';
  }

  List<String> _coerceSegmentRoutingTypes(List<dynamic> raw) {
    return raw
        .map((e) => e.toString().trim().toLowerCase())
        .map((v) => v == 'direct' ? 'direct' : 'calculated')
        .toList();
  }

  @override
  void initState() {
    super.initState();
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

    _transportMode =
        ((_liveData['transportMode'] ?? 'driving') as Object?)
            .toString()
            .trim()
            .toLowerCase();
    final viaAny = _liveData['routeVia'];
    final viaRaw = (viaAny is List) ? viaAny : const <dynamic>[];
    _routeVia =
        viaRaw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e.cast<String, dynamic>()))
            .toList();

    final segAny = _liveData['segmentRoutingTypes'];
    final segRaw = (segAny is List) ? segAny : const <dynamic>[];
    _segmentRoutingTypes = _coerceSegmentRoutingTypes(segRaw);
    final arrivalRaw = _liveData['transitArrivalStop'];
    if (arrivalRaw is Map) {
      _transitArrivalStop = Map<String, dynamic>.from(
        arrivalRaw.cast<String, dynamic>(),
      );
    }

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
        _docSub = docRef.snapshots().listen((snapshot) {
          if (!snapshot.exists) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
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
                    return Map<String, dynamic>.from(e.cast<String, dynamic>());
                  }
                  return <String, dynamic>{};
                }).toList();
            // update days if present
            final td = _liveData['totalDays'];
            if (td is num) _days = td.toInt();

            _transportMode =
                ((_liveData['transportMode'] ?? 'driving') as Object?)
                    .toString()
                    .trim()
                    .toLowerCase();
            final viaAny = _liveData['routeVia'];
            final viaRaw = (viaAny is List) ? viaAny : const <dynamic>[];
            _routeVia =
                viaRaw
                    .whereType<Map>()
                    .map(
                      (e) =>
                          Map<String, dynamic>.from(e.cast<String, dynamic>()),
                    )
                    .toList();

            final segAny = _liveData['segmentRoutingTypes'];
            final segRaw = (segAny is List) ? segAny : const <dynamic>[];
            _segmentRoutingTypes = _coerceSegmentRoutingTypes(segRaw);
            final arrivalRaw = _liveData['transitArrivalStop'];
            if (arrivalRaw is Map) {
              _transitArrivalStop = Map<String, dynamic>.from(
                arrivalRaw.cast<String, dynamic>(),
              );
            }
          });
        });
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
        _localDocSub = localRef.snapshots().listen((snap) {
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
              _docSub = ownerRef.snapshots().listen((snapshot) {
                if (!snapshot.exists) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
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

                    _transportMode =
                        ((_liveData['transportMode'] ?? 'driving') as Object?)
                            .toString()
                            .trim()
                            .toLowerCase();
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

                    final segAny = _liveData['segmentRoutingTypes'];
                    final segRaw =
                        (segAny is List) ? segAny : const <dynamic>[];
                    _segmentRoutingTypes = _coerceSegmentRoutingTypes(segRaw);
                    final arrivalRaw = _liveData['transitArrivalStop'];
                    if (arrivalRaw is Map) {
                      _transitArrivalStop = Map<String, dynamic>.from(
                        arrivalRaw.cast<String, dynamic>(),
                      );
                    }
                  });
                }
              });
            } catch (_) {}
          } else {
            // Merge local data to reflect user's own metadata quickly
            if (mounted) setState(() => _liveData.addAll(data));
          }
        });
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

  DocumentReference<Map<String, dynamic>> _resolveTripRefForView(User me) {
    final refPath = (_liveData['tripRef'] ?? widget.data['tripRef']) as String?;
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

  Future<void> _copyJoinLinkForTrip(
    DocumentReference<Map<String, dynamic>> tripRef,
  ) async {
    final origin = kIsWeb ? Uri.base.origin : '';
    final join = Uri(
      scheme: origin.isNotEmpty ? Uri.parse(origin).scheme : 'https',
      host: origin.isNotEmpty ? Uri.parse(origin).host : '',
      port:
          origin.isNotEmpty
              ? Uri.parse(origin).hasPort
                  ? Uri.parse(origin).port
                  : null
              : null,
      path: '/',
      queryParameters: {'joinTrip': tripRef.path},
    );

    final link =
        origin.isNotEmpty ? join.toString() : 'joinTrip=${tripRef.path}';
    await Clipboard.setData(ClipboardData(text: link));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Join link copied to clipboard')),
      );
    }
  }

  Future<void> _setTransportMode(String mode) async {
    final me = _user;
    if (me == null) return;

    setState(() {
      _transportMode = mode;
      _routeInstructions = const [];
    });

    final tripRef = _resolveTripRefForView(me);
    final ownerUid = _ownerUidFromTripRefPath(tripRef.path);
    if (ownerUid != me.uid) return;

    try {
      await tripRef.update({
        'transportMode': mode,
        'requires_gear_list': _isAdventureMode(mode),
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to update mode: $e')));
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to update route: $e')));
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update routing type: $e')),
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
      await tripRef.update({'transitArrivalStop': stop});
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to update route: $e')));
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to update route: $e')));
      }
    }
  }

  Future<void> _approveJoinRequest({
    required DocumentReference<Map<String, dynamic>> tripRef,
    required String requesterUid,
    required String requesterName,
  }) async {
    final me = _user;
    if (me == null) return;
    final ownerUid = _ownerUidFromTripRefPath(tripRef.path);
    if (ownerUid != me.uid) return;

    final tripId = tripRef.id;
    final tripName =
        (_liveData['name'] ?? widget.data['name'] ?? '').toString();

    await tripRef.update({
      'sharedWith': FieldValue.arrayUnion([requesterUid]),
    });

    final dest = FirebaseFirestore.instance
        .collection('users')
        .doc(requesterUid)
        .collection('sharedTrips')
        .doc(tripId);
    await dest.set({
      'ownerUid': ownerUid,
      'ownerName': me.displayName ?? me.email ?? me.uid,
      'tripRef': tripRef.path,
      'tripName': tripName,
      'createdAt': FieldValue.serverTimestamp(),
      'sharedFrom': me.displayName ?? me.email ?? me.uid,
    }, SetOptions(merge: true));
  }

  Future<void> _setJoinRequestStatus({
    required String requestId,
    required String status,
  }) async {
    final me = _user;
    if (me == null) return;
    await FirebaseFirestore.instance
        .collection('tripJoinRequests')
        .doc(requestId)
        .update({
          'status': status,
          'processedAt': FieldValue.serverTimestamp(),
        });
  }

  Future<void> _shareTrip() async {
    final me = _user;
    if (me == null) return;

    // Determine tripRef: if this screen was opened from a shared invite, use that path
    DocumentReference<Map<String, dynamic>> tripRef;
    final refPath = (_liveData['tripRef'] ?? widget.data['tripRef']) as String?;
    if (refPath != null && refPath.isNotEmpty) {
      tripRef = FirebaseFirestore.instance.doc(refPath);
    } else {
      tripRef = FirebaseFirestore.instance
          .collection('users')
          .doc(me.uid)
          .collection('trips')
          .doc(widget.docId);
    }

    // Load friends from my user doc
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
                  builder: (ctx2, setState2) {
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
                                    setState2(() {
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
                        if (_ownerUidFromTripRefPath(tripRef.path) == me.uid)
                          const SizedBox(height: 12),
                        if (_ownerUidFromTripRefPath(tripRef.path) == me.uid)
                          const Divider(height: 1),
                        if (_ownerUidFromTripRefPath(tripRef.path) == me.uid)
                          const SizedBox(height: 12),
                        if (_ownerUidFromTripRefPath(tripRef.path) == me.uid)
                          const Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'Link requests',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                        if (_ownerUidFromTripRefPath(tripRef.path) == me.uid)
                          const SizedBox(height: 8),
                        if (_ownerUidFromTripRefPath(tripRef.path) == me.uid)
                          SizedBox(
                            height: 160,
                            child: StreamBuilder<
                              QuerySnapshot<Map<String, dynamic>>
                            >(
                              stream:
                                  FirebaseFirestore.instance
                                      .collection('tripJoinRequests')
                                      .where('tripRef', isEqualTo: tripRef.path)
                                      .snapshots(),
                              builder: (ctxReq, snapReq) {
                                if (snapReq.connectionState ==
                                    ConnectionState.waiting) {
                                  return const Center(
                                    child: Text('Loading requests…'),
                                  );
                                }
                                final docs = snapReq.data?.docs ?? const [];
                                final pending =
                                    docs
                                        .where(
                                          (d) =>
                                              (d.data()['status'] ??
                                                  'pending') ==
                                              'pending',
                                        )
                                        .toList();
                                if (pending.isEmpty) {
                                  return const Center(
                                    child: Text('No pending requests'),
                                  );
                                }
                                return ListView.separated(
                                  itemCount: pending.length,
                                  separatorBuilder:
                                      (_, __) => const Divider(height: 1),
                                  itemBuilder: (ctxRow, idx) {
                                    final doc = pending[idx];
                                    final data = doc.data();
                                    final requesterUid =
                                        (data['requesterUid'] ?? '').toString();
                                    final requesterName =
                                        (data['requesterName'] ??
                                                data['requesterEmail'] ??
                                                requesterUid)
                                            .toString();
                                    return ListTile(
                                      dense: true,
                                      title: Text(requesterName),
                                      subtitle: Text(requesterUid),
                                      trailing: Wrap(
                                        spacing: 8,
                                        children: [
                                          TextButton(
                                            onPressed: () async {
                                              try {
                                                await _approveJoinRequest(
                                                  tripRef: tripRef,
                                                  requesterUid: requesterUid,
                                                  requesterName: requesterName,
                                                );
                                                await _setJoinRequestStatus(
                                                  requestId: doc.id,
                                                  status: 'approved',
                                                );
                                                if (mounted) {
                                                  ScaffoldMessenger.of(
                                                    context,
                                                  ).showSnackBar(
                                                    const SnackBar(
                                                      content: Text(
                                                        'Request approved',
                                                      ),
                                                    ),
                                                  );
                                                }
                                              } catch (e) {
                                                if (mounted) {
                                                  ScaffoldMessenger.of(
                                                    context,
                                                  ).showSnackBar(
                                                    SnackBar(
                                                      content: Text(
                                                        'Approve failed: $e',
                                                      ),
                                                    ),
                                                  );
                                                }
                                              }
                                            },
                                            child: const Text('Approve'),
                                          ),
                                          TextButton(
                                            onPressed: () async {
                                              try {
                                                await _setJoinRequestStatus(
                                                  requestId: doc.id,
                                                  status: 'denied',
                                                );
                                              } catch (e) {
                                                if (mounted) {
                                                  ScaffoldMessenger.of(
                                                    context,
                                                  ).showSnackBar(
                                                    SnackBar(
                                                      content: Text(
                                                        'Deny failed: $e',
                                                      ),
                                                    ),
                                                  );
                                                }
                                              }
                                            },
                                            child: const Text('Deny'),
                                          ),
                                        ],
                                      ),
                                    );
                                  },
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
                  await _copyJoinLinkForTrip(tripRef);
                },
                child: const Text('Copy link'),
              ),
              TextButton(
                onPressed: () async {
                  Navigator.of(ctx).pop();
                  if (selected.isEmpty) return;
                  try {
                    // If we are the owner, update sharedWith on the trip doc
                    String ownerUid = '';
                    try {
                      final p = tripRef.path.split('/');
                      if (p.length >= 2 && p[0] == 'users') ownerUid = p[1];
                    } catch (_) {}

                    if (ownerUid == me.uid) {
                      await tripRef.update({
                        'sharedWith': FieldValue.arrayUnion(selected.toList()),
                      });
                    }

                    final List<String> failed = [];
                    for (final uid in selected) {
                      try {
                        final dest = FirebaseFirestore.instance
                            .collection('users')
                            .doc(uid)
                            .collection('sharedTrips')
                            .doc(widget.docId);
                        await dest.set({
                          'ownerUid': ownerUid.isNotEmpty ? ownerUid : me.uid,
                          'ownerName': me.displayName ?? '',
                          'tripRef': tripRef.path,
                          'tripName':
                              _liveData['name'] ?? widget.data['name'] ?? '',
                          'createdAt': FieldValue.serverTimestamp(),
                        });
                      } catch (e, st) {
                        // invite write failed — attempt to copy trip into recipient's trips as fallback
                        if (kDebugMode) {
                          // ignore: avoid_print
                          print(
                            'Invite write to $uid failed, attempting copy: $e\n$st',
                          );
                        }
                        try {
                          await FirebaseFirestore.instance
                              .collection('users')
                              .doc(uid)
                              .collection('trips')
                              .add({
                                ...widget.data,
                                'sharedFrom': me.displayName ?? me.uid,
                                'createdAt': FieldValue.serverTimestamp(),
                              });
                          // best-effort: try to still create sharedTrips doc
                          try {
                            final dest = FirebaseFirestore.instance
                                .collection('users')
                                .doc(uid)
                                .collection('sharedTrips')
                                .doc(widget.docId);
                            await dest.set({
                              'ownerUid':
                                  ownerUid.isNotEmpty ? ownerUid : me.uid,
                              'ownerName': me.displayName ?? '',
                              'tripRef': tripRef.path,
                              'tripName':
                                  _liveData['name'] ??
                                  widget.data['name'] ??
                                  '',
                              'createdAt': FieldValue.serverTimestamp(),
                            });
                          } catch (_) {}
                        } catch (e2, st2) {
                          failed.add(uid);
                          if (kDebugMode) {
                            // ignore: avoid_print
                            print('Copy to $uid failed: $e2\n$st2');
                          }
                        }
                      }
                    }

                    if (failed.isEmpty) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Trip shared')),
                        );
                      }
                    } else {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'Share completed with failures: ${failed.join(', ')}',
                            ),
                          ),
                        );
                      }
                      if (kDebugMode) {
                        // ignore: avoid_print
                        print(
                          'Share completed with failures for uids: ${failed.join(', ')}',
                        );
                      }
                    }
                  } catch (e, st) {
                    if (kDebugMode) {
                      // ignore: avoid_print
                      print('Share failed: $e\n$st');
                    }
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Share failed: $e')),
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

  @override
  void dispose() {
    _searchController.dispose();
    _debounce?.cancel();
    _docSub?.cancel();
    _localDocSub?.cancel();
    super.dispose();
  }

  Future<void> _searchPlaces(String query) async {
    setState(() {
      _searchingPlaces = true;
    });
    try {
      final url = Uri.parse(
        'https://nominatim.openstreetmap.org/search',
      ).replace(
        queryParameters: {
          'q': query,
          'format': 'json',
          'limit': '6',
          'addressdetails': '1',
        },
      );
      final resp = await http.get(
        url,
        headers: {'User-Agent': 'trypr-app/1.0 (https://example.com)'},
      );
      if (resp.statusCode == 200) {
        final List<dynamic> list = jsonDecode(resp.body) as List<dynamic>;
        setState(() {
          _placeSuggestions =
              list
                  .map<Map<String, dynamic>>(
                    (e) => Map<String, dynamic>.from(e as Map),
                  )
                  .toList();
        });
      } else {
        setState(() => _placeSuggestions = []);
      }
    } catch (e) {
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
      final targetPath =
          (_liveData['tripRef'] ?? widget.data['tripRef']) as String?;
      if (targetPath != null && targetPath.isNotEmpty) {
        targetRef = FirebaseFirestore.instance.doc(targetPath);
      } else {
        targetRef = FirebaseFirestore.instance
            .collection('users')
            .doc(u.uid)
            .collection('trips')
            .doc(widget.docId);
      }

      await targetRef.update({'totalDays': _days, 'waypoints': _waypoints});
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Saved')));
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Save failed: $e')));
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
    if ((_liveData['tripRef'] ?? widget.data['tripRef']) is String) {
      final refPath =
          (_liveData['tripRef'] ?? widget.data['tripRef']) as String;
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
      final shared =
          (_liveData['sharedWith'] as List<dynamic>?) ??
          (widget.data['sharedWith'] as List<dynamic>?) ??
          [];
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
                                  final privateTo =
                                      data['privateTo'] as String?;
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
    final refPath = (_liveData['tripRef'] ?? widget.data['tripRef']) as String?;
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
    final refPath = (_liveData['tripRef'] ?? widget.data['tripRef']) as String?;
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

      final shared =
          (_liveData['sharedWith'] as List<dynamic>?) ??
          (widget.data['sharedWith'] as List<dynamic>?) ??
          [];
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
      _waypoints.add({'lat': lat, 'lon': lon, 'name': 'Point $idx'});
    });
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
    String tripRefPath =
        (_liveData['tripRef'] ?? widget.data['tripRef']) as String? ?? '';

    if (tripRefPath.isEmpty) {
      // For personal trips, construct the path from user ID and trip ID
      final user = _user;
      if (user == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Not logged in')));
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
          // Keep live data in sync so preview chips update immediately
          _liveData['waypoints'] =
              _waypoints.map((e) => Map<String, dynamic>.from(e)).toList();
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
      if (q.trim().isEmpty) {
        localSuggestions = [];
        if (mounted) setState(() {});
        return;
      }
      localLoading = true;
      if (mounted) setState(() {});
      try {
        final url = Uri.parse(
          'https://nominatim.openstreetmap.org/search',
        ).replace(
          queryParameters: {
            'q': q,
            'format': 'json',
            'limit': '6',
            'addressdetails': '1',
          },
        );
        final resp = await http.get(
          url,
          headers: {'User-Agent': 'trypr-app/1.0 (https://example.com)'},
        );
        if (resp.statusCode == 200) {
          final List<dynamic> list = jsonDecode(resp.body) as List<dynamic>;
          localSuggestions =
              list
                  .map<Map<String, dynamic>>(
                    (e) => Map<String, dynamic>.from(e as Map),
                  )
                  .toList();
        } else {
          localSuggestions = [];
        }
      } catch (e) {
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
                                    _waypoints[index]['lat'] = lat;
                                    _waypoints[index]['lon'] = lon;
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
    });
  }

  Widget _webSafeMenuItemText(String text) {
    final t = Text(text);
    if (!kIsWeb) return t;
    return PointerInterceptor(
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
    });
    try {
      await tripRef.update({'routeVia': []});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
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
          final isTransit = _transportMode == 'transit';
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
                title: const Text('Segment routing'),
                content: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: SizedBox(
                    width: double.maxFinite,
                    height: dialogHeight,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Calculated follows roads/trails. Direct draws a straight (dashed) line.',
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

                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 10,
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: Column(
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
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: Colors.black54,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Wrap(
                                      spacing: 8,
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
    return PointerInterceptor(child: child);
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
      _waypoints.add({'lat': lat, 'lon': lon, 'name': display});
      _placeSuggestions = [];
      _searchController.clear();
    });
  }

  Widget _buildOmnibox(BuildContext context) {
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

    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: 16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _maybePointerIntercept(
                _glassCard(
                  borderRadius: BorderRadius.circular(999),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
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
        ),
      ),
    );
  }

  IconData _iconForStop(Map<String, dynamic> wp) {
    // Heuristic: show a "hotel" icon if accommodations exist.
    final accs = (wp['accommodations'] as List?)?.length ?? 0;
    if (accs > 0) return Icons.hotel;
    return Icons.location_city;
  }

  Widget _buildStopTile({
    required int index,
    required Map<String, dynamic> wp,
    required bool isLast,
    required VoidCallback? onTap,
    Widget? trailing,
  }) {
    final name = (wp['name'] ?? 'Stop ${index + 1}').toString();
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
                      child: Text(
                        '${index + 1}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Row(
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
            ),
            if (trailing != null) trailing,
          ],
        ),
      ),
    );
  }

  Widget _buildRouteControls({required bool canWriteTrip}) {
    final waypoints = _waypoints;

    final transportRow = Row(
      children: [
        const Icon(Icons.directions, size: 18, color: Colors.black87),
        const SizedBox(width: 8),
        const Text(
          'Mode',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children:
                [
                  {'mode': 'driving', 'label': 'Car', 'emoji': '🚗'},
                  {'mode': 'flying', 'label': 'Flight', 'emoji': '✈️'},
                  {'mode': 'transit', 'label': 'Train', 'emoji': '🚆'},
                  {'mode': 'walking', 'label': 'Walk', 'emoji': '🚶'},
                  {'mode': 'biking', 'label': 'Bike', 'emoji': '🚲'},
                  {'mode': 'bikepacking', 'label': 'Bikepack', 'emoji': '🚵'},
                  {'mode': 'backpacking', 'label': 'Backpack', 'emoji': '🎒'},
                ].map((opt) {
                  final mode = opt['mode'] as String;
                  final selected = _transportMode == mode;
                  return ChoiceChip(
                    label: Text(
                      opt['emoji'] as String,
                      style: const TextStyle(fontSize: 16),
                    ),
                    selected: selected,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    onSelected:
                        (!canWriteTrip)
                            ? null
                            : (v) {
                              if (!v) return;
                              _setTransportMode(mode);
                            },
                  );
                }).toList(),
          ),
        ),
      ],
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
        transportRow,
        if (_isAdventureMode(_transportMode))
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
          '${waypoints.length} stops',
          style: const TextStyle(fontSize: 12, color: Colors.black54),
        ),
        const Spacer(),
        IconButton(
          tooltip: _editing ? 'Done' : 'Edit',
          icon: Icon(_editing ? Icons.check : Icons.edit),
          onPressed: canWriteTrip ? _toggleEditing : null,
        ),
        if (_editing)
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
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Edit stop',
                            icon: const Icon(Icons.tune),
                            onPressed: () => _editWaypointDialog(e.key),
                          ),
                          IconButton(
                            tooltip: 'Remove stop',
                            icon: const Icon(Icons.delete),
                            onPressed: () => _removeWaypoint(e.key),
                          ),
                          ReorderableDragStartListener(
                            index: e.key,
                            child: const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 8.0),
                              child: Icon(Icons.drag_handle),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            )
            : ListView.builder(
              itemCount: waypoints.length,
              itemBuilder: (ctx, i) {
                final wp = waypoints[i];
                return _buildStopTile(
                  index: i,
                  wp: wp,
                  isLast: i == waypoints.length - 1,
                  onTap: () => _openDestinationDetail(i, wp),
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
          initialChildSize: 0.18,
          minChildSize: 0.12,
          maxChildSize: 0.75,
          builder: (ctx, scrollController) {
            final waypoints = _waypoints;
            return _glassCard(
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(18),
                topRight: Radius.circular(18),
              ),
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              child: Column(
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
                        '${waypoints.length} stops',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.black54,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: _editing ? 'Done' : 'Edit',
                        icon: Icon(_editing ? Icons.check : Icons.edit),
                        onPressed: canWriteTrip ? _toggleEditing : null,
                      ),
                      if (_editing)
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
                  Expanded(
                    child:
                        _editing
                            ? ReorderableListView(
                              buildDefaultDragHandles: false,
                              onReorder: (oldIndex, newIndex) {
                                setState(() {
                                  if (newIndex > oldIndex) newIndex -= 1;
                                  final item = _waypoints.removeAt(oldIndex);
                                  _waypoints.insert(newIndex, item);
                                });
                              },
                              children: [
                                for (final e in waypoints.asMap().entries)
                                  Container(
                                    key: ValueKey('sheet-wp-${e.key}'),
                                    margin: const EdgeInsets.symmetric(
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(12),
                                      color: const Color(0x08FFFFFF),
                                    ),
                                    child: _buildStopTile(
                                      index: e.key,
                                      wp: e.value,
                                      isLast: e.key == waypoints.length - 1,
                                      onTap: null,
                                      trailing: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                            tooltip: 'Edit stop',
                                            icon: const Icon(Icons.tune),
                                            onPressed:
                                                () =>
                                                    _editWaypointDialog(e.key),
                                          ),
                                          IconButton(
                                            tooltip: 'Remove stop',
                                            icon: const Icon(Icons.delete),
                                            onPressed:
                                                () => _removeWaypoint(e.key),
                                          ),
                                          ReorderableDragStartListener(
                                            index: e.key,
                                            child: const Padding(
                                              padding: EdgeInsets.symmetric(
                                                horizontal: 8.0,
                                              ),
                                              child: Icon(Icons.drag_handle),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                              ],
                            )
                            : ListView.builder(
                              controller: scrollController,
                              itemCount: waypoints.length,
                              itemBuilder: (ctx2, i) {
                                final wp = waypoints[i];
                                return _buildStopTile(
                                  index: i,
                                  wp: wp,
                                  isLast: i == waypoints.length - 1,
                                  onTap: () => _openDestinationDetail(i, wp),
                                );
                              },
                            ),
                  ),
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
    final bottomOffset = isNarrow ? 130.0 : 24.0;

    final statsText =
        '${waypoints.length} Stops | ${totalKm.toStringAsFixed(0)} km';

    return Positioned(
      right: 24,
      bottom: bottomOffset,
      child: _maybePointerIntercept(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _glassCard(
              borderRadius: BorderRadius.circular(999),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Text(
                statsText,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 12),
            ElevatedButton(
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
            ),
          ],
        ),
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

  Widget _buildTopRightActions(BuildContext context) {
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

  @override
  Widget build(BuildContext context) {
    final data = _liveData;
    final name = data['name'] ?? 'Untitled Trip';
    final waypoints = _waypoints;
    final totalKm = (data['totalKm'] ?? 0) as num;

    final me = _user;
    final tripRefForView = me == null ? null : _resolveTripRefForView(me);
    final canWriteTrip =
        me != null &&
        tripRefForView != null &&
        _ownerUidFromTripRefPath(tripRefForView.path) == me.uid;
    final isNarrow = MediaQuery.sizeOf(context).width < 760;

    return Scaffold(
      body: Stack(
        children: [
          // Full-screen background map.
          Positioned.fill(
            child: IgnorePointer(
              ignoring: _suspendMapTap,
              child: MapEmbed(
                points:
                    waypoints.map((w) {
                      return {
                        'lat': (w['lat'] ?? w['latitude'] ?? 0.0),
                        'lon': (w['lon'] ?? w['longitude'] ?? w['lng'] ?? 0.0),
                        'name': w['name'] ?? '',
                      };
                    }).toList(),
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
                  if (_transportMode == 'transit') {
                    _persistTransitArrivalStop(arrivalStop);
                  }
                },
                secondaryPoints:
                    waypoints.asMap().entries.expand((entry) {
                      final wIndex = entry.key;
                      final w = entry.value;

                      final accs =
                          (w['accommodations'] as List<dynamic>?) ?? [];
                      final itinerary =
                          (w['itinerary'] as List<dynamic>?) ?? [];

                      final accMarkers = accs
                          .asMap()
                          .entries
                          .where(
                            (a) =>
                                (a.value as Map)['lat'] != null &&
                                (a.value as Map)['lon'] != null,
                          )
                          .map(
                            (a) => {
                              'lat': (a.value as Map)['lat'],
                              'lon': (a.value as Map)['lon'],
                              'kind': 'accommodation',
                              'category': 'Accommodation',
                              'waypointIndex': wIndex,
                              'accommodationIndex': a.key,
                            },
                          );

                      final activityMarkers = itinerary.asMap().entries.expand((
                        dayEntry,
                      ) {
                        final dayIndex = dayEntry.key;
                        final day = (dayEntry.value as Map<String, dynamic>);
                        final acts =
                            (day['activities'] as List<dynamic>?) ?? [];
                        return acts
                            .asMap()
                            .entries
                            .where(
                              (a) =>
                                  (a.value as Map)['locationLat'] != null &&
                                  (a.value as Map)['locationLon'] != null,
                            )
                            .map(
                              (a) => {
                                'lat': (a.value as Map)['locationLat'],
                                'lon': (a.value as Map)['locationLon'],
                                'kind': 'activity',
                                'category': (a.value as Map)['category'] ?? '',
                                'waypointIndex': wIndex,
                                'dayIndex': dayIndex,
                                'activityIndex': a.key,
                              },
                            );
                      });

                      return [...accMarkers, ...activityMarkers];
                    }).toList(),
                onMapTap:
                    _editing
                        ? (lat, lon) => _addWaypointFromTap(lat, lon)
                        : null,
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
                        ? (viaIndex, lat, lon) => _moveViaPoint(
                          viaIndex: viaIndex,
                          lat: lat,
                          lon: lon,
                        )
                        : null,
                onViaTapDelete:
                    (!_editing && canWriteTrip)
                        ? (viaIndex) => _deleteViaPoint(viaIndex: viaIndex)
                        : null,
              ),
            ),
          ),
          if (kIsWeb && _suspendMapTap)
            Positioned.fill(
              child: PointerInterceptor(child: const SizedBox.expand()),
            ),

          // Floating UI layer.
          SafeArea(
            child: Stack(
              children: [
                _buildOmnibox(context),
                _buildTopLeftNav(context, name.toString()),
                _buildTopRightActions(context),
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
              ],
            ),
          ),
        ],
      ),
    );
  }
}
