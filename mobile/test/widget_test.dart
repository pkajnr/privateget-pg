// PG's own tests replace Flutter's generated counter example.
// These tests do not connect to a server or send sensitive messages.
import 'package:flutter_test/flutter_test.dart';
import 'package:privateget_pg/main.dart';

void main() {
  test('PG message model records message content and direction', () {
    final outgoing = PgMessage('Hello PG', true);
    final incoming = PgMessage('Received', false);

    expect(outgoing.text, 'Hello PG');
    expect(outgoing.mine, isTrue);
    expect(incoming.text, 'Received');
    expect(incoming.mine, isFalse);
  });

  test('PG API errors have a readable message', () {
    final error = ApiException('Invitation expired');
    expect(error.toString(), 'Invitation expired');
  });
}
