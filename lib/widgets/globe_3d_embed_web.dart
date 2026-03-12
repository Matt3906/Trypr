// ignore: avoid_web_libraries_in_flutter
import 'dart:async';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:js_interop';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:trypr/utils/platform_view_registry.dart';
import 'package:trypr/widgets/earth_srcdoc.dart';

/// Web implementation – renders the Earth 3D globe inside an iframe and
/// communicates via postMessage.
class Globe3DEmbed extends StatefulWidget {
  /// Waypoints to display & route between.
  /// Each map should contain `lat`, `lon` (or `lng`), and optionally `name`.
  final List<Map<String, dynamic>> points;

  /// Extra points shown as non-route markers (e.g. activity pins).
  final List<Map<String, dynamic>> secondaryPoints;

  /// Optional precomputed route geometry from the 2D map routing engine.
  /// When provided, the globe should render this exact line instead of
  /// recomputing with its own directions request.
  final List<Map<String, dynamic>> routeGeometry;

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
    this.secondaryPoints = const [],
    this.routeGeometry = const [],
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
  int _retryCount = 0;
  int _earthPathIndex = 0;
  bool _attemptedSrcdocFallback = false;
  static const int _maxRetries = 2;

  // Store the listener so we can cleanly remove it.
  late final html.EventListener _msgListener;

  Timer? _readyTimeout;

  String _postTargetOrigin() {
    try {
      final origin = Uri.base.origin;
      if (origin.isNotEmpty && origin != 'null') return origin;
    } catch (_) {}
    return '*';
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
    _counter++;
    _viewType = 'globe-3d-embed-$_counter';

    final mapsKey = _resolvedMapsKey();
    final earthSrc = _earthAssetUrl(
      mapsKey: mapsKey,
      pathIndex: _earthPathIndex,
    );

    _iframe =
        html.IFrameElement()
          ..src = earthSrc
          ..style.border = '0'
          ..style.width = '100%'
          ..style.height = '100%'
          ..style.display = 'block'
          ..allow = 'fullscreen';

    _iframe.onLoad.listen((_) {
      // iframe HTML loaded — but the 3D globe may not be initialized yet.
      // Wait for the 'map_ready' postMessage before sending points.
      // Start a timeout: if map_ready is not received within 10 seconds,
      // attempt a retry or force-ready.
      _scheduleReadyTimeout();
    });

    _msgListener = (html.Event e) {
      if (e is html.MessageEvent) _handleMessage(e);
    };
    html.window.addEventListener('message', _msgListener);

    registerHtmlElementViewFactory(_viewType, (int viewId) => _iframe);
  }

  /// Schedule a timeout that fires if `map_ready` has not arrived.
  void _scheduleReadyTimeout() {
    _readyTimeout?.cancel();
    _readyTimeout = Timer(const Duration(seconds: 10), () {
      if (_ready || !mounted) return;
      if (_retryCount < _maxRetries) {
        _retryCount++;
        if (kDebugMode) {
          print(
            'Globe3DEmbed: map_ready not received after 10 s – '
            'reloading iframe (retry $_retryCount/$_maxRetries)',
          );
        }
        // Reload the iframe by re-setting the src with a fresh cache-bust.
        if (_retryCount == 1) {
          _earthPathIndex = 1;
        }
        final mapsKey = _resolvedMapsKey();
        _iframe.src = _earthAssetUrl(
          mapsKey: mapsKey,
          pathIndex: _earthPathIndex,
        );
      } else {
        _trySrcdocFallbackOrForceReady();
      }
    });
  }

  static String _earthAssetUrl({required String mapsKey, int pathIndex = 0}) {
    final encodedKey = Uri.encodeQueryComponent(mapsKey);
    final cacheBust = DateTime.now().millisecondsSinceEpoch;
    const basePaths = ['/earth/index.html', '/assets/web/earth/index.html'];
    final safeIndex = pathIndex.clamp(0, basePaths.length - 1).toInt();
    final base = basePaths[safeIndex];
    // It reads embed=true (and gmapsKey) from window.location.search.
    return mapsKey.isEmpty
        ? '$base?embed=true&cb=$cacheBust'
        : '$base?embed=true&gmapsKey=$encodedKey&cb=$cacheBust';
  }

