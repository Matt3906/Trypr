import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:trypr/screens/verified_trip_map_screen.dart';
import 'package:trypr/widgets/top_taskbar.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ScrollController _scrollController = ScrollController();
  // Continuous progress value [0..1] representing dock animation progress.
  double _dockProgress = 0.0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(() {
      if (!mounted) return;
      // Start and end offsets (relative to viewport height) where the dock transition occurs.
      final h = MediaQuery.of(context).size.height;
      final start = h * 0.4; // begin transition when ~40% scrolled
      final end = h * 0.75; // fully docked by ~75%
      final raw = (_scrollController.offset - start) / (end - start);
      final progress = raw.clamp(0.0, 1.0);
      if ((progress - _dockProgress).abs() > 0.01) {
        setState(() => _dockProgress = progress);
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  // Verified trip previews use a dedicated widget to match My Trips sizing
  // and support cycling through uploaded photos.

  Widget _buildReviewCard(BuildContext context, String user, String text) {
    return Container(
      margin: const EdgeInsets.only(right: 12, bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(color: const Color.fromRGBO(0, 0, 0, 0.06), blurRadius: 6),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(child: Text(user[0].toUpperCase())),
              const SizedBox(width: 8),
              Text(user, style: Theme.of(context).textTheme.bodyMedium),
              const Spacer(),
              Row(
                children: List.generate(
                  5,
                  (i) => const Icon(Icons.star, size: 14, color: Colors.amber),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(text, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: TopTaskbar(dockProgress: _dockProgress),
      extendBodyBehindAppBar: true,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isNarrow = constraints.maxWidth < 420;
          // The AppBar is drawn on top of the hero (extendBodyBehindAppBar = true),
          // so increase the hero height by the app bar height so the visible
          // portion fills the full viewport without the next section peeking in.
          const double appBarHeight = 64.0;
          final heroHeight = MediaQuery.of(context).size.height + appBarHeight;
          return SingleChildScrollView(
            controller: _scrollController,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Fullscreen hero image (below the transparent appbar)
                SizedBox(
                  height: heroHeight,
                  child: Stack(
                    fit: StackFit.expand,
                    alignment: Alignment.center,
                    children: [
                      Image.asset(
                        'images/mainScreenPic.jpg',
                        fit: BoxFit.cover,
                      ),
                      Container(color: const Color.fromRGBO(0, 0, 0, 0.35)),
                      // Centered big logo (image with text fallback) — animate with dock progress
                      Center(
                        child: Transform.translate(
                          offset: Offset(0, -30 * _dockProgress),
                          child: Transform.scale(
                            scale: 1.0 - (0.22 * _dockProgress),
                            child: Opacity(
                              opacity: (1.0 - _dockProgress).clamp(0.0, 1.0),
                              child: Image.asset(
                                'images/TryprLogo_White.png',
                                width:
                                    constraints.maxWidth > 800
                                        ? 260
                                        : (isNarrow ? 140 : 160),
                                fit: BoxFit.contain,
                                errorBuilder:
                                    (ctx, err, st) => Text(
                                      'Trypr',
                                      style: GoogleFonts.poppins(
                                        color: Colors.white,
                                        fontSize:
                                            constraints.maxWidth > 800
                                                ? 72
                                                : 44,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 1.2,
                                      ),
                                    ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // White content area with rounded top corners
                Container(
                  width: double.infinity,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(24),
                    ),
                  ),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: isNarrow ? 16.0 : 20.0,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Famous / Recommended Trips',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 12),
                        // Famous trips == Verified Trips
                        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                          stream:
                              FirebaseFirestore.instance
                                  .collection('verifiedTrips')
                                  .orderBy('createdAt', descending: true)
                                  .limit(3)
                                  .snapshots(),
                          builder: (ctx, snap) {
                            if (snap.hasError) {
                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                child: Text(
                                  'Famous trips failed to load: ${snap.error}',
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(color: Colors.black54),
                                ),
                              );
                            }
                            if (!snap.hasData) {
                              return const Padding(
                                padding: EdgeInsets.symmetric(vertical: 24),
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              );
                            }

                            final docs = snap.data!.docs;
                            if (docs.isEmpty) {
                              return const Padding(
                                padding: EdgeInsets.symmetric(vertical: 12),
                                child: Text(
                                  'No famous trips yet — check back soon.',
                                ),
                              );
                            }

                            return LayoutBuilder(
                              builder: (ctx2, box) {
                                final cards =
                                    docs.map((d) {
                                      final data = d.data();
                                      final title =
                                          (data['title'] ?? '').toString();
                                      final cover =
                                          (data['coverImage'] ?? '').toString();
                                      final photosRaw = data['photos'];
                                      final photos =
                                          photosRaw is List
                                              ? photosRaw
                                                  .map((e) => e.toString())
                                                  .where(
                                                    (s) => s.trim().isNotEmpty,
                                                  )
                                                  .toList()
                                              : <String>[];
                                      final images = <String>[
                                        if (cover.trim().isNotEmpty)
                                          cover.trim(),
                                        ...photos.where(
                                          (p) =>
                                              p.trim().isNotEmpty &&
                                              p.trim() != cover.trim(),
                                        ),
                                      ];

                                      final daysRaw =
                                          data['recommendedDays'] ??
                                          data['days'];
                                      final days =
                                          daysRaw is num
                                              ? daysRaw.toInt()
                                              : int.tryParse(
                                                daysRaw?.toString() ?? '',
                                              );

                                      int? stops;
                                      final wps = data['waypoints'];
                                      if (wps is List) {
                                        stops = wps.length;
                                      }

                                      final points = <Map<String, dynamic>>[];
                                      if (wps is List) {
                                        for (final w in wps) {
                                          if (w is Map) {
                                            final lat = w['lat'];
                                            final lon = w['lon'];
                                            if (lat is num && lon is num) {
                                              points.add({
                                                'name':
                                                    (w['name'] ?? '')
                                                        .toString(),
                                                'lat': lat.toDouble(),
                                                'lon': lon.toDouble(),
                                              });
                                            }
                                          }
                                        }
                                      }

                                      final subtitle =
                                          days != null
                                              ? '$days days'
                                              : 'Verified trip';
                                      final subtitleWithStops =
                                          stops != null
                                              ? '$subtitle • $stops stops'
                                              : subtitle;

                                      return _VerifiedTripPreviewCard(
                                        key: ValueKey(d.id),
                                        title: title,
                                        subtitle: subtitleWithStops,
                                        images:
                                            images.isNotEmpty
                                                ? images
                                                : const [
                                                  'images/mainScreenPic.jpg',
                                                ],
                                        onTap:
                                            points.isEmpty
                                                ? null
                                                : () {
                                                  Navigator.of(context).push(
                                                    VerifiedTripMapScreen.route(
                                                      title: title,
                                                      points: points,
                                                    ),
                                                  );
                                                },
                                      );
                                    }).toList();

                                if (box.maxWidth >= 900 && cards.length == 3) {
                                  return Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(child: cards[0]),
                                      const SizedBox(width: 12),
                                      Expanded(child: cards[1]),
                                      const SizedBox(width: 12),
                                      Expanded(child: cards[2]),
                                    ],
                                  );
                                }

                                return Column(
                                  children: [
                                    for (final c in cards) ...[
                                      c,
                                      const SizedBox(height: 12),
                                    ],
                                  ],
                                );
                              },
                            );
                          },
                        ),

                        const SizedBox(height: 24),

                        const Text(
                          'Features',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: const [
                            Text(
                              '• A trip planner built for real, rigorous roadtrip planning — beyond point‑A to point‑B navigation.',
                            ),
                            Text(
                              '• Collaborate with friends: shared trips, shared packing lists, and a built‑in group chat.',
                            ),
                            Text(
                              '• Plan day-by-day with arrival/departure dates and itinerary structure that stays clean.',
                            ),
                            Text(
                              '• Make packing lists together so the whole group stays ready.',
                            ),
                            Text(
                              '• Coming next: hiking/backpacking, equestrian, portaging, and bikepacking trips.',
                            ),
                          ],
                        ),

                        const SizedBox(height: 24),

                        const Text(
                          'Reviews',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 12),
                        // Three-up reviews (responsive)
                        LayoutBuilder(
                          builder: (ctx, box) {
                            if (box.maxWidth >= 900) {
                              return Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: _buildReviewCard(
                                      context,
                                      'Alice',
                                      'Amazing trip — loved every moment!',
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: _buildReviewCard(
                                      context,
                                      'Bob',
                                      'Well organized and beautiful scenery.',
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: _buildReviewCard(
                                      context,
                                      'Sam',
                                      'Would recommend to friends.',
                                    ),
                                  ),
                                ],
                              );
                            } else {
                              return Column(
                                children: [
                                  _buildReviewCard(
                                    context,
                                    'Alice',
                                    'Amazing trip — loved every moment!',
                                  ),
                                  const SizedBox(height: 12),
                                  _buildReviewCard(
                                    context,
                                    'Bob',
                                    'Well organized and beautiful scenery.',
                                  ),
                                  const SizedBox(height: 12),
                                  _buildReviewCard(
                                    context,
                                    'Sam',
                                    'Would recommend to friends.',
                                  ),
                                ],
                              );
                            }
                          },
                        ),

                        const SizedBox(height: 28),
                      ],
                    ),
                  ),
                ),

                Container(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  color: Colors.grey.shade100,
                  child: Center(
                    child: Text(
                      '© Trypr 2025 all rights reserved',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _VerifiedTripPreviewCard extends StatefulWidget {
  final String title;
  final String subtitle;
  final List<String> images;
  final VoidCallback? onTap;

  const _VerifiedTripPreviewCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.images,
    this.onTap,
  });

  @override
  State<_VerifiedTripPreviewCard> createState() =>
      _VerifiedTripPreviewCardState();
}

class _VerifiedTripPreviewCardState extends State<_VerifiedTripPreviewCard> {
  int _idx = 0;

  Widget _imageFromSource(String src) {
    final s = src.trim();
    if (s.isEmpty) return const SizedBox.shrink();
    if (s.startsWith('data:image')) {
      if (kIsWeb) {
        return Image.network(
          s,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
        );
      }
      try {
        final bytes = base64Decode(s.split(',').last);
        return Image.memory(
          bytes,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
        );
      } catch (_) {
        return const SizedBox.shrink();
      }
    }
    if (s.startsWith('http')) {
      return Image.network(
        s,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      );
    }
    return Image.asset(
      s,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final images =
        widget.images.isNotEmpty
            ? widget.images
            : const ['images/mainScreenPic.jpg'];
    final clampedIdx = (_idx % images.length);
    final current = images[clampedIdx];

    return Container(
      margin: const EdgeInsets.only(right: 12, bottom: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Colors.white,
        boxShadow: [
          BoxShadow(color: const Color.fromRGBO(0, 0, 0, 0.08), blurRadius: 8),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            child: AspectRatio(
              aspectRatio: 16 / 11,
              child: LayoutBuilder(
                builder: (ctx, constraints) {
                  final available =
                      constraints.maxHeight.isFinite
                          ? constraints.maxHeight
                          : 320.0;
                  final footerHeight = (available * 0.28).clamp(56.0, 140.0);
                  final imageHeight = (available - footerHeight).clamp(
                    40.0,
                    double.infinity,
                  );

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        height: imageHeight,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            _imageFromSource(current),
                            Container(
                              color: const Color.fromRGBO(0, 0, 0, 0.06),
                            ),
                            if (images.length > 1)
                              Positioned(
                                top: 10,
                                right: 10,
                                child: Material(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(16),
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(16),
                                    onTap:
                                        () => setState(() => _idx = _idx + 1),
                                    child: const Padding(
                                      padding: EdgeInsets.all(8),
                                      child: Icon(
                                        Icons.navigate_next,
                                        color: Colors.white,
                                        size: 18,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      Container(
                        height: footerHeight,
                        padding: const EdgeInsets.all(12.0),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey.shade300),
                          color: Colors.white,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              widget.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              widget.subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: Colors.black54),
                            ),
                          ],
                        ),
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
