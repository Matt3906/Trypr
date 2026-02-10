import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:trypr/services/geocode.dart';
import 'package:trypr/services/pick_image_data_url.dart';
import 'package:trypr/widgets/map_embed.dart';

class VerifiedTripBuilderScreen extends StatefulWidget {
  final String? existingTripId;
  final Map<String, dynamic>? existingTripData;

  const VerifiedTripBuilderScreen({
    super.key,
    this.existingTripId,
    this.existingTripData,
  });

  @override
  State<VerifiedTripBuilderScreen> createState() =>
      _VerifiedTripBuilderScreenState();

  static Route<void> route({
    String? existingTripId,
    Map<String, dynamic>? existingTripData,
  }) {
    return MaterialPageRoute<void>(
      builder:
          (_) => VerifiedTripBuilderScreen(
            existingTripId: existingTripId,
            existingTripData: existingTripData,
          ),
    );
  }
}

class _Waypoint {
  final String name;
  final double lat;
  final double lon;
  int days;

  _Waypoint({
    required this.name,
    required this.lat,
    required this.lon,
    this.days = 2,
  });
}

class _VerifiedTripBuilderScreenState extends State<VerifiedTripBuilderScreen> {
  final _formKey = GlobalKey<FormState>();

  // Travel-themed categories with colors for activities
  static const travelCategories = {
    'Hiking': Color(0xFF2E7D32),
    'Biking': Color(0xFF1565C0),
    'Walking': Color(0xFF00796B),
    'Museum': Color(0xFF6A1B9A),
    'Sightseeing': Color(0xFFF57C00),
    'Exploring': Color(0xFFC62828),
    'Restaurant': Color(0xFFD32F2F),
    'Shopping': Color(0xFF7B1FA2),
    'Photography': Color(0xFF0277BD),
    'Adventure': Color(0xFFFBC02D),
    'Driving': Colors.blueAccent,
  };

  final _titleCtl = TextEditingController();
  final _subtitleCtl = TextEditingController();
  final _descCtl = TextEditingController();
  String _coverImage = '';

  final _searchCtl = TextEditingController();
  Timer? _searchDebounce;
  List<Map<String, dynamic>> _searchResults = [];

  final List<String> _photoUrls = [];
  final List<_Waypoint> _waypoints = [];

  // Per-day itinerary for verified trips.
  // Stored as: [{'title': 'Day 1', 'notes': '', 'activities': [{'time':'', 'title':'', 'description':''}, ...]}, ...]
  final List<Map<String, dynamic>> _itinerary = [];

  bool _saving = false;

  bool _suspendMapTap = false;

  Future<T?> _withMapTapSuspended<T>(Future<T?> Function() action) async {
    if (!mounted) return null;
    setState(() => _suspendMapTap = true);
    try {
      return await action();
    } finally {
      if (mounted) setState(() => _suspendMapTap = false);
    }
  }

  @override
  void dispose() {
    _titleCtl.dispose();
    _subtitleCtl.dispose();
    _descCtl.dispose();
    _searchDebounce?.cancel();
    _searchCtl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _populateFromExistingTrip();
  }

  void _populateFromExistingTrip() {
    final data = widget.existingTripData;
    if (data == null) return;

    _titleCtl.text = data['title']?.toString() ?? '';
    _subtitleCtl.text = data['subtitle']?.toString() ?? '';
    _descCtl.text = data['description']?.toString() ?? '';
    _coverImage = data['coverImage']?.toString() ?? '';

    // Populate photos
    final photos = data['photos'];
    if (photos is List) {
      _photoUrls.clear();
      for (final p in photos) {
        if (p is String && p.isNotEmpty) {
          _photoUrls.add(p);
        }
      }
    }

    // Populate waypoints
    final waypoints = data['waypoints'];
    if (waypoints is List) {
      _waypoints.clear();
      for (final w in waypoints) {
        if (w is Map) {
          final name = w['name']?.toString() ?? '';
          final lat = (w['lat'] is num) ? (w['lat'] as num).toDouble() : 0.0;
          final lon = (w['lon'] is num) ? (w['lon'] as num).toDouble() : 0.0;
          final days = (w['days'] is num) ? (w['days'] as num).toInt() : 2;
          if (name.isNotEmpty) {
            _waypoints.add(
              _Waypoint(name: name, lat: lat, lon: lon, days: days),
            );
          }
        }
      }
    }

    // Populate itinerary
    final itinerary = data['itinerary'];
    if (itinerary is List) {
      _itinerary.clear();
      for (final day in itinerary) {
        if (day is Map) {
          final dayMap = <String, dynamic>{
            'title': day['title']?.toString() ?? '',
            'notes': day['notes']?.toString() ?? '',
            'activities': <Map<String, dynamic>>[],
          };
          final activities = day['activities'];
          if (activities is List) {
            for (final a in activities) {
              if (a is Map) {
                (dayMap['activities'] as List).add({
                  'time': a['time']?.toString() ?? '',
                  'title': a['title']?.toString() ?? '',
                  'description': a['description']?.toString() ?? '',
                });
              }
            }
          }
          _itinerary.add(dayMap);
        }
      }
    }
  }

