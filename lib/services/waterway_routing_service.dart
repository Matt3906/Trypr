import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import 'package:trypr/services/directions_result.dart';
import 'package:trypr/utils/async_utils.dart';
import 'package:trypr/utils/route_cache.dart';

class WaterwayRoutingService {
  WaterwayRoutingService._();

  static final WaterwayRoutingService instance = WaterwayRoutingService._();

  static const double _paddleMetersPerHour = 5000.0;
  static const int _maxCacheEntries = 96;
  final LinkedHashMap<String, DirectionsResult> _cache =
      LinkedHashMap<String, DirectionsResult>();

  Future<DirectionsResult> route({
    required double originLat,
    required double originLng,
    required double destLat,
    required double destLng,
    List<List<double>>? waypoints,
    int portageCount = 0,
    String? cacheKey,
  }) async {
    final resolvedCacheKey =
        cacheKey ??
        buildSegmentRouteCacheKey(
          segmentPoints: [
            {'lat': originLat, 'lon': originLng},
            ...(waypoints ?? const <List<double>>[]).map(
              (point) => {
                'lat': point.isNotEmpty ? point.first : 0.0,
                'lon': point.length > 1 ? point[1] : 0.0,
              },
            ),
            {'lat': destLat, 'lon': destLng},
          ],
          routingType: 'waterway',
          mode: 'waterway',
        );

    final cached = _cache.remove(resolvedCacheKey);
    if (cached != null) {
      _cache[resolvedCacheKey] = cached;
      return cached;
    }

    return withTimeout(
      operationName: 'waterwayRouting',
      timeout: const Duration(milliseconds: 500),
      operation: () async {
        final stopwatch = Stopwatch()..start();
        final anchors = _buildAnchors(
          originLat: originLat,
          originLng: originLng,
          destLat: destLat,
          destLng: destLng,
          waypoints: waypoints,
        );
        final sampled = _sampleWaterwayPath(anchors);
        final simplified = _simplifyWaterwayPath(sampled);
        final distanceMeters = _polylineDistanceMeters(simplified);
        final durationSeconds = _estimateDurationSeconds(
          distanceMeters: distanceMeters,
          portageCount: portageCount,
          waypointCount: math.max(0, anchors.length - 2),
        );
        final result = DirectionsResult(
          polylinePoints: simplified
              .map((point) => [point.latitude, point.longitude])
              .toList(growable: false),
          distanceMeters: distanceMeters,
          durationSeconds: durationSeconds,
          instructions: _buildInstructions(
            distanceMeters: distanceMeters,
            portageCount: portageCount,
            waypointCount: math.max(0, anchors.length - 2),
          ),
          stepDetails: _buildStepDetails(
            anchors: anchors,
            sampledPath: simplified,
            portageCount: portageCount,
          ),
        );
        _cache[resolvedCacheKey] = result;
        _trimCache();
        debugPrint(
          'waterwayRouting success ms=${stopwatch.elapsedMilliseconds} '
          'points=${result.polylinePoints.length} '
          'distance=${result.distanceMeters.toStringAsFixed(0)}',
        );
        return result;
      },
      fallback: () => throw TimeoutException('waterway routing timed out'),
    );
  }

  List<gmaps.LatLng> _buildAnchors({
    required double originLat,
    required double originLng,
    required double destLat,
    required double destLng,
    List<List<double>>? waypoints,
  }) {
    final anchors = <gmaps.LatLng>[gmaps.LatLng(originLat, originLng)];
    for (final waypoint in waypoints ?? const <List<double>>[]) {
      if (waypoint.length < 2) continue;
      anchors.add(gmaps.LatLng(waypoint[0], waypoint[1]));
    }
    anchors.add(gmaps.LatLng(destLat, destLng));
    return anchors;
  }

