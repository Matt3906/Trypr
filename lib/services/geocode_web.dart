// Web location search + reverse geocoding.
//
// Primary: Google Places search (new API), then legacy PlacesService, then
// Geocoder (all via Maps JavaScript API).
// Fallback: Nominatim (OpenStreetMap) only when no Maps key is configured.

import 'dart:async';
import 'dart:convert';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
// Some analyzer contexts (non-web) don't expose this library. This file is
// only conditionally exported for web via lib/services/geocode.dart.
// ignore: uri_does_not_exist
import 'dart:js_util' as js_util;

import 'package:http/http.dart' as http;
import 'package:trypr/services/google_maps_loader_web.dart';

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

String _resolveMapsKey() {
  const fromDefine = String.fromEnvironment('GOOGLE_MAPS_API_KEY');
  if (fromDefine.isNotEmpty) return fromDefine;

  try {
    final meta = html.document.querySelector(
      'meta[name="google-maps-api-key"]',
    );
    return meta?.getAttribute('content')?.trim() ?? '';
  } catch (_) {
    return '';
  }
}

bool _hasMapsKey() => _resolveMapsKey().isNotEmpty;

Future<void> _ensureServices() async {
  if (!_hasMapsKey()) return;
  await ensureGoogleMapsLoaded();

  final maps = _getMaps();
  if (maps == null) return;

  // Ensure Places library is available even if Maps JS booted without
  // `libraries=places`.
  try {
    final importLib = js_util.getProperty(maps, 'importLibrary');
    if (importLib != null) {
      final placesLibPromiseAny = js_util.callMethod<Object?>(
        maps,
        'importLibrary',
        const ['places'],
      );
      if (placesLibPromiseAny != null) {
        await js_util.promiseToFuture<Object?>(placesLibPromiseAny as Object);
      }
    }
  } catch (_) {
    // Non-fatal; continue with whichever services are available.
  }

  if (_placesHost == null) {
    _placesHost =
        html.DivElement()
          ..id = 'trypr-places-host'
          ..style.display = 'none';
    html.document.body?.append(_placesHost!);
  }

  if (_geocoder == null) {
    final Geocoder = js_util.getProperty(maps, 'Geocoder');
    _geocoder = js_util.callConstructor(Geocoder, const []);
  }
}

Future<Object?> _ensureLegacyPlacesService() async {
  if (_placesService != null) return _placesService;
  final maps = _getMaps();
  if (maps == null) return null;
  if (_placesHost == null) return null;
  try {
    final places = js_util.getProperty(maps, 'places');
    final placesServiceCtor = js_util.getProperty(places, 'PlacesService');
    _placesService = js_util.callConstructor(placesServiceCtor, [_placesHost!]);
    return _placesService;
  } catch (_) {
    _placesService = null;
    return null;
  }
}

String _asText(Object? value) {
  if (value == null) return '';
  if (value is String) return value.trim();
  try {
    final t = (js_util.getProperty(value, 'text') ?? '').toString().trim();
    if (t.isNotEmpty) return t;
  } catch (_) {}
  final raw = value.toString().trim();
  if (raw == '[object Object]') return '';
  return raw;
}

double? _asDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

double? _locationLat(Object? location) {
  if (location == null) return null;
  try {
    final lat = js_util.callMethod(location, 'lat', const []);
    final parsed = _asDouble(lat);
    if (parsed != null) return parsed;
  } catch (_) {}
  try {
    return _asDouble(js_util.getProperty(location, 'lat'));
  } catch (_) {
    return null;
  }
}

double? _locationLng(Object? location) {
  if (location == null) return null;
  try {
    final lng = js_util.callMethod(location, 'lng', const []);
    final parsed = _asDouble(lng);
    if (parsed != null) return parsed;
  } catch (_) {}
  try {
    return _asDouble(js_util.getProperty(location, 'lng'));
  } catch (_) {
    return null;
  }
}

Map<String, dynamic>? _searchItem({
  required String query,
  required String displayName,
  required String formattedAddress,
  required Object? location,
}) {
  final lat = _locationLat(location);
  final lon = _locationLng(location);
  if (lat == null || lon == null) return null;

  final display =
      formattedAddress.trim().isNotEmpty
          ? formattedAddress.trim()
          : (displayName.trim().isNotEmpty ? displayName.trim() : query);
  final name = displayName.trim().isNotEmpty ? displayName.trim() : display;

  return {'name': name, 'display_name': display, 'lat': lat, 'lon': lon};
}

