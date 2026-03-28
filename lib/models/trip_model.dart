import 'package:cloud_firestore/cloud_firestore.dart';

String _normalizeTripMode(String? raw) {
  var value = (raw ?? '').trim().toLowerCase();
  if (value == 'driving') value = 'car';
  if (value == 'flying' || value == 'flight') value = 'plane';
  if (value == 'rail' ||
      value == 'public transit' ||
      value == 'public_transit') {
    value = 'train';
  }
  if (value == 'walking') value = 'walk';
  if (value == 'bicycling' || value == 'biking' || value == 'bikepacking') {
    value = 'bike';
  }
  if (value == 'canoe' || value == 'canoeing' || value == 'portage') {
    value = 'portaging';
  }
  if (value == 'backpacking') value = 'hiking';
  if (value == 'gas/stops' || value == 'gas-stops') value = 'gas_stops';
  return value;
}

String normalizeTripType(
  String? raw, {
  String? transportMode,
  List<String>? segmentTransportModes,
}) {
  final normalizedRaw = (raw ?? '').trim().toLowerCase();
  switch (normalizedRaw) {
    case 'road':
    case 'road_trip':
    case 'road trip':
      return 'road';
    case 'portage':
    case 'portaging':
    case 'canoe':
    case 'canoe_trip':
    case 'canoe trip':
    case 'backcountry':
    case 'backcountry_portage':
    case 'backcountry portage':
      return 'portage';
    case 'hiking':
    case 'backpacking':
    case 'hiking_trip':
    case 'hiking trip':
      return 'hiking';
    case 'mixed':
    case 'mixed_mode':
    case 'mixed mode':
      return 'mixed';
  }

  final modes = <String>{};
  void addMode(String? rawMode) {
    final normalized = _normalizeTripMode(rawMode);
    if (normalized.isNotEmpty) modes.add(normalized);
  }

  addMode(transportMode);
  for (final mode in segmentTransportModes ?? const <String>[]) {
    addMode(mode);
  }

  final hasPortage = modes.contains('portaging');
  final hasHiking = modes.contains('hiking');
  final hasRoadMode = modes.any(
    (mode) => mode == 'car' || mode == 'plane' || mode == 'train',
  );
  final hasMixedSurface =
      (hasPortage && (hasRoadMode || hasHiking)) ||
      (hasHiking && hasRoadMode) ||
      modes.where((mode) => mode.isNotEmpty).length >= 3;

  if (hasMixedSurface) return 'mixed';
  if (hasPortage) return 'portage';
  if (hasHiking) return 'hiking';
  return 'road';
}

bool isAdventureTripType(String? raw) {
  final type = normalizeTripType(raw);
  return type == 'portage' || type == 'hiking';
}

String tripTypeDisplayLabel(String? raw) {
  switch (normalizeTripType(raw)) {
    case 'portage':
      return 'Portage / Canoe Trip';
    case 'hiking':
      return 'Hiking / Backpacking Trip';
    case 'mixed':
      return 'Mixed Mode Trip';
    default:
      return 'Road Trip';
  }
}

String tripTypeBadgeLabel(String? raw) {
  switch (normalizeTripType(raw)) {
    case 'portage':
      return 'BACKCOUNTRY PORTAGE';
    case 'hiking':
      return 'HIKING / BACKPACKING';
    case 'mixed':
      return 'MIXED MODE';
    default:
      return 'ROAD TRIP';
  }
}

String tripTypeEmoji(String? raw) {
  switch (normalizeTripType(raw)) {
    case 'portage':
      return '🏕️';
    case 'hiking':
      return '🥾';
    case 'mixed':
      return '🧭';
    default:
      return '🚗';
  }
}

String normalizeTripExperienceLevel(String? raw) {
  final value = (raw ?? '').trim().toLowerCase();
  switch (value) {
    case 'beginner':
    case 'easy':
    case 'novice':
      return 'beginner';
    case 'intermediate':
    case 'moderate':
      return 'intermediate';
    case 'advanced':
    case 'expert':
    case 'challenging':
      return 'advanced';
    default:
      return '';
  }
}

String tripExperienceDisplayLabel(String? raw) {
  switch (normalizeTripExperienceLevel(raw)) {
    case 'intermediate':
      return 'Intermediate';
    case 'advanced':
      return 'Advanced';
    case 'beginner':
      return 'Beginner';
    default:
      return '';
  }
}

String inferTripDifficultyLabel({
  String? tripType,
  String? experienceLevel,
  double? distanceKm,
  double? estimatedDurationMin,
  int stopCount = 0,
  List<String>? segmentTransportModes,
}) {
  final explicit = tripExperienceDisplayLabel(experienceLevel);
  if (explicit.isNotEmpty) return explicit;

  final normalizedType = normalizeTripType(
    tripType,
    segmentTransportModes: segmentTransportModes,
  );
  final km = distanceKm ?? 0.0;
  final minutes = estimatedDurationMin ?? 0.0;
  final stopWeight = stopCount <= 1 ? 0.0 : (stopCount - 1) * 1.2;

  if (normalizedType == 'road') {
    if (km >= 1200 || stopCount >= 6) return 'Advanced';
    if (km >= 450 || stopCount >= 4) return 'Intermediate';
    return 'Beginner';
  }

  var score = km;
  score += minutes / 180.0;
  score += stopWeight;
  if (normalizedType == 'mixed') score += 3.0;

  if (score >= 16) return 'Advanced';
  if (score >= 8) return 'Intermediate';
  return 'Beginner';
}

