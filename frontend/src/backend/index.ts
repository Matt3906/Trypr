/** Single entry point for backend access (replaces the old firebase.ts). */
import { getFirestore } from './firestore'
import { getFunctions } from './functions'
import { getStorage } from './storage'

export { auth } from './auth'
export const db = getFirestore()
export const storage = getStorage()
export const functions = getFunctions()
