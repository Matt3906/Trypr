import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:trypr/widgets/top_taskbar.dart';

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

  Widget _buildTripCard(
    BuildContext context,
    String title,
    String subtitle, {
    required String image,
  }) {
    return Container(
      // No fixed width so it works with Expanded (three-up) or stacked layout.
      margin: const EdgeInsets.only(right: 12, bottom: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Colors.white,
        boxShadow: [
          BoxShadow(color: const Color.fromRGBO(0, 0, 0, 0.08), blurRadius: 8),
        ],
      ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Large map/image area with rounded top corners
            ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.asset(image, fit: BoxFit.cover),
                    // subtle overlay for contrast
                    Container(color: const Color.fromRGBO(0, 0, 0, 0.06)),
                  ],
                ),
              ),
            ),

            // Content area: title and metadata row
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600, color: Colors.black87),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      // Left meta: days | kms
                      Expanded(
                        child: Text(
                          'Total days  |  total kms',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.black54),
                        ),
                      ),
                      // Right meta: total stops
                      Text(
                        'Total stops',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.black54),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
    );
  }

  Widget _buildReviewCard(BuildContext context, String user, String text) {
    return Container(
      width: 260,
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
                                'images/Trypr Logo_White.png',
                                width: constraints.maxWidth > 800 ? 260 : 160,
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
                    padding: const EdgeInsets.symmetric(horizontal: 20.0),
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
                        // Three-up trips (responsive)
                        LayoutBuilder(
                          builder: (ctx, box) {
                            if (box.maxWidth >= 900) {
                              return Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: _buildTripCard(
                                      context,
                                      'Canadian Icefield Parkway',
                                      '4 - 7 days',
                                       image: 'images/mainScreenPic.jpg',
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: _buildTripCard(
                                      context,
                                      'Pacific West Coast',
                                      '7 - 14 days',
                                       image: 'images/mainScreenPic.jpg',
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: _buildTripCard(
                                      context,
                                      'Vancouver Island',
                                      '4 - 6 days',
                                       image: 'images/mainScreenPic.jpg',
                                    ),
                                  ),
                                ],
                              );
                            } else {
                              return Column(
                                children: [
                                  _buildTripCard(
                                    context,
                                    'Canadian Icefield Parkway',
                                    '4 - 7 days',
                                     image: 'images/mainScreenPic.jpg',
                                  ),
                                  const SizedBox(height: 12),
                                  _buildTripCard(
                                    context,
                                    'Pacific West Coast',
                                    '7 - 14 days',
                                     image: 'images/mainScreenPic.jpg',
                                  ),
                                  const SizedBox(height: 12),
                                  _buildTripCard(
                                    context,
                                    'Vancouver Island',
                                    '4 - 6 days',
                                     image: 'images/mainScreenPic.jpg',
                                  ),
                                ],
                              );
                            }
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
                            Text('• Point 1'),
                            Text('• Point 2'),
                            Text('• Point 3'),
                            Text('• Point 4'),
                            Text('• Point 5'),
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
