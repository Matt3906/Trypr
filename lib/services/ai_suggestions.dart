import 'package:cloud_functions/cloud_functions.dart';

class PremiumRequiredException implements Exception {
  final String message;
  const PremiumRequiredException(this.message);

  @override
  String toString() => message;
}

class AiSuggestionsService {
  final FirebaseFunctions _functions;

  AiSuggestionsService({FirebaseFunctions? functions})
    : _functions = functions ?? FirebaseFunctions.instance;

  Future<List<Map<String, dynamic>>> suggestAccommodations({
    required String destinationName,
    required double lat,
    required double lon,
    required String startDate,
    required String endDate,
    Map<String, dynamic>? preferences,
  }) async {
    final res = await _call(
      module: 'accommodations',
      destinationName: destinationName,
      lat: lat,
      lon: lon,
      startDate: startDate,
      endDate: endDate,
      preferences: preferences,
    );
    return res;
  }

  Future<List<Map<String, dynamic>>> suggestItinerary({
    required String destinationName,
    required double lat,
    required double lon,
    required String startDate,
    required String endDate,
    Map<String, dynamic>? preferences,
  }) async {
    final res = await _call(
      module: 'itinerary',
      destinationName: destinationName,
      lat: lat,
      lon: lon,
      startDate: startDate,
      endDate: endDate,
      preferences: preferences,
    );
    return res;
  }

  Future<List<Map<String, dynamic>>> _call({
    required String module,
    required String destinationName,
    required double lat,
    required double lon,
    required String startDate,
    required String endDate,
    Map<String, dynamic>? preferences,
  }) async {
    try {
      final callable = _functions.httpsCallable('aiSuggest');
      final payload = <String, dynamic>{
        'module': module,
        'destinationName': destinationName,
        'lat': lat,
        'lon': lon,
        'startDate': startDate,
        'endDate': endDate,
      };

      if (preferences != null && preferences.isNotEmpty) {
        payload['preferences'] = preferences;
      }

      final result = await callable.call(payload);

      final data = Map<String, dynamic>.from(result.data as Map);
      final suggestionsRaw = (data['suggestions'] as List?) ?? const [];
      return suggestionsRaw
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } on FirebaseFunctionsException catch (e) {
      if (e.code == 'permission-denied' &&
          (e.message ?? '').contains('PREMIUM_REQUIRED')) {
        throw const PremiumRequiredException(
          'Unlock AI Suggestions with Trypr Premium. Save time planning your trip.',
        );
      }
      rethrow;
    }
  }
}
