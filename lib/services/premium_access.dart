import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class PremiumAccessService {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  PremiumAccessService({FirebaseFirestore? firestore, FirebaseAuth? auth})
    : _firestore = firestore ?? FirebaseFirestore.instance,
      _auth = auth ?? FirebaseAuth.instance;

  Future<bool> canAccessPremium() async {
    final user = _auth.currentUser;
    if (user == null) return false;

    // Mirror backend logic:
    // - admins/{uid} exists => admin
    // - userEntitlements/{uid} controls premium fields
    // - userEntitlements/{uid}.role/roles includes admin
    try {
      final uid = user.uid;
      final entRef = _firestore.doc('userEntitlements/$uid');
      final adminRef = _firestore.doc('admins/$uid');

      final snaps = await Future.wait([entRef.get(), adminRef.get()]);
      final entSnap = snaps[0];
      final adminSnap = snaps[1];

      if (adminSnap.exists) return true;

      final data = entSnap.data() ?? const <String, dynamic>{};

      final subscription =
          (data['subscription'] ?? '').toString().toLowerCase();
      if (subscription == 'premium') return true;

      final status =
          (data['subscriptionStatus'] ?? '').toString().toLowerCase();
      if (status == 'premium') return true;

      final role = data['role'];
      final roles = data['roles'];
      final normalizedRoles = <String>[];
      if (role is String) normalizedRoles.add(role.toLowerCase());
      if (role is List) {
        normalizedRoles.addAll(role.map((e) => e.toString().toLowerCase()));
      }
      if (roles is String) normalizedRoles.add(roles.toLowerCase());
      if (roles is List) {
        normalizedRoles.addAll(roles.map((e) => e.toString().toLowerCase()));
      }

      if (normalizedRoles.contains('admin')) return true;

      return false;
    } catch (_) {
      return false;
    }
  }
}
