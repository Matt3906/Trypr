// Web Google Directions Service via JS interop.
//
// Uses the Google Maps JavaScript API DirectionsService to avoid CORS issues
// that would occur when calling the REST API directly from the browser.

import 'dart:async';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
// ignore: uri_does_not_exist
import 'dart:js_util' as js_util;

import 'package:flutter/foundation.dart';
import 'package:trypr/services/google_maps_loader_web.dart';

Object? _directionsService;
const Duration _mapsBootstrapTimeout = Duration(seconds: 8);
const Duration _directionsCtorTimeout = Duration(seconds: 4);

Object? _getGoogle() {
  return js_util.getProperty(html.window, 'google');
}

Object? _getMaps() {
  final google = _getGoogle();
  if (google == null) return null;
  return js_util.getProperty(google, 'maps');
}

Object _jsDepartureTime() {
  try {
    final dateCtor = js_util.getProperty(html.window, 'Date');
    final millis =
        DateTime.now().add(const Duration(minutes: 5)).millisecondsSinceEpoch;
    return js_util.callConstructor(dateCtor, [millis]);
  } catch (_) {
    // Fallback keeps request valid enough for non-critical failure paths.
    return DateTime.now().toIso8601String();
  }
}

Future<void> _ensureDirectionsService() async {
  await ensureGoogleMapsLoaded().timeout(_mapsBootstrapTimeout);
  final maps = await _waitForMapsObject();
  if (maps == null) {
    debugPrint('googleDirections: maps object is null after wait');
    return;
  }

  if (_directionsService != null) return;

  await _importRoutesLibrary(maps);
  final directionsServiceCtor = await _waitForDirectionsServiceCtor(maps);
  if (directionsServiceCtor == null) {
    debugPrint(
      'googleDirections: DirectionsService constructor is null after wait',
    );
    return;
  }

  _directionsService = js_util.callConstructor(directionsServiceCtor, const []);
  debugPrint('googleDirections: DirectionsService initialized successfully');
}

