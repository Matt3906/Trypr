import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'screens/home_screen.dart';
import 'screens/sign_in_screen.dart';
import 'screens/create_account_screen.dart';
import 'screens/account_screen.dart';
import 'screens/friends_screen.dart';
import 'screens/my_trips_screen.dart';
import 'screens/trip_builder_screen.dart';
import 'services/auth_state.dart';
import 'services/google_maps_loader.dart';
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.web);
  } else {
    await Firebase.initializeApp();
  }

  // Web-only: load Google Maps JS once (key provided via --dart-define).
  // If not provided, the app still runs, but map widgets will show a hint.
  if (kIsWeb) {
    try {
      await ensureGoogleMapsLoaded();
    } catch (e) {
      if (kDebugMode) {
        // ignore: avoid_print
        print('Google Maps JS failed to load: $e');
      }
    }
  }

  // App Check helps protect Firebase resources from abuse.
  // For web you must provide a reCAPTCHA site key at build time.
  // Example: flutter run -d chrome --dart-define=RECAPTCHA_SITE_KEY=YOUR_KEY
  await _initAppCheck();

  // Attach auth listener so AuthState keeps in sync with FirebaseAuth
  AuthState.instance.attachFirebaseListener();
  runApp(const MyApp());
}

Future<void> _initAppCheck() async {
  if (!kIsWeb) {
    // This workspace is primarily using web FirebaseOptions. Avoid turning on
    // App Check for other platforms here unless you’ve configured them.
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
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Trypr',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color.fromARGB(255, 0, 71, 27),
        ),
        scaffoldBackgroundColor: Colors.grey.shade100,
        useMaterial3: true,
      ),
      routes: {
        '/sign-in': (_) => const SignInScreen(),
        '/create-account': (_) => const CreateAccountScreen(),
        '/account': (_) => const AccountScreen(),
        '/friends': (_) => const FriendsScreen(),
        '/my-trips': (_) => const MyTripsScreen(),
        '/trip-builder': (_) => const TripBuilderScreen(),
      },
      builder: (context, child) {
        // Force a full navigator rebuild when auth changes so the UI updates
        // immediately after login/logout and stale screens are cleared.
        return StreamBuilder<User?>(
          stream: FirebaseAuth.instance.authStateChanges(),
          builder: (ctx, snap) {
            final key = ValueKey<String>(snap.data?.uid ?? 'signed-out');
            return KeyedSubtree(
              key: key,
              child: child ?? const SizedBox.shrink(),
            );
          },
        );
      },
      home: const HomeScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
