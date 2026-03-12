import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import 'package:latlong2/latlong.dart' as latlng;
import 'package:trypr/utils/route_cache.dart';

class MapPreview extends StatelessWidget {
  final List<dynamic> waypoints;
  final List<dynamic> routeGeometry;
  final String transportMode;
  final List<String> segmentTransportModes;

  const MapPreview({
    super.key,
    required this.waypoints,
    this.routeGeometry = const [],
    this.transportMode = 'car',
    this.segmentTransportModes = const [],
  });

  List<latlng.LatLng> _waypointLatLngs() {
    final pts = <latlng.LatLng>[];
    for (final w in waypoints) {
      try {
        if (w is Map) {
          final lat = (w['lat'] ?? w['latitude'] ?? w['locationLat']) as num?;
          final lon =
              (w['lon'] ?? w['longitude'] ?? w['lng'] ?? w['locationLon'])
                  as num?;
          if (lat != null && lon != null) {
            pts.add(latlng.LatLng(lat.toDouble(), lon.toDouble()));
          }
        }
      } catch (_) {
        continue;
      }
    }
    return pts;
  }

  List<latlng.LatLng> _routeLatLngs() {
    final cached = simplifyRouteGeometry(
      readRouteGeometry(routeGeometry),
      maxPoints: 160,
    );
    if (cached.isNotEmpty) {
      return cached
          .map(
            (p) => latlng.LatLng(
              (p['lat'] as num).toDouble(),
              ((p['lon'] ?? p['lng']) as num).toDouble(),
            ),
          )
          .toList(growable: false);
    }
    return _waypointLatLngs();
  }

  String _activeMode() {
    final normalizedSegments = segmentTransportModes
        .map(normalizeRouteMode)
        .where((mode) => mode.isNotEmpty)
        .toList(growable: false);
    if (normalizedSegments.isNotEmpty) return normalizedSegments.first;
    return normalizeRouteMode(transportMode);
  }

  Color _routeColor() {
    switch (_activeMode()) {
      case 'flying':
        return const Color(0xFF3949AB);
      case 'train':
        return const Color(0xFF546E7A);
      case 'walking':
        return const Color(0xFF00897B);
      case 'biking':
        return const Color(0xFF1565C0);
      case 'hiking':
        return const Color(0xFF8E24AA);
      case 'portaging':
        return const Color(0xFFD81B60);
      case 'driving':
      default:
        return const Color(0xFF1E88E5);
    }
  }

  @override
  Widget build(BuildContext context) {
    final waypointPts = _waypointLatLngs();
    final routePts = _routeLatLngs();
    final allPts = <latlng.LatLng>[...routePts, ...waypointPts];

    if (allPts.isEmpty) {
      return Container(
        color: Colors.grey.shade200,
        child: const Center(
          child: Icon(Icons.map, size: 36, color: Colors.black26),
        ),
      );
    }

    if (kIsWeb) {
      return _MapPreviewWeb(
        waypointPts: waypointPts,
        routePts: routePts,
        routeColor: _routeColor(),
      );
    }

    final bounds = LatLngBounds.fromPoints(allPts);
    final routeColor = _routeColor();
    return FlutterMap(
      options: MapOptions(
        bounds: bounds,
        boundsOptions: FitBoundsOptions(
          padding: const EdgeInsets.all(24),
          maxZoom: allPts.length <= 1 ? 12 : 10,
        ),
        interactiveFlags: InteractiveFlag.all,
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
          subdomains: const ['a', 'b', 'c'],
          userAgentPackageName: 'com.example.trypr',
        ),
        if (routePts.length > 1)
          PolylineLayer(
            polylines: [
              Polyline(
                points: routePts,
                color: Colors.white.withValues(alpha: 0.7),
                strokeWidth: 5.0,
              ),
              Polyline(
                points: routePts,
                color: routeColor.withValues(alpha: 0.9),
                strokeWidth: 3.0,
              ),
            ],
          ),
        MarkerLayer(
          markers: waypointPts
              .asMap()
              .entries
              .map((e) {
                final idx = e.key;
                final p = e.value;
                return Marker(
                  point: p,
                  width: 28,
                  height: 28,
                  builder:
                      (ctx) => Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          border: Border.all(color: routeColor, width: 2),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          '${idx + 1}',
                          style: TextStyle(
                            color: routeColor,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                );
              })
              .toList(growable: false),
        ),
      ],
    );
  }
}