Future<List<Map<String, dynamic>>> _searchAutocompleteSuggestionsNew(
  String query,
) async {
  final maps = _getMaps();
  if (maps == null) return const [];

  try {
    final libPromiseAny = js_util.callMethod<Object?>(
      maps,
      'importLibrary',
      const ['places'],
    );
    if (libPromiseAny == null) return const [];
    final placesLib = await js_util.promiseToFuture<Object?>(
      libPromiseAny as Object,
    );
    if (placesLib == null) return const [];

    final suggestionClass = js_util.getProperty(
      placesLib,
      'AutocompleteSuggestion',
    );
    if (suggestionClass == null) return const [];

    final request = js_util.jsify({'input': query, 'language': 'en'});
    final fetchPromiseAny = js_util.callMethod<Object?>(
      suggestionClass,
      'fetchAutocompleteSuggestions',
      [request],
    );
    if (fetchPromiseAny == null) return const [];

    final response = await js_util.promiseToFuture<Object?>(
      fetchPromiseAny as Object,
    );
    if (response == null) return const [];

    final suggestionsAny = js_util.getProperty(response, 'suggestions');
    if (suggestionsAny is! List || suggestionsAny.isEmpty) return const [];

    final out = <Map<String, dynamic>>[];
    for (final suggestion in suggestionsAny) {
      final prediction = js_util.getProperty(suggestion, 'placePrediction');
      if (prediction == null) continue;

      final predictionText = _asText(js_util.getProperty(prediction, 'text'));
      Object? place;
      try {
        place = js_util.callMethod<Object?>(prediction, 'toPlace', const []);
      } catch (_) {
        place = null;
      }
      if (place == null) continue;

      try {
        final fetchFieldsPromiseAny = js_util.callMethod<Object?>(
          place,
          'fetchFields',
          [
            js_util.jsify({
              'fields': js_util.jsify([
                'displayName',
                'formattedAddress',
                'location',
              ]),
            }),
          ],
        );
        if (fetchFieldsPromiseAny != null) {
          await js_util.promiseToFuture<Object?>(
            fetchFieldsPromiseAny as Object,
          );
        }
      } catch (_) {
        // Continue and read any preloaded fields.
      }

      final displayName = _asText(js_util.getProperty(place, 'displayName'));
      final formattedAddress =
          (js_util.getProperty(place, 'formattedAddress') ?? '')
              .toString()
              .trim();
      final location = js_util.getProperty(place, 'location');

      final item = _searchItem(
        query: query,
        displayName:
            displayName.isNotEmpty
                ? displayName
                : (predictionText.isNotEmpty ? predictionText : query),
        formattedAddress: formattedAddress,
        location: location,
      );
      if (item != null) {
        out.add(item);
      } else {
        // If Place details are unavailable, geocode the prediction text.
        final textToResolve =
            formattedAddress.isNotEmpty
                ? formattedAddress
                : (displayName.isNotEmpty
                    ? displayName
                    : (predictionText.isNotEmpty ? predictionText : query));
        final resolved = await _searchViaGeocoder(textToResolve);
        if (resolved.isNotEmpty) {
          final first = Map<String, dynamic>.from(resolved.first);
          first['name'] = displayName.isNotEmpty ? displayName : textToResolve;
          first['display_name'] = textToResolve;
          out.add(first);
        }
      }
      if (out.length >= 8) break;
    }
    return out;
  } catch (_) {
    return const [];
  }
}

Future<List<Map<String, dynamic>>> _searchPlacesNew(String query) async {
  final maps = _getMaps();
  if (maps == null) return const [];

  try {
    final importLib = js_util.getProperty(maps, 'importLibrary');
    if (importLib == null) return const [];

    final libPromiseAny = js_util.callMethod<Object?>(
      maps,
      'importLibrary',
      const ['places'],
    );
    if (libPromiseAny == null) return const [];
    final placesLib = await js_util.promiseToFuture<Object?>(
      libPromiseAny as Object,
    );
    if (placesLib == null) return const [];

    final placeClass = js_util.getProperty(placesLib, 'Place');
    if (placeClass == null) return const [];

    final request = js_util.jsify({
      'textQuery': query,
      'fields': js_util.jsify(['displayName', 'formattedAddress', 'location']),
      'maxResultCount': 8,
      'language': 'en',
    });

    final searchPromiseAny = js_util.callMethod<Object?>(
      placeClass,
      'searchByText',
      [request],
    );
    if (searchPromiseAny == null) return const [];
    final searchResult = await js_util.promiseToFuture<Object?>(
      searchPromiseAny as Object,
    );
    if (searchResult == null) return const [];

    final placesAny = js_util.getProperty(searchResult, 'places');
    if (placesAny is! List || placesAny.isEmpty) return const [];

    final out = <Map<String, dynamic>>[];
    for (final p in placesAny) {
      final displayName = _asText(js_util.getProperty(p, 'displayName'));
      final formattedAddress =
          (js_util.getProperty(p, 'formattedAddress') ?? '').toString().trim();
      final location = js_util.getProperty(p, 'location');
      final item = _searchItem(
        query: query,
        displayName: displayName,
        formattedAddress: formattedAddress,
        location: location,
      );
      if (item == null) continue;
      out.add(item);
      if (out.length >= 8) break;
    }
    return out;
  } catch (_) {
    return const [];
  }
}

