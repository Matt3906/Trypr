import 'package:web/web.dart' as web;

bool _isSafeExternalScheme(Uri uri) {
  return uri.scheme == 'https' ||
      uri.scheme == 'http' ||
      uri.scheme == 'mailto' ||
      uri.scheme == 'tel';
}

Future<bool> openExternalUrlImpl(String url, {bool sameTab = true}) async {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return false;

  final uri = Uri.tryParse(trimmed);
  if (uri == null || !_isSafeExternalScheme(uri)) return false;

  if (sameTab) {
    web.window.location.assign(uri.toString());
  } else {
    web.window.open(uri.toString(), '_blank', 'noopener,noreferrer');
  }
  return true;
}
