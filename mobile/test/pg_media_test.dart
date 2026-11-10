import 'package:flutter_test/flutter_test.dart';
import 'package:privateget_pg/pg_media.dart';

void main() {
  test('Attachment metadata round-trips through encrypted chat marker', () {
    final item = PgAttachment(
      id: '12345678-1234-4000-8000-123456789abc',
      name: 'photo.jpg', kind: 'image', size: 1024,
      key: pgB64(List<int>.filled(32, 7)),
      nonce: pgB64(List<int>.filled(12, 9)),
    );
    final recreated = PgAttachment.fromMessage(item.encodeMessage());
    expect(recreated, isNotNull);
    expect(recreated!.name, 'photo.jpg');
    expect(recreated.id, item.id);
    expect(recreated.size, 1024);
    expect(recreated.kind, 'image');
  });

  test('Reject malformed media metadata and sanitize names', () {
    expect(PgAttachment.fromMessage('normal chat'), isNull);
    expect(PgAttachment.fromMessage('PG_FILE:invalid'), isNull);
    expect(pgSafeFilename('../private-photo.jpg'), 'private-photo.jpg');
    expect(pgSafeFilename('foo/bar.pdf'), 'bar.pdf');
    expect(pgSafeFilename(''), 'attachment.bin');
    expect(pgFileMaxBytes, lessThan(12 * 1024 * 1024));
  });
}
