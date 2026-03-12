// Geocode implementation for non-web platforms.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

Future<List<Map<String, dynamic>>> searchNominatim(String query) async {
  final q = query.trim();
  if (q.isEmpty) return const <Map<String, dynamic>>[];

  final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
    'format': 'json',
    'limit': '8',
    'q': q,
  });

  try {
    final resp = await http.get(
      uri,
      headers: {'User-Agent': 'trypr-app/1.0 (https://example.com)'},
    );
    if (resp.statusCode != 200) return const <Map<String, dynamic>>[];
    final data = jsonDecode(resp.body) as List<dynamic>;
    return data.map<Map<String, dynamic>>((e) {
      final display = (e['display_name'] as String?) ?? '';
      return {
        'name': display,
        'display_name': display,
        'lat': double.tryParse(e['lat']?.toString() ?? '') ?? 0.0,
        'lon': double.tryParse(e['lon']?.toString() ?? '') ?? 0.0,
      };
    }).toList();
  } catch (_) {
    return <Map<String, dynamic>>[];
  }
}

Future<String?> reverseNominatim(double lat, double lon) async {
  final uri = Uri.https('nominatim.openstreetmap.org', '/reverse', {
    'format': 'json',
    'lat': lat.toString(),
    'lon': lon.toString(),
    'zoom': '14',
    'addressdetails': '0',
  });

  try {
    final resp = await http.get(
      uri,
      headers: {'User-Agent': 'trypr-app/1.0 (https://example.com)'},
    );
    if (resp.statusCode != 200) return null;
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return data['display_name'] as String?;
  } catch (_) {
    return null;
  }
}

bool _looksBroadArea(String value) {
  final s = value.trim().toLowerCase();
  if (s.isEmpty) return true;
  if (s == 'canada' || s == 'united states' || s == 'usa') return true;
  return s.contains('county') ||
      s.contains('region') ||
      s.contains('district') ||
      s.contains('province') ||
      s.contains('state') ||
      s.contains('territory');
}

String? _extractLocalityFromReverse(Map<String, dynamic> data) {
  final addressRaw = data['address'];
  if (addressRaw is! Map) return null;
  final address = Map<String, dynamic>.from(addressRaw);

  const keys = [
    'city',
    'town',
    'village',
    'municipality',
    'city_district',
    'borough',
    'suburb',
    'hamlet',
  ];
  for (final key in keys) {
    final raw = (address[key] ?? '').toString().trim();
    if (raw.isEmpty) continue;
    if (_looksBroadArea(raw)) continue;
    return raw;
  }
  return null;
}

Future<String?> reverseLocality(double lat, double lon) async {
  final uri = Uri.https('nominatim.openstreetmap.org', '/reverse', {
    'format': 'json',
    'lat': lat.toString(),
    'lon': lon.toString(),
    'zoom': '14',
    'addressdetails': '1',
  });

  try {
    final resp = await http.get(
      uri,
      headers: {'User-Agent': 'trypr-app/1.0 (https://example.com)'},
    );
    if (resp.statusCode != 200) return null;
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return _extractLocalityFromReverse(data);
  } catch (_) {
    return null;
  }
}
