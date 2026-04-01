import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

const _chunkSize = 65536; // 64KB chunks
const _burstChunks = 16; // Send up to 16 chunks (1MB) per burst

final _iceServers = <Map<String, dynamic>>[
  {
    'urls': ['stun:stun.l.google.com:19302', 'stun:stun1.l.google.com:19302']
  },
];

class PeerService {
  static final _firestore = FirebaseFirestore.instance;
  static final _hostedFiles = <String, Uint8List>{};
  static StreamSubscription? _hostListener;

  static void hostFile(String mediaId, Uint8List data) {
    _hostedFiles[mediaId] = data;
  }

  static void removeHostedFile(String mediaId) {
    _hostedFiles.remove(mediaId);
  }

  static void startHosting(String roomId, String userId) {
    _hostListener?.cancel();
    _hostListener = _firestore
        .collection('rooms')
        .doc(roomId)
        .collection('signals')
        .where('to', isEqualTo: userId)
        .where('type', isEqualTo: 'offer')
        .snapshots()
        .listen((snapshot) {
      for (final change in snapshot.docChanges) {
        if (change.type == DocumentChangeType.added) {
          final data = change.doc.data()!;
          _handleIncomingRequest(roomId, userId, data);
        }
      }
    });
  }

  static void stopHosting() {
    _hostListener?.cancel();
    _hostListener = null;
    _hostedFiles.clear();
  }

  static Future<void> _handleIncomingRequest(
    String roomId,
    String userId,
    Map<String, dynamic> signal,
  ) async {
    final mediaId = signal['mediaId'] as String;
    final fileData = _hostedFiles[mediaId];
    if (fileData == null) return;

    final pc = await createPeerConnection({'iceServers': _iceServers});
    final dc = await pc.createDataChannel('file', RTCDataChannelInit());

    dc.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        dc.send(RTCDataChannelMessage(jsonEncode({'size': fileData.length})));
        _sendChunks(dc, fileData);
      }
    };

    pc.onIceCandidate = (candidate) {
      _sendSignal(roomId, {
        'type': 'ice',
        'mediaId': mediaId,
        'from': userId,
        'to': signal['from'],
        'data': jsonEncode(candidate.toMap()),
      });
    };

    final offer = jsonDecode(signal['data']);
    await pc.setRemoteDescription(RTCSessionDescription(
      offer['sdp'],
      offer['type'],
    ));

    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);

    await _sendSignal(roomId, {
      'type': 'answer',
      'mediaId': mediaId,
      'from': userId,
      'to': signal['from'],
      'data': jsonEncode(answer.toMap()),
    });

    _firestore
        .collection('rooms')
        .doc(roomId)
        .collection('signals')
        .where('to', isEqualTo: userId)
        .where('from', isEqualTo: signal['from'])
        .where('type', isEqualTo: 'ice')
        .where('mediaId', isEqualTo: mediaId)
        .snapshots()
        .listen((snap) {
      for (final change in snap.docChanges) {
        if (change.type == DocumentChangeType.added) {
          final iceData = jsonDecode(change.doc.data()!['data']);
          pc.addCandidate(RTCIceCandidate(
            iceData['candidate'],
            iceData['sdpMid'],
            iceData['sdpMLineIndex'],
          ));
        }
      }
    });
  }

  /// Burst-send chunks — sends multiple chunks per tick, pauses when buffer full
  static void _sendChunks(RTCDataChannel dc, Uint8List data) {
    var offset = 0;

    void drainBuffer() {
      var sent = 0;
      while (offset < data.length && sent < _burstChunks) {
        final end = (offset + _chunkSize).clamp(0, data.length);
        dc.send(RTCDataChannelMessage.fromBinary(data.sublist(offset, end)));
        offset = end;
        sent++;
      }

      if (offset >= data.length) {
        Future.delayed(const Duration(milliseconds: 200), () => dc.close());
      } else {
        // Brief pause to let buffer drain, then send more
        Future.delayed(const Duration(milliseconds: 5), drainBuffer);
      }
    }

    drainBuffer();
  }

  static Future<void> requestFile({
    required String roomId,
    required String mediaId,
    required String senderId,
    required String myUserId,
    required void Function(int pct) onProgress,
    required void Function(Uint8List data) onComplete,
    required void Function(String err) onError,
  }) async {
    final pc = await createPeerConnection({'iceServers': _iceServers});
    var totalSize = 0;
    final chunks = <Uint8List>[];
    var received = 0;

    pc.onDataChannel = (channel) {
      channel.onMessage = (message) {
        if (message.type == MessageType.text) {
          final meta = jsonDecode(message.text);
          totalSize = meta['size'] as int;
        } else {
          chunks.add(message.binary);
          received += message.binary.length;
          onProgress(totalSize > 0 ? ((received / totalSize) * 100).round() : 0);
        }
      };

      channel.onDataChannelState = (state) {
        if (state == RTCDataChannelState.RTCDataChannelClosing ||
            state == RTCDataChannelState.RTCDataChannelClosed) {
          if (received >= totalSize && totalSize > 0) {
            final result = Uint8List(totalSize);
            var offset = 0;
            for (final chunk in chunks) {
              result.setRange(offset, offset + chunk.length, chunk);
              offset += chunk.length;
            }
            onComplete(result);
          }
        }
      };
    };

    pc.onIceCandidate = (candidate) {
      _sendSignal(roomId, {
        'type': 'ice',
        'mediaId': mediaId,
        'from': myUserId,
        'to': senderId,
        'data': jsonEncode(candidate.toMap()),
      });
    };

    _firestore
        .collection('rooms')
        .doc(roomId)
        .collection('signals')
        .where('to', isEqualTo: myUserId)
        .where('from', isEqualTo: senderId)
        .where('type', isEqualTo: 'answer')
        .where('mediaId', isEqualTo: mediaId)
        .snapshots()
        .listen((snap) {
      for (final change in snap.docChanges) {
        if (change.type == DocumentChangeType.added) {
          final answerData = jsonDecode(change.doc.data()!['data']);
          pc.setRemoteDescription(RTCSessionDescription(
            answerData['sdp'],
            answerData['type'],
          ));
        }
      }
    });

    _firestore
        .collection('rooms')
        .doc(roomId)
        .collection('signals')
        .where('to', isEqualTo: myUserId)
        .where('from', isEqualTo: senderId)
        .where('type', isEqualTo: 'ice')
        .where('mediaId', isEqualTo: mediaId)
        .snapshots()
        .listen((snap) {
      for (final change in snap.docChanges) {
        if (change.type == DocumentChangeType.added) {
          final iceData = jsonDecode(change.doc.data()!['data']);
          pc.addCandidate(RTCIceCandidate(
            iceData['candidate'],
            iceData['sdpMid'],
            iceData['sdpMLineIndex'],
          ));
        }
      }
    });

    // Create offer
    final dc = await pc.createDataChannel('file', RTCDataChannelInit());
    dc.close();

    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);

    await _sendSignal(roomId, {
      'type': 'offer',
      'mediaId': mediaId,
      'from': myUserId,
      'to': senderId,
      'data': jsonEncode(offer.toMap()),
    });

    Future.delayed(const Duration(seconds: 15), () {
      if (received == 0) {
        onError('Sender is offline');
        pc.close();
      }
    });
  }

  static Future<void> _sendSignal(
    String roomId,
    Map<String, dynamic> signal,
  ) async {
    await _firestore
        .collection('rooms')
        .doc(roomId)
        .collection('signals')
        .add(signal);
  }
}
