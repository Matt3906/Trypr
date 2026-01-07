// Always use the flutter_map-based embed implementation for all platforms.
// This avoids platform view registration timing issues on web and provides
// a consistent, cross-platform experience.
export 'map_embed_stub.dart' if (dart.library.html) 'map_embed_web.dart';
