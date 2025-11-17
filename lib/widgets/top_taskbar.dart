import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:trypr/screens/my_trips_screen.dart';
import 'package:trypr/screens/trip_builder_screen.dart';
import 'package:trypr/screens/verified_trips_screen.dart';
import 'package:trypr/screens/about_screen.dart';
import 'package:trypr/screens/account_screen.dart';
import 'package:trypr/screens/friends_screen.dart';
import 'package:trypr/screens/sign_in_screen.dart';
import 'package:trypr/screens/create_account_screen.dart';
import 'package:trypr/services/auth_state.dart';

typedef SignInStateSetter = void Function(bool signedIn);

class TopTaskbar extends StatefulWidget implements PreferredSizeWidget {
  final double dockProgress;
  final SignInStateSetter? onSignInStateChanged;

  const TopTaskbar({
    Key? key,
    this.dockProgress = 1.0,
    this.onSignInStateChanged,
  }) : super(key: key);

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  State<TopTaskbar> createState() => _TopTaskbarState();
}

class _TopTaskbarState extends State<TopTaskbar> {
  bool get _signedIn => AuthState.instance.signedIn.value;

  @override
  Widget build(BuildContext context) {
    final dp = widget.dockProgress.clamp(0.0, 1.0);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      color: Color.lerp(Colors.transparent, Colors.white, dp),
      child: SafeArea(
        child: Row(
          children: [
            SizedBox(
              height: 36,
              child: Stack(
                alignment: Alignment.centerLeft,
                children: [
                  Opacity(
                    opacity: (1.0 - dp).clamp(0.0, 1.0),
                    child: Image.asset(
                      'images/Trypr Logo_White.png',
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
                      'images/Trypr Logo_Black.png',
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
            const SizedBox(width: 18),
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  _NavItem(
                    label: 'Home',
                    color: Color.lerp(Colors.white70, Colors.black87, dp)!,
                    onPressed:
                        () => Navigator.of(context).popUntil((r) => r.isFirst),
                  ),
                  _NavItem(
                    label: 'My Trips',
                    color: Color.lerp(Colors.white70, Colors.black87, dp)!,
                    onPressed:
                        () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const MyTripsScreen(),
                          ),
                        ),
                  ),
                  _NavItem(
                    label: 'Trip Builder',
                    color: Color.lerp(Colors.white70, Colors.black87, dp)!,
                    onPressed:
                        () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const TripBuilderScreen(),
                          ),
                        ),
                  ),
                  _NavItem(
                    label: 'Verified Trips',
                    color: Color.lerp(Colors.white70, Colors.black87, dp)!,
                    onPressed:
                        () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const VerifiedTripsScreen(),
                          ),
                        ),
                  ),
                  _NavItem(
                    label: 'About',
                    color: Color.lerp(Colors.white70, Colors.black87, dp)!,
                    onPressed:
                        () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const AboutScreen(),
                          ),
                        ),
                  ),
                ],
              ),
            ),
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: Color.lerp(Colors.white24, Colors.grey.shade200, dp),
                shape: BoxShape.circle,
              ),
              child: PopupMenuButton<String>(
                padding: EdgeInsets.zero,
                child: Icon(
                  Icons.person_outline,
                  color: Color.lerp(Colors.white, Colors.black87, dp),
                ),
                onSelected: (value) async {
                  if (value == 'sign_in') {
                    final res = await Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const SignInScreen()),
                    );
                    if (res == true)
                      (widget.onSignInStateChanged ??
                          AuthState.instance.setSignedIn)(true);
                  } else if (value == 'create_account') {
                    final res = await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const CreateAccountScreen(),
                      ),
                    );
                    if (res == true)
                      (widget.onSignInStateChanged ??
                          AuthState.instance.setSignedIn)(true);
                  } else if (value == 'view_account') {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const AccountScreen()),
                    );
                  } else if (value == 'friends') {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const FriendsScreen()),
                    );
                  } else if (value == 'sign_out') {
                    (widget.onSignInStateChanged ??
                        AuthState.instance.setSignedIn)(false);
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('Signed out')));
                  }
                },
                itemBuilder: (ctx) {
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
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: 'sign_out',
                      child: Text('Sign out'),
                    ),
                  ];
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback? onPressed;
  const _NavItem({
    Key? key,
    required this.label,
    this.color = Colors.white70,
    this.onPressed,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0),
      child: TextButton(
        style: TextButton.styleFrom(foregroundColor: color),
        onPressed: onPressed,
        child: Text(label, style: const TextStyle(fontSize: 14)),
      ),
    );
  }
}
