import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:trypr/services/premium_access.dart';

class PremiumRequiredException implements Exception {
  final String message;
  const PremiumRequiredException(this.message);

  @override
  String toString() => message;
}

class AiSuggestionsService {
  final FirebaseFunctions _functions;

  AiSuggestionsService({FirebaseFunctions? functions})
    : _functions =
          functions ??
          FirebaseFunctions.instanceFor(
            region: const String.fromEnvironment(
              'FIREBASE_FUNCTIONS_REGION',
              defaultValue: 'us-central1',
            ),
          );

  Future<List<Map<String, dynamic>>> suggestAccommodations({
    required String destinationName,
    required double lat,
    required double lon,
    required String startDate,
    required String endDate,
    Map<String, dynamic>? preferences,
  }) async {
    return _call(
      module: 'accommodations',
      destinationName: destinationName,
      lat: lat,
      lon: lon,
      startDate: startDate,
      endDate: endDate,
      preferences: preferences,
    );
  }

  Future<List<Map<String, dynamic>>> suggestItinerary({
    required String destinationName,
    required double lat,
    required double lon,
    required String startDate,
    required String endDate,
    Map<String, dynamic>? preferences,
  }) async {
    return _call(
      module: 'itinerary',
      destinationName: destinationName,
      lat: lat,
      lon: lon,
      startDate: startDate,
      endDate: endDate,
      preferences: preferences,
    );
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

      final result = await callable
          .call(payload)
          .timeout(const Duration(seconds: 18));
      final data = Map<String, dynamic>.from(result.data as Map);
      final suggestionsRaw = (data['suggestions'] as List?) ?? const [];
      return suggestionsRaw
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } on FirebaseFunctionsException catch (e) {
      final message = (e.message ?? '');
      if (e.code == 'permission-denied' &&
          message.contains('PREMIUM_REQUIRED')) {
        final premiumEnabled = await PremiumAccessService().canAccessPremium();
        if (premiumEnabled) {
          return _buildLocalFallbackSuggestions(
            module: module,
            destinationName: destinationName,
            preferences: preferences,
          );
        }
        throw const PremiumRequiredException(
          'Unlock AI Suggestions with Trypr Premium. Save time planning your trip.',
        );
      }

      if (e.code == 'failed-precondition') {
        if (message.contains('Trip dates required') ||
            message.contains('Waypoint coordinates required')) {
          throw Exception(message);
        }
        return _buildLocalFallbackSuggestions(
          module: module,
          destinationName: destinationName,
          preferences: preferences,
        );
      }

      if (e.code == 'internal' ||
          e.code == 'unavailable' ||
          e.code == 'not-found') {
        return _buildLocalFallbackSuggestions(
          module: module,
          destinationName: destinationName,
          preferences: preferences,
        );
      }

      rethrow;
    } catch (_) {
      return _buildLocalFallbackSuggestions(
        module: module,
        destinationName: destinationName,
        preferences: preferences,
      );
    }
  }

  List<Map<String, dynamic>> _buildLocalFallbackSuggestions({
    required String module,
    required String destinationName,
    Map<String, dynamic>? preferences,
  }) {
    final seed = destinationName.codeUnits.fold<int>(
      0,
      (sum, c) => (sum + c) % 100000,
    );
    final budgetTier = (preferences?['budgetTier'] ?? 'moderate').toString();
    final type = (preferences?['activityType'] ?? 'exploring').toString();

    double budgetMultiplier() {
      switch (budgetTier.toLowerCase()) {
        case 'budget':
          return 0.75;
        case 'luxury':
          return 1.5;
        default:
          return 1.0;
      }
    }

    double ratingFor(int i) {
      final v = 3.8 + (((seed + i * 17) % 12) / 10.0);
      return v.clamp(3.8, 4.9);
    }

    if (module == 'accommodations') {
      final stayType =
          (preferences?['stayType'] ?? 'hotel').toString().trim().toLowerCase();
      late final List<String> names;
      late final List<double> basePrices;
      switch (stayType) {
        case 'camping':
          names = <String>[
            '$destinationName Campground',
            '$destinationName RV & Tent Site',
            '$destinationName Nature Campsite',
          ];
          basePrices = <double>[45, 60, 75];
          break;
        case 'hostel':
          names = <String>[
            '$destinationName Central Hostel',
            '$destinationName Backpacker House',
            '$destinationName Social Hostel',
          ];
          basePrices = <double>[50, 72, 95];
          break;
        default:
          names = <String>[
            '$destinationName Central Hotel',
            '$destinationName Riverside Suites',
            '$destinationName Boutique Stay',
          ];
          basePrices = <double>[120, 165, 210];
          break;
      }
      final multiplier = budgetMultiplier();
      return List.generate(3, (i) {
        return {
          'name': names[i],
          'address': '${i + 1} Main St, $destinationName',
          'price': (basePrices[i] * multiplier).roundToDouble(),
          'rating': ratingFor(i),
          'stayType': stayType,
          'source': 'local_fallback',
        };
      });
    }

    final category = _fallbackCategory(type);
    final activityNames = <String>[
      'City highlights walk',
      'Scenic viewpoint stop',
      'Local food experience',
      'Historic district exploration',
      'Cultural center visit',
      'Neighborhood market stroll',
      'Sunset photo session',
      'Signature local attraction',
    ];
    final basePrices = <double>[0, 12, 28, 15, 20, 10, 0, 25];
    final multiplier = budgetMultiplier();
    return List.generate(activityNames.length, (i) {
      return {
        'name': '$destinationName ${activityNames[i]}',
        'address': '${10 + i} Center Ave, $destinationName',
        'estimatedPrice': (basePrices[i] * multiplier).roundToDouble(),
        'rating': ratingFor(i),
        'category': category,
        'source': 'local_fallback',
      };
    });
  }

  String _fallbackCategory(String type) {
    switch (type.toLowerCase()) {
      case 'adventure':
        return 'Adventure';
      case 'fooddrink':
      case 'food_drink':
      case 'food':
        return 'Restaurant';
      case 'culturemuseum':
      case 'culture':
      case 'museum':
        return 'Museum';
      case 'relaxation':
        return 'Free Time';
      case 'sightseeing':
        return 'Sightseeing';
      case 'nightlife':
      case 'towns':
        return 'Exploring';
      case 'attractions':
        return 'Sightseeing';
      default:
        return 'Exploring';
    }
  }
}
