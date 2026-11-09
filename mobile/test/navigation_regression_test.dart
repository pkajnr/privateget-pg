import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privateget_pg/main.dart';

void main() {
  testWidgets('Rename dialog is removed safely after Save and Cancel',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<String>(
              context: context,
              builder: (_) => const PgRenameDialog(
                initialName: 'Private chat',
              ),
            ),
            child: const Text('Rename chat'),
          ),
        ),
      ),
    ));

    for (final button in <String>['Save name', 'Cancel']) {
      await tester.tap(find.text('Rename chat'));
      await tester.pumpAndSettle();
      expect(find.byType(PgRenameDialog), findsOneWidget);
      await tester.tap(find.text(button));
      await tester.pumpAndSettle();
      expect(find.byType(PgRenameDialog), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });
}
