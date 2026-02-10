import 'package:flutter/material.dart';

/// Stub implementation for non-web platforms
/// The 3D globe is only available on web
class GlobeWidget extends StatelessWidget {
  final List<Map<String, dynamic>> trips;
  final Map<String, dynamic>? selectedTrip;
  final void Function(Map<String, dynamic> trip)? onTripSelected;

  const GlobeWidget({
    super.key,
    required this.trips,
    this.selectedTrip,
    this.onTripSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFF1a365d),
            const Color(0xFF2563eb),
            const Color(0xFF1d4ed8),
          ],
        ),
        borderRadius: BorderRadius.circular(24),
      ),
      child: const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.public, size: 80, color: Colors.white54),
            SizedBox(height: 16),
            Text(
              '3D Globe available on web only',
              style: TextStyle(color: Colors.white54, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}
