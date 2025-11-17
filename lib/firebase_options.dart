// GENERATED FILE — use `flutterfire configure` to regenerate
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) return web;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
        // For non-web platforms the default initialization (without options)
        // should be used if you configure platform files. Return `null`-equivalent by
        // throwing to signal the caller to use default initializeApp().
        throw UnsupportedError(
          'DefaultFirebaseOptions are only configured for Web in this project.',
        );
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyCV43kvtfDcmmikbLqC5TXEHJAnupZt-lA',
    authDomain: 'trypr-5ee47.firebaseapp.com',
    projectId: 'trypr-5ee47',
    storageBucket: 'trypr-5ee47.firebasestorage.app',
    messagingSenderId: '39789168828',
    appId: '1:39789168828:web:35dc72dce890271c9e68b9',
    measurementId: 'G-1KRHR1T6D2',
  );
}
