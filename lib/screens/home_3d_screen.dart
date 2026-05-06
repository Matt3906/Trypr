import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'package:trypr/widgets/top_taskbar.dart';
import 'package:trypr/widgets/globe_widget.dart';
import 'package:trypr/screens/trip_detail_screen.dart';

class Home3DScreen extends StatefulWidget {
  const Home3DScreen({super.key});

  @override
  State<Home3DScreen> createState() => _Home3DScreenState();
}

class _Home3DScreenState extends State<Home3DScreen>
    with TickerProviderStateMixin {
  Map<String, dynamic>? _selectedTrip;
  bool _showOpenButton = false;
  late AnimationController _buttonAnimController;
  late Animation<double> _buttonAnimation;

  @override
  void initState() {
    super.initState();
    _buttonAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _buttonAnimation = CurvedAnimation(
      parent: _buttonAnimController,
      curve: Curves.easeOutBack,
    );
  }

  @override
  void dispose() {
    _buttonAnimController.dispose();
    super.dispose();
  }

  void _onTripSelected(Map<String, dynamic> trip) {
    setState(() {
      _selectedTrip = trip;
      _showOpenButton = false;
    });

    // Show the open button after the camera animation
    Future.delayed(const Duration(milliseconds: 1600), () {
      if (mounted && _selectedTrip?['id'] == trip['id']) {
        setState(() => _showOpenButton = true);
        _buttonAnimController.forward(from: 0);
      }
    });
  }

  void _clearSelection() {
    setState(() {
      _selectedTrip = null;
      _showOpenButton = false;
    });
    _buttonAnimController.reset();
  }

  void _openTrip() async {
    if (_selectedTrip == null) return;

    final tripId = _selectedTrip!['id']?.toString();
    final userId = _selectedTrip!['userId']?.toString();

    if (tripId == null || userId == null) return;

    // Load the trip data from Firestore
    final doc =
        await FirebaseFirestore.instance
            .collection('users')
            .doc(userId)
            .collection('trips')
            .doc(tripId)
            .get();

    if (!mounted) return;
    if (!doc.exists) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TripDetailScreen(docId: tripId, data: doc.data() ?? {}),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final overlayInset = viewportWidth < 640 ? 16.0 : 32.0;
    final openButtonBottom = viewportWidth < 640 ? 128.0 : 100.0;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: const TopTaskbar(dockProgress: 1.0),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF0a0a1a), Color(0xFF1a1a2e), Color(0xFF16213e)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // Globe section (takes most of the screen)
              Expanded(
                child: Stack(
                  children: [
                    // 3D Globe
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                        stream:
                            user == null
                                ? const Stream.empty()
                                : FirebaseFirestore.instance
                                    .collection('users')
                                    .doc(user.uid)
                                    .collection('trips')
                                    .orderBy('createdAt', descending: true)
                                    .limit(10)
                                    .snapshots(),
                        builder: (context, snapshot) {
                          final trips = <Map<String, dynamic>>[];

                          if (snapshot.hasData) {
                            for (final doc in snapshot.data!.docs) {
                              final data = doc.data();
                              final waypoints = <Map<String, dynamic>>[];

                              final wps = data['waypoints'];
                              if (wps is List) {
                                for (final w in wps) {
                                  if (w is Map) {
                                    final lat = w['lat'];
                                    final lon = w['lon'];
                                    if (lat is num && lon is num) {
                                      waypoints.add({
                                        'lat': lat.toDouble(),
                                        'lon': lon.toDouble(),
                                        'name': (w['name'] ?? '').toString(),
                                      });
                                    }
                                  }
                                }
                              }

                              trips.add({
                                'id': doc.id,
                                'userId': user?.uid ?? '',
                                'title':
                                    (data['title'] ?? 'Untitled Trip')
                                        .toString(),
                                'waypoints': waypoints,
                                'stops': waypoints.length,
                                'distance': data['totalDistance'],
                                'createdAt': data['createdAt'],
                                'startDate': data['startDate'],
                              });
                            }
                          }

                          return GlobeWidget(
                            trips: trips,
                            selectedTrip: _selectedTrip,
                            onTripSelected: _onTripSelected,
                          );
                        },
                      ),
                    ),

                    // "Open & Edit Trip" floating button
                    if (_showOpenButton && _selectedTrip != null)
                      Positioned(
                        bottom: openButtonBottom,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: ScaleTransition(
                            scale: _buttonAnimation,
                            child: _GlassmorphicButton(
                              label: 'Open & Edit Trip',
                              icon: Icons.edit_road,
                              onTap: _openTrip,
                            ),
                          ),
                        ),
                      ),

                    // Clear selection button
                    if (_selectedTrip != null)
                      Positioned(
                        top: 16,
                        right: overlayInset,
                        child: _GlassmorphicIconButton(
                          icon: Icons.close,
                          onTap: _clearSelection,
                        ),
                      ),

                    // Selected trip info overlay
                    if (_selectedTrip != null)
                      Positioned(
                        top: 16,
                        left: overlayInset,
                        child: _GlassmorphicChip(
                          text: _selectedTrip!['title'] ?? 'Trip',
                        ),
                      ),
                  ],
                ),
              ),

              // Saved Trips dock at bottom
              _SavedTripsDock(
                selectedTripId: _selectedTrip?['id'],
                onTripSelected: _onTripSelected,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Horizontal scrolling "Saved Trips" dock with glassmorphism cards
class _SavedTripsDock extends StatelessWidget {
  final String? selectedTripId;
  final void Function(Map<String, dynamic> trip) onTripSelected;

  const _SavedTripsDock({
    required this.selectedTripId,
    required this.onTripSelected,
  });

  String _formatDistance(double? km) {
    if (km == null) return '';
    if (km < 1) return '${(km * 1000).round()} m';
    return '${km.toStringAsFixed(0)} km';
  }

  String _formatDate(dynamic timestamp) {
    if (timestamp == null) return '';
    DateTime date;
    if (timestamp is Timestamp) {
      date = timestamp.toDate();
    } else if (timestamp is String) {
      date = DateTime.tryParse(timestamp) ?? DateTime.now();
    } else {
      return '';
    }
    return DateFormat('MMM d, y').format(date);
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final dockHeight = viewportWidth < 640 ? 184.0 : 160.0;
    final dockHorizontalPadding = viewportWidth < 640 ? 12.0 : 16.0;
    final cardWidth =
        viewportWidth < 420 ? 148.0 : (viewportWidth < 600 ? 164.0 : 180.0);

    return Container(
      height: dockHeight,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black.withValues(alpha: 0.3)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: dockHorizontalPadding + 8,
              vertical: 8,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.bookmark_outline,
                  size: 16,
                  color: Colors.white.withValues(alpha: 0.6),
                ),
                const SizedBox(width: 8),
                Text(
                  'Saved Trips',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child:
                user == null
                    ? Center(
                      child: Text(
                        'Sign in to see your trips',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 13,
                        ),
                      ),
                    )
                    : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream:
                          FirebaseFirestore.instance
                              .collection('users')
                              .doc(user.uid)
                              .collection('trips')
                              .orderBy('createdAt', descending: true)
                              .limit(10)
                              .snapshots(),
                      builder: (context, snapshot) {
                        if (!snapshot.hasData) {
                          return const Center(
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white54,
                            ),
                          );
                        }

                        final docs = snapshot.data!.docs;

                        if (docs.isEmpty) {
                          return Center(
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.add_circle_outline,
                                  color: Colors.white.withValues(alpha: 0.4),
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'No trips yet — start planning!',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.5),
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          );
                        }

                        return ListView.builder(
                          scrollDirection: Axis.horizontal,
                          padding: EdgeInsets.symmetric(
                            horizontal: dockHorizontalPadding,
                          ),
                          itemCount: docs.length,
                          itemBuilder: (context, index) {
                            final doc = docs[index];
                            final data = doc.data();

                            final waypoints = <Map<String, dynamic>>[];
                            final wps = data['waypoints'];
                            if (wps is List) {
                              for (final w in wps) {
                                if (w is Map) {
                                  final lat = w['lat'];
                                  final lon = w['lon'];
                                  if (lat is num && lon is num) {
                                    waypoints.add({
                                      'lat': lat.toDouble(),
                                      'lon': lon.toDouble(),
                                      'name': (w['name'] ?? '').toString(),
                                    });
                                  }
                                }
                              }
                            }

                            final trip = {
                              'id': doc.id,
                              'userId': user.uid,
                              'title':
                                  (data['title'] ?? 'Untitled Trip').toString(),
                              'waypoints': waypoints,
                              'stops': waypoints.length,
                              'distance': data['totalDistance'],
                              'createdAt': data['createdAt'],
                              'startDate': data['startDate'],
                            };

                            final isSelected = selectedTripId == doc.id;

                            return _TripCard(
                              width: cardWidth,
                              title: trip['title'] as String,
                              stops: trip['stops'] as int,
                              distance: _formatDistance(
                                trip['distance'] is num
                                    ? (trip['distance'] as num).toDouble()
                                    : null,
                              ),
                              date: _formatDate(
                                trip['startDate'] ?? trip['createdAt'],
                              ),
                              isSelected: isSelected,
                              onTap: () => onTripSelected(trip),
                            );
                          },
                        );
                      },
                    ),
          ),
        ],
      ),
    );
  }
}

