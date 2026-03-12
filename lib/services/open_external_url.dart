import 'open_external_url_stub.dart'
    if (dart.library.html) 'open_external_url_web.dart';

Future<bool> openExternalUrl(String url, {bool sameTab = true}) {
  return openExternalUrlImpl(url, sameTab: sameTab);
}
