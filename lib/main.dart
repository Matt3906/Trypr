import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:trypr/theme/app_theme.dart';
import 'screens/app_home_mobile.dart'
    if (dart.library.html) 'screens/app_home_web.dart';
import 'screens/sign_in_screen.dart';
import 'screens/create_account_screen.dart';
import 'screens/account_screen_mobile.dart'
    if (dart.library.html) 'screens/account_screen.dart';
import 'screens/friends_screen.dart';
import 'screens/my_trips_screen.dart';
import 'screens/trip_builder_screen.dart';
import 'screens/trip_link_screen.dart';
import 'screens/unlisted_page_screen.dart';
import 'screens/premium_screen.dart';
import 'services/auth_state.dart';
import 'services/google_maps_loader.dart';
import 'firebase_options.dart';

/// The original browser URL captured before Flutter's router can modify it.
/// This preserves query parameters (e.g. ?joinTrip=...) and path segments
/// (e.g. /page/slug) that Flutter may strip when setting up its initial route.
Uri? _initialUri;
String? _startupErrorMessage;
bool _firebaseReady = false;
bool _firebaseEmulatorsConfigured = false;

const _localFirebaseHost = '127.0.0.1';
const _functionsRegion = String.fromEnvironment(
  'FIREBASE_FUNCTIONS_REGION',
  defaultValue: 'us-central1',
);
const _useFirebaseEmulators = bool.fromEnvironment(
  'USE_FIREBASE_EMULATORS',
  defaultValue: false,
);

class _TripRouteTarget {
  final String ownerUid;
  final String tripId;

  const _TripRouteTarget({required this.ownerUid, required this.tripId});
}

class _PageRouteTarget {
  final String slug;

  const _PageRouteTarget(this.slug);
}

Future<void> main() async {
  final startupWatch = Stopwatch()..start();
  // Use path-based URLs (trypr.co/trip/abc) instead of hash URLs (trypr.co/#/trip/abc)
  if (kIsWeb) {
    usePathUrlStrategy();
  }

  // Capture the full URL immediately, before Flutter's router can replace it
  // via history.replaceState and strip the query parameters.
  if (kIsWeb) {
    _initialUri = Uri.base;
  }
  WidgetsFlutterBinding.ensureInitialized();
  try {
    if (kIsWeb) {
      await Firebase.initializeApp(options: DefaultFirebaseOptions.web);
    } else {
      await Firebase.initializeApp();
    }
    await _configureFirebaseEmulatorsIfNeeded();
    _firebaseReady = true;

    // Attach auth listener so AuthState keeps in sync with FirebaseAuth
    AuthState.instance.attachFirebaseListener();

    // Run the UI as soon as Firebase is ready. Expensive web-only setup runs
    // in the background to avoid blocking first paint.
    if (kIsWeb) {
      _warmupWebServices();
    }
  } catch (e, st) {
    _firebaseReady = false;
    _startupErrorMessage = _firebaseSetupHint(e);
    if (kDebugMode) {
      // ignore: avoid_print
      print('Startup Firebase initialization failed: $e');
      // ignore: avoid_print
      print(st);
    }
  }

  if (kDebugMode) {
    // ignore: avoid_print
    print('Startup: runApp after ${startupWatch.elapsedMilliseconds}ms');
  }
  runApp(
    MyApp(
      firebaseReady: _firebaseReady,
      startupErrorMessage: _startupErrorMessage,
    ),
  );
}

bool _shouldUseFirebaseEmulators() {
  if (!kIsWeb || !_useFirebaseEmulators) return false;

  final host = Uri.base.host.trim().toLowerCase();
  return host == 'localhost' || host == '127.0.0.1' || host == '::1';
}

