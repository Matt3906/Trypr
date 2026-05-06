import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:trypr/models/trip_model.dart';

class FirestoreService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Reference to the current user's trips sub-collection.
  /// Returns null if the user is not signed in.
  CollectionReference<Map<String, dynamic>>? _userTripsRef() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return null;
    return _firestore.collection('users').doc(uid).collection('trips');
  }

  /// Fetch all trips as a stream (from the user's own trips sub-collection).
  Stream<List<TripModel>> getTripsStream() {
    final ref = _userTripsRef();
    if (ref == null) return Stream.value([]);
    return ref.orderBy('createdAt', descending: true).snapshots().asyncMap((
      snapshot,
    ) async {
      final futures = snapshot.docs.map(_tripModelForDoc).toList();
      return Future.wait(futures);
    });
  }

  Future<TripModel> _tripModelForDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) async {
    final local = doc.data();
    final tripRefPath = _tripRefPathFromData(local);
    final localWaypoints = local['waypoints'];
    final hasLocalWaypoints =
        localWaypoints is List && localWaypoints.isNotEmpty;
    final hasRoutingMetadata =
        local['transportMode'] != null ||
        local['segmentTransportModes'] is List ||
        local['segmentRoutingTypes'] is List ||
        local['routeVia'] is List;

    if (hasLocalWaypoints && (hasRoutingMetadata || tripRefPath == null)) {
      return TripModel.fromMap(local, doc.id);
    }
    if (tripRefPath == null) return TripModel.fromMap(local, doc.id);

    try {
      final remoteDoc = await _firestore.doc(tripRefPath).get();
      if (!remoteDoc.exists) return TripModel.fromMap(local, doc.id);
      final remote = remoteDoc.data() ?? <String, dynamic>{};
      final merged = Map<String, dynamic>.from(remote)..addAll(local);

      final remoteWaypoints = remote['waypoints'] ?? remote['stops'];
      if (remoteWaypoints is List && remoteWaypoints.isNotEmpty) {
        merged['waypoints'] = remoteWaypoints;
      }
      if (local['transportMode'] == null && remote['transportMode'] != null) {
        merged['transportMode'] = remote['transportMode'];
      }
      if (local['segmentTransportModes'] == null &&
          remote['segmentTransportModes'] is List) {
        merged['segmentTransportModes'] = remote['segmentTransportModes'];
      }
      if (local['segmentRoutingTypes'] == null &&
          remote['segmentRoutingTypes'] is List) {
        merged['segmentRoutingTypes'] = remote['segmentRoutingTypes'];
      }
      if (local['routeVia'] == null && remote['routeVia'] is List) {
        merged['routeVia'] = remote['routeVia'];
      }

      return TripModel.fromMap(merged, doc.id);
    } catch (_) {
      return TripModel.fromMap(local, doc.id);
    }
  }

  String? _tripRefPathFromData(Map<String, dynamic> data) {
    final raw = data['tripRef'];
    if (raw is String) {
      final v = raw.trim();
      return v.isEmpty ? null : v;
    }
    if (raw is DocumentReference) return raw.path;
    final v = raw?.toString().trim();
    if (v == null || v.isEmpty) return null;
    return v;
  }

  /// Fetch a single trip by ID
  Future<TripModel?> getTripById(String tripId) async {
    try {
      final ref = _userTripsRef();
      if (ref == null) return null;
      final doc = await ref.doc(tripId).get();
      if (doc.exists) {
        return TripModel.fromFirestore(doc);
      }
      return null;
    } catch (e) {
      debugPrint('Error fetching trip: $e');
      return null;
    }
  }

  /// Create a new trip
  Future<String> createTrip(TripModel trip) async {
    try {
      final ref = _userTripsRef();
      if (ref == null) throw Exception('User not signed in');
      final docRef = await ref.add(trip.toMap());
      return docRef.id;
    } catch (e) {
      debugPrint('Error creating trip: $e');
      rethrow;
    }
  }

  /// Update an existing trip
  Future<void> updateTrip(String tripId, TripModel trip) async {
    try {
      final ref = _userTripsRef();
      if (ref == null) throw Exception('User not signed in');
      await ref.doc(tripId).update(trip.toMap());
    } catch (e) {
      debugPrint('Error updating trip: $e');
      rethrow;
    }
  }

  /// Delete a trip
  Future<void> deleteTrip(String tripId) async {
    try {
      final ref = _userTripsRef();
      if (ref == null) throw Exception('User not signed in');
      await ref.doc(tripId).delete();
    } catch (e) {
      debugPrint('Error deleting trip: $e');
      rethrow;
    }
  }
}
