import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:trypr/widgets/map_embed.dart';
import 'package:trypr/widgets/top_taskbar.dart';
import 'package:http/http.dart' as http;

class VisitedMapScreen extends StatefulWidget {
  const VisitedMapScreen({Key? key}) : super(key: key);

  @override
  State<VisitedMapScreen> createState() => _VisitedMapScreenState();
}

class _VisitedMapScreenState extends State<VisitedMapScreen> {
  final Set<String> _visited = {};
  bool _loading = false;
  User? get _user => FirebaseAuth.instance.currentUser;

  @override
  void initState() {
    super.initState();
    _loadVisited();
  }

  Future<void> _loadVisited() async {
    final u = _user;
    if (u == null) return;
    final doc =
        await FirebaseFirestore.instance.collection('users').doc(u.uid).get();
    final data = doc.data() ?? {};
    final vc = (data['visitedCountries'] as List<dynamic>?) ?? [];
    setState(() => _visited.addAll(vc.map((e) => e.toString())));
  }

  Future<String?> _countryFromLatLon(double lat, double lon) async {
    try {
      final url = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse',
      ).replace(
        queryParameters: {
          'format': 'json',
          'lat': lat.toString(),
          'lon': lon.toString(),
          'zoom': '3',
          'addressdetails': '1',
        },
      );
      final resp = await http.get(
        url,
        headers: {'User-Agent': 'trypr-app/1.0 (https://example.com)'},
      );
      if (resp.statusCode != 200) return null;
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      final address = body['address'] as Map<String, dynamic>?;
      if (address == null) return null;
      final country = address['country'] ?? address['country_name'];
      return country?.toString();
    } catch (_) {
      return null;
    }
  }

  Future<void> _toggleCountry(String country) async {
    final u = _user;
    if (u == null) return;
    setState(() => _loading = true);
    final docRef = FirebaseFirestore.instance.collection('users').doc(u.uid);
    try {
      if (_visited.contains(country)) {
        _visited.remove(country);
        await docRef.update({
          'visitedCountries': FieldValue.arrayRemove([country]),
        });
      } else {
        _visited.add(country);
        await docRef.update({
          'visitedCountries': FieldValue.arrayUnion([country]),
        });
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to update visited: $e')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const TopTaskbar(dockProgress: 1.0),
      body: Column(
        children: [
          Expanded(
            child: MapEmbed(
              points: [],
              onMapTap: (lat, lon) async {
                final country = await _countryFromLatLon(lat, lon);
                if (country == null) {
                  if (mounted)
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Could not detect country')),
                    );
                  return;
                }
                if (!mounted) return;
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder:
                      (ctx) => AlertDialog(
                        title: Text(country),
                        content: Text('Mark $country as visited?'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(false),
                            child: const Text('Cancel'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(true),
                            child: const Text('Yes'),
                          ),
                        ],
                      ),
                );
                if (confirmed == true) await _toggleCountry(country);
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              border: Border(top: BorderSide(color: Colors.grey.shade200)),
            ),
            child: Row(
              children: [
                const Text(
                  'Visited: ',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children:
                          _visited
                              .map(
                                (c) => Padding(
                                  padding: const EdgeInsets.only(right: 8.0),
                                  child: Chip(label: Text(c)),
                                ),
                              )
                              .toList(),
                    ),
                  ),
                ),
                if (_loading)
                  const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
