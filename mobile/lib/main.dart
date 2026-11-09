// PrivateGet PG – actual two-device networked ALPHA (not a simulation).
// Run with --dart-define=PG_API_URL=http://YOUR_LAN_IP:8787
// SECURITY: The message construction here is experimental and NOT audited.
// Do not use for sensitive conversations or production deployment.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _apiBase = String.fromEnvironment('PG_API_URL', defaultValue: 'http://10.0.2.2:8787');
const _bg = Color(0xFF0B1523);
const _surface = Color(0xFF17283B);
const _field = Color(0xFF0E2032);
const _stroke = Color(0xFF324457);
const _orange = Color(0xFFFFA51F);
const _teal = Color(0xFF54D7B2);
const _danger = Color(0xFFFF8990);
const _muted = Color(0xFFAFBDCB);
const _white = Color(0xFFF3F7FC);

void main() => runApp(const PgApp());

class PgApp extends StatelessWidget {
  const PgApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'PrivateGet · PG',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: _bg,
      colorScheme: ColorScheme.fromSeed(
        seedColor: _orange, brightness: Brightness.dark, surface: _surface),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: _field,
        hintStyle: const TextStyle(color: _muted, fontSize: 13),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _stroke),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _stroke),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _orange, width: 1.5),
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: _bg, surfaceTintColor: Colors.transparent),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: _surface,
        contentTextStyle: TextStyle(color: _white),
      ),
    ),
    home: const PgHome(),
  );
}

class PgMessage {
  final String text;
  final bool mine;
  PgMessage(this.text, this.mine);
}

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}

class PgHome extends StatefulWidget {
  const PgHome({super.key});
  @override
  State<PgHome> createState() => _PgHomeState();
}

class _PgHomeState extends State<PgHome> {
  final _inviteInput = TextEditingController();
  final _messageInput = TextEditingController();
  final _scroll = ScrollController();
  final _messages = <PgMessage>[];
  final _keyExchange = X25519();
  final _cipher = AesGcm.with256bits();
  HttpClient? _http;
  Timer? _ticker;
  bool _busy = false;
  bool _polling = false;
  String _page = 'home';
  String? _token, _deviceId, _inviteId, _inviteCode, _sessionId, _role, _safetyCode;
  String? _error;
  String _sessionState = '';
  KeyPair? _pair;
  SimplePublicKey? _myPublicKey;
  SecretKey? _sendKey, _receiveKey;
  bool _ending = false;

  @override
  void initState() {
    super.initState();
    _http = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    _register();
    _ticker = Timer.periodic(const Duration(milliseconds: 1100), (_) => _tick());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _http?.close(force: true);
    _inviteInput.dispose();
    _messageInput.dispose();
    _scroll.dispose();
    _eraseLocal();
    super.dispose();
  }

  void _setError(Object err) {
    if (!mounted) return;
    setState(() => _error = err.toString());
  }

  Future<Map<String, dynamic>> _request(String method, String path, [Map<String, dynamic>? body]) async {
    final uri = Uri.parse('$_apiBase$path');
    final request = await _http!.openUrl(method, uri).timeout(const Duration(seconds: 7));
    request.headers.set('Accept', 'application/json');
    request.headers.set('Cache-Control', 'no-store');
    if (_token != null) request.headers.set('Authorization', 'Bearer $_token');
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(const Duration(seconds: 7));
    final raw = await utf8.decoder.bind(response).join();
    final result = jsonDecode(raw) as Map<String, dynamic>;
    if (response.statusCode >= 400) throw ApiException('${response.statusCode}: ${result['error'] ?? 'Request failed'}');
    return result;
  }

  Future<void> _register() async {
    try {
      final data = await _request('POST', '/v1/devices', {});
      if (!mounted) return;
      setState(() { _token = data['token'] as String; _deviceId = data['deviceId'] as String; _error = null; });
    } catch (e) { _setError('Cannot connect to PG server at $_apiBase. $e'); }
  }

  Future<void> _preparePair() async {
    _pair = await _keyExchange.newKeyPair();
    _myPublicKey = await _pair!.extractPublicKey() as SimplePublicKey;
  }

  String _b64(List<int> data) => base64UrlEncode(data).replaceAll('=', '');
  List<int> _bytes(String s) => base64Url.decode(base64Url.normalize(s));

