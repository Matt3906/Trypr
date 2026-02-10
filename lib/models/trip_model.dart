import 'package:cloud_firestore/cloud_firestore.dart';

class Stop {
  final String placeName;
  final double latitude;
  final double longitude;
  final String? placeId;

  Stop({
    required this.placeName,
    required this.latitude,
    required this.longitude,
    this.placeId,
  });

  factory Stop.fromMap(Map<String, dynamic> data) {
    // Support both field naming conventions:
    //   Firestore waypoints: name / lat / lon
    //   Legacy TripModel:    placeName / latitude / longitude
    return Stop(
      placeName: (data['name'] ?? data['placeName'] ?? '').toString(),
      latitude: (data['lat'] ?? data['latitude'] ?? 0).toDouble(),
      longitude: (data['lon'] ?? data['longitude'] ?? 0).toDouble(),
      placeId: data['placeId'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': placeName,
      'lat': latitude,
      'lon': longitude,
      'placeId': placeId,
    };
  }
}

class TripModel {
  final String id;
  final String tripName;
  final List<Stop> stops;
  final DateTime startDate;
  final DateTime endDate;
  final double? distance; // in km
  final String? description;
  final List<String>? participants;

  TripModel({
    required this.id,
    required this.tripName,
    required this.stops,
    required this.startDate,
    required this.endDate,
    this.distance,
    this.description,
    this.participants,
  });

  factory TripModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    return TripModel.fromMap(data, doc.id);
  }

  factory TripModel.fromMap(Map<String, dynamic> data, String id) {
    // Support both 'waypoints' (live Firestore) and 'stops' (legacy TripModel)
    final rawStops = data['waypoints'] ?? data['stops'];
    final stopsList = <Stop>[];
    if (rawStops is List) {
      for (final s in rawStops) {
        if (s is Map) {
          stopsList.add(Stop.fromMap(Map<String, dynamic>.from(s)));
        }
      }
    }

    DateTime parseDate(dynamic dateValue) {
      if (dateValue is Timestamp) return dateValue.toDate();
      if (dateValue is String && dateValue.isNotEmpty) {
        return DateTime.tryParse(dateValue) ?? DateTime.now();
      }
      return DateTime.now();
    }

    // Support both field naming conventions
    final name = (data['name'] ?? data['tripName'] ?? 'Untitled Trip').toString();

    return TripModel(
      id: id,
      tripName: name,
      stops: stopsList,
      startDate: parseDate(data['startDate']),
      endDate: parseDate(data['endDate']),
      distance: (data['totalKm'] ?? data['distance'] as num?)?.toDouble(),
      description: data['description'] as String?,
      participants: List<String>.from(data['sharedWith'] ?? data['participants'] ?? []),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': tripName,
      'waypoints': stops.map((s) => s.toMap()).toList(),
      'startDate': startDate.toIso8601String(),
      'endDate': endDate.toIso8601String(),
      'totalKm': distance,
      'description': description,
      'sharedWith': participants,
    };
  }

  int get durationDays => endDate.difference(startDate).inDays + 1;

  String get formattedDates {
    final startFmt = '${startDate.month}/${startDate.day}/${startDate.year}';
    final endFmt = '${endDate.month}/${endDate.day}/${endDate.year}';
    return '$startFmt - $endFmt';
  }
}
