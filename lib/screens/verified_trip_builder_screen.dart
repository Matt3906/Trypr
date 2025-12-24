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
  const VerifiedTripBuilderScreen({super.key});

  @override
  State<VerifiedTripBuilderScreen> createState() =>
      _VerifiedTripBuilderScreenState();

  static Route<void> route() {
    return MaterialPageRoute<void>(
      builder: (_) => const VerifiedTripBuilderScreen(),
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

  final _titleCtl = TextEditingController();
  final _subtitleCtl = TextEditingController();
  final _descCtl = TextEditingController();
  String _coverImage = '';

  final _searchCtl = TextEditingController();
  Timer? _searchDebounce;
  List<Map<String, dynamic>> _searchResults = [];

  final List<String> _photoUrls = [];
  final List<_Waypoint> _waypoints = [];

  bool _saving = false;

  @override
  void dispose() {
    _titleCtl.dispose();
    _subtitleCtl.dispose();
    _descCtl.dispose();
    _searchDebounce?.cancel();
    _searchCtl.dispose();
    super.dispose();
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

  Future<int?> _promptDays({required String locationName}) async {
    var value = 2;
    return showDialog<int>(
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

      final docRef =
          FirebaseFirestore.instance.collection('verifiedTrips').doc();
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

      await docRef.set({
        'title': title,
        'subtitle': subtitle,
        'description': description,
        'coverImage': coverImage,
        'recommendedDays': recommendedDays,
        // Back-compat
        'days': recommendedDays,
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
        'createdAt': FieldValue.serverTimestamp(),
        'createdByUid': u.uid,
      });

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Verified trip created')));
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
    final cover =
        _coverImage.trim().isNotEmpty
            ? _coverImage.trim()
            : (_photoUrls.isNotEmpty ? _photoUrls.first : '');
    final km = _totalKm;

    return Scaffold(
      appBar: AppBar(
        title: const Text('New verified trip'),
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
                      height: 260,
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey.shade300),
                          borderRadius: BorderRadius.circular(8),
                        ),
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
                          onMapTap: (lat, lon) async {
                            final name = await reverseNominatim(lat, lon);
                            await _addWaypointFromResult(
                              name: name ?? 'Dropped Pin',
                              lat: lat,
                              lon: lon,
                            );
                          },
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
                          DropdownButton<int>(
                            value: w.days,
                            items: List.generate(
                              21,
                              (idx) => DropdownMenuItem(
                                value: idx + 1,
                                child: Text('${idx + 1}d'),
                              ),
                            ),
                            onChanged:
                                _saving
                                    ? null
                                    : (v) {
                                      if (v == null) return;
                                      setState(() => w.days = v);
                                    },
                          ),
                          IconButton(
                            tooltip: 'Remove stop',
                            onPressed:
                                _saving
                                    ? null
                                    : () =>
                                        setState(() => _waypoints.removeAt(i)),
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ],
                      ),
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
                              child: Icon(
                                Icons.close,
                                color: Colors.white,
                                size: 16,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),

            const SizedBox(height: 24),

            ElevatedButton.icon(
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.save),
              label: const Text('Save verified trip'),
            ),
          ],
        ),
      ),
    );
  }
}
