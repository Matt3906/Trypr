import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:trypr/screens/verified_trip_builder_screen.dart';
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
                        itemBuilder: (ctx2, i) {
                          final data = docs[i].data();
                          final title = (data['title'] ?? '').toString();
                          final desc = (data['description'] ?? '').toString();
                          final waypoints =
                              (data['waypoints'] as List<dynamic>?) ?? [];

                          return _Hoverable(
                            onTap: () {
                              showDialog<void>(
                                context: context,
                                builder:
                                    (_) => AlertDialog(
                                      title: Text(title),
                                      content: Text(desc),
                                      actions: [
                                        TextButton(
                                          onPressed:
                                              () => Navigator.of(context).pop(),
                                          child: const Text('Close'),
                                        ),
                                      ],
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
                                                title.isNotEmpty
                                                    ? title
                                                    : 'Verified Trip',
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