  Future<void> _createInvite() async {
    if (_busy || _token == null) return;
    setState(() { _busy = true; _error = null; });
    try {
      await _preparePair();
      final result = await _request('POST', '/v1/invites', { 'publicKey': _b64(_myPublicKey!.bytes) });
      if (!mounted) return;
      setState(() {
        _inviteId = result['id'] as String;
        _inviteCode = result['code'] as String;
        _role = 'A';
        _page = 'inviting';
      });
    } catch (e) { _setError(e); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _acceptInvite() async {
    if (_busy || _token == null) return;
    final code = _inviteInput.text.trim();
    if (code.length < 20) { _setError('Paste a full invitation code.'); return; }
    setState(() { _busy = true; _error = null; });
    try {
      await _preparePair();
      final response = await _request('POST', '/v1/invites/accept', {
        'code': code,
        'publicKey': _b64(_myPublicKey!.bytes),
      });
      if (!mounted) return;
      setState(() {
        _role = 'B';
        _sessionId = response['sessionId'] as String;
        _sessionState = 'awaiting_approval';
        _inviteInput.clear();
        _page = 'waiting';
      });
      await _fetchSession();
    } catch (e) { _setError(e); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _tick() async {
    if (_polling || _token == null || !mounted || _ending) return;
    if (_page != 'inviting' && _page != 'waiting' && _page != 'chat') return;
    _polling = true;
    try {
      if (_page == 'inviting' && _inviteId != null) {
        final invite = await _request('GET', '/v1/invites/$_inviteId');
        if (invite['state'] == 'expired') { await _stopToHome(); _setError('Invitation expired. Create a new one.'); return; }
        if (invite['sessionId'] is String) {
          _sessionId = invite['sessionId'] as String;
          if (mounted) setState(() => _page = 'waiting');
        }
      }
      if (_sessionId != null) await _fetchSession();
      if (_page == 'chat' && _sessionId != null) await _pollMessages();
    } catch (e) {
      // Network faults are shown without closing local session; do not treat an outage as verified deletion.
      _setError(e);
    } finally { _polling = false; }
  }

  Future<void> _fetchSession() async {
    final id = _sessionId;
    if (id == null) return;
    final result = await _request('GET', '/v1/sessions/$id');
    final state = result['state'] as String;
    if (state == 'ended') {
      if (mounted) setState(() { _eraseLocal(); _page = 'ended'; _error = null; });
      return;
    }
    if (!mounted) return;
    final peerKey = result['peerKey'];
    if (peerKey is String && _sendKey == null && _pair != null) await _establishKeys(peerKey);
    setState(() {
      _sessionState = state;
      if (state == 'active' && _sendKey != null) _page = 'chat';
      else _page = 'waiting';
    });
  }

  Future<void> _establishKeys(String peer64) async {
    final peerPublic = SimplePublicKey(_bytes(peer64), type: KeyPairType.x25519);
    final shared = await _keyExchange.sharedSecretKey(keyPair: _pair!, remotePublicKey: peerPublic);
    final sessionBytes = utf8.encode(_sessionId!);
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final ab = await hkdf.deriveKey(secretKey: shared, nonce: sessionBytes, info: utf8.encode('PG-alpha-A-to-B'));
    final ba = await hkdf.deriveKey(secretKey: shared, nonce: sessionBytes, info: utf8.encode('PG-alpha-B-to-A'));
    _sendKey = _role == 'A' ? ab : ba;
    _receiveKey = _role == 'A' ? ba : ab;
    final pubA = _role == 'A' ? _myPublicKey!.bytes : peerPublic.bytes;
    final pubB = _role == 'B' ? _myPublicKey!.bytes : peerPublic.bytes;
    final hash = await Sha256().hash([...utf8.encode('PG-alpha-safety'), ...sessionBytes, ...pubA, ...pubB]);
    final code = hash.bytes.take(6).map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
    if (mounted) setState(() => _safetyCode = '${code.substring(0,4)} ${code.substring(4,8)} ${code.substring(8,12)}');
  }

  Future<void> _approve() async {
    if (_busy || _sessionId == null) return;
    setState(() { _busy = true; _error = null; });
    try { await _request('POST', '/v1/sessions/$_sessionId/approve', {}); await _fetchSession(); }
    catch (e) { _setError(e); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _sendMessage() async {
    if (_busy || _sendKey == null || _sessionId == null || _page != 'chat') return;
    final text = _messageInput.text.trim();
    if (text.isEmpty || text.length > 2000) return;
    final sendingSession = _sessionId;
    setState(() { _busy = true; _error = null; });
    try {
      final rand = Random.secure();
      final nonce = List<int>.generate(12, (_) => rand.nextInt(256));
      final aad = utf8.encode('PG|$_sessionId|$_role');
      final box = await _cipher.encrypt(utf8.encode(text), secretKey: _sendKey!, nonce: nonce, aad: aad);
      await _request('POST', '/v1/sessions/$_sessionId/messages', {
        'iv': _b64(box.nonce), 'ciphertext': _b64(box.cipherText), 'mac': _b64(box.mac.bytes),
      });
      if (!mounted || _page != 'chat' || sendingSession != _sessionId) return;
      setState(() { _messages.add(PgMessage(text, true)); _messageInput.clear(); });
      _scrollDown();
    } catch (e) { _setError(e); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _pollMessages() async {
    if (_receiveKey == null || _sessionId == null) return;
    final readingSession = _sessionId;
    final answer = await _request('GET', '/v1/sessions/$_sessionId/messages');
    final items = (answer['messages'] as List<dynamic>?) ?? [];
    if (items.isEmpty) return;
    final newItems = <PgMessage>[];
    for (final item in items) {
      try {
        final m = item as Map<String, dynamic>;
        final opposite = _role == 'A' ? 'B' : 'A';
        final box = SecretBox(_bytes(m['ciphertext'] as String),
          nonce: _bytes(m['iv'] as String), mac: Mac(_bytes(m['mac'] as String)));
        final clear = await _cipher.decrypt(box, secretKey: _receiveKey!, aad: utf8.encode('PG|$_sessionId|$opposite'));
        newItems.add(PgMessage(utf8.decode(clear), false));
      } catch (_) {
        newItems.add(PgMessage('Encrypted message failed authentication', false));
      }
    }
    if (mounted && _page == 'chat' && readingSession == _sessionId) setState(() => _messages.addAll(newItems));
    _scrollDown();
  }

  Future<void> _endChat() async {
    if (_ending) return;
    _ending = true;
    try {
      if (_sessionId != null) await _request('POST', '/v1/sessions/$_sessionId/end', {});
    } catch (e) { _setError('Server did not confirm session termination. $e'); }
    finally {
      if (mounted) setState(() { _eraseLocal(); _page = 'ended'; });
      _ending = false;
    }
  }

  void _eraseLocal() {
    _pair?.destroy();
    _sendKey?.destroy();
    _receiveKey?.destroy();
    _pair = null;
    _myPublicKey = null;
    _sendKey = null;
    _receiveKey = null;
    _messages.clear();
    _messageInput.clear();
    _inviteInput.clear();
    _inviteCode = null;
    _inviteId = null;
    _sessionId = null;
    _safetyCode = null;
    _sessionState = '';
    _role = null;
  }

  Future<void> _stopToHome() async {
    final id = _inviteId;
    final session = _sessionId;
    try {
      if (id != null) await _request('POST', '/v1/invites/$id/revoke', {});
      else if (session != null) await _request('POST', '/v1/sessions/$session/end', {});
    } catch (e) { _setError('Could not confirm cancellation on server: $e'); }
    if (mounted) setState(() { _eraseLocal(); _page = 'home'; });
  }
  void _scrollDown() { WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 160), curve: Curves.easeOut);
  }); }

  // PG Interface v0.5 — AWS-inspired navy, warm orange, and clear action hierarchy.
  // The security warning remains prominent: styling does not imply a security audit.
  Widget _sectionLabel(String value) => Text(
    value.toUpperCase(),
    style: const TextStyle(
      color: _muted, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.45,
    ),
  );

  Widget _heading(String title, String description, {String? eyebrow}) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (eyebrow != null) ...[
        _sectionLabel(eyebrow),
        const SizedBox(height: 10),
      ],
      Text(title, style: const TextStyle(
        color: _white, fontWeight: FontWeight.w800, fontSize: 30,
        height: 1.12, letterSpacing: -0.75,
      )),
      const SizedBox(height: 11),
      Text(description, style: const TextStyle(
        color: _muted, height: 1.48, fontSize: 14,
      )),
    ],
  );

  Widget _card(Widget child, {EdgeInsetsGeometry? padding}) => Container(
    width: double.infinity,
    padding: padding ?? const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: _surface,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: _stroke),
      boxShadow: [BoxShadow(
        color: Colors.black.withValues(alpha: 0.12),
        blurRadius: 18, offset: const Offset(0, 8),
      )],
    ),
    child: child,
  );

