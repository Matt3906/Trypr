import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import 'package:latlong2/latlong.dart' as latlng;

class MapPreview extends StatelessWidget {
  final List<dynamic> waypoints;
  const MapPreview({super.key, required this.waypoints});

  static const _mapsKey = String.fromEnvironment('GOOGLE_MAPS_API_KEY');

  List<latlng.LatLng> _toLatLngs() {
    final pts = <latlng.LatLng>[];
    for (final w in waypoints) {
      try {
        if (w is Map) {
          final lat = (w['lat'] ?? w['latitude']) as num?;
          final lon =
              (w['lon'] ?? w['longitude'] ?? w['lng'] ?? w['lng']) as num?;
          if (lat != null && lon != null) {
            pts.add(latlng.LatLng(lat.toDouble(), lon.toDouble()));
          }
        }
      } catch (_) {
        // skip malformed
      }
    }
    return pts;
  }

  @override
  Widget build(BuildContext context) {
    final pts = _toLatLngs();
    if (pts.isEmpty) {
      return Container(
        color: Colors.grey.shade200,
        child: const Center(
          child: Icon(Icons.map, size: 36, color: Colors.black26),
        ),
      );
    }

    if (kIsWeb) {
      if (_mapsKey.isEmpty) {
        return Container(
          color: Colors.grey.shade200,
          alignment: Alignment.center,
          padding: const EdgeInsets.all(12),
          child: const Text(
            'Google Maps is not configured. Build with '
            '--dart-define=GOOGLE_MAPS_API_KEY=YOUR_KEY',
            textAlign: TextAlign.center,
          ),
        );
      }
      return _MapPreviewWeb(pts: pts);
    }

    final bounds = LatLngBounds.fromPoints(pts);

    return FlutterMap(
      options: MapOptions(
        bounds: bounds,
        boundsOptions: FitBoundsOptions(
          padding: const EdgeInsets.all(24),
          maxZoom: pts.length <= 1 ? 12 : 10,
        ),
        // Allow panning/zooming on the card preview so users can move the map.
        interactiveFlags: InteractiveFlag.all,
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
          subdomains: const ['a', 'b', 'c'],
          userAgentPackageName: 'com.example.trypr',
        ),
        if (pts.length > 1)
          PolylineLayer(
            polylines: [
              Polyline(
                points: pts,
                color: Colors.blue.withOpacity(0.8),
                strokeWidth: 3.0,
              ),
            ],
          ),
        MarkerLayer(
          markers:
              pts.asMap().entries.map((e) {
                final idx = e.key;
                final p = e.value;
                return Marker(
                  point: p,
                  width: 28,
                  height: 28,
                  builder:
                      (ctx) => Container(
                        decoration: BoxDecoration(
                          color: Colors.blue,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          '${idx + 1}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                );
              }).toList(),
        ),
      ],
    );
  }
}

class _MapPreviewWeb extends StatefulWidget {
  final List<latlng.LatLng> pts;
  const _MapPreviewWeb({required this.pts});

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
    final pts = widget.pts;
    if (pts.isEmpty) return;
    if (pts.length == 1) {
      await c.moveCamera(
        gmaps.CameraUpdate.newLatLngZoom(
          gmaps.LatLng(pts[0].latitude, pts[0].longitude),
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
    final pts = widget.pts;
    final markers = <gmaps.Marker>{
      for (final e in pts.asMap().entries)
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
        pts.length > 1
            ? <gmaps.Polyline>{
              gmaps.Polyline(
                polylineId: const gmaps.PolylineId('preview'),
                points:
                    pts
                        .map((p) => gmaps.LatLng(p.latitude, p.longitude))
                        .toList(),
                width: 3,
                color: Colors.blue.withOpacity(0.8),
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
      mapToolbarEnabled: false,
      myLocationButtonEnabled: false,
    );
  }
}