Future<List<Map<String, dynamic>>> _searchPlacesLegacy(String query) async {
  final svc = await _ensureLegacyPlacesService();
  if (svc == null) return const [];

  try {
    final c = Completer<List<Map<String, dynamic>>>();
    final request = js_util.jsify({'query': query});

    void done(List<Map<String, dynamic>> v) {
      if (!c.isCompleted) c.complete(v);
    }

    final callback = js_util.allowInterop((results, status, pagination) {
      try {
        final statusStr = status?.toString() ?? '';
        if (statusStr != 'OK' || results == null) {
          done(const []);
          return;
        }

        final out = <Map<String, dynamic>>[];
        for (final r in (results as List)) {
          final name = (js_util.getProperty(r, 'name') ?? '').toString().trim();
          final formatted =
              (js_util.getProperty(r, 'formatted_address') ?? '')
                  .toString()
                  .trim();
          final geometry = js_util.getProperty(r, 'geometry');
          final location =
              geometry == null
                  ? null
                  : js_util.getProperty(geometry, 'location');
          final item = _searchItem(
            query: query,
            displayName: name,
            formattedAddress: formatted,
            location: location,
          );
          if (item == null) continue;
          out.add(item);
          if (out.length >= 8) break;
        }
        done(out);
      } catch (_) {
        done(const []);
      }
    });

    js_util.callMethod(svc, 'textSearch', [request, callback]);
    return await c.future.timeout(
      const Duration(seconds: 8),
      onTimeout: () => const <Map<String, dynamic>>[],
    );
  } catch (_) {
    return const [];
  }
}

Future<List<Map<String, dynamic>>> _searchViaGeocoder(String query) async {
  final geocoder = _geocoder;
  if (geocoder == null) return const [];

  try {
    final c = Completer<List<Map<String, dynamic>>>();
    final request = js_util.jsify({'address': query});

    void done(List<Map<String, dynamic>> v) {
      if (!c.isCompleted) c.complete(v);
    }

    final callback = js_util.allowInterop((results, status) {
      try {
        final statusStr = status?.toString() ?? '';
        if (statusStr != 'OK' || results == null) {
          done(const []);
          return;
        }
        final out = <Map<String, dynamic>>[];
        for (final r in (results as List)) {
          final formatted =
              (js_util.getProperty(r, 'formatted_address') ?? '').toString();
          final geometry = js_util.getProperty(r, 'geometry');
          final location =
              geometry == null
                  ? null
                  : js_util.getProperty(geometry, 'location');
          final item = _searchItem(
            query: query,
            displayName: formatted,
            formattedAddress: formatted,
            location: location,
          );
          if (item == null) continue;
          out.add(item);
          if (out.length >= 8) break;
        }
        done(out);
      } catch (_) {
        done(const []);
      }
    });

    js_util.callMethod(geocoder, 'geocode', [request, callback]);
    return await c.future.timeout(
      const Duration(seconds: 8),
      onTimeout: () => const <Map<String, dynamic>>[],
    );
  } catch (_) {
    return const [];
  }
}

