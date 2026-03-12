// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;
import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// A 3D interactive globe widget using Google Maps 3D (Photorealistic).
///
/// The 3D map runs in an isolated `web/map.html` IFrame so that Google Maps JS
/// and the Flutter engine never fight over the same canvas context.
/// Communication happens via `postMessage`.
class GlobeWidget extends StatefulWidget {
  final List<Map<String, dynamic>> trips;
  final Map<String, dynamic>? selectedTrip;
  final void Function(Map<String, dynamic> trip)? onTripSelected;

  const GlobeWidget({
    super.key,
    required this.trips,
    this.selectedTrip,
    this.onTripSelected,
  });

  @override
  State<GlobeWidget> createState() => _GlobeWidgetState();
}

class _GlobeWidgetState extends State<GlobeWidget> {
  late String _viewId;
  html.IFrameElement? _iframe;
  bool _globeReady = false;
  StreamSubscription? _messageSub;

  String _postTargetOrigin() {
    try {
      final origin = Uri.base.origin;
      if (origin.isNotEmpty && origin != 'null') return origin;
    } catch (_) {}
    return '*';
  }

  bool _isTrustedMessage(html.MessageEvent event) {
    final expectedWindow = _iframe?.contentWindow;
    if (expectedWindow != null && event.source != expectedWindow) {
      return false;
    }

    try {
      final origin = Uri.base.origin;
      if (origin.isNotEmpty && origin != 'null' && event.origin != origin) {
        return false;
      }
    } catch (_) {}

    return true;
  }

  String _resolvedMapsKey() {
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

  @override
  void initState() {
    super.initState();
    _viewId = 'globe-view-${DateTime.now().millisecondsSinceEpoch}';
    _registerView();
  }

  void _registerView() {
    ui_web.platformViewRegistry.registerViewFactory(_viewId, (int viewId) {
      // Build the iframe pointing at the dedicated map.html file
      // (lives in web/ and gets copied to build/web/ by `flutter build web`).
      final keyParam = Uri.encodeComponent(_resolvedMapsKey());
      _iframe =
          html.IFrameElement()
            ..style.border = 'none'
            ..style.width = '100%'
            ..style.height = '100%'
            ..allow = 'accelerometer; autoplay; encrypted-media; gyroscope'
            ..src = 'map.html?key=$keyParam';

      _iframe!.onLoad.listen((_) {
        // Give the iframe's JS a moment to call initMap()
        Future.delayed(const Duration(milliseconds: 2500), () {
          if (mounted) {
            setState(() => _globeReady = true);
            _updateTrips();
            if (widget.selectedTrip != null) {
              _focusTrip(widget.selectedTrip);
            }
          }
        });
      });

      // Listen for messages from the iframe
      _messageSub = html.window.onMessage.listen((event) {
        if (!_isTrustedMessage(event)) return;
        if (event.data is Map) {
          final data = Map<String, dynamic>.from(event.data as Map);
          if (data['type'] == 'tripSelected' && data['tripId'] != null) {
            final tripId = data['tripId'].toString();
            final trip = widget.trips.firstWhere(
              (t) => t['id'] == tripId,
              orElse: () => <String, dynamic>{},
            );
            if (trip.isNotEmpty) {
              widget.onTripSelected?.call(trip);
            }
          } else if (data['type'] == 'mapReady') {
            debugPrint('Google Maps 3D is ready (via map.html)');
            if (mounted) {
              setState(() => _globeReady = true);
              _updateTrips();
              if (widget.selectedTrip != null) {
                _focusTrip(widget.selectedTrip);
              }
            }
          }
        }
      });

      return _iframe!;
    });
  }

  @override
  void didUpdateWidget(GlobeWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_globeReady) {
      if (oldWidget.selectedTrip != widget.selectedTrip) {
        _focusTrip(widget.selectedTrip);
      }
      if (oldWidget.trips != widget.trips) {
        _updateTrips();
      }
    }
  }

  void _updateTrips() {
    if (_iframe?.contentWindow == null) return;
    final sanitizedTrips = widget.trips.map(_sanitizeForJson).toList();
    final message = jsonEncode({
      'type': 'updateTrips',
      'trips': sanitizedTrips,
    });
    _iframe!.contentWindow!.postMessage(message, _postTargetOrigin());
  }

  void _focusTrip(Map<String, dynamic>? trip) {
    if (_iframe?.contentWindow == null) return;
    final sanitizedTrip = trip != null ? _sanitizeForJson(trip) : null;
    final message = jsonEncode({'type': 'focusTrip', 'trip': sanitizedTrip});
    _iframe!.contentWindow!.postMessage(message, _postTargetOrigin());
  }

  /// Recursively convert Firestore Timestamps and other non-JSON types to serializable values
  dynamic _sanitizeForJson(dynamic value) {
    if (value == null) return null;
    if (value is Timestamp) {
      return value.millisecondsSinceEpoch;
    }
    if (value is DateTime) {
      return value.millisecondsSinceEpoch;
    }
    if (value is Map) {
      return value.map((k, v) => MapEntry(k.toString(), _sanitizeForJson(v)));
    }
    if (value is List) {
      return value.map(_sanitizeForJson).toList();
    }
    // For primitives (String, int, double, bool) return as-is
    return value;
  }

  // _getGlobeHtml removed – map logic now lives in web/map.html

  @override
  Widget build(BuildContext context) {
    if (_resolvedMapsKey().isEmpty) {
      // Show fallback UI when no API key
      return Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF0a0a1a), Color(0xFF1a1a2e), Color(0xFF16213e)],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.public,
                size: 64,
                color: Colors.white.withOpacity(0.3),
              ),
              const SizedBox(height: 16),
              Text(
                '3D Globe',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.5),
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Configure GOOGLE_MAPS_API_KEY to enable',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.3),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return HtmlElementView(viewType: _viewId);
  }

  @override
  void dispose() {
    _messageSub?.cancel();
    super.dispose();
  }
}