Future<void> _configureFirebaseEmulatorsIfNeeded() async {
  if (!_shouldUseFirebaseEmulators() || _firebaseEmulatorsConfigured) {
    return;
  }

  await FirebaseAuth.instance.useAuthEmulator(_localFirebaseHost, 9099);
  FirebaseFirestore.instance.useFirestoreEmulator(_localFirebaseHost, 8080);
  await FirebaseStorage.instance.useStorageEmulator(_localFirebaseHost, 9199);

  FirebaseFunctions.instance.useFunctionsEmulator(_localFirebaseHost, 5001);
  FirebaseFunctions.instanceFor(
    region: _functionsRegion,
  ).useFunctionsEmulator(_localFirebaseHost, 5001);

  _firebaseEmulatorsConfigured = true;

  if (kDebugMode) {
    // ignore: avoid_print
    print(
      'Firebase emulators enabled for localhost '
      '(auth=9099, firestore=8080, storage=9199, functions=5001)',
    );
  }
}

String _firebaseSetupHint(Object error) {
  final text = error.toString().toLowerCase();
  final missingIosConfig =
      text.contains('google-service-info.plist') ||
      text.contains('[core/not-initialized]') ||
      text.contains('no app has been configured yet');

  if (!kIsWeb && missingIosConfig) {
    return 'Firebase is not configured for iOS.\n\n'
        'Add `ios/Runner/GoogleService-Info.plist` from Firebase Console '
        '(Project Settings > Your apps > iOS app), then run:\n'
        '`flutter clean`\n'
        '`flutter pub get`\n'
        '`flutter run -d ios`';
  }

  return 'Startup failed while initializing Firebase:\n$error';
}

void _warmupWebServices() {
  // Fire-and-forget App Check activation (if a site key is configured).
  _initAppCheck();

  // Fire-and-forget Maps JS warm-up. Map widgets also lazy-load on demand.
  ensureGoogleMapsLoaded().catchError((e) {
    if (kDebugMode) {
      // ignore: avoid_print
      print('Google Maps JS warm-up failed: $e');
    }
  });
}

Future<void> _initAppCheck() async {
  if (!kIsWeb) {
    // This workspace is primarily using web FirebaseOptions. Avoid turning on
    // App Check for other platforms here unless you’ve configured them.
    return;
  }

  if (_shouldUseFirebaseEmulators()) {
    if (kDebugMode) {
      // ignore: avoid_print
      print('AppCheck: skipped while using local Firebase emulators');
    }
    return;
  }

  const siteKey = String.fromEnvironment('RECAPTCHA_SITE_KEY');
  if (siteKey.isEmpty) {
    if (kDebugMode) {
      // In debug, allow the app to run without App Check configured.
      // (When you enable enforcement in Firebase Console, you MUST provide
      // a site key, or things will start failing.)
      // ignore: avoid_print
      print('AppCheck: RECAPTCHA_SITE_KEY not provided; skipping activation');
    }
    return;
  }

  try {
    await FirebaseAppCheck.instance.activate(
      providerWeb: ReCaptchaV3Provider(siteKey),
    );
  } catch (e) {
    if (kDebugMode) {
      // ignore: avoid_print
      print('AppCheck activation failed: $e');
    }
  }
}

class MyApp extends StatelessWidget {
  final bool firebaseReady;
  final String? startupErrorMessage;

  const MyApp({
    super.key,
    required this.firebaseReady,
    this.startupErrorMessage,
  });

  /// Returns the URL and a hash-fragment URL candidate (for legacy `/#/trip/...` links).
  List<Uri> _deepLinkCandidates(Uri uri) {
    final out = <Uri>[uri];
    final fragment = uri.fragment.trim();
    if (fragment.isEmpty) return out;

    final hashPath = fragment.startsWith('/') ? fragment : '/$fragment';
    final hashUri = Uri.tryParse(hashPath);
    if (hashUri != null) out.add(hashUri);
    return out;
  }

  List<String> _normalizedSegments(Uri uri) {
    return uri.pathSegments
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
  }

