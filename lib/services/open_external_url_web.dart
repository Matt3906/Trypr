// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:html' as html;

Future<bool> openExternalUrlImpl(String url, {bool sameTab = true}) async {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return false;
  if (sameTab) {
    html.window.location.assign(trimmed);
  } else {
    html.window.open(trimmed, '_blank');
  }
  return true;
}
