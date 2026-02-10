// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'package:flutter/foundation.dart' show kDebugMode, listEquals;
import 'package:flutter/material.dart';
import 'package:trypr/utils/platform_view_registry.dart';

/// Web implementation – renders the Earth 3D globe inside an iframe and
/// communicates via postMessage.
class Globe3DEmbed extends StatefulWidget {
  /// Waypoints to display & route between.
  /// Each map should contain `lat`, `lon` (or `lng`), and optionally `name`.
  final List<Map<String, dynamic>> points;

  /// Called when the user taps the 3D globe surface.
  final void Function(double lat, double lon)? onMapTap;

  /// Called after routing completes with distance (m) and duration (s).
  final void Function(double distanceMeters, double durationSeconds)?
  onRouteSummary;

  /// Transport mode forwarded to the globe's Directions request.
  final String transportMode;

  const Globe3DEmbed({
    super.key,
    this.points = const [],
    this.onMapTap,
    this.onRouteSummary,
    this.transportMode = 'DRIVING',
  });

  @override
  State<Globe3DEmbed> createState() => _Globe3DEmbedState();
}

class _Globe3DEmbedState extends State<Globe3DEmbed> {
  static int _counter = 0;
  late final String _viewType;
  late final html.IFrameElement _iframe;
  bool _ready = false;

  // Store the listener so we can cleanly remove it.
  late final html.EventListener _msgListener;

  @override
  void initState() {
    super.initState();
    _counter++;
    _viewType = 'globe-3d-embed-$_counter';

    final earthUrl =
        kDebugMode
            ? 'http://localhost:6767/earth/?embed=true'
            : 'earth/index.html?embed=true';
    _iframe =
        html.IFrameElement()
          ..src = earthUrl
          ..style.border = '0'
          ..style.width = '100%'
          ..style.height = '100%'
          ..style.display = 'block'
          ..allow = 'fullscreen';

    _iframe.onLoad.listen((_) {
      // iframe HTML loaded — but the 3D globe may not be initialized yet.
      // Wait for the 'map_ready' postMessage before sending points.
    });

    _msgListener = (html.Event e) {
      if (e is html.MessageEvent) _handleMessage(e);
    };
    html.window.addEventListener('message', _msgListener);

    registerHtmlElementViewFactory(_viewType, (int viewId) => _iframe);
  }

  void _handleMessage(html.MessageEvent event) {
    // Only process messages from *our* iframe.
    if (event.source != _iframe.contentWindow) return;

    final data = event.data;
    if (data is! Map) return;

    switch (data['type']) {
      case 'mapTap':
        widget.onMapTap?.call(
          (data['lat'] as num).toDouble(),
          (data['lng'] as num).toDouble(),
        );
        break;

      case 'routeSummary':
        widget.onRouteSummary?.call(
          (data['distanceMeters'] as num).toDouble(),
          (data['durationSeconds'] as num).toDouble(),
        );
        break;

      case 'map_ready':
        _ready = true;
        _sendPoints();
        break;
    }
  }

  @override
  void dispose() {
    html.window.removeEventListener('message', _msgListener);
    super.dispose();
  }

  @override
  void didUpdateWidget(Globe3DEmbed old) {
    super.didUpdateWidget(old);
    // Use deep equality so rebuilds with identical content don't re-trigger
    // the expensive postMessage → Directions API round-trip.
    final pointsChanged = !_pointsEqual(old.points, widget.points);
    if (pointsChanged || old.transportMode != widget.transportMode) {
      _sendPoints();
    }
  }

  /// Deep-compare two point lists by value (lat, lon, name).
  static bool _pointsEqual(
    List<Map<String, dynamic>> a,
    List<Map<String, dynamic>> b,
  ) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i]['lat'] != b[i]['lat'] ||
          a[i]['lon'] != b[i]['lon'] ||
          a[i]['name'] != b[i]['name']) {
        return false;
      }
    }
    return true;
  }

  void _sendPoints() {
    if (!_ready || _iframe.contentWindow == null) {
      if (kDebugMode) {
        print(
          'Globe3DEmbed._sendPoints: skipped (ready=$_ready, '
          'contentWindow=${_iframe.contentWindow != null})',
        );
      }
      return;
    }

    if (widget.points.isEmpty) {
      if (kDebugMode) print('Globe3DEmbed._sendPoints: clearRoute (0 points)');
      _iframe.contentWindow!.postMessage({'type': 'clearRoute'}, '*');
      return;
    }

    if (kDebugMode) {
      print('Globe3DEmbed._sendPoints: sending ${widget.points.length} points');
      for (final p in widget.points) {
        print('  → lat=${p['lat']}, lon=${p['lon']}, name=${p['name']}');
      }
    }

    _iframe.contentWindow!.postMessage({
      'type': 'setPoints',
      'points': widget.points,
      'transportMode': widget.transportMode,
    }, '*');
  }

  @override
  Widget build(BuildContext context) {
    return HtmlElementView(viewType: _viewType);
  }
}
