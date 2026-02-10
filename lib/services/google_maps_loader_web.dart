import 'dart:async';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

Completer<void>? _loadCompleter;

String _resolveMapsKey() {
  const fromDefine = String.fromEnvironment('GOOGLE_MAPS_API_KEY');
  if (fromDefine.isNotEmpty) return fromDefine;

  try {
    final meta = html.document.querySelector(
      'meta[name="google-maps-api-key"]',
    );
    final fromMeta = meta?.getAttribute('content')?.trim() ?? '';
    return fromMeta;
  } catch (_) {
    return '';
  }
}

bool _isMapsLoaded() {
  try {
    // ignore: avoid_dynamic_calls
    return (html.window as dynamic).google?.maps != null;
  } catch (_) {
    return false;
  }
}

/// Dynamically loads the Google Maps JavaScript SDK into the page.
///
/// The `google_maps_flutter_web` plugin requires `google.maps` on `window`
/// before any [GoogleMap] widget can render.  This function injects an
/// appropriate `<script>` tag (if not already present) and waits for the SDK
/// to become available.  It resolves the API key from `--dart-define` first,
/// then falls back to the `<meta name="google-maps-api-key">` tag.
Future<void> ensureGoogleMapsLoaded() {
  if (_isMapsLoaded()) return Future.value();
  if (_loadCompleter != null) return _loadCompleter!.future;

  _loadCompleter = Completer<void>();

  final key = _resolveMapsKey();
  if (key.isEmpty) {
    // No key – nothing to load; widgets will show a "not configured" message.
    _loadCompleter!.complete();
    return _loadCompleter!.future;
  }

  // Check if a script tag for Maps JS is already in the DOM.
  final existing = html.document.querySelectorAll(
    'script[src*="maps.googleapis.com"]',
  );
  if (existing.isNotEmpty) {
    // Script tag exists – just wait for it to finish loading.
    _pollForMaps();
    return _loadCompleter!.future;
  }

  final script =
      html.ScriptElement()
        ..src =
            'https://maps.googleapis.com/maps/api/js?key=$key&libraries=places'
        ..async = true;

  script.onLoad.listen((_) {
    _pollForMaps();
  });

  script.onError.listen((_) {
    if (!_loadCompleter!.isCompleted) {
      _loadCompleter!.complete(); // Complete anyway to unblock the UI.
    }
  });

  html.document.head!.append(script);
  return _loadCompleter!.future;
}

/// The script's `onLoad` fires when the file is fetched, but `google.maps`
/// may not be defined immediately.  Poll briefly to be safe.
void _pollForMaps([int attempts = 0]) {
  if (_isMapsLoaded()) {
    if (!_loadCompleter!.isCompleted) _loadCompleter!.complete();
    return;
  }
  if (attempts > 50) {
    // Give up after ~5 s.
    if (!_loadCompleter!.isCompleted) _loadCompleter!.complete();
    return;
  }
  Future.delayed(
    const Duration(milliseconds: 100),
    () => _pollForMaps(attempts + 1),
  );
}
