import 'dart:convert';
import 'dart:math' as math;

double _toDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0.0;
  return 0.0;
}

String normalizeRouteMode(String raw) {
  var mode = raw.trim().toLowerCase();
  if (mode == 'car' || mode == 'driving') mode = 'driving';
  if (mode == 'plane' || mode == 'flight' || mode == 'flying') {
    mode = 'flying';
  }
  if (mode == 'train' ||
      mode == 'rail' ||
      mode == 'public_transit' ||
      mode == 'public transit' ||
      mode == 'transit') {
    mode = 'train';
  }
  if (mode == 'walk') mode = 'walking';
  if (mode == 'bike' ||
      mode == 'biking' ||
      mode == 'bicycling' ||
      mode == 'cycling' ||
      mode == 'bikepacking') {
    mode = 'biking';
  }
  if (mode == 'hiking' || mode == 'backpacking') mode = 'hiking';
  if (mode == 'portage' ||
      mode == 'portaging' ||
      mode == 'canoe' ||
      mode == 'canoeing') {
    mode = 'portaging';
  }
  if (mode == 'gas' ||
      mode == 'gas_stops' ||
      mode == 'gas/stops' ||
      mode == 'gas-stops' ||
      mode == 'gasstops') {
    mode = 'driving';
  }
  switch (mode) {
    case 'driving':
    case 'flying':
    case 'train':
    case 'walking':
    case 'biking':
    case 'hiking':
    case 'portaging':
      return mode;
    default:
      return 'driving';
  }
}

List<String> normalizeSegmentModes(
  List<dynamic> raw, {
  required int segmentCount,
  required String fallbackMode,
}) {
  final fallback = normalizeRouteMode(fallbackMode);
  final out = raw
      .map((e) => normalizeRouteMode(e.toString()))
      .toList(growable: true);
  if (out.length > segmentCount) return out.take(segmentCount).toList();
  while (out.length < segmentCount) {
    out.add(fallback);
  }
  return out;
}

List<String> normalizeSegmentRoutingTypes(
  List<dynamic> raw, {
  required int segmentCount,
}) {
  final out = raw
      .map(
        (e) =>
            e.toString().trim().toLowerCase() == 'direct'
                ? 'direct'
                : 'calculated',
      )
      .toList(growable: true);
  if (out.length > segmentCount) return out.take(segmentCount).toList();
  while (out.length < segmentCount) {
    out.add('calculated');
  }
  return out;
}

List<Map<String, dynamic>> normalizeRouteVia(
  List<dynamic> raw, {
  required int segmentCount,
}) {
  final out = <Map<String, dynamic>>[];
  for (final item in raw) {
    if (item is! Map) continue;
    final after = (item['afterIndex'] as num?)?.toInt();
    if (after == null || after < 0 || after >= segmentCount) continue;
    final lat = _toDouble(item['lat']);
    final lon = _toDouble(item['lon'] ?? item['lng']);
    if (!lat.isFinite || !lon.isFinite) continue;
    out.add({
      'afterIndex': after,
      'lat': double.parse(lat.toStringAsFixed(6)),
      'lon': double.parse(lon.toStringAsFixed(6)),
    });
  }
  return out;
}

List<Map<String, dynamic>> readRouteGeometry(Object? raw) {
  if (raw is! List) return const [];
  final out = <Map<String, dynamic>>[];
  for (final item in raw) {
    if (item is! Map) continue;
    final lat = _toDouble(
      item['lat'] ?? item['latitude'] ?? item['locationLat'],
    );
    final lon = _toDouble(
      item['lon'] ?? item['lng'] ?? item['longitude'] ?? item['locationLon'],
    );
    if (!lat.isFinite || !lon.isFinite) continue;
    out.add({'lat': lat, 'lon': lon, 'lng': lon});
  }
  return out;
}

List<String> readRouteInstructions(Object? raw, {int maxItems = 8}) {
  if (raw is! List) return const [];
  final out = raw
      .map((e) => e.toString().trim())
      .where((e) => e.isNotEmpty)
      .take(maxItems)
      .toList(growable: false);
  return out;
}

List<Map<String, dynamic>> simplifyRouteGeometry(
  List<Map<String, dynamic>> geometry, {
  int maxPoints = 450,
}) {
  if (geometry.length <= maxPoints) {
    return geometry
        .map(
          (point) => {
            'lat': _toDouble(point['lat']),
            'lon': _toDouble(point['lon'] ?? point['lng']),
            'lng': _toDouble(point['lon'] ?? point['lng']),
          },
        )
        .toList(growable: false);
  }

  final out = <Map<String, dynamic>>[];
  final lastIndex = geometry.length - 1;
  final step = (lastIndex / (maxPoints - 1)).clamp(1, geometry.length);
  var nextIndex = 0.0;
  for (var i = 0; i < maxPoints; i++) {
    final index =
        i == maxPoints - 1 ? lastIndex : math.min(lastIndex, nextIndex.round());
    final point = geometry[index];
    final lat = _toDouble(point['lat']);
    final lon = _toDouble(point['lon'] ?? point['lng']);
    if (!lat.isFinite || !lon.isFinite) {
      nextIndex += step;
      continue;
    }
    if (out.isNotEmpty) {
      final prev = out.last;
      final prevLat = _toDouble(prev['lat']);
      final prevLon = _toDouble(prev['lon'] ?? prev['lng']);
      if ((prevLat - lat).abs() < 1e-7 && (prevLon - lon).abs() < 1e-7) {
        nextIndex += step;
        continue;
      }
    }
    out.add({'lat': lat, 'lon': lon, 'lng': lon});
    nextIndex += step;
  }
  return out;
}

String buildRouteCacheKey({
  required List<Map<String, dynamic>> waypoints,
  required String transportMode,
  List<dynamic> segmentTransportModes = const [],
  List<dynamic> segmentRoutingTypes = const [],
  List<dynamic> routeVia = const [],
}) {
  final segmentCount = math.max(0, waypoints.length - 1);
  final normalizedWaypoints = waypoints
      .map(
        (point) => {
          'lat': double.parse(
            _toDouble(
              point['lat'] ?? point['latitude'] ?? point['locationLat'],
            ).toStringAsFixed(6),
          ),
          'lon': double.parse(
            _toDouble(
              point['lon'] ??
                  point['lng'] ??
                  point['longitude'] ??
                  point['locationLon'],
            ).toStringAsFixed(6),
          ),
          'name': (point['name'] ?? '').toString(),
        },
      )
      .toList(growable: false);

  final payload = <String, dynamic>{
    'mode': normalizeRouteMode(transportMode),
    'waypoints': normalizedWaypoints,
    'segmentTransportModes': normalizeSegmentModes(
      segmentTransportModes,
      segmentCount: segmentCount,
      fallbackMode: transportMode,
    ),
    'segmentRoutingTypes': normalizeSegmentRoutingTypes(
      segmentRoutingTypes,
      segmentCount: segmentCount,
    ),
    'routeVia': normalizeRouteVia(routeVia, segmentCount: segmentCount),
  };
  return jsonEncode(payload);
}
