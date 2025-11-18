import 'package:flutter/material.dart';

// Fallback map widget for non-web platforms: shows a placeholder and a simple
// list of coordinates. This avoids adding mapping dependencies and keeps
// behavior consistent on mobile/desktop while web gets an embedded Leaflet map.
class MapEmbed extends StatelessWidget {
  final List<Map<String, dynamic>> points;
  const MapEmbed({super.key, required this.points});

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) {
      return const Center(
        child: Text('Map placeholder — add points to visualize'),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(12.0),
      child: ListView.builder(
        itemCount: points.length,
        itemBuilder: (ctx, i) {
          final p = points[i];
          return ListTile(
            leading: CircleAvatar(child: Text('${i + 1}')),
            title: Text(p['name'] ?? 'Point ${i + 1}'),
            subtitle: Text(
              '${p['lat']?.toStringAsFixed(4) ?? '-'}, ${p['lon']?.toStringAsFixed(4) ?? '-'}',
            ),
          );
        },
      ),
    );
  }
}
