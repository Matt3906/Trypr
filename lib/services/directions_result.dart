class DirectionsResult {
  final List<List<double>> polylinePoints; // List of [lat, lng]
  final double distanceMeters;
  final double durationSeconds;
  final List<String> instructions;
  final List<Map<String, dynamic>> stepDetails;
  final Map<String, dynamic>? transitArrivalStop;
  final String? transitLineColor;

  const DirectionsResult({
    required this.polylinePoints,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.instructions,
    this.stepDetails = const [],
    this.transitArrivalStop,
    this.transitLineColor,
  });
}
