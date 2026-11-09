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
const _panel = Color(0xFF101E35);
const _surface = Color(0xFF172842);
const _green = Color(0xFF40E0A0);

void main() => runApp(const PgApp());

class PgApp extends StatelessWidget {
  const PgApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'PrivateGet · PG',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: _panel,
      colorScheme: ColorScheme.fromSeed(seedColor: _green, brightness: Brightness.dark),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: _surface,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: BorderSide.none),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(style: ElevatedButton.styleFrom(
        backgroundColor: _green, foregroundColor: _panel, minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      )),
      appBarTheme: const AppBarTheme(backgroundColor: _panel),
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

  Widget _heading(String heading, String sub) => Padding(
    padding: const EdgeInsets.only(bottom: 22),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(heading, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 28)),
      const SizedBox(height: 7), Text(sub, style: const TextStyle(color: Colors.white70, height: 1.4)),
    ]),
  );
  Widget _button(String text, VoidCallback onTap, {bool disabled = false}) => ElevatedButton(
    onPressed: disabled ? null : onTap,
    child: Text(text, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
  );
  Widget _card(Widget child) => Container(width: double.infinity,
    padding: const EdgeInsets.all(20), decoration: BoxDecoration(
      color: _surface, borderRadius: BorderRadius.circular(17),
      border: Border.all(color: Colors.white12)), child: child);

  @override
  Widget build(BuildContext context) {
    final online = _token != null;
    return Scaffold(
      appBar: AppBar(title: const Row(children: [
        Icon(Icons.shield_outlined, color: _green), SizedBox(width: 9),
        Text('PrivateGet', style: TextStyle(fontWeight: FontWeight.bold)),
        SizedBox(width: 6), Text('PG', style: TextStyle(color: _green, fontSize: 13)),
      ])),
      body: SafeArea(child: Column(children: [
        Container(width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 10),
          color: const Color(0xFF44310C),
          child: const Text('EXPERIMENTAL ALPHA · NOT SECURITY-AUDITED · DO NOT SEND SECRETS',
            style: TextStyle(color: Color(0xFFFFE6A2), fontSize: 11, fontWeight: FontWeight.w700), textAlign: TextAlign.center)),
        if (_error != null) Container(width: double.infinity,
          padding: const EdgeInsets.all(12), color: const Color(0xFF61252D),
          child: Text(_error!, style: const TextStyle(fontSize: 12))),
        Expanded(child: Padding(padding: const EdgeInsets.all(19), child: _renderBody(online))),
        Padding(padding: const EdgeInsets.all(12), child: Text(
          online ? 'Device: ${_deviceId!.substring(0,8)} • Server: $_apiBase' : 'Connecting to $_apiBase',
          style: const TextStyle(color: Colors.white38, fontSize: 10), textAlign: TextAlign.center)),
      ])),
    );
  }

  Widget _renderBody(bool online) {
    if (!online) return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      const CircularProgressIndicator(color: _green), const SizedBox(height: 20),
      const Text('Connecting to real PG backend…'), const SizedBox(height: 15),
      TextButton(onPressed: _register, child: const Text('Retry connection')),
    ]));
    if (_page == 'home') return SingleChildScrollView(child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _heading('Private by invitation.', 'Start a real chat between two phones through your PG server.'),
        _card(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('PARTY A', style: TextStyle(color: _green, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8), const Text('Invite someone to a temporary private session.'),
          const SizedBox(height: 18), _button(_busy ? 'Creating…' : 'Create invitation', _createInvite, disabled: _busy),
        ])),
        const SizedBox(height: 20),
        _card(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('PARTY B', style: TextStyle(color: _green, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8), const Text('Paste a one-time code received from Party A.'),
          const SizedBox(height: 13), TextField(controller: _inviteInput,
            autocorrect: false, enableSuggestions: false,
            decoration: const InputDecoration(hintText: 'Paste invitation code')),
          const SizedBox(height: 15), _button('Accept invitation', _acceptInvite, disabled: _busy),
        ])),
      ]));
    if (_page == 'inviting') return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _heading('Invite created', 'Share this one-time code privately. It expires after 10 minutes.'),
      _card(Column(children: [
        const Icon(Icons.link, color: _green, size: 36), const SizedBox(height: 15),
        SelectableText(_inviteCode ?? '', textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 1)),
        const SizedBox(height: 18),
        _button('Copy invitation code', () { Clipboard.setData(ClipboardData(text: _inviteCode!));
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied. Share privately, then clear clipboard.'))); }),
      ])),
      const SizedBox(height: 20), const Center(child: CircularProgressIndicator(color: _green)),
      const SizedBox(height: 10), const Center(child: Text('Waiting for Party B to accept…')),
      const Spacer(), OutlinedButton(onPressed: () => _stopToHome(), child: const Text('Cancel invitation')),
    ]);
    if (_page == 'waiting') return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _heading(_role == 'A' ? 'Confirm Party B' : 'Waiting for approval',
        _role == 'A' ? 'Someone accepted your invitation. Only approve your intended contact.'
          : 'Party A must approve the connection before chatting.'),
      _card(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Status: $_sessionState', style: const TextStyle(color: _green)),
        const SizedBox(height: 12),
        if (_safetyCode != null) ...[
          const Text('SAFETY CODE — compare on both phones'),
          const SizedBox(height: 9), Text(_safetyCode!, textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 25, letterSpacing: 2)),
          const SizedBox(height: 7),
          const Text('If the two phones show different codes, do not chat.',
            style: TextStyle(color: Colors.amberAccent, fontSize: 12)),
        ],
        if (_role == 'A' && _sessionState == 'awaiting_approval') ...[
          const SizedBox(height: 18), _button(_busy ? 'Approving…' : 'Approve this connection', _approve, disabled: _busy),
        ],
      ])),
      const Spacer(), OutlinedButton(onPressed: _endChat, child: const Text('Cancel / End session')),
    ]);
    if (_page == 'chat') return Column(children: [
      _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [Icon(Icons.lock_outline, color: _green, size: 18), SizedBox(width: 8),
          Text('Encrypted session', style: TextStyle(color: _green, fontWeight: FontWeight.bold))]),
        const SizedBox(height: 5), Text('Safety: ${_safetyCode ?? "Not available"}',
          style: const TextStyle(fontSize: 12, color: Colors.white70)),
        const Text('Verify on both phones to detect server-side key substitution.',
          style: TextStyle(color: Colors.amberAccent, fontSize: 10)),
      ])),
      const SizedBox(height: 7),
      Expanded(child: ListView.builder(controller: _scroll,
        itemCount: _messages.length, itemBuilder: (context, i) {
          final m = _messages[i];
          return Align(alignment: m.mine ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(margin: const EdgeInsets.symmetric(vertical: 5),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
              constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * .75),
              decoration: BoxDecoration(color: m.mine ? const Color(0xFF174D47) : _surface,
                borderRadius: BorderRadius.circular(15)), child: Text(m.text)));
        })),
      Row(children: [Expanded(child: TextField(controller: _messageInput, maxLength: 2000,
        maxLines: 3, minLines: 1,
        decoration: const InputDecoration(hintText: 'Encrypted message…', counterText: ''))),
        const SizedBox(width: 8), IconButton.filled(onPressed: _busy ? null : _sendMessage,
          style: IconButton.styleFrom(backgroundColor: _green, foregroundColor: _panel),
          icon: const Icon(Icons.send_rounded))]),
      const SizedBox(height: 8),
      OutlinedButton.icon(onPressed: _endChat,
        icon: const Icon(Icons.delete_forever_outlined, color: Colors.redAccent),
        label: const Text('End session & erase local chat')),
    ]);
    if (_page == 'ended') return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.lock_clock_outlined, color: _green, size: 74),
      const SizedBox(height: 20), const Text('Session ended', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
      const SizedBox(height: 9), const Text('This device discarded the session keys and chat state.',
        textAlign: TextAlign.center, style: TextStyle(color: Colors.white70)),
      const SizedBox(height: 22), _button('New invitation', () => _stopToHome()),
    ]));
    return const SizedBox.shrink();
  }
}
