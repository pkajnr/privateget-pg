import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privateget_pg/pg_lock.dart';

void main() {
  test('PG locks on background and hide, not brief inactive states', () {
    expect(pgNeedsLockOnLifecycle(AppLifecycleState.paused), isTrue);
    expect(pgNeedsLockOnLifecycle(AppLifecycleState.hidden), isTrue);
    expect(pgNeedsLockOnLifecycle(AppLifecycleState.detached), isTrue);
    expect(pgNeedsLockOnLifecycle(AppLifecycleState.inactive), isFalse);
    expect(pgNeedsLockOnLifecycle(AppLifecycleState.resumed), isFalse);
  });

  test('PG app lock has a dedicated non-cryptographic setting name', () {
    expect(pgAppLockPreference, 'pg_device_app_lock_enabled_v1');
  });
}
