import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:trypr/theme/app_theme.dart';
import 'package:trypr/widgets/top_taskbar.dart';
import 'package:trypr/screens/complete_profile_screen.dart';

class CreateAccountScreen extends StatefulWidget {
  const CreateAccountScreen({super.key});

  @override
  State<CreateAccountScreen> createState() => _CreateAccountScreenState();
}

class _CreateAccountScreenState extends State<CreateAccountScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _loading = false;
  bool _googleLoading = false;

  Future<void> _createAccount() async {
    if (_passwordController.text != _confirmController.text) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Passwords do not match')));
      return;
    }
    setState(() => _loading = true);
    try {
      final cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );
      // Ensure a normalized users/{uid} document exists for searches.
      final user = cred.user ?? FirebaseAuth.instance.currentUser;
      if (user != null) {
        await _upsertUserDoc(user);
      }
      if (!mounted) return;
      // Navigate to complete profile so new users fill required fields
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const CompleteProfileScreen()),
      );
    } on FirebaseAuthException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? 'Create account failed')),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _signUpWithGoogle() async {
    setState(() => _googleLoading = true);
    try {
      if (kIsWeb) {
        final provider = GoogleAuthProvider();
        await FirebaseAuth.instance.signInWithPopup(provider);
      } else {
        final googleUser = await GoogleSignIn().signIn();
        if (googleUser == null) return;
        final googleAuth = await googleUser.authentication;
        final credential = GoogleAuthProvider.credential(
          accessToken: googleAuth.accessToken,
          idToken: googleAuth.idToken,
        );
        await FirebaseAuth.instance.signInWithCredential(credential);
      }
      // After sign-in, ensure a users/{uid} doc is present/normalized
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        await _upsertUserDoc(user);
      }
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const CompleteProfileScreen()),
      );
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Google sign up failed')));
    } finally {
      if (mounted) setState(() => _googleLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const TopTaskbar(dockProgress: 1.0),
      body: Container(
        decoration: BoxDecoration(
          image: DecorationImage(
            image: const AssetImage('images/DSC_0042.jpg'),
            fit: BoxFit.cover,
            colorFilter: ColorFilter.mode(
              Colors.black.withOpacity(0.35),
              BlendMode.darken,
            ),
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(TryprSpacing.xxl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Container(
                decoration: BoxDecoration(
                  color: TryprColors.surface,
                  borderRadius: BorderRadius.circular(TryprRadius.xxl),
                  boxShadow: TryprColors.elevatedShadow,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(TryprSpacing.xxxl),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Welcome icon
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: TryprColors.primary.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(TryprRadius.lg),
                        ),
                        child: const Icon(
                          Icons.explore_rounded,
                          color: TryprColors.primary,
                          size: 28,
                        ),
                      ),
                      const SizedBox(height: TryprSpacing.xl),
                      Text(
                        'Start your journey',
                        style: Theme.of(context).textTheme.displaySmall,
                      ),
                      const SizedBox(height: TryprSpacing.sm),
                      Text(
                        'Create an account to plan and save your adventures',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: TryprColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: TryprSpacing.xxl),
                      TextField(
                        controller: _emailController,
                        decoration: InputDecoration(
                          prefixIcon: const Icon(Icons.email_outlined),
                          hintText: 'Enter your email',
                          labelText: 'Email',
                          filled: true,
                          fillColor: TryprColors.surfaceVariant,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(TryprRadius.md),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        keyboardType: TextInputType.emailAddress,
                      ),
                      const SizedBox(height: TryprSpacing.lg),
                      TextField(
                        controller: _passwordController,
                        decoration: InputDecoration(
                          prefixIcon: const Icon(Icons.lock_outline),
                          hintText: 'Create a password',
                          labelText: 'Password',
                          filled: true,
                          fillColor: TryprColors.surfaceVariant,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(TryprRadius.md),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        obscureText: true,
                      ),
                      const SizedBox(height: TryprSpacing.lg),
                      TextField(
                        controller: _confirmController,
                        decoration: InputDecoration(
                          prefixIcon: const Icon(Icons.lock_outline),
                          hintText: 'Confirm your password',
                          labelText: 'Confirm password',
                          filled: true,
                          fillColor: TryprColors.surfaceVariant,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(TryprRadius.md),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        obscureText: true,
                      ),
                      const SizedBox(height: TryprSpacing.xxl),
                      _loading
                          ? const Center(
                            child: CircularProgressIndicator(
                              color: TryprColors.primary,
                            ),
                          )
                          : PrimaryButton(
                            label: 'Create account',
                            icon: Icons.arrow_forward,
                            fullWidth: true,
                            onPressed: _createAccount,
                          ),
                      const SizedBox(height: TryprSpacing.xl),
                      Row(
                        children: [
                          const Expanded(
                            child: Divider(color: TryprColors.textTertiary),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: TryprSpacing.lg,
                            ),
                            child: Text(
                              'or continue with',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                          const Expanded(
                            child: Divider(color: TryprColors.textTertiary),
                          ),
                        ],
                      ),
                      const SizedBox(height: TryprSpacing.xl),
                      _googleLoading
                          ? const Center(
                            child: CircularProgressIndicator(
                              color: TryprColors.primary,
                            ),
                          )
                          : OutlinedButton.icon(
                            icon: Image.network(
                              'https://www.google.com/favicon.ico',
                              width: 20,
                              height: 20,
                              errorBuilder:
                                  (_, __, ___) =>
                                      const Icon(Icons.g_mobiledata, size: 20),
                            ),
                            label: const Text('Google'),
                            onPressed: _signUpWithGoogle,
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                vertical: TryprSpacing.lg,
                              ),
                              side: const BorderSide(color: Color(0xFFE2E8F0)),
                              foregroundColor: TryprColors.textPrimary,
                            ),
                          ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _upsertUserDoc(User user) async {
  try {
    final email = (user.email ?? '').toLowerCase();
    var displayName = (user.displayName ?? '').trim();
    if (displayName.isEmpty) {
      // Fallback to local-part of email if displayName missing
      final parts = email.split('@');
      displayName = parts.isNotEmpty ? parts.first : '';
    }
    final doc = FirebaseFirestore.instance.collection('users').doc(user.uid);
    await doc.set({
      'name': displayName,
      'displayName': displayName,
      'displayNameLower': displayName.toLowerCase(),
      'email': email,
      'createdAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  } catch (_) {
    // Don't block sign-in on Firestore write failures; optional retry could be added.
  }
}
