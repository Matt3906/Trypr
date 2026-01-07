import 'dart:async';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

Completer<void>? _loadCompleter;

Future<void> ensureGoogleMapsLoaded() {
  const apiKey = String.fromEnvironment('GOOGLE_MAPS_API_KEY');
  if (apiKey.isEmpty) {
    // Allow app to run without Maps configured.
    return Future.value();
  }

  // If already loaded (or in progress), reuse the same future.
  final existing = html.document.getElementById('google-maps-js');
  if (existing != null) {
    return Future.value();
  }
  if (_loadCompleter != null) {
    return _loadCompleter!.future;
  }

  _loadCompleter = Completer<void>();

  final script =
      html.ScriptElement()
        ..id = 'google-maps-js'
        ..async = true
        ..defer = true
        ..src =
            'https://maps.googleapis.com/maps/api/js?key=$apiKey&libraries=places';

  script.onError.first.then((_) {
    if (!(_loadCompleter?.isCompleted ?? true)) {
      _loadCompleter?.completeError(
        StateError('Failed to load Google Maps JavaScript API'),
      );
    }
  });

  script.onLoad.first.then((_) {
    if (!(_loadCompleter?.isCompleted ?? true)) {
      _loadCompleter?.complete();
    }
  });

  html.document.head?.append(script);

  return _loadCompleter!.future.timeout(
    const Duration(seconds: 20),
    onTimeout: () {
      throw TimeoutException('Timed out loading Google Maps JavaScript API');
    },
  );
}
