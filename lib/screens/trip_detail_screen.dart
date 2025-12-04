import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:trypr/widgets/map_embed.dart';
import 'package:trypr/screens/destination_detail_screen.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
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
  final Map<String, String> _nameCache = {};
  String? _currentSubscribedPath;

  User? get _user => FirebaseAuth.instance.currentUser;

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

    // If we have a remote tripRef, listen for live updates and merge them
    // into `_liveData` so the UI updates when the owner edits the trip.
    try {
      final tripRefPath =
          (_liveData['tripRef'] ?? widget.data['tripRef']) as String?;
      if (tripRefPath != null && tripRefPath.isNotEmpty) {
        final docRef =
            FirebaseFirestore.instance.doc(tripRefPath);
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
              final ownerRef =
                  FirebaseFirestore.instance.doc(newRef);
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

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Share trip with friends'),
          content: SizedBox(
            width: 520,
            child: StatefulBuilder(
              builder: (ctx2, setState2) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (friends.isEmpty) const Text('No friends to share with'),
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
                  ],
                );
              },
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
                      // ignore: avoid_print
                      print(
                        'Invite write to $uid failed, attempting copy: $e\n$st',
                      );
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
                            'ownerUid': ownerUid.isNotEmpty ? ownerUid : me.uid,
                            'ownerName': me.displayName ?? '',
                            'tripRef': tripRef.path,
                            'tripName':
                                _liveData['name'] ?? widget.data['name'] ?? '',
                            'createdAt': FieldValue.serverTimestamp(),
                          });
                        } catch (_) {}
                      } catch (e2, st2) {
                        failed.add(uid);
                        // ignore: avoid_print
                        print('Copy to $uid failed: $e2\n$st2');
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
                    // ignore: avoid_print
                    print(
                      'Share completed with failures for uids: ${failed.join(', ')}',
                    );
                  }
                } catch (e, st) {
                  // ignore: avoid_print
                  print('Share failed: $e\n$st');
                  if (mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text('Share failed: $e')));
                  }
                }
              },
              child: const Text('Share'),
            ),
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    _debounce?.cancel();
    _docSub?.cancel();
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

    Future<void> ensureNames(List<String> uids) async {
      final missing = uids.where((u) => !nameCache.containsKey(u)).toList();
      for (final uid in missing) {
        try {
          final doc =
              await FirebaseFirestore.instance
                  .collection('users')
                  .doc(uid)
                  .get();
          final data = doc.data() ?? {};
          final name =
              (data['displayName'] ?? data['name'] ?? data['email'] ?? uid)
                  .toString();
          nameCache[uid] = name;
        } catch (_) {
          nameCache[uid] = uid;
        }
      }
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        String scopeView = 'group'; // 'group' or 'private'
        final addCtl = TextEditingController();
        String addScope = 'group';
        String? addAssignee;
        final participants = collectParticipants();
        ensureNames(participants);

        return StatefulBuilder(
          builder: (ctx2, setState2) {
            return AlertDialog(
              title: const Text('Packing list'),
              content: SizedBox(
                width: 520,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
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
                      child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
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
                                if (scopeView == 'group') return pTo == null;
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
                              final checkedBy = List<String>.from(
                                data['checkedBy'] ?? [],
                              );
                              final checked = checkedBy.contains(me.uid);
                              final assignee =
                                  (data['assigneeUid'] ?? '').toString();
                              final privateTo = data['privateTo'] as String?;
                              final canEdit =
                                  (scopeView == 'group') ||
                                  (privateTo == me.uid);
                              final assigneeName =
                                  assignee.isNotEmpty
                                      ? (nameCache[assignee] ?? assignee)
                                      : '';
                              if (assignee.isNotEmpty &&
                                  !nameCache.containsKey(assignee)) {
                                // fire-and-forget load
                                FirebaseFirestore.instance
                                    .collection('users')
                                    .doc(assignee)
                                    .get()
                                    .then((doc) {
                                      final ddata = doc.data() ?? {};
                                      final n =
                                          (ddata['displayName'] ??
                                                  ddata['name'] ??
                                                  ddata['email'] ??
                                                  assignee)
                                              .toString();
                                      if (mounted) {
                                        setState(() => nameCache[assignee] = n);
                                      }
                                    })
                                    .catchError((_) {});
                              }

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
                                    if (assigneeName.isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          left: 8.0,
                                        ),
                                        child: Chip(label: Text(assigneeName)),
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
                                                final chosen = await showDialog<
                                                  String?
                                                >(
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
                                                                  value: sel,
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
                                                                    ...participants
                                                                        .map(
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
                                                                        )
                                                                        ,
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
                                                                  ).pop(null),
                                                          child: const Text(
                                                            'Cancel',
                                                          ),
                                                        ),
                                                        TextButton(
                                                          onPressed:
                                                              () =>
                                                                  Navigator.of(
                                                                    ctx3,
                                                                  ).pop(sel),
                                                          child: const Text(
                                                            'Save',
                                                          ),
                                                        ),
                                                      ],
                                                    );
                                                  },
                                                );
                                                if (chosen != null) {
                                                  await d.reference.update({
                                                    'assigneeUid': chosen,
                                                  });
                                                  if (mounted) setState2(() {});
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
                        DropdownButton<String>(
                          value: addScope,
                          items: const [
                            DropdownMenuItem(
                              value: 'group',
                              child: Text('Group'),
                            ),
                            DropdownMenuItem(
                              value: 'private',
                              child: Text('Private'),
                            ),
                          ],
                          onChanged:
                              (v) => setState2(() => addScope = v ?? 'group'),
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
                            ...participants
                                .map(
                                  (u) => DropdownMenuItem<String?>(
                                    value: u,
                                    child: Text(nameCache[u] ?? u),
                                  ),
                                )
                                ,
                          ],
                          onChanged: (v) => setState2(() => addAssignee = v),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: () async {
                            final t = addCtl.text.trim();
                            if (t.isEmpty) return;
                            final data = <String, dynamic>{
                              'name': t,
                              'createdAt': FieldValue.serverTimestamp(),
                              'checkedBy': [],
                            };
                            if (addScope == 'private') {
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
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final msgCtl = TextEditingController();
        return AlertDialog(
          title: const Text('Trip chat'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Expanded(
                  child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream:
                        tripRef
                            .collection('messages')
                            .orderBy('createdAt')
                            .snapshots(),
                    builder: (ctx2, snap) {
                      if (!snap.hasData) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      final docs = snap.data!.docs;
                      if (docs.isEmpty) {
                        return const Center(child: Text('No messages yet'));
                      }
                      return ListView.builder(
                        itemCount: docs.length,
                        itemBuilder: (ctx3, i) {
                          final d = docs[i];
                          final data = d.data();
                          final senderUid =
                              (data['senderUid'] ?? '').toString();
                          final text = (data['text'] ?? '').toString();
                          // Prefer explicit senderName written on messages (faster),
                          // otherwise fall back to cache or async lookup of the user doc.
                          String display =
                              senderUid == me.uid ? 'You' : senderUid;
                          final explicit =
                              (data['senderName'] ?? '').toString();
                          if (explicit.isNotEmpty) {
                            display = explicit;
                          } else if (senderUid != me.uid) {
                            final cached = _nameCache[senderUid];
                            if (cached != null) {
                              display = cached;
                            } else {
                              // fire-and-forget fetch displayName
                              FirebaseFirestore.instance
                                  .collection('users')
                                  .doc(senderUid)
                                  .get()
                                  .then((doc) {
                                    final ddata = doc.data() ?? {};
                                    final name =
                                        (ddata['displayName'] ??
                                                ddata['name'] ??
                                                ddata['email'] ??
                                                senderUid)
                                            .toString();
                                    if (mounted) {
                                      setState(
                                        () => _nameCache[senderUid] = name,
                                      );
                                    }
                                  })
                                  .catchError((_) {});
                            }
                          }
                          return ListTile(
                            title: Text(display),
                            subtitle: text.isNotEmpty ? Text(text) : null,
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
                        controller: msgCtl,
                        decoration: const InputDecoration(hintText: 'Message'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: () async {
                        final t = msgCtl.text.trim();
                        if (t.isEmpty) return;
                        try {
                          // Debug: log the target path so we can confirm where messages are written
                          if (kDebugMode) {
                            print('Trip chat send -> target: ${tripRef.path}');
                          }
                          await tripRef.collection('messages').add({
                            'senderUid': me.uid,
                            'senderName': me.displayName ?? '',
                            'text': t,
                            'createdAt': FieldValue.serverTimestamp(),
                          });
                          msgCtl.clear();
                        } catch (e) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Send failed: $e')),
                            );
                          }
                        }
                      },
                      child: const Text('Send'),
                    ),
                  ],
                ),
              ],
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
    Map<String, dynamic> destination,
  ) async {
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
            ),
      ),
    );

    // Refresh waypoints if destination was updated
    if (result != null && mounted) {
      setState(() {
        if (index >= 0 && index < _waypoints.length) {
          _waypoints[index] = result;
          // Keep live data in sync so preview chips update immediately
          _liveData['waypoints'] = _waypoints.map((e) => Map<String, dynamic>.from(e)).toList();
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

    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx2, setStateDialog) {
            return AlertDialog(
              title: const Text('Edit waypoint'),
              content: SizedBox(
                width: 560,
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
                            final display = (p['display_name'] ?? '') as String;
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
            SizedBox(
              height: 360,
              // Use MapEmbed (OSRM route request) so saved trips show road-following
              // routes the same way they were built. When editing, allow tapping
              // the map to add a waypoint via `onMapTap`.
              child: MapEmbed(
                points:
                    waypoints.map((w) {
                      return {
                        'lat': (w['lat'] ?? w['latitude'] ?? 0.0),
                        'lon': (w['lon'] ?? w['longitude'] ?? w['lng'] ?? 0.0),
                        'name': w['name'] ?? '',
                      };
                    }).toList(),
                onMapTap:
                    _editing
                        ? (lat, lon) => _addWaypointFromTap(lat, lon)
                        : null,
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
                                        '${(wp['itinerary'] as List?)?.length ?? 0} days',
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
