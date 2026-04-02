import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
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

const int maxFileSize = 5 * 1024 * 1024; // 5MB
const int chunkMax = 800000; // 800KB per Firestore doc

class ChatMessage {
  final String id;
  final String text;
  final String senderId;
  final String senderName;
  final String senderAvatar;
  final Timestamp? timestamp;
  final bool edited;
  final String? mediaName;
  final String? mediaType;
  final int? mediaSize;
  final String? encMediaData; // inline encrypted data
  final int? mediaChunks;    // number of chunks for large files

  ChatMessage({
    required this.id,
    required this.text,
    required this.senderId,
    required this.senderName,
    required this.senderAvatar,
    this.timestamp,
    this.edited = false,
    this.mediaName,
    this.mediaType,
    this.mediaSize,
    this.encMediaData,
    this.mediaChunks,
  });

  bool get hasMedia => encMediaData != null || (mediaChunks != null && mediaChunks! > 0);
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

  static Future<String> getAnonymousUser() async {
    final credential = await _auth.signInAnonymously();
    return credential.user!.uid;
  }

  static Timestamp? _roomExpiresAt;

  static void setRoomExpiresAt(Timestamp ts) {
    _roomExpiresAt = ts;
  }

  static Timestamp _getExpiresAt() {
    return _roomExpiresAt ?? Timestamp.fromMillisecondsSinceEpoch(
      DateTime.now().millisecondsSinceEpoch + 60 * 60 * 1000,
    );
  }