Future<List<Map<String, dynamic>>> _searchNominatimFallback(
  String query,
) async {
  try {
    final url = Uri.parse(
      'https://nominatim.openstreetmap.org/search',
    ).replace(queryParameters: {'q': query, 'format': 'json', 'limit': '8'});
    final resp = await http.get(url);
    if (resp.statusCode != 200) return <Map<String, dynamic>>[];

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

Future<List<Map<String, dynamic>>> _searchPhotonFallback(String query) async {
  try {
    final url = Uri.https('photon.komoot.io', '/api/', {
      'q': query,
      'limit': '8',
      'lang': 'en',
    });
    final resp = await http.get(url);
    if (resp.statusCode != 200) return const [];

    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final features = (data['features'] as List<dynamic>?) ?? const [];
    if (features.isEmpty) return const [];

    final out = <Map<String, dynamic>>[];
    for (final raw in features) {
      final feature = (raw as Map).cast<String, dynamic>();
      final props = (feature['properties'] as Map?)?.cast<String, dynamic>();
      final geom = (feature['geometry'] as Map?)?.cast<String, dynamic>();
      final coords =
          (geom?['coordinates'] as List?)?.cast<dynamic>() ?? const [];
      if (coords.length < 2) continue;

      final lon = (coords[0] as num?)?.toDouble();
      final lat = (coords[1] as num?)?.toDouble();
      if (lat == null || lon == null) continue;

      final name = (props?['name'] ?? props?['street'] ?? '').toString().trim();
      final city = (props?['city'] ?? props?['state'] ?? '').toString().trim();
      final country = (props?['country'] ?? '').toString().trim();

      final displayParts = <String>[
        if (name.isNotEmpty) name,
        if (city.isNotEmpty) city,
        if (country.isNotEmpty) country,
      ];
      final display = displayParts.join(', ');
      if (display.isEmpty) continue;

      out.add({
        'name': name.isNotEmpty ? name : display,
        'display_name': display,
        'lat': lat,
        'lon': lon,
      });
      if (out.length >= 8) break;
    }
    return out;
  } catch (_) {
    return const [];
  }
}

Future<List<Map<String, dynamic>>> _searchViaGeocodingRest(String query) async {
  final key = _resolveMapsKey();
  if (key.isEmpty) return const [];

  try {
    final uri = Uri.https('maps.googleapis.com', '/maps/api/geocode/json', {
      'address': query,
      'key': key,
    });
    final resp = await http.get(uri);
    if (resp.statusCode != 200) return const [];

    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final status = (data['status'] ?? '').toString().trim().toUpperCase();
    if (status != 'OK') return const [];

    final results = (data['results'] as List<dynamic>?) ?? const [];
    if (results.isEmpty) return const [];

    final out = <Map<String, dynamic>>[];
    for (final entry in results) {
      final item = (entry as Map).cast<String, dynamic>();
      final formatted = (item['formatted_address'] ?? '').toString().trim();
      final geometry = (item['geometry'] as Map?)?.cast<String, dynamic>();
      final location = (geometry?['location'] as Map?)?.cast<String, dynamic>();
      final lat = (location?['lat'] as num?)?.toDouble();
      final lng = (location?['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) continue;

      out.add({
        'name': formatted.isNotEmpty ? formatted : query,
        'display_name': formatted.isNotEmpty ? formatted : query,
        'lat': lat,
        'lon': lng,
      });
      if (out.length >= 8) break;
    }
    return out;
  } catch (_) {
    return const [];
  }
}

Future<String?> _reverseNominatimFallback(double lat, double lon) async {
  try {
    final url = Uri.parse(
      'https://nominatim.openstreetmap.org/reverse',
    ).replace(
      queryParameters: {
        'format': 'json',
        'lat': lat.toString(),
        'lon': lon.toString(),
        'zoom': '14',
        'addressdetails': '0',
      },
    );

    final resp = await http.get(url);
    if (resp.statusCode != 200) return null;

    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return (data['display_name'] as String?);
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

Future<List<Map<String, dynamic>>> searchNominatim(String query) async {
  final q = query.trim();
  if (q.isEmpty) return const [];

  // If Maps isn't configured, keep existing behavior.
  if (!_hasMapsKey()) {
    final nominatim = await _searchNominatimFallback(q);
    if (nominatim.isNotEmpty) return nominatim;
    return _searchPhotonFallback(q);
  }

  try {
    // Keep a short bound so search doesn't hang while Maps initializes.
    await _ensureServices().timeout(const Duration(seconds: 1));

    final autocompleteSuggestions = await _searchAutocompleteSuggestionsNew(q);
    if (autocompleteSuggestions.isNotEmpty) return autocompleteSuggestions;

    final nextPlaces = await _searchPlacesNew(q);
    if (nextPlaces.isNotEmpty) return nextPlaces;

    final legacyPlaces = await _searchPlacesLegacy(q);
    if (legacyPlaces.isNotEmpty) return legacyPlaces;

    final geocoderResults = await _searchViaGeocoder(q);
    if (geocoderResults.isNotEmpty) return geocoderResults;

    return _searchPhotonFallback(q);
  } catch (_) {
    return _searchPhotonFallback(q);
  }
}

Future<String?> reverseNominatim(double lat, double lon) async {
  if (!_hasMapsKey()) {
    return _reverseNominatimFallback(lat, lon);
  }

  try {
    // Don't block reverse-geocoding UX on slow Maps JS.
    await _ensureServices().timeout(const Duration(seconds: 1));
    final geocoder = _geocoder;
    if (geocoder == null) {
      return null;
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
        final statusStr = status?.toString() ?? '';
        if (statusStr != 'OK' || results == null) {
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
    return res;
  } catch (_) {
    return null;
  }
}

Future<String?> reverseLocality(double lat, double lon) async {
  try {
    final url = Uri.parse(
      'https://nominatim.openstreetmap.org/reverse',
    ).replace(
      queryParameters: {
        'format': 'json',
        'lat': lat.toString(),
        'lon': lon.toString(),
        'zoom': '14',
        'addressdetails': '1',
      },
    );

    final resp = await http.get(url);
    if (resp.statusCode != 200) return null;
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return _extractLocalityFromReverse(data);
  } catch (_) {
    return null;
  }
}
