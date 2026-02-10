import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
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
    return ref
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) {
          return snapshot.docs
              .map((doc) => TripModel.fromFirestore(doc))
              .toList();
        });
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
      print('Error fetching trip: $e');
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
      print('Error creating trip: $e');
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
      print('Error updating trip: $e');
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
      print('Error deleting trip: $e');
      rethrow;
    }
  }
}
