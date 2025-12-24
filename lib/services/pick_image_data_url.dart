import 'pick_image_data_url_stub.dart'
    if (dart.library.html) 'pick_image_data_url_web.dart';

/// Picks a single image from the user's device and returns it as a Data URL
/// string (e.g. `data:image/png;base64,...`).
///
/// On non-web platforms this returns null (no-op) unless a platform picker
/// package is added.
Future<String?> pickImageDataUrl() => pickImageDataUrlImpl();
