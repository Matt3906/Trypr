import 'dart:convert';
import 'package:http/http.dart' as http;

/// Lightweight address search using OpenStreetMap Nominatim.
/// No API key required, but rate limits apply. Provide a short user agent.
class AddressSuggestion {
  final String displayName;
  final double lat;
  final double lon;

  AddressSuggestion({
    required this.displayName,
    required this.lat,
    required this.lon,
  });
}

class AddressSearchService {
  static const _endpoint = 'https://nominatim.openstreetmap.org/search';

  static Future<List<AddressSuggestion>> search(String query) async {
    if (query.trim().isEmpty) return [];

    final uri = Uri.parse(_endpoint).replace(
      queryParameters: {
        'q': query,
        'format': 'json',
        'addressdetails': '0',
        'limit': '8',
      },
    );

    final resp = await http.get(
      uri,
      headers: {'User-Agent': 'Trypr/1.0 (address search)'},
    );

    if (resp.statusCode != 200) return [];
    try {
      final data = jsonDecode(resp.body) as List<dynamic>;
      return data.map((item) {
        final lat = double.tryParse(item['lat']?.toString() ?? '') ?? 0.0;
        final lon = double.tryParse(item['lon']?.toString() ?? '') ?? 0.0;
        return AddressSuggestion(
          displayName: item['display_name']?.toString() ?? 'Unknown',
          lat: lat,
          lon: lon,
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }
}
