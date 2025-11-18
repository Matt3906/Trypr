// Stub geocode implementation for non-web platforms.
import 'dart:async';

Future<List<Map<String, dynamic>>> searchNominatim(String query) async {
  // No-op on non-web platforms; return empty list.
  return <Map<String, dynamic>>[];
}

Future<String?> reverseNominatim(double lat, double lon) async {
  return null;
}
