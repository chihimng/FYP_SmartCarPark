import firebase from 'firebase/app'
import 'firebase/firestore'
import 'firebase/auth'
import 'firebase/storage'

firebase.initializeApp({
  apiKey: 'AIzaSyCJOspIynTav487E4qnKkj-o8WHTsddGIQ',
  authDomain: 'fyp-smartcarpark.firebaseapp.com',
  databaseURL: 'https://fyp-smartcarpark.firebaseio.com',
  projectId: 'fyp-smartcarpark',
  storageBucket: 'fyp-smartcarpark.appspot.com',
  messagingSenderId: '777981643981',
  appId: '1:777981643981:web:c3b373ce798b3d7e89ad84',
  measurementId: 'G-X9BHYVJG9B'
})

// Firestore
export const db = firebase.firestore()

// Export types that exists in Firestore
// This is not always necessary, but it's used in other examples
const { Timestamp, GeoPoint } = firebase.firestore
export { Timestamp, GeoPoint }

// Auth
export const auth = firebase.auth()

// Storage
export const storage = firebase.storage()
