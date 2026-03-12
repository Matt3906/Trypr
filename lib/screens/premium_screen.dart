import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:trypr/screens/sign_in_screen.dart';
import 'package:trypr/services/open_external_url.dart';
import 'package:trypr/services/stripe_billing.dart';
import 'package:trypr/theme/app_theme.dart';
import 'package:trypr/utils/trypr_snackbar.dart';
import 'package:trypr/widgets/top_taskbar.dart';

class PremiumScreen extends StatefulWidget {
  const PremiumScreen({super.key});

  @override
  State<PremiumScreen> createState() => _PremiumScreenState();
}

class _PremiumScreenState extends State<PremiumScreen> {
  final StripeBillingService _billing = StripeBillingService();

  bool _checkoutBusy = false;
  bool _portalBusy = false;
  String _selectedPlan = 'yearly';

  User? get _user => FirebaseAuth.instance.currentUser;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _showCheckoutStatusToast();
    });
  }

  void _showCheckoutStatusToast() {
    if (!kIsWeb) return;
    final status = Uri.base.queryParameters['checkout']?.trim().toLowerCase();
    if (status == 'success') {
      ScaffoldMessenger.of(context).showTryprSnackBar(
        const SnackBar(
          content: Text('Payment received. Premium will activate in a moment.'),
        ),
      );
    } else if (status == 'cancelled') {
      ScaffoldMessenger.of(
        context,
      ).showTryprSnackBar(const SnackBar(content: Text('Checkout cancelled.')));
    }
  }

  String? _currentOrigin() {
    if (!kIsWeb) return null;
    try {
      return Uri.base.origin;
    } catch (_) {
      return null;
    }
  }

  Future<void> _startCheckout() async {
    final user = _user;
    if (user == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showTryprSnackBar(
        const SnackBar(content: Text('Sign in to subscribe.')),
      );
      return;
    }

    setState(() => _checkoutBusy = true);
    try {
      final url = await _billing.createCheckoutUrl(
        plan: _selectedPlan,
        returnOrigin: _currentOrigin(),
      );
      final opened = await openExternalUrl(url, sameTab: true);
      if (!opened && mounted) {
        ScaffoldMessenger.of(context).showTryprSnackBar(
          SnackBar(content: Text('Open this URL manually: $url')),
        );
      }
    } on StripeBillingException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showTryprSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showTryprSnackBar(SnackBar(content: Text('Checkout failed: $e')));
    } finally {
      if (mounted) setState(() => _checkoutBusy = false);
    }
  }

  Future<void> _openBillingPortal() async {
    final user = _user;
    if (user == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showTryprSnackBar(
        const SnackBar(content: Text('Sign in to manage billing.')),
      );
      return;
    }

    setState(() => _portalBusy = true);
    try {
      final url = await _billing.createBillingPortalUrl(
        returnOrigin: _currentOrigin(),
      );
      final opened = await openExternalUrl(url, sameTab: true);
      if (!opened && mounted) {
        ScaffoldMessenger.of(context).showTryprSnackBar(
          SnackBar(content: Text('Open this URL manually: $url')),
        );
      }
    } on StripeBillingException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showTryprSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showTryprSnackBar(
        SnackBar(content: Text('Unable to open billing portal: $e')),
      );
    } finally {
      if (mounted) setState(() => _portalBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = _user;

    return Scaffold(
      appBar: const TopTaskbar(dockProgress: 1.0),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFEFF7FF), TryprColors.background],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 36),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 980),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _heroCard(),
                    const SizedBox(height: TryprSpacing.lg),
                    if (user == null) ...[
                      _signedOutCard(context),
                    ] else ...[
                      StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                        stream:
                            FirebaseFirestore.instance
                                .collection('userEntitlements')
                                .doc(user.uid)
                                .snapshots(),
                        builder: (context, snap) {
                          final data =
                              snap.data?.data() ?? const <String, dynamic>{};
                          final premium = _isPremium(data);
                          final status =
                              (data['subscriptionStatus'] ?? '')
                                  .toString()
                                  .toLowerCase();
                          final plan =
                              (data['premiumPlan'] ?? '')
                                  .toString()
                                  .toLowerCase();
                          final periodEnd = data['currentPeriodEnd'];

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _statusCard(
                                premium: premium,
                                plan: plan,
                                status: status,
                                periodEnd: periodEnd,
                              ),
                              const SizedBox(height: TryprSpacing.md),
                              _planSelectorCard(),
                              const SizedBox(height: TryprSpacing.md),
                              _actionCard(premium: premium),
                            ],
                          );
                        },
                      ),
                    ],
                    const SizedBox(height: TryprSpacing.md),
                    _featuresCard(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool _isPremium(Map<String, dynamic> data) {
    final subscription = (data['subscription'] ?? '').toString().toLowerCase();
    final status = (data['subscriptionStatus'] ?? '').toString().toLowerCase();
    final type = (data['subscriptionType'] ?? '').toString().toLowerCase();
    return subscription == 'premium' ||
        status == 'premium' ||
        type == 'premium';
  }

  Widget _heroCard() {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(TryprRadius.xl),
        gradient: const LinearGradient(
          colors: [Color(0xFF1C77C3), Color(0xFF30A8D8), Color(0xFF2CB59A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: TryprColors.elevatedShadow,
      ),
      child: Padding(
        padding: const EdgeInsets.all(TryprSpacing.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Text(
              'Trypr Premium',
              style: TextStyle(
                color: Colors.white,
                fontSize: 30,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.6,
              ),
            ),
            SizedBox(height: TryprSpacing.sm),
            Text(
              'AI planning that saves hours on every trip.',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _signedOutCard(BuildContext context) {
    return SoftCard(
      elevated: true,
      padding: const EdgeInsets.all(TryprSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Sign in to continue',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
              color: TryprColors.textPrimary,
            ),
          ),
          const SizedBox(height: TryprSpacing.sm),
          const Text(
            'You need an account to subscribe and manage billing.',
            style: TextStyle(color: TryprColors.textSecondary),
          ),
          const SizedBox(height: TryprSpacing.lg),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const SignInScreen()));
            },
            icon: const Icon(Icons.login),
            label: const Text('Sign in'),
          ),
        ],
      ),
    );
  }

  Widget _statusCard({
    required bool premium,
    required String plan,
    required String status,
    required dynamic periodEnd,
  }) {
    final planLabel =
        plan == 'yearly'
            ? '\$36/year'
            : plan == 'monthly'
            ? '\$4/month'
            : 'Not set';
    final statusLabel = premium ? 'Active' : (status.isEmpty ? 'Free' : status);
    final color = premium ? TryprColors.success : TryprColors.textSecondary;

    String renewal = '';
    if (periodEnd is Timestamp) {
      renewal = DateFormat('MMM d, yyyy').format(periodEnd.toDate());
    }

    return SoftCard(
      elevated: true,
      padding: const EdgeInsets.all(TryprSpacing.lg),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        runSpacing: TryprSpacing.md,
        spacing: TryprSpacing.xl,
        children: [
          _statusMetric('Status', statusLabel, color),
          _statusMetric('Current Plan', planLabel, TryprColors.primaryDark),
          _statusMetric(
            'Renewal',
            renewal.isEmpty ? '—' : renewal,
            TryprColors.textPrimary,
          ),
        ],
      ),
    );
  }

  Widget _statusMetric(String label, String value, Color valueColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: TryprColors.textSecondary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            color: valueColor,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  Widget _planSelectorCard() {
    return SoftCard(
      elevated: true,
      padding: const EdgeInsets.all(TryprSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Choose billing cycle',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: TryprColors.textPrimary,
            ),
          ),
          const SizedBox(height: TryprSpacing.sm),
          const Text(
            'Monthly: \$4/month • Yearly: \$36/year (save 25%)',
            style: TextStyle(color: TryprColors.textSecondary),
          ),
          const SizedBox(height: TryprSpacing.md),
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 700;
              final monthlyCard = _planCard(
                plan: 'monthly',
                title: 'Monthly',
                price: '\$4',
                detail: 'per month',
              );
              final yearlyCard = _planCard(
                plan: 'yearly',
                title: 'Yearly',
                price: '\$36',
                detail: 'per year',
                badge: 'Best value',
              );
              if (compact) {
                return Column(
                  children: [
                    monthlyCard,
                    const SizedBox(height: TryprSpacing.sm),
                    yearlyCard,
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: monthlyCard),
                  const SizedBox(width: TryprSpacing.md),
                  Expanded(child: yearlyCard),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _planCard({
    required String plan,
    required String title,
    required String price,
    required String detail,
    String? badge,
  }) {
    final selected = _selectedPlan == plan;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(TryprRadius.lg),
        border: Border.all(
          color: selected ? TryprColors.primary : const Color(0xFFD6E2EE),
          width: selected ? 2.2 : 1.2,
        ),
        color:
            selected
                ? const Color(0xFFEFF7FF)
                : TryprColors.surface.withValues(alpha: 0.9),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(TryprRadius.lg),
        onTap: () => setState(() => _selectedPlan = plan),
        child: Padding(
          padding: const EdgeInsets.all(TryprSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: TryprColors.textPrimary,
                    ),
                  ),
                  const Spacer(),
                  if (badge != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: TryprColors.secondary.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        badge,
                        style: const TextStyle(
                          color: TryprColors.secondary,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: TryprSpacing.sm),
              Text(
                price,
                style: const TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  color: TryprColors.textPrimary,
                  letterSpacing: -0.6,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                detail,
                style: const TextStyle(
                  color: TryprColors.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _actionCard({required bool premium}) {
    return SoftCard(
      elevated: true,
      padding: const EdgeInsets.all(TryprSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ElevatedButton.icon(
            onPressed: _checkoutBusy ? null : _startCheckout,
            icon:
                _checkoutBusy
                    ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : const Icon(Icons.bolt),
            label: Text(
              premium
                  ? 'Switch to ${_selectedPlan == 'yearly' ? '\$36/year' : '\$4/month'}'
                  : 'Start ${_selectedPlan == 'yearly' ? '\$36/year' : '\$4/month'}',
            ),
          ),
          const SizedBox(height: TryprSpacing.sm),
          OutlinedButton.icon(
            onPressed: _portalBusy ? null : _openBillingPortal,
            icon:
                _portalBusy
                    ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : const Icon(Icons.settings_outlined),
            label: const Text('Manage billing in Stripe'),
          ),
        ],
      ),
    );
  }

  Widget _featuresCard() {
    const features = [
      'AI activity suggestions for each stop',
      'AI accommodation and route ideas',
      'Faster itinerary planning for complex trips',
      'Premium-only feature releases',
    ];

    return SoftCard(
      padding: const EdgeInsets.all(TryprSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'What you get',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: TryprColors.textPrimary,
            ),
          ),
          const SizedBox(height: TryprSpacing.sm),
          for (final feature in features) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 3),
                  child: Icon(
                    Icons.check_circle,
                    size: 18,
                    color: TryprColors.secondary,
                  ),
                ),
                const SizedBox(width: TryprSpacing.sm),
                Expanded(
                  child: Text(
                    feature,
                    style: const TextStyle(
                      color: TryprColors.textPrimary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: TryprSpacing.sm),
          ],
        ],
      ),
    );
  }
}
