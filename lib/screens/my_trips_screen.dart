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
  const _Hoverable({required this.child, this.onTap});

  @override
  State<_Hoverable> createState() => _HoverableState();
}

class _HoverableState extends State<_Hoverable> {
  bool _hover = false;
  void _onEnter(PointerEvent e) => setState(() => _hover = true);
  void _onExit(PointerEvent e) => setState(() => _hover = false);

  @override
  Widget build(BuildContext context) {
    final scale = _hover ? 1.05 : 1.0;
    final shadow =
        _hover
            ? [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.12),
                blurRadius: 12,
                offset: const Offset(0, 6),
              ),
            ]
            : [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.06),
                blurRadius: 6,
              ),
            ];
    return MouseRegion(
      onEnter: _onEnter,
      onExit: _onExit,
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedScale(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          scale: scale,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              boxShadow: shadow,
            ),
            child: widget.child,
          ),
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

  String _dateRange(Map<String, dynamic> data) {
    final start = (data['startDate'] ?? '').toString().trim();
    final end = (data['endDate'] ?? '').toString().trim();
    if (start.isNotEmpty && end.isNotEmpty) return '$start – $end';
    if (start.isNotEmpty) return start;
    if (end.isNotEmpty) return end;
    final created = data['createdAt'];
    return created != null ? _prettyDate(created) : 'Dates TBD';
  }

  String _tripEmoji(Map<String, dynamic> data) {
    final emoji = (data['emoji'] ?? data['tripEmoji'] ?? '').toString().trim();
    return emoji.isNotEmpty ? emoji : '🧭';
  }

  List<Map<String, dynamic>> _mapPoints(List<dynamic> waypoints) {
    return waypoints
        .map(
          (w) => {
            'lat': (w['lat'] ?? w['latitude'] ?? 0.0),
            'lon': (w['lon'] ?? w['longitude'] ?? w['lng'] ?? 0.0),
            'name': w['name'] ?? '',
          },
        )
        .toList();
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
      tripData['tripRef'] = tripRefPath;
      if (mounted) {
        final updated = await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => TripDetailScreen(docId: tripDoc.id, data: tripData),
          ),
        );
        if (updated == true && mounted) {
          setState(() {});
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
    final userName =
        _user?.displayName ?? _user?.email?.split('@').first ?? 'Traveler';
    final panelContent =
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
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Text(
                            'Welcome back, $userName! Here are your adventures.',
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        const SizedBox(width: 12),
                        ElevatedButton.icon(
                          onPressed:
                              () => Navigator.of(
                                context,
                              ).pushNamed('/trip-builder'),
                          icon: const Icon(Icons.add),
                          label: const Text('Create New Trip'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFFFD54F),
                            foregroundColor: Colors.black87,
                            shape: const StadiumBorder(),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 14,
                            ),
                            elevation: 2,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
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
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(fontWeight: FontWeight.w600),
                                ),
                                const SizedBox(height: 8),
                                SizedBox(
                                  height: 180,
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
                                          sdata['tripName'] ?? 'Shared Trip';
                                      return SizedBox(
                                        width: 340,
                                        child: Card(
                                          child: Padding(
                                            padding: const EdgeInsets.all(8.0),
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  title,
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.w600,
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
                                                Wrap(
                                                  spacing: 8,
                                                  runSpacing: 6,
                                                  children: [
                                                    ElevatedButton(
                                                      onPressed:
                                                          () => _openSharedTrip(
                                                            sd,
                                                          ),
                                                      style: ElevatedButton.styleFrom(
                                                        padding:
                                                            const EdgeInsets.symmetric(
                                                              horizontal: 12,
                                                              vertical: 8,
                                                            ),
                                                        minimumSize: const Size(
                                                          0,
                                                          36,
                                                        ),
                                                        tapTargetSize:
                                                            MaterialTapTargetSize
                                                                .shrinkWrap,
                                                      ),
                                                      child: const Text('Open'),
                                                    ),
                                                    OutlinedButton(
                                                      onPressed:
                                                          () =>
                                                              _acceptSharedTrip(
                                                                sd,
                                                              ),
                                                      style: OutlinedButton.styleFrom(
                                                        padding:
                                                            const EdgeInsets.symmetric(
                                                              horizontal: 12,
                                                              vertical: 8,
                                                            ),
                                                        minimumSize: const Size(
                                                          0,
                                                          36,
                                                        ),
                                                        tapTargetSize:
                                                            MaterialTapTargetSize
                                                                .shrinkWrap,
                                                      ),
                                                      child: const Text(
                                                        'Accept',
                                                      ),
                                                    ),
                                                    TextButton(
                                                      onPressed:
                                                          () =>
                                                              _declineSharedTrip(
                                                                sd,
                                                              ),
                                                      style: TextButton.styleFrom(
                                                        padding:
                                                            const EdgeInsets.symmetric(
                                                              horizontal: 12,
                                                              vertical: 8,
                                                            ),
                                                        minimumSize: const Size(
                                                          0,
                                                          36,
                                                        ),
                                                        tapTargetSize:
                                                            MaterialTapTargetSize
                                                                .shrinkWrap,
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
                    const SizedBox(height: 16),
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
                      GridView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount:
                              MediaQuery.sizeOf(context).width >= 1100
                                  ? 3
                                  : MediaQuery.sizeOf(context).width >= 720
                                  ? 2
                                  : 1,
                          mainAxisSpacing: 16,
                          crossAxisSpacing: 16,
                          childAspectRatio: 4 / 3,
                        ),
                        itemCount: docs.length,
                        itemBuilder: (ctx, i) {
                          final d = docs[i];
                          final data = d.data();
                          final name =
                              (data['name'] ?? 'Untitled Trip').toString();
                          final waypoints =
                              (data['waypoints'] as List<dynamic>?) ?? [];
                          final isShared =
                              ((data['sharedWith'] as List?)?.isNotEmpty ??
                                  false) ||
                              (data['sharedFrom'] != null &&
                                  data['sharedFrom'].toString().isNotEmpty);

                          return _Hoverable(
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
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(18),
                              child: Stack(
                                children: [
                                  Positioned.fill(
                                    child: IgnorePointer(
                                      ignoring: true,
                                      child: MapEmbed(
                                        points: _mapPoints(waypoints),
                                        disableDefaultUi: true,
                                        disableGestures: true,
                                        zoomControlsEnabled: false,
                                      ),
                                    ),
                                  ),
                                  Positioned.fill(
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          begin: Alignment.bottomCenter,
                                          end: Alignment.topCenter,
                                          colors: [
                                            Colors.black.withValues(
                                              alpha: 0.65,
                                            ),
                                            Colors.transparent,
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    left: 16,
                                    right: 16,
                                    bottom: 14,
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.end,
                                      children: [
                                        Text(
                                          _tripEmoji(data),
                                          style: const TextStyle(fontSize: 22),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(
                                                name,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontSize: 18,
                                                  fontWeight: FontWeight.w700,
                                                  color: Colors.white,
                                                ),
                                              ),
                                              const SizedBox(height: 4),
                                              Text(
                                                _dateRange(data),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: Colors.white
                                                      .withValues(alpha: 0.85),
                                                  fontSize: 13,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (isShared)
                                    Positioned(
                                      top: 12,
                                      right: 12,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 6,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.black.withValues(
                                            alpha: 0.6,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            999,
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
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
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  Positioned(
                                    top: 8,
                                    left: 8,
                                    child: PopupMenuButton<String>(
                                      iconColor: Colors.white,
                                      onSelected: (v) async {
                                        if (v == 'delete') {
                                          final ok = await showDialog<bool>(
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
                                                          () => Navigator.of(
                                                            ctx,
                                                          ).pop(false),
                                                      child: const Text(
                                                        'Cancel',
                                                      ),
                                                    ),
                                                    TextButton(
                                                      onPressed:
                                                          () => Navigator.of(
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
                                            if (context.mounted) {
                                              ScaffoldMessenger.of(
                                                context,
                                              ).showSnackBar(
                                                const SnackBar(
                                                  content: Text('Trip deleted'),
                                                ),
                                              );
                                            }
                                          }
                                        } else if (v == 'share') {
                                          await _shareTripFromMyTrips(
                                            d.id,
                                            data,
                                          );
                                        }
                                      },
                                      itemBuilder:
                                          (_) => const [
                                            PopupMenuItem(
                                              value: 'share',
                                              child: Text('Share'),
                                            ),
                                            PopupMenuItem(
                                              value: 'delete',
                                              child: Text('Delete'),
                                            ),
                                          ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                  ],
                );
              },
            );

    return Scaffold(
      appBar: const TopTaskbar(dockProgress: 1.0),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1280),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: SingleChildScrollView(child: panelContent),
          ),
        ),
      ),
    );
  }
}
