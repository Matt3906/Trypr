import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:trypr/widgets/top_taskbar.dart';
import 'package:trypr/screens/trip_detail_screen.dart';
import 'package:trypr/screens/sign_in_screen.dart';
import 'package:trypr/widgets/map_embed.dart';

class MyTripsScreen extends StatefulWidget {
  const MyTripsScreen({super.key});

  @override
  State<MyTripsScreen> createState() => _MyTripsScreenState();
}

class _Hoverable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  const _Hoverable({super.key, required this.child, this.onTap});

  @override
  State<_Hoverable> createState() => _HoverableState();
}

class _HoverableState extends State<_Hoverable> {
  bool _hover = false;
  void _onEnter(PointerEvent e) => setState(() => _hover = true);
  void _onExit(PointerEvent e) => setState(() => _hover = false);

  @override
  Widget build(BuildContext context) {
    final scale = _hover ? 1.02 : 1.0;
    final shadow =
        _hover
            ? [
              BoxShadow(
                color: Colors.black.withOpacity(0.12),
                blurRadius: 12,
                offset: const Offset(0, 6),
              ),
            ]
            : [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 6)];
    return MouseRegion(
      onEnter: _onEnter,
      onExit: _onExit,
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          transform: Matrix4.identity()..scale(scale, scale),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            boxShadow: shadow,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

class _MyTripsScreenState extends State<MyTripsScreen> {
  User? get _user => FirebaseAuth.instance.currentUser;

  Stream<QuerySnapshot<Map<String, dynamic>>>? _tripsStream() {
    final u = _user;
    if (u == null) return null;
    return FirebaseFirestore.instance
        .collection('users')
        .doc(u.uid)
        .collection('trips')
        .orderBy('createdAt', descending: true)
        .snapshots();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>>? _sharedStream() {
    final u = _user;
    if (u == null) return null;
    return FirebaseFirestore.instance
        .collection('users')
        .doc(u.uid)
        .collection('sharedTrips')
        .orderBy('createdAt', descending: true)
        .snapshots();
  }

  String _prettyDate(Object ts) {
    try {
      if (ts is Timestamp) {
        final dt = ts.toDate().toLocal();
        return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
      }
      return ts.toString();
    } catch (_) {
      return ts.toString();
    }
  }

  Future<void> _deleteTrip(String docId) async {
    final u = _user;
    if (u == null) return;
    await FirebaseFirestore.instance
        .collection('users')
        .doc(u.uid)
        .collection('trips')
        .doc(docId)
        .delete();
    // force rebuild after delete to ensure UI updates immediately
    if (mounted) setState(() {});
  }

  Future<void> _openSharedTrip(
    DocumentSnapshot<Map<String, dynamic>> sharedDoc,
  ) async {
    final data = sharedDoc.data() ?? {};
    final tripRefPath = (data['tripRef'] ?? '') as String;
    if (tripRefPath.isEmpty) return;
    try {
      final tripDoc = await FirebaseFirestore.instance.doc(tripRefPath).get();
      if (!tripDoc.exists) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Trip not available')));
        }
        return;
      }
      final tripData = Map<String, dynamic>.from(
        tripDoc.data() as Map<String, dynamic>,
      );
      tripData['tripRef'] =
          tripRefPath; // ensure TripDetailScreen can find packing/chat
      if (mounted) {
        final updated = await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => TripDetailScreen(docId: tripDoc.id, data: tripData),
          ),
        );
        if (updated == true && mounted) {
          setState(() {}); // triggers refresh
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Open failed: $e')));
      }
    }
  }

