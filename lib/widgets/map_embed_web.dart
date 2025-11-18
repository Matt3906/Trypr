// Minimal web fallback file. The project now uses the flutter_map-based
// implementation for all platforms. Keep this file as a harmless placeholder
// so older conditional exports or references don't break analysis.

import 'package:flutter/material.dart';

class MapEmbed extends StatelessWidget {
  final List<Map<String, dynamic>> points;
  final void Function(double lat, double lon)? onMapTap;
  const MapEmbed({super.key, required this.points, this.onMapTap});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        padding: const EdgeInsets.all(12),
        child: const Text('Web-specific embed disabled — using native map.'),
      ),
    );
  }
}
