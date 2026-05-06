import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:trypr/utils/trypr_snackbar.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:trypr/theme/app_theme.dart';
import 'package:trypr/widgets/top_taskbar.dart';
import 'create_account_screen.dart';

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;
  bool _googleLoading = false;

  Future<void> _signIn() async {
    setState(() => _loading = true);
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showTryprSnackBar(
        SnackBar(content: Text(e.message ?? 'Sign in failed')),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _signInWithGoogle() async {
    setState(() => _googleLoading = true);
    try {
      if (kIsWeb) {
        final provider = GoogleAuthProvider();
        await FirebaseAuth.instance.signInWithPopup(provider);
      } else {
        final googleUser = await GoogleSignIn().signIn();
        if (googleUser == null) return; // cancelled
        final googleAuth = await googleUser.authentication;
        final credential = GoogleAuthProvider.credential(
          accessToken: googleAuth.accessToken,
          idToken: googleAuth.idToken,
        );
        await FirebaseAuth.instance.signInWithCredential(credential);
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showTryprSnackBar(
        SnackBar(content: Text(e.message ?? 'Google sign in failed')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showTryprSnackBar(SnackBar(content: Text('Google sign in failed')));
    } finally {
      if (mounted) setState(() => _googleLoading = false);
    }
  }

  Future<void> _showForgotPassword() async {
    final emailCtrl = TextEditingController(text: _emailController.text);
    final ok = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Reset password'),
            content: TextField(
              controller: emailCtrl,
              decoration: const InputDecoration(labelText: 'Email'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Send'),
              ),
            ],
          ),
    );
    if (ok != true) return;
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(
        email: emailCtrl.text.trim(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showTryprSnackBar(
        const SnackBar(content: Text('Password reset email sent')),
      );
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showTryprSnackBar(
        SnackBar(content: Text(e.message ?? 'Failed to send reset email')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const TopTaskbar(dockProgress: 1.0),
      body: Container(
        decoration: BoxDecoration(
          image: DecorationImage(
            image: const AssetImage('images/DSC_0318.jpg'),
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
                          Icons.waving_hand_rounded,
                          color: TryprColors.primary,
                          size: 28,
                        ),
                      ),
                      const SizedBox(height: TryprSpacing.xl),
                      Text(
                        'Welcome back',
                        style: Theme.of(context).textTheme.displaySmall,
                      ),
                      const SizedBox(height: TryprSpacing.sm),
                      Text(
                        'Sign in to continue your next adventure',
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
                          hintText: 'Enter your password',
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
                      const SizedBox(height: TryprSpacing.sm),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: _showForgotPassword,
                          child: const Text(
                            'Forgot password?',
                            style: TextStyle(
                              color: TryprColors.primary,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: TryprSpacing.lg),
                      _loading
                          ? const Center(
                            child: CircularProgressIndicator(
                              color: TryprColors.primary,
                            ),
                          )
                          : PrimaryButton(
                            label: 'Sign in',
                            icon: Icons.arrow_forward,
                            fullWidth: true,
                            onPressed: _signIn,
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
                            onPressed: _signInWithGoogle,
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                vertical: TryprSpacing.lg,
                              ),
                              side: const BorderSide(color: Color(0xFFE2E8F0)),
                              foregroundColor: TryprColors.textPrimary,
                            ),
                          ),
                      const SizedBox(height: TryprSpacing.xxl),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            "Don't have an account? ",
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          GestureDetector(
                            onTap:
                                () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => const CreateAccountScreen(),
                                  ),
                                ),
                            child: const Text(
                              'Create one',
                              style: TextStyle(
                                color: TryprColors.primary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
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
