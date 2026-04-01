import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'crypto_service.dart';

const List<String> avatars = [
  '😀', '😎', '🤖', '👻', '🦊', '🐱', '🐸', '🦄', '🐼', '🐵', '🦁', '🐯'
];

const List<Map<String, dynamic>> ttlOptions = [
  {'label': '15 min', 'value': 15},
  {'label': '30 min', 'value': 30},
  {'label': '1 hour', 'value': 60},
  {'label': '6 hours', 'value': 360},
  {'label': '24 hours', 'value': 1440},
];

class ChatMessage {
  final String id;
  final String text;
  final String senderId;
  final String senderName;
  final String senderAvatar;
  final Timestamp? timestamp;
  final bool edited;
  // Media fields
  final String? mediaId;
  final String? mediaName;
  final String? mediaType;
  final int? mediaSize;

  ChatMessage({
    required this.id,
    required this.text,
    required this.senderId,
    required this.senderName,
    required this.senderAvatar,
    this.timestamp,
    this.edited = false,
    this.mediaId,
    this.mediaName,
    this.mediaType,
    this.mediaSize,
  });
}

class ChatService {
  static final _firestore = FirebaseFirestore.instance;
  static final _auth = FirebaseAuth.instance;

  static String generateRoomCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final random = Random.secure();
    return String.fromCharCodes(
      List.generate(6, (_) => chars.codeUnitAt(random.nextInt(chars.length))),
    );
  }

  static String generateMediaId() {
    final random = Random.secure();
    final suffix = List.generate(6, (_) => random.nextInt(36))
        .map((n) => n < 10 ? '$n' : String.fromCharCode(97 + n - 10))
        .join();
    return 'media-${DateTime.now().millisecondsSinceEpoch}-$suffix';
  }

  static Future<String> getAnonymousUser() async {
    final credential = await _auth.signInAnonymously();
    return credential.user!.uid;
  }

  static Future<void> createRoom(String roomId, int ttlMinutes) async {
    await _firestore.collection('rooms').doc(roomId).set({
      'createdAt': FieldValue.serverTimestamp(),
      'ttlMinutes': ttlMinutes,
    });
  }

  static Future<Map<String, dynamic>?> getRoomInfo(String roomId) async {
    final snap = await _firestore.collection('rooms').doc(roomId).get();
    if (!snap.exists) return null;
    return snap.data();
  }

  static Future<void> sendMessage({
    required String roomId,
    required String text,
    required String senderId,
    required String senderName,
    required String senderAvatar,
    required String encryptionKey,
  }) async {
    final encText = CryptoService.encrypt(text, encryptionKey);
    final encName = CryptoService.encrypt(senderName, encryptionKey);
    await _firestore
        .collection('rooms')
        .doc(roomId)
        .collection('messages')
        .add({
      'encText': encText,
      'encName': encName,
      'senderAvatar': senderAvatar,
      'senderId': senderId,
      'timestamp': FieldValue.serverTimestamp(),
    });
  }

  static Future<void> sendMediaMessage({
    required String roomId,
    required String senderId,
    required String senderName,
    required String senderAvatar,
    required String encryptionKey,
    required String mediaId,
    required String mediaName,
    required String mediaType,
    required int mediaSize,
  }) async {
    final encName = CryptoService.encrypt(senderName, encryptionKey);
    final encMediaName = CryptoService.encrypt(mediaName, encryptionKey);
    final encText = CryptoService.encrypt('📎 $mediaName', encryptionKey);
    await _firestore
        .collection('rooms')
        .doc(roomId)
        .collection('messages')
        .add({
      'encText': encText,
      'encName': encName,
      'senderAvatar': senderAvatar,
      'senderId': senderId,
      'mediaId': mediaId,
      'encMediaName': encMediaName,
      'mediaType': mediaType,
      'mediaSize': mediaSize,
      'timestamp': FieldValue.serverTimestamp(),
    });
  }

  static Future<void> editMessage({
    required String roomId,
    required String messageId,
    required String newText,
    required String encryptionKey,
  }) async {
    final encText = CryptoService.encrypt(newText, encryptionKey);
    await _firestore
        .collection('rooms')
        .doc(roomId)
        .collection('messages')
        .doc(messageId)
        .update({
      'encText': encText,
      'edited': true,
    });
  }

  static Future<void> deleteMessage(String roomId, String messageId) async {
    await _firestore
        .collection('rooms')
        .doc(roomId)
        .collection('messages')
        .doc(messageId)
        .delete();
  }

  static Stream<List<ChatMessage>> subscribeToMessages(
    String roomId,
    String encryptionKey,
  ) {
    return _firestore
        .collection('rooms')
        .doc(roomId)
        .collection('messages')
        .orderBy('timestamp', descending: false)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) {
        final data = doc.data();
        final text = CryptoService.decrypt(
          data['encText'] ?? '',
          encryptionKey,
        );
        final name = CryptoService.decrypt(
          data['encName'] ?? '',
          encryptionKey,
        );
        String? mediaName;
        if (data['encMediaName'] != null) {
          mediaName = CryptoService.decrypt(
            data['encMediaName'],
            encryptionKey,
          );
        }
        return ChatMessage(
          id: doc.id,
          text: text,
          senderId: data['senderId'] ?? '',
          senderName: name,
          senderAvatar: data['senderAvatar'] ?? '😀',
          timestamp: data['timestamp'] as Timestamp?,
          edited: data['edited'] ?? false,
          mediaId: data['mediaId'],
          mediaName: mediaName,
          mediaType: data['mediaType'],
          mediaSize: data['mediaSize'],
        );
      }).toList();
    });
  }

  static Future<void> deleteRoom(String roomId) async {
    // Delete messages
    final messages = await _firestore
        .collection('rooms')
        .doc(roomId)
        .collection('messages')
        .get();
    for (final doc in messages.docs) {
      await doc.reference.delete();
    }
    // Delete signals
    final signals = await _firestore
        .collection('rooms')
        .doc(roomId)
        .collection('signals')
        .get();
    for (final doc in signals.docs) {
      await doc.reference.delete();
    }
    // Delete room
    await _firestore.collection('rooms').doc(roomId).delete();
  }
}
