import 'dart:math' as math;

import 'package:flutter/material.dart';

class TripBuilderLayout extends StatelessWidget {
  final Widget panel;
  final Widget map;
  final EdgeInsetsGeometry panelPadding;
  final double maxPanelWidth;
  final double minPanelWidth;
  final double panelRadius;
  final double panelElevation;

  const TripBuilderLayout({
    super.key,
    required this.panel,
    required this.map,
    this.panelPadding = const EdgeInsets.all(16),
    this.maxPanelWidth = 400,
    this.minPanelWidth = 280,
    this.panelRadius = 16,
    this.panelElevation = 16,
  });

  Widget _panelCard(Widget child) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(panelRadius),
      child: Material(
        color: Colors.white,
        elevation: panelElevation,
        shadowColor: Colors.black26,
        child: Padding(padding: panelPadding, child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, box) {
        final maxW = box.maxWidth;
        final maxH = box.maxHeight;

        final sidePadding = (maxW < 520) ? 12.0 : 20.0;
        final topPadding = (maxH < 520) ? 12.0 : 20.0;
        final panelWidth = math.min(
          maxPanelWidth,
          math.max(minPanelWidth, maxW - 2 * sidePadding),
        );

        return Stack(
          children: [
            Positioned.fill(child: map),
            Positioned(
              left: sidePadding,
              top: topPadding,
              bottom: topPadding,
              width: panelWidth,
              child: _panelCard(panel),
            ),
          ],
        );
      },
    );
  }
}