  String _trim(String v) => v.trim();

  ({Uint8List bytes, String contentType})? _decodeDataUrl(String dataUrl) {
    final raw = dataUrl.trim();
    if (!raw.startsWith('data:')) return null;
    final comma = raw.indexOf(',');
    if (comma <= 0) return null;

    final header = raw.substring(0, comma); // data:image/png;base64
    final payload = raw.substring(comma + 1);

    String contentType = 'image/jpeg';
    if (header.startsWith('data:')) {
      final meta = header.substring(5);
      final parts = meta.split(';');
      if (parts.isNotEmpty && parts.first.trim().isNotEmpty) {
        contentType = parts.first.trim();
      }
    }

    try {
      return (bytes: base64Decode(payload), contentType: contentType);
    } catch (_) {
      return null;
    }
  }

  String _extForContentType(String contentType) {
    final ct = contentType.toLowerCase();
    if (ct.contains('png')) return 'png';
    if (ct.contains('webp')) return 'webp';
    if (ct.contains('gif')) return 'gif';
    return 'jpg';
  }

  Future<String> _uploadVerifiedTripImage({
    required String tripId,
    required String label,
    required String dataUrl,
  }) async {
    final decoded = _decodeDataUrl(dataUrl);
    if (decoded == null) {
      throw Exception('Unsupported image format');
    }

    final ts = DateTime.now().millisecondsSinceEpoch;
    final ext = _extForContentType(decoded.contentType);
    final ref = FirebaseStorage.instance.ref(
      'verifiedTrips/$tripId/${label}_$ts.$ext',
    );

    final meta = SettableMetadata(contentType: decoded.contentType);
    final task = await ref.putData(decoded.bytes, meta);
    return task.ref.getDownloadURL();
  }

  int get _recommendedDays {
    var total = 0;
    for (final w in _waypoints) {
      total += w.days;
    }
    return total;
  }

  Map<String, dynamic> _newDay(int dayNumber) {
    return {
      'title': 'Day $dayNumber',
      'notes': '',
      'activities': <Map<String, dynamic>>[],
    };
  }

  void _ensureItineraryLength(int dayCount) {
    final desired = dayCount < 0 ? 0 : dayCount;
    while (_itinerary.length < desired) {
      _itinerary.add(_newDay(_itinerary.length + 1));
    }
    while (_itinerary.length > desired) {
      _itinerary.removeLast();
    }
    // Keep titles sane if days were added/removed.
    for (var i = 0; i < _itinerary.length; i++) {
      final day = _itinerary[i];
      day['title'] =
          (day['title'] as String?)?.trim().isNotEmpty == true
              ? day['title']
              : 'Day ${i + 1}';
    }
  }

