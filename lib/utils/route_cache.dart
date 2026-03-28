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

String normalizeSegmentRoutingType(String raw, {required String mode}) {
  final normalizedMode = normalizeRouteMode(mode);
  final value = raw.trim().toLowerCase();
  if (value == 'direct') return 'direct';
  switch (normalizedMode) {
    case 'hiking':
      return 'trails';
    case 'portaging':
      return 'waterway';
    default:
      return 'calculated';
  }
}

List<String> normalizeSegmentRoutingTypes(
  List<dynamic> raw, {
  required int segmentCount,
  List<dynamic> segmentModes = const [],
  required String fallbackMode,
}) {
  final normalizedModes = normalizeSegmentModes(
    segmentModes,
    segmentCount: segmentCount,
    fallbackMode: fallbackMode,
  );
  return List<String>.generate(segmentCount, (index) {
    final rawType = index < raw.length ? raw[index].toString() : '';
    return normalizeSegmentRoutingType(rawType, mode: normalizedModes[index]);
  });
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

List<Map<String, dynamic>> readRouteSegmentDetails(
  Object? raw, {
  int maxSegments = 24,
  int maxStepsPerSegment = 8,
}) {
  if (raw is! List) return const [];
  final out = <Map<String, dynamic>>[];

  Map<String, dynamic>? sanitizeStop(dynamic rawStop) {
    if (rawStop is! Map) return null;
    final name = (rawStop['name'] ?? rawStop['label'] ?? '').toString().trim();
    final lat = _toDouble(rawStop['lat']);
    final lon = _toDouble(rawStop['lon'] ?? rawStop['lng']);
    final stop = <String, dynamic>{};
    if (name.isNotEmpty) stop['name'] = name;
    if (lat.isFinite && lon.isFinite) {
      stop['lat'] = lat;
      stop['lon'] = lon;
      stop['lng'] = lon;
    }
    return stop.isEmpty ? null : stop;
  }

  for (final item in raw.take(maxSegments)) {
    if (item is! Map) continue;
    final segmentIndex = (item['segmentIndex'] as num?)?.toInt();
    if (segmentIndex == null || segmentIndex < 0) continue;

    final mode = normalizeRouteMode((item['mode'] ?? '').toString());
    final stepsRaw = item['steps'];
    final steps = <Map<String, dynamic>>[];
    if (stepsRaw is List) {
      for (final step in stepsRaw.take(maxStepsPerSegment)) {
        if (step is! Map) continue;
        final tabLabel = (step['tabLabel'] ?? '').toString().trim();
        final headline = (step['headline'] ?? '').toString().trim();
        if (tabLabel.isEmpty && headline.isEmpty) continue;
        final stepMap = <String, dynamic>{
          'mode': (step['mode'] ?? '').toString().trim().toLowerCase(),
          if (tabLabel.isNotEmpty) 'tabLabel': tabLabel,
          if (headline.isNotEmpty) 'headline': headline,
        };
        final detail = (step['detail'] ?? '').toString().trim();
        final caption = (step['caption'] ?? '').toString().trim();
        final lineColor = (step['lineColor'] ?? '').toString().trim();
        if (detail.isNotEmpty) stepMap['detail'] = detail;
        if (caption.isNotEmpty) stepMap['caption'] = caption;
        if (lineColor.isNotEmpty) stepMap['lineColor'] = lineColor;
        final focusLat = _toDouble(step['focusLat'] ?? step['lat']);
        final focusLon = _toDouble(
          step['focusLon'] ?? step['lon'] ?? step['lng'],
        );
        if (focusLat.isFinite && focusLon.isFinite) {
          stepMap['focusLat'] = focusLat;
          stepMap['focusLon'] = focusLon;
          stepMap['lat'] = focusLat;
          stepMap['lon'] = focusLon;
          stepMap['lng'] = focusLon;
        }
        final focusZoom = _toDouble(step['focusZoom']);
        if (focusZoom.isFinite && focusZoom > 0) {
          stepMap['focusZoom'] = focusZoom.clamp(3.0, 18.0);
        }
        final path = readRouteGeometry(step['path']);
        if (path.isNotEmpty) {
          stepMap['path'] = path;
        }
        steps.add(stepMap);
      }
    }
    if (steps.isEmpty) continue;

    final detail = <String, dynamic>{
      'segmentIndex': segmentIndex,
      'mode': mode,
      'steps': steps,
    };
    final distanceMeters = _toDouble(item['distanceMeters']);
    final durationSeconds = _toDouble(item['durationSeconds']);
    if (distanceMeters > 0) detail['distanceMeters'] = distanceMeters;
    if (durationSeconds > 0) detail['durationSeconds'] = durationSeconds;
    final arrivalStop = sanitizeStop(item['arrivalStop']);
    if (arrivalStop != null) detail['arrivalStop'] = arrivalStop;
    out.add(detail);
  }

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
      segmentModes: segmentTransportModes,
      fallbackMode: transportMode,
    ),
    'routeVia': normalizeRouteVia(routeVia, segmentCount: segmentCount),
  };
  return jsonEncode(payload);
}
