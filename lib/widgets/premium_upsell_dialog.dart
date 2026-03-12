import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:trypr/utils/trypr_snackbar.dart';

Future<void> showPremiumUpsellDialog(
  BuildContext context, {
  String? title,
  String? message,
}) async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showTryprSnackBar(
      const SnackBar(content: Text('Sign in to unlock premium features.')),
    );
    return;
  }

  if (!context.mounted) return;
  await Navigator.of(context).pushNamed('/premium');
}