  static Future<void> createRoom(String roomId, int ttlMinutes) async {
    final expiresAt = Timestamp.fromMillisecondsSinceEpoch(
      DateTime.now().millisecondsSinceEpoch + ttlMinutes * 60 * 1000,
    );
    _roomExpiresAt = expiresAt;
    await _firestore.collection('rooms').doc(roomId).set({
      'createdAt': FieldValue.serverTimestamp(),
      'ttlMinutes': ttlMinutes,
      'expiresAt': expiresAt,
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
    await _firestore.collection('rooms').doc(roomId).collection('messages').add({
      'encText': encText,
      'encName': encName,
      'senderAvatar': senderAvatar,
      'senderId': senderId,
      'timestamp': FieldValue.serverTimestamp(),
      'expiresAt': _getExpiresAt(),
    });
  }

  static Future<void> sendMediaMessage({
    required String roomId,
    required String senderId,
    required String senderName,
    required String senderAvatar,
    required String encryptionKey,
    required String mediaName,
    required String mediaType,
    required Uint8List fileData,
  }) async {
    final encName = CryptoService.encrypt(senderName, encryptionKey);
    final encMediaName = CryptoService.encrypt(mediaName, encryptionKey);
    final encText = CryptoService.encrypt('📎 $mediaName', encryptionKey);

    // Convert to base64 then encrypt
    final base64Data = base64Encode(fileData);
    final encMediaData = CryptoService.encrypt(base64Data, encryptionKey);

    final expiry = _getExpiresAt();

    if (encMediaData.length <= chunkMax) {
      // Small file — inline
      await _firestore.collection('rooms').doc(roomId).collection('messages').add({
        'encText': encText,
        'encName': encName,
        'senderAvatar': senderAvatar,
        'senderId': senderId,
        'encMediaName': encMediaName,
        'mediaType': mediaType,
        'mediaSize': fileData.length,
        'encMediaData': encMediaData,
        'timestamp': FieldValue.serverTimestamp(),
        'expiresAt': expiry,
      });
    } else {
      // Large file — chunks
      final chunks = (encMediaData.length / chunkMax).ceil();
      final msgRef = await _firestore
          .collection('rooms').doc(roomId).collection('messages').add({
        'encText': encText,
        'encName': encName,
        'senderAvatar': senderAvatar,
        'senderId': senderId,
        'encMediaName': encMediaName,
        'mediaType': mediaType,
        'mediaSize': fileData.length,
        'mediaChunks': chunks,
        'timestamp': FieldValue.serverTimestamp(),
        'expiresAt': expiry,
      });

      for (var i = 0; i < chunks; i++) {
        final start = i * chunkMax;
        final end = (start + chunkMax).clamp(0, encMediaData.length);
        await msgRef.collection('chunks').doc('$i').set({
          'data': encMediaData.substring(start, end),
          'expiresAt': expiry,
        });
      }
    }
  }

  // Load and decrypt media data
  static Future<Uint8List?> loadMediaData({
    required String roomId,
    required String messageId,
    String? encMediaData,
    int? mediaChunks,
    required String encryptionKey,
  }) async {
    try {
      String fullEncData;

      if (encMediaData != null) {
        fullEncData = encMediaData;
      } else if (mediaChunks != null && mediaChunks > 0) {
        final parts = <String>[];
        for (var i = 0; i < mediaChunks; i++) {
          final chunkSnap = await _firestore
              .collection('rooms').doc(roomId)
              .collection('messages').doc(messageId)
              .collection('chunks').doc('$i').get();
          if (chunkSnap.exists) {
            parts.add(chunkSnap.data()!['data'] as String);
          }
        }
        fullEncData = parts.join('');
      } else {
        return null;
      }

      final base64Data = CryptoService.decrypt(fullEncData, encryptionKey);
      if (base64Data == '[Decryption failed]') return null;
      return base64Decode(base64Data);
    } catch (_) {
      return null;
    }
  }

  static Future<void> editMessage({
    required String roomId,
    required String messageId,
    required String newText,
    required String encryptionKey,
  }) async {
    final encText = CryptoService.encrypt(newText, encryptionKey);
    await _firestore
        .collection('rooms').doc(roomId)
        .collection('messages').doc(messageId)
        .update({'encText': encText, 'edited': true});
  }

  static Future<void> deleteMessage(String roomId, String messageId) async {
    // Delete chunks
    final chunksSnap = await _firestore
        .collection('rooms').doc(roomId)
        .collection('messages').doc(messageId)
        .collection('chunks').get();
    for (final doc in chunksSnap.docs) {
      await doc.reference.delete();
    }
    await _firestore
        .collection('rooms').doc(roomId)
        .collection('messages').doc(messageId)
        .delete();
  }

  static Stream<List<ChatMessage>> subscribeToMessages(
    String roomId,
    String encryptionKey,
  ) {
    return _firestore
        .collection('rooms').doc(roomId)
        .collection('messages')
        .orderBy('timestamp', descending: false)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) {
        final data = doc.data();
        final text = CryptoService.decrypt(data['encText'] ?? '', encryptionKey);
        final name = CryptoService.decrypt(data['encName'] ?? '', encryptionKey);
        String? mediaName;
        if (data['encMediaName'] != null) {
          mediaName = CryptoService.decrypt(data['encMediaName'], encryptionKey);
        }
        return ChatMessage(
          id: doc.id,
          text: text,
          senderId: data['senderId'] ?? '',
          senderName: name,
          senderAvatar: data['senderAvatar'] ?? '😀',
          timestamp: data['timestamp'] as Timestamp?,
          edited: data['edited'] ?? false,
          mediaName: mediaName,
          mediaType: data['mediaType'],
          mediaSize: data['mediaSize'],
          encMediaData: data['encMediaData'],
          mediaChunks: data['mediaChunks'],
        );
      }).toList();
    });
  }

  static Future<void> deleteRoom(String roomId) async {
    final messages = await _firestore
        .collection('rooms').doc(roomId).collection('messages').get();
    for (final msgDoc in messages.docs) {
      final chunks = await msgDoc.reference.collection('chunks').get();
      for (final chunk in chunks.docs) {
        await chunk.reference.delete();
      }
      await msgDoc.reference.delete();
    }
    await _firestore.collection('rooms').doc(roomId).delete();
  }
}
