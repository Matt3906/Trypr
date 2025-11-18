// Conditional export: web implementation uses Nominatim; other platforms use stub.
export 'geocode_stub.dart' if (dart.library.html) 'geocode_web.dart';
