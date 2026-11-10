// PG optional device-credential app lock for the experimental alpha.
// This is a UI access barrier, NOT a substitute for vetted E2EE or a
// hardware-backed encryption key protecting the actual conversation state.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

const pgAppLockPreference = 'pg_device_app_lock_enabled_v1';

// Restrict which lifecycle transitions force a new phone-unlock challenge.
// "inactive" can occur while Android's biometric dialog is being displayed.
bool pgNeedsLockOnLifecycle(AppLifecycleState state) =>
    state == AppLifecycleState.hidden ||
    state == AppLifecycleState.paused ||
    state == AppLifecycleState.detached;

typedef PgLockContentBuilder = Widget Function(
  BuildContext context,
  bool lockEnabled,
  Future<bool> Function(bool enabled) changeLock,
);

class PgLockShell extends StatefulWidget {
  const PgLockShell({super.key, required this.builder});
  final PgLockContentBuilder builder;

  @override
  State<PgLockShell> createState() => _PgLockShellState();
}

class _PgLockShellState extends State<PgLockShell>
    with WidgetsBindingObserver {
  final LocalAuthentication _deviceAuth = LocalAuthentication();
  final SharedPreferencesAsync _preferences = SharedPreferencesAsync();

  bool _loaded = false;
  bool _enabled = false;
  bool _locked = true;
  bool _authenticating = false;
  bool _pendingResumeUnlock = false;
  String? _unlockError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadConfiguration());
  }

  Future<void> _loadConfiguration() async {
    bool enabled = false;
    try {
      enabled = await _preferences.getBool(pgAppLockPreference) ?? false;
    } catch (_) {
      // Fail closed when a previously activated lock cannot be read reliably:
      // there is no safe way to know that it was enabled, so report this as a
      // configuration failure, not as successful protection.
      if (mounted) {
        setState(() {
          _loaded = true;
          _enabled = true;
          _locked = true;
          _unlockError = 'Could not read app-lock settings. '
              'Restart PG or check your phone settings.';
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _loaded = true;
      _enabled = enabled;
      _locked = enabled;
    });
    if (enabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_unlock());
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_loaded || !_enabled || _authenticating) return;
    if (pgNeedsLockOnLifecycle(state)) {
      // Keep chat state in memory to preserve live sessions. Render an opaque
      // access barrier immediately on return, and forbid input underneath.
      if (!_locked && mounted) setState(() => _locked = true);
      _pendingResumeUnlock = true;
    } else if (state == AppLifecycleState.resumed &&
        _pendingResumeUnlock && _locked) {
      _pendingResumeUnlock = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _locked && !_authenticating) unawaited(_unlock());
      });
    }
  }

  Future<void> _unlock() async {
    if (!_loaded || !_enabled || !_locked || _authenticating) return;
    _authenticating = true;
    try {
      final supported = await _deviceAuth.isDeviceSupported();
      if (!supported) {
        if (mounted) {
          setState(() => _unlockError =
              'Set up a fingerprint, face unlock, or device screen lock '
              'in Android settings to unlock PG.');
        }
        return;
      }
      final result = await _deviceAuth.authenticate(
        localizedReason: 'Unlock PG with your phone security',
        biometricOnly: false,
        persistAcrossBackgrounding: true,
      );
      if (mounted) {
        setState(() {
          _locked = !result;
          _unlockError = result ? null : 'PG is still locked.';
        });
      }
    } on PlatformException {
      if (mounted) {
        setState(() => _unlockError =
            'Could not use the phone security prompt. Retry unlocking PG.');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _unlockError =
            'Device authentication is unavailable right now.');
      }
    } finally {
      _authenticating = false;
    }
  }

  Future<bool> _changeLock(bool enabled) async {
    if (!_loaded || _authenticating) return false;
    if (_enabled == enabled) return true;

    _authenticating = true;
    try {
      // Require an OS credential challenge to enable OR disable protection.
      if (!await _deviceAuth.isDeviceSupported()) return false;
      final authorized = await _deviceAuth.authenticate(
        localizedReason: enabled
            ? 'Verify your phone security to turn on PG App Lock'
            : 'Verify your phone security to turn off PG App Lock',
        biometricOnly: false,
        persistAcrossBackgrounding: true,
      );
      if (!authorized || !mounted) return false;
      await _preferences.setBool(pgAppLockPreference, enabled);
      if (!mounted) return false;
      setState(() {
        _enabled = enabled;
        _locked = false;
        _unlockError = null;
      });
      return true;
    } catch (_) {
      return false;
    } finally {
      _authenticating = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(
        backgroundColor: Color(0xFF081322),
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final showLock = _enabled && _locked;
    return PopScope<void>(
      canPop: !showLock,
      child: Stack(children: [
        AbsorbPointer(
          absorbing: showLock,
          child: ExcludeSemantics(
            excluding: showLock,
            child: widget.builder(context, _enabled, _changeLock),
          ),
        ),
        if (showLock)
          Positioned.fill(child: Material(
            color: const Color(0xFF081322),
            child: SafeArea(child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.security_rounded,
                      size: 82, color: Color(0xFFFFB340)),
                    const SizedBox(height: 16),
                    const Text('PG is locked',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white,
                        fontSize: 26, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 12),
                    const Text(
                      'Use your fingerprint, face unlock, or phone PIN, '
                      'pattern or password to continue.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xFFB8C8D6),
                        fontSize: 14, height: 1.5)),
                    if (_unlockError != null) ...[
                      const SizedBox(height: 14),
                      Text(_unlockError!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Color(0xFFFF8990), fontSize: 12)),
                    ],
                    const SizedBox(height: 26),
                    FilledButton.icon(
                      onPressed: _authenticating ? null : _unlock,
                      icon: const Icon(Icons.fingerprint),
                      label: Text(_authenticating ? 'Unlocking…' : 'Unlock PG'),
                    ),
                  ]),
                ),
              ),
            )),
          )),
      ]),
    );
  }
}