  List<gmaps.LatLng> _sampleWaterwayPath(List<gmaps.LatLng> anchors) {
    if (anchors.length < 2) return anchors;
    final out = <gmaps.LatLng>[];
    for (var index = 0; index < anchors.length - 1; index++) {
      final start = anchors[index];
      final end = anchors[index + 1];
      final legMeters = haversineMetersBetween(
        start.latitude,
        start.longitude,
        end.latitude,
        end.longitude,
      );
      final samples =
          legMeters <= 1200.0 ? 4 : (legMeters / 1800.0).round().clamp(5, 12);
      for (var step = 0; step <= samples; step++) {
        final t = step / samples;
        final lat = start.latitude + (end.latitude - start.latitude) * t;
        final lon = start.longitude + (end.longitude - start.longitude) * t;
        if (out.isNotEmpty) {
          final last = out.last;
          if ((last.latitude - lat).abs() < 1e-7 &&
              (last.longitude - lon).abs() < 1e-7) {
            continue;
          }
        }
        out.add(gmaps.LatLng(lat, lon));
      }
    }
    return out;
  }

  List<gmaps.LatLng> _simplifyWaterwayPath(List<gmaps.LatLng> path) {
    if (path.length <= 12) return path;
    final step = math.max(1, (path.length / 10).floor());
    final simplified = <gmaps.LatLng>[];
    for (var index = 0; index < path.length; index += step) {
      simplified.add(path[index]);
    }
    final last = path.last;
    if (simplified.isEmpty ||
        (simplified.last.latitude - last.latitude).abs() > 1e-7 ||
        (simplified.last.longitude - last.longitude).abs() > 1e-7) {
      simplified.add(last);
    }
    return simplified;
  }

  double _polylineDistanceMeters(List<gmaps.LatLng> path) {
    if (path.length < 2) return 0.0;
    var total = 0.0;
    for (var index = 0; index < path.length - 1; index++) {
      total += haversineMetersBetween(
        path[index].latitude,
        path[index].longitude,
        path[index + 1].latitude,
        path[index + 1].longitude,
      );
    }
    return total;
  }

  double _estimateDurationSeconds({
    required double distanceMeters,
    required int portageCount,
    required int waypointCount,
  }) {
    final travelHours = distanceMeters / _paddleMetersPerHour;
    final portagePenaltyMinutes = math.max(portageCount, waypointCount) * 12.0;
    return (travelHours * 3600.0) + (portagePenaltyMinutes * 60.0);
  }

  List<String> _buildInstructions({
    required double distanceMeters,
    required int portageCount,
    required int waypointCount,
  }) {
    final distanceKm = distanceMeters / 1000.0;
    return [
      'Paddle approximately ${distanceKm.toStringAsFixed(1)} km across connected waterways.',
      if (math.max(portageCount, waypointCount) > 0)
        'Allow extra time for ${math.max(portageCount, waypointCount)} carry transition${math.max(portageCount, waypointCount) == 1 ? '' : 's'}.',
    ];
  }

  List<Map<String, dynamic>> _buildStepDetails({
    required List<gmaps.LatLng> anchors,
    required List<gmaps.LatLng> sampledPath,
    required int portageCount,
  }) {
    final details = <Map<String, dynamic>>[];
    for (var index = 0; index < anchors.length - 1; index++) {
      final start = anchors[index];
      final end = anchors[index + 1];
      final distanceMeters = haversineMetersBetween(
        start.latitude,
        start.longitude,
        end.latitude,
        end.longitude,
      );
      details.add({
        'mode': 'waterway',
        'tabLabel': 'Paddle',
        'headline':
            'Leg ${index + 1}: ${_formatDistance(distanceMeters)} on water',
        'detail':
            index == anchors.length - 2
                ? 'Finish at destination'
                : 'Continue through the next lake connection',
        'focusLat': end.latitude,
        'focusLon': end.longitude,
        'focusZoom': 11.0,
        'path': sampledPath
            .map((point) => {'lat': point.latitude, 'lon': point.longitude})
            .toList(growable: false),
      });
    }
    if (portageCount > 0 && details.isNotEmpty) {
      details.last['caption'] =
          'Includes approximately $portageCount mapped carry transition${portageCount == 1 ? '' : 's'}.';
    }
    return details;
  }

  String _formatDistance(double meters) {
    if (meters >= 1000.0) {
      return '${(meters / 1000.0).toStringAsFixed(1)} km';
    }
    return '${meters.round()} m';
  }

  void _trimCache() {
    while (_cache.length > _maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
  }
}