  _TripRouteTarget? _parseTripRouteFromUri(Uri uri) {
    for (final candidate in _deepLinkCandidates(uri)) {
      final segs = _normalizedSegments(candidate);
      if (segs.length < 3 || segs[0] != 'trip') continue;

      final ownerUid = segs[1];
      final tripId = segs[2];
      if (ownerUid.isEmpty || tripId.isEmpty) continue;
      return _TripRouteTarget(ownerUid: ownerUid, tripId: tripId);
    }
    return null;
  }

  _PageRouteTarget? _parsePageRouteFromUri(Uri uri) {
    for (final candidate in _deepLinkCandidates(uri)) {
      final segs = _normalizedSegments(candidate);
      if (segs.length < 2 || segs[0] != 'page') continue;

      final slug = segs[1];
      if (slug.isEmpty) continue;
      return _PageRouteTarget(slug);
    }
    return null;
  }

  bool _isPremiumRouteFromUri(Uri uri) {
    for (final candidate in _deepLinkCandidates(uri)) {
      final segs = _normalizedSegments(candidate);
      if (segs.isEmpty) continue;
      if (segs[0] == 'premium') return true;
    }
    return false;
  }

  _TripRouteTarget? _parseTripRouteFromName(String? name) {
    if (name == null || name.trim().isEmpty) return null;
    final uri = Uri.tryParse(name.trim());
    if (uri == null) return null;
    return _parseTripRouteFromUri(uri);
  }

  _PageRouteTarget? _parsePageRouteFromName(String? name) {
    if (name == null || name.trim().isEmpty) return null;
    final uri = Uri.tryParse(name.trim());
    if (uri == null) return null;
    return _parsePageRouteFromUri(uri);
  }

  bool _isPremiumRouteFromName(String? name) {
    if (name == null || name.trim().isEmpty) return false;
    final uri = Uri.tryParse(name.trim());
    if (uri == null) return false;
    return _isPremiumRouteFromUri(uri);
  }

  /// Compute the initial route from the browser URL so that deep links
  /// (e.g. /trip/abc/xyz, /page/slug, ?joinTrip=...) go straight through
  /// onGenerateRoute instead of being silently swallowed by `home:`.
  String _computeInitialRoute() {
    if (!kIsWeb) return '/';
    final uri = _initialUri ?? Uri.base;

    // /trip/:ownerUid/:tripId (accepts trailing slash and hash-style links)
    final tripTarget = _parseTripRouteFromUri(uri);
    if (tripTarget != null) {
      return '/trip/${tripTarget.ownerUid}/${tripTarget.tripId}';
    }

    // /page/:slug (accepts trailing slash and hash-style links)
    final pageTarget = _parsePageRouteFromUri(uri);
    if (pageTarget != null) {
      return '/page/${pageTarget.slug}';
    }

    if (_isPremiumRouteFromUri(uri)) {
      return '/premium';
    }

    // Legacy ?joinTrip=users/{uid}/trips/{id}
    final joinTrip = uri.queryParameters['joinTrip'];
    if (joinTrip != null && joinTrip.trim().isNotEmpty) {
      final parsed = _parseTripRef(joinTrip.trim());
      if (parsed != null) {
        return '/trip/${parsed['ownerUid']}/${parsed['tripId']}';
      }
    }

    return '/';
  }

  static Map<String, String>? _parseTripRef(String tripRef) {
    final parts = tripRef.split('/');
    if (parts.length != 4) return null;
    if (parts[0] != 'users' || parts[2] != 'trips') return null;
    if (parts[1].trim().isEmpty || parts[3].trim().isEmpty) return null;
    return {'ownerUid': parts[1], 'tripId': parts[3]};
  }

