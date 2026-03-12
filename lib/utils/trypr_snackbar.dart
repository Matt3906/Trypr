import 'package:flutter/material.dart';

// Centralized snackbar motion so notifications feel consistent and polished.
const AnimationStyle _tryprSnackBarAnimation = AnimationStyle(
  duration: Duration(milliseconds: 420),
  reverseDuration: Duration(milliseconds: 220),
  curve: Curves.easeOutCubic,
  reverseCurve: Curves.easeInCubic,
);

extension TryprSnackBarX on ScaffoldMessengerState {
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showTryprSnackBar(
    SnackBar snackBar, {
    AnimationStyle? animationStyle,
  }) {
    return showSnackBar(
      snackBar,
      snackBarAnimationStyle: animationStyle ?? _tryprSnackBarAnimation,
    );
  }
}
