import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:pointycastle/export.dart';

/// AES-256-GCM encryption — compatible with the Web app's crypto.ts
class CryptoService {
  static String generateKey() {
    final random = Random.secure();
    final bytes = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      bytes[i] = random.nextInt(256);
    }
    return _bufferToBase64url(bytes);
  }

  static String encrypt(String plaintext, String keyBase64) {
    final key = _base64urlToBuffer(keyBase64);
    final iv = _randomBytes(12);
    final plainBytes = Uint8List.fromList(utf8.encode(plaintext));

    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        true,
        AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)),
      );

    final output = Uint8List(cipher.getOutputSize(plainBytes.length));
    var offset = cipher.processBytes(plainBytes, 0, plainBytes.length, output, 0);
    offset += cipher.doFinal(output, offset);

    final ivStr = _bufferToBase64url(iv);
    final cipherStr = _bufferToBase64url(Uint8List.view(output.buffer, 0, offset));
    return '$ivStr:$cipherStr';
  }

  static String decrypt(String payload, String keyBase64) {
    try {
      final idx = payload.indexOf(':');
      if (idx == -1) return '[Decryption failed]';

      final iv = _base64urlToBuffer(payload.substring(0, idx));
      final cipherBytes = _base64urlToBuffer(payload.substring(idx + 1));
      final key = _base64urlToBuffer(keyBase64);

      final cipher = GCMBlockCipher(AESEngine())
        ..init(
          false,
          AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)),
        );

      final output = Uint8List(cipher.getOutputSize(cipherBytes.length));
      var offset = cipher.processBytes(cipherBytes, 0, cipherBytes.length, output, 0);
      offset += cipher.doFinal(output, offset);

      return utf8.decode(Uint8List.view(output.buffer, 0, offset));
    } catch (_) {
      return '[Decryption failed]';
    }
  }

  static Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List.generate(length, (_) => random.nextInt(256)),
    );
  }

  static String _bufferToBase64url(Uint8List bytes) {
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static Uint8List _base64urlToBuffer(String base64url) {
    String padded = base64url;
    final remainder = padded.length % 4;
    if (remainder != 0) {
      padded += '=' * (4 - remainder);
    }
    return base64Url.decode(padded);
  }
}