  Future<Map<String, String>?> _promptActivity({
    required String dayTitle,
    Map<String, dynamic>? initial,
  }) async {
    final timeCtl = TextEditingController(
      text: (initial?['time'] ?? '').toString(),
    );
    final titleCtl = TextEditingController(
      text: (initial?['title'] ?? '').toString(),
    );
    final descCtl = TextEditingController(
      text: (initial?['description'] ?? '').toString(),
    );
    final locationCtl = TextEditingController(
      text: (initial?['location'] ?? '').toString(),
    );

    String selectedCategory =
        (initial?['category'] ?? '').toString().isEmpty
            ? 'Sightseeing'
            : (initial?['category'] ?? 'Sightseeing').toString();

    List<Map<String, dynamic>> locationSuggestions = [];
    Map<String, dynamic>? selectedLocation;
    bool searchingLocation = false;
    Timer? locationDebounce;

    return showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              title: const Text('Edit Activity'),
              content: SingleChildScrollView(
                child: SizedBox(
                  width: 480,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          dayTitle,
                          style: Theme.of(ctx).textTheme.bodySmall,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: timeCtl,
                        decoration: const InputDecoration(
                          labelText: 'Time (e.g. 9:00 AM)',
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: titleCtl,
                        decoration: const InputDecoration(labelText: 'Title'),
                      ),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<String>(
                        value: selectedCategory,
                        decoration: const InputDecoration(
                          labelText: 'Category',
                          prefixIcon: Icon(Icons.category),
                        ),
                        items:
                            travelCategories.keys.map((cat) {
                              return DropdownMenuItem(
                                value: cat,
                                child: Row(
                                  children: [
                                    Container(
                                      width: 16,
                                      height: 16,
                                      margin: const EdgeInsets.only(right: 8),
                                      decoration: BoxDecoration(
                                        color: travelCategories[cat],
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    Text(cat),
                                  ],
                                ),
                              );
                            }).toList(),
                        onChanged: (v) {
                          setStateDialog(() {
                            selectedCategory = v ?? 'Sightseeing';
                          });
                        },
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: locationCtl,
                        decoration: InputDecoration(
                          labelText: 'Location (optional - add to map)',
                          prefixIcon: const Icon(Icons.place),
                          suffixIcon:
                              searchingLocation
                                  ? const Padding(
                                    padding: EdgeInsets.all(12),
                                    child: SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  )
                                  : null,
                        ),
                        onChanged: (v) {
                          locationDebounce?.cancel();
                          if (v.trim().isEmpty) {
                            setStateDialog(() {
                              locationSuggestions = [];
                              selectedLocation = null;
                            });
                            return;
                          }
                          locationDebounce = Timer(
                            const Duration(milliseconds: 400),
                            () async {
                              setStateDialog(() => searchingLocation = true);
                              try {
                                final results = await searchNominatim(v.trim());
                                setStateDialog(() {
                                  locationSuggestions = results;
                                  searchingLocation = false;
                                });
                              } catch (e) {
                                setStateDialog(() {
                                  locationSuggestions = [];
                                  searchingLocation = false;
                                });
                              }
                            },
                          );
                        },
                      ),
                      if (locationSuggestions.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Container(
                          constraints: const BoxConstraints(maxHeight: 150),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey.shade300),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: ListView.builder(
                            shrinkWrap: true,
                            itemCount: locationSuggestions.length,
                            itemBuilder: (ctx, i) {
                              final s = locationSuggestions[i];
                              final name = (s['name'] ?? '').toString();
                              return ListTile(
                                dense: true,
                                title: Text(name),
                                onTap: () {
                                  setStateDialog(() {
                                    locationCtl.text = name;
                                    selectedLocation = s;
                                    locationSuggestions = [];
                                  });
                                },
                              );
                            },
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      TextField(
                        controller: descCtl,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          labelText: 'Description (optional)',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(null),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () {
                    final title = titleCtl.text.trim();
                    if (title.isEmpty) return;
                    Navigator.of(ctx).pop({
                      'time': timeCtl.text.trim(),
                      'title': title,
                      'description': descCtl.text.trim(),
                      'location': locationCtl.text.trim(),
                      'category': selectedCategory,
                      'lat': selectedLocation?['lat']?.toString() ?? '',
                      'lon': selectedLocation?['lon']?.toString() ?? '',
                    });
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    ).then((result) {
      locationDebounce?.cancel();
      return result;
    });
  }

  double get _totalKm {
    double total = 0.0;
    for (var i = 1; i < _waypoints.length; i++) {
      total += _haversine(
        _waypoints[i - 1].lat,
        _waypoints[i - 1].lon,
        _waypoints[i].lat,
        _waypoints[i].lon,
      );
    }
    return total;
  }

  double _degToRad(double d) => d * math.pi / 180.0;

  double _haversine(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371.0;
    final dLat = _degToRad(lat2 - lat1);
    final dLon = _degToRad(lon2 - lon1);
    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_degToRad(lat1)) *
            math.cos(_degToRad(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return r * c;
  }

  Widget _imagePreview(String url, {double? height}) {
    final u = url.trim();
    if (u.isEmpty) {
      return SizedBox(height: height);
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child:
          u.startsWith('data:image')
              ? (kIsWeb
                  ? Image.network(
                    u,
                    height: height,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    errorBuilder:
                        (_, __, ___) => Container(
                          height: height,
                          alignment: Alignment.center,
                          color: Colors.black12,
                          child: const Text('Image failed to load'),
                        ),
                  )
                  : _dataUrlImage(u, height: height))
              : (u.startsWith('http')
                  ? Image.network(
                    u,
                    height: height,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    errorBuilder:
                        (_, __, ___) => Container(
                          height: height,
                          alignment: Alignment.center,
                          color: Colors.black12,
                          child: const Text('Image failed to load'),
                        ),
                  )
                  : Image.asset(
                    u,
                    height: height,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    errorBuilder:
                        (_, __, ___) => Container(
                          height: height,
                          alignment: Alignment.center,
                          color: Colors.black12,
                          child: const Text('Image failed to load'),
                        ),
                  )),
    );
  }

  Widget _dataUrlImage(String dataUrl, {double? height}) {
    try {
      final parts = dataUrl.split(',');
      if (parts.length < 2) {
        return Container(
          height: height,
          alignment: Alignment.center,
          color: Colors.black12,
          child: const Text('Image failed to load'),
        );
      }
      final bytes = base64Decode(parts.last);
      return Image.memory(
        bytes,
        height: height,
        width: double.infinity,
        fit: BoxFit.cover,
        errorBuilder:
            (_, __, ___) => Container(
              height: height,
              alignment: Alignment.center,
              color: Colors.black12,
              child: const Text('Image failed to load'),
            ),
      );
    } catch (_) {
      return Container(
        height: height,
        alignment: Alignment.center,
        color: Colors.black12,
        child: const Text('Image failed to load'),
      );
    }
  }

  Future<void> _uploadCover() async {
    final dataUrl = await pickImageDataUrl();
    if (dataUrl == null || dataUrl.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Photo upload is currently available on web only.'),
          ),
        );
      }
      return;
    }
    if (!mounted) return;
    setState(() => _coverImage = dataUrl);
  }

  Future<void> _addPhotoUpload() async {
    final dataUrl = await pickImageDataUrl();
    if (dataUrl == null || dataUrl.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Photo upload is currently available on web only.'),
          ),
        );
      }
      return;
    }
    if (!mounted) return;
    setState(() => _photoUrls.add(dataUrl));
  }

  Future<int?> _promptDays({
    required String locationName,
    int initialValue = 2,
  }) async {
    var value = initialValue.clamp(1, 21);
    return _withMapTapSuspended(
      () => showDialog<int>(
        context: context,
        builder: (ctx) {
          return AlertDialog(
            title: const Text('Recommended days here'),
            content: StatefulBuilder(
              builder: (ctx2, setState2) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      locationName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Text('Days:'),
                        const SizedBox(width: 12),
                        Expanded(
                          child: DropdownButton<int>(
                            value: value,
                            isExpanded: true,
                            items: List.generate(
                              21,
                              (i) => DropdownMenuItem(
                                value: i + 1,
                                child: Text('${i + 1} day${i == 0 ? '' : 's'}'),
                              ),
                            ),
                            onChanged: (v) {
                              if (v == null) return;
                              setState2(() => value = v);
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(null),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(value),
                child: const Text('Add'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _addWaypointFromResult({
    required String name,
    required double lat,
    required double lon,
  }) async {
    final days = await _promptDays(locationName: name);
    if (days == null) return;
    if (!mounted) return;
    setState(() {
      _waypoints.add(_Waypoint(name: name, lat: lat, lon: lon, days: days));
      _ensureItineraryLength(_recommendedDays);
      _searchResults = [];
      _searchCtl.clear();
    });
  }

  Future<void> _save() async {
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('You must be signed in to create a verified trip.'),
        ),
      );
      return;
    }

    if (!(_formKey.currentState?.validate() ?? false)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fix the highlighted fields.')),
      );
      return;
    }

    if (_waypoints.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Add at least one location to build the trip.'),
        ),
      );
      return;
    }

    final title = _trim(_titleCtl.text);
    final subtitle = _trim(_subtitleCtl.text);
    final description = _trim(_descCtl.text);
    final coverCandidate =
        _coverImage.trim().isNotEmpty
            ? _coverImage.trim()
            : (_photoUrls.isNotEmpty ? _photoUrls.first.trim() : '');

    setState(() => _saving = true);
    try {
      final recommendedDays = _recommendedDays;
      final totalKm = _totalKm;

      final bool isEditing = widget.existingTripId != null;
      final docRef =
          isEditing
              ? FirebaseFirestore.instance
                  .collection('verifiedTrips')
                  .doc(widget.existingTripId)
              : FirebaseFirestore.instance.collection('verifiedTrips').doc();
      final tripId = docRef.id;

      String coverImage = coverCandidate;
      final uploadedPhotos = <String>[];

      // Upload cover image (only if it's a data URL).
      if (coverImage.trim().startsWith('data:image')) {
        coverImage = await _uploadVerifiedTripImage(
          tripId: tripId,
          label: 'cover',
          dataUrl: coverImage.trim(),
        );
      }

      // Upload photos (only data URLs). Keep any existing http(s)/asset refs as-is.
      for (var i = 0; i < _photoUrls.length; i++) {
        final p = _photoUrls[i].trim();
        if (p.isEmpty) continue;
        if (p.startsWith('data:image')) {
          final url = await _uploadVerifiedTripImage(
            tripId: tripId,
            label: 'photo_$i',
            dataUrl: p,
          );
          uploadedPhotos.add(url);
        } else {
          uploadedPhotos.add(p);
        }
      }

      // If there was no cover, fall back to first uploaded photo.
      if (coverImage.trim().isEmpty && uploadedPhotos.isNotEmpty) {
        coverImage = uploadedPhotos.first;
      }

      // Avoid duplicates.
      final uniquePhotos = <String>[];
      final seen = <String>{};
      for (final p in uploadedPhotos) {
        final s = p.trim();
        if (s.isEmpty) continue;
        if (seen.add(s)) uniquePhotos.add(s);
      }

      final tripData = <String, dynamic>{
        'title': title,
        'subtitle': subtitle,
        'description': description,
        'coverImage': coverImage,
        'recommendedDays': recommendedDays,
        // Back-compat
        'days': recommendedDays,
        'itinerary': _itinerary,
        'photos': uniquePhotos,
        'waypoints':
            _waypoints
                .map(
                  (w) => {
                    'name': w.name,
                    'lat': w.lat,
                    'lon': w.lon,
                    'days': w.days,
                  },
                )
                .toList(),
        'totalStops': _waypoints.length,
        'totalKm': totalKm,
      };

      if (isEditing) {
        // Update existing trip - preserve createdAt/createdByUid, add updatedAt
        tripData['updatedAt'] = FieldValue.serverTimestamp();
        tripData['updatedByUid'] = u.uid;
        await docRef.update(tripData);
      } else {
        // Create new trip
        tripData['createdAt'] = FieldValue.serverTimestamp();
        tripData['createdByUid'] = u.uid;
        await docRef.set(tripData);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isEditing ? 'Verified trip updated' : 'Verified trip created',
            ),
          ),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final mapHeight = (screenWidth * 0.55).clamp(220.0, 340.0);

    final cover =
        _coverImage.trim().isNotEmpty
            ? _coverImage.trim()
            : (_photoUrls.isNotEmpty ? _photoUrls.first : '');
    final km = _totalKm;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.existingTripId != null
              ? 'Edit verified trip'
              : 'New verified trip',
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child:
                _saving
                    ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : const Text('Save'),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (cover.isNotEmpty) ...[
              _imagePreview(cover, height: 220),
              const SizedBox(height: 12),
            ],

            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    TextFormField(
                      controller: _titleCtl,
                      decoration: const InputDecoration(labelText: 'Title'),
                      validator:
                          (v) =>
                              _trim(v ?? '').isEmpty
                                  ? 'Title is required'
                                  : null,
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _subtitleCtl,
                      decoration: const InputDecoration(
                        labelText: 'Subtitle (optional)',
                      ),
                    ),
                    const SizedBox(height: 8),
                    InputDecorator(
                      decoration: const InputDecoration(
                        labelText: 'Cover photo',
                      ),
                      child: Text(
                        _coverImage.isNotEmpty ? 'Uploaded' : 'None',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        OutlinedButton.icon(
                          onPressed: _saving ? null : _uploadCover,
                          icon: const Icon(Icons.upload),
                          label: const Text('Upload cover'),
                        ),
                        const SizedBox(width: 8),
                        if (_coverImage.isNotEmpty)
                          TextButton(
                            onPressed:
                                _saving
                                    ? null
                                    : () => setState(() => _coverImage = ''),
                            child: const Text('Remove cover'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _descCtl,
                      maxLines: 6,
                      decoration: const InputDecoration(
                        labelText: 'Description',
                      ),
                      validator:
                          (v) =>
                              _trim(v ?? '').isEmpty
                                  ? 'Description is required'
                                  : null,
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Recommended: $_recommendedDays days',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        Text(
                          '${_waypoints.length} stops${_waypoints.length > 1 ? ' • ${km.toStringAsFixed(0)} km' : ''}',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: Colors.black54),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 12),

            Text(
              'Build the route',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),

            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _searchCtl,
                            decoration: const InputDecoration(
                              prefixIcon: Icon(Icons.search),
                              hintText: 'Search locations',
                            ),
                            onChanged: (v) {
                              _searchDebounce?.cancel();
                              _searchDebounce = Timer(
                                const Duration(milliseconds: 400),
                                () async {
                                  final q = _searchCtl.text.trim();
                                  if (q.isEmpty) {
                                    if (mounted) {
                                      setState(() => _searchResults = []);
                                    }
                                    return;
                                  }
                                  final results = await searchNominatim(q);
                                  if (!mounted) return;
                                  setState(() => _searchResults = results);
                                },
                              );
                            },
                            onSubmitted: (v) async {
                              final q = v.trim();
                              if (q.isEmpty) return;
                              final results = await searchNominatim(q);
                              if (results.isEmpty) return;
                              final r = results.first;
                              await _addWaypointFromResult(
                                name: (r['name'] ?? q).toString(),
                                lat: (r['lat'] ?? 0.0) as double,
                                lon: (r['lon'] ?? 0.0) as double,
                              );
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed:
                              _saving
                                  ? null
                                  : () async {
                                    final q = _searchCtl.text.trim();
                                    if (q.isEmpty) return;
                                    final results = await searchNominatim(q);
                                    if (results.isEmpty) return;
                                    final r = results.first;
                                    await _addWaypointFromResult(
                                      name: (r['name'] ?? q).toString(),
                                      lat: (r['lat'] ?? 0.0) as double,
                                      lon: (r['lon'] ?? 0.0) as double,
                                    );
                                  },
                          child: const Text('Add'),
                        ),
                      ],
                    ),
                    if (_searchResults.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Container(
                        height: 160,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          border: Border.all(color: Colors.grey.shade300),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: ListView.builder(
                          itemCount: _searchResults.length,
                          itemBuilder: (ctx, i) {
                            final r = _searchResults[i];
                            final name =
                                (r['name'] ?? 'Result ${i + 1}').toString();
                            final lat = (r['lat'] ?? 0.0) as double;
                            final lon = (r['lon'] ?? 0.0) as double;
                            return ListTile(
                              title: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '${lat.toStringAsFixed(4)}, ${lon.toStringAsFixed(4)}',
                              ),
                              trailing: TextButton(
                                onPressed:
                                    _saving
                                        ? null
                                        : () => _addWaypointFromResult(
                                          name: name,
                                          lat: lat,
                                          lon: lon,
                                        ),
                                child: const Text('Add'),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    SizedBox(
                      height: mapHeight,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Material(
                          color: Theme.of(context).colorScheme.surface,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.grey.shade300),
                            ),
                            child: IgnorePointer(
                              ignoring: _suspendMapTap,
                              child: MapEmbed(
                                points:
                                    _waypoints
                                        .map(
                                          (w) => {
                                            'name': w.name,
                                            'lat': w.lat,
                                            'lon': w.lon,
                                          },
                                        )
                                        .toList(),
                                secondaryPoints:
                                    _itinerary.asMap().entries.expand((
                                      dayEntry,
                                    ) {
                                      final dayIndex = dayEntry.key;
                                      final day = dayEntry.value;
                                      final acts =
                                          (day['activities']
                                              as List<dynamic>?) ??
                                          [];
                                      return acts
                                          .asMap()
                                          .entries
                                          .where(
                                            (a) =>
                                                (a.value
                                                        as Map)['locationLat'] !=
                                                    null &&
                                                (a.value
                                                        as Map)['locationLon'] !=
                                                    null,
                                          )
                                          .map(
                                            (a) => {
                                              'lat':
                                                  (a.value
                                                      as Map)['locationLat'],
                                              'lon':
                                                  (a.value
                                                      as Map)['locationLon'],
                                              'kind': 'activity',
                                              'category':
                                                  (a.value
                                                      as Map)['category'] ??
                                                  'Sightseeing',
                                              'dayIndex': dayIndex,
                                              'activityIndex': a.key,
                                            },
                                          );
                                    }).toList(),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 12),

            if (_waypoints.isEmpty)
              const Text(
                'No stops yet — search a location to start building the verified trip.',
              ),

            if (_waypoints.isNotEmpty) ...[
              Row(
                children: [
                  Text(
                    'Stops',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    'Total: $_recommendedDays days',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: Colors.black54),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Card(
                child: ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _waypoints.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (ctx, i) {
                    final w = _waypoints[i];
                    return ListTile(
                      title: Text(
                        w.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${w.lat.toStringAsFixed(4)}, ${w.lon.toStringAsFixed(4)}',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 72,
                            child: OutlinedButton(
                              onPressed:
                                  _saving
                                      ? null
                                      : () async {
                                        final v = await _promptDays(
                                          locationName: w.name,
                                          initialValue: w.days,
                                        );
                                        if (v == null) return;
                                        if (!mounted) return;
                                        setState(() {
                                          w.days = v;
                                          _ensureItineraryLength(
                                            _recommendedDays,
                                          );
                                        });
                                      },
                              child: Text('${w.days}d'),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Remove stop',
                            onPressed:
                                _saving
                                    ? null
                                    : () => setState(() {
                                      _waypoints.removeAt(i);
                                      _ensureItineraryLength(_recommendedDays);
                                    }),
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],

            if (_waypoints.isNotEmpty) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  Text(
                    'Itinerary (by day)',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${_itinerary.length} days',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: Colors.black54),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Card(
                child: ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _itinerary.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (ctx, dayIndex) {
                    final day = _itinerary[dayIndex];
                    final title =
                        (day['title'] ?? 'Day ${dayIndex + 1}').toString();
                    final notes = (day['notes'] ?? '').toString();
                    final activities = List<Map<String, dynamic>>.from(
                      (day['activities'] as List<dynamic>? ?? const []).map(
                        (a) => Map<String, dynamic>.from(a as Map),
                      ),
                    );

                    return ExpansionTile(
                      title: Text(title),
                      subtitle:
                          notes.trim().isEmpty
                              ? Text(
                                '${activities.length} activit${activities.length == 1 ? 'y' : 'ies'}',
                              )
                              : Text(
                                notes,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      children: [
                        TextField(
                          enabled: !_saving,
                          decoration: const InputDecoration(
                            labelText: 'Day notes (optional)',
                          ),
                          controller: TextEditingController(text: notes)
                            ..selection = TextSelection.collapsed(
                              offset: notes.length,
                            ),
                          onChanged: (v) {
                            setState(() {
                              day['notes'] = v;
                            });
                          },
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            OutlinedButton.icon(
                              onPressed:
                                  _saving
                                      ? null
                                      : () async {
                                        final res = await _promptActivity(
                                          dayTitle: title,
                                        );
                                        if (res == null) return;
                                        setState(() {
                                          // Parse lat/lon first
                                          final lat = double.tryParse(
                                            res['lat'] ?? '',
                                          );
                                          final lon = double.tryParse(
                                            res['lon'] ?? '',
                                          );

                                          final list =
                                              List<Map<String, dynamic>>.from(
                                                day['activities']
                                                        as List<dynamic>? ??
                                                    const [],
                                              );
                                          list.add({
                                            'time': res['time'] ?? '',
                                            'title': res['title'] ?? '',
                                            'description':
                                                res['description'] ?? '',
                                            'location': res['location'] ?? '',
                                            'category':
                                                res['category'] ??
                                                'Sightseeing',
                                            'locationLat': lat,
                                            'locationLon': lon,
                                          });
                                          day['activities'] = list;
                                        });
                                      },
                              icon: const Icon(Icons.add),
                              label: const Text('Add activity'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        if (activities.isEmpty)
                          const Text('No activities yet.'),
                        if (activities.isNotEmpty)
                          ListView.separated(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: activities.length,
                            separatorBuilder:
                                (_, __) => const Divider(height: 1),
                            itemBuilder: (ctx2, aIndex) {
                              final a = activities[aIndex];
                              final aTime = (a['time'] ?? '').toString();
                              final aTitle = (a['title'] ?? '').toString();
                              final aDesc = (a['description'] ?? '').toString();
                              final aLocation =
                                  (a['location'] ?? '').toString();
                              final aCategory =
                                  (a['category'] ?? '').toString();

                              return ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading:
                                    aLocation.trim().isNotEmpty
                                        ? Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            if (aCategory.isNotEmpty &&
                                                travelCategories.containsKey(
                                                  aCategory,
                                                ))
                                              Container(
                                                width: 12,
                                                height: 12,
                                                margin: const EdgeInsets.only(
                                                  right: 6,
                                                ),
                                                decoration: BoxDecoration(
                                                  color:
                                                      travelCategories[aCategory],
                                                  shape: BoxShape.circle,
                                                ),
                                              ),
                                            const Icon(Icons.place, size: 20),
                                          ],
                                        )
                                        : null,
                                title: Text(
                                  aTitle.isEmpty ? 'Activity' : aTitle,
                                ),
                                subtitle:
                                    (aTime.trim().isEmpty &&
                                            aDesc.trim().isEmpty &&
                                            aLocation.trim().isEmpty)
                                        ? null
                                        : Text(
                                          [
                                            if (aTime.trim().isNotEmpty)
                                              aTime.trim(),
                                            if (aLocation.trim().isNotEmpty)
                                              '📍 ${aLocation.trim()}',
                                            if (aDesc.trim().isNotEmpty)
                                              aDesc.trim(),
                                          ].join(' • '),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      tooltip: 'Edit activity',
                                      onPressed:
                                          _saving
                                              ? null
                                              : () async {
                                                final res =
                                                    await _promptActivity(
                                                      dayTitle: title,
                                                      initial: a,
                                                    );
                                                if (res == null) return;
                                                setState(() {
                                                  // Parse lat/lon first
                                                  final lat = double.tryParse(
                                                    res['lat'] ?? '',
                                                  );
                                                  final lon = double.tryParse(
                                                    res['lon'] ?? '',
                                                  );

                                                  final list = List<
                                                    Map<String, dynamic>
                                                  >.from(
                                                    day['activities']
                                                            as List<dynamic>? ??
                                                        const [],
                                                  );
                                                  list[aIndex] = {
                                                    'time': res['time'] ?? '',
                                                    'title': res['title'] ?? '',
                                                    'description':
                                                        res['description'] ??
                                                        '',
                                                    'location':
                                                        res['location'] ?? '',
                                                    'category':
                                                        res['category'] ??
                                                        'Sightseeing',
                                                    'locationLat': lat,
                                                    'locationLon': lon,
                                                  };
                                                  day['activities'] = list;
                                                });
                                              },
                                      icon: const Icon(Icons.edit_outlined),
                                    ),
                                    IconButton(
                                      tooltip: 'Delete activity',
                                      onPressed:
                                          _saving
                                              ? null
                                              : () {
                                                setState(() {
                                                  final list = List<
                                                    Map<String, dynamic>
                                                  >.from(
                                                    day['activities']
                                                            as List<dynamic>? ??
                                                        const [],
                                                  );
                                                  list.removeAt(aIndex);
                                                  day['activities'] = list;
                                                });
                                              },
                                      icon: const Icon(Icons.delete_outline),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                      ],
                    );
                  },
                ),
              ),
            ],

            const SizedBox(height: 12),

            Row(
              children: [
                Text(
                  'Photo log',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                OutlinedButton.icon(
                  onPressed: _saving ? null : _addPhotoUpload,
                  icon: const Icon(Icons.add),
                  label: const Text('Add photo'),
                ),
              ],
            ),
            const SizedBox(height: 8),

            if (_photoUrls.isEmpty)
              const Text(
                'No photos yet. Upload a few images to make this feel premium.',
              ),

            if (_photoUrls.isNotEmpty)
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 1.3,
                ),
                itemCount: _photoUrls.length,
                itemBuilder: (ctx, i) {
                  final url = _photoUrls[i];
                  return Stack(
                    children: [
                      Positioned.fill(child: _imagePreview(url)),
                      Positioned(
                        top: 6,
                        right: 6,
                        child: Material(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(16),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap:
                                _saving
                                    ? null
                                    : () =>
                                        setState(() => _photoUrls.removeAt(i)),
                            child: const Padding(
                              padding: EdgeInsets.all(6),
                              child: Icon(Icons.close, color: Colors.white),
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}
