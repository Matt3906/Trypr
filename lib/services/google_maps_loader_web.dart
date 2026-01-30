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

Future<void> ensureGoogleMapsLoaded() {
  final apiKey = _resolveMapsKey();
  if (apiKey.isEmpty) {
    // Allow app to run without Maps configured.
    return Future.value();
  }

  if (_isMapsLoaded()) {
    return Future.value();
  }

  if (_loadCompleter != null) {
    return _loadCompleter!.future;
  }

  _loadCompleter = Completer<void>();

  html.ScriptElement? script =
      html.document.getElementById('google-maps-js') as html.ScriptElement?;

  // If a maps script already exists (e.g., injected by index.html), reuse it.
  script ??=
      html.document.querySelector(
            'script[src*="maps.googleapis.com/maps/api/js"]',
          )
          as html.ScriptElement?;

  if (script == null) {
    script =
        html.ScriptElement()
          ..id = 'google-maps-js'
          ..async = true
          ..defer = true
          ..src =
              'https://maps.googleapis.com/maps/api/js?key=$apiKey&libraries=places,maps3d&v=alpha&loading=async';
    html.document.head?.append(script);
  } else {
    // Ensure our loader can find this element later.
    script.id = 'google-maps-js';
  }

  void completeIfLoaded() {
    if (_isMapsLoaded() && !(_loadCompleter?.isCompleted ?? true)) {
      _loadCompleter?.complete();
    }
  }

  script.onError.first.then((_) {
    if (!(_loadCompleter?.isCompleted ?? true)) {
      _loadCompleter?.completeError(
        StateError('Failed to load Google Maps JavaScript API'),
      );
    }
  });

  script.onLoad.first.then((_) {
    completeIfLoaded();
  });

  // Poll until the JS API is available in case the script element pre-existed.
  final pollTimer = Timer.periodic(const Duration(milliseconds: 150), (timer) {
    completeIfLoaded();
    if (_loadCompleter?.isCompleted ?? true) {
      timer.cancel();
    }
  });

  return _loadCompleter!.future.timeout(
    const Duration(seconds: 20),
    onTimeout: () {
      pollTimer.cancel();
      throw TimeoutException('Timed out loading Google Maps JavaScript API');
    },
  );
}
