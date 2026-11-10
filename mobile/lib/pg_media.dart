// PrivateGet experimental ephemeral attachment transport.
// The server receives authenticated-encryption ciphertext only.
// Opening decrypted media with another app can leave durable traces.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

const pgFilePrefix = 'PG_FILE:';
const pgFileMaxBytes = 12 * 1024 * 1024 - 16;

class PgAttachment {
  PgAttachment({
    required this.id,
    required this.name,
    required this.kind,
    required this.size,
    required this.key,
    required this.nonce,
  });
  final String id, name, kind, key, nonce;
  final int size;

  String encodeMessage() => pgFilePrefix + jsonEncode({
    'id': id, 'name': name, 'kind': kind, 'size': size,
    'key': key, 'nonce': nonce,
  });

  static PgAttachment? fromMessage(String raw) {
    if (!raw.startsWith(pgFilePrefix)) return null;
    try {
      final obj = jsonDecode(raw.substring(pgFilePrefix.length));
      if (obj is! Map<String, dynamic>) return null;
      final id = obj['id'], name = obj['name'], kind = obj['kind'];
      final key = obj['key'], nonce = obj['nonce'], size = obj['size'];
      if (id is! String || !RegExp(r'^[0-9a-f-]{36}$').hasMatch(id) ||
          name is! String || name.isEmpty || name.length > 120 ||
          kind is! String || !['image','video','document','audio'].contains(kind) ||
          key is! String || nonce is! String ||
          size is! int || size < 0 || size > pgFileMaxBytes) return null;
      if (base64Url.decode(base64Url.normalize(key)).length != 32 ||
          base64Url.decode(base64Url.normalize(nonce)).length != 12) return null;
      return PgAttachment(
        id: id, name: name, kind: kind, size: size, key: key, nonce: nonce,
      );
    } catch (_) {
      return null;
    }
  }
}

String pgSafeFilename(String source) {
  final stripped = source.split(RegExp(r'[/\\]')).last;
  final clean = stripped.replaceAll(RegExp(r'[^a-zA-Z0-9._ -]'), '_');
  return clean.isEmpty ? 'attachment.bin'
      : clean.substring(0, min(clean.length, 100));
}

String pgB64(List<int> data) => base64UrlEncode(data).replaceAll('=', '');
List<int> pgUnb64(String value) =>
    base64Url.decode(base64Url.normalize(value));

Future<PgAttachment> pgUploadEncrypted({
  required HttpClient client,
  required String apiBase,
  required String token,
  required String sessionId,
  required List<int> clearBytes,
  required String filename,
  required String kind,
}) async {
  if (clearBytes.isEmpty || clearBytes.length > pgFileMaxBytes) {
    throw StateError('File must be under 12 MB for this alpha.');
  }
  final random = Random.secure();
  final key = List<int>.generate(32, (_) => random.nextInt(256));
  final nonce = List<int>.generate(12, (_) => random.nextInt(256));
  final box = await AesGcm.with256bits().encrypt(clearBytes,
    secretKey: SecretKey(key), nonce: nonce,
    aad: utf8.encode('PG-file|$sessionId'));
  final sealed = <int>[...box.cipherText, ...box.mac.bytes];
  final request = await client.postUrl(
    Uri.parse('$apiBase/v1/sessions/$sessionId/attachments'));
  request.headers.set('Authorization', 'Bearer $token');
  request.headers.contentType = ContentType.binary;
  request.headers.set('Cache-Control', 'no-store');
  request.add(sealed);
  final response = await request.close();
  final raw = await utf8.decoder.bind(response).join();
  if (response.statusCode != 201) {
    throw StateError('Attachment relay refused upload: ${response.statusCode}');
  }
  final parsed = jsonDecode(raw);
  if (parsed is! Map<String, dynamic> || parsed['id'] is! String) {
    throw const FormatException('Unexpected attachment response');
  }
  return PgAttachment(
    id: parsed['id'] as String, name: pgSafeFilename(filename),
    kind: kind, size: clearBytes.length, key: pgB64(key),
    nonce: pgB64(nonce),
  );
}

Future<Uint8List> pgDownloadDecrypted({
  required HttpClient client,
  required String apiBase,
  required String token,
  required String sessionId,
  required PgAttachment attachment,
}) async {
  final request = await client.getUrl(Uri.parse(
    '$apiBase/v1/sessions/$sessionId/attachments/${attachment.id}'));
  request.headers.set('Authorization', 'Bearer $token');
  request.headers.set('Cache-Control', 'no-store');
  final response = await request.close();
  if (response.statusCode != 200) {
    await response.drain<void>();
    throw StateError('File unavailable or expired (${response.statusCode}).');
  }
  final data = BytesBuilder(copy: false);
  var count = 0;
  await for (final chunk in response) {
    count += chunk.length;
    if (count > pgFileMaxBytes + 16) {
      throw StateError('Encrypted file exceeded size limit.');
    }
    data.add(chunk);
  }
  final bytes = data.takeBytes();
  if (bytes.length < 17) throw const FormatException('Encrypted file corrupted');
  final nonce = pgUnb64(attachment.nonce);
  final key = pgUnb64(attachment.key);
  final plaintext = await AesGcm.with256bits().decrypt(
    SecretBox(
      bytes.sublist(0, bytes.length - 16),
      nonce: nonce,
      mac: Mac(bytes.sublist(bytes.length - 16)),
    ),
    secretKey: SecretKey(key),
    aad: utf8.encode('PG-file|$sessionId'),
  );
  if (plaintext.length != attachment.size) {
    throw StateError('Attachment length verification failed.');
  }
  return Uint8List.fromList(plaintext);
}
