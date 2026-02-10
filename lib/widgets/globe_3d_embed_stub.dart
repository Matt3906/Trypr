import 'package:flutter/material.dart';

/// Non-web stub — the 3D globe is only available in the browser.
class Globe3DEmbed extends StatelessWidget {
  final List<Map<String, dynamic>> points;
  final void Function(double lat, double lon)? onMapTap;
  final void Function(double distanceMeters, double durationSeconds)?
  onRouteSummary;
  final String transportMode;

  const Globe3DEmbed({
    super.key,
    this.points = const [],
    this.onMapTap,
    this.onRouteSummary,
    this.transportMode = 'DRIVING',
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0a0a1a),
      child: const Center(
        child: Text(
          '3D Globe is available in the browser.',
          style: TextStyle(color: Colors.white54, fontSize: 13),
        ),
      ),
    );
  }
}
