import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:trypr/widgets/map_embed.dart';
import 'package:trypr/screens/destination_detail_screen.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:trypr/widgets/trip_chat_dialog.dart';
import 'package:trypr/widgets/trip_expenses_dialog.dart';
import 'package:trypr/services/name_lookup.dart';
import 'dart:async';
import 'dart:convert';

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
    final w = (_liveData['waypoints'] as List<dynamic>?) ?? [];
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
    final viaRaw = (_liveData['routeVia'] as List<dynamic>?) ?? const [];
    _routeVia =
        viaRaw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e.cast<String, dynamic>()))
            .toList();

    final segRaw =
        (_liveData['segmentRoutingTypes'] as List<dynamic>?) ?? const [];
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
      final tripRefPath =
          (_liveData['tripRef'] ?? widget.data['tripRef']) as String?;
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
            final rw = (_liveData['waypoints'] as List<dynamic>?) ?? [];
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
            final viaRaw =
                (_liveData['routeVia'] as List<dynamic>?) ?? const [];
            _routeVia =
                viaRaw
                    .whereType<Map>()
                    .map(
                      (e) =>
                          Map<String, dynamic>.from(e.cast<String, dynamic>()),
                    )
                    .toList();

            final segRaw =
                (_liveData['segmentRoutingTypes'] as List<dynamic>?) ??
                const [];
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
          final newRef = (data['tripRef'] ?? '') as String;
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
                    final rw = (_liveData['waypoints'] as List<dynamic>?) ?? [];
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
                    final viaRaw =
                        (_liveData['routeVia'] as List<dynamic>?) ?? const [];
                    _routeVia =
                        viaRaw
                            .whereType<Map>()
                            .map(
                              (e) => Map<String, dynamic>.from(
                                e.cast<String, dynamic>(),
                              ),
                            )
                            .toList();

                    final segRaw =
                        (_liveData['segmentRoutingTypes'] as List<dynamic>?) ??
                        const [];
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
    final existingIndex = updated.indexWhere(
      (v) => ((v['afterIndex'] as num?)?.toInt() ?? -1) == afterIndex,
    );
    final next = {'afterIndex': afterIndex, 'lat': lat, 'lon': lon};
    if (existingIndex >= 0) {
      updated[existingIndex] = next;
    } else {
      updated.add(next);
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
                                    if (scopeView == 'group')
                                      return pTo == null;
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

    return Scaffold(
      appBar: AppBar(
        title: Text(name),
        actions: [
          IconButton(
            icon: const Icon(Icons.list),
            tooltip: 'Packing list',
            onPressed: _openPackingList,
          ),
          IconButton(
            icon: const Icon(Icons.pie_chart),
            tooltip: 'Expenses',
            onPressed: _openExpensesDialog,
          ),
          IconButton(
            icon: const Icon(Icons.chat),
            tooltip: 'Open chat',
            onPressed: _openTripChat,
          ),
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: 'Share trip',
            onPressed: _shareTrip,
          ),
          IconButton(
            icon: const Icon(Icons.save),
            tooltip: 'Save changes',
            onPressed: _saving ? null : _saveDays,
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  const Text('Transportation:'),
                  const SizedBox(width: 12),
                  DropdownButton<String>(
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
                  const Spacer(),
                ],
              ),
            ),
            if (waypoints.length > 1)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Segment routing:',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    ...List.generate(waypoints.length - 1, (i) {
                      final fromName = (waypoints[i]['name'] ?? '').toString();
                      final toName =
                          (waypoints[i + 1]['name'] ?? '').toString();

                      final desiredLen = waypoints.length - 1;
                      if (_segmentRoutingTypes.length != desiredLen) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (!mounted) return;
                          final updated = List<String>.from(
                            _segmentRoutingTypes,
                          );
                          if (updated.length > desiredLen) {
                            updated.removeRange(desiredLen, updated.length);
                          }
                          while (updated.length < desiredLen) {
                            updated.add('calculated');
                          }
                          setState(() => _segmentRoutingTypes = updated);
                        });
                      }

                      final segType =
                          (i < _segmentRoutingTypes.length)
                              ? _segmentRoutingTypes[i]
                              : 'calculated';

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6.0),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Leg ${i + 1}: $fromName → $toName',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                            const SizedBox(width: 12),
                            DropdownButton<String>(
                              value:
                                  ({'calculated', 'direct'}.contains(segType))
                                      ? segType
                                      : 'calculated',
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
                              onChanged:
                                  canWriteTrip
                                      ? (v) {
                                        if (v == null) return;
                                        _setSegmentRoutingType(i, v);
                                      }
                                      : null,
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                ),
              ),
            if (_transportMode == 'transit' && _routeInstructions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
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
            SizedBox(
              height: 360,
              // Use MapEmbed (OSRM route request) so saved trips show road-following
              // routes the same way they were built. When editing, allow tapping
              // the map to add a waypoint via `onMapTap`.
              child: Stack(
                children: [
                  IgnorePointer(
                    ignoring: _suspendMapTap,
                    child: MapEmbed(
                      points:
                          waypoints.map((w) {
                            return {
                              'lat': (w['lat'] ?? w['latitude'] ?? 0.0),
                              'lon':
                                  (w['lon'] ??
                                      w['longitude'] ??
                                      w['lng'] ??
                                      0.0),
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

                            final activityMarkers = itinerary
                                .asMap()
                                .entries
                                .expand((dayEntry) {
                                  final dayIndex = dayEntry.key;
                                  final day =
                                      (dayEntry.value as Map<String, dynamic>);
                                  final acts =
                                      (day['activities'] as List<dynamic>?) ??
                                      [];
                                  return acts
                                      .asMap()
                                      .entries
                                      .where(
                                        (a) =>
                                            (a.value as Map)['locationLat'] !=
                                                null &&
                                            (a.value as Map)['locationLon'] !=
                                                null,
                                      )
                                      .map(
                                        (a) => {
                                          'lat':
                                              (a.value as Map)['locationLat'],
                                          'lon':
                                              (a.value as Map)['locationLon'],
                                          'kind': 'activity',
                                          'category':
                                              (a.value as Map)['category'] ??
                                              '',
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
                              ? (viaIndex) =>
                                  _deleteViaPoint(viaIndex: viaIndex)
                              : null,
                    ),
                  ),
                  if (kIsWeb && _suspendMapTap)
                    Positioned.fill(
                      child: PointerInterceptor(child: const SizedBox.expand()),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Text('Days:', style: TextStyle(fontSize: 16)),
                      const SizedBox(width: 12),
                      Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.grey.shade300),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.remove),
                              onPressed:
                                  _days > 1
                                      ? () => setState(() => _days--)
                                      : null,
                            ),
                            SizedBox(
                              width: 40,
                              child: Center(
                                child: Text(
                                  '$_days',
                                  style: const TextStyle(fontSize: 16),
                                ),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.add),
                              onPressed: () => setState(() => _days++),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      ElevatedButton.icon(
                        onPressed: _saving ? null : _saveDays,
                        icon:
                            _saving
                                ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                                : const Icon(Icons.save),
                        label: const Text('Save'),
                      ),
                    ],
                  ),

                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Text('${waypoints.length} stops'),
                      const SizedBox(width: 12),
                      Text('${totalKm.toStringAsFixed(1)} km'),
                    ],
                  ),
                  const SizedBox(height: 12),

                  const Divider(),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Waypoints',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Row(
                        children: [
                          if (_editing)
                            TextButton.icon(
                              onPressed: _saveAll,
                              icon: const Icon(Icons.save),
                              label: const Text('Save'),
                            ),
                          TextButton.icon(
                            onPressed: _toggleEditing,
                            icon: Icon(_editing ? Icons.check : Icons.edit),
                            label: Text(_editing ? 'Done' : 'Edit'),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_editing)
                    SizedBox(
                      height: 220,
                      child: Column(
                        children: [
                          // Search / autocomplete input to help users pick a location
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8.0,
                              vertical: 6.0,
                            ),
                            child: Column(
                              children: [
                                TextField(
                                  controller: _searchController,
                                  decoration: InputDecoration(
                                    prefixIcon: const Icon(Icons.search),
                                    hintText: 'Type a place name or address',
                                    suffix:
                                        _searchingPlaces
                                            ? const SizedBox(
                                              width: 16,
                                              height: 16,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            )
                                            : null,
                                  ),
                                ),
                                if (_placeSuggestions.isNotEmpty)
                                  Container(
                                    constraints: const BoxConstraints(
                                      maxHeight: 160,
                                    ),
                                    margin: const EdgeInsets.only(top: 6),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      border: Border.all(
                                        color: Colors.grey.shade300,
                                      ),
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
                                      itemCount: _placeSuggestions.length,
                                      itemBuilder: (ctx, i) {
                                        final p = _placeSuggestions[i];
                                        final display =
                                            (p['display_name'] ?? '') as String;
                                        return ListTile(
                                          title: Text(
                                            display,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          onTap: () {
                                            // Add waypoint from the selected place; user doesn't need to edit coords
                                            final lat =
                                                double.tryParse(
                                                  (p['lat'] ?? '').toString(),
                                                ) ??
                                                0.0;
                                            final lon =
                                                double.tryParse(
                                                  (p['lon'] ?? '').toString(),
                                                ) ??
                                                0.0;
                                            setState(() {
                                              _waypoints.add({
                                                'lat': lat,
                                                'lon': lon,
                                                'name': display,
                                              });
                                              _placeSuggestions = [];
                                              _searchController.clear();
                                            });
                                          },
                                        );
                                      },
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: ReorderableListView(
                              onReorder: (oldIndex, newIndex) {
                                setState(() {
                                  if (newIndex > oldIndex) newIndex -= 1;
                                  final item = _waypoints.removeAt(oldIndex);
                                  _waypoints.insert(newIndex, item);
                                });
                              },
                              children:
                                  _waypoints.asMap().entries.map((e) {
                                    final idx = e.key;
                                    final wp = e.value;
                                    return ListTile(
                                      key: ValueKey('wp-$idx'),
                                      leading: CircleAvatar(
                                        child: Text('${idx + 1}'),
                                      ),
                                      title: Text(
                                        wp['name'] ?? 'Point ${idx + 1}',
                                      ),
                                      subtitle: Text(
                                        '${wp['lat'] ?? '-'}, ${wp['lon'] ?? '-'}',
                                      ),
                                      trailing: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                            icon: const Icon(Icons.edit),
                                            onPressed:
                                                () => _editWaypointDialog(idx),
                                          ),
                                          IconButton(
                                            icon: const Icon(Icons.delete),
                                            onPressed:
                                                () => _removeWaypoint(idx),
                                          ),
                                        ],
                                      ),
                                    );
                                  }).toList(),
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    ...waypoints.asMap().entries.map((e) {
                      final idx = e.key;
                      final wp = e.value;
                      return GestureDetector(
                        onTap: () => _openDestinationDetail(idx, wp),
                        child: Card(
                          margin: const EdgeInsets.symmetric(vertical: 6),
                          elevation: 2,
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: const Color(0xFF00695C),
                              foregroundColor: Colors.white,
                              child: Text('${idx + 1}'),
                            ),
                            title: Text(
                              wp['name'] ?? 'Point ${idx + 1}',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${wp['lat'] ?? '-'}, ${wp['lon'] ?? '-'}',
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    Chip(
                                      label: Text(
                                        '${(wp['accommodations'] as List?)?.length ?? 0} accommodations',
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                      padding: const EdgeInsets.all(4),
                                    ),
                                    const SizedBox(width: 8),
                                    Chip(
                                      label: Text(
                                        '${_calculateDayCount(wp)} days',
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                      padding: const EdgeInsets.all(4),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            trailing: const Icon(
                              Icons.arrow_forward_ios,
                              size: 16,
                            ),
                          ),
                        ),
                      );
                    }),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
