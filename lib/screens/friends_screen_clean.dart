import 'package:flutter/material.dart';
import 'package:trypr/widgets/top_taskbar.dart';

class FriendsScreenClean extends StatelessWidget {
  const FriendsScreenClean({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const TopTaskbar(dockProgress: 1.0),
      body: const Center(
        child: Text(
          'Friends (clean placeholder) — full implementation will be restored',
        ),
      ),
    );
  }
}