/// Glassmorphism trip card
class _TripCard extends StatefulWidget {
  final double width;
  final String title;
  final int stops;
  final String distance;
  final String date;
  final bool isSelected;
  final VoidCallback onTap;

  const _TripCard({
    required this.width,
    required this.title,
    required this.stops,
    required this.distance,
    required this.date,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_TripCard> createState() => _TripCardState();
}

class _TripCardState extends State<_TripCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: widget.width,
          margin: const EdgeInsets.only(right: 12, bottom: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color:
                  widget.isSelected
                      ? const Color(0xFF00ff88)
                      : Colors.white.withValues(alpha: _isHovered ? 0.3 : 0.15),
              width: widget.isSelected ? 2 : 1,
            ),
            boxShadow:
                widget.isSelected
                    ? [
                      BoxShadow(
                        color: const Color(0xFF00ff88).withValues(alpha: 0.3),
                        blurRadius: 20,
                        spreadRadius: -5,
                      ),
                    ]
                    : null,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.white.withValues(
                        alpha: widget.isSelected ? 0.15 : 0.08,
                      ),
                      Colors.white.withValues(
                        alpha: widget.isSelected ? 0.08 : 0.03,
                      ),
                    ],
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.95),
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(
                          Icons.place_outlined,
                          size: 12,
                          color: Colors.white.withValues(alpha: 0.5),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${widget.stops} stops',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.6),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    if (widget.distance.isNotEmpty)
                      Row(
                        children: [
                          Icon(
                            Icons.straighten,
                            size: 12,
                            color: Colors.white.withValues(alpha: 0.5),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            widget.distance,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.6),
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    const Spacer(),
                    if (widget.date.isNotEmpty)
                      Text(
                        widget.date,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.4),
                          fontSize: 10,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Glassmorphism floating button
class _GlassmorphicButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  const _GlassmorphicButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  State<_GlassmorphicButton> createState() => _GlassmorphicButtonState();
}

class _GlassmorphicButtonState extends State<_GlassmorphicButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(50),
            border: Border.all(
              color: const Color(
                0xFF00ff88,
              ).withValues(alpha: _isHovered ? 1 : 0.6),
              width: 2,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(
                  0xFF00ff88,
                ).withValues(alpha: _isHovered ? 0.4 : 0.2),
                blurRadius: _isHovered ? 30 : 20,
                spreadRadius: -5,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(50),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      const Color(
                        0xFF00ff88,
                      ).withValues(alpha: _isHovered ? 0.3 : 0.15),
                      const Color(
                        0xFF00ff88,
                      ).withValues(alpha: _isHovered ? 0.15 : 0.05),
                    ],
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(widget.icon, color: const Color(0xFF00ff88), size: 20),
                    const SizedBox(width: 10),
                    Text(
                      widget.label,
                      style: const TextStyle(
                        color: Color(0xFF00ff88),
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Small glassmorphic icon button
class _GlassmorphicIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _GlassmorphicIconButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(50),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.1),
              border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
            ),
            child: Icon(
              icon,
              color: Colors.white.withValues(alpha: 0.8),
              size: 18,
            ),
          ),
        ),
      ),
    );
  }
}

/// Glassmorphic info chip
class _GlassmorphicChip extends StatelessWidget {
  final String text;

  const _GlassmorphicChip({required this.text});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: Colors.white.withValues(alpha: 0.1),
            border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.map_outlined,
                size: 14,
                color: Colors.white.withValues(alpha: 0.8),
              ),
              const SizedBox(width: 8),
              Text(
                text,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.9),
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
