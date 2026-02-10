import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:trypr/screens/verified_trip_builder_screen.dart';
import 'package:trypr/screens/verified_trip_detail_screen.dart';
import 'package:trypr/widgets/map_embed.dart';
import 'package:trypr/widgets/top_taskbar.dart';
import 'dart:async';

class VerifiedTripsScreen extends StatefulWidget {
  const VerifiedTripsScreen({super.key});

  @override
  State<VerifiedTripsScreen> createState() => _VerifiedTripsScreenState();
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

class _VerifiedTripsScreenState extends State<VerifiedTripsScreen> {
  Stream<DocumentSnapshot<Map<String, dynamic>>>? _adminDoc;
  StreamSubscription<User?>? _authSub;
  bool _isAdmin = false;

  String _dateRange(Map<String, dynamic> data) {
    final subtitle = (data['subtitle'] ?? '').toString().trim();
    final days = data['recommendedDays'] ?? data['days'];
    if (subtitle.isNotEmpty) return subtitle;
    if (days is int) return 'Recommended: $days days';
    return 'Verified itinerary';
  }

  String _tripEmoji(Map<String, dynamic> data) {
    final emoji = (data['emoji'] ?? data['tripEmoji'] ?? '').toString().trim();
    return emoji.isNotEmpty ? emoji : '✅';
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

  @override
  void initState() {
    super.initState();
    void syncAdminDoc(User? u) {
      setState(() {
        _adminDoc =
            u == null
                ? null
                : FirebaseFirestore.instance
                    .collection('admins')
                    .doc(u.uid)
                    .snapshots();
      });
    }

    syncAdminDoc(FirebaseAuth.instance.currentUser);
    _authSub = FirebaseAuth.instance.authStateChanges().listen(syncAdminDoc);
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  Future<void> _deleteTrip(String tripId, String tripTitle) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Delete Verified Trip'),
            content: Text(
              'Are you sure you want to delete "$tripTitle"?\n\nThis action cannot be undone.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Delete'),
              ),
            ],
          ),
    );

    if (confirmed == true) {
      try {
        await FirebaseFirestore.instance
            .collection('verifiedTrips')
            .doc(tripId)
            .delete();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Deleted "$tripTitle"'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to delete: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  Future<void> _editTrip(String tripId, Map<String, dynamic> tripData) async {
    await Navigator.of(context).push(
      VerifiedTripBuilderScreen.route(
        existingTripId: tripId,
        existingTripData: tripData,
      ),
    );
  }

  Widget _errorBox(String title, Object? error) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              Text(
                (error ?? '').toString(),
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: Colors.black54),
              ),
              const SizedBox(height: 10),
              const Text(
                'If this mentions permissions, make sure your Firestore rules are deployed and that your admin document ID exactly matches your Firebase Auth UID.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openCreateBuilder() async {
    await Navigator.of(context).push(VerifiedTripBuilderScreen.route());
  }

  @override
  Widget build(BuildContext context) {
    final trips =
        FirebaseFirestore.instance
            .collection('verifiedTrips')
            .orderBy('createdAt', descending: true)
            .snapshots();

    return Scaffold(
      appBar: const TopTaskbar(dockProgress: 1.0),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1280),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: SingleChildScrollView(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: trips,
                builder: (ctx, snap) {
                  if (snap.hasError) {
                    return _errorBox(
                      'Failed to load verified trips',
                      snap.error,
                    );
                  }
                  if (!snap.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final docs = snap.data!.docs;
                  if (docs.isEmpty) {
                    return const Center(child: Text('No verified trips yet'));
                  }

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Text(
                              'Verified Trips',
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                          const SizedBox(width: 12),
                          StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                            stream: _adminDoc,
                            builder: (ctx3, adminSnap) {
                              if (adminSnap.hasError) {
                                return const SizedBox.shrink();
                              }
                              final isAdmin = (adminSnap.data?.exists ?? false);
                              if (!isAdmin) return const SizedBox.shrink();
                              return ElevatedButton.icon(
                                onPressed: _openCreateBuilder,
                                icon: const Icon(Icons.add),
                                label: const Text('Create Trip'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF00B894),
                                  foregroundColor: Colors.white,
                                  shape: const StadiumBorder(),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 18,
                                    vertical: 14,
                                  ),
                                  elevation: 2,
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                        stream: _adminDoc,
                        builder: (adminCtx, adminSnap) {
                          final isAdmin = adminSnap.data?.exists ?? false;
                          return GridView.builder(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount:
                                      MediaQuery.sizeOf(context).width >= 1100
                                          ? 3
                                          : MediaQuery.sizeOf(context).width >=
                                              720
                                          ? 2
                                          : 1,
                                  mainAxisSpacing: 16,
                                  crossAxisSpacing: 16,
                                  childAspectRatio: 4 / 3,
                                ),
                            itemCount: docs.length,
                            itemBuilder: (ctx2, i) {
                              final tripId = docs[i].id;
                              final data = docs[i].data();
                              final title = (data['title'] ?? '').toString();
                              final subtitle =
                                  (data['subtitle'] ?? '').toString();
                              final coverImage =
                                  (data['coverImage'] ?? '').toString();
                              final recommendedDays =
                                  data['recommendedDays'] ?? data['days'] ?? 0;
                              final totalStops = data['totalStops'] ?? 0;
                              final waypoints =
                                  (data['waypoints'] as List<dynamic>?) ?? [];

                              return _Hoverable(
                                onTap: () {
                                  Navigator.of(context).push(
                                    VerifiedTripDetailScreen.route(
                                      tripId: tripId,
                                      tripData: data,
                                    ),
                                  );
                                },
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(18),
                                  child: Stack(
                                    children: [
                                      // Cover image or map fallback
                                      Positioned.fill(
                                        child:
                                            coverImage.isNotEmpty
                                                ? Image.network(
                                                  coverImage,
                                                  fit: BoxFit.cover,
                                                  loadingBuilder: (
                                                    context,
                                                    child,
                                                    loadingProgress,
                                                  ) {
                                                    if (loadingProgress == null)
                                                      return child;
                                                    return Container(
                                                      color: Colors.grey[200],
                                                      child: const Center(
                                                        child:
                                                            CircularProgressIndicator(
                                                              strokeWidth: 2,
                                                            ),
                                                      ),
                                                    );
                                                  },
                                                  errorBuilder: (
                                                    _,
                                                    error,
                                                    ___,
                                                  ) {
                                                    debugPrint(
                                                      'Image load error: $error',
                                                    );
                                                    return IgnorePointer(
                                                      ignoring: true,
                                                      child: MapEmbed(
                                                        points: _mapPoints(
                                                          waypoints,
                                                        ),
                                                        disableDefaultUi: true,
                                                        disableGestures: true,
                                                        zoomControlsEnabled:
                                                            false,
                                                      ),
                                                    );
                                                  },
                                                )
                                                : IgnorePointer(
                                                  ignoring: true,
                                                  child: MapEmbed(
                                                    points: _mapPoints(
                                                      waypoints,
                                                    ),
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
                                      // Admin edit/delete buttons
                                      if (isAdmin)
                                        Positioned(
                                          top: 12,
                                          left: 12,
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              _AdminActionButton(
                                                icon: Icons.edit,
                                                tooltip: 'Edit Trip',
                                                onPressed:
                                                    () =>
                                                        _editTrip(tripId, data),
                                              ),
                                              const SizedBox(width: 8),
                                              _AdminActionButton(
                                                icon: Icons.delete,
                                                tooltip: 'Delete Trip',
                                                color: Colors.red,
                                                onPressed:
                                                    () => _deleteTrip(
                                                      tripId,
                                                      title,
                                                    ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      Positioned(
                                        left: 16,
                                        right: 16,
                                        bottom: 14,
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            // Subtitle tag
                                            if (subtitle.isNotEmpty)
                                              Container(
                                                margin: const EdgeInsets.only(
                                                  bottom: 8,
                                                ),
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 10,
                                                      vertical: 4,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: const Color(
                                                    0xFF00B894,
                                                  ),
                                                  borderRadius:
                                                      BorderRadius.circular(12),
                                                ),
                                                child: Text(
                                                  subtitle,
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                              ),
                                            // Title
                                            Text(
                                              title.isNotEmpty
                                                  ? title
                                                  : 'Verified Trip',
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 20,
                                                fontWeight: FontWeight.w700,
                                                color: Colors.white,
                                                shadows: [
                                                  Shadow(
                                                    blurRadius: 8,
                                                    color: Colors.black54,
                                                  ),
                                                ],
                                              ),
                                            ),
                                            const SizedBox(height: 8),
                                            // Stats row
                                            Row(
                                              children: [
                                                _TripStatChip(
                                                  icon: Icons.calendar_today,
                                                  label:
                                                      '$recommendedDays days',
                                                ),
                                                const SizedBox(width: 8),
                                                _TripStatChip(
                                                  icon: Icons.place,
                                                  label: '$totalStops stops',
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
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
                                                Icons.verified,
                                                size: 14,
                                                color: Colors.white,
                                              ),
                                              SizedBox(width: 6),
                                              Text(
                                                'Verified',
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
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Small circular button for admin actions on trip cards
class _AdminActionButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final Color color;

  const _AdminActionButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.black.withValues(alpha: 0.6),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(icon, size: 18, color: color),
          ),
        ),
      ),
    );
  }
}

/// Small stat chip for trip cards
class _TripStatChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _TripStatChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: Colors.white70),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