  Widget _iconTile(IconData icon, {Color color = _orange}) => Container(
    width: 45, height: 45,
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(13),
      border: Border.all(color: color.withValues(alpha: 0.22)),
    ),
    child: Icon(icon, color: color, size: 23),
  );

  Widget _primaryAction(String title, VoidCallback onTap, {
    bool disabled = false,
    IconData icon = Icons.arrow_forward_rounded,
  }) => SizedBox(
    width: double.infinity, height: 52,
    child: ElevatedButton(
      onPressed: disabled ? null : onTap,
      style: ElevatedButton.styleFrom(
        backgroundColor: _orange,
        foregroundColor: _bg,
        disabledBackgroundColor: _orange.withValues(alpha: 0.35),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        elevation: 0,
      ),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Flexible(child: Text(title, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15))),
        const SizedBox(width: 10), Icon(icon, size: 19),
      ]),
    ),
  );

  Widget _secondaryAction(String title, VoidCallback onTap, {
    IconData icon = Icons.arrow_back_rounded,
    bool danger = false,
  }) => SizedBox(
    width: double.infinity, height: 48,
    child: OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 18),
      label: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
      style: OutlinedButton.styleFrom(
        foregroundColor: danger ? _danger : _white,
        side: BorderSide(color: danger ? _danger.withValues(alpha: 0.6) : _stroke),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
  );

  Widget _statusChip(String label, {
    IconData icon = Icons.circle,
    Color color = _teal,
  }) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.1),
      border: Border.all(color: color.withValues(alpha: 0.25)),
      borderRadius: BorderRadius.circular(99),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 13, color: color),
      const SizedBox(width: 6),
      Flexible(child: Text(label, overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color))),
    ]),
  );

  Widget _featurePill(IconData icon, String title) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 15, color: _teal),
      const SizedBox(width: 7),
      Text(title, style: const TextStyle(color: _muted, fontSize: 12)),
    ],
  );

  Future<void> _confirmEnd() async {
    if (_ending || _busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: _surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('End this conversation?',
          style: TextStyle(color: _white, fontWeight: FontWeight.w800)),
        content: const Text(
          'The app will discard this device’s session keys and chat messages. '
          'The other device will be notified when reachable.',
          style: TextStyle(color: _muted, height: 1.45),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep chatting')),
          TextButton(onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('End chat', style: TextStyle(color: _danger))),
        ],
      ),
    );
    if (confirmed == true && mounted) await _endChat();
  }

  void _showPrivacyNote() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 30),
          child: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _iconTile(Icons.security_rounded),
              const SizedBox(height: 18),
              const Text('About this PG build', style: TextStyle(
                color: _white, fontSize: 23, fontWeight: FontWeight.w800)),
              const SizedBox(height: 10),
              const Text(
                'PrivateGet is currently an experimental alpha. '
                'The message encryption protocol has not been independently audited. '
                'Do not send secrets or sensitive personal information. '
                'Avoid sharing invitation codes publicly.',
                style: TextStyle(color: _muted, height: 1.6),
              ),
              const SizedBox(height: 22),
              _secondaryAction('Close', () => Navigator.pop(sheetContext),
                icon: Icons.close_rounded),
            ],
          ),
        ),
      ),
    );
  }

  Widget _errorBanner() => Container(
    margin: const EdgeInsets.fromLTRB(18, 8, 18, 0),
    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
    decoration: BoxDecoration(
      color: const Color(0xFF3D2732),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: _danger.withValues(alpha: 0.3)),
    ),
    child: Row(children: [
      const Icon(Icons.error_outline_rounded, color: _danger, size: 20),
      const SizedBox(width: 10),
      Expanded(child: Text(_error!, maxLines: 3, overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Color(0xFFFFCFD2), fontSize: 12, height: 1.4))),
      IconButton(
        tooltip: 'Dismiss error', onPressed: () => setState(() => _error = null),
        icon: const Icon(Icons.close, color: _muted, size: 17),
      ),
    ]),
  );

  Widget _connectionFooter(bool online) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
    child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(Icons.circle, size: 7, color: online ? _teal : _orange),
      const SizedBox(width: 7),
      Flexible(child: Text(
        online ? 'Connected to PG relay • Device ${_deviceId!.substring(0, 8)}'
          : 'Connecting to your PG relay',
        textAlign: TextAlign.center,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: _muted, fontSize: 10),
      )),
    ]),
  );

  @override
  Widget build(BuildContext context) {
    final online = _token != null;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 75,
        titleSpacing: 20,
        title: Row(children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              color: _orange.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _orange.withValues(alpha: 0.32)),
            ),
            child: const Icon(Icons.shield_outlined, color: _orange, size: 24),
          ),
          const SizedBox(width: 11),
          const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('PrivateGet', style: TextStyle(
              color: _white, fontWeight: FontWeight.w800, fontSize: 20,
              letterSpacing: -0.4)),
            Text('PRIVATE MESSAGING', style: TextStyle(
              color: _muted, fontSize: 9, letterSpacing: 1.3,
              fontWeight: FontWeight.w800)),
          ]),
        ]),
        actions: [
          IconButton(
            tooltip: 'Privacy and build information',
            onPressed: _showPrivacyNote,
            icon: const Icon(Icons.info_outline_rounded, color: _muted),
          ),
          const SizedBox(width: 10),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(gradient: LinearGradient(
          begin: Alignment.topCenter, end: Alignment.bottomCenter,
          colors: [_bg, Color(0xFF101D2E)],
        )),
        child: SafeArea(child: Column(children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 9),
            color: const Color(0xFF352C20),
            child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.warning_amber_rounded, color: _orange, size: 16),
              SizedBox(width: 8),
              Flexible(child: Text('EARLY ACCESS · NOT SECURITY AUDITED',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 10, color: Color(0xFFFFD99E),
                  fontWeight: FontWeight.w800, letterSpacing: 0.7))),
            ]),
          ),
          if (_error != null) _errorBanner(),
          Expanded(child: Padding(
            padding: const EdgeInsets.fromLTRB(19, 23, 19, 8),
            child: _renderBody(online),
          )),
          _connectionFooter(online),
        ])),
      ),
    );
  }

  Widget _renderBody(bool online) {
    if (!online) return Center(child: SingleChildScrollView(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        _iconTile(Icons.cloud_off_outlined, color: _orange),
        const SizedBox(height: 20),
        const Text('Connecting to PrivateGet', style: TextStyle(
          fontSize: 23, fontWeight: FontWeight.w800, color: _white)),
        const SizedBox(height: 11),
        const Text('The app needs a reachable PG server before you can invite contacts or chat.',
          textAlign: TextAlign.center,
          style: TextStyle(color: _muted, fontSize: 14, height: 1.5)),
        const SizedBox(height: 22),
        _primaryAction('Try connecting again', _register, icon: Icons.refresh_rounded),
        const SizedBox(height: 12),
        Text(_apiBase, textAlign: TextAlign.center,
          style: const TextStyle(color: _muted, fontSize: 11)),
      ]),
    ));

    if (_page == 'home') return SingleChildScrollView(child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _statusChip('INVITATION-ONLY', icon: Icons.lock_outline_rounded, color: _orange),
        const SizedBox(height: 20),
        _heading('A private space for your conversations.',
          'Start a temporary conversation with someone you trust, or join using their one-time invite.'),
        const SizedBox(height: 24),
        _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            _iconTile(Icons.add_comment_outlined),
            const SizedBox(width: 12),
            const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Start a private chat', style: TextStyle(
                color: _white, fontSize: 17, fontWeight: FontWeight.w800)),
              SizedBox(height: 3),
              Text('Create an invitation', style: TextStyle(color: _muted, fontSize: 12)),
            ])),
          ]),
          const SizedBox(height: 17),
          const Text('Generate a one-time code to share directly with your contact.',
            style: TextStyle(color: _muted, fontSize: 13, height: 1.5)),
          const SizedBox(height: 18),
          _primaryAction(_busy ? 'Creating invite…' : 'Create invitation', _createInvite,
            disabled: _busy, icon: Icons.arrow_forward_rounded),
        ])),
        const SizedBox(height: 15),
        _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            _iconTile(Icons.link_rounded, color: _teal),
            const SizedBox(width: 12),
            const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Join a conversation', style: TextStyle(
                color: _white, fontSize: 17, fontWeight: FontWeight.w800)),
              SizedBox(height: 3),
              Text('Received an invite?', style: TextStyle(color: _muted, fontSize: 12)),
            ])),
          ]),
          const SizedBox(height: 16),
          TextField(
            controller: _inviteInput,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.none,
            decoration: const InputDecoration(
              hintText: 'Paste your invitation code',
              prefixIcon: Icon(Icons.vpn_key_outlined, color: _muted),
            ),
          ),
          const SizedBox(height: 12),
          _primaryAction(_busy ? 'Joining…' : 'Join private chat', _acceptInvite,
            disabled: _busy, icon: Icons.arrow_forward_rounded),
        ])),
        const SizedBox(height: 22),
        Wrap(spacing: 16, runSpacing: 12, children: [
          _featurePill(Icons.shield_outlined, 'One-time invites'),
          _featurePill(Icons.timer_outlined, 'Temporary sessions'),
          _featurePill(Icons.visibility_off_outlined, 'No public directory'),
        ]),
        const SizedBox(height: 25),
      ],
    ));

    if (_page == 'inviting') return SingleChildScrollView(child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading('Invitation ready',
          'Send this code to the person you want to speak with.', eyebrow: 'NEW CONVERSATION'),
        const SizedBox(height: 23),
        _card(Column(children: [
          _iconTile(Icons.link_rounded),
          const SizedBox(height: 15),
          _sectionLabel('YOUR SINGLE-USE INVITE'),
          const SizedBox(height: 13),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 17, horizontal: 13),
            decoration: BoxDecoration(
              color: _field, borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _stroke),
            ),
            child: SelectableText(_inviteCode ?? '', textAlign: TextAlign.center,
              style: const TextStyle(color: _white, fontSize: 15,
                fontWeight: FontWeight.w800, letterSpacing: 0.7)),
          ),
          const SizedBox(height: 16),
          _primaryAction('Copy invitation code', () {
            final code = _inviteCode;
            if (code == null) return;
            Clipboard.setData(ClipboardData(text: code));
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Invite copied. Share it privately and clear your clipboard afterward.'),
            ));
          }, icon: Icons.copy_rounded),
          const SizedBox(height: 15),
          const Text('Expires after 10 minutes • Can only be used once',
            textAlign: TextAlign.center,
            style: TextStyle(color: _muted, fontSize: 11)),
        ])),
        const SizedBox(height: 25),
        Row(children: [
          const SizedBox(width: 18, height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: _orange)),
          const SizedBox(width: 12),
          const Expanded(child: Text('Waiting for your contact to join…',
            style: TextStyle(color: _white, fontSize: 13, fontWeight: FontWeight.w600))),
        ]),
        const SizedBox(height: 27),
        _secondaryAction('Cancel invitation', _stopToHome, icon: Icons.close_rounded),
      ],
    ));

    if (_page == 'waiting') return SingleChildScrollView(child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(
          _role == 'A' ? 'Review connection request' : 'Awaiting confirmation',
          _role == 'A'
            ? 'Someone used your invitation. Confirm this is the person you intended to connect with.'
            : 'Your invitation was accepted. The contact who invited you must confirm this connection.',
          eyebrow: 'PRIVATE CONNECTION',
        ),
        const SizedBox(height: 24),
        _card(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Align(alignment: Alignment.centerLeft,
            child: _statusChip(
              _sessionState == 'awaiting_approval' ? 'AWAITING APPROVAL' : 'CONNECTING',
              icon: Icons.schedule_rounded, color: _orange)),
          const SizedBox(height: 20),
          const Text('Connection safety code', style: TextStyle(
            color: _white, fontWeight: FontWeight.w700, fontSize: 15)),
          const SizedBox(height: 8),
          const Text('Compare this code on both phones before discussing anything private.',
            style: TextStyle(color: _muted, fontSize: 12, height: 1.4)),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 17),
            decoration: BoxDecoration(color: _field,
              borderRadius: BorderRadius.circular(12)),
            child: Text(_safetyCode ?? 'Generating code…',
              textAlign: TextAlign.center,
              style: const TextStyle(color: _orange, fontSize: 23,
                fontWeight: FontWeight.w800, letterSpacing: 2.1)),
          ),
          if (_role == 'A' && _sessionState == 'awaiting_approval') ...[
            const SizedBox(height: 19),
            _primaryAction(_busy ? 'Confirming…' : 'Confirm this contact', _approve,
              disabled: _busy, icon: Icons.check_rounded),
          ],
        ])),
        const SizedBox(height: 22),
        _secondaryAction('Cancel connection', _confirmEnd,
          icon: Icons.close_rounded, danger: true),
      ],
    ));

    if (_page == 'chat') return Column(children: [
      _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          _iconTile(Icons.person_outline_rounded, color: _teal),
          const SizedBox(width: 12),
          const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Private contact', style: TextStyle(
              color: _white, fontSize: 16, fontWeight: FontWeight.w800)),
            SizedBox(height: 4),
            Text('Temporary conversation', style: TextStyle(
              color: _muted, fontSize: 12)),
          ])),
          _statusChip('CONNECTED', icon: Icons.circle, color: _teal),
        ]),
        const SizedBox(height: 14),
        Text('Safety code  ${_safetyCode ?? "Unavailable"}',
          style: const TextStyle(color: _muted, fontSize: 12)),
        const SizedBox(height: 4),
        const Text('Compare on both devices to detect unexpected key changes.',
          style: TextStyle(color: Color(0xFFF0BE80), fontSize: 10)),
      ], padding: const EdgeInsets.all(16)),
      const SizedBox(height: 16),
      Expanded(child: _messages.isEmpty
        ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.chat_bubble_outline_rounded,
              size: 46, color: _muted.withValues(alpha: 0.7)),
            const SizedBox(height: 12),
            const Text('Your conversation starts here', style: TextStyle(
              fontWeight: FontWeight.w700, color: _white, fontSize: 15)),
            const SizedBox(height: 7),
            const Text('Messages appear during this session. Check the safety code on both phones.',
              textAlign: TextAlign.center,
              style: TextStyle(color: _muted, fontSize: 12, height: 1.45)),
          ]))
        : ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.only(bottom: 14),
            itemCount: _messages.length,
            itemBuilder: (context, index) {
              final message = _messages[index];
              return Align(
                alignment: message.mine ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.77),
                  margin: const EdgeInsets.symmetric(vertical: 5),
                  padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
                  decoration: BoxDecoration(
                    color: message.mine ? const Color(0xFF3D341F) : _surface,
                    border: Border.all(color: message.mine
                      ? _orange.withValues(alpha: 0.26) : _stroke),
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(16),
                      topRight: const Radius.circular(16),
                      bottomLeft: Radius.circular(message.mine ? 16 : 5),
                      bottomRight: Radius.circular(message.mine ? 5 : 16),
                    ),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(message.mine ? 'YOU' : 'CONTACT',
                      style: TextStyle(color: message.mine ? _orange : _teal,
                        letterSpacing: 0.9, fontWeight: FontWeight.w800, fontSize: 9)),
                    const SizedBox(height: 5),
                    Text(message.text, style: const TextStyle(
                      color: _white, fontSize: 14, height: 1.45)),
                  ]),
                ),
              );
            },
          )),
      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Expanded(child: TextField(
          controller: _messageInput,
          minLines: 1, maxLines: 4, maxLength: 2000,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            hintText: 'Write a message…', counterText: '',
            contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          ),
        )),
        const SizedBox(width: 9),
        SizedBox(width: 50, height: 50, child: IconButton.filled(
          tooltip: 'Send message',
          onPressed: _busy ? null : _sendMessage,
          style: IconButton.styleFrom(
            backgroundColor: _orange, foregroundColor: _bg,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
          ),
          icon: const Icon(Icons.send_rounded, size: 22),
        )),
      ]),
      const SizedBox(height: 12),
      _secondaryAction('End conversation', _confirmEnd,
        icon: Icons.logout_rounded, danger: true),
    ]);

    if (_page == 'ended') return Center(child: SingleChildScrollView(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        _iconTile(Icons.lock_clock_outlined, color: _teal),
        const SizedBox(height: 18),
        const Text('Conversation closed', textAlign: TextAlign.center,
          style: TextStyle(color: _white, fontSize: 26, fontWeight: FontWeight.w800)),
        const SizedBox(height: 12),
        Text(_error == null
            ? 'This device discarded the chat messages and session keys. '
              'A fresh invitation is required to talk again.'
            : 'This device discarded its chat state, but the PG server did not confirm termination. '
              'Please check the connection before using PG again.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: _muted, fontSize: 14, height: 1.6)),
        const SizedBox(height: 25),
        _primaryAction('Back to conversations', _stopToHome,
          icon: Icons.arrow_forward_rounded),
      ]),
    ));

    return const SizedBox.shrink();
  }
}
