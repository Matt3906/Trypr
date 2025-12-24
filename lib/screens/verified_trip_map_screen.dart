import 'package:flutter/material.dart';
import 'package:trypr/widgets/map_embed.dart';

class VerifiedTripMapScreen extends StatelessWidget {
  final String title;
  final List<Map<String, dynamic>> points;

  const VerifiedTripMapScreen({
    super.key,
    required this.title,
    required this.points,
  });

  static Route<void> route({
    required String title,
    required List<Map<String, dynamic>> points,
  }) {
    return MaterialPageRoute<void>(
      builder: (_) => VerifiedTripMapScreen(title: title, points: points),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title.trim().isEmpty ? 'Verified trip' : title.trim()),
      ),
      body: MapEmbed(points: points),
    );
  }
}