  Future<void> _trySrcdocFallbackOrForceReady() async {
    if (_attemptedSrcdocFallback) {
      if (kDebugMode) {
        print(
          'Globe3DEmbed: srcdoc fallback already attempted – forcing ready state.',
        );
      }
      _ready = true;
      if (mounted) setState(() {});
      _sendPoints();
      return;
    }

    _attemptedSrcdocFallback = true;
    try {
      if (kDebugMode) {
        print(
          'Globe3DEmbed: map_ready not received after retries – '
          'trying srcdoc fallback.',
        );
      }
      final mapsKey = _resolvedMapsKey();
      final htmlDoc = await EarthSrcdoc.build(mapsApiKey: mapsKey);
      if (!mounted) return;
      _iframe
        ..src = 'about:blank'
        ..srcdoc = htmlDoc;
      _scheduleReadyTimeout();
    } catch (e) {
      if (kDebugMode) {
        print('Globe3DEmbed: srcdoc fallback failed: $e');
        print('Globe3DEmbed: forcing ready state.');
      }
      _ready = true;
      if (mounted) setState(() {});
      _sendPoints();
    }
  }

  /// Checks whether [event.source] belongs to our iframe.
  ///
  /// The `dart:html` wrappers can return different Dart objects for the same
  /// underlying JS window reference, so a simple `==` sometimes fails.
  /// We fall back to a JS-level identity check via `dart:js_interop`.
  bool _isOurIframe(html.MessageEvent event) {
    try {
      final srcWindow = event.source;
      final iframeWindow = _iframe.contentWindow;
      if (srcWindow == null || iframeWindow == null) return false;
      // dart:html == may work for simple cases.
      if (srcWindow == iframeWindow) return true;
      // Use JS-interop identity comparison (Object.is) as a fallback.
      return _jsIdentical(srcWindow, iframeWindow);
    } catch (_) {
      // If anything fails, accept messages with the expected types
      // (there is typically only one Globe3DEmbed active at a time).
      return true;
    }
  }

  /// JS-level `Object.is()` comparison for two dart:html object references.
  static bool _jsIdentical(Object? a, Object? b) {
    try {
      final jsA = a.jsify();
      final jsB = b.jsify();
      return jsA == jsB;
    } catch (_) {
      return false;
    }
  }

