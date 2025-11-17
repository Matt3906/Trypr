import 'package:flutter/material.dart';
import 'package:trypr/widgets/top_taskbar.dart';

class VerifiedTripsScreen extends StatelessWidget {
  const VerifiedTripsScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const TopTaskbar(dockProgress: 1.0),
      body: const Center(child: Text('Verified Trips page')),
    );
  }
}
