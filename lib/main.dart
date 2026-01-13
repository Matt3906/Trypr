import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'screens/home_screen.dart';
import 'screens/sign_in_screen.dart';
import 'screens/create_account_screen.dart';
import 'screens/account_screen.dart';
import 'screens/friends_screen.dart';
import 'screens/my_trips_screen.dart';
import 'screens/trip_builder_screen.dart';
import 'screens/trip_detail_screen.dart';
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
      home: const _JoinTripLinkHandler(child: HomeScreen()),
      debugShowCheckedModeBanner: false,
    );
  }
}

class _JoinTripLinkHandler extends StatefulWidget {
  const _JoinTripLinkHandler({required this.child});

  final Widget child;

  @override
  State<_JoinTripLinkHandler> createState() => _JoinTripLinkHandlerState();
}

class _JoinTripLinkHandlerState extends State<_JoinTripLinkHandler> {
  bool _handled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _maybeHandleJoinLink();
  }

  @override
  void didUpdateWidget(covariant _JoinTripLinkHandler oldWidget) {
    super.didUpdateWidget(oldWidget);
    _maybeHandleJoinLink();
  }

  Map<String, String>? _parseTripRef(String tripRef) {
    final parts = tripRef.split('/');
    if (parts.length != 4) return null;
    if (parts[0] != 'users' || parts[2] != 'trips') return null;
    if (parts[1].trim().isEmpty || parts[3].trim().isEmpty) return null;
    return {'ownerUid': parts[1], 'tripId': parts[3]};
  }

  void _snack(String message) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    });
  }

  Future<void> _openTripDetailFromRef(String tripRefPath) async {
    final tripDocRef = FirebaseFirestore.instance.doc(tripRefPath);
    final snap = await tripDocRef.get();
    if (!snap.exists) {
      _snack('Trip not found');
      return;
    }
    final data = snap.data();
    if (data == null) {
      _snack('Trip not available');
      return;
    }

    final tripData = <String, dynamic>{...data, 'tripRef': tripRefPath};
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TripDetailScreen(docId: snap.id, data: tripData),
        ),
      );
    });
  }

  Future<void> _showJoinPendingDialog({required String ownerUid}) async {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) {
          return AlertDialog(
            title: const Text('Join request sent'),
            content: Text(
              ownerUid.isEmpty
                  ? 'The trip owner needs to approve your request before it appears in Shared Trips.'
                  : 'The trip owner ($ownerUid) needs to approve your request before it appears in Shared Trips.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK'),
              ),
              TextButton(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  if (!mounted) return;
                  Navigator.of(context).pushNamed('/my-trips');
                },
                child: const Text('Go to My Trips'),
              ),
            ],
          );
        },
      );
    });
  }

  Future<void> _maybeHandleJoinLink() async {
    if (_handled) return;
    if (!kIsWeb) return;

    final joinTrip = Uri.base.queryParameters['joinTrip'];
    if (joinTrip == null || joinTrip.trim().isEmpty) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return; // wait until user signs in

    _handled = true;

    final parsed = _parseTripRef(joinTrip.trim());
    if (parsed == null) {
      _snack('Invalid trip link');
      return;
    }

    final ownerUid = parsed['ownerUid']!;
    final tripId = parsed['tripId']!;

    try {
      // First try to open the trip immediately. If the current user already
      // has read access (owner or already-shared), this will work and the
      // link behaves like users expect.
      try {
        await _openTripDetailFromRef(joinTrip.trim());
        return;
      } catch (e) {
        // If we can't read it yet (permission denied), fall back to join flow.
        if (kDebugMode) {
          // ignore: avoid_print
          print('Join link: could not open trip directly: $e');
        }
      }

      String requesterName = (user.displayName ?? '').trim();
      if (requesterName.isEmpty) {
        final pub =
            await FirebaseFirestore.instance
                .collection('publicUsers')
                .doc(user.uid)
                .get();
        requesterName = (pub.data()?['name'] ?? '').toString().trim();
      }
      if (requesterName.isEmpty) requesterName = 'Someone';

      final tripDocRef = FirebaseFirestore.instance.doc(joinTrip.trim());
      final joinReqId = '${ownerUid}_${tripId}_${user.uid}';
      final joinReqRef = FirebaseFirestore.instance
          .collection('tripJoinRequests')
          .doc(joinReqId);

      await FirebaseFirestore.instance.runTransaction((tx) async {
        final tripSnap = await tx.get(tripDocRef);
        if (!tripSnap.exists) {
          throw StateError('Trip not found');
        }

        final existing = await tx.get(joinReqRef);
        if (existing.exists) {
          return;
        }

        tx.set(joinReqRef, {
          'tripRef': joinTrip.trim(),
          'ownerUid': ownerUid,
          'tripId': tripId,
          'requesterUid': user.uid,
          'requesterName': requesterName,
          'status': 'pending',
          'createdAt': FieldValue.serverTimestamp(),
        });
      });

      _showJoinPendingDialog(ownerUid: ownerUid);
    } catch (e) {
      _snack('Could not send join request');
      if (kDebugMode) {
        // ignore: avoid_print
        print('Join link handling failed: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
