import 'package:cloud_functions/cloud_functions.dart';

class StripeBillingException implements Exception {
  final String message;
  const StripeBillingException(this.message);

  @override
  String toString() => message;
}

class StripeBillingService {
  final FirebaseFunctions _functions;

  StripeBillingService({FirebaseFunctions? functions})
    : _functions =
          functions ??
          FirebaseFunctions.instanceFor(
            region: const String.fromEnvironment(
              'FIREBASE_FUNCTIONS_REGION',
              defaultValue: 'us-central1',
            ),
          );

  Future<String> createCheckoutUrl({
    required String plan,
    String? returnOrigin,
  }) async {
    final normalizedPlan = plan.trim().toLowerCase();
    if (normalizedPlan != 'monthly' && normalizedPlan != 'yearly') {
      throw const StripeBillingException(
        'Invalid plan. Use monthly or yearly.',
      );
    }

    try {
      final callable = _functions.httpsCallable('createStripeCheckoutSession');
      final payload = <String, dynamic>{'plan': normalizedPlan};
      final origin = returnOrigin?.trim() ?? '';
      if (origin.isNotEmpty) payload['returnOrigin'] = origin;

      final result = await callable.call(payload);
      final data = Map<String, dynamic>.from(result.data as Map);
      final url = (data['url'] ?? '').toString().trim();
      if (url.isEmpty) {
        throw const StripeBillingException('Checkout URL was not returned.');
      }
      return url;
    } on FirebaseFunctionsException catch (e) {
      throw StripeBillingException(_friendlyMessage(e));
    }
  }

  Future<String> createBillingPortalUrl({String? returnOrigin}) async {
    try {
      final callable = _functions.httpsCallable('createStripeBillingPortal');
      final payload = <String, dynamic>{};
      final origin = returnOrigin?.trim() ?? '';
      if (origin.isNotEmpty) payload['returnOrigin'] = origin;

      final result = await callable.call(payload);
      final data = Map<String, dynamic>.from(result.data as Map);
      final url = (data['url'] ?? '').toString().trim();
      if (url.isEmpty) {
        throw const StripeBillingException(
          'Billing portal URL was not returned.',
        );
      }
      return url;
    } on FirebaseFunctionsException catch (e) {
      throw StripeBillingException(_friendlyMessage(e));
    }
  }

  String _friendlyMessage(FirebaseFunctionsException e) {
    final code = e.code;
    final message = (e.message ?? '').trim();
    if (code == 'unauthenticated') return 'Please sign in first.';
    if (code == 'failed-precondition' && message.isNotEmpty) return message;
    if (code == 'invalid-argument' && message.isNotEmpty) return message;
    if (code == 'permission-denied') {
      return 'You do not have permission to start billing for this account.';
    }
    if (message.isNotEmpty) return message;
    return 'Billing request failed. Please try again.';
  }
}