List<String> inferTripRequiredSkills({
  String? tripType,
  List<String>? segmentTransportModes,
}) {
  final normalizedType = normalizeTripType(
    tripType,
    segmentTransportModes: segmentTransportModes,
  );
  final skills = <String>{};
  switch (normalizedType) {
    case 'portage':
      skills.addAll(const ['Paddling', 'Portaging', 'Camp setup']);
      break;
    case 'hiking':
      skills.addAll(const ['Navigation', 'Camp setup', 'Trail travel']);
      break;
    case 'mixed':
      skills.addAll(const ['Route planning', 'Mode changes']);
      break;
    default:
      skills.add('Trip planning');
      break;
  }
  return skills.toList(growable: false);
}

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
    double asDouble(dynamic value) {
      if (value is num) return value.toDouble();
      if (value is String) return double.tryParse(value) ?? 0.0;
      return 0.0;
    }

    // Support both field naming conventions:
    //   Firestore waypoints: name / lat / lon
    //   Legacy TripModel:    placeName / latitude / longitude
    return Stop(
      placeName:
          (data['name'] ?? data['placeName'] ?? data['title'] ?? '').toString(),
      latitude: asDouble(data['lat'] ?? data['latitude']),
      longitude: asDouble(data['lon'] ?? data['lng'] ?? data['longitude']),
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
  final String? transportMode;
  final List<String>? segmentTransportModes;
  final List<String>? segmentRoutingTypes;
  final String? tripType;
  final String? experienceLevel;
  final String? difficultyLabel;
  final double? estimatedDurationMin;
  final List<String>? requiredSkills;

  TripModel({
    required this.id,
    required this.tripName,
    required this.stops,
    required this.startDate,
    required this.endDate,
    this.distance,
    this.description,
    this.participants,
    this.transportMode,
    this.segmentTransportModes,
    this.segmentRoutingTypes,
    this.tripType,
    this.experienceLevel,
    this.difficultyLabel,
    this.estimatedDurationMin,
    this.requiredSkills,
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

    List<String>? parseStringList(dynamic raw) {
      if (raw is! List) return null;
      final out = raw
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList(growable: false);
      return out.isEmpty ? null : out;
    }

    // Support both field naming conventions
    final name =
        (data['name'] ?? data['tripName'] ?? 'Untitled Trip').toString();
    final rawTransport = (data['transportMode'] ?? '').toString().trim();
    final parsedSegmentModes = parseStringList(data['segmentTransportModes']);
    final rawDistance =
        (data['totalKm'] ?? data['distance'] as num?)?.toDouble();
    final effectiveDistance = stopsList.length >= 2 ? rawDistance : null;
    final rawTripType = normalizeTripType(
      (data['tripType'] ?? '').toString(),
      transportMode: rawTransport,
      segmentTransportModes: parsedSegmentModes,
    );
    final rawExperience = normalizeTripExperienceLevel(
      (data['experienceLevel'] ?? data['experience'] ?? '').toString(),
    );
    final estimatedDurationMin =
        (data['estimatedDurationMin'] as num?)?.toDouble();
    final parsedRequiredSkills =
        parseStringList(data['requiredSkills']) ??
        parseStringList(data['required_skills']) ??
        inferTripRequiredSkills(
          tripType: rawTripType,
          segmentTransportModes: parsedSegmentModes,
        );
    final rawDifficulty =
        (data['difficultyLabel'] ?? data['difficulty'] ?? '').toString().trim();

    return TripModel(
      id: id,
      tripName: name,
      stops: stopsList,
      startDate: parseDate(data['startDate']),
      endDate: parseDate(data['endDate']),
      distance: effectiveDistance,
      description: data['description'] as String?,
      participants: List<String>.from(
        data['sharedWith'] ?? data['participants'] ?? [],
      ),
      transportMode: rawTransport.isEmpty ? null : rawTransport,
      segmentTransportModes: parsedSegmentModes,
      segmentRoutingTypes: parseStringList(data['segmentRoutingTypes']),
      tripType: rawTripType,
      experienceLevel: rawExperience.isEmpty ? null : rawExperience,
      difficultyLabel:
          rawDifficulty.isNotEmpty
              ? rawDifficulty
              : inferTripDifficultyLabel(
                tripType: rawTripType,
                experienceLevel: rawExperience,
                distanceKm: effectiveDistance,
                estimatedDurationMin: estimatedDurationMin,
                stopCount: stopsList.length,
                segmentTransportModes: parsedSegmentModes,
              ),
      estimatedDurationMin: estimatedDurationMin,
      requiredSkills: parsedRequiredSkills,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': tripName,
      'waypoints': stops.map((s) => s.toMap()).toList(),
      'startDate': startDate.toIso8601String(),
      'endDate': endDate.toIso8601String(),
      'totalKm': stops.length >= 2 ? distance : null,
      'description': description,
      'sharedWith': participants,
      if (transportMode != null) 'transportMode': transportMode,
      if (segmentTransportModes != null)
        'segmentTransportModes': segmentTransportModes,
      if (segmentRoutingTypes != null)
        'segmentRoutingTypes': segmentRoutingTypes,
      if (tripType != null) 'tripType': tripType,
      if (experienceLevel != null) 'experienceLevel': experienceLevel,
      if (difficultyLabel != null) 'difficultyLabel': difficultyLabel,
      if (estimatedDurationMin != null)
        'estimatedDurationMin': estimatedDurationMin,
      if (requiredSkills != null) 'requiredSkills': requiredSkills,
    };
  }

  int get durationDays => endDate.difference(startDate).inDays + 1;

  String get formattedDates {
    final startFmt = '${startDate.month}/${startDate.day}/${startDate.year}';
    final endFmt = '${endDate.month}/${endDate.day}/${endDate.year}';
    return '$startFmt - $endFmt';
  }
}
