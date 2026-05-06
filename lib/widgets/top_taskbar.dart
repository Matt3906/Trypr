import 'package:flutter/material.dart';
import 'package:trypr/utils/trypr_snackbar.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:trypr/theme/app_theme.dart';
import 'package:trypr/screens/my_trips_screen.dart';
import 'package:trypr/screens/trip_builder_screen.dart';
import 'package:trypr/screens/verified_trips_screen.dart';
import 'package:trypr/screens/about_screen.dart';
import 'package:trypr/screens/app_home_mobile.dart'
    if (dart.library.html) 'package:trypr/screens/app_home_web.dart';
import 'package:trypr/screens/account_screen.dart';
import 'package:trypr/screens/friends_screen.dart';
import 'package:trypr/screens/sign_in_screen.dart';
import 'package:trypr/screens/create_account_screen.dart';
import 'package:trypr/screens/admin_panel_screen.dart';
import 'package:trypr/services/auth_state.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;

import 'dart:async';

typedef SignInStateSetter = void Function(bool signedIn);

class TopTaskbar extends StatefulWidget implements PreferredSizeWidget {
  final double dockProgress;
  final SignInStateSetter? onSignInStateChanged;

  const TopTaskbar({
    super.key,
    this.dockProgress = 1.0,
    this.onSignInStateChanged,
  });

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  State<TopTaskbar> createState() => _TopTaskbarState();
}

class _TopTaskbarState extends State<TopTaskbar> {
  bool get _signedIn => AuthState.instance.signedIn.value;
  Stream<DocumentSnapshot<Map<String, dynamic>>>? _userDoc;
  Stream<DocumentSnapshot<Map<String, dynamic>>>? _adminDoc;
  VoidCallback? _signedInListener;
  StreamSubscription<User?>? _authSub;

  bool _isPremiumFromUserDoc(Map<String, dynamic>? data) {
    final source = data ?? const <String, dynamic>{};
    final subscription =
        (source['subscription'] ?? '').toString().toLowerCase();
    final subscriptionType =
        (source['subscriptionType'] ?? '').toString().toLowerCase();
    final status =
        (source['subscriptionStatus'] ?? '').toString().toLowerCase();
    return subscription == 'premium' ||
        subscriptionType == 'premium' ||
        status == 'premium';
  }

