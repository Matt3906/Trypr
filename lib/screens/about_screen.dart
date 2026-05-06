import 'package:flutter/material.dart';
import 'package:trypr/utils/trypr_snackbar.dart';
import 'package:trypr/widgets/top_taskbar.dart';
import 'package:trypr/screens/trip_builder_screen.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screenWidth = MediaQuery.sizeOf(context).width;
    final isCompact = screenWidth < 760;
    return Scaffold(
      appBar: const TopTaskbar(dockProgress: 1.0),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(isCompact ? 14.0 : 16.0),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Logo + Header
                Center(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 12.0),
                    child: Image.asset(
                      'images/TryprLogo_Black.png',
                      height: isCompact ? 72 : 96,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
                Text(
                  'Plan deeper. Travel smarter.',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 16),

                // Image + intro (image left, intro right). Caption sits under the image.
                LayoutBuilder(
                  builder: (context, constraints) {
                    final useStacked = constraints.maxWidth < 760;
                    final imageColumn = Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                          height: useStacked ? 220 : 320,
                          decoration: BoxDecoration(
                            color: const Color(0xFFF5F5F5),
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.08),
                                blurRadius: 12,
                                offset: const Offset(0, 6),
                              ),
                            ],
                            image: const DecorationImage(
                              image: AssetImage('images/aboutUsPic.jpg'),
                              fit: BoxFit.cover,
                              alignment: Alignment.center,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'McDonald Lake, Glacier National Park - Apgar, Montana',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontStyle: FontStyle.italic,
                            color: Colors.black54,
                          ),
                        ),
                      ],
                    );
                    final introColumn = Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'About Trypr',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Trypr is a trip planning home built for people who love planning — not just point‑A to point‑B navigation. When traditional map tools fall short for ambitious roadtrip planning, Trypr steps in with a planner designed for real trips: rigorous route control, group collaboration, and the tools you need to actually get ready and go.',
                        ),
                      ],
                    );

                    if (useStacked) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          imageColumn,
                          const SizedBox(height: 18),
                          introColumn,
                        ],
                      );
                    }

                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 4, child: imageColumn),
                        const SizedBox(width: 20),
                        Expanded(flex: 6, child: introColumn),
                      ],
                    );
                  },
                ),

                const SizedBox(height: 20),

                // Details
                Text(
                  'What Trypr does',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                const Text('• Focused, detailed roadtrip planning (car).'),
                const Text(
                  '• Collaborative trips — invite friends, edit together, and keep everyone in sync.',
                ),
                const Text(
                  '• Shared packing lists with collaboration so nobody forgets the essentials.',
                ),
                const Text(
                  '• Live trip features: group chat, effortless photo sharing, and plans to support full-resolution images without heavy compression.',
                ),

                const SizedBox(height: 16),
                Text(
                  'Future modes',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Soon we’ll expand beyond roadtrips to support hiking/backpacking, equestrian routes, portaging, and bikepacking — because different adventures need different tools.',
                ),

                const SizedBox(height: 16),
                Text(
                  'Why I built it',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'I’m a 19‑year‑old from Toronto who loves to travel and to plan. Spreadsheets and generic map apps weren’t cutting it for the kinds of trips I wanted to build, so I made something better — a “mega” trip planning home for planners who take their trips seriously.',
                ),

                const SizedBox(height: 24),
                // CTA / closing
                ElevatedButton.icon(
                  onPressed: () async {
                    try {
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const TripBuilderScreen(),
                        ),
                      );
                      if (!context.mounted) return;
                    } catch (e) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showTryprSnackBar(
                        const SnackBar(
                          content: Text('Trip builder is not available.'),
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.explore),
                  label: const Text('Start planning a trip'),
                ),

                const SizedBox(height: 12),
                Text(
                  'Built with care in Toronto. © ${DateTime.now().year} Trypr',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
