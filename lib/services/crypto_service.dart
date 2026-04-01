import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:pointycastle/export.dart';

/// AES-256-GCM encryption — compatible with the Web app's crypto.ts
class CryptoService {
  static String generateKey() {
    final random = Random.secure();
    final bytes = Uint8List(32); // 256-bit key
    for (var i = 0; i < 32; i++) {
      bytes[i] = random.nextInt(256);
    }
    return _bufferToBase64url(bytes);
  }

  static String encrypt(String plaintext, String keyBase64) {
    final key = _base64urlToBuffer(keyBase64);
    final iv = _randomBytes(12);
    final plainBytes = utf8.encode(plaintext);

    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        true,
        AEADParameters(
          KeyParameter(key),
          128, // tag length in bits
          iv,
          Uint8List(0),
        ),
      );

    final output = Uint8List(cipher.getOutputSize(plainBytes.length));
    final len = cipher.processBytes(
      Uint8List.fromList(plainBytes),
      0,
      plainBytes.length,
      output,
      0,
    );
    cipher.doFinal(output, len);

    final ivStr = _bufferToBase64url(iv);
    final cipherStr = _bufferToBase64url(output);
    return '$ivStr:$cipherStr';
  }

  static String decrypt(String payload, String keyBase64) {
    try {
      final parts = payload.split(':');
      if (parts.length != 2) return '[Decryption failed]';

      final iv = _base64urlToBuffer(parts[0]);
      final cipherBytes = _base64urlToBuffer(parts[1]);
      final key = _base64urlToBuffer(keyBase64);

      final cipher = GCMBlockCipher(AESEngine())
        ..init(
          false,
          AEADParameters(
            KeyParameter(key),
            128,
            iv,
            Uint8List(0),
          ),
        );

      final output = Uint8List(cipher.getOutputSize(cipherBytes.length));
      final len =
          cipher.processBytes(cipherBytes, 0, cipherBytes.length, output, 0);
      cipher.doFinal(output, len);

      // Remove padding/tag — output contains plaintext + may have trailing zeros
      final plainLen = len + cipher.doFinal(output, len);
      return utf8.decode(output.sublist(0, plainLen - 16)); // subtract 16 byte tag
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
