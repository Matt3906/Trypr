import { initializeApp } from 'firebase/app'
import { initializeAppCheck, ReCaptchaV3Provider } from 'firebase/app-check'
import { connectAuthEmulator, getAuth } from 'firebase/auth'
import { connectFirestoreEmulator, getFirestore } from 'firebase/firestore'
import { connectFunctionsEmulator, getFunctions } from 'firebase/functions'
import { connectStorageEmulator, getStorage } from 'firebase/storage'
import { config, firebaseOptions } from './config'

const LOCAL_HOST = '127.0.0.1'

export const app = initializeApp(firebaseOptions)
export const auth = getAuth(app)
export const db = getFirestore(app)
export const storage = getStorage(app)
export const functions = getFunctions(app, config.functionsRegion)

function shouldUseEmulators(): boolean {
  if (!config.useFirebaseEmulators) return false
  const host = window.location.hostname.toLowerCase()
  return host === 'localhost' || host === '127.0.0.1' || host === '::1'
}

if (shouldUseEmulators()) {
  connectAuthEmulator(auth, `http://${LOCAL_HOST}:9099`)
  connectFirestoreEmulator(db, LOCAL_HOST, 8080)
  connectStorageEmulator(storage, LOCAL_HOST, 9199)
  connectFunctionsEmulator(functions, LOCAL_HOST, 5001)
} else if (config.recaptchaSiteKey) {
  // App Check is only activated when a reCAPTCHA site key is configured.
  try {
    initializeAppCheck(app, {
      provider: new ReCaptchaV3Provider(config.recaptchaSiteKey),
      isTokenAutoRefreshEnabled: true,
    })
  } catch (e) {
    console.warn('AppCheck activation failed', e)
  }
}