  Future<void> _acceptSharedTrip(
    DocumentSnapshot<Map<String, dynamic>> sharedDoc,
  ) async {
    final u = _user;
    if (u == null) return;
    final data = sharedDoc.data() ?? {};
    final tripRefPath = (data['tripRef'] ?? '') as String;
    if (tripRefPath.isEmpty) return;
    try {
      final tripDoc = await FirebaseFirestore.instance.doc(tripRefPath).get();
      if (!tripDoc.exists) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Original trip not found')),
          );
        }
        return;
      }
      // Instead of copying the trip into the recipient's collection, create
      // a lightweight linked trip that points to the owner's trip document
      // using `tripRef`. This lets the recipient view the owner's live
      // document (packing/chat/waypoints) and see updates in realtime.
      final ownerName = data['ownerName'] ?? data['ownerUid'] ?? '';
      await FirebaseFirestore.instance
          .collection('users')
          .doc(u.uid)
          .collection('trips')
          .add({
            'name':
                data['tripName'] ?? tripDoc.data()?['name'] ?? 'Shared Trip',
            'tripRef': tripRefPath,
            'sharedFrom': ownerName,
            'createdAt': FieldValue.serverTimestamp(),
          });
      await FirebaseFirestore.instance
          .collection('users')
          .doc(u.uid)
          .collection('sharedTrips')
          .doc(sharedDoc.id)
          .delete();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Trip accepted and added to My Trips')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Accept failed: $e')));
      }
    }
  }

  Future<void> _declineSharedTrip(
    DocumentSnapshot<Map<String, dynamic>> sharedDoc,
  ) async {
    final u = _user;
    if (u == null) return;
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(u.uid)
          .collection('sharedTrips')
          .doc(sharedDoc.id)
          .delete();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Shared invite declined')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Decline failed: $e')));
      }
    }
  }

  Future<void> _shareTripFromMyTrips(
    String tripId,
    Map<String, dynamic> tripData,
  ) async {
    final u = _user;
    if (u == null) return;
    final meDoc =
        await FirebaseFirestore.instance.collection('users').doc(u.uid).get();
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
                  final tripRef = FirebaseFirestore.instance
                      .collection('users')
                      .doc(u.uid)
                      .collection('trips')
                      .doc(tripId);
                  await tripRef.update({
                    'sharedWith': FieldValue.arrayUnion(selected.toList()),
                  });
                  for (final uid in selected) {
                    final dest = FirebaseFirestore.instance
                        .collection('users')
                        .doc(uid)
                        .collection('sharedTrips')
                        .doc(tripId);
                    await dest.set({
                      'ownerUid': u.uid,
                      'ownerName': u.displayName ?? u.email ?? u.uid,
                      'tripRef': tripRef.path,
                      'tripName': tripData['name'] ?? '',
                      'createdAt': FieldValue.serverTimestamp(),
                    });
                  }
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Trip shared')),
                    );
                  }
                } catch (e) {
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
  Widget build(BuildContext context) {
    final stream = _tripsStream();
    return Scaffold(
      appBar: const TopTaskbar(dockProgress: 1.0),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child:
            stream == null
                ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Sign in to view your saved trips',
                        style: TextStyle(fontSize: 18),
                      ),
                      const SizedBox(height: 12),
                      ElevatedButton(
                        onPressed:
                            () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const SignInScreen(),
                              ),
                            ),
                        child: const Text('Sign in'),
                      ),
                    ],
                  ),
                )
                : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: stream,
                  builder: (ctx, snap) {
                    if (snap.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final docs = snap.data?.docs ?? [];

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Always render shared invites area (so users with no
                        // personal trips still see incoming shared trips).
                        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                          stream: _sharedStream(),
                          builder: (sctx, ssnap) {
                            if (!ssnap.hasData) return const SizedBox.shrink();
                            final sdocs = ssnap.data!.docs;
                            if (sdocs.isEmpty) return const SizedBox.shrink();
                            return Card(
                              child: Padding(
                                padding: const EdgeInsets.all(12.0),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Shared Trips',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleMedium?.copyWith(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    SizedBox(
                                      height: 140,
                                      child: ListView.separated(
                                        scrollDirection: Axis.horizontal,
                                        itemCount: sdocs.length,
                                        separatorBuilder:
                                            (_, __) => const SizedBox(width: 8),
                                        itemBuilder: (ctx2, si) {
                                          final sd = sdocs[si];
                                          final sdata = sd.data();
                                          final owner =
                                              sdata['ownerName'] ??
                                              sdata['ownerUid'] ??
                                              'Someone';
                                          final title =
                                              sdata['tripName'] ??
                                              'Shared Trip';
                                          return SizedBox(
                                            width: 320,
                                            child: Card(
                                              child: Padding(
                                                padding: const EdgeInsets.all(
                                                  8.0,
                                                ),
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      title,
                                                      style: const TextStyle(
                                                        fontWeight:
                                                            FontWeight.w600,
                                                      ),
                                                    ),
                                                    const SizedBox(height: 6),
                                                    Text(
                                                      'From: ${owner.toString()}',
                                                      style: const TextStyle(
                                                        color: Colors.black54,
                                                        fontSize: 12,
                                                      ),
                                                    ),
                                                    const Spacer(),
                                                    Row(
                                                      children: [
                                                        ElevatedButton(
                                                          onPressed:
                                                              () =>
                                                                  _openSharedTrip(
                                                                    sd,
                                                                  ),
                                                          child: const Text(
                                                            'Open',
                                                          ),
                                                        ),
                                                        const SizedBox(
                                                          width: 8,
                                                        ),
                                                        TextButton(
                                                          onPressed:
                                                              () =>
                                                                  _acceptSharedTrip(
                                                                    sd,
                                                                  ),
                                                          child: const Text(
                                                            'Accept',
                                                          ),
                                                        ),
                                                        const SizedBox(
                                                          width: 8,
                                                        ),
                                                        TextButton(
                                                          onPressed:
                                                              () =>
                                                                  _declineSharedTrip(
                                                                    sd,
                                                                  ),
                                                          child: const Text(
                                                            'Decline',
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                        const SizedBox(height: 12),
                        if (docs.isEmpty)
                          Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text(
                                  'No saved trips yet',
                                  style: TextStyle(fontSize: 18),
                                ),
                                const SizedBox(height: 8),
                                ElevatedButton(
                                  onPressed:
                                      () => Navigator.of(
                                        context,
                                      ).pushNamed('/trip-builder'),
                                  child: const Text('Create a trip'),
                                ),
                              ],
                            ),
                          )
                        else
                          Expanded(
                            child: GridView.builder(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount:
                                        MediaQuery.of(context).size.width >= 900
                                            ? 3
                                            : 1,
                                    mainAxisSpacing: 12,
                                    crossAxisSpacing: 12,
                                    childAspectRatio: 16 / 11,
                                  ),
                              itemCount: docs.length,
                              itemBuilder: (ctx, i) {
                                final d = docs[i];
                              final data = d.data();
                              final name = data['name'] ?? 'Untitled Trip';
                              final created = data['createdAt'];
                              final totalKm = (data['totalKm'] ?? 0) as num;
                              final waypoints =
                                  (data['waypoints'] as List<dynamic>?) ?? [];

                              return ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: _Hoverable(
                                  onTap: () {
                                    Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder:
                                            (_) => TripDetailScreen(
                                              docId: d.id,
                                              data: data,
                                            ),
                                      ),
                                    );
                                  },
                                  child: Material(
                                    color: Colors.white,
                                    elevation: 4,
                                    child: Stack(
                                      children: [
                                        LayoutBuilder(
                                          builder: (tileCtx, tileConstraints) {
                                            // allocate footer as a proportion of available height
                                            final available =
                                                tileConstraints
                                                        .maxHeight
                                                        .isFinite
                                                    ? tileConstraints.maxHeight
                                                    : 320.0;
                                            final footerHeight = (available *
                                                    0.28)
                                                .clamp(56.0, 140.0);
                                            final mapHeight = (available -
                                                    footerHeight)
                                                .clamp(40.0, double.infinity);

                                            return Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.stretch,
                                              children: [
                                                SizedBox(
                                                  height: mapHeight,
                                                  child: ClipRRect(
                                                    borderRadius:
                                                        const BorderRadius.vertical(
                                                          top: Radius.circular(
                                                            12,
                                                          ),
                                                        ),
                                                    child: MapEmbed(
                                                      points:
                                                          waypoints
                                                              .map(
                                                                (w) => {
                                                                  'lat':
                                                                      (w['lat'] ??
                                                                          w['latitude'] ??
                                                                          0.0),
                                                                  'lon':
                                                                      (w['lon'] ??
                                                                          w['longitude'] ??
                                                                          w['lng'] ??
                                                                          0.0),
                                                                  'name':
                                                                      w['name'] ??
                                                                      '',
                                                                },
                                                              )
                                                              .toList(),
                                                    ),
                                                  ),
                                                ),
                                                Container(
                                                  height: footerHeight,
                                                  padding: const EdgeInsets.all(
                                                    12.0,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    border: Border.all(
                                                      color:
                                                          Colors.grey.shade300,
                                                    ),
                                                    borderRadius:
                                                        const BorderRadius.vertical(
                                                          bottom:
                                                              Radius.circular(
                                                                12,
                                                              ),
                                                        ),
                                                  ),
                                                  child: Row(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .center,
                                                    children: [
                                                      Expanded(
                                                        child: Column(
                                                          crossAxisAlignment:
                                                              CrossAxisAlignment
                                                                  .start,
                                                          children: [
                                                            Text(
                                                              name,
                                                              style: const TextStyle(
                                                                fontSize: 16,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .bold,
                                                              ),
                                                            ),
                                                            const SizedBox(
                                                              height: 6,
                                                            ),
                                                            Row(
                                                              children: [
                                                                Icon(
                                                                  Icons
                                                                      .calendar_today,
                                                                  size: 14,
                                                                  color:
                                                                      Colors
                                                                          .grey[600],
                                                                ),
                                                                const SizedBox(
                                                                  width: 6,
                                                                ),
                                                                Text(
                                                                  created !=
                                                                          null
                                                                      ? _prettyDate(
                                                                        created,
                                                                      )
                                                                      : '—',
                                                                  style: TextStyle(
                                                                    color:
                                                                        Colors
                                                                            .grey[700],
                                                                  ),
                                                                ),
                                                              ],
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                      Column(
                                                        crossAxisAlignment:
                                                            CrossAxisAlignment
                                                                .end,
                                                        children: [
                                                          Chip(
                                                            label: Text(
                                                              '${waypoints.length} stops',
                                                            ),
                                                          ),
                                                          const SizedBox(
                                                            height: 6,
                                                          ),
                                                          Text(
                                                            '${totalKm.toStringAsFixed(1)} km',
                                                            style:
                                                                const TextStyle(
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .w600,
                                                                ),
                                                          ),
                                                        ],
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ],
                                            );
                                          },
                                        ),
                                        // shared badge (left) — shows when trip is shared or was shared from someone
                                        Builder(
                                          builder: (ctx) {
                                            final isShared =
                                                ((data['sharedWith'] as List?)
                                                        ?.isNotEmpty ??
                                                    false) ||
                                                (data['sharedFrom'] != null &&
                                                    data['sharedFrom']
                                                        .toString()
                                                        .isNotEmpty);
                                            if (!isShared) {
                                              return const SizedBox.shrink();
                                            }
                                            return Positioned(
                                              top: 8,
                                              left: 8,
                                              child: Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 8,
                                                      vertical: 6,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: Colors.blue.shade600,
                                                  borderRadius:
                                                      BorderRadius.circular(8),
                                                  boxShadow: [
                                                    BoxShadow(
                                                      color: Colors.black
                                                          .withOpacity(0.12),
                                                      blurRadius: 6,
                                                    ),
                                                  ],
                                                ),
                                                child: Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: const [
                                                    Icon(
                                                      Icons.people,
                                                      size: 14,
                                                      color: Colors.white,
                                                    ),
                                                    SizedBox(width: 6),
                                                    Text(
                                                      'Shared',
                                                      style: TextStyle(
                                                        color: Colors.white,
                                                        fontSize: 12,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                        Positioned(
                                          top: 8,
                                          right: 8,
                                          child: PopupMenuButton<String>(
                                            onSelected: (v) async {
                                              if (v == 'delete') {
                                                final ok = await showDialog<
                                                  bool
                                                >(
                                                  context: context,
                                                  builder:
                                                      (ctx) => AlertDialog(
                                                        title: const Text(
                                                          'Delete trip?',
                                                        ),
                                                        content: const Text(
                                                          'This will permanently delete the trip.',
                                                        ),
                                                        actions: [
                                                          TextButton(
                                                            onPressed:
                                                                () =>
                                                                    Navigator.of(
                                                                      ctx,
                                                                    ).pop(
                                                                      false,
                                                                    ),
                                                            child: const Text(
                                                              'Cancel',
                                                            ),
                                                          ),
                                                          TextButton(
                                                            onPressed:
                                                                () =>
                                                                    Navigator.of(
                                                                      ctx,
                                                                    ).pop(true),
                                                            child: const Text(
                                                              'Delete',
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                );
                                                if (ok == true) {
                                                  await _deleteTrip(d.id);
                                                  ScaffoldMessenger.of(
                                                    context,
                                                  ).showSnackBar(
                                                    const SnackBar(
                                                      content: Text(
                                                        'Trip deleted',
                                                      ),
                                                    ),
                                                  );
                                                }
                                              } else if (v == 'share') {
                                                await _shareTripFromMyTrips(
                                                  d.id,
                                                  data,
                                                );
                                              }
                                            },
                                            itemBuilder:
                                                (_) => [
                                                  const PopupMenuItem(
                                                    value: 'share',
                                                    child: Text('Share'),
                                                  ),
                                                  const PopupMenuItem(
                                                    value: 'delete',
                                                    child: Text('Delete'),
                                                  ),
                                                ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    );
                  },
                ),
      ),
    );
  }
}
