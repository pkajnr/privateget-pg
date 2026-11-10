import 'package:flutter_test/flutter_test.dart';
import 'package:privateget_pg/main.dart';

void main() {
  test('PG emoji stickers round-trip through text message payloads', () {
    final payload = encodePgSticker('🥳');
    expect(payload, 'PG_STICKER:🥳');
    expect(decodePgSticker(payload), '🥳');
    expect(decodePgSticker('Ordinary message 🙂'), isNull);
    expect(decodePgSticker('PG_STICKER:untrusted'), isNull);
    expect(() => encodePgSticker('unknown'), throwsArgumentError);
  });
}