  @override
  Widget build(BuildContext context) {
    if (!firebaseReady) {
      return MaterialApp(
        title: 'Trypr',
        theme: TryprTheme.lightTheme,
        localizationsDelegates:
            FlutterQuillLocalizations.localizationsDelegates,
        supportedLocales: FlutterQuillLocalizations.supportedLocales,
        debugShowCheckedModeBanner: false,
        home: _StartupErrorScreen(message: startupErrorMessage),
      );
    }

    final initialRoute = _computeInitialRoute();
    final useDeepLink = initialRoute != '/';

    return MaterialApp(
      title: 'Trypr',
      theme: TryprTheme.lightTheme,
      localizationsDelegates: FlutterQuillLocalizations.localizationsDelegates,
      supportedLocales: FlutterQuillLocalizations.supportedLocales,
      initialRoute: useDeepLink ? initialRoute : null,
      // Override the default behaviour that splits '/trip/abc/xyz' into
      // sub-paths (/trip, /trip/abc, /trip/abc/xyz) and tries to resolve
      // each one — the intermediate paths don't exist and cause a blank
      // screen. Instead, just push the single deep-link route directly.
      onGenerateInitialRoutes:
          useDeepLink
              ? (String route) {
                final tripTarget = _parseTripRouteFromName(route);
                if (tripTarget != null) {
                  return [
                    MaterialPageRoute(
                      builder:
                          (_) => TripLinkScreen(
                            ownerUid: tripTarget.ownerUid,
                            tripId: tripTarget.tripId,
                          ),
                      settings: RouteSettings(name: route),
                    ),
                  ];
                }
                final pageTarget = _parsePageRouteFromName(route);
                if (pageTarget != null) {
                  return [
                    MaterialPageRoute(
                      builder:
                          (_) => UnlistedPageScreen(pageSlug: pageTarget.slug),
                      settings: RouteSettings(name: route),
                    ),
                  ];
                }
                if (_isPremiumRouteFromName(route)) {
                  return [
                    MaterialPageRoute(
                      builder: (_) => const PremiumScreen(),
                      settings: RouteSettings(name: route),
                    ),
                  ];
                }
                // Fallback — shouldn't happen, but land on home if it does
                return [
                  MaterialPageRoute(builder: (_) => const AppHomeScreen()),
                ];
              }
              : null,
      routes: {
        '/sign-in': (_) => const SignInScreen(),
        '/create-account': (_) => const CreateAccountScreen(),
        '/account': (_) => const AccountScreen(),
        '/friends': (_) => const FriendsScreen(),
        '/my-trips': (_) => const MyTripsScreen(),
        '/trip-builder': (_) => const TripBuilderScreen(),
        '/premium': (_) => const PremiumScreen(),
      },
      onGenerateRoute: (settings) {
        // Handle /trip/:ownerUid/:tripId routes for shared trip links
        final tripTarget = _parseTripRouteFromName(settings.name);
        if (tripTarget != null) {
          return MaterialPageRoute(
            builder:
                (_) => TripLinkScreen(
                  ownerUid: tripTarget.ownerUid,
                  tripId: tripTarget.tripId,
                ),
            settings: settings,
          );
        }

        // Handle /page/:slug routes for unlisted pages
        final pageTarget = _parsePageRouteFromName(settings.name);
        if (pageTarget != null) {
          return MaterialPageRoute(
            builder: (_) => UnlistedPageScreen(pageSlug: pageTarget.slug),
            settings: settings,
          );
        }
        if (_isPremiumRouteFromName(settings.name)) {
          return MaterialPageRoute(
            builder: (_) => const PremiumScreen(),
            settings: settings,
          );
        }
        return null;
      },
      onUnknownRoute:
          (_) => MaterialPageRoute(builder: (_) => const AppHomeScreen()),
      builder: (context, child) {
        // Always render a concrete screen to avoid blank white output if a
        // malformed external URL slips through route generation.
        return child ?? const AppHomeScreen();
      },
      home: useDeepLink ? null : const AppHomeScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class _StartupErrorScreen extends StatelessWidget {
  final String? message;

  const _StartupErrorScreen({this.message});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6F8),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Card(
              margin: const EdgeInsets.all(24),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.error_outline, color: Colors.redAccent),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'App Startup Error',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SelectableText(
                      message ??
                          'Unable to initialize app services. Check console logs for details.',
                      style: const TextStyle(height: 1.35),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