  void _handleMessage(html.MessageEvent event) {
    // Only process messages from *our* iframe.
    if (!_isOurIframe(event)) return;

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
        _readyTimeout?.cancel();
        if (!_ready) {
          _ready = true;
          if (mounted) setState(() {});
          _sendPoints();
        }
        break;

      case 'debug_secondary_points':
        if (kDebugMode) {
          final stops = data['stops'];
          final secondary = data['secondary'];
          print(
            'Globe3DEmbed debug: iframe received stops=$stops secondary=$secondary',
          );
        }
        break;
    }
  }

  @override
  void dispose() {
    _readyTimeout?.cancel();
    html.window.removeEventListener('message', _msgListener);
    super.dispose();
  }

  @override
  void didUpdateWidget(Globe3DEmbed old) {
    super.didUpdateWidget(old);
    // Use deep equality so rebuilds with identical content don't re-trigger
    // the expensive postMessage → Directions API round-trip.
    final pointsChanged = !_pointsEqual(old.points, widget.points);
    final secondaryChanged =
        !_pointsEqual(old.secondaryPoints, widget.secondaryPoints);
    final routeGeometryChanged =
        !_pointsEqual(old.routeGeometry, widget.routeGeometry);
    final oldMode = _normalizeTransportMode(old.transportMode);
    final newMode = _normalizeTransportMode(widget.transportMode);
    if (pointsChanged ||
        secondaryChanged ||
        routeGeometryChanged ||
        oldMode != newMode) {
      _sendPoints();
    }
  }

  static String _normalizeTransportMode(String mode) {
    final m = mode.trim();
    if (m.isEmpty) return 'DRIVING';

    // Accept lowercase values used in Flutter UI.
    switch (m.toLowerCase()) {
      case 'drive':
      case 'driving':
        return 'DRIVING';
      case 'walk':
      case 'walking':
        return 'WALKING';
      case 'portaging':
      case 'canoe':
      case 'canoeing':
      case 'portage':
        return 'WALKING';
      case 'bike':
      case 'bicycling':
      case 'bicycle':
        return 'BICYCLING';
      case 'train':
      case 'rail':
      case 'public_transit':
      case 'public transit':
      case 'transit':
        return 'TRANSIT';
    }

    // Already an enum-like value.
    return m.toUpperCase();
  }

  /// Deep-compare two point lists by value (lat, lon, name).
  static bool _pointsEqual(
    List<Map<String, dynamic>> a,
    List<Map<String, dynamic>> b,
  ) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      final aLat = _latOf(a[i]);
      final aLon = _lonOf(a[i]);
      final bLat = _latOf(b[i]);
      final bLon = _lonOf(b[i]);
      final aName = (a[i]['name'] ?? a[i]['title'] ?? '').toString();
      final bName = (b[i]['name'] ?? b[i]['title'] ?? '').toString();
      final aKind = (a[i]['kind'] ?? '').toString();
      final bKind = (b[i]['kind'] ?? '').toString();
      final aCategory = (a[i]['category'] ?? '').toString();
      final bCategory = (b[i]['category'] ?? '').toString();

      if (aLat != bLat ||
          aLon != bLon ||
          aName != bName ||
          aKind != bKind ||
          aCategory != bCategory) {
        return false;
      }
    }
    return true;
  }

  static double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? double.nan;
    return double.nan;
  }

  static double _latOf(Map<String, dynamic> point) {
    return _toDouble(point['lat'] ?? point['latitude'] ?? point['locationLat']);
  }

  static double _lonOf(Map<String, dynamic> point) {
    return _toDouble(
      point['lon'] ??
          point['lng'] ??
          point['longitude'] ??
          point['locationLon'],
    );
  }

  static List<Map<String, dynamic>> _normalizePoints(
    List<Map<String, dynamic>> input, {
    required bool includeSecondaryMeta,
  }) {
    final out = <Map<String, dynamic>>[];
    for (final point in input) {
      final lat = _latOf(point);
      final lon = _lonOf(point);
      if (!lat.isFinite || !lon.isFinite) continue;

      final normalized = <String, dynamic>{'lat': lat, 'lon': lon, 'lng': lon};
      final name = (point['name'] ?? point['title'] ?? '').toString().trim();
      if (name.isNotEmpty) normalized['name'] = name;

      if (includeSecondaryMeta) {
        final kind = (point['kind'] ?? '').toString().trim();
        final category = (point['category'] ?? '').toString().trim();
        if (kind.isNotEmpty) normalized['kind'] = kind;
        if (category.isNotEmpty) normalized['category'] = category;
      }

      out.add(normalized);
    }
    return out;
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

    final points = _normalizePoints(widget.points, includeSecondaryMeta: false);
    final secondaryPoints = _normalizePoints(
      widget.secondaryPoints,
      includeSecondaryMeta: true,
    );
    final routeGeometry =
        points.isEmpty
            ? const <Map<String, dynamic>>[]
            : _normalizePoints(
              widget.routeGeometry,
              includeSecondaryMeta: false,
            );

    if (points.isEmpty && secondaryPoints.isEmpty && routeGeometry.isEmpty) {
      if (kDebugMode) {
        print('Globe3DEmbed._sendPoints: clearRoute (0 points, 0 secondary)');
      }
      _iframe.contentWindow!.postMessage({
        'type': 'clearRoute',
      }, _postTargetOrigin());
      return;
    }

    if (kDebugMode) {
      print(
        'Globe3DEmbed._sendPoints: sending ${points.length} points '
        'and ${secondaryPoints.length} secondary points',
      );
      for (final p in points) {
        print('  → lat=${p['lat']}, lon=${p['lon']}, name=${p['name']}');
      }
    }

    _iframe.contentWindow!.postMessage({
      'type': 'setPoints',
      'points': points,
      'secondaryPoints': secondaryPoints,
      'routeGeometry': routeGeometry,
      'transportMode': _normalizeTransportMode(widget.transportMode),
    }, _postTargetOrigin());
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        HtmlElementView(viewType: _viewType),
        // Show a subtle loading indicator until the iframe signals map_ready.
        if (!_ready)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                color: const Color(0xCC0a0a1a),
                child: const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 32,
                        height: 32,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: Colors.white54,
                        ),
                      ),
                      SizedBox(height: 12),
                      Text(
                        'Loading 3D Globe…',
                        style: TextStyle(color: Colors.white54, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
