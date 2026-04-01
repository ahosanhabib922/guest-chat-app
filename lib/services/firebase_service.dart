import 'package:firebase_core/firebase_core.dart';

class FirebaseService {
  static Future<void> initialize() async {
    await Firebase.initializeApp(
      options: const FirebaseOptions(
        apiKey: 'AIzaSyABlFnm6_mx_dO98dl5RmwIMpe5ITmpnqY',
        authDomain: 'guestchat-922.firebaseapp.com',
        projectId: 'guestchat-922',
        storageBucket: 'guestchat-922.firebasestorage.app',
        messagingSenderId: '772731195741',
        appId: '1:772731195741:android:e88c966b15b3d0531598b4',
      ),
    );
  }
}
