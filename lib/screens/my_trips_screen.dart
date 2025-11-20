import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:trypr/widgets/top_taskbar.dart';
import 'package:trypr/screens/trip_detail_screen.dart';
import 'package:trypr/screens/sign_in_screen.dart';
import 'package:trypr/widgets/map_embed.dart';

class MyTripsScreen extends StatefulWidget {
  const MyTripsScreen({Key? key}) : super(key: key);

  @override
  State<MyTripsScreen> createState() => _MyTripsScreenState();
}

// Hoverable wrapper for web/desktop to give visual affordance that the
// tile is clickable. Scales + increases shadow on hover.
class _Hoverable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  const _Hoverable({Key? key, required this.child, this.onTap}) : super(key: key);

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
    final shadow = _hover
        ? [BoxShadow(color: Colors.black.withOpacity(0.12), blurRadius: 12, offset: const Offset(0, 6))]
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
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), boxShadow: shadow),
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

  Future<void> _deleteTrip(String docId) async {
    final u = _user;
    if (u == null) return;
    await FirebaseFirestore.instance
        .collection('users')
        .doc(u.uid)
        .collection('trips')
        .doc(docId)
        .delete();
  }

  void _showTripDetails(Map<String, dynamic> data) {
    // Deprecated: we now use a full-screen detail view. Keep function for
    // backwards compatibility, but push the detail screen instead.
    // Navigator push in place of the old dialog
    // (caller may still call this helper with the trip data)
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => TripDetailScreen(docId: data['id'] ?? '', data: data)));
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
                        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SignInScreen())),
                        child: const Text('Sign in'),
                      ),
                    ],
                  ),
                )
                : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: stream,
                  builder: (ctx, snap) {
                    if (snap.connectionState == ConnectionState.waiting)
                      return const Center(child: CircularProgressIndicator());
                    if (!snap.hasData || snap.data!.docs.isEmpty) {
                      return Center(
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
                      );
                    }

                    return GridView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount:
                            MediaQuery.of(context).size.width >= 900 ? 3 : 1,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        // Make the grid tiles taller so the map + metadata fits without overflow
                        childAspectRatio: 16 / 11,
                      ),
                      itemCount: snap.data!.docs.length,
                      itemBuilder: (ctx, i) {
                        final d = snap.data!.docs[i];
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
                              Navigator.of(context).push(MaterialPageRoute(builder: (_) => TripDetailScreen(docId: d.id, data: data)));
                            },
                            child: Material(
                              color: Colors.white,
                              elevation: 4,
                              child: Stack(
                                children: [
                                  LayoutBuilder(builder: (tileCtx, tileConstraints) {
                                    const double footerHeight = 92.0;
                                    final mapHeight = (tileConstraints.maxHeight - footerHeight).clamp(80.0, double.infinity);
                                    return Column(
                                      crossAxisAlignment: CrossAxisAlignment.stretch,
                                      children: [
                                        // Map area sized explicitly to fit the footer
                                        SizedBox(
                                          height: mapHeight,
                                          child: ClipRRect(
                                            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                                            child: MapEmbed(
                                              points: waypoints.map((w) {
                                                return {
                                                  'lat': (w['lat'] ?? w['latitude'] ?? 0.0),
                                                  'lon': (w['lon'] ?? w['longitude'] ?? w['lng'] ?? 0.0),
                                                  'name': w['name'] ?? '',
                                                };
                                              }).toList(),
                                            ),
                                          ),
                                        ),
                                        Container(
                                          height: footerHeight,
                                          padding: const EdgeInsets.all(12.0),
                                          decoration: BoxDecoration(
                                            border: Border.all(color: Colors.grey.shade300),
                                            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
                                          ),
                                          child: Row(
                                            crossAxisAlignment: CrossAxisAlignment.center,
                                            children: [
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment: CrossAxisAlignment.start,
                                                  children: [
                                                    Text(name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                                                    const SizedBox(height: 6),
                                                    Row(children: [
                                                      Icon(Icons.calendar_today, size: 14, color: Colors.grey[600]),
                                                      const SizedBox(width: 6),
                                                      Text(created != null ? _prettyDate(created) : '—', style: TextStyle(color: Colors.grey[700])),
                                                    ]),
                                                  ],
                                                ),
                                              ),
                                              Column(
                                                crossAxisAlignment: CrossAxisAlignment.end,
                                                children: [
                                                  Chip(label: Text('${waypoints.length} stops')),
                                                  const SizedBox(height: 6),
                                                  Text('${totalKm.toStringAsFixed(1)} km', style: const TextStyle(fontWeight: FontWeight.w600)),
                                                ],
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    );
                                  }),
                                  Positioned(
                                    top: 8,
                                    right: 8,
                                    child: PopupMenuButton<String>(
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
                                            ScaffoldMessenger.of(
                                              context,
                                            ).showSnackBar(
                                              const SnackBar(
                                                content: Text('Trip deleted'),
                                              ),
                                            );
                                          }
                                        }
                                      },
                                      itemBuilder:
                                          (_) => [
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
                    );
                  },
                ),
      ),
    );
  }
}
