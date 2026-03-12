import 'dart:async';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
// ignore: uri_does_not_exist
import 'dart:js_util' as js_util;

import 'package:trypr/services/google_maps_loader_web.dart';

Object? _directionsService;

class TravelRouteOption {
  final String mode;
  final String summary;
  final double distanceMeters;
  final double durationSeconds;
  final int transferCount;
  final int layoverCount;
  final double layoverMinutes;
  final String departureTimeText;
  final String arrivalTimeText;
  final List<String> instructions;
  final String? transitLineColor;
  final Map<String, dynamic>? transitArrivalStop;

  const TravelRouteOption({
    required this.mode,
    required this.summary,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.transferCount,
    required this.layoverCount,
    required this.layoverMinutes,
    required this.departureTimeText,
    required this.arrivalTimeText,
    required this.instructions,
    this.transitLineColor,
    this.transitArrivalStop,
  });

  Map<String, dynamic> toMap() {
    return {
      'mode': mode,
      'summary': summary,
      'distanceMeters': distanceMeters,
      'durationSeconds': durationSeconds,
      'transferCount': transferCount,
      'layoverCount': layoverCount,
      'layoverMinutes': layoverMinutes,
      'departureTimeText': departureTimeText,
      'arrivalTimeText': arrivalTimeText,
      'instructions': instructions,
      if (transitLineColor != null) 'transitLineColor': transitLineColor,
      if (transitArrivalStop != null) 'transitArrivalStop': transitArrivalStop,
    };
  }
}

class _TransitWindow {
  final int departureMs;
  final int arrivalMs;

  const _TransitWindow({required this.departureMs, required this.arrivalMs});
}

Object? _getGoogle() {
  return js_util.getProperty(html.window, 'google');
}

Object? _getMaps() {
  final google = _getGoogle();
  if (google == null) return null;
  return js_util.getProperty(google, 'maps');
}

Future<void> _ensureDirectionsService() async {
  await ensureGoogleMapsLoaded();
  final maps = _getMaps();
  if (maps == null) return;

  if (_directionsService == null) {
    final ctor = js_util.getProperty(maps, 'DirectionsService');
    _directionsService = js_util.callConstructor(ctor, const []);
  }
}

String _normalizeMode(String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'train':
    case 'rail':
    case 'public_transit':
    case 'public transit':
    case 'transit':
      return 'transit';
    case 'driving':
    case 'walking':
    case 'hiking':
    case 'portaging':
    case 'backpacking':
    case 'biking':
    case 'bikepacking':
      return raw.trim().toLowerCase();
    default:
      return 'driving';
  }
}

String _googleModeFor(String mode) {
  switch (mode) {
    case 'transit':
      return 'TRANSIT';
    case 'walking':
    case 'hiking':
    case 'portaging':
    case 'backpacking':
      return 'WALKING';
    case 'biking':
    case 'bikepacking':
      return 'BICYCLING';
    default:
      return 'DRIVING';
  }
}

Object _jsDepartureTime(DateTime? departureTime) {
  try {
    final dateCtor = js_util.getProperty(html.window, 'Date');
    final when =
        (departureTime ?? DateTime.now().add(const Duration(minutes: 5)))
            .millisecondsSinceEpoch;
    return js_util.callConstructor(dateCtor, [when]);
  } catch (_) {
    return (departureTime ?? DateTime.now()).toIso8601String();
  }
}