Future<Object?> _waitForMapsObject() async {
  final deadline = DateTime.now().add(_directionsCtorTimeout);
  while (DateTime.now().isBefore(deadline)) {
    final maps = _getMaps();
    if (maps != null) return maps;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return _getMaps();
}

Future<void> _importRoutesLibrary(Object maps) async {
  try {
    final importLibrary = js_util.getProperty(maps, 'importLibrary');
    if (importLibrary == null) return;
    final promise = js_util.callMethod<Object?>(maps, 'importLibrary', const [
      'routes',
    ]);
    if (promise == null) return;
    await js_util
        .promiseToFuture<Object?>(promise)
        .timeout(_directionsCtorTimeout);
  } catch (_) {}
}

Future<Object?> _waitForDirectionsServiceCtor(Object maps) async {
  final deadline = DateTime.now().add(_directionsCtorTimeout);
  while (DateTime.now().isBefore(deadline)) {
    try {
      final ctor = js_util.getProperty(maps, 'DirectionsService');
      if (ctor != null) return ctor;
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  try {
    return js_util.getProperty(maps, 'DirectionsService');
  } catch (_) {
    return null;
  }
}

/// Result from a directions request.
class DirectionsResult {
  final List<List<double>> polylinePoints; // List of [lat, lng]
  final double distanceMeters;
  final double durationSeconds;
  final List<String> instructions;
  final List<Map<String, dynamic>> stepDetails;
  final Map<String, dynamic>? transitArrivalStop;
  final String? transitLineColor;

  DirectionsResult({
    required this.polylinePoints,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.instructions,
    this.stepDetails = const [],
    this.transitArrivalStop,
    this.transitLineColor,
  });
}

String _tabLabelForTransitStep({
  required String travelMode,
  String shortName = '',
  String vehicleName = '',
}) {
  switch (travelMode.trim().toUpperCase()) {
    case 'WALKING':
      return 'Walk';
    case 'BICYCLING':
      return 'Bike';
    case 'TRANSIT':
      if (shortName.isNotEmpty) return 'Train $shortName';
      if (vehicleName.isNotEmpty) return vehicleName;
      return 'Transit';
    default:
      return 'Step';
  }
}

Map<String, dynamic> _stepDetail({
  required String mode,
  required String tabLabel,
  required String headline,
  String detail = '',
  String caption = '',
  String lineColor = '',
  double? focusLat,
  double? focusLon,
  double? focusZoom,
  List<Map<String, dynamic>> path = const [],
}) {
  return {
    'mode': mode.trim().toLowerCase(),
    'tabLabel': tabLabel.trim(),
    'headline': headline.trim(),
    if (detail.trim().isNotEmpty) 'detail': detail.trim(),
    if (caption.trim().isNotEmpty) 'caption': caption.trim(),
    if (lineColor.trim().isNotEmpty) 'lineColor': lineColor.trim(),
    if (focusLat != null && focusLon != null) ...{
      'focusLat': focusLat,
      'focusLon': focusLon,
    },
    if (focusZoom != null && focusZoom.isFinite) 'focusZoom': focusZoom,
    if (path.isNotEmpty) 'path': path,
  };
}

double? _jsLat(Object? location) {
  if (location == null) return null;
  try {
    return (js_util.callMethod(location, 'lat', const []) as num?)?.toDouble();
  } catch (_) {
    return null;
  }
}

double? _jsLng(Object? location) {
  if (location == null) return null;
  try {
    return (js_util.callMethod(location, 'lng', const []) as num?)?.toDouble();
  } catch (_) {
    return null;
  }
}

Map<String, dynamic>? _pointFromLocation(Object? location) {
  final lat = _jsLat(location);
  final lon = _jsLng(location);
  if (lat == null || lon == null || !lat.isFinite || !lon.isFinite) {
    return null;
  }
  return {'lat': lat, 'lon': lon, 'lng': lon};
}

void _appendDistinctPoint(
  List<Map<String, dynamic>> out,
  Map<String, dynamic>? point,
) {
  if (point == null) return;
  final lat = (point['lat'] as num?)?.toDouble();
  final lon = (point['lon'] as num?)?.toDouble();
  if (lat == null || lon == null || !lat.isFinite || !lon.isFinite) return;
  if (out.isNotEmpty) {
    final last = out.last;
    final lastLat = (last['lat'] as num?)?.toDouble();
    final lastLon = (last['lon'] as num?)?.toDouble();
    if (lastLat != null &&
        lastLon != null &&
        (lastLat - lat).abs() < 1e-7 &&
        (lastLon - lon).abs() < 1e-7) {
      return;
    }
  }
  out.add({'lat': lat, 'lon': lon, 'lng': lon});
}

List<Map<String, dynamic>> _pathFromStep(
  Object step, {
  Map<String, dynamic>? startPoint,
  Map<String, dynamic>? endPoint,
}) {
  final out = <Map<String, dynamic>>[];
  _appendDistinctPoint(out, startPoint);

  final stepPath = js_util.getProperty(step, 'path');
  if (stepPath is List) {
    for (final point in stepPath) {
      _appendDistinctPoint(out, _pointFromLocation(point));
    }
  }

  _appendDistinctPoint(out, endPoint);
  return out;
}

Map<String, dynamic>? _focusPointFromPath(List<Map<String, dynamic>> path) {
  if (path.isEmpty) return null;
  if (path.length == 1) return Map<String, dynamic>.from(path.first);
  return Map<String, dynamic>.from(path[path.length ~/ 2]);
}

double _focusZoomForStepMode(String mode) {
  switch (mode.trim().toUpperCase()) {
    case 'WALKING':
      return 15.4;
    case 'BICYCLING':
      return 14.8;
    case 'TRANSIT':
      return 13.6;
    default:
      return 14.0;
  }
}

/// Get directions between two points using Google Maps JS API.
///
/// [mode] should be one of: 'driving', 'walking', 'bicycling', 'transit'
/// [waypoints] is an optional list of intermediate points as [lat, lng] pairs.
/// [avoidHighways] and [avoidTolls] can be set to prefer quieter routes.
Future<DirectionsResult?> getDirections({
  required double originLat,
  required double originLng,
  required double destLat,
  required double destLng,
  required String mode,
  List<List<double>>? waypoints,
  String? originQuery,
  String? destQuery,
  List<String>? waypointQueries,
  bool avoidHighways = false,
  bool avoidTolls = false,
  bool includeTransitTrainMode = true,
}) async {
  try {
    // DirectionsService initialization can take >800ms on cold web loads.
    await _ensureDirectionsService();
    final svc = _directionsService;
    if (svc == null) return null;

    final maps = _getMaps();
    if (maps == null) return null;

    final c = Completer<DirectionsResult?>();
    final trimmedOriginQuery = originQuery?.trim() ?? '';
    final trimmedDestQuery = destQuery?.trim() ?? '';
    final normalizedWaypointQueries = waypointQueries
        ?.map((q) => q.trim())
        .toList(growable: false);
    final useQueryLocations =
        trimmedOriginQuery.isNotEmpty ||
        trimmedDestQuery.isNotEmpty ||
        (normalizedWaypointQueries?.any((q) => q.isNotEmpty) ?? false);

    // Build waypoints array for Google
    final jsWaypoints = <Object>[];
    if (waypoints != null && waypoints.isNotEmpty) {
      for (var i = 0; i < waypoints.length; i++) {
        final wp = waypoints[i];
        if (wp.length >= 2) {
          final waypointQuery =
              normalizedWaypointQueries != null &&
                      i < normalizedWaypointQueries.length
                  ? normalizedWaypointQueries[i]
                  : '';
          jsWaypoints.add(
            js_util.jsify({
              'location':
                  waypointQuery.isNotEmpty
                      ? waypointQuery
                      : js_util.jsify({'lat': wp[0], 'lng': wp[1]}),
              'stopover': true,
            }),
          );
        }
      }
    }

    // Build the request
    final travelMode = js_util.getProperty(
      js_util.getProperty(maps, 'TravelMode'),
      mode.toUpperCase(),
    );

    final requestMap = <String, dynamic>{
      'origin':
          trimmedOriginQuery.isNotEmpty
              ? trimmedOriginQuery
              : js_util.jsify({'lat': originLat, 'lng': originLng}),
      'destination':
          trimmedDestQuery.isNotEmpty
              ? trimmedDestQuery
              : js_util.jsify({'lat': destLat, 'lng': destLng}),
      'travelMode': travelMode,
      // For bicycling mode, Google Maps already prefers bike paths, bike lanes,
      // and quieter roads. Adding avoidHighways further ensures we stay off
      // busy roads when possible.
      'avoidHighways': avoidHighways || mode.toLowerCase() == 'bicycling',
      'avoidTolls': avoidTolls,
    };

    if (jsWaypoints.isNotEmpty) {
      requestMap['waypoints'] = js_util.jsify(jsWaypoints);
    }

    if (mode.toLowerCase() == 'transit') {
      Object? trainMode;
      try {
        trainMode = js_util.getProperty(
          js_util.getProperty(maps, 'TransitMode'),
          'TRAIN',
        );
      } catch (_) {}

      requestMap['transitOptions'] = js_util.jsify({
        'routingPreference': 'FEWER_TRANSFERS',
        'departureTime': _jsDepartureTime(),
        if (includeTransitTrainMode && trainMode != null)
          'modes': js_util.jsify([trainMode]),
      });
    }

    final request = js_util.jsify(requestMap);

    void done(DirectionsResult? v) {
      if (!c.isCompleted) c.complete(v);
    }

    final callback = js_util.allowInterop((result, status) {
      try {
        final statusStr = status?.toString() ?? '';
        if (statusStr != 'OK' || result == null) {
          debugPrint(
            'googleDirections status=$statusStr mode=$mode use_queries=$useQueryLocations',
          );
          done(null);
          return;
        }

        // Extract routes
        final routes = js_util.getProperty(result, 'routes');
        if (routes == null) {
          done(null);
          return;
        }

        final routeList = routes as List;
        if (routeList.isEmpty) {
          done(null);
          return;
        }

        final route = routeList.first;

        final polyPoints = <List<double>>[];

        // Prefer overview_path (array of LatLng objects).
        final overviewPath = js_util.getProperty(route, 'overview_path');
        if (overviewPath is List && overviewPath.isNotEmpty) {
          for (final pt in overviewPath) {
            final lat =
                (js_util.callMethod(pt, 'lat', const []) as num?)?.toDouble();
            final lng =
                (js_util.callMethod(pt, 'lng', const []) as num?)?.toDouble();
            if (lat == null || lng == null) continue;
            polyPoints.add([lat, lng]);
          }
        }

        // Fallback to encoded overview polyline string.
        if (polyPoints.isEmpty) {
          final overviewPolyline = js_util.getProperty(
            route,
            'overview_polyline',
          );
          if (overviewPolyline != null) {
            final encodedStr = js_util.getProperty(overviewPolyline, 'points');
            final encoded = encodedStr?.toString() ?? '';
            if (encoded.isNotEmpty) {
              polyPoints.addAll(_decodePolyline(encoded));
            }
          }
        }

        // Extract distance and duration from legs
        final legs = js_util.getProperty(route, 'legs') as List?;
        var totalDist = 0.0;
        var totalDur = 0.0;
        final instructions = <String>[];
        final stepDetails = <Map<String, dynamic>>[];
        Map<String, dynamic>? transitArrivalStop;
        String? transitLineColor;

        if (legs != null) {
          for (final leg in legs) {
            final distance = js_util.getProperty(leg, 'distance');
            final duration = js_util.getProperty(leg, 'duration');

            if (distance != null) {
              final val = js_util.getProperty(distance, 'value');
              if (val is num) totalDist += val.toDouble();
            }
            if (duration != null) {
              final val = js_util.getProperty(duration, 'value');
              if (val is num) totalDur += val.toDouble();
            }

            // Get steps for instructions
            final steps = js_util.getProperty(leg, 'steps') as List?;
            if (steps != null) {
              for (final step in steps) {
                final travelMode =
                    js_util.getProperty(step, 'travel_mode')?.toString() ?? '';

                if (mode.toLowerCase() == 'transit' &&
                    travelMode == 'TRANSIT') {
                  // Extract transit details
                  final transit = js_util.getProperty(step, 'transit');
                  if (transit != null) {
                    final line = js_util.getProperty(transit, 'line');
                    if (line != null) {
                      final shortName =
                          js_util.getProperty(line, 'short_name')?.toString() ??
                          '';
                      final lineName =
                          js_util.getProperty(line, 'name')?.toString() ?? '';
                      final color =
                          js_util.getProperty(line, 'color')?.toString();
                      transitLineColor ??= color;

                      final vehicle = js_util.getProperty(line, 'vehicle');
                      final vehicleName =
                          vehicle != null
                              ? js_util
                                      .getProperty(vehicle, 'name')
                                      ?.toString() ??
                                  ''
                              : '';

                      final headsign =
                          js_util
                              .getProperty(transit, 'headsign')
                              ?.toString() ??
                          '';

                      final depStop = js_util.getProperty(
                        transit,
                        'departure_stop',
                      );
                      final arrStop = js_util.getProperty(
                        transit,
                        'arrival_stop',
                      );
                      final depName =
                          depStop != null
                              ? js_util
                                      .getProperty(depStop, 'name')
                                      ?.toString() ??
                                  ''
                              : '';
                      final arrName =
                          arrStop != null
                              ? js_util
                                      .getProperty(arrStop, 'name')
                                      ?.toString() ??
                                  ''
                              : '';

                      // Get arrival stop location
                      if (arrStop != null) {
                        final arrLoc = js_util.getProperty(arrStop, 'location');
                        if (arrLoc != null) {
                          final arrLat =
                              (js_util.callMethod(arrLoc, 'lat', const [])
                                      as num?)
                                  ?.toDouble();
                          final arrLng =
                              (js_util.callMethod(arrLoc, 'lng', const [])
                                      as num?)
                                  ?.toDouble();
                          if (arrLat != null && arrLng != null) {
                            transitArrivalStop = {
                              'name': arrName,
                              'lat': arrLat,
                              'lon': arrLng,
                            };
                          }
                        }
                      }

                      final stepStart =
                          _pointFromLocation(
                            js_util.getProperty(step, 'start_location'),
                          ) ??
                          _pointFromLocation(
                            depStop == null
                                ? null
                                : js_util.getProperty(depStop, 'location'),
                          );
                      final stepEnd =
                          _pointFromLocation(
                            js_util.getProperty(step, 'end_location'),
                          ) ??
                          _pointFromLocation(
                            arrStop == null
                                ? null
                                : js_util.getProperty(arrStop, 'location'),
                          );
                      final stepPath = _pathFromStep(
                        step,
                        startPoint: stepStart,
                        endPoint: stepEnd,
                      );
                      final focusPoint =
                          _focusPointFromPath(stepPath) ?? stepStart ?? stepEnd;

                      final label = [
                        if (vehicleName.isNotEmpty) vehicleName,
                        if (shortName.isNotEmpty)
                          shortName
                        else if (lineName.isNotEmpty)
                          lineName,
                      ].join(' ');

                      final stopPart =
                          (depName.isNotEmpty && arrName.isNotEmpty)
                              ? '$depName → $arrName'
                              : '';
                      final headPart = headsign.isNotEmpty ? '→ $headsign' : '';
                      final full = [
                        label,
                        stopPart,
                        headPart,
                      ].where((s) => s.trim().isNotEmpty).join(' — ');
                      if (full.isNotEmpty) instructions.add(full);
                      if (full.isNotEmpty) {
                        stepDetails.add(
                          _stepDetail(
                            mode: 'transit',
                            tabLabel: _tabLabelForTransitStep(
                              travelMode: travelMode,
                              shortName: shortName,
                              vehicleName: vehicleName,
                            ),
                            headline: full,
                            detail: stopPart,
                            caption: headsign,
                            lineColor: color ?? '',
                            focusLat:
                                (focusPoint?['lat'] as num?)?.toDouble(),
                            focusLon:
                                (focusPoint?['lon'] as num?)?.toDouble(),
                            focusZoom: _focusZoomForStepMode(travelMode),
                            path: stepPath,
                          ),
                        );
                      }
                    }
                  }
                } else {
                  // Regular step instructions
                  final htmlInstr =
                      js_util.getProperty(step, 'instructions')?.toString() ??
                      '';
                  final clean = _stripHtml(htmlInstr);
                  if (clean.isNotEmpty) {
                    final stepDist = js_util.getProperty(step, 'distance');
                    final distText =
                        stepDist != null
                            ? js_util
                                    .getProperty(stepDist, 'text')
                                    ?.toString() ??
                                ''
                            : '';
                    final stepStart = _pointFromLocation(
                      js_util.getProperty(step, 'start_location'),
                    );
                    final stepEnd = _pointFromLocation(
                      js_util.getProperty(step, 'end_location'),
                    );
                    final stepPath = _pathFromStep(
                      step,
                      startPoint: stepStart,
                      endPoint: stepEnd,
                    );
                    final focusPoint =
                        _focusPointFromPath(stepPath) ?? stepStart ?? stepEnd;
                    final stepLine =
                        distText.isNotEmpty ? '$clean ($distText)' : clean;
                    instructions.add(stepLine);
                    if (mode.toLowerCase() == 'transit') {
                      stepDetails.add(
                        _stepDetail(
                          mode: travelMode.isEmpty ? 'walking' : travelMode,
                          tabLabel: _tabLabelForTransitStep(
                            travelMode:
                                travelMode.isEmpty ? 'WALKING' : travelMode,
                          ),
                          headline: clean,
                          detail: distText,
                          focusLat:
                              (focusPoint?['lat'] as num?)?.toDouble(),
                          focusLon:
                              (focusPoint?['lon'] as num?)?.toDouble(),
                          focusZoom: _focusZoomForStepMode(
                            travelMode.isEmpty ? 'WALKING' : travelMode,
                          ),
                          path: stepPath,
                        ),
                      );
                    }
                  }
                }

                // If overview polyline is unavailable, build path from step
                // paths so we still render the transit line.
                if (polyPoints.isEmpty) {
                  final stepPath = js_util.getProperty(step, 'path');
                  if (stepPath is List && stepPath.isNotEmpty) {
                    for (final pt in stepPath) {
                      final lat =
                          (js_util.callMethod(pt, 'lat', const []) as num?)
                              ?.toDouble();
                      final lng =
                          (js_util.callMethod(pt, 'lng', const []) as num?)
                              ?.toDouble();
                      if (lat == null || lng == null) continue;
                      if (polyPoints.isNotEmpty) {
                        final last = polyPoints.last;
                        if ((last[0] - lat).abs() < 1e-7 &&
                            (last[1] - lng).abs() < 1e-7) {
                          continue;
                        }
                      }
                      polyPoints.add([lat, lng]);
                    }
                  }
                }
              }
            }
          }
        }

        done(
          DirectionsResult(
            polylinePoints: polyPoints,
            distanceMeters: totalDist,
            durationSeconds: totalDur,
            instructions: instructions.take(6).toList(),
            stepDetails: stepDetails.take(6).toList(growable: false),
            transitArrivalStop: transitArrivalStop,
            transitLineColor: transitLineColor,
          ),
        );
      } catch (e) {
        debugPrint('googleDirections callback_exception mode=$mode err=$e');
        done(null);
      }
    });

    js_util.callMethod(svc, 'route', [request, callback]);

    return await c.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => null,
    );
  } catch (e) {
    debugPrint('googleDirections request_exception mode=$mode err=$e');
    return null;
  }
}

/// Decode a Google polyline encoded string.
List<List<double>> _decodePolyline(String encoded) {
  final points = <List<double>>[];
  var index = 0;
  var lat = 0;
  var lng = 0;

  while (index < encoded.length) {
    var result = 0;
    var shift = 0;
    int b;
    do {
      b = encoded.codeUnitAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    final dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
    lat += dlat;

    result = 0;
    shift = 0;
    do {
      b = encoded.codeUnitAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    final dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
    lng += dlng;

    points.add([lat / 1e5, lng / 1e5]);
  }

  return points;
}

/// Strip HTML tags from a string.
String _stripHtml(String html) {
  return html
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
