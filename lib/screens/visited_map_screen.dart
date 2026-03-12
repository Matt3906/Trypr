import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:trypr/utils/trypr_snackbar.dart';

import 'package:trypr/widgets/top_taskbar.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import 'package:latlong2/latlong.dart';

class VisitedMapScreen extends StatefulWidget {
  const VisitedMapScreen({super.key});

  @override
  State<VisitedMapScreen> createState() => _VisitedMapScreenState();
}

class _VisitedMapScreenState extends State<VisitedMapScreen> {
  User? get _user => FirebaseAuth.instance.currentUser;

  static const _mapsKey = String.fromEnvironment('GOOGLE_MAPS_API_KEY');

  Stream<DocumentSnapshot<Map<String, dynamic>>>? _userDocStream() {
    final u = _user;
    if (u == null) return null;
    return FirebaseFirestore.instance
        .collection('users')
        .doc(u.uid)
        .snapshots();
  }

  // Quick common suggestions for users to add (expandable later)
  static const List<String> _commonSuggestions = [
    'US',
    'US-CA',
    'GB',
    'FR',
    'DE',
    'IT',
    'ES',
    'AU',
    'JP',
    'CN',
  ];

  Future<void> _addRegion(String regionId) async {
    final u = _user;
    if (u == null) return;
    final id = regionId.trim().toUpperCase();
    if (id.isEmpty) return;

    final docRef = FirebaseFirestore.instance.collection('users').doc(u.uid);
    try {
      final snap = await docRef.get();
      if (snap.exists) {
        await docRef.update({
          'visitedCountries': FieldValue.arrayUnion([id]),
        });
      } else {
        await docRef.set({
          'visitedCountries': [id],
        }, SetOptions(merge: true));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showTryprSnackBar(SnackBar(content: Text('Failed to add: $e')));
      }
    }
  }

  Future<void> _removeRegion(String regionId) async {
    final u = _user;
    if (u == null) return;
    final id = regionId.trim().toUpperCase();
    if (id.isEmpty) return;

    final docRef = FirebaseFirestore.instance.collection('users').doc(u.uid);
    try {
      await docRef.update({
        'visitedCountries': FieldValue.arrayRemove([id]),
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showTryprSnackBar(SnackBar(content: Text('Failed to remove: $e')));
      }
    }
  }

  Future<void> _showAddDialog([String? prefill]) async {
    final ctl = TextEditingController(text: prefill ?? '');
    final res = await showDialog<String?>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Add region'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: ctl,
                  decoration: const InputDecoration(
                    labelText: 'Region ID (e.g. US, US-CA, FR)',
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children:
                      _commonSuggestions
                          .map(
                            (s) => ActionChip(
                              label: Text(s),
                              onPressed: () => Navigator.of(ctx).pop(s),
                            ),
                          )
                          .toList(),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.of(ctx).pop(ctl.text),
                child: const Text('Add'),
              ),
            ],
          ),
    );
    if (res != null && res.isNotEmpty) {
      await _addRegion(res);
    }
  }

  // Helper to create color mapping for the world map
  // Render a tiled world map using flutter_map. This reliably displays a map
  // and provides a tap handler to add regions. Country-shape toggling can be
  // added later if precise geometry data is available.
  Widget _buildMapArea(Set<String> visitedSet) {
    if (kIsWeb) {
      if (_mapsKey.isEmpty) {
        return const Center(
          child: Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'Google Maps is not configured. Build with '
              '--dart-define=GOOGLE_MAPS_API_KEY=YOUR_KEY',
              textAlign: TextAlign.center,
            ),
          ),
        );
      }

      return gmaps.GoogleMap(
        initialCameraPosition: const gmaps.CameraPosition(
          target: gmaps.LatLng(20, 0),
          zoom: 2,
        ),
        onTap: (_) => _showAddDialog(),
        mapToolbarEnabled: false,
        myLocationButtonEnabled: false,
      );
    }

    return FlutterMap(
      options: MapOptions(
        center: LatLng(20, 0),
        zoom: 2,
        minZoom: 1,
        maxZoom: 18,
        onTap: (_, __) => _showAddDialog(),
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
          subdomains: const ['a', 'b', 'c'],
          userAgentPackageName: 'com.example.trypr',
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final stream = _userDocStream();
    return Scaffold(
      appBar: const TopTaskbar(dockProgress: 1.0),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child:
                    stream == null
                        ? const Text('Sign in to view your travel map')
                        : StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                          stream: stream,
                          builder: (ctx, snap) {
                            if (snap.connectionState ==
                                ConnectionState.waiting) {
                              return const SizedBox(
                                height: 200,
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              );
                            }
                            final data =
                                snap.data?.data() ?? <String, dynamic>{};
                            final visited =
                                (data['visitedCountries'] as List<dynamic>?) ??
                                [];
                            final visitedSet =
                                visited.map((e) => e.toString()).toSet();

                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      'Visited Map',
                                      style:
                                          Theme.of(
                                            context,
                                          ).textTheme.titleLarge,
                                    ),
                                    ElevatedButton.icon(
                                      onPressed: () => _showAddDialog(),
                                      icon: const Icon(Icons.add),
                                      label: const Text('Add region'),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),

                                // World map area (uses countries_world_map). Tapping regions toggles visited state.
                                SizedBox(
                                  height: 360,
                                  child: Card(
                                    margin: EdgeInsets.zero,
                                    color: const Color(0xFFF5F7FA),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(12),
                                      child: _buildMapArea(visitedSet),
                                    ),
                                  ),
                                ),

                                const SizedBox(height: 12),
                                Expanded(
                                  child:
                                      visitedSet.isEmpty
                                          ? const Text('No regions marked yet.')
                                          : ListView(
                                            children:
                                                visitedSet
                                                    .map(
                                                      (e) => ListTile(
                                                        title: Text(e),
                                                        trailing: IconButton(
                                                          icon: const Icon(
                                                            Icons
                                                                .delete_outline,
                                                          ),
                                                          onPressed:
                                                              () =>
                                                                  _removeRegion(
                                                                    e,
                                                                  ),
                                                        ),
                                                        onTap:
                                                            () =>
                                                                _showAddDialog(
                                                                  e,
                                                                ),
                                                      ),
                                                    )
                                                    .toList(),
                                          ),
                                ),
                              ],
                            );
                          },
                        ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
