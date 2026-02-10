import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:trypr/models/trip_model.dart';
import 'package:trypr/services/firestore_service.dart';
import 'package:trypr/screens/verified_trip_map_screen.dart';
import 'package:trypr/theme/app_theme.dart';
import 'package:trypr/widgets/top_taskbar.dart';
import 'package:trypr/widgets/web_interceptor.dart';
import 'dart:convert';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show kIsWeb, kDebugMode;
import 'package:intl/intl.dart';
import 'package:trypr/utils/platform_view_registry.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  final ScrollController _scrollController = ScrollController();
  // Continuous progress value [0..1] representing dock animation progress.
  double _dockProgress = 0.0;

  // Globe state
  Map<String, dynamic>? _selectedTrip;
  bool _showOpenButton = false;
  late AnimationController _buttonAnimController;
  late Animation<double> _buttonAnimation;
  static const String _mapViewType = 'trypr-3d-map-view';
  bool _mapFactoryRegistered = false;
  bool _mapLoaded = false;
  bool _globeReady = false;
  html.IFrameElement? _mapIFrame;

  @override
  void initState() {
    super.initState();

    // Button animation for globe
    _buttonAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _buttonAnimation = CurvedAnimation(
      parent: _buttonAnimController,
      curve: Curves.easeOutBack,
    );

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
    _initializeMapFrame();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _buttonAnimController.dispose();
    super.dispose();
  }

  // Globe trip selection handlers
  void _onTripSelected(Map<String, dynamic> trip) {
    setState(() {
      _selectedTrip = trip;
      _showOpenButton = false;
    });

    Future.delayed(const Duration(milliseconds: 1600), () {
      if (mounted && _selectedTrip?['id'] == trip['id']) {
        setState(() => _showOpenButton = true);
        _buttonAnimController.forward(from: 0);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _sendTripsToMap();
    });
  }

  void _clearSelection() {
    setState(() {
      _selectedTrip = null;
      _showOpenButton = false;
    });
    _buttonAnimController.reset();
    // Clear the route from the globe
    if (kIsWeb && _mapIFrame?.contentWindow != null) {
      _mapIFrame!.contentWindow!.postMessage({'type': 'clearRoute'}, '*');
    }
  }

  void _openTrip() {
    if (_selectedTrip == null) return;
    final tripId = _selectedTrip!['id'] as String?;
    if (tripId == null) return;
    Navigator.of(context).pushNamed('/trip-builder', arguments: tripId);
  }

  void _initializeMapFrame() {
    if (!kIsWeb || _mapFactoryRegistered) return;
    final earthUrl =
        kDebugMode
            ? 'http://localhost:6767/earth/?embed=true'
            : 'earth/index.html?embed=true';
    _mapIFrame =
        html.IFrameElement()
          ..src = earthUrl
          ..style.border = '0'
          ..style.width = '100%'
          ..style.height = '100%'
          ..style.display = 'block'
          ..title = 'Trypr 3D Globe'
          ..allow = 'fullscreen';
    _mapIFrame!.onLoad.listen((_) => _handleMapIFrameLoaded());

    // Listen for postMessage events from the Earth iframe (map_ready, etc.)
    html.window.addEventListener('message', (html.Event event) {
      if (event is html.MessageEvent) {
        final data = event.data;
        if (data is Map && data['type'] == 'map_ready') {
          if (!_globeReady) {
            _globeReady = true;
            // The 3D globe is now ready — send the route if a trip is selected
            _sendTripsToMap();
          }
        }
      }
    });

    if (kIsWeb) {
      registerHtmlElementViewFactory(_mapViewType, (int viewId) => _mapIFrame!);
    }
    _mapFactoryRegistered = true;
  }

  void _handleMapIFrameLoaded() {
    if (_mapLoaded) return;
    _mapLoaded = true;
    _sendTestPing();
    // Don't send route yet — wait for 'map_ready' from the Earth 3D globe
  }

  void _sendTestPing() {
    if (!kIsWeb || _mapIFrame?.contentWindow == null) return;
    _mapIFrame!.contentWindow!.postMessage({
      'type': 'flutter_ping',
      'timestamp': DateTime.now().toIso8601String(),
    }, '*');
  }

  void _sendTripsToMap() {
    if (!kIsWeb ||
        _mapIFrame?.contentWindow == null ||
        !_globeReady ||
        _selectedTrip == null)
      return;

    final trip = _selectedTrip!;
    final waypoints = trip['waypoints'] as List<dynamic>? ?? [];

    if (waypoints.isEmpty) {
      _mapIFrame!.contentWindow!.postMessage({'type': 'clearRoute'}, '*');
      return;
    }

    // Extract origin, destination, and waypoint stops
    final origin =
        waypoints.isNotEmpty
            ? {
              'lat': (waypoints[0] as Map)['lat'] as num,
              'lng': (waypoints[0] as Map)['lon'] as num,
              'name': (waypoints[0] as Map)['name'] ?? '',
            }
            : null;

    final destination =
        waypoints.length > 1
            ? {
              'lat': (waypoints[waypoints.length - 1] as Map)['lat'] as num,
              'lng': (waypoints[waypoints.length - 1] as Map)['lon'] as num,
              'name': (waypoints[waypoints.length - 1] as Map)['name'] ?? '',
            }
            : origin;

    final middleWaypoints =
        waypoints.length > 2
            ? [
              for (int i = 1; i < waypoints.length - 1; i++)
                {
                  'lat': (waypoints[i] as Map)['lat'] as num,
                  'lng': (waypoints[i] as Map)['lon'] as num,
                  'name': (waypoints[i] as Map)['name'] ?? '',
                },
            ]
            : <Map<String, dynamic>>[];

    if (origin == null || destination == null) return;

    // Send route message to iframe
    String tripDates = '';
    try {
      if (trip['startDate'] is Timestamp) {
        tripDates = DateFormat(
          'MMM d',
        ).format((trip['startDate'] as Timestamp).toDate());
      }
    } catch (_) {}

    final payload = {
      'type': 'route',
      'origin': origin,
      'destination': destination,
      'waypoints': middleWaypoints,
      'tripInfo': {
        'name': trip['title'] ?? 'Trip',
        'dates': tripDates,
        'distance': trip['distance'] is num ? trip['distance'] : null,
        'stops': waypoints.length,
      },
    };

    _mapIFrame!.contentWindow!.postMessage(payload, '*');

    // Also fly the globe to the trip region so there's visible feedback
    _mapIFrame!.contentWindow!.postMessage({
      'type': 'flyTo',
      'lat': origin['lat'],
      'lng': origin['lng'],
      'range': waypoints.length > 1 ? 4000000 : 2000000,
    }, '*');
  }

  Widget _buildMapView() {
    if (!kIsWeb) {
      return Container(
        color: TryprColors.surfaceVariant,
        child: const Center(
          child: Text(
            'Trypr 3D map is available in the browser.',
            style: TextStyle(color: Colors.white70),
          ),
        ),
      );
    }
    if (!_mapFactoryRegistered) {
      return const Center(child: CircularProgressIndicator());
    }
    return HtmlElementView(viewType: _mapViewType);
  }

  // Verified trip previews use a dedicated widget to match My Trips sizing
  // and support cycling through uploaded photos.

  Widget _buildReviewCard(BuildContext context, String user, String text) {
    return Container(
      margin: const EdgeInsets.only(
        right: TryprSpacing.md,
        bottom: TryprSpacing.md,
      ),
      padding: const EdgeInsets.all(TryprSpacing.lg),
      decoration: BoxDecoration(
        color: TryprColors.surface,
        borderRadius: BorderRadius.circular(TryprRadius.lg),
        boxShadow: TryprColors.softShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [TryprColors.primary, TryprColors.primaryLight],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    user[0].toUpperCase(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: TryprSpacing.md),
              Text(
                user,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  color: TryprColors.textPrimary,
                ),
              ),
              const Spacer(),
              Row(
                children: List.generate(
                  5,
                  (i) => const Icon(
                    Icons.star_rounded,
                    size: 16,
                    color: Color(0xFFFBBF24),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: TryprSpacing.md),
          Text(
            text,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: TryprColors.textSecondary),
          ),
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
                // 3D Globe hero section – ClipRect prevents the iframe
                // from visually overflowing into the AppBar during scroll.
                ClipRect(
                  child: Container(
                    height: heroHeight,
                    decoration: const BoxDecoration(
                      // Match the Earth app's light background
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color(0xFFF8FAFC),
                          Color(0xFFE2E8F0),
                          Color(0xFFF1F5F9),
                        ],
                      ),
                    ),
                    child: Stack(
                      children: [
                        // 3D Globe
                        Positioned.fill(child: _buildMapView()),

                        // Transparent barrier over the AppBar area so the
                        // taskbar receives pointer events above the iframe.
                        if (kIsWeb)
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            height:
                                appBarHeight +
                                MediaQuery.of(context).padding.top,
                            child: WebInterceptor(
                              child: const SizedBox.expand(),
                            ),
                          ),

                        // "Open & Edit Trip" floating button
                        if (_showOpenButton && _selectedTrip != null)
                          Positioned(
                            bottom: 200,
                            left: 0,
                            right: 0,
                            child: Center(
                              child: ScaleTransition(
                                scale: _buttonAnimation,
                                child: WebInterceptor(
                                  child: Material(
                                    color: Colors.transparent,
                                    child: _GlassmorphicButton(
                                      label: 'Open & Edit Trip',
                                      icon: Icons.edit_road,
                                      onTap: _openTrip,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),

                        // Clear selection button
                        if (_selectedTrip != null)
                          Positioned(
                            top: appBarHeight + 16,
                            right: 32,
                            child: WebInterceptor(
                              child: _GlassmorphicIconButton(
                                icon: Icons.close,
                                onTap: _clearSelection,
                              ),
                            ),
                          ),

                        // Selected trip info overlay
                        if (_selectedTrip != null)
                          Positioned(
                            top: appBarHeight + 16,
                            left: 32,
                            child: WebInterceptor(
                              child: _GlassmorphicChip(
                                text: _selectedTrip!['title'] ?? 'Trip',
                              ),
                            ),
                          ),

                        // Saved Trips dock at bottom of globe section
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: WebInterceptor(
                            child: _SavedTripsDock(
                              selectedTripId: _selectedTrip?['id'],
                              onTripSelected: _onTripSelected,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // White content area with rounded top corners
                Container(
                  width: double.infinity,
                  decoration: const BoxDecoration(
                    color: TryprColors.background,
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(TryprRadius.xxl),
                    ),
                  ),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: isNarrow ? TryprSpacing.lg : TryprSpacing.xxl,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: TryprSpacing.xxl),
                        const SectionHeader(
                          title: 'Recommended Trips',
                          seeAllText: 'View all',
                        ),
                        const SizedBox(height: TryprSpacing.lg),
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

                        const SizedBox(height: TryprSpacing.xxl),

                        // Features section
                        SoftCard(
                          padding: const EdgeInsets.all(TryprSpacing.xl),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(
                                      TryprSpacing.sm,
                                    ),
                                    decoration: BoxDecoration(
                                      color: TryprColors.primary.withOpacity(
                                        0.1,
                                      ),
                                      borderRadius: BorderRadius.circular(
                                        TryprRadius.md,
                                      ),
                                    ),
                                    child: const Icon(
                                      Icons.auto_awesome,
                                      color: TryprColors.primary,
                                      size: 20,
                                    ),
                                  ),
                                  const SizedBox(width: TryprSpacing.md),
                                  const Text(
                                    'Features',
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w600,
                                      color: TryprColors.textPrimary,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: TryprSpacing.lg),
                              _FeatureItem(
                                icon: Icons.map_outlined,
                                text:
                                    'A trip planner built for real, rigorous roadtrip planning — beyond point‑A to point‑B navigation.',
                              ),
                              _FeatureItem(
                                icon: Icons.group_outlined,
                                text:
                                    'Collaborate with friends: shared trips, shared packing lists, and a built‑in group chat.',
                              ),
                              _FeatureItem(
                                icon: Icons.calendar_today_outlined,
                                text:
                                    'Plan day-by-day with arrival/departure dates and itinerary structure that stays clean.',
                              ),
                              _FeatureItem(
                                icon: Icons.checklist_outlined,
                                text:
                                    'Make packing lists together so the whole group stays ready.',
                              ),
                              _FeatureItem(
                                icon: Icons.hiking,
                                text:
                                    'Coming next: hiking/backpacking, equestrian, portaging, and bikepacking trips.',
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: TryprSpacing.xxl),

                        const SectionHeader(title: 'Reviews'),
                        const SizedBox(height: TryprSpacing.lg),
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

                        const SizedBox(height: TryprSpacing.xxxl),
                      ],
                    ),
                  ),
                ),

                Container(
                  padding: const EdgeInsets.symmetric(
                    vertical: TryprSpacing.xl,
                  ),
                  color: TryprColors.surfaceVariant,
                  child: Center(
                    child: Text(
                      '© Trypr 2026 — All rights reserved',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: TryprColors.textTertiary,
                      ),
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

class _FeatureItem extends StatelessWidget {
  final IconData icon;
  final String text;

  const _FeatureItem({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: TryprSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: TryprColors.primary),
          const SizedBox(width: TryprSpacing.md),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 14,
                color: TryprColors.textSecondary,
                height: 1.5,
              ),
            ),
          ),
        ],
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
  bool _isHovered = false;

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

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedScale(
        duration: const Duration(milliseconds: 200),
        scale: _isHovered ? 1.02 : 1.0,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.only(
            right: TryprSpacing.md,
            bottom: TryprSpacing.md,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(TryprRadius.xl),
            color: TryprColors.surface,
            boxShadow:
                _isHovered
                    ? TryprColors.elevatedShadow
                    : TryprColors.softShadow,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(TryprRadius.xl),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: widget.onTap,
                child: AspectRatio(
                  aspectRatio: 4 / 3,
                  child: LayoutBuilder(
                    builder: (ctx, constraints) {
                      final available =
                          constraints.maxHeight.isFinite
                              ? constraints.maxHeight
                              : 320.0;
                      final footerHeight = (available * 0.25).clamp(
                        56.0,
                        100.0,
                      );
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
                                // Subtle gradient overlay at bottom
                                Positioned(
                                  bottom: 0,
                                  left: 0,
                                  right: 0,
                                  height: 40,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                        colors: [
                                          Colors.transparent,
                                          Colors.black.withOpacity(0.1),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                                if (images.length > 1)
                                  Positioned(
                                    top: TryprSpacing.md,
                                    right: TryprSpacing.md,
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: Colors.white.withOpacity(0.9),
                                        borderRadius: BorderRadius.circular(
                                          TryprRadius.full,
                                        ),
                                        boxShadow: TryprColors.softShadow,
                                      ),
                                      child: Material(
                                        color: Colors.transparent,
                                        child: InkWell(
                                          borderRadius: BorderRadius.circular(
                                            TryprRadius.full,
                                          ),
                                          onTap:
                                              () => setState(
                                                () => _idx = _idx + 1,
                                              ),
                                          child: const Padding(
                                            padding: EdgeInsets.all(
                                              TryprSpacing.sm,
                                            ),
                                            child: Icon(
                                              Icons.chevron_right_rounded,
                                              color: TryprColors.textPrimary,
                                              size: 20,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                // Image counter pills
                                if (images.length > 1)
                                  Positioned(
                                    bottom: TryprSpacing.md,
                                    left: 0,
                                    right: 0,
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: List.generate(
                                        images.length.clamp(0, 5),
                                        (i) => Container(
                                          width: i == clampedIdx ? 16 : 6,
                                          height: 6,
                                          margin: const EdgeInsets.symmetric(
                                            horizontal: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color:
                                                i == clampedIdx
                                                    ? Colors.white
                                                    : Colors.white.withOpacity(
                                                      0.5,
                                                    ),
                                            borderRadius: BorderRadius.circular(
                                              3,
                                            ),
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
                            padding: const EdgeInsets.symmetric(
                              horizontal: TryprSpacing.lg,
                              vertical: TryprSpacing.sm,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(
                                  child: Text(
                                    widget.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: TryprColors.textPrimary,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Flexible(
                                  child: Text(
                                    widget.subtitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: TryprColors.textSecondary,
                                    ),
                                  ),
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

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return Container(
      height: 340,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black.withOpacity(0.10)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Your Trips row ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Row(
              children: [
                Icon(
                  Icons.bookmark_outline,
                  size: 16,
                  color: Colors.white.withOpacity(0.6),
                ),
                const SizedBox(width: 8),
                Text(
                  'Your Trips',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.7),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 150,
            child:
                user == null
                    ? Center(
                      child: Text(
                        'Sign in to see your trips',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.5),
                          fontSize: 13,
                        ),
                      ),
                    )
                    : StreamBuilder<List<TripModel>>(
                      stream: FirestoreService().getTripsStream(),
                      builder: (context, snapshot) {
                        if (snapshot.hasError) {
                          return Center(
                            child: Text(
                              'Could not load trips',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.5),
                                fontSize: 13,
                              ),
                            ),
                          );
                        }
                        if (!snapshot.hasData) {
                          return const Center(
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white54,
                            ),
                          );
                        }

                        final trips = snapshot.data ?? [];

                        if (trips.isEmpty) {
                          return Center(
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.add_circle_outline,
                                  color: Colors.white.withOpacity(0.4),
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'No trips yet — start planning!',
                                  style: TextStyle(
                                    color: Colors.white.withOpacity(0.5),
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          );
                        }

                        return ListView.builder(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          itemCount: trips.length,
                          itemBuilder: (context, index) {
                            final tripModel = trips[index];

                            // Convert TripModel.Stop to waypoint format
                            final waypoints =
                                tripModel.stops
                                    .map(
                                      (stop) => {
                                        'lat': stop.latitude,
                                        'lon': stop.longitude,
                                        'name': stop.placeName,
                                      },
                                    )
                                    .toList();

                            final trip = {
                              'id': tripModel.id,
                              'title': tripModel.tripName,
                              'waypoints': waypoints,
                              'stops': waypoints.length,
                              'distance': tripModel.distance,
                              'startDate': tripModel.startDate,
                              'endDate': tripModel.endDate,
                              'description': tripModel.description,
                            };

                            final isSelected = selectedTripId == tripModel.id;

                            return _TripCard(
                              title: tripModel.tripName,
                              stops: tripModel.stops.length,
                              distance: _formatDistance(tripModel.distance),
                              date: tripModel.formattedDates,
                              isSelected: isSelected,
                              onTap: () => onTripSelected(trip),
                            );
                          },
                        );
                      },
                    ),
          ),

          // ── Verified Trips row ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
            child: Row(
              children: [
                Icon(
                  Icons.verified_outlined,
                  size: 16,
                  color: Colors.white.withOpacity(0.6),
                ),
                const SizedBox(width: 8),
                Text(
                  'Verified Trips',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.7),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream:
                  FirebaseFirestore.instance
                      .collection('verifiedTrips')
                      .orderBy('createdAt', descending: true)
                      .limit(10)
                      .snapshots(),
              builder: (context, snap) {
                if (!snap.hasData || snap.data!.docs.isEmpty) {
                  return Center(
                    child: Text(
                      'No verified trips yet',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.5),
                        fontSize: 13,
                      ),
                    ),
                  );
                }
                final docs = snap.data!.docs;
                return ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    final data = docs[index].data();
                    final title = (data['title'] ?? 'Verified Trip').toString();
                    final wps = data['waypoints'];
                    final stops = wps is List ? wps.length : 0;
                    final daysRaw = data['recommendedDays'] ?? data['days'];
                    final days =
                        daysRaw is num ? '${daysRaw.toInt()} days' : '';

                    return _TripCard(
                      title: title,
                      stops: stops,
                      distance: days,
                      date: '',
                      isSelected: false,
                      onTap: () {
                        // Build waypoints for the globe preview
                        final points = <Map<String, dynamic>>[];
                        if (wps is List) {
                          for (final w in wps) {
                            if (w is Map) {
                              final lat = w['lat'];
                              final lon = w['lon'];
                              if (lat is num && lon is num) {
                                points.add({
                                  'lat': lat.toDouble(),
                                  'lon': lon.toDouble(),
                                  'name': (w['name'] ?? '').toString(),
                                });
                              }
                            }
                          }
                        }
                        if (points.isNotEmpty) {
                          onTripSelected({
                            'id': docs[index].id,
                            'title': title,
                            'waypoints': points,
                            'stops': stops,
                          });
                        }
                      },
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

/// Trip card for the dock – warm, travel-inspired design
class _TripCard extends StatefulWidget {
  final String title;
  final int stops;
  final String distance;
  final String date;
  final bool isSelected;
  final VoidCallback onTap;

  const _TripCard({
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

  /// Pick a fun emoji based on the trip title
  String get _tripEmoji {
    final t = widget.title.toLowerCase();
    if (t.contains('beach') || t.contains('island') || t.contains('coast'))
      return '🏖️';
    if (t.contains('mountain') || t.contains('hiking') || t.contains('trek'))
      return '⛰️';
    if (t.contains('city') ||
        t.contains('urban') ||
        t.contains('york') ||
        t.contains('london') ||
        t.contains('paris') ||
        t.contains('tokyo'))
      return '🏙️';
    if (t.contains('road') || t.contains('drive')) return '🚗';
    if (t.contains('camp')) return '⛺';
    if (t.contains('ski') || t.contains('snow')) return '🎿';
    if (t.contains('safari') || t.contains('jungle') || t.contains('wildlife'))
      return '🦁';
    if (t.contains('cruise') || t.contains('sail') || t.contains('boat'))
      return '🚢';
    if (t.contains('europe')) return '🇪🇺';
    if (t.contains('asia')) return '🌏';
    if (t.contains('africa')) return '🌍';
    // Cycle through fun travel emojis for variety
    final emojis = ['✈️', '🌎', '🗺️', '🧳', '🌴', '🏔️', '🌅', '🎒'];
    return emojis[widget.title.hashCode.abs() % emojis.length];
  }

  /// Pastel gradient palette per card – warm & inviting
  List<Color> get _cardGradient {
    final palettes = [
      [const Color(0xFF667eea), const Color(0xFF764ba2)], // Violet dream
      [const Color(0xFFf093fb), const Color(0xFFf5576c)], // Pink coral
      [const Color(0xFF4facfe), const Color(0xFF00f2fe)], // Ocean blue
      [const Color(0xFF43e97b), const Color(0xFF38f9d7)], // Mint fresh
      [const Color(0xFFfa709a), const Color(0xFFfee140)], // Sunset glow
      [const Color(0xFFa18cd1), const Color(0xFFfbc2eb)], // Lavender haze
      [const Color(0xFFffecd2), const Color(0xFFfcb69f)], // Peach warmth
      [const Color(0xFF89f7fe), const Color(0xFF66a6ff)], // Sky breeze
    ];
    return palettes[widget.title.hashCode.abs() % palettes.length];
  }

  @override
  Widget build(BuildContext context) {
    final gradColors = _cardGradient;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          width: 160,
          margin: const EdgeInsets.only(right: 12, bottom: 12),
          transform:
              _isHovered || widget.isSelected
                  ? (Matrix4.identity()..translate(0.0, -4.0))
                  : Matrix4.identity(),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                gradColors[0].withOpacity(widget.isSelected ? 0.85 : 0.65),
                gradColors[1].withOpacity(widget.isSelected ? 0.85 : 0.65),
              ],
            ),
            border: Border.all(
              color:
                  widget.isSelected
                      ? Colors.white.withOpacity(0.7)
                      : Colors.white.withOpacity(_isHovered ? 0.35 : 0.15),
              width: widget.isSelected ? 2 : 1,
            ),
            boxShadow: [
              BoxShadow(
                color: gradColors[0].withOpacity(
                  widget.isSelected ? 0.4 : (_isHovered ? 0.3 : 0.15),
                ),
                blurRadius: widget.isSelected ? 24 : 12,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Emoji badge
                  Text(_tripEmoji, style: const TextStyle(fontSize: 18)),
                  const SizedBox(height: 3),
                  // Title
                  Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      shadows: [
                        Shadow(color: Color(0x40000000), blurRadius: 4),
                      ],
                    ),
                  ),
                  const SizedBox(height: 3),
                  // Stops & distance
                  Row(
                    children: [
                      const Icon(Icons.place, size: 10, color: Colors.white70),
                      const SizedBox(width: 2),
                      Text(
                        '${widget.stops} stops',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 9,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (widget.distance.isNotEmpty) ...[
                        const SizedBox(width: 4),
                        Text(
                          '·',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.5),
                            fontSize: 9,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            widget.distance,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 9,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  // Date pill
                  if (widget.date.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        widget.date,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 9,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ],
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
      child: InkWell(
        onTap: () {
          debugPrint('GlassmorphicButton tapped');
          widget.onTap();
        },
        borderRadius: BorderRadius.circular(50),
        splashColor: const Color(0xFF00ff88).withOpacity(0.3),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(50),
            border: Border.all(
              color: const Color(0xFF00ff88).withOpacity(_isHovered ? 1 : 0.6),
              width: 2,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(
                  0xFF00ff88,
                ).withOpacity(_isHovered ? 0.4 : 0.2),
                blurRadius: _isHovered ? 30 : 20,
                spreadRadius: -5,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(50),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      const Color(
                        0xFF00ff88,
                      ).withOpacity(_isHovered ? 0.3 : 0.15),
                      const Color(
                        0xFF00ff88,
                      ).withOpacity(_isHovered ? 0.15 : 0.05),
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
          filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withOpacity(0.1),
              border: Border.all(color: Colors.white.withOpacity(0.2)),
            ),
            child: Icon(icon, color: Colors.white.withOpacity(0.8), size: 18),
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
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: Colors.white.withOpacity(0.1),
            border: Border.all(color: Colors.white.withOpacity(0.2)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.map_outlined,
                size: 14,
                color: Colors.white.withOpacity(0.8),
              ),
              const SizedBox(width: 8),
              Text(
                text,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.9),
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