  @override
  void initState() {
    super.initState();

    void syncDocs(User? u) {
      if (!mounted) return;
      setState(() {
        _userDoc =
            u != null
                ? FirebaseFirestore.instance
                    .collection('users')
                    .doc(u.uid)
                    .snapshots()
                : null;
        _adminDoc =
            u != null
                ? FirebaseFirestore.instance
                    .collection('admins')
                    .doc(u.uid)
                    .snapshots()
                : null;
        if (u != null) {
          _ensureUserDoc(u);
        }
      });
    }

    // Initialize with current user
    final currentUser = FirebaseAuth.instance.currentUser;
    syncDocs(currentUser);

    // Listen to auth state changes directly from Firebase
    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      syncDocs(user);
    });

    // Also listen to AuthState for UI refresh
    _signedInListener = () {
      if (!mounted) return;
      syncDocs(FirebaseAuth.instance.currentUser);
    };
    AuthState.instance.signedIn.addListener(_signedInListener!);
  }

  @override
  void dispose() {
    _authSub?.cancel();
    final l = _signedInListener;
    if (l != null) {
      AuthState.instance.signedIn.removeListener(l);
    }
    super.dispose();
  }

  Future<void> _ensureUserDoc(User u) async {
    try {
      final doc = FirebaseFirestore.instance.collection('users').doc(u.uid);
      final snap = await doc.get();
      final exists = snap.exists;
      final upd = <String, dynamic>{};
      if (!exists) {
        upd['createdAt'] = FieldValue.serverTimestamp();
      }
      // ensure email and displayName exist in the document for discoverability
      upd['email'] = (u.email ?? '').toLowerCase();
      final dn = (u.displayName ?? '').toString();
      if (dn.isNotEmpty) {
        upd['displayName'] = dn;
        upd['displayNameLower'] = dn.toLowerCase();
      } else {
        // ensure the lower field exists (may be empty)
        upd['displayNameLower'] = '';
      }
      await doc.set(upd, SetOptions(merge: true));
      // Also maintain a public profile doc for displaying names in shared trips.
      // This avoids needing read access to /users/{uid} for other users.
      final pub = FirebaseFirestore.instance
          .collection('publicUsers')
          .doc(u.uid);
      await pub.set({
        'displayName': dn,
        'displayNameLower': dn.toLowerCase(),
        'email': (u.email ?? '').toLowerCase(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {
      // ignore errors here; this is best-effort to populate user doc for friend search
    }
  }

  void _goToPrimaryLanding() {
    final navigator = Navigator.of(context);
    navigator.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const AppHomeScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final dp = widget.dockProgress.clamp(0.0, 1.0);
    final w = MediaQuery.sizeOf(context).width;
    final isMobile = w < 760;
    final horizontalPadding = w < 420 ? 12.0 : 18.0;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      color: Color.lerp(Colors.transparent, Colors.white, dp),
      child: SafeArea(
        child: Row(
          children: [
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _goToPrimaryLanding,
                child: SizedBox(
                  height: 36,
                  child: Stack(
                    alignment: Alignment.centerLeft,
                    children: [
                      Opacity(
                        opacity: (1.0 - dp).clamp(0.0, 1.0),
                        child: Image.asset(
                          'images/TryprLogo_White.png',
                          fit: BoxFit.contain,
                          errorBuilder:
                              (ctx2, err, st) => Text(
                                'Trypr',
                                style: GoogleFonts.poppins(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                  color: Color.lerp(
                                    Colors.white,
                                    Colors.black87,
                                    dp,
                                  ),
                                ),
                              ),
                        ),
                      ),
                      Opacity(
                        opacity: (dp).clamp(0.0, 1.0),
                        child: Image.asset(
                          'images/TryprLogo_Black.png',
                          fit: BoxFit.contain,
                          errorBuilder:
                              (ctx2, err, st) => Text(
                                'Trypr',
                                style: GoogleFonts.poppins(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                  color: Color.lerp(
                                    Colors.white,
                                    Colors.black87,
                                    dp,
                                  ),
                                ),
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (!isMobile) ...[
              SizedBox(width: w < 420 ? 10 : 18),
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.start,
                      children: [
                        _NavItem(
                          label: 'My Trips',
                          color:
                              Color.lerp(Colors.white70, Colors.black87, dp)!,
                          onPressed:
                              () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => const MyTripsScreen(),
                                ),
                              ),
                        ),
                        _NavItem(
                          label: 'Trip Builder',
                          color:
                              Color.lerp(Colors.white70, Colors.black87, dp)!,
                          onPressed:
                              () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => const TripBuilderScreen(),
                                ),
                              ),
                        ),
                        _NavItem(
                          label: 'Verified Trips',
                          color:
                              Color.lerp(Colors.white70, Colors.black87, dp)!,
                          onPressed:
                              () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => const VerifiedTripsScreen(),
                                ),
                              ),
                        ),
                        _NavItem(
                          label: 'About',
                          color:
                              Color.lerp(Colors.white70, Colors.black87, dp)!,
                          onPressed:
                              () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => const AboutScreen(),
                                ),
                              ),
                        ),
                        // Admin Panel - only visible to admins
                        Builder(
                          builder: (ctx) {
                            if (_adminDoc == null) {
                              return const SizedBox.shrink();
                            }
                            return StreamBuilder<
                              DocumentSnapshot<Map<String, dynamic>>
                            >(
                              stream: _adminDoc,
                              builder: (ctx, adminSnap) {
                                if (adminSnap.connectionState ==
                                    ConnectionState.waiting) {
                                  return const SizedBox.shrink();
                                }
                                if (adminSnap.hasError) {
                                  return const SizedBox.shrink();
                                }
                                if (!adminSnap.hasData ||
                                    !(adminSnap.data?.exists ?? false)) {
                                  return const SizedBox.shrink();
                                }
                                return _NavItem(
                                  label: '⚙️ Admin',
                                  color:
                                      Color.lerp(
                                        const Color(0xFF00B894),
                                        const Color(0xFF00896F),
                                        dp,
                                      )!,
                                  onPressed:
                                      () => Navigator.of(
                                        context,
                                      ).push(AdminPanelScreen.route()),
                                );
                              },
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ] else ...[
              const Spacer(),
              StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                stream: _adminDoc,
                builder: (context, adminSnap) {
                  final isAdmin =
                      adminSnap.hasData && (adminSnap.data?.exists ?? false);
                  return PopupMenuButton<String>(
                    tooltip: 'Menu',
                    icon: Icon(
                      Icons.menu,
                      color: Color.lerp(Colors.white, Colors.black87, dp),
                    ),
                    onSelected: (value) {
                      switch (value) {
                        case 'my_trips':
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const MyTripsScreen(),
                            ),
                          );
                          return;
                        case 'trip_builder':
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const TripBuilderScreen(),
                            ),
                          );
                          return;
                        case 'verified_trips':
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const VerifiedTripsScreen(),
                            ),
                          );
                          return;
                        case 'about':
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const AboutScreen(),
                            ),
                          );
                          return;
                        case 'admin':
                          Navigator.of(context).push(AdminPanelScreen.route());
                          return;
                      }
                    },
                    itemBuilder: (ctx) {
                      final items = <PopupMenuItem<String>>[
                        const PopupMenuItem(
                          value: 'my_trips',
                          child: Text('My Trips'),
                        ),
                        const PopupMenuItem(
                          value: 'trip_builder',
                          child: Text('Trip Builder'),
                        ),
                        const PopupMenuItem(
                          value: 'verified_trips',
                          child: Text('Verified Trips'),
                        ),
                        const PopupMenuItem(
                          value: 'about',
                          child: Text('About'),
                        ),
                      ];
                      if (isAdmin) {
                        items.add(
                          const PopupMenuItem(
                            value: 'admin',
                            child: Text(
                              '⚙️ Admin Panel',
                              style: TextStyle(color: Color(0xFF00B894)),
                            ),
                          ),
                        );
                      }
                      return items;
                    },
                  );
                },
              ),
              const SizedBox(width: 8),
            ],
            StreamBuilder<DocumentSnapshot<Map<String, dynamic>>?>(
              stream: _userDoc,
              builder: (ctx, snap) {
                final userData = snap.data?.data();
                final premiumActive = _isPremiumFromUserDoc(userData);
                Widget avatarChild = Icon(
                  Icons.person_outline,
                  color: Color.lerp(Colors.white, Colors.black87, dp),
                );
                if (snap.hasData && snap.data?.data() != null) {
                  final img =
                      snap.data!.data()!['profileImageDataUrl'] as String?;
                  if (img != null) {
                    if (kIsWeb) {
                      avatarChild = ClipOval(
                        child: Image.network(img, fit: BoxFit.cover),
                      );
                    } else {
                      try {
                        final bytes = base64Decode(img.split(',').last);
                        avatarChild = ClipOval(
                          child: Image.memory(bytes, fit: BoxFit.cover),
                        );
                      } catch (_) {}
                    }
                  }
                }

                return Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Color.lerp(Colors.white24, Colors.grey.shade200, dp),
                    shape: BoxShape.circle,
                  ),
                  child: Tooltip(
                    message: 'Account',
                    child: PopupMenuButton<String>(
                      padding: EdgeInsets.zero,
                      child: avatarChild,
                      onSelected: (value) async {
                        if (value == 'sign_in') {
                          final res = await Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const SignInScreen(),
                            ),
                          );
                          if (res == true) {
                            (widget.onSignInStateChanged ??
                                AuthState.instance.setSignedIn)(true);
                          }
                        } else if (value == 'create_account') {
                          final res = await Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const CreateAccountScreen(),
                            ),
                          );
                          if (res == true) {
                            (widget.onSignInStateChanged ??
                                AuthState.instance.setSignedIn)(true);
                          }
                        } else if (value == 'view_account') {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const AccountScreen(),
                            ),
                          );
                        } else if (value == 'friends') {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const FriendsScreen(),
                            ),
                          );
                        } else if (value == 'open_premium') {
                          await Navigator.of(context).pushNamed('/premium');
                        } else if (value == 'sign_out') {
                          final navigator = Navigator.of(context);
                          final messenger = ScaffoldMessenger.of(context);
                          try {
                            await FirebaseAuth.instance.signOut();
                          } catch (_) {}
                          (widget.onSignInStateChanged ??
                              AuthState.instance.setSignedIn)(false);
                          // Navigate back to sign-in clearing the stack so the
                          // application state resets to a fresh view.
                          if (mounted) {
                            navigator.pushNamedAndRemoveUntil(
                              '/',
                              (route) => false,
                            );
                            messenger.showTryprSnackBar(
                              const SnackBar(content: Text('Signed out')),
                            );
                          }
                        }
                      },
                      itemBuilder: (ctx2) {
                        if (!_signedIn) {
                          return [
                            const PopupMenuItem(
                              value: 'sign_in',
                              child: Text('Sign in'),
                            ),
                            const PopupMenuItem(
                              value: 'create_account',
                              child: Text('Create account'),
                            ),
                          ];
                        }
                        return [
                          const PopupMenuItem(
                            value: 'view_account',
                            child: Text('View account'),
                          ),
                          const PopupMenuItem(
                            value: 'friends',
                            child: Text('Friends'),
                          ),
                          PopupMenuItem(
                            value: 'open_premium',
                            child: Text(
                              premiumActive
                                  ? 'Manage Premium'
                                  : 'Unlock Premium',
                            ),
                          ),
                          const PopupMenuDivider(),
                          const PopupMenuItem(
                            value: 'sign_out',
                            child: Text('Sign out'),
                          ),
                        ];
                      },
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _NavItem extends StatefulWidget {
  final String label;
  final Color color;
  final VoidCallback? onPressed;
  const _NavItem({
    required this.label,
    this.color = Colors.white70,
    this.onPressed,
  });

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: TryprSpacing.sm),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(
            horizontal: TryprSpacing.md,
            vertical: TryprSpacing.sm,
          ),
          decoration: BoxDecoration(
            color:
                _isHovered
                    ? widget.color.withValues(alpha: 0.1)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(TryprRadius.md),
          ),
          child: GestureDetector(
            onTap: widget.onPressed,
            child: Text(
              widget.label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: widget.color,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
