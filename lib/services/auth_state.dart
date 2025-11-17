import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class AuthState {
  AuthState._internal();
  static final AuthState instance = AuthState._internal();

  final ValueNotifier<bool> signedIn = ValueNotifier<bool>(false);

  void setSignedIn(bool v) => signedIn.value = v;

  void attachFirebaseListener() {
    FirebaseAuth.instance.authStateChanges().listen((user) {
      signedIn.value = user != null;
    });
  }
}