class _MapPreviewWeb extends StatefulWidget {
  final List<latlng.LatLng> waypointPts;
  final List<latlng.LatLng> routePts;
  final Color routeColor;

  const _MapPreviewWeb({
    required this.waypointPts,
    required this.routePts,
    required this.routeColor,
  });

  @override
  State<_MapPreviewWeb> createState() => _MapPreviewWebState();
}

class _MapPreviewWebState extends State<_MapPreviewWeb> {
  gmaps.GoogleMapController? _controller;

  gmaps.LatLngBounds _boundsFromPoints(List<latlng.LatLng> pts) {
    double? minLat, maxLat, minLon, maxLon;
    for (final p in pts) {
      minLat =
          (minLat == null)
              ? p.latitude
              : (p.latitude < minLat ? p.latitude : minLat);
      maxLat =
          (maxLat == null)
              ? p.latitude
              : (p.latitude > maxLat ? p.latitude : maxLat);
      minLon =
          (minLon == null)
              ? p.longitude
              : (p.longitude < minLon ? p.longitude : minLon);
      maxLon =
          (maxLon == null)
              ? p.longitude
              : (p.longitude > maxLon ? p.longitude : maxLon);
    }
    return gmaps.LatLngBounds(
      southwest: gmaps.LatLng(minLat!, minLon!),
      northeast: gmaps.LatLng(maxLat!, maxLon!),
    );
  }

  Future<void> _fit() async {
    final c = _controller;
    if (c == null) return;
    final pts = <latlng.LatLng>[...widget.routePts, ...widget.waypointPts];
    if (pts.isEmpty) return;
    if (pts.length == 1) {
      await c.moveCamera(
        gmaps.CameraUpdate.newLatLngZoom(
          gmaps.LatLng(pts.first.latitude, pts.first.longitude),
          12,
        ),
      );
      return;
    }
    await c.moveCamera(
      gmaps.CameraUpdate.newLatLngBounds(_boundsFromPoints(pts), 48),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pts = <latlng.LatLng>[...widget.routePts, ...widget.waypointPts];
    if (pts.isEmpty) {
      return const SizedBox.shrink();
    }

    final markers = <gmaps.Marker>{
      for (final e in widget.waypointPts.asMap().entries)
        gmaps.Marker(
          markerId: gmaps.MarkerId('p_${e.key}'),
          position: gmaps.LatLng(e.value.latitude, e.value.longitude),
          icon: gmaps.BitmapDescriptor.defaultMarkerWithHue(
            gmaps.BitmapDescriptor.hueAzure,
          ),
          infoWindow: gmaps.InfoWindow(title: 'Stop ${e.key + 1}'),
        ),
    };
    final polylines =
        widget.routePts.length > 1
            ? <gmaps.Polyline>{
              gmaps.Polyline(
                polylineId: const gmaps.PolylineId('preview_outline'),
                points:
                    widget.routePts
                        .map((p) => gmaps.LatLng(p.latitude, p.longitude))
                        .toList(),
                width: 5,
                color: Colors.white.withValues(alpha: 0.7),
              ),
              gmaps.Polyline(
                polylineId: const gmaps.PolylineId('preview'),
                points:
                    widget.routePts
                        .map((p) => gmaps.LatLng(p.latitude, p.longitude))
                        .toList(),
                width: 3,
                color: widget.routeColor.withValues(alpha: 0.9),
              ),
            }
            : const <gmaps.Polyline>{};

    return gmaps.GoogleMap(
      initialCameraPosition: gmaps.CameraPosition(
        target: gmaps.LatLng(pts.first.latitude, pts.first.longitude),
        zoom: 3,
      ),
      onMapCreated: (c) {
        _controller = c;
        _fit();
      },
      markers: markers,
      polylines: polylines,
      zoomControlsEnabled: false,
      zoomGesturesEnabled: false,
      scrollGesturesEnabled: false,
      rotateGesturesEnabled: false,
      tiltGesturesEnabled: false,
      compassEnabled: false,
      mapToolbarEnabled: false,
      myLocationButtonEnabled: false,
    );
  }
}
