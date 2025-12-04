// Web geocoding using Nominatim (OpenStreetMap).
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;

Future<List<Map<String, dynamic>>> searchNominatim(String query) async {
  final q = Uri.encodeQueryComponent(query);
  final url =
      'https://nominatim.openstreetmap.org/search?format=json&limit=8&q=$q';
  try {
    final resp = await html.HttpRequest.getString(url);
    final data = jsonDecode(resp) as List<dynamic>;
    return data.map<Map<String, dynamic>>((e) {
      return {
        'name': (e['display_name'] as String?) ?? '',
        'lat': double.tryParse(e['lat']?.toString() ?? '') ?? 0.0,
        'lon': double.tryParse(e['lon']?.toString() ?? '') ?? 0.0,
      };
    }).toList();
  } catch (e) {
    return <Map<String, dynamic>>[];
  }
}

Future<String?> reverseNominatim(double lat, double lon) async {
  final url =
      'https://nominatim.openstreetmap.org/reverse?format=json&lat=${lat.toString()}&lon=${lon.toString()}&zoom=14&addressdetails=0';
  try {
    final resp = await html.HttpRequest.getString(url);
    final data = jsonDecode(resp) as Map<String, dynamic>;
    return (data['display_name'] as String?);
  } catch (e) {
    return null;
  }
}
