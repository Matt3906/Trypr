import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:trypr/utils/trypr_snackbar.dart';
import 'package:trypr/theme/app_theme.dart';
import 'package:trypr/widgets/map_preview.dart';
import 'package:trypr/widgets/share_trip_dialog.dart';
import 'package:trypr/widgets/top_taskbar.dart';
import 'package:trypr/screens/trip_detail_screen.dart';
import 'package:trypr/screens/sign_in_screen.dart';

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
    final scale = _hover ? 1.02 : 1.0;
    final shadow = _hover ? TryprColors.elevatedShadow : TryprColors.softShadow;
    return MouseRegion(
      onEnter: _onEnter,
      onExit: _onExit,
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedScale(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          scale: scale,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(TryprRadius.xl),
              boxShadow: shadow,
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class _TripCardPreview extends StatelessWidget {
  final List<dynamic> waypoints;
  final List<dynamic> routeGeometry;
  final String transportMode;
  final List<String> segmentTransportModes;

  const _TripCardPreview({
    required this.waypoints,
    required this.routeGeometry,
    required this.transportMode,
    required this.segmentTransportModes,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(color: Color(0xFFE5EEF5)),
      child: IgnorePointer(
        child: MapPreview(
          waypoints: waypoints,
          routeGeometry: routeGeometry,
          transportMode: transportMode,
          segmentTransportModes: segmentTransportModes,
        ),
      ),
    );
  }
}

class _MyTripsScreenState extends State<MyTripsScreen> {
  User? get _user => FirebaseAuth.instance.currentUser;
  final Map<String, String> _resolveKeyByDocId = {};
  final Map<String, Future<Map<String, dynamic>>> _resolveFutureByDocId = {};

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

  String? _tripRefPathFromData(Map<String, dynamic> data) {
    final raw = data['tripRef'];
    if (raw is String) {
      final v = raw.trim();
      return v.isEmpty ? null : v;
    }
    if (raw is DocumentReference) return raw.path;
    final v = raw?.toString().trim();
    if (v == null || v.isEmpty) return null;
    return v;
  }

  bool _hasWaypoints(Map<String, dynamic> data) {
    final w = data['waypoints'];
    return w is List && w.isNotEmpty;
  }

  String _resolveKey(String docId, Map<String, dynamic> data) {
    final tripRef = _tripRefPathFromData(data) ?? '';
    final waypointCount = (data['waypoints'] as List?)?.length ?? 0;
    final updated = (data['updatedAt'] ?? data['createdAt'] ?? '').toString();
    return '$docId|$tripRef|$waypointCount|$updated';
  }

  Future<Map<String, dynamic>> _resolvedTripData(
    String docId,
    Map<String, dynamic> data,
  ) {
    final key = _resolveKey(docId, data);
    final existingKey = _resolveKeyByDocId[docId];
    if (existingKey == key && _resolveFutureByDocId[docId] != null) {
      return _resolveFutureByDocId[docId]!;
    }
    _resolveKeyByDocId[docId] = key;
    final future = _resolveTripDataImpl(docId, data);
    _resolveFutureByDocId[docId] = future;
    return future;
  }

  Future<Map<String, dynamic>> _resolveTripDataImpl(
    String docId,
    Map<String, dynamic> local,
  ) async {
    final out = Map<String, dynamic>.from(local);
    final tripRefPath = _tripRefPathFromData(out);
    if (tripRefPath == null) return out;

    final needsHydration =
        !_hasWaypoints(out) ||
        out['transportMode'] == null ||
        out['segmentTransportModes'] == null ||
        out['segmentRoutingTypes'] == null ||
        out['routeVia'] == null ||
        out['routeGeometry3d'] == null ||
        out['routeInstructions'] == null ||
        out['routeCacheKey'] == null;
    if (!needsHydration) return out;

    try {
      final remoteDoc = await FirebaseFirestore.instance.doc(tripRefPath).get();
      if (!remoteDoc.exists) return out;
      final remote = remoteDoc.data() ?? <String, dynamic>{};
      final merged = Map<String, dynamic>.from(remote)..addAll(out);
      final syncPayload = <String, dynamic>{};
      final remoteWaypoints = remote['waypoints'] ?? remote['stops'];
      if (!_hasWaypoints(local) &&
          remoteWaypoints is List &&
          remoteWaypoints.isNotEmpty) {
        merged['waypoints'] = remoteWaypoints;
        syncPayload['waypoints'] = remoteWaypoints;
      }
      if (local['startDate'] == null && merged['startDate'] != null) {
        syncPayload['startDate'] = merged['startDate'];
      }
      if (local['endDate'] == null && merged['endDate'] != null) {
        syncPayload['endDate'] = merged['endDate'];
      }
      if (local['totalKm'] == null && merged['totalKm'] != null) {
        syncPayload['totalKm'] = merged['totalKm'];
      }
      if (local['transportMode'] == null && merged['transportMode'] != null) {
        syncPayload['transportMode'] = merged['transportMode'];
      }
      if (local['segmentTransportModes'] == null &&
          merged['segmentTransportModes'] != null) {
        syncPayload['segmentTransportModes'] = merged['segmentTransportModes'];
      }
      if (local['segmentRoutingTypes'] == null &&
          merged['segmentRoutingTypes'] != null) {
        syncPayload['segmentRoutingTypes'] = merged['segmentRoutingTypes'];
      }
      if (local['routeVia'] == null && merged['routeVia'] != null) {
        syncPayload['routeVia'] = merged['routeVia'];
      }
      if (local['routeGeometry3d'] == null &&
          merged['routeGeometry3d'] != null) {
        syncPayload['routeGeometry3d'] = merged['routeGeometry3d'];
      }
      if (local['routeInstructions'] == null &&
          merged['routeInstructions'] != null) {
        syncPayload['routeInstructions'] = merged['routeInstructions'];
      }
      if (local['routeCacheKey'] == null && merged['routeCacheKey'] != null) {
        syncPayload['routeCacheKey'] = merged['routeCacheKey'];
      }
      if (local['transitArrivalStop'] == null &&
          merged['transitArrivalStop'] != null) {
        syncPayload['transitArrivalStop'] = merged['transitArrivalStop'];
      }
      merged['tripRef'] = tripRefPath;

      // Backfill local cache so previews/opening stay populated for old shared trips.
      final me = _user;
      if (me != null && syncPayload.isNotEmpty) {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(me.uid)
            .collection('trips')
            .doc(docId)
            .set(syncPayload, SetOptions(merge: true));
      }

      return merged;
    } catch (_) {
      return out;
    }
  }

  Future<void> _openTripFromMyTrips(
    String docId,
    Map<String, dynamic> data,
  ) async {
    final resolved = await _resolvedTripData(docId, data);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TripDetailScreen(docId: docId, data: resolved),
      ),
    );
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
          ScaffoldMessenger.of(context).showTryprSnackBar(
            const SnackBar(content: Text('Trip not available')),
          );
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
        ).showTryprSnackBar(SnackBar(content: Text('Open failed: $e')));
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
          ScaffoldMessenger.of(context).showTryprSnackBar(
            const SnackBar(content: Text('Original trip not found')),
          );
        }
        return;
      }
      final ownerName = data['ownerName'] ?? data['ownerUid'] ?? '';
      final remoteData = tripDoc.data() ?? <String, dynamic>{};
      final remoteWaypoints = remoteData['waypoints'] ?? remoteData['stops'];
      await FirebaseFirestore.instance
          .collection('users')
          .doc(u.uid)
          .collection('trips')
          .add({
            'name':
                data['tripName'] ?? tripDoc.data()?['name'] ?? 'Shared Trip',
            'tripRef': tripRefPath,
            'sharedFrom': ownerName,
            if (remoteWaypoints is List && remoteWaypoints.isNotEmpty)
              'waypoints': remoteWaypoints,
            if (remoteData['startDate'] != null)
              'startDate': remoteData['startDate'],
            if (remoteData['endDate'] != null) 'endDate': remoteData['endDate'],
            if (remoteData['totalKm'] != null) 'totalKm': remoteData['totalKm'],
            if (remoteData['transportMode'] != null)
              'transportMode': remoteData['transportMode'],
            if (remoteData['segmentTransportModes'] != null)
              'segmentTransportModes': remoteData['segmentTransportModes'],
            if (remoteData['segmentRoutingTypes'] != null)
              'segmentRoutingTypes': remoteData['segmentRoutingTypes'],
            if (remoteData['routeVia'] != null)
              'routeVia': remoteData['routeVia'],
            if (remoteData['transitArrivalStop'] != null)
              'transitArrivalStop': remoteData['transitArrivalStop'],
            'createdAt': FieldValue.serverTimestamp(),
          });
      await FirebaseFirestore.instance
          .collection('users')
          .doc(u.uid)
          .collection('sharedTrips')
          .doc(sharedDoc.id)
          .delete();
      if (mounted) {
        ScaffoldMessenger.of(context).showTryprSnackBar(
          const SnackBar(content: Text('Trip accepted and added to My Trips')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showTryprSnackBar(SnackBar(content: Text('Accept failed: $e')));
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
        ScaffoldMessenger.of(context).showTryprSnackBar(
          const SnackBar(content: Text('Shared invite declined')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showTryprSnackBar(SnackBar(content: Text('Decline failed: $e')));
      }
    }
  }

  Future<void> _shareTripFromMyTrips(
    String tripId,
    Map<String, dynamic> tripData,
  ) async {
    final u = _user;
    if (u == null) return;
    final tripRefPath = 'users/${u.uid}/trips/$tripId';
    final tripName = (tripData['name'] ?? '').toString();
    await ShareTripDialog.show(
      context,
      tripRefPath: tripRefPath,
      tripId: tripId,
      tripName: tripName,
    );
  }

  Widget _statTile({
    required IconData icon,
    required String label,
    required String value,
    required Color accent,
  }) {
    return Container(
      padding: const EdgeInsets.all(TryprSpacing.md),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(TryprRadius.lg),
        border: Border.all(color: accent.withValues(alpha: 0.25)),
        boxShadow: TryprColors.softShadow,
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 18, color: accent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: TryprColors.textPrimary,
                  ),
                ),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: TryprColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _frostBadge({required IconData icon, required String text}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(TryprRadius.full),
        border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: Colors.white),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
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
              child: SoftCard(
                elevated: true,
                padding: const EdgeInsets.all(TryprSpacing.xl),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: TryprColors.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(TryprRadius.lg),
                      ),
                      child: const Icon(
                        Icons.route_outlined,
                        color: TryprColors.primaryDark,
                        size: 28,
                      ),
                    ),
                    const SizedBox(height: TryprSpacing.md),
                    Text(
                      'Sign in to view your saved trips',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: TryprSpacing.sm),
                    Text(
                      'Your past and upcoming adventures will appear here.',
                      style: Theme.of(context).textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: TryprSpacing.lg),
                    ElevatedButton.icon(
                      onPressed:
                          () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const SignInScreen(),
                            ),
                          ),
                      icon: const Icon(Icons.login),
                      label: const Text('Sign in'),
                    ),
                  ],
                ),
              ),
            )
            : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: stream,
              builder: (ctx, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(
                      color: TryprColors.primary,
                    ),
                  );
                }
                final docs = snap.data?.docs ?? [];
                final sharedByMeCount =
                    docs.where((d) {
                      final data = d.data();
                      final sharedWith = data['sharedWith'];
                      return sharedWith is List && sharedWith.isNotEmpty;
                    }).length;
                final totalStops = docs.fold<int>(0, (total, d) {
                  final list = d.data()['waypoints'] as List?;
                  return total + (list?.length ?? 0);
                });
                final avgStops =
                    docs.isEmpty ? 0 : (totalStops / docs.length).round();

                return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: _sharedStream(),
                  builder: (sctx, ssnap) {
                    final sdocs = ssnap.data?.docs ?? const [];
                    final isCompact = MediaQuery.sizeOf(context).width < 760;

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(TryprSpacing.xl),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [
                                Color(0xFF1D74B7),
                                TryprColors.primary,
                                Color(0xFF2BB7A2),
                              ],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(TryprRadius.xl),
                            boxShadow: TryprColors.elevatedShadow,
                          ),
                          child:
                              isCompact
                                  ? Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Welcome back, $userName',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.headlineSmall?.copyWith(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      const Text(
                                        'Your adventures, shared plans, and route ideas all in one place.',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 14,
                                        ),
                                      ),
                                      const SizedBox(height: TryprSpacing.md),
                                      SizedBox(
                                        width: double.infinity,
                                        child: ElevatedButton.icon(
                                          onPressed:
                                              () => Navigator.of(
                                                context,
                                              ).pushNamed('/trip-builder'),
                                          icon: const Icon(Icons.add),
                                          label: const Text('Create New Trip'),
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: Colors.white,
                                            foregroundColor:
                                                TryprColors.primaryDark,
                                          ),
                                        ),
                                      ),
                                    ],
                                  )
                                  : Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              'Welcome back, $userName',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .displaySmall
                                                  ?.copyWith(
                                                    color: Colors.white,
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                            ),
                                            const SizedBox(height: 6),
                                            const Text(
                                              'Your adventures, shared plans, and route ideas all in one place.',
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontSize: 14,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: TryprSpacing.lg),
                                      ElevatedButton.icon(
                                        onPressed:
                                            () => Navigator.of(
                                              context,
                                            ).pushNamed('/trip-builder'),
                                        icon: const Icon(Icons.add),
                                        label: const Text('Create New Trip'),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: Colors.white,
                                          foregroundColor:
                                              TryprColors.primaryDark,
                                        ),
                                      ),
                                    ],
                                  ),
                        ),
                        const SizedBox(height: TryprSpacing.lg),
                        LayoutBuilder(
                          builder: (ctx4, box) {
                            final tiles = <Widget>[
                              _statTile(
                                icon: Icons.map_outlined,
                                label: 'Total Trips',
                                value: '${docs.length}',
                                accent: TryprColors.primary,
                              ),
                              _statTile(
                                icon: Icons.mail_outline,
                                label: 'Shared Invites',
                                value: '${sdocs.length}',
                                accent: TryprColors.secondary,
                              ),
                              _statTile(
                                icon: Icons.people_alt_outlined,
                                label: 'Trips You Shared',
                                value: '$sharedByMeCount',
                                accent: TryprColors.peach,
                              ),
                              _statTile(
                                icon: Icons.route_outlined,
                                label: 'Avg Stops per Trip',
                                value: '$avgStops',
                                accent: TryprColors.mint,
                              ),
                            ];

                            if (box.maxWidth < 760) {
                              return Column(
                                children: [
                                  for (var i = 0; i < tiles.length; i++) ...[
                                    tiles[i],
                                    if (i < tiles.length - 1)
                                      const SizedBox(height: TryprSpacing.sm),
                                  ],
                                ],
                              );
                            }

                            return Row(
                              children: [
                                for (var i = 0; i < tiles.length; i++) ...[
                                  Expanded(child: tiles[i]),
                                  if (i < tiles.length - 1)
                                    const SizedBox(width: TryprSpacing.sm),
                                ],
                              ],
                            );
                          },
                        ),
                        if (sdocs.isNotEmpty) ...[
                          const SizedBox(height: TryprSpacing.lg),
                          SoftCard(
                            elevated: true,
                            padding: const EdgeInsets.all(TryprSpacing.lg),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      width: 34,
                                      height: 34,
                                      decoration: BoxDecoration(
                                        color: TryprColors.secondary.withValues(
                                          alpha: 0.14,
                                        ),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: const Icon(
                                        Icons.move_to_inbox_outlined,
                                        color: TryprColors.secondary,
                                        size: 18,
                                      ),
                                    ),
                                    const SizedBox(width: TryprSpacing.sm),
                                    Expanded(
                                      child: Text(
                                        'Shared Trip Invites',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleMedium?.copyWith(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      '${sdocs.length} pending',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall?.copyWith(
                                        color: TryprColors.textSecondary,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: TryprSpacing.md),
                                SizedBox(
                                  height: 196,
                                  child: ListView.separated(
                                    scrollDirection: Axis.horizontal,
                                    itemCount: sdocs.length,
                                    separatorBuilder:
                                        (_, __) => const SizedBox(
                                          width: TryprSpacing.md,
                                        ),
                                    itemBuilder: (ctx2, si) {
                                      final sd = sdocs[si];
                                      final sdata = sd.data();
                                      final owner =
                                          (sdata['ownerName'] ??
                                                  sdata['ownerUid'] ??
                                                  'Someone')
                                              .toString();
                                      final title =
                                          (sdata['tripName'] ?? 'Shared Trip')
                                              .toString();

                                      return Container(
                                        width: 320,
                                        decoration: BoxDecoration(
                                          gradient: const LinearGradient(
                                            colors: [
                                              Color(0xFFF7FBFF),
                                              Colors.white,
                                            ],
                                            begin: Alignment.topLeft,
                                            end: Alignment.bottomRight,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            TryprRadius.lg,
                                          ),
                                          border: Border.all(
                                            color: const Color(0xFFE5EEF7),
                                          ),
                                        ),
                                        padding: const EdgeInsets.all(
                                          TryprSpacing.md,
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              title,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w700,
                                                fontSize: 15,
                                                color: TryprColors.textPrimary,
                                              ),
                                            ),
                                            const SizedBox(height: 6),
                                            Text(
                                              'From ${owner.toString()}',
                                              style: const TextStyle(
                                                color:
                                                    TryprColors.textSecondary,
                                                fontSize: 12,
                                              ),
                                            ),
                                            const Spacer(),
                                            Wrap(
                                              spacing: 8,
                                              runSpacing: 8,
                                              children: [
                                                ElevatedButton(
                                                  onPressed:
                                                      () => _openSharedTrip(sd),
                                                  child: const Text('Open'),
                                                ),
                                                OutlinedButton(
                                                  onPressed:
                                                      () =>
                                                          _acceptSharedTrip(sd),
                                                  child: const Text('Accept'),
                                                ),
                                                TextButton(
                                                  onPressed:
                                                      () => _declineSharedTrip(
                                                        sd,
                                                      ),
                                                  child: const Text('Decline'),
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
                        ],
                        const SizedBox(height: TryprSpacing.lg),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'My Trips',
                                style: Theme.of(context).textTheme.headlineSmall
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: TryprSpacing.sm),
                        if (docs.isEmpty)
                          SoftCard(
                            elevated: true,
                            padding: const EdgeInsets.all(TryprSpacing.xl),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 56,
                                  height: 56,
                                  decoration: BoxDecoration(
                                    color: TryprColors.surfaceVariant,
                                    borderRadius: BorderRadius.circular(
                                      TryprRadius.lg,
                                    ),
                                  ),
                                  child: const Icon(
                                    Icons.luggage_outlined,
                                    color: TryprColors.textSecondary,
                                    size: 28,
                                  ),
                                ),
                                const SizedBox(height: TryprSpacing.md),
                                Text(
                                  'No saved trips yet',
                                  style: Theme.of(context).textTheme.titleLarge
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(height: TryprSpacing.sm),
                                Text(
                                  'Create your first itinerary and it will appear here.',
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                                const SizedBox(height: TryprSpacing.lg),
                                ElevatedButton.icon(
                                  onPressed:
                                      () => Navigator.of(
                                        context,
                                      ).pushNamed('/trip-builder'),
                                  icon: const Icon(Icons.add),
                                  label: const Text('Create a trip'),
                                ),
                              ],
                            ),
                          )
                        else
                          LayoutBuilder(
                            builder: (gridCtx, gridBox) {
                              final width = gridBox.maxWidth;
                              final crossAxisCount =
                                  width >= 1100
                                      ? 3
                                      : width >= 720
                                      ? 2
                                      : 1;
                              final aspectRatio =
                                  crossAxisCount == 1
                                      ? 1.9
                                      : crossAxisCount == 2
                                      ? 1.35
                                      : 1.1;

                              return GridView.builder(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: crossAxisCount,
                                      mainAxisSpacing: 16,
                                      crossAxisSpacing: 16,
                                      childAspectRatio: aspectRatio,
                                    ),
                                itemCount: docs.length,
                                itemBuilder: (ctx5, i) {
                                  final d = docs[i];
                                  final localData = d.data();
                                  final data = localData;
                                  final name =
                                      (data['name'] ?? 'Untitled Trip')
                                          .toString();
                                  final waypoints =
                                      (data['waypoints'] as List<dynamic>?) ??
                                      const <dynamic>[];
                                  final transportMode =
                                      (data['transportMode'] ?? 'car')
                                          .toString();
                                  final segmentTransportModesRaw =
                                      data['segmentTransportModes'];
                                  final segmentTransportModes =
                                      (segmentTransportModesRaw is List)
                                          ? segmentTransportModesRaw
                                              .map((e) => e.toString())
                                              .toList(growable: false)
                                          : const <String>[];
                                  final stopCount = waypoints.length;
                                  final isShared =
                                      ((data['sharedWith'] as List?)
                                              ?.isNotEmpty ??
                                          false) ||
                                      (data['sharedFrom'] != null &&
                                          data['sharedFrom']
                                              .toString()
                                              .isNotEmpty);

                                  return _Hoverable(
                                    onTap:
                                        () => _openTripFromMyTrips(
                                          d.id,
                                          localData,
                                        ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(
                                        TryprRadius.xl,
                                      ),
                                      child: Stack(
                                        children: [
                                          Positioned.fill(
                                            child: _TripCardPreview(
                                              waypoints: waypoints,
                                              routeGeometry:
                                                  (data['routeGeometry3d']
                                                      as List<dynamic>?) ??
                                                  const <dynamic>[],
                                              transportMode: transportMode,
                                              segmentTransportModes:
                                                  segmentTransportModes,
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
                                                      alpha: 0.72,
                                                    ),
                                                    Colors.black.withValues(
                                                      alpha: 0.24,
                                                    ),
                                                    Colors.transparent,
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                          Positioned(
                                            top: 12,
                                            left: 12,
                                            child: Container(
                                              decoration: BoxDecoration(
                                                color: Colors.black.withValues(
                                                  alpha: 0.42,
                                                ),
                                                borderRadius:
                                                    BorderRadius.circular(
                                                      TryprRadius.full,
                                                    ),
                                              ),
                                              child: PopupMenuButton<String>(
                                                iconColor: Colors.white,
                                                onSelected: (v) async {
                                                  if (v == 'delete') {
                                                    final ok = await showDialog<
                                                      bool
                                                    >(
                                                      context: context,
                                                      builder:
                                                          (ctx6) => AlertDialog(
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
                                                                          ctx6,
                                                                        ).pop(
                                                                          false,
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
                                                                          ctx6,
                                                                        ).pop(
                                                                          true,
                                                                        ),
                                                                child:
                                                                    const Text(
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
                                                        ).showTryprSnackBar(
                                                          const SnackBar(
                                                            content: Text(
                                                              'Trip deleted',
                                                            ),
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
                                          ),
                                          Positioned(
                                            top: 12,
                                            right: 12,
                                            child: Wrap(
                                              spacing: 8,
                                              runSpacing: 8,
                                              children: [
                                                _frostBadge(
                                                  icon: Icons.place_outlined,
                                                  text: '$stopCount stops',
                                                ),
                                                if (isShared)
                                                  _frostBadge(
                                                    icon: Icons.people,
                                                    text: 'Shared',
                                                  ),
                                              ],
                                            ),
                                          ),
                                          Positioned(
                                            left: 14,
                                            right: 14,
                                            bottom: 14,
                                            child: Container(
                                              padding: const EdgeInsets.all(
                                                TryprSpacing.md,
                                              ),
                                              decoration: BoxDecoration(
                                                color: Colors.black.withValues(
                                                  alpha: 0.38,
                                                ),
                                                borderRadius:
                                                    BorderRadius.circular(
                                                      TryprRadius.lg,
                                                    ),
                                              ),
                                              child: Row(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.end,
                                                children: [
                                                  Text(
                                                    _tripEmoji(data),
                                                    style: const TextStyle(
                                                      fontSize: 22,
                                                    ),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Expanded(
                                                    child: Column(
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .start,
                                                      mainAxisSize:
                                                          MainAxisSize.min,
                                                      children: [
                                                        Text(
                                                          name,
                                                          maxLines: 1,
                                                          overflow:
                                                              TextOverflow
                                                                  .ellipsis,
                                                          style:
                                                              const TextStyle(
                                                                fontSize: 18,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w700,
                                                                color:
                                                                    Colors
                                                                        .white,
                                                              ),
                                                        ),
                                                        const SizedBox(
                                                          height: 4,
                                                        ),
                                                        Text(
                                                          _dateRange(data),
                                                          maxLines: 1,
                                                          overflow:
                                                              TextOverflow
                                                                  .ellipsis,
                                                          style: TextStyle(
                                                            color: Colors.white
                                                                .withValues(
                                                                  alpha: 0.9,
                                                                ),
                                                            fontSize: 13,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              );
                            },
                          ),
                      ],
                    );
                  },
                );
              },
            );

    return Scaffold(
      appBar: const TopTaskbar(dockProgress: 1.0),
      backgroundColor: TryprColors.background,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1280),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(top: 16),
              child: panelContent,
            ),
          ),
        ),
      ),
    );
  }
}
