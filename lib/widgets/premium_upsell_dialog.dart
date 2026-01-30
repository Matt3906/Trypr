import 'package:flutter/material.dart';

Future<void> showPremiumUpsellDialog(
  BuildContext context, {
  String? title,
  String? message,
}) async {
  return showDialog<void>(
    context: context,
    builder: (ctx) {
      return AlertDialog(
        title: Text(title ?? 'Trypr Premium'),
        content: Text(
          message ??
              'Unlock AI Travel Agent. Upgrade to Trypr Premium to get instant, personalized travel suggestions and save hours of planning.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Not now'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00897B),
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              Navigator.of(ctx).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Premium upgrade flow coming soon'),
                ),
              );
            },
            child: const Text('Upgrade Now'),
          ),
        ],
      );
    },
  );
}
