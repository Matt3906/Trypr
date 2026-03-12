import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:trypr/utils/trypr_snackbar.dart';
import 'package:trypr/theme/app_theme.dart';
import 'package:trypr/services/pick_image_data_url.dart';
import 'package:trypr/widgets/top_taskbar.dart';
import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/foundation.dart' show kIsWeb, setEquals;

// MAP PACKAGES
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import 'package:latlong2/latlong.dart';
// 'http' used previously for remote GeoJSON fetch; now we load from assets.

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  User? get _user => FirebaseAuth.instance.currentUser;
  // Staged visited countries while editing the embedded map
  final Set<String> _stagedVisited = {};
  bool _isEditingVisited = false;

  static const _mapsKey = String.fromEnvironment('GOOGLE_MAPS_API_KEY');

  // MAP STATE (uses dedicated VisitedMapScreen)

  Stream<DocumentSnapshot<Map<String, dynamic>>>? _userDocStream() {
    final u = _user;
    if (u == null) return null;
    return FirebaseFirestore.instance
        .collection('users')
        .doc(u.uid)
        .snapshots();
  }

  // -------------------------------------------------------------------------
  // MAP LOGIC
  // -------------------------------------------------------------------------

  int supportedTotal() {
    // Approximate number of countries supported for progress calculation.
    // Using a constant avoids depending on the countries_world_map package
    // which had API mismatches in this environment.
    return 195;
  }

  Future<void> _toggleRegion(
    String regionId,
    List<dynamic> currentVisited,
  ) async {
    final u = _user;
    if (u == null) return;

    final docRef = FirebaseFirestore.instance.collection('users').doc(u.uid);

    try {
      final snap = await docRef.get();
      if (currentVisited.contains(regionId)) {
        if (snap.exists) {
          await docRef.update({
            'visitedCountries': FieldValue.arrayRemove([regionId]),
          });
          if (mounted) {
            setState(() {
              _stagedVisited.remove(regionId);
              _isEditingVisited = false;
            });
          }
        }
      } else {
        if (snap.exists) {
          await docRef.update({
            'visitedCountries': FieldValue.arrayUnion([regionId]),
          });
          if (mounted) {
            setState(() {
              _stagedVisited.add(regionId);
              _isEditingVisited = false;
            });
          }
        } else {
          await docRef.set({
            'visitedCountries': [regionId],
          }, SetOptions(merge: true));
          if (mounted) {
            setState(() {
              _stagedVisited.add(regionId);
              _isEditingVisited = false;
            });
          }
        }
      }
    } catch (e) {
      // best-effort: ignore failures here (UI will show raw doc for debugging)
      rethrow;
    }
  }

  // Show add-region dialog and return the chosen country name (full name) or null
  // Note: map-based adding is handled by tapping the map; search/dialog
  // based adding has been removed from this screen.

  bool _pointInPolygon(LatLng point, List<LatLng> polygon) {
    // Ray-casting algorithm
    var inside = false;
    for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      final xi = polygon[i].longitude, yi = polygon[i].latitude;
      final xj = polygon[j].longitude, yj = polygon[j].latitude;
      final intersect =
          ((yi > point.latitude) != (yj > point.latitude)) &&
          (point.longitude <
              (xj - xi) * (point.latitude - yi) / (yj - yi + 0.0) + xi);
      if (intersect) inside = !inside;
    }
    return inside;
  }

  // Small built-in centroid lookup for common countries. If a country isn't
  // found here, we will still store the country name but won't show a marker.
  static final Map<String, LatLng> _countryCentroids = {
    'United States': LatLng(39.8283, -98.5795),
    'Canada': LatLng(56.1304, -106.3468),
    'Mexico': LatLng(23.6345, -102.5528),
    'Brazil': LatLng(-14.2350, -51.9253),
    'Argentina': LatLng(-38.4161, -63.6167),
    'United Kingdom': LatLng(55.3781, -3.4360),
    'France': LatLng(46.2276, 2.2137),
    'Germany': LatLng(51.1657, 10.4515),
    'Italy': LatLng(41.8719, 12.5674),
    'Spain': LatLng(40.4637, -3.7492),
    'Portugal': LatLng(39.3999, -8.2245),
    'Netherlands': LatLng(52.1326, 5.2913),
    'Belgium': LatLng(50.5039, 4.4699),
    'Switzerland': LatLng(46.8182, 8.2275),
    'Austria': LatLng(47.5162, 14.5501),
    'Sweden': LatLng(60.1282, 18.6435),
    'Norway': LatLng(60.4720, 8.4689),
    'Finland': LatLng(61.9241, 25.7482),
    'Denmark': LatLng(56.2639, 9.5018),
    'Poland': LatLng(51.9194, 19.1451),
    'Czech Republic': LatLng(49.8175, 15.4730),
    'Hungary': LatLng(47.1625, 19.5033),
    'Greece': LatLng(39.0742, 21.8243),
    'Turkey': LatLng(38.9637, 35.2433),
    'Russia': LatLng(61.5240, 105.3188),
    'China': LatLng(35.8617, 104.1954),
    'Japan': LatLng(36.2048, 138.2529),
    'South Korea': LatLng(35.9078, 127.7669),
    'India': LatLng(20.5937, 78.9629),
    'Pakistan': LatLng(30.3753, 69.3451),
    'Bangladesh': LatLng(23.6850, 90.3563),
    'Australia': LatLng(-25.2744, 133.7751),
    'New Zealand': LatLng(-40.9006, 174.8860),
    'South Africa': LatLng(-30.5595, 22.9375),
    'Egypt': LatLng(26.8206, 30.8025),
    'Nigeria': LatLng(9.0820, 8.6753),
    'Kenya': LatLng(-0.0236, 37.9062),
    'Morocco': LatLng(31.7917, -7.0926),
    'Algeria': LatLng(28.0339, 1.6596),
    'Saudi Arabia': LatLng(23.8859, 45.0792),
    'United Arab Emirates': LatLng(23.4241, 53.8478),
    'Israel': LatLng(31.0461, 34.8516),
    'Lebanon': LatLng(33.8547, 35.8623),
    'Indonesia': LatLng(-0.7893, 113.9213),
    'Philippines': LatLng(12.8797, 121.7740),
    'Vietnam': LatLng(14.0583, 108.2772),
    'Thailand': LatLng(15.8700, 100.9925),
    'Malaysia': LatLng(4.2105, 101.9758),
    'Singapore': LatLng(1.3521, 103.8198),
  };

  // Polygons loaded from an external GeoJSON source keyed by a normalized name.
  final Map<String, List<List<LatLng>>> _countryPolygons = {};
  bool _polygonsLoaded = false;

  String _keyForMatching(String s) {
    final low = s.toLowerCase();
    // remove common words and non-alphanum
    final cleaned = low.replaceAll(RegExp(r"[^a-z0-9]"), ' ');
    final tokens =
        cleaned
            .split(RegExp(r"\s+"))
            .where(
              (t) =>
                  t.isNotEmpty &&
                  t != 'of' &&
                  t != 'the' &&
                  t != 'and' &&
                  t != 'republic' &&
                  t != 'federation' &&
                  t != 'kingdom',
            )
            .toList();
    return tokens.join(' ');
  }

  Future<void> _loadCountryPolygons() async {
    if (_polygonsLoaded) return;
    try {
      // Load bundled GeoJSON from assets to avoid runtime CORS/network issues.
      final body = await rootBundle.loadString('assets/countries.geojson');
      final js = jsonDecode(body) as Map<String, dynamic>;
      final features = js['features'] as List<dynamic>?;
      if (features == null) return;
      for (final f in features) {
        try {
          final feat = f as Map<String, dynamic>;
          final props = feat['properties'] as Map<String, dynamic>? ?? {};
          final rawName =
              (props['ADMIN'] ??
                      props['admin'] ??
                      props['NAME'] ??
                      props['name'] ??
                      props['COUNTRY'] ??
                      props['country'] ??
                      '')
                  .toString();
          if (rawName.isEmpty) continue;
          final key = _keyForMatching(rawName);
          final geom = feat['geometry'] as Map<String, dynamic>?;
          if (geom == null) continue;
          final type = geom['type'] as String?;
          final coords = geom['coordinates'];
          final List<List<LatLng>> polygons = [];
          if (type == 'Polygon' && coords is List) {
            // coords: [ [ [lon,lat], ... ], [ ... holes ... ] ]
            final firstRing =
                coords.isNotEmpty ? coords[0] as List<dynamic> : [];
            final pts = <LatLng>[];
            for (final p in firstRing) {
              if (p is List && p.length >= 2) {
                final lon = (p[0] as num).toDouble();
                final lat = (p[1] as num).toDouble();
                pts.add(LatLng(lat, lon));
              }
            }
            if (pts.isNotEmpty) polygons.add(pts);
          } else if (type == 'MultiPolygon' && coords is List) {
            // coords: [ [ [ [lon,lat], ... ], ... ], ... ]
            for (final poly in coords) {
              if (poly is List && poly.isNotEmpty) {
                final outer = poly[0] as List<dynamic>;
                final pts = <LatLng>[];
                for (final p in outer) {
                  if (p is List && p.length >= 2) {
                    final lon = (p[0] as num).toDouble();
                    final lat = (p[1] as num).toDouble();
                    pts.add(LatLng(lat, lon));
                  }
                }
                if (pts.isNotEmpty) polygons.add(pts);
              }
            }
          }
          if (polygons.isNotEmpty) {
            _countryPolygons[key] = polygons;
          }
        } catch (_) {
          // ignore per-feature failures
        }
      }
      _polygonsLoaded = true;
      if (mounted) setState(() {});
    } catch (_) {
      // best-effort; leave polygons empty
    }
  }

  Set<gmaps.Marker> _buildGmapMarkers(Set<String> staged) {
    final markers = <gmaps.Marker>{};
    for (final name in staged) {
      final key = name.trim();
      final center = _countryCentroids[key];
      if (center != null) {
        markers.add(
          gmaps.Marker(
            markerId: gmaps.MarkerId('country_$key'),
            position: gmaps.LatLng(center.latitude, center.longitude),
            icon: gmaps.BitmapDescriptor.defaultMarkerWithHue(
              gmaps.BitmapDescriptor.hueGreen,
            ),
          ),
        );
      }
    }
    return markers;
  }

  Set<gmaps.Marker> _buildGmapMarkersForMissingPolygons(Set<String> staged) {
    final markers = <gmaps.Marker>{};
    for (final name in staged) {
      final norm = _keyForMatching(name);
      if (_countryPolygons.containsKey(norm)) continue;
      final center = _countryCentroids[name.trim()];
      if (center == null) continue;
      markers.add(
        gmaps.Marker(
          markerId: gmaps.MarkerId('country_missingpoly_${name.trim()}'),
          position: gmaps.LatLng(center.latitude, center.longitude),
          icon: gmaps.BitmapDescriptor.defaultMarkerWithHue(
            gmaps.BitmapDescriptor.hueGreen,
          ),
        ),
      );
    }
    return markers;
  }

  String _normalizeCountryName(String s) {
    final words = s.trim().split(RegExp(r"\s+"));
    final normalized = words
        .map((w) {
          if (w.isEmpty) return '';
          final lower = w.toLowerCase();
          return '${lower[0].toUpperCase()}${lower.substring(1)}';
        })
        .where((p) => p.isNotEmpty)
        .join(' ');
    return normalized;
  }

  // Map color helper removed; Visited map is shown in a dedicated screen.

  Set<gmaps.Polygon> _buildGmapPolygonsSet(Set<String> staged) {
    // Render ONLY visited polygons. Rendering all ~200 country polygons makes
    // the base map look washed out (opaque fills) and can be very heavy on web.
    final out = <gmaps.Polygon>{};
    for (final name in staged) {
      final norm = _keyForMatching(name);
      final polyRings = _countryPolygons[norm];
      if (polyRings == null) continue;
      var ringIndex = 0;
      for (final ring in polyRings) {
        final id = '${norm}_$ringIndex';
        ringIndex++;
        out.add(
          gmaps.Polygon(
            polygonId: gmaps.PolygonId(id),
            points:
                ring.map((p) => gmaps.LatLng(p.latitude, p.longitude)).toList(),
            fillColor: Theme.of(
              context,
            ).colorScheme.primary.withValues(alpha: 0.28),
            strokeColor: Theme.of(
              context,
            ).colorScheme.primary.withValues(alpha: 0.55),
            strokeWidth: 1,
          ),
        );
      }
    }
    return out;
  }

  ImageProvider<Object>? _profileImageProvider(String? profileImageDataUrl) {
    if (profileImageDataUrl == null || profileImageDataUrl.isEmpty) return null;
    if (kIsWeb) return NetworkImage(profileImageDataUrl);
    try {
      return MemoryImage(base64Decode(profileImageDataUrl.split(',').last));
    } catch (_) {
      return null;
    }
  }

  String _initialsFor(String value) {
    final parts =
        value
            .trim()
            .split(RegExp(r'\s+'))
            .where((part) => part.isNotEmpty)
            .toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }

  Color _chipAccent(String seed) {
    const palette = <Color>[
      TryprColors.primary,
      TryprColors.secondary,
      TryprColors.coral,
      TryprColors.mint,
      TryprColors.peach,
      TryprColors.lavender,
      TryprColors.rose,
    ];
    final idx =
        seed.runes.fold<int>(0, (total, ch) => total + ch) % palette.length;
    return palette[idx];
  }

  Widget _heroPill(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(TryprRadius.full),
        border: Border.all(color: Colors.white.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.white),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _metricTile({
    required IconData icon,
    required String label,
    required String value,
    required Color accent,
  }) {
    return Container(
      padding: const EdgeInsets.all(TryprSpacing.md),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(TryprRadius.lg),
        border: Border.all(color: accent.withValues(alpha: 0.3)),
        boxShadow: TryprColors.softShadow,
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: accent, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: TryprColors.textPrimary,
                  ),
                ),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 12,
                    color: TryprColors.textSecondary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionContainer({required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(TryprRadius.xl),
        border: Border.all(color: const Color(0xFFE8EEF5)),
      ),
      padding: const EdgeInsets.all(TryprSpacing.lg),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final stream = _userDocStream();
    return Scaffold(
      appBar: const TopTaskbar(dockProgress: 1.0),
      backgroundColor: TryprColors.background,
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(TryprSpacing.lg),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: SoftCard(
              elevated: true,
              padding: const EdgeInsets.all(TryprSpacing.xl),
              child:
                  stream == null
                      ? _signedOutContent(context)
                      : StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                        stream: stream,
                        builder: (ctx, snap) {
                          if (snap.connectionState == ConnectionState.waiting) {
                            return const SizedBox(
                              height: 180,
                              child: Center(
                                child: CircularProgressIndicator(
                                  color: TryprColors.primary,
                                ),
                              ),
                            );
                          }

                          final isCompact = MediaQuery.sizeOf(ctx).width < 760;
                          final doc = snap.data;
                          final data = doc?.data() ?? <String, dynamic>{};

                          final displayName =
                              data['name'] ??
                              data['displayName'] ??
                              _user?.displayName ??
                              '—';
                          final email = _user?.email ?? data['email'] ?? '—';
                          final subscription =
                              data['subscriptionType'] ??
                              data['subscription'] ??
                              'Free';
                          final city = data['city'] ?? '—';
                          String dobStr = '—';
                          if (data['dob'] != null) {
                            try {
                              final d = data['dob'];
                              DateTime dt;
                              if (d is String) {
                                dt = DateTime.parse(d);
                              } else if (d is Timestamp) {
                                dt = d.toDate();
                              } else {
                                dt = DateTime.parse(d.toString());
                              }
                              dobStr =
                                  '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
                            } catch (_) {}
                          }
                          final sex =
                              (data['sex'] ?? data['gender'] ?? '—').toString();
                          final profileImage =
                              data['profileImageDataUrl'] as String?;

                          final friendsRaw = data['friends'] as List<dynamic>?;
                          final friends = <Map<String, dynamic>>[];
                          if (friendsRaw != null) {
                            for (final f in friendsRaw) {
                              if (f is Map) {
                                friends.add(Map<String, dynamic>.from(f));
                              } else if (f is String) {
                                friends.add({'id': f});
                              }
                            }
                          }

                          final visitedRaw =
                              data['visitedCountries'] as List<dynamic>? ?? [];
                          final visitedSet =
                              visitedRaw.map((e) => e.toString()).toSet();

                          // Keep the staged set in sync with Firestore when the
                          // user is not actively editing in the embedded map.
                          // Only update if the persisted set differs to avoid
                          // scheduling a post-frame setState on every build
                          // (which caused a rebuild loop and UI flash).
                          if (!_isEditingVisited) {
                            final newSet = visitedSet;
                            if (!setEquals(_stagedVisited, newSet)) {
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (!mounted) return;
                                setState(() {
                                  _stagedVisited
                                    ..clear()
                                    ..addAll(newSet);
                                });
                              });
                            }
                          }

                          final totalSupported = supportedTotal();
                          final visitedCount = _stagedVisited.length;
                          final progressValue =
                              totalSupported > 0
                                  ? (visitedCount / totalSupported)
                                  : 0.0;
                          final progressPercent = (progressValue * 100).round();
                          final profileProvider = _profileImageProvider(
                            profileImage,
                          );
                          final initials = _initialsFor(displayName.toString());
                          final cityText = city.toString();
                          final sortedVisited = visitedSet.toList()..sort();

                          Future<void> persistVisited() async {
                            final u = _user;
                            if (u == null) return;
                            final docRef = FirebaseFirestore.instance
                                .collection('users')
                                .doc(u.uid);
                            try {
                              await docRef.set({
                                'visitedCountries': _stagedVisited.toList(),
                              }, SetOptions(merge: true));
                              if (!ctx.mounted) return;
                              setState(() => _isEditingVisited = false);
                            } catch (err) {
                              if (!ctx.mounted) return;
                              ScaffoldMessenger.of(ctx).showTryprSnackBar(
                                SnackBar(content: Text('Failed to save: $err')),
                              );
                            }
                          }

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Container(
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    colors: [
                                      Color(0xFF1F6FAE),
                                      TryprColors.primary,
                                      Color(0xFF2BA9A0),
                                    ],
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                  ),
                                  borderRadius: BorderRadius.circular(
                                    TryprRadius.xl,
                                  ),
                                  boxShadow: TryprColors.softShadow,
                                ),
                                child: Stack(
                                  children: [
                                    Positioned(
                                      right: -28,
                                      top: -22,
                                      child: Container(
                                        width: 120,
                                        height: 120,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: Colors.white.withValues(
                                            alpha: 0.11,
                                          ),
                                        ),
                                      ),
                                    ),
                                    Positioned(
                                      left: -24,
                                      bottom: -28,
                                      child: Container(
                                        width: 110,
                                        height: 110,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: Colors.white.withValues(
                                            alpha: 0.07,
                                          ),
                                        ),
                                      ),
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.all(
                                        TryprSpacing.lg,
                                      ),
                                      child:
                                          isCompact
                                              ? Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Row(
                                                    children: [
                                                      CircleAvatar(
                                                        radius: 28,
                                                        backgroundColor: Colors
                                                            .white
                                                            .withValues(
                                                              alpha: 0.22,
                                                            ),
                                                        backgroundImage:
                                                            profileProvider,
                                                        child:
                                                            profileProvider ==
                                                                    null
                                                                ? Text(
                                                                  initials,
                                                                  style: const TextStyle(
                                                                    color:
                                                                        Colors
                                                                            .white,
                                                                    fontWeight:
                                                                        FontWeight
                                                                            .w700,
                                                                  ),
                                                                )
                                                                : null,
                                                      ),
                                                      const SizedBox(
                                                        width: TryprSpacing.md,
                                                      ),
                                                      Expanded(
                                                        child: Column(
                                                          crossAxisAlignment:
                                                              CrossAxisAlignment
                                                                  .start,
                                                          children: [
                                                            Text(
                                                              displayName
                                                                  .toString(),
                                                              style: Theme.of(
                                                                    context,
                                                                  )
                                                                  .textTheme
                                                                  .headlineSmall
                                                                  ?.copyWith(
                                                                    color:
                                                                        Colors
                                                                            .white,
                                                                    fontWeight:
                                                                        FontWeight
                                                                            .w700,
                                                                  ),
                                                            ),
                                                            const SizedBox(
                                                              height: 2,
                                                            ),
                                                            Text(
                                                              email.toString(),
                                                              style: const TextStyle(
                                                                color:
                                                                    Colors
                                                                        .white,
                                                                fontSize: 13,
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                  const SizedBox(
                                                    height: TryprSpacing.md,
                                                  ),
                                                  Wrap(
                                                    spacing: 8,
                                                    runSpacing: 8,
                                                    children: [
                                                      _heroPill(
                                                        Icons.workspace_premium,
                                                        subscription.toString(),
                                                      ),
                                                      _heroPill(
                                                        Icons.public,
                                                        '$visitedCount countries',
                                                      ),
                                                      _heroPill(
                                                        Icons
                                                            .people_alt_outlined,
                                                        '${friends.length} friends',
                                                      ),
                                                    ],
                                                  ),
                                                ],
                                              )
                                              : Row(
                                                children: [
                                                  CircleAvatar(
                                                    radius: 34,
                                                    backgroundColor: Colors
                                                        .white
                                                        .withValues(
                                                          alpha: 0.22,
                                                        ),
                                                    backgroundImage:
                                                        profileProvider,
                                                    child:
                                                        profileProvider == null
                                                            ? Text(
                                                              initials,
                                                              style: const TextStyle(
                                                                color:
                                                                    Colors
                                                                        .white,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w700,
                                                                fontSize: 20,
                                                              ),
                                                            )
                                                            : null,
                                                  ),
                                                  const SizedBox(
                                                    width: TryprSpacing.md,
                                                  ),
                                                  Expanded(
                                                    child: Column(
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .start,
                                                      children: [
                                                        Text(
                                                          displayName
                                                              .toString(),
                                                          style: Theme.of(
                                                                context,
                                                              )
                                                              .textTheme
                                                              .headlineSmall
                                                              ?.copyWith(
                                                                color:
                                                                    Colors
                                                                        .white,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w700,
                                                              ),
                                                        ),
                                                        const SizedBox(
                                                          height: 4,
                                                        ),
                                                        Text(
                                                          email.toString(),
                                                          style:
                                                              const TextStyle(
                                                                color:
                                                                    Colors
                                                                        .white,
                                                                fontSize: 14,
                                                              ),
                                                        ),
                                                        const SizedBox(
                                                          height: 10,
                                                        ),
                                                        Wrap(
                                                          spacing: 8,
                                                          runSpacing: 8,
                                                          children: [
                                                            _heroPill(
                                                              Icons.location_on,
                                                              cityText == '—'
                                                                  ? 'City not set'
                                                                  : cityText,
                                                            ),
                                                            _heroPill(
                                                              Icons
                                                                  .badge_outlined,
                                                              sex.toString(),
                                                            ),
                                                            _heroPill(
                                                              Icons
                                                                  .cake_outlined,
                                                              dobStr,
                                                            ),
                                                            _heroPill(
                                                              Icons
                                                                  .workspace_premium,
                                                              subscription
                                                                  .toString(),
                                                            ),
                                                          ],
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ],
                                              ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: TryprSpacing.lg),
                              LayoutBuilder(
                                builder: (statsCtx, statsBox) {
                                  final cards = <Widget>[
                                    _metricTile(
                                      icon: Icons.public,
                                      label: 'Countries visited',
                                      value: '$visitedCount',
                                      accent: TryprColors.primary,
                                    ),
                                    _metricTile(
                                      icon: Icons.route_outlined,
                                      label: 'World coverage',
                                      value: '$progressPercent%',
                                      accent: TryprColors.secondary,
                                    ),
                                    _metricTile(
                                      icon: Icons.people_alt_outlined,
                                      label: 'Friends',
                                      value: '${friends.length}',
                                      accent: TryprColors.peach,
                                    ),
                                    _metricTile(
                                      icon: Icons.workspace_premium_outlined,
                                      label: 'Membership',
                                      value: subscription.toString(),
                                      accent: TryprColors.mint,
                                    ),
                                  ];

                                  if (statsBox.maxWidth < 760) {
                                    return Column(
                                      children: [
                                        for (
                                          var i = 0;
                                          i < cards.length;
                                          i++
                                        ) ...[
                                          cards[i],
                                          if (i < cards.length - 1)
                                            const SizedBox(
                                              height: TryprSpacing.sm,
                                            ),
                                        ],
                                      ],
                                    );
                                  }

                                  return Row(
                                    children: [
                                      for (
                                        var i = 0;
                                        i < cards.length;
                                        i++
                                      ) ...[
                                        Expanded(child: cards[i]),
                                        if (i < cards.length - 1)
                                          const SizedBox(
                                            width: TryprSpacing.sm,
                                          ),
                                      ],
                                    ],
                                  );
                                },
                              ),
                              const SizedBox(height: TryprSpacing.lg),
                              _sectionContainer(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Container(
                                          width: 36,
                                          height: 36,
                                          decoration: BoxDecoration(
                                            color: TryprColors.secondary
                                                .withValues(alpha: 0.14),
                                            borderRadius: BorderRadius.circular(
                                              10,
                                            ),
                                          ),
                                          child: const Icon(
                                            Icons.people_outline,
                                            color: TryprColors.secondary,
                                          ),
                                        ),
                                        const SizedBox(width: TryprSpacing.md),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                'Travel Circle',
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .titleMedium
                                                    ?.copyWith(
                                                      fontWeight:
                                                          FontWeight.w700,
                                                      color:
                                                          TryprColors
                                                              .textPrimary,
                                                    ),
                                              ),
                                              Text(
                                                'People connected to your account',
                                                style:
                                                    Theme.of(
                                                      context,
                                                    ).textTheme.bodySmall,
                                              ),
                                            ],
                                          ),
                                        ),
                                        if (!isCompact)
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 10,
                                              vertical: 6,
                                            ),
                                            decoration: BoxDecoration(
                                              color: TryprColors.surfaceVariant,
                                              borderRadius:
                                                  BorderRadius.circular(
                                                    TryprRadius.full,
                                                  ),
                                            ),
                                            child: Text(
                                              '${friends.length} total',
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w600,
                                                fontSize: 12,
                                                color:
                                                    TryprColors.textSecondary,
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                    const SizedBox(height: TryprSpacing.md),
                                    if (friends.isEmpty)
                                      Container(
                                        width: double.infinity,
                                        padding: const EdgeInsets.all(
                                          TryprSpacing.md,
                                        ),
                                        decoration: BoxDecoration(
                                          color: TryprColors.surfaceVariant,
                                          borderRadius: BorderRadius.circular(
                                            TryprRadius.md,
                                          ),
                                        ),
                                        child: Text(
                                          'No friends added yet. Invite someone and start planning together.',
                                          style:
                                              Theme.of(
                                                context,
                                              ).textTheme.bodyMedium,
                                        ),
                                      )
                                    else
                                      Wrap(
                                        spacing: TryprSpacing.sm,
                                        runSpacing: TryprSpacing.sm,
                                        children:
                                            friends.map((f) {
                                              final fname =
                                                  (f['name'] ??
                                                          f['displayName'] ??
                                                          f['email'] ??
                                                          f['id'] ??
                                                          'Friend')
                                                      .toString();
                                              final accent = _chipAccent(fname);
                                              return Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 10,
                                                      vertical: 8,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: accent.withValues(
                                                    alpha: 0.12,
                                                  ),
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                        TryprRadius.full,
                                                      ),
                                                  border: Border.all(
                                                    color: accent.withValues(
                                                      alpha: 0.3,
                                                    ),
                                                  ),
                                                ),
                                                child: Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    CircleAvatar(
                                                      radius: 11,
                                                      backgroundColor: accent
                                                          .withValues(
                                                            alpha: 0.22,
                                                          ),
                                                      child: Text(
                                                        _initialsFor(fname),
                                                        style: const TextStyle(
                                                          fontSize: 10,
                                                          fontWeight:
                                                              FontWeight.w700,
                                                          color:
                                                              TryprColors
                                                                  .textPrimary,
                                                        ),
                                                      ),
                                                    ),
                                                    const SizedBox(width: 8),
                                                    ConstrainedBox(
                                                      constraints:
                                                          BoxConstraints(
                                                            maxWidth:
                                                                isCompact
                                                                    ? 170
                                                                    : 220,
                                                          ),
                                                      child: Text(
                                                        fname,
                                                        overflow:
                                                            TextOverflow
                                                                .ellipsis,
                                                        style: const TextStyle(
                                                          fontWeight:
                                                              FontWeight.w600,
                                                          fontSize: 13,
                                                          color:
                                                              TryprColors
                                                                  .textPrimary,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              );
                                            }).toList(),
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: TryprSpacing.md),
                              _sectionContainer(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Container(
                                          width: 36,
                                          height: 36,
                                          decoration: BoxDecoration(
                                            color: TryprColors.primary
                                                .withValues(alpha: 0.14),
                                            borderRadius: BorderRadius.circular(
                                              10,
                                            ),
                                          ),
                                          child: const Icon(
                                            Icons.travel_explore,
                                            color: TryprColors.primary,
                                          ),
                                        ),
                                        const SizedBox(width: TryprSpacing.md),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                'My Travel Map',
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .titleMedium
                                                    ?.copyWith(
                                                      fontWeight:
                                                          FontWeight.w700,
                                                    ),
                                              ),
                                              Text(
                                                'Tap countries to mark places you have visited',
                                                style:
                                                    Theme.of(
                                                      context,
                                                    ).textTheme.bodySmall,
                                              ),
                                            ],
                                          ),
                                        ),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 6,
                                          ),
                                          decoration: BoxDecoration(
                                            color: TryprColors.primary
                                                .withValues(alpha: 0.12),
                                            borderRadius: BorderRadius.circular(
                                              TryprRadius.full,
                                            ),
                                          ),
                                          child: Text(
                                            '$progressPercent% explored',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                              fontSize: 12,
                                              color: TryprColors.primaryDark,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: TryprSpacing.md),
                                    SizedBox(
                                      height: isCompact ? 320 : 460,
                                      child: Card(
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            TryprRadius.md,
                                          ),
                                        ),
                                        clipBehavior: Clip.antiAlias,
                                        child: Padding(
                                          padding: const EdgeInsets.all(8),
                                          child: Builder(
                                            builder: (mapCtx) {
                                              if (_stagedVisited.isEmpty) {
                                                _stagedVisited.addAll(
                                                  visitedSet,
                                                );
                                              }
                                              _loadCountryPolygons();

                                              if (_mapsKey.isEmpty) {
                                                return const Center(
                                                  child: Padding(
                                                    padding: EdgeInsets.all(
                                                      TryprSpacing.md,
                                                    ),
                                                    child: Text(
                                                      'Google Maps is not configured. Build with '
                                                      '--dart-define=GOOGLE_MAPS_API_KEY=YOUR_KEY',
                                                      textAlign:
                                                          TextAlign.center,
                                                    ),
                                                  ),
                                                );
                                              }

                                              return gmaps.GoogleMap(
                                                initialCameraPosition:
                                                    const gmaps.CameraPosition(
                                                      target: gmaps.LatLng(
                                                        20,
                                                        0,
                                                      ),
                                                      zoom: 2,
                                                    ),
                                                minMaxZoomPreference:
                                                    const gmaps.MinMaxZoomPreference(
                                                      2,
                                                      18,
                                                    ),
                                                polygons:
                                                    _polygonsLoaded
                                                        ? _buildGmapPolygonsSet(
                                                          _stagedVisited,
                                                        )
                                                        : const <
                                                          gmaps.Polygon
                                                        >{},
                                                markers:
                                                    _polygonsLoaded
                                                        ? _buildGmapMarkersForMissingPolygons(
                                                          _stagedVisited,
                                                        )
                                                        : _buildGmapMarkers(
                                                          _stagedVisited,
                                                        ),
                                                onTap: (p) {
                                                  if (!_polygonsLoaded) {
                                                    return;
                                                  }

                                                  final latlng = LatLng(
                                                    p.latitude,
                                                    p.longitude,
                                                  );
                                                  String? foundKey;
                                                  _countryPolygons.forEach((
                                                    k,
                                                    polyRings,
                                                  ) {
                                                    for (final ring
                                                        in polyRings) {
                                                      if (_pointInPolygon(
                                                        latlng,
                                                        ring,
                                                      )) {
                                                        foundKey = k;
                                                        break;
                                                      }
                                                    }
                                                  });

                                                  if (foundKey == null) {
                                                    return;
                                                  }
                                                  final display =
                                                      _normalizeCountryName(
                                                        foundKey!,
                                                      );
                                                  if (_stagedVisited.contains(
                                                    display,
                                                  )) {
                                                    return;
                                                  }
                                                  setState(() {
                                                    _stagedVisited.add(display);
                                                    _isEditingVisited = true;
                                                  });
                                                },
                                                mapToolbarEnabled: false,
                                                myLocationButtonEnabled: false,
                                                zoomControlsEnabled: false,
                                                compassEnabled: false,
                                                rotateGesturesEnabled: false,
                                                tiltGesturesEnabled: false,
                                              );
                                            },
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: TryprSpacing.md),
                                    if (isCompact) ...[
                                      Row(
                                        children: [
                                          Expanded(
                                            child: LinearProgressIndicator(
                                              value: progressValue,
                                              minHeight: 8,
                                            ),
                                          ),
                                          const SizedBox(
                                            width: TryprSpacing.sm,
                                          ),
                                          Text('$progressPercent%'),
                                        ],
                                      ),
                                      const SizedBox(height: TryprSpacing.sm),
                                      SizedBox(
                                        width: double.infinity,
                                        child: ElevatedButton.icon(
                                          onPressed:
                                              _isEditingVisited
                                                  ? persistVisited
                                                  : null,
                                          icon: const Icon(Icons.save_outlined),
                                          label: const Text('Save travel map'),
                                        ),
                                      ),
                                    ] else ...[
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Row(
                                              children: [
                                                Expanded(
                                                  child:
                                                      LinearProgressIndicator(
                                                        value: progressValue,
                                                        minHeight: 8,
                                                      ),
                                                ),
                                                const SizedBox(width: 10),
                                                Text('$progressPercent%'),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          ElevatedButton.icon(
                                            onPressed:
                                                _isEditingVisited
                                                    ? persistVisited
                                                    : null,
                                            icon: const Icon(
                                              Icons.save_outlined,
                                            ),
                                            label: const Text(
                                              'Save travel map',
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                    const SizedBox(height: TryprSpacing.sm),
                                    Text(
                                      '$visitedCount visited / $totalSupported supported',
                                      style:
                                          Theme.of(context).textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: TryprSpacing.md),
                              _sectionContainer(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Container(
                                          width: 36,
                                          height: 36,
                                          decoration: BoxDecoration(
                                            color: TryprColors.peach.withValues(
                                              alpha: 0.18,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              10,
                                            ),
                                          ),
                                          child: const Icon(
                                            Icons.flag_outlined,
                                            color: TryprColors.warning,
                                          ),
                                        ),
                                        const SizedBox(width: TryprSpacing.md),
                                        Expanded(
                                          child: Text(
                                            'Visited Regions',
                                            style: Theme.of(
                                              context,
                                            ).textTheme.titleMedium?.copyWith(
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 5,
                                          ),
                                          decoration: BoxDecoration(
                                            color: TryprColors.surfaceVariant,
                                            borderRadius: BorderRadius.circular(
                                              TryprRadius.full,
                                            ),
                                          ),
                                          child: Text(
                                            '${visitedSet.length}',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: TryprSpacing.md),
                                    if (visitedSet.isNotEmpty)
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        children:
                                            sortedVisited.map((c) {
                                              final accent = _chipAccent(c);
                                              return Chip(
                                                label: Text(
                                                  c,
                                                  style: const TextStyle(
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w600,
                                                    color:
                                                        TryprColors.textPrimary,
                                                  ),
                                                ),
                                                side: BorderSide(
                                                  color: accent.withValues(
                                                    alpha: 0.28,
                                                  ),
                                                ),
                                                backgroundColor: accent
                                                    .withValues(alpha: 0.12),
                                                deleteIconColor: accent,
                                                visualDensity:
                                                    VisualDensity.compact,
                                                onDeleted:
                                                    () => _toggleRegion(
                                                      c,
                                                      visitedRaw,
                                                    ),
                                              );
                                            }).toList(),
                                      )
                                    else
                                      Container(
                                        width: double.infinity,
                                        padding: const EdgeInsets.all(
                                          TryprSpacing.md,
                                        ),
                                        decoration: BoxDecoration(
                                          color: TryprColors.surfaceVariant,
                                          borderRadius: BorderRadius.circular(
                                            TryprRadius.md,
                                          ),
                                        ),
                                        child: Text(
                                          'No regions marked yet. Use the map above to start building your footprint.',
                                          style:
                                              Theme.of(
                                                context,
                                              ).textTheme.bodyMedium,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: TryprSpacing.lg),
                              if (isCompact) ...[
                                SizedBox(
                                  width: double.infinity,
                                  child: ElevatedButton.icon(
                                    onPressed: () {
                                      _showEditProfile(context, data);
                                    },
                                    icon: const Icon(Icons.edit),
                                    label: const Text('Edit profile'),
                                  ),
                                ),
                                const SizedBox(height: TryprSpacing.sm),
                                SizedBox(
                                  width: double.infinity,
                                  child: OutlinedButton.icon(
                                    onPressed: () async {
                                      await FirebaseAuth.instance.signOut();
                                      if (!ctx.mounted) return;
                                      Navigator.of(ctx).pushNamedAndRemoveUntil(
                                        '/sign-in',
                                        (route) => false,
                                      );
                                      ScaffoldMessenger.of(
                                        ctx,
                                      ).showTryprSnackBar(
                                        const SnackBar(
                                          content: Text('Signed out'),
                                        ),
                                      );
                                    },
                                    icon: const Icon(Icons.logout),
                                    label: const Text('Sign out'),
                                  ),
                                ),
                              ] else ...[
                                Wrap(
                                  spacing: TryprSpacing.sm,
                                  runSpacing: TryprSpacing.sm,
                                  children: [
                                    ElevatedButton.icon(
                                      onPressed: () {
                                        _showEditProfile(context, data);
                                      },
                                      icon: const Icon(Icons.edit),
                                      label: const Text('Edit profile'),
                                    ),
                                    const SizedBox(width: 12),
                                    OutlinedButton.icon(
                                      onPressed: () async {
                                        await FirebaseAuth.instance.signOut();
                                        if (!ctx.mounted) return;
                                        Navigator.of(
                                          ctx,
                                        ).pushNamedAndRemoveUntil(
                                          '/sign-in',
                                          (route) => false,
                                        );
                                        ScaffoldMessenger.of(
                                          ctx,
                                        ).showTryprSnackBar(
                                          const SnackBar(
                                            content: Text('Signed out'),
                                          ),
                                        );
                                      },
                                      icon: const Icon(Icons.logout),
                                      label: const Text('Sign out'),
                                    ),
                                  ],
                                ),
                              ],
                              const SizedBox(height: TryprSpacing.sm),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: TextButton.icon(
                                  onPressed: () {
                                    showDialog<void>(
                                      context: ctx,
                                      builder:
                                          (dialogCtx) => AlertDialog(
                                            title: const Text(
                                              'Raw user document',
                                            ),
                                            content: SingleChildScrollView(
                                              child: SelectableText(
                                                JsonEncoder.withIndent(
                                                  '  ',
                                                ).convert(data),
                                              ),
                                            ),
                                            actions: [
                                              TextButton(
                                                onPressed:
                                                    () =>
                                                        Navigator.of(
                                                          dialogCtx,
                                                        ).pop(),
                                                child: const Text('Close'),
                                              ),
                                            ],
                                          ),
                                    );
                                  },
                                  icon: const Icon(Icons.bug_report_outlined),
                                  label: const Text('Show raw doc'),
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
    );
  }

  Widget _signedOutContent(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [
                Color(0xFF1F6FAE),
                TryprColors.primary,
                Color(0xFF2BA9A0),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(TryprRadius.xl),
          ),
          padding: const EdgeInsets.all(TryprSpacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Account',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Sign in to view your profile, travel map, and social circle.',
                style: TextStyle(color: Colors.white, fontSize: 14),
              ),
              const SizedBox(height: TryprSpacing.lg),
              ElevatedButton.icon(
                onPressed: () => Navigator.of(context).pushNamed('/sign-in'),
                icon: const Icon(Icons.login),
                label: const Text('Sign in'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: TryprColors.primaryDark,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // Show bottom sheet to edit profile fields: name, city, dob, sex, visited countries
  Future<void> _showEditProfile(
    BuildContext context,
    Map<String, dynamic> data,
  ) async {
    final uid = _user?.uid;
    if (uid == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder:
          (ctx) => Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: _EditProfileSheet(
              uid: uid,
              data: Map<String, dynamic>.from(data),
            ),
          ),
    );
  }
}

class _EditProfileSheet extends StatefulWidget {
  final String uid;
  final Map<String, dynamic> data;

  const _EditProfileSheet({required this.uid, required this.data});

  @override
  State<_EditProfileSheet> createState() => _EditProfileSheetState();
}

class _EditProfileSheetState extends State<_EditProfileSheet> {
  late TextEditingController nameCtl;
  late TextEditingController cityCtl;
  DateTime? dob;
  String sex = 'male';
  final Set<String> visited = {};
  String? localProfileImage;
  bool removeImage = false;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    final data = widget.data;
    nameCtl = TextEditingController(
      text: (data['name'] ?? data['displayName'] ?? '').toString(),
    );
    cityCtl = TextEditingController(text: (data['city'] ?? '').toString());
    if (data['dob'] is String) {
      try {
        dob = DateTime.parse(data['dob']);
      } catch (_) {}
    } else if (data['dob'] is Timestamp) {
      dob = (data['dob'] as Timestamp).toDate();
    }
    final s = (data['sex'] ?? data['gender'] ?? '').toString().toLowerCase();
    if (s == 'female') sex = 'female';
    final vc = data['visitedCountries'] as List<dynamic>?;
    if (vc != null) visited.addAll(vc.map((e) => e.toString()));
    localProfileImage = data['profileImageDataUrl'] as String?;
  }

  @override
  void dispose() {
    nameCtl.dispose();
    cityCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isCompact = MediaQuery.sizeOf(context).width < 640;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.9,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(TryprSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Edit profile',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: TryprSpacing.md),
              Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextFormField(
                      controller: nameCtl,
                      decoration: const InputDecoration(labelText: 'Name'),
                    ),
                    const SizedBox(height: TryprSpacing.sm),
                    TextFormField(
                      controller: cityCtl,
                      decoration: const InputDecoration(labelText: 'City'),
                    ),
                    const SizedBox(height: TryprSpacing.sm),
                    Wrap(
                      spacing: TryprSpacing.md,
                      runSpacing: TryprSpacing.sm,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        CircleAvatar(
                          radius: 36,
                          backgroundColor: TryprColors.surfaceVariant,
                          backgroundImage:
                              localProfileImage != null
                                  ? (kIsWeb
                                      ? NetworkImage(localProfileImage!)
                                      : MemoryImage(
                                            base64Decode(
                                              localProfileImage!
                                                  .split(',')
                                                  .last,
                                            ),
                                          )
                                          as ImageProvider)
                                  : null,
                          child:
                              localProfileImage == null
                                  ? const Icon(
                                    Icons.person,
                                    size: 36,
                                    color: TryprColors.textTertiary,
                                  )
                                  : null,
                        ),
                        ElevatedButton.icon(
                          onPressed: _onUploadPressed,
                          icon: const Icon(Icons.upload_file),
                          label: const Text('Upload profile picture'),
                        ),
                        if (localProfileImage != null)
                          TextButton(
                            onPressed: () {
                              setState(() {
                                localProfileImage = null;
                                removeImage = true;
                              });
                            },
                            child: const Text('Remove'),
                          ),
                      ],
                    ),
                    const SizedBox(height: TryprSpacing.sm),
                    if (isCompact) ...[
                      InputDecorator(
                        decoration: const InputDecoration(labelText: 'Sex'),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: sex,
                            items: const [
                              DropdownMenuItem(
                                value: 'male',
                                child: Text('Male'),
                              ),
                              DropdownMenuItem(
                                value: 'female',
                                child: Text('Female'),
                              ),
                            ],
                            onChanged: (v) => setState(() => sex = v ?? 'male'),
                          ),
                        ),
                      ),
                      const SizedBox(height: TryprSpacing.sm),
                      _dobPicker(context),
                    ] else ...[
                      Row(
                        children: [
                          Expanded(
                            child: InputDecorator(
                              decoration: const InputDecoration(
                                labelText: 'Sex',
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  value: sex,
                                  items: const [
                                    DropdownMenuItem(
                                      value: 'male',
                                      child: Text('Male'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'female',
                                      child: Text('Female'),
                                    ),
                                  ],
                                  onChanged:
                                      (v) => setState(() => sex = v ?? 'male'),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: TryprSpacing.md),
                          Expanded(child: _dobPicker(context)),
                        ],
                      ),
                    ],
                    const SizedBox(height: TryprSpacing.md),
                    if (isCompact) ...[
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: _onSavePressed,
                          child: const Text('Save'),
                        ),
                      ),
                      const SizedBox(height: TryprSpacing.sm),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Cancel'),
                        ),
                      ),
                    ] else ...[
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton(
                              onPressed: _onSavePressed,
                              child: const Text('Save'),
                            ),
                          ),
                          const SizedBox(width: TryprSpacing.md),
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => Navigator.of(context).pop(),
                              child: const Text('Cancel'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dobPicker(BuildContext context) {
    return InputDecorator(
      decoration: const InputDecoration(labelText: 'Date of birth'),
      child: InkWell(
        onTap: () async {
          final now = DateTime.now();
          final picked = await showDatePicker(
            context: context,
            initialDate: dob ?? DateTime(now.year - 25),
            firstDate: DateTime(1900),
            lastDate: DateTime(now.year),
          );
          if (picked != null && mounted) {
            setState(() => dob = picked);
          }
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12.0),
          child: Text(
            dob != null
                ? '${dob!.year}-${dob!.month.toString().padLeft(2, '0')}-${dob!.day.toString().padLeft(2, '0')}'
                : 'Select date',
          ),
        ),
      ),
    );
  }

  Future<void> _onUploadPressed() async {
    final picked = await pickImageDataUrl();
    if (picked == null || !mounted) return;
    setState(() {
      localProfileImage = picked;
      removeImage = false;
    });
  }

  Future<void> _onSavePressed() async {
    if (!_formKey.currentState!.validate()) return;
    final docRef = FirebaseFirestore.instance
        .collection('users')
        .doc(widget.uid);
    final upd = <String, dynamic>{
      'name': nameCtl.text.trim(),
      'displayName': nameCtl.text.trim(),
      'displayNameLower': nameCtl.text.trim().toLowerCase(),
      'city': cityCtl.text.trim(),
      'sex': sex,
      'dob': dob?.toIso8601String(),
      'visitedCountries': visited.toList(),
    };
    if (localProfileImage != null) {
      upd['profileImageDataUrl'] = localProfileImage;
    }
    if (removeImage) {
      upd['profileImageDataUrl'] = FieldValue.delete();
    }
    upd.removeWhere((k, v) => v == null || (v is String && v.isEmpty));

    try {
      await docRef.set(upd, SetOptions(merge: true));
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(
        context,
      ).showTryprSnackBar(const SnackBar(content: Text('Profile updated')));
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context).showTryprSnackBar(
          SnackBar(content: Text('Failed to save profile: $err')),
        );
      }
    }
  }
}
