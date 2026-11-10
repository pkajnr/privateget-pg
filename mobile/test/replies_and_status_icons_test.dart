import 'package:flutter_test/flutter_test.dart';
import 'package:privateget_pg/main.dart';

void main() {
  test('PG replies encrypt a bounded quote and render on recipient', () {
    final wire = encodePgReply('Yes, confirmed.', 'Meeting on Friday', false);
    expect(wire, startsWith(pgReplyMarker));
    final decoded = decodePgReply(wire)!;
    expect(decoded.message, 'Yes, confirmed.');
    expect(decoded.quoted, 'Meeting on Friday');
    expect(decoded.quotedFromSender, isFalse);

    final sender = PgMessage.fromWire(wire, true);
    expect(sender.quotedText, 'Meeting on Friday');
    expect(sender.quotedMine, isFalse);
    final recipient = PgMessage.fromWire(wire, false);
    expect(recipient.text, 'Yes, confirmed.');
    expect(recipient.quotedMine, isTrue);
    expect(recipient.quotedText, 'Meeting on Friday');
  });

  test('Legacy plain chat and malformed reply payload still render', () {
    final legacy = PgMessage.fromWire('Ordinary PG text', false);
    expect(legacy.text, 'Ordinary PG text');
    expect(legacy.quotedText, isNull);
    expect(decodePgReply(pgReplyMarker + '{invalid-json'), isNull);
    expect(() => encodePgReply('Hello', '', false), throwsArgumentError);
    expect(() => encodePgReply(List<String>.filled(1500, 'X').join(), 'Test', false),
      throwsArgumentError);
  });

  test('All five PG-exclusive status symbols round trip by ID', () {
    const ids = <String>[
      'contract_agreed','date_fixed','terms_agreed','on_the_move','eating',
    ];
    expect(pgStatusIcons.map((s) => s.id).toList(), ids);
    for (final id in ids) {
      final encoded = encodePgStatus(id);
      final decoded = decodePgStatus(encoded);
      expect(decoded?.id, id);
      expect(decoded?.label.isNotEmpty, isTrue);
    }
    expect(decodePgStatus('Ordinary text'), isNull);
    expect(decodePgStatus(pgStatusMarker + 'bogus'), isNull);
    expect(() => encodePgStatus('bogus'), throwsArgumentError);
  });
}
