// Web location search + reverse geocoding.
//
// Primary: Google Places / Geocoder (via Maps JavaScript API).
// Fallback: Nominatim (OpenStreetMap) so the app still works if Maps isn't
// configured or the JS API fails.

import 'dart:async';
import 'dart:convert';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
// Some analyzer contexts (non-web) don't expose this library. This file is
// only conditionally exported for web via lib/services/geocode.dart.
// ignore: uri_does_not_exist
import 'dart:js_util' as js_util;

import 'package:trypr/services/google_maps_loader_web.dart';

const _mapsKey = String.fromEnvironment('GOOGLE_MAPS_API_KEY');

html.DivElement? _placesHost;
Object? _placesService;
Object? _geocoder;

Object? _getGoogle() {
  return js_util.getProperty(html.window, 'google');
}

Object? _getMaps() {
  final google = _getGoogle();
  if (google == null) return null;
  return js_util.getProperty(google, 'maps');
}

Future<void> _ensureServices() async {
  if (_mapsKey.isEmpty) return;
  await ensureGoogleMapsLoaded();

  final maps = _getMaps();
  if (maps == null) return;

  if (_placesHost == null) {
    _placesHost =
        html.DivElement()
          ..id = 'trypr-places-host'
          ..style.display = 'none';
    html.document.body?.append(_placesHost!);
  }

  if (_placesService == null) {
    final places = js_util.getProperty(maps, 'places');
    final PlacesService = js_util.getProperty(places, 'PlacesService');
    _placesService = js_util.callConstructor(PlacesService, [_placesHost!]);
  }

  if (_geocoder == null) {
    final Geocoder = js_util.getProperty(maps, 'Geocoder');
    _geocoder = js_util.callConstructor(Geocoder, const []);
  }
}

Future<List<Map<String, dynamic>>> _searchNominatimFallback(
  String query,
) async {
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
  } catch (_) {
    return <Map<String, dynamic>>[];
  }
}

Future<String?> _reverseNominatimFallback(double lat, double lon) async {
  final url =
      'https://nominatim.openstreetmap.org/reverse?format=json&lat=${lat.toString()}&lon=${lon.toString()}&zoom=14&addressdetails=0';
  try {
    final resp = await html.HttpRequest.getString(url);
    final data = jsonDecode(resp) as Map<String, dynamic>;
    return (data['display_name'] as String?);
  } catch (_) {
    return null;
  }
}

Future<List<Map<String, dynamic>>> searchNominatim(String query) async {
  final q = query.trim();
  if (q.isEmpty) return const [];

  // If Maps isn't configured, keep existing behavior.
  if (_mapsKey.isEmpty) {
    return _searchNominatimFallback(q);
  }

  try {
    await _ensureServices();
    final svc = _placesService;
    if (svc == null) {
      return _searchNominatimFallback(q);
    }

    final c = Completer<List<Map<String, dynamic>>>();
    final request = js_util.jsify({'query': q});

    void done(List<Map<String, dynamic>> v) {
      if (!c.isCompleted) c.complete(v);
    }

    final callback = js_util.allowInterop((results, status, pagination) {
      try {
        if (status != 'OK' || results == null) {
          done(const []);
          return;
        }
        final out = <Map<String, dynamic>>[];
        for (final r in (results as List)) {
          final name = (js_util.getProperty(r, 'name') ?? '').toString();
          final formatted =
              (js_util.getProperty(r, 'formatted_address') ?? '').toString();
          final geometry = js_util.getProperty(r, 'geometry');
          final location =
              geometry == null
                  ? null
                  : js_util.getProperty(geometry, 'location');
          if (location == null) continue;
          final lat =
              (js_util.callMethod(location, 'lat', const []) as num?)
                  ?.toDouble() ??
              0.0;
          final lon =
              (js_util.callMethod(location, 'lng', const []) as num?)
                  ?.toDouble() ??
              0.0;
          out.add({
            'name':
                name.isNotEmpty ? name : (formatted.isNotEmpty ? formatted : q),
            'lat': lat,
            'lon': lon,
          });
          if (out.length >= 8) break;
        }
        done(out);
      } catch (_) {
        done(const []);
      }
    });

    js_util.callMethod(svc, 'textSearch', [request, callback]);

    final res = await c.future.timeout(
      const Duration(seconds: 8),
      onTimeout: () => const <Map<String, dynamic>>[],
    );
    if (res.isNotEmpty) return res;
  } catch (_) {
    // fall through
  }

  return _searchNominatimFallback(q);
}

Future<String?> reverseNominatim(double lat, double lon) async {
  if (_mapsKey.isEmpty) {
    return _reverseNominatimFallback(lat, lon);
  }

  try {
    await _ensureServices();
    final geocoder = _geocoder;
    if (geocoder == null) {
      return _reverseNominatimFallback(lat, lon);
    }

    final c = Completer<String?>();
    final request = js_util.jsify({
      'location': js_util.jsify({'lat': lat, 'lng': lon}),
    });

    void done(String? v) {
      if (!c.isCompleted) c.complete(v);
    }

    final callback = js_util.allowInterop((results, status) {
      try {
        if (status != 'OK' || results == null) {
          done(null);
          return;
        }
        final list = results as List;
        if (list.isEmpty) {
          done(null);
          return;
        }
        final first = list.first;
        final formatted =
            (js_util.getProperty(first, 'formatted_address') ?? '').toString();
        done(formatted.isEmpty ? null : formatted);
      } catch (_) {
        done(null);
      }
    });

    js_util.callMethod(geocoder, 'geocode', [request, callback]);
    final res = await c.future.timeout(
      const Duration(seconds: 8),
      onTimeout: () => null,
    );
    return res ?? _reverseNominatimFallback(lat, lon);
  } catch (_) {
    return _reverseNominatimFallback(lat, lon);
  }
}
