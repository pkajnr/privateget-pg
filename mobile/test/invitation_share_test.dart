import 'package:flutter_test/flutter_test.dart';
import 'package:privateget_pg/main.dart';

void main() {
  test('Invitation share text includes one-time code and join steps', () {
    const code = 'PG-TEST-ONE-TIME-CODE-12345';
    final text = buildInvitationShareText(code);

    expect(text, contains('PrivateGet (PG)'));
    expect(text, contains('Join a conversation'));
    expect(text, contains(code));
    expect(text, contains('expires after 10 minutes'));
    expect(text, contains('Please do not forward'));
    expect(text, isNot(contains('http://')));
  });
}
