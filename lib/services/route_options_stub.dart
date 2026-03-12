class TravelRouteOption {
  final String mode;
  final String summary;
  final double distanceMeters;
  final double durationSeconds;
  final int transferCount;
  final int layoverCount;
  final double layoverMinutes;
  final String departureTimeText;
  final String arrivalTimeText;
  final List<String> instructions;
  final String? transitLineColor;
  final Map<String, dynamic>? transitArrivalStop;

  const TravelRouteOption({
    required this.mode,
    required this.summary,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.transferCount,
    required this.layoverCount,
    required this.layoverMinutes,
    required this.departureTimeText,
    required this.arrivalTimeText,
    required this.instructions,
    this.transitLineColor,
    this.transitArrivalStop,
  });

  Map<String, dynamic> toMap() {
    return {
      'mode': mode,
      'summary': summary,
      'distanceMeters': distanceMeters,
      'durationSeconds': durationSeconds,
      'transferCount': transferCount,
      'layoverCount': layoverCount,
      'layoverMinutes': layoverMinutes,
      'departureTimeText': departureTimeText,
      'arrivalTimeText': arrivalTimeText,
      'instructions': instructions,
      if (transitLineColor != null) 'transitLineColor': transitLineColor,
      if (transitArrivalStop != null) 'transitArrivalStop': transitArrivalStop,
    };
  }
}

Future<List<TravelRouteOption>> getRouteOptions({
  required double originLat,
  required double originLng,
  required double destLat,
  required double destLng,
  required String mode,
  DateTime? departureTime,
  bool avoidHighways = false,
  bool avoidTolls = false,
  int maxOptions = 4,
}) async {
  return const <TravelRouteOption>[];
}