String _stripHtml(String value) {
  return value
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String _timeText(Object? timeObj) {
  if (timeObj == null) return '';
  try {
    return (js_util.getProperty(timeObj, 'text') ?? '').toString().trim();
  } catch (_) {
    return '';
  }
}

int? _timeMillis(Object? timeObj) {
  if (timeObj == null) return null;
  try {
    final value = js_util.getProperty(timeObj, 'value');
    if (value == null) return null;
    final ms = js_util.callMethod(value, 'getTime', const []);
    if (ms is num) return ms.toInt();
  } catch (_) {}
  return null;
}

Map<String, dynamic>? _stopToMap(Object? stop) {
  if (stop == null) return null;
  try {
    final name = (js_util.getProperty(stop, 'name') ?? '').toString().trim();
    final location = js_util.getProperty(stop, 'location');
    if (location == null) {
      if (name.isEmpty) return null;
      return {'name': name};
    }
    final lat =
        (js_util.callMethod(location, 'lat', const []) as num?)?.toDouble();
    final lng =
        (js_util.callMethod(location, 'lng', const []) as num?)?.toDouble();
    if (lat == null || lng == null) {
      if (name.isEmpty) return null;
      return {'name': name};
    }
    return {if (name.isNotEmpty) 'name': name, 'lat': lat, 'lon': lng};
  } catch (_) {
    return null;
  }
}

String _routeSummary(
  Object route,
  String mode,
  List<String> instructions,
  int optionNumber,
) {
  final summary =
      (js_util.getProperty(route, 'summary') ?? '').toString().trim();
  if (summary.isNotEmpty) return summary;
  if (instructions.isNotEmpty) return instructions.first;
  switch (mode) {
    case 'transit':
      return 'Transit option $optionNumber';
    case 'biking':
    case 'bikepacking':
      return 'Bike route $optionNumber';
    case 'walking':
    case 'hiking':
    case 'backpacking':
      return 'Walking route $optionNumber';
    case 'portaging':
      return 'Portage route $optionNumber';
    default:
      return 'Driving route $optionNumber';
  }
}

Future<List<TravelRouteOption>> getRouteOptions({
  required double originLat,
  required double originLng,
  required double destLat,
  required double destLng,
  required String mode,
  DateTime? departureTime,
  bool avoidHighways = false,
  bool avoidTolls = false,
  int maxOptions = 4,
}) async {
  try {
    final normalizedMode = _normalizeMode(mode);
    await _ensureDirectionsService().timeout(const Duration(milliseconds: 900));

    final svc = _directionsService;
    final maps = _getMaps();
    if (svc == null || maps == null) return const <TravelRouteOption>[];

    final travelModeEnum = js_util.getProperty(
      js_util.getProperty(maps, 'TravelMode'),
      _googleModeFor(normalizedMode),
    );

    final requestMap = <String, dynamic>{
      'origin': js_util.jsify({'lat': originLat, 'lng': originLng}),
      'destination': js_util.jsify({'lat': destLat, 'lng': destLng}),
      'travelMode': travelModeEnum,
      'provideRouteAlternatives': true,
      'avoidHighways': avoidHighways || normalizedMode == 'biking',
      'avoidTolls': avoidTolls,
    };

    if (normalizedMode == 'transit') {
      Object? trainMode;
      try {
        trainMode = js_util.getProperty(
          js_util.getProperty(maps, 'TransitMode'),
          'TRAIN',
        );
      } catch (_) {}

      requestMap['transitOptions'] = js_util.jsify({
        'routingPreference': 'FEWER_TRANSFERS',
        'departureTime': _jsDepartureTime(departureTime),
        if (trainMode != null) 'modes': js_util.jsify([trainMode]),
      });
    }

    final request = js_util.jsify(requestMap);
    final completer = Completer<List<TravelRouteOption>>();

    void done(List<TravelRouteOption> value) {
      if (!completer.isCompleted) completer.complete(value);
    }

    final callback = js_util.allowInterop((result, status) {
      try {
        final statusStr = status?.toString() ?? '';
        if (statusStr != 'OK' || result == null) {
          done(const <TravelRouteOption>[]);
          return;
        }

        final routesAny = js_util.getProperty(result, 'routes');
        if (routesAny is! List || routesAny.isEmpty) {
          done(const <TravelRouteOption>[]);
          return;
        }

        final options = <TravelRouteOption>[];
        final routes = routesAny.take(maxOptions).toList();

        for (var idx = 0; idx < routes.length; idx++) {
          final route = routes[idx];
          var totalDistance = 0.0;
          var totalDuration = 0.0;
          final instructions = <String>[];

          String departureText = '';
          String arrivalText = '';

          String? transitLineColor;
          Map<String, dynamic>? transitArrivalStop;
          final transitWindows = <_TransitWindow>[];
          var transitLegCount = 0;

          final legs = js_util.getProperty(route, 'legs');
          if (legs is List) {
            for (final leg in legs) {
              final distance = js_util.getProperty(leg, 'distance');
              final duration = js_util.getProperty(leg, 'duration');
              if (distance != null) {
                final val = js_util.getProperty(distance, 'value');
                if (val is num) totalDistance += val.toDouble();
              }
              if (duration != null) {
                final val = js_util.getProperty(duration, 'value');
                if (val is num) totalDuration += val.toDouble();
              }

              final legDeparture = js_util.getProperty(leg, 'departure_time');
              final legArrival = js_util.getProperty(leg, 'arrival_time');
              if (departureText.isEmpty) {
                departureText = _timeText(legDeparture);
              }
              final legArrivalText = _timeText(legArrival);
              if (legArrivalText.isNotEmpty) {
                arrivalText = legArrivalText;
              }

              final steps = js_util.getProperty(leg, 'steps');
              if (steps is! List) continue;

              for (final step in steps) {
                final stepMode =
                    (js_util.getProperty(step, 'travel_mode') ?? '')
                        .toString()
                        .toUpperCase();

                if (normalizedMode == 'transit' && stepMode == 'TRANSIT') {
                  final transit = js_util.getProperty(step, 'transit');
                  if (transit == null) continue;

                  transitLegCount++;

                  final line = js_util.getProperty(transit, 'line');
                  final shortName =
                      (line == null
                              ? ''
                              : (js_util.getProperty(line, 'short_name') ?? ''))
                          .toString()
                          .trim();
                  final lineName =
                      (line == null
                              ? ''
                              : (js_util.getProperty(line, 'name') ?? ''))
                          .toString()
                          .trim();
                  final lineColor =
                      (line == null
                              ? ''
                              : (js_util.getProperty(line, 'color') ?? ''))
                          .toString()
                          .trim();
                  if (lineColor.isNotEmpty) {
                    transitLineColor ??= lineColor;
                  }

                  final vehicle =
                      line == null
                          ? null
                          : js_util.getProperty(line, 'vehicle');
                  final vehicleName =
                      (vehicle == null
                              ? ''
                              : (js_util.getProperty(vehicle, 'name') ?? ''))
                          .toString()
                          .trim();

                  final headsign =
                      (js_util.getProperty(transit, 'headsign') ?? '')
                          .toString()
                          .trim();

                  final depStop = js_util.getProperty(
                    transit,
                    'departure_stop',
                  );
                  final arrStop = js_util.getProperty(transit, 'arrival_stop');
                  final depStopName =
                      (depStop == null
                              ? ''
                              : (js_util.getProperty(depStop, 'name') ?? ''))
                          .toString()
                          .trim();
                  final arrStopName =
                      (arrStop == null
                              ? ''
                              : (js_util.getProperty(arrStop, 'name') ?? ''))
                          .toString()
                          .trim();

                  final depTimeObj = js_util.getProperty(
                    transit,
                    'departure_time',
                  );
                  final arrTimeObj = js_util.getProperty(
                    transit,
                    'arrival_time',
                  );

                  if (departureText.isEmpty) {
                    departureText = _timeText(depTimeObj);
                  }
                  final arrText = _timeText(arrTimeObj);
                  if (arrText.isNotEmpty) {
                    arrivalText = arrText;
                  }

                  final depMs = _timeMillis(depTimeObj);
                  final arrMs = _timeMillis(arrTimeObj);
                  if (depMs != null && arrMs != null && arrMs >= depMs) {
                    transitWindows.add(
                      _TransitWindow(departureMs: depMs, arrivalMs: arrMs),
                    );
                  }

                  final arrivalStopMap = _stopToMap(arrStop);
                  if (arrivalStopMap != null) {
                    transitArrivalStop = arrivalStopMap;
                  }

                  final label = [
                    if (vehicleName.isNotEmpty) vehicleName,
                    if (shortName.isNotEmpty)
                      shortName
                    else if (lineName.isNotEmpty)
                      lineName,
                  ].join(' ');

                  final stopPart =
                      (depStopName.isNotEmpty && arrStopName.isNotEmpty)
                          ? '$depStopName -> $arrStopName'
                          : '';
                  final headPart = headsign.isNotEmpty ? '-> $headsign' : '';
                  final full = [
                    label,
                    stopPart,
                    headPart,
                  ].where((s) => s.trim().isNotEmpty).join(' - ');
                  if (full.isNotEmpty) {
                    instructions.add(full);
                  }
                } else {
                  final htmlInstr =
                      (js_util.getProperty(step, 'instructions') ?? '')
                          .toString();
                  final clean = _stripHtml(htmlInstr);
                  if (clean.isEmpty) continue;

                  final stepDist = js_util.getProperty(step, 'distance');
                  final distText =
                      (stepDist == null
                              ? ''
                              : (js_util.getProperty(stepDist, 'text') ?? ''))
                          .toString()
                          .trim();

                  instructions.add(
                    distText.isNotEmpty ? '$clean ($distText)' : clean,
                  );
                }
              }
            }
          }

          var layoverCount = 0;
          var layoverMinutes = 0.0;
          if (transitWindows.length > 1) {
            for (var i = 1; i < transitWindows.length; i++) {
              final prev = transitWindows[i - 1];
              final curr = transitWindows[i];
              final gapMs = curr.departureMs - prev.arrivalMs;
              if (gapMs <= 0) continue;
              final gapMin = gapMs / 60000.0;
              if (gapMin < 3) continue;
              layoverCount++;
              layoverMinutes += gapMin;
            }
          }

          final transferCount = transitLegCount > 0 ? transitLegCount - 1 : 0;

          options.add(
            TravelRouteOption(
              mode: normalizedMode,
              summary: _routeSummary(
                route,
                normalizedMode,
                instructions,
                idx + 1,
              ),
              distanceMeters: totalDistance,
              durationSeconds: totalDuration,
              transferCount: transferCount,
              layoverCount: layoverCount,
              layoverMinutes: layoverMinutes,
              departureTimeText: departureText,
              arrivalTimeText: arrivalText,
              instructions: instructions.take(8).toList(),
              transitLineColor: transitLineColor,
              transitArrivalStop: transitArrivalStop,
            ),
          );
        }

        done(options);
      } catch (_) {
        done(const <TravelRouteOption>[]);
      }
    });

    js_util.callMethod(svc, 'route', [request, callback]);

    return await completer.future.timeout(
      const Duration(seconds: 16),
      onTimeout: () => const <TravelRouteOption>[],
    );
  } catch (_) {
    return const <TravelRouteOption>[];
  }
}
