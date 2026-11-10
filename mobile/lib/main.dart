// PrivateGet PG – actual two-device networked ALPHA (not a simulation).
// Run with --dart-define=PG_API_URL=http://YOUR_LAN_IP:8787
// SECURITY: The message construction here is experimental and NOT audited.
// Do not use for sensitive conversations or production deployment.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'pg_media.dart';
import 'pg_calls.dart';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _defaultApiBase = String.fromEnvironment('PG_API_URL', defaultValue: 'http://10.0.2.2:8787');
const _privateAlerts = MethodChannel('pg/private_notifications');
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
    title: 'PG',
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

// Only the invitation code is shared. No chat keys or messages are included.
// The invite remains valid until redeemed, revoked, or expired on the PG relay.
String buildInvitationShareText(String code) =>
    'You are invited to a private conversation on PrivateGet (PG).\n\n'
    'Open the PrivateGet app, choose Join a conversation, and paste this invitation code:\n\n'
    '$code\n\n'
    'This invitation works only once and expires after 10 minutes. '
    'Please do not forward it to anyone else.';

// These large emoji stickers travel inside PG's existing encrypted text channel.
const _pgStickerChoices = <String>[
  '🥳','❤️','😂','😍','🔥','👏','💯','🤗','🙏','🎉','💪','👋',
];
const _pgStickerPrefix = 'PG_STICKER:';

String encodePgSticker(String glyph) {
  if (!_pgStickerChoices.contains(glyph)) {
    throw ArgumentError.value(glyph, 'glyph', 'Unknown PG sticker');
  }
  return '$_pgStickerPrefix$glyph';
}

String? decodePgSticker(String message) {
  if (!message.startsWith(_pgStickerPrefix)) return null;
  final glyph = message.substring(_pgStickerPrefix.length);
  return _pgStickerChoices.contains(glyph) ? glyph : null;
}

// A reply's quoted text stays inside the existing encrypted message body.
// Legacy plain-text messages continue to decode unchanged.
const pgReplyMarker = 'PG_REPLY_V1:';
const pgStatusMarker = 'PG_STATUS_V1:';

class PgReplyPayload {
  const PgReplyPayload(this.message, this.quoted, this.quotedFromSender);
  final String message;
  final String quoted;
  final bool quotedFromSender;
}

String encodePgReply(String message, String quote, bool quoteMine) {
  if (message.isEmpty || message.length > 1450 ||
      quote.isEmpty || quote.length > 160) {
    throw ArgumentError('Reply content exceeds limits');
  }
  return pgReplyMarker + jsonEncode({
    'message': message,
    'quote': quote,
    'quoteMine': quoteMine,
  });
}

PgReplyPayload? decodePgReply(String raw) {
  if (!raw.startsWith(pgReplyMarker)) return null;
  try {
    final parsed = jsonDecode(raw.substring(pgReplyMarker.length));
    if (parsed is! Map<String, dynamic>) return null;
    final message = parsed['message'];
    final quote = parsed['quote'];
    final quoteMine = parsed['quoteMine'];
    if (message is! String || message.isEmpty || message.length > 1450 ||
        quote is! String || quote.isEmpty || quote.length > 160 ||
        quoteMine is! bool) return null;
    return PgReplyPayload(message, quote, quoteMine);
  } catch (_) {
    return null;
  }
}

class PgStatusIcon {
  const PgStatusIcon(this.id, this.label, this.icon, this.color);
  final String id, label;
  final IconData icon;
  final Color color;
}

// PG-exclusive status stickers: structured identifiers are transmitted
// inside the encrypted chat and rendered by the receiving PG app.
const pgStatusIcons = <PgStatusIcon>[
  PgStatusIcon('contract_agreed', 'Contract agreed',
    Icons.handshake_rounded, Color(0xFF54D7B2)),
  PgStatusIcon('date_fixed', 'Date fixed',
    Icons.event_available_rounded, Color(0xFFFFB238)),
  PgStatusIcon('terms_agreed', 'Terms agreed',
    Icons.fact_check_rounded, Color(0xFF64D7F9)),
  PgStatusIcon('on_the_move', 'On the move',
    Icons.directions_run_rounded, Color(0xFFFF955C)),
  PgStatusIcon('eating', 'Eating',
    Icons.restaurant_rounded, Color(0xFF8CE3A3)),
];

String encodePgStatus(String id) {
  if (!pgStatusIcons.any((status) => status.id == id)) {
    throw ArgumentError.value(id, 'id', 'Unsupported PG status');
  }
  return '$pgStatusMarker$id';
}

PgStatusIcon? decodePgStatus(String raw) {
  if (!raw.startsWith(pgStatusMarker)) return null;
  final id = raw.substring(pgStatusMarker.length);
  for (final status in pgStatusIcons) {
    if (status.id == id) return status;
  }
  return null;
}

class PgMessage {
  final String text;
  final bool mine;
  final String? quotedText;
  final bool? quotedMine;
  PgMessage(this.text, this.mine, {this.quotedText, this.quotedMine});

  factory PgMessage.fromWire(String raw, bool mine) {
    final reply = decodePgReply(raw);
    if (reply == null) return PgMessage(raw, mine);
    return PgMessage(
      reply.message, mine,
      quotedText: reply.quoted,
      quotedMine: mine ? reply.quotedFromSender : !reply.quotedFromSender,
    );
  }
}


class PgConversation {
  PgConversation(this.number);

  final int number;
  String page = 'inviting';
  String sessionState = '';
  String? inviteId, inviteCode, sessionId, role, safetyCode;
  KeyPair? pair;
  SimplePublicKey? publicKey;
  SecretKey? sendKey, receiveKey;
  final List<PgMessage> messages = <PgMessage>[];
  final List<File> temporaryDecryptedFiles = <File>[];
  String draft = '';
  bool cleared = false;
  String? nickname;
  int unreadCount = 0;

  // Session names exist only in this app's volatile memory; the relay
  // receives neither nicknames nor read counters.
  String get title => nickname ?? 'Private chat $number';
  String get initials {
    if (nickname == null) return number.toString().padLeft(2, '0');
    final pieces = title.trim().split(RegExp(r'\s+'));
    if (pieces.length > 1) {
      return ('${pieces[0][0]}${pieces[1][0]}').toUpperCase();
    }
    final word = pieces.first;
    return word.substring(0, word.length < 2 ? word.length : 2).toUpperCase();
  }

  void rename(String name) {
    final clean = name.trim();
    nickname = clean.isEmpty ? null
        : clean.substring(0, clean.length > 24 ? 24 : clean.length);
  }

  void receive(List<PgMessage> items, {required bool visible}) {
    if (cleared || page == 'ended') return;
    messages.addAll(items);
    if (visible) {
      unreadCount = 0;
    } else {
      unreadCount += items.length;
    }
  }

  void markRead() => unreadCount = 0;
  String get status {
    switch (page) {
      case 'inviting': return 'Invitation ready';
      case 'waiting': return 'Waiting for connection';
      case 'chat': return 'Connected';
      case 'ended': return 'Conversation ended';
      default: return 'Private conversation';
    }
  }

  // This only clears application-held references and does not guarantee
  // erasure of copies made by the OS, backups or a compromised device.
  void clearSensitive() {
    if (cleared) return;
    pair?.destroy();
    sendKey?.destroy();
    receiveKey?.destroy();
    pair = null;
    publicKey = null;
    sendKey = null;
    receiveKey = null;
    messages.clear();
    // Best-effort OS-cache cleanup; external viewers may copy the file.
    for (final file in temporaryDecryptedFiles) {
      unawaited(file.delete().catchError((Object _) => file));
    }
    temporaryDecryptedFiles.clear();
    draft = '';
    nickname = null;
    unreadCount = 0;
    inviteId = null;
    inviteCode = null;
    sessionId = null;
    safetyCode = null;
    role = null;
    cleared = true;
  }
}

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}

// Keep the editing controller alive until the dialog route is actually
// disposed. showDialog's Future can resolve before the exit animation ends.
class PgRenameDialog extends StatefulWidget {
  const PgRenameDialog({super.key, required this.initialName});
  final String initialName;

  @override
  State<PgRenameDialog> createState() => _PgRenameDialogState();
}

class _PgRenameDialogState extends State<PgRenameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: _surface,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    title: const Text('Name this conversation',
      style: TextStyle(color: _white, fontWeight: FontWeight.w800)),
    content: Column(mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 24,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(
          hintText: 'e.g. Suitor or KwameP',
          prefixIcon: Icon(Icons.edit_outlined, color: _orange),
        ),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      const SizedBox(height: 8),
      const Text('This label is visible only on your phone and disappears when the session ends.',
        style: TextStyle(color: _muted, fontSize: 12, height: 1.4)),
    ]),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel')),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(_controller.text),
        child: const Text('Save name'),
      ),
    ],
  );
}

// The dialog owns its controller until the route finishes closing.
class PgServerAddressDialog extends StatefulWidget {
  const PgServerAddressDialog({super.key, required this.initialUrl});
  final String initialUrl;
  @override
  State<PgServerAddressDialog> createState() => _PgServerAddressDialogState();
}
class _PgServerAddressDialogState extends State<PgServerAddressDialog> {
  late final TextEditingController _controller;
  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialUrl);
  }
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('PG server address'),
    content: Column(mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Open the Render dashboard and copy the exact HTTPS '
        'address of the PG web service.'),
      const SizedBox(height: 12),
      TextField(
        controller: _controller,
        keyboardType: TextInputType.url,
        autocorrect: false,
        decoration: const InputDecoration(
          labelText: 'Server address',
          hintText: 'https://your-service.onrender.com',
        ),
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
    ]),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context),
        child: const Text('Cancel')),
      FilledButton(onPressed: () => Navigator.pop(context, _controller.text),
        child: const Text('Use address')),
    ],
  );
}

class PgHome extends StatefulWidget {
  const PgHome({super.key});
  @override
  State<PgHome> createState() => _PgHomeState();
}

class _PgHomeState extends State<PgHome> {
  final _inviteInput = TextEditingController();
  final _messageInput = TextEditingController();
  final _messageFocus = FocusNode();
  final _imagePicker = ImagePicker();
  late final PgCallService _calls;
  bool _showingCallPanel = false;
  final _scroll = ScrollController();
  final _keyExchange = X25519();
  final _chats = <PgConversation>[];
  PgConversation? _selectedChat;
  int _chatCounter = 0;
  static const _maxLiveChats = 4;

  String get _page => _selectedChat?.page ?? 'home';
  String? get _inviteCode => _selectedChat?.inviteCode;
  String? get _safetyCode => _selectedChat?.safetyCode;
  String? get _role => _selectedChat?.role;
  String get _sessionState => _selectedChat?.sessionState ?? '';
  List<PgMessage> get _messages =>
      _selectedChat?.messages ?? <PgMessage>[];
  int get _totalUnread => _chats
      .where((c) => !c.cleared && c.page != 'ended')
      .fold<int>(0, (count, c) => count + c.unreadCount);
  int get _activeCount => _chats
      .where((c) => !c.cleared && c.page != 'ended').length;
  final _cipher = AesGcm.with256bits();
  HttpClient? _http;
  Timer? _ticker;
  bool _busy = false;
  bool _polling = false;
  String? _token, _deviceId;
  String _apiBase = _defaultApiBase;
  String? _error;
  bool _ending = false;
  String _pickerMode = 'none'; // none or sticker
  PgMessage? _replyTarget;

  @override
  void initState() {
    super.initState();
    _http = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    _calls = PgCallService(_sendCallSignal, _loadIceServers);
    unawaited(_loadServerUrlAndRegister());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_requestNotificationPermission());
    });
    // Four parallel sessions, polled conservatively to respect relay limits.
    _ticker = Timer.periodic(const Duration(seconds: 4), (_) => _tick());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    unawaited(_calls.shutdown());
    _http?.close(force: true);
    _inviteInput.dispose();
    _messageInput.dispose();
    _messageFocus.dispose();
    _scroll.dispose();
    for (final chat in _chats) {
      chat.clearSensitive();
    }
    super.dispose();
  }

  // Android 13+ asks for notifications at first launch. Reopening PG doesn't
  // repeatedly ask after the user has made a system-level choice.
  Future<void> _requestNotificationPermission() async {
    if (!Platform.isAndroid || !mounted) return;
    try {
      await _privateAlerts.invokeMethod<bool>('requestPermission');
    } on PlatformException {
      // Notifications are optional; denial must never block encrypted chat.
    } on MissingPluginException {
      // Widget tests/iOS may not have an Android channel implementation.
    }
  }

  // Foreground alpha only: this is NOT Firebase/APNs push delivery.
  // No plaintext, sender name, message ID or encryption keys enter OS alerts.
  Future<void> _showPrivateIncomingNotification() async {
    if (!Platform.isAndroid || !mounted) return;
    try {
      await _privateAlerts.invokeMethod<bool>('showPrivateMessage');
    } on PlatformException {
      // Foreground in-app notice remains as fallback.
    } on MissingPluginException {
      // No Android plugin in tests/iOS.
    }
  }

  void _setError(Object err) {
    if (!mounted) return;
    setState(() => _error = err.toString());
  }

  Future<Map<String, dynamic>> _request(String method, String path, [Map<String, dynamic>? body]) async {
    final uri = Uri.parse('$_apiBase$path');
    final HttpClientRequest request;
    try {
      request = await _http!.openUrl(method, uri)
          .timeout(const Duration(seconds: 7));
    } on SocketException {
      throw ApiException('Cannot resolve or reach the PG host ' + uri.host +
        '. Open Server address and use the HTTPS URL from your Render dashboard.');
    }
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

  Future<void> _loadServerUrlAndRegister() async {
    try {
      final saved = await SharedPreferencesAsync().getString('pg_server_url_v1');
      if (saved != null && _validPgServerUrl(saved) && mounted) {
        setState(() => _apiBase = saved);
      }
    } catch (_) {
      // Keep the build-time address when preferences cannot be loaded.
    }
    if (mounted) await _register();
  }

  static bool _validPgServerUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasAuthority || uri.host.isEmpty ||
        uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) return false;
    if (uri.scheme == 'https') return true;
    if (uri.scheme != 'http') return false;
    return uri.host == 'localhost' || uri.host == '127.0.0.1' ||
        uri.host == '10.0.2.2' ||
        uri.host.startsWith('192.168.') || uri.host.startsWith('10.');
  }

  Future<void> _register() async {
    try {
      final data = await _request('POST', '/v1/devices', {});
      if (!mounted) return;
      setState(() { _token = data['token'] as String; _deviceId = data['deviceId'] as String; _error = null; });
    } catch (e) { _setError('Cannot connect to PG server at $_apiBase. $e'); }
  }


  // Every conversation has separate ephemeral key material, a unique
  // invitation/session, isolated messages, and an independent draft.
  PgConversation? _createLocalConversation(String initialPage) {
    if (_chats.where((c) => c.page != 'ended').length >= _maxLiveChats) {
      _setError('Up to four live conversations are supported in this alpha. End one before starting another.');
      return null;
    }
    final chat = PgConversation(++_chatCounter)..page = initialPage;
    _openChat(chat, add: true);
    return chat;
  }

  void _openChat(PgConversation? chat, {bool add = false}) {
    FocusManager.instance.primaryFocus?.unfocus();
    if (_selectedChat != null && !_selectedChat!.cleared) {
      _selectedChat!.draft = _messageInput.text;
    }
    setState(() {
      _pickerMode = 'none';
      _replyTarget = null;
      if (chat != null && add) _chats.add(chat);
      _selectedChat = chat;
      if (chat != null) chat.markRead();
      _messageInput.text = chat?.draft ?? '';
      _error = null;
    });
    if (chat?.page == 'chat') _scrollDown();
  }

  void _returnHome() => _openChat(null);

  Future<void> _preparePair(PgConversation chat) async {
    chat.pair = await _keyExchange.newKeyPair();
    chat.publicKey = await chat.pair!.extractPublicKey() as SimplePublicKey;
  }

  String _b64(List<int> data) => base64UrlEncode(data).replaceAll('=', '');
  List<int> _bytes(String s) => base64Url.decode(base64Url.normalize(s));

  Future<void> _createInvite() async {
    if (_busy || _token == null) return;
    final chat = _createLocalConversation('inviting');
    if (chat == null) return;
    setState(() { _busy = true; _error = null; });
    try {
      await _preparePair(chat);
      final result = await _request('POST', '/v1/invites', {
        'publicKey': _b64(chat.publicKey!.bytes),
      });
      if (!mounted || !_chats.contains(chat)) return;
      setState(() {
        chat.inviteId = result['id'] as String;
        chat.inviteCode = result['code'] as String;
        chat.role = 'A';
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          chat.clearSensitive();
          _chats.remove(chat);
          if (identical(_selectedChat, chat)) _selectedChat = null;
        });
        _setError(e);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _shareInvite() async {
    final code = _inviteCode;
    if (!mounted || code == null || code.isEmpty) return;
    try {
      // The OS offers installed apps such as WhatsApp, Messages and email.
      // PG doesn't upload the invitation to the share provider itself.
      await SharePlus.instance.share(ShareParams(
        text: buildInvitationShareText(code),
        title: 'PrivateGet invitation',
        subject: 'PrivateGet private chat invitation',
      ));
    } catch (_) {
      _setError('Unable to open the phone sharing options. Please try again.');
    }
  }

  Future<void> _acceptInvite() async {
    if (_busy || _token == null) return;
    final code = _inviteInput.text.trim();
    if (code.length < 20) {
      _setError('Paste a full invitation code.');
      return;
    }
    final chat = _createLocalConversation('waiting');
    if (chat == null) return;
    setState(() { _busy = true; _error = null; });
    try {
      await _preparePair(chat);
      final response = await _request('POST', '/v1/invites/accept', {
        'code': code,
        'publicKey': _b64(chat.publicKey!.bytes),
      });
      if (!mounted || !_chats.contains(chat)) return;
      setState(() {
        chat.role = 'B';
        chat.sessionId = response['sessionId'] as String;
        chat.sessionState = 'awaiting_approval';
        _inviteInput.clear();
      });
      await _fetchSession(chat);
    } catch (e) {
      if (mounted) {
        setState(() {
          chat.clearSensitive();
          _chats.remove(chat);
          if (identical(_selectedChat, chat)) _selectedChat = null;
        });
        _setError(e);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _tick() async {
    if (_polling || _token == null || !mounted || _ending) return;
    _polling = true;
    try {
      for (final chat in List<PgConversation>.of(_chats)) {
        if (!mounted || !_chats.contains(chat) ||
            chat.cleared || chat.page == 'ended') continue;
        try {
          if (chat.page == 'inviting' && chat.inviteId != null) {
            final invite = await _request('GET', '/v1/invites/${chat.inviteId}');
            if (!_chats.contains(chat) || chat.cleared) continue;
            if (invite['state'] == 'expired' ||
                invite['state'] == 'revoked') {
              _closeLocalChat(chat);
              continue;
            }
            if (invite['sessionId'] is String) {
              chat.sessionId = invite['sessionId'] as String;
              chat.page = 'waiting';
            }
          }
          if (chat.sessionId != null) await _fetchSession(chat);
          if (chat.page == 'chat' && chat.sessionId != null) {
            await _pollMessages(chat);
            await _pollCallSignals(chat);
          }
        } catch (e) {
          // A server restart destroys volatile sessions in this alpha.
          if (e is ApiException && e.message.startsWith('404:') &&
              chat.sessionId != null) {
            _closeLocalChat(chat);
          } else if (identical(_selectedChat, chat)) {
            _setError(e);
          }
        }
      }
      if (mounted) setState(() {});
    } finally {
      _polling = false;
    }
  }

  Future<void> _fetchSession(PgConversation chat) async {
    final id = chat.sessionId;
    if (id == null || chat.cleared) return;
    final result = await _request('GET', '/v1/sessions/$id');
    if (!_chats.contains(chat) || chat.cleared || !mounted) return;
    final state = result['state'] as String;
    if (state == 'ended') {
      _closeLocalChat(chat);
      return;
    }
    final peerKey = result['peerKey'];
    if (peerKey is String && chat.sendKey == null && chat.pair != null) {
      await _establishKeys(chat, peerKey);
    }
    if (!_chats.contains(chat) || chat.cleared || !mounted) return;
    setState(() {
      chat.sessionState = state;
      chat.page = state == 'active' && chat.sendKey != null
          ? 'chat' : 'waiting';
    });
  }

  Future<void> _establishKeys(PgConversation chat, String peer64) async {
    final id = chat.sessionId;
    if (id == null || chat.pair == null || chat.role == null) return;
    final peerPublic = SimplePublicKey(_bytes(peer64),
        type: KeyPairType.x25519);
    final shared = await _keyExchange.sharedSecretKey(
        keyPair: chat.pair!, remotePublicKey: peerPublic);
    final sessionBytes = utf8.encode(id);
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final ab = await hkdf.deriveKey(secretKey: shared,
        nonce: sessionBytes, info: utf8.encode('PG-alpha-A-to-B'));
    final ba = await hkdf.deriveKey(secretKey: shared,
        nonce: sessionBytes, info: utf8.encode('PG-alpha-B-to-A'));
    if (chat.cleared) {
      ab.destroy();
      ba.destroy();
      return;
    }
    chat.sendKey = chat.role == 'A' ? ab : ba;
    chat.receiveKey = chat.role == 'A' ? ba : ab;
    final pubA = chat.role == 'A' ? chat.publicKey!.bytes : peerPublic.bytes;
    final pubB = chat.role == 'B' ? chat.publicKey!.bytes : peerPublic.bytes;
    final hash = await Sha256().hash([
      ...utf8.encode('PG-alpha-safety'), ...sessionBytes, ...pubA, ...pubB
    ]);
    final code = hash.bytes.take(6)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join().toUpperCase();
    if (!chat.cleared) {
      chat.safetyCode =
          '${code.substring(0, 4)} ${code.substring(4, 8)} ${code.substring(8, 12)}';
    }
  }

  Future<void> _approve() async {
    final chat = _selectedChat;
    if (_busy || chat?.sessionId == null) return;
    setState(() { _busy = true; _error = null; });
    try {
      await _request('POST', '/v1/sessions/${chat!.sessionId}/approve', {});
      await _fetchSession(chat);
    } catch (e) {
      _setError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendMessage({String? overrideText}) async {
    final chat = _selectedChat;
    if (_busy || chat?.sendKey == null || chat?.sessionId == null ||
        chat?.page != 'chat') return;
    final text = overrideText ?? _messageInput.text.trim();
    if (text.isEmpty || text.length > 2000) return;
    final reply = overrideText == null ? _replyTarget : null;
    if (reply != null && text.length > 1450) {
      _setError('Replies must be shorter than 1,450 characters.');
      return;
    }
    final quoted = reply == null ? null : _replyPreview(reply);
    final wire = reply == null
        ? text : encodePgReply(text, quoted!, reply.mine);
    if (wire.length > 2000) {
      _setError('Reply is too long. Shorten the message.');
      return;
    }
    final id = chat!.sessionId!;
    final key = chat.sendKey!;
    final role = chat.role!;
    setState(() { _busy = true; _error = null; });
    try {
      final rand = Random.secure();
      final nonce = List<int>.generate(12, (_) => rand.nextInt(256));
      final box = await _cipher.encrypt(utf8.encode(wire),
          secretKey: key, nonce: nonce,
          aad: utf8.encode('PG|$id|$role'));
      await _request('POST', '/v1/sessions/$id/messages', {
        'iv': _b64(box.nonce),
        'ciphertext': _b64(box.cipherText),
        'mac': _b64(box.mac.bytes),
      });
      if (!mounted || chat.cleared || !_chats.contains(chat)) return;
      setState(() {
        chat.messages.add(PgMessage(
          text, true, quotedText: quoted, quotedMine: reply?.mine));
        if (identical(_selectedChat, chat)) {
          if (reply != null) _replyTarget = null;
          if (overrideText == null) {
            _messageInput.clear();
            chat.draft = '';
          } else {
            _pickerMode = 'none';
          }
        }
      });
      if (identical(_selectedChat, chat)) _scrollDown();
    } catch (e) {
      _setError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pollMessages(PgConversation chat) async {
    final id = chat.sessionId;
    final key = chat.receiveKey;
    if (id == null || key == null || chat.cleared) return;
    final answer = await _request('GET', '/v1/sessions/$id/messages');
    final items = (answer['messages'] as List<dynamic>?) ?? [];
    if (items.isEmpty || chat.cleared || !_chats.contains(chat)) return;
    final newItems = <PgMessage>[];
    final opposite = chat.role == 'A' ? 'B' : 'A';
    for (final item in items) {
      try {
        final m = item as Map<String, dynamic>;
        final box = SecretBox(_bytes(m['ciphertext'] as String),
            nonce: _bytes(m['iv'] as String),
            mac: Mac(_bytes(m['mac'] as String)));
        final clear = await _cipher.decrypt(box,
            secretKey: key, aad: utf8.encode('PG|$id|$opposite'));
        newItems.add(PgMessage.fromWire(utf8.decode(clear), false));
      } catch (_) {
        newItems.add(PgMessage('Message authentication failed', false));
      }
    }
    if (!mounted || chat.cleared || !_chats.contains(chat)) return;
    final showingThisChat =
        identical(_selectedChat, chat) && chat.page == 'chat';
    setState(() => chat.receive(newItems, visible: showingThisChat));
    if (showingThisChat) {
      _scrollDown();
    } else {
      // OS local alert is available only while PG is running. Full background
      // push requires a separate private push-token and server infrastructure.
      unawaited(_showPrivateIncomingNotification());
      // Foreground in-app notice; never include message content.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || chat.cleared || !_chats.contains(chat)) return;
        final messenger = ScaffoldMessenger.maybeOf(context);
        messenger?.hideCurrentSnackBar();
        messenger?.showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 5),
          content: const Text('New private message in PG'),
          action: SnackBarAction(label: 'OPEN', onPressed: () {
            if (mounted && !chat.cleared && _chats.contains(chat)) {
              _openChat(chat);
            }
          }),
        ));
      });
    }
  }

  void _closeLocalChat(PgConversation chat) {
    if (_calls.sessionId == chat.sessionId && _calls.callId != null) {
      unawaited(_calls.close(sendEnd: false));
    }
    if (identical(_selectedChat, chat)) _replyTarget = null;
    chat.clearSensitive();
    chat.page = 'ended';
    if (mounted) {
      setState(() {
        if (identical(_selectedChat, chat)) _messageInput.clear();
      });
    }
  }

  Future<void> _endChat() async {
    final chat = _selectedChat;
    if (_ending || chat == null) return;
    _ending = true;
    final sessionId = chat.sessionId;
    try {
      if (sessionId != null) {
        await _request('POST', '/v1/sessions/$sessionId/end', {});
      }
    } catch (e) {
      _setError('Server did not confirm session termination. $e');
    } finally {
      _closeLocalChat(chat);
      _ending = false;
    }
  }

  Future<void> _stopToHome() async {
    final chat = _selectedChat;
    if (chat == null) return;
    final inviteId = chat.inviteId;
    final sessionId = chat.sessionId;
    try {
      if (chat.page != 'ended' && inviteId != null) {
        await _request('POST', '/v1/invites/$inviteId/revoke', {});
      } else if (chat.page != 'ended' && sessionId != null) {
        await _request('POST', '/v1/sessions/$sessionId/end', {});
      }
    } catch (e) {
      _setError('Could not confirm termination on server: $e');
    }
    if (_calls.sessionId == sessionId && _calls.callId != null) {
      await _calls.close(sendEnd: false);
    }
    chat.clearSensitive();
    if (!mounted) return;
    setState(() {
      _chats.remove(chat);
      if (identical(_selectedChat, chat)) {
        _selectedChat = null;
        _messageInput.clear();
      }
    });
  }

  Future<List<Map<String, dynamic>>> _loadIceServers(String sid) async {
    const fallback = <Map<String, dynamic>>[
      {'urls': 'stun:stun.l.google.com:19302'},
    ];
    try {
      final result = await _request('GET', '/v1/sessions/$sid/ice');
      final source = result['iceServers'];
      if (source is! List) return fallback;
      final out = <Map<String, dynamic>>[];
      for (final value in source) {
        if (value is! Map) continue;
        final data = Map<String, dynamic>.from(value);
        final urls = data['urls'];
        if (urls is! String && urls is! List) continue;
        if (urls is List &&
            (urls.isEmpty || !urls.every((v) => v is String))) continue;
        out.add(data);
      }
      return out.isEmpty ? fallback : out;
    } catch (_) {
      // Older PG relay versions have no ICE route; keep existing STUN-only
      // behavior for alpha backward compatibility, not a TURN guarantee.
      return fallback;
    }
  }

  Future<void> _sendCallSignal(
    String sid, String cid, String type, Map<String, dynamic> data) async {
    await _request('POST', '/v1/sessions/$sid/call', {
      'callId': cid, 'type': type, 'data': data,
    });
  }

  Future<bool> _confirmIncomingCall(PgConversation chat, bool isVideo) async {
    if (!mounted || chat.cleared || !_chats.contains(chat)) return false;
    final accepted = await showDialog<bool>(context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: _surface,
        title: Text(isVideo ? 'Incoming PG video call' : 'Incoming PG voice call'),
        content: const Text('This is an experimental, unaudited WebRTC call. '
          'Accept only from a contact whose safety code you verified.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Decline')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Answer')),
        ],
      ));
    if (accepted == true && mounted && !chat.cleared) {
      _openChat(chat);
    }
    return accepted == true && mounted && !chat.cleared;
  }

  Future<void> _pollCallSignals(PgConversation chat) async {
    final sid = chat.sessionId;
    if (sid == null || chat.cleared) return;
    final data = await _request('GET', '/v1/sessions/$sid/call');
    final signals = data['signals'];
    if (signals is! List) return;
    for (final item in signals) {
      if (!mounted || chat.cleared || !_chats.contains(chat)) break;
      try {
        await _calls.handle(
          sid, Map<String, dynamic>.from(item as Map),
          confirmIncoming: (video) => _confirmIncomingCall(chat, video),
        );
        if (_calls.sessionId == sid &&
            _calls.callId != null && !_showingCallPanel) {
          unawaited(_openCallPanel());
        }
      } catch (error) {
        _setError('Call signaling failed. $error');
      }
    }
  }

  Future<void> _startCall(bool video) async {
    final chat = _selectedChat;
    if (chat == null || chat.page != 'chat' || chat.sessionId == null ||
        _calls.callId != null || _busy) return;
    try {
      final approved = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(video ? 'Start video call?' : 'Start voice call?'),
          content: const Text(
            'Experimental PG calls are not security-audited. '
            'WebRTC and the STUN service may learn network metadata '
            'including IP addresses. This is for testing, not confidential calls.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Call')),
          ],
        ),
      );
      if (approved != true || !mounted || chat.cleared ||
          !_chats.contains(chat) || chat.page != 'chat') return;
      await _calls.dial(chat.sessionId!, withVideo: video);
      if (mounted && _calls.callId != null) unawaited(_openCallPanel());
    } catch (error) {
      _setError('Unable to start call. $error');
    }
  }

  Future<void> _openCallPanel() async {
    if (!mounted || _showingCallPanel) return;
    _showingCallPanel = true;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => PopScope<void>(
          canPop: false,
          child: Dialog.fullscreen(
            backgroundColor: _bg,
            child: SafeArea(
              child: AnimatedBuilder(
                animation: _calls,
                builder: (ctx, _) => Stack(children: [
                  // Remote video occupies the entire available display.
                  // Contain, never Cover, so no part of the incoming frame is
                  // cut off on devices with unusual screen aspect ratios.
                  if (_calls.video && _calls.callId != null)
                    Positioned.fill(child: ColoredBox(
                      color: Colors.black,
                      child: RTCVideoView(
                        _calls.remoteVideo,
                        objectFit:
                          RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                        mirror: false,
                      ),
                    ))
                  else
                    const Positioned.fill(child: Center(
                      child: Icon(Icons.record_voice_over_rounded,
                        size: 100, color: _muted),
                    )),
                  // Keep call information readable, without overlaying most
                  // of the picture with a small dialog or fixed-height panel.
                  Positioned(
                    left: 16, top: 12,
                    right: _calls.video ? 145 : 16,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_calls.callId == null ? 'Call ended'
                          : _calls.active ? 'PG call connected'
                          : 'Connecting PG call…',
                          style: const TextStyle(
                            color: _white, fontSize: 19,
                            fontWeight: FontWeight.w800,
                            shadows: [Shadow(
                              color: Colors.black87, blurRadius: 8)])),
                        const SizedBox(height: 4),
                        const Text('EXPERIMENTAL · NOT SECURITY AUDITED',
                          style: TextStyle(color: _danger, fontSize: 10,
                            fontWeight: FontWeight.w700,
                            shadows: [Shadow(
                              color: Colors.black, blurRadius: 6)])),
                        if (_calls.video && _calls.callId != null &&
                            !_calls.remoteVideoReady) ...[
                          const SizedBox(height: 8),
                          const Text('Waiting for incoming video…',
                            style: TextStyle(color: _white, fontSize: 12,
                              shadows: [Shadow(
                                color: Colors.black, blurRadius: 6)])),
                        ],
                      ],
                    ),
                  ),
                  if (_calls.video && _calls.callId != null)
                    Positioned(
                      right: 14, top: 12,
                      width: 118, height: 164,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(15),
                        child: ColoredBox(
                          color: _surface,
                          child: RTCVideoView(
                            _calls.localVideo,
                            mirror: true,
                            objectFit: RTCVideoViewObjectFit
                                .RTCVideoViewObjectFitCover,
                          ),
                        ),
                      ),
                    ),
                  // Controls stay at the bottom without shrinking the remote
                  // image. Leave room for the navigation bar and notches.
                  Positioned(
                    bottom: 18, left: 12, right: 12,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        color: _surface.withValues(alpha: 0.94),
                        borderRadius: BorderRadius.circular(30),
                      ),
                      child: _calls.callId != null
                        ? Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              IconButton.filledTonal(
                                tooltip: _calls.muted ? 'Unmute' : 'Mute',
                                onPressed: _calls.toggleMute,
                                icon: Icon(_calls.muted
                                  ? Icons.mic_off_rounded : Icons.mic_rounded),
                              ),
                              if (_calls.video) ...[
                                const SizedBox(width: 16),
                                IconButton.filledTonal(
                                  tooltip: 'Toggle camera',
                                  onPressed: _calls.toggleCamera,
                                  icon: const Icon(
                                    Icons.videocam_off_outlined),
                                ),
                              ],
                              const SizedBox(width: 24),
                              IconButton.filled(
                                tooltip: 'Hang up',
                                style: IconButton.styleFrom(
                                  backgroundColor: _danger),
                                onPressed: () async {
                                  await _calls.close();
                                  if (dialogContext.mounted) {
                                    Navigator.pop(dialogContext);
                                  }
                                },
                                icon: const Icon(
                                  Icons.call_end_rounded, color: _bg),
                              ),
                            ],
                          )
                        : FilledButton(
                            onPressed: () => Navigator.pop(dialogContext),
                            child: const Text('Close call'),
                          ),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
      );
    } finally {
      _showingCallPanel = false;
    }
  }

  Future<void> _pickAndSendAttachment(String category) async {
    final chat = _selectedChat;
    if (_busy || chat == null || chat.page != 'chat' ||
        chat.sessionId == null || _token == null) return;
    try {
      String filename;
      late final List<int> data;
      String kind = category;
      if (category == 'document') {
        // file_picker 12.x uses a federated Android plugin compatible with
        // AGP 9 and exposes a single PlatformFile through pickFile().
        final selected = await FilePicker.pickFile(type: FileType.any);
        if (selected == null) return;
        final fileLength = await selected.length();
        if (fileLength < 1 || fileLength > pgFileMaxBytes) {
          throw StateError('Choose a non-empty file smaller than 12 MB for PG alpha.');
        }
        filename = selected.name;
        data = await selected.readAsBytes();
        kind = 'document';
      } else {
        XFile? selected;
        if (category == 'camera') {
          selected = await _imagePicker.pickImage(source: ImageSource.camera);
          kind = 'image';
        } else if (category == 'image') {
          selected = await _imagePicker.pickImage(source: ImageSource.gallery);
        } else if (category == 'video') {
          selected = await _imagePicker.pickVideo(source: ImageSource.gallery);
        }
        if (selected == null) return;
        filename = selected.name;
        final fileLength = await selected.length();
        if (fileLength < 1 || fileLength > pgFileMaxBytes) {
          throw StateError('Choose a non-empty file smaller than 12 MB for PG alpha.');
        }
        data = await selected.readAsBytes();
      }
      if (data.isEmpty || data.length > pgFileMaxBytes) {
        throw StateError('Choose a non-empty file smaller than 12 MB for PG alpha.');
      }
      if (!mounted || !_chats.contains(chat) || chat.cleared) return;
      setState(() { _busy = true; _error = null; });
      final attachment = await pgUploadEncrypted(
        client: _http!, apiBase: _apiBase, token: _token!,
        sessionId: chat.sessionId!, clearBytes: data,
        filename: filename, kind: kind);
      if (!mounted || chat.cleared || !_chats.contains(chat)) return;
      setState(() => _busy = false);
      // Metadata, the random file key and filename travel INSIDE the
      // encrypted session message, not to the attachment upload endpoint.
      if (identical(_selectedChat, chat)) {
        await _sendMessage(overrideText: attachment.encodeMessage());
      } else {
        _openChat(chat);
        await _sendMessage(overrideText: attachment.encodeMessage());
      }
    } catch (error) {
      _setError('Attachment could not be sent. $error');
    } finally {
      if (mounted && _busy) setState(() => _busy = false);
    }
  }

  void _showAttachmentOptions() {
    if (_busy || _page != 'chat') return;
    FocusManager.instance.primaryFocus?.unfocus();
    showModalBottomSheet<void>(
      context: context, backgroundColor: _surface,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.image_outlined, color: _teal),
            title: const Text('Photo from gallery'),
            onTap: () { Navigator.pop(sheetContext); _pickAndSendAttachment('image'); }),
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined, color: _orange),
            title: const Text('Take a photo'),
            onTap: () { Navigator.pop(sheetContext); _pickAndSendAttachment('camera'); }),
          ListTile(
            leading: const Icon(Icons.videocam_outlined, color: _teal),
            title: const Text('Video from gallery'),
            onTap: () { Navigator.pop(sheetContext); _pickAndSendAttachment('video'); }),
          ListTile(
            leading: const Icon(Icons.insert_drive_file_outlined, color: _orange),
            title: const Text('Document or other file'),
            subtitle: const Text('PDF, Word, Excel and more · up to 12 MB'),
            onTap: () { Navigator.pop(sheetContext); _pickAndSendAttachment('document'); }),
          const SizedBox(height: 12),
        ],
      )),
    );
  }

  Future<void> _openReceivedAttachment(PgAttachment attachment) async {
    final chat = _selectedChat;
    if (chat == null || chat.page != 'chat' ||
        chat.sessionId == null || _token == null) return;
    try {
      setState(() { _busy = true; _error = null; });
      final bytes = await pgDownloadDecrypted(
        client: _http!, apiBase: _apiBase, token: _token!,
        sessionId: chat.sessionId!, attachment: attachment);
      if (!mounted || chat.cleared || !_chats.contains(chat)) return;
      setState(() => _busy = false);
      if (attachment.kind == 'image') {
        await showDialog<void>(context: context,
          builder: (ctx) => Dialog(
            backgroundColor: _bg,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(ctx).height * 0.68,
                  maxWidth: MediaQuery.sizeOf(ctx).width * 0.92),
                child: Image.memory(bytes, fit: BoxFit.contain),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close image'),
              ),
            ]),
          ),
        );
      } else {
        final approved = await showDialog<bool>(context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Open attachment outside PG?'),
            content: const Text('This may create a readable temporary file. '
              'Other apps or the operating system can retain copies. '
              'Do not open confidential files in this experimental build.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Open file')),
            ],
          ));
        if (approved != true || !mounted || chat.cleared) return;
        final directory = await getTemporaryDirectory();
        final file = File('${directory.path}/pg_${DateTime.now().microsecondsSinceEpoch}_${pgSafeFilename(attachment.name)}');
        await file.writeAsBytes(bytes, flush: true);
        chat.temporaryDecryptedFiles.add(file);
        await OpenFilex.open(file.path);
      }
    } catch (error) {
      _setError('Cannot open attachment. $error');
    } finally {
      if (mounted && _busy) setState(() => _busy = false);
    }
  }

  Widget _buildAttachmentBubble(PgAttachment attachment, bool mine) {
    final icon = switch (attachment.kind) {
      'image' => Icons.image_outlined,
      'video' => Icons.video_file_outlined,
      'audio' => Icons.audio_file_outlined,
      _ => Icons.description_outlined,
    };
    return InkWell(
      onTap: mine || _busy ? null : () => _openReceivedAttachment(attachment),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: _teal, size: 32),
        const SizedBox(width: 10),
        Flexible(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(attachment.name, maxLines: 2, overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: _white, fontWeight: FontWeight.w700)),
          const SizedBox(height: 3),
          Text(mine ? 'Sent · encrypted' : 'Tap to open · temporary',
            style: const TextStyle(color: _muted, fontSize: 11)),
        ])),
      ]),
    );
  }

  String _replyPreview(PgMessage message) {
    final attachment = PgAttachment.fromMessage(message.text);
    if (attachment != null) return 'Attachment: ${attachment.name}';
    final status = decodePgStatus(message.text);
    if (status != null) return status.label;
    final sticker = decodePgSticker(message.text);
    if (sticker != null) return 'Sticker $sticker';
    final normal = message.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return normal.length > 150 ? '${normal.substring(0, 149)}…' : normal;
  }

  void _replyTo(PgMessage message) {
    final chat = _selectedChat;
    if (chat == null || chat.cleared || chat.page != 'chat' ||
        !chat.messages.contains(message)) return;
    setState(() {
      _pickerMode = 'none';
      _replyTarget = message;
    });
    _messageFocus.requestFocus();
  }

  Widget _replyPreviewBar() {
    final target = _replyTarget;
    if (target == null) return const SizedBox.shrink();
    return Container(
      key: const ValueKey('pg-reply-preview'),
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: _surface,
        border: Border(left: BorderSide(color: _teal, width: 3)),
      ),
      child: Row(children: [
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(target.mine ? 'Replying to yourself' : 'Replying to contact',
              style: const TextStyle(fontSize: 11, color: _teal,
                fontWeight: FontWeight.w800)),
            const SizedBox(height: 3),
            Text(_replyPreview(target),
              maxLines: 2, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: _white, fontSize: 12)),
          ],
        )),
        IconButton(
          tooltip: 'Cancel reply',
          onPressed: () => setState(() => _replyTarget = null),
          icon: const Icon(Icons.close_rounded, color: _muted),
        ),
      ]),
    );
  }

  Widget _pgStatusArtwork(PgStatusIcon status, {double size = 58}) {
    return Container(
      width: size, height: size,
      decoration: BoxDecoration(
        color: const Color(0xFF0D2530),
        borderRadius: BorderRadius.circular(size * .28),
        border: Border.all(color: status.color.withValues(alpha: 0.5), width: 2),
        boxShadow: [BoxShadow(
          color: status.color.withValues(alpha: 0.17),
          blurRadius: 12, spreadRadius: 1)],
      ),
      child: Stack(alignment: Alignment.center, children: [
        Icon(status.icon, size: size * .52, color: status.color),
        Positioned(right: size * .1, bottom: size * .08,
          child: Container(
            decoration: const BoxDecoration(
              shape: BoxShape.circle, color: Color(0xFF133D37)),
            child: Icon(Icons.check_rounded,
              size: size * .20, color: const Color(0xFFFFB238)),
          )),
      ]),
    );
  }

  Widget _pgStatusMessage(PgStatusIcon status) =>
    Column(mainAxisSize: MainAxisSize.min, children: [
      _pgStatusArtwork(status, size: 76),
      const SizedBox(height: 6),
      Text(status.label,
        style: const TextStyle(color: _white, fontSize: 12,
          fontWeight: FontWeight.w800)),
    ]);

  void _togglePicker(String mode) {
    FocusManager.instance.primaryFocus?.unfocus();
    if (!mounted || _page != 'chat') return;
    setState(() => _pickerMode = _pickerMode == mode ? 'none' : mode);
  }

  Widget _buildChatPicker() => Container(
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 10),
    decoration: BoxDecoration(
      color: _surface,
      border: Border.all(color: _stroke),
      borderRadius: BorderRadius.circular(18),
    ),
    child: SizedBox(height: 236, child: SingleChildScrollView(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('PG EXCLUSIVE', style: TextStyle(
          color: _teal, fontSize: 11, letterSpacing: 1.2,
          fontWeight: FontWeight.w900)),
        const SizedBox(height: 8),
        SizedBox(height: 110, child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: pgStatusIcons.length,
          separatorBuilder: (_, _) => const SizedBox(width: 10),
          itemBuilder: (context, index) {
            final status = pgStatusIcons[index];
            return InkWell(
              key: ValueKey('pg-status-${status.id}'),
              borderRadius: BorderRadius.circular(12),
              onTap: _busy ? null : () =>
                  _sendMessage(overrideText: encodePgStatus(status.id)),
              child: SizedBox(width: 86, child: Column(children: [
                _pgStatusArtwork(status, size: 68),
                const SizedBox(height: 6),
                Text(status.label, maxLines: 2,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: _white, fontSize: 10,
                    fontWeight: FontWeight.w700)),
              ])),
            );
          },
        )),
        const SizedBox(height: 10),
        const Text('CLASSIC STICKERS', style: TextStyle(
          color: _muted, fontSize: 11, letterSpacing: 1.2,
          fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        SizedBox(height: 54, child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            for (final glyph in _pgStickerChoices)
              SizedBox(width: 55, height: 52, child: IconButton(
                tooltip: 'Send sticker $glyph',
                padding: EdgeInsets.zero,
                onPressed: _busy ? null : () =>
                    _sendMessage(overrideText: encodePgSticker(glyph)),
                icon: Text(glyph, style: const TextStyle(fontSize: 34)),
              )),
          ],
        )),
      ]),
    )),
  );

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      _scroll.animateTo(max,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut);
    });
  }

  Future<void> _renameChat(PgConversation chat) async {
    if (chat.cleared || chat.page == 'ended' || !mounted) return;
    final chosen = await showDialog<String>(
      context: context,
      builder: (_) => PgRenameDialog(initialName: chat.nickname ?? ''),
    );
    if (!mounted || chosen == null || chat.cleared ||
        !_chats.contains(chat)) return;
    setState(() => chat.rename(chosen));
  }

  // WhatsApp Status-inspired horizontal session selector.
  // Nicknames and unread counters never leave this device.
  Widget _sessionStrip() {
    final live = _chats.where((chat) =>
        !chat.cleared && chat.page != 'ended').toList(growable: false);
    if (live.isEmpty) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _stroke))),
      padding: const EdgeInsets.fromLTRB(0, 10, 0, 8),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 17),
          child: Row(children: [
            const Text('SESSIONS', style: TextStyle(
              color: _muted, fontWeight: FontWeight.w800,
              letterSpacing: 1.3, fontSize: 10)),
            const SizedBox(width: 9),
            Text('${_activeCount} active',
              style: const TextStyle(color: _muted, fontSize: 11)),
            const Spacer(),
            if (_totalUnread > 0) Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(color: _orange,
                borderRadius: BorderRadius.circular(14)),
              child: Text('${_totalUnread > 99 ? '99+' : _totalUnread} unread',
                style: const TextStyle(color: _bg,
                  fontWeight: FontWeight.w800, fontSize: 10)),
            ),
          ]),
        ),
        const SizedBox(height: 9),
        SizedBox(height: 82, child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 11),
          children: [
            for (final chat in live)
              Padding(padding: const EdgeInsets.only(right: 7),
                child: SizedBox(width: 74, child: Tooltip(
                  message: '${chat.title}: ${chat.status}. Hold to rename.',
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _openChat(chat),
                    onLongPress: () => _renameChat(chat),
                    child: Column(children: [
                      SizedBox(width: 54, height: 54, child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Container(
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle, color: _field,
                              border: Border.all(
                                color: identical(_selectedChat, chat)
                                    ? _orange
                                    : chat.page == 'chat' ? _teal : _stroke,
                                width: identical(_selectedChat, chat) ? 2.5 : 1.5)),
                            child: Text(chat.initials, style: const TextStyle(
                              color: _white, fontWeight: FontWeight.w800,
                              fontSize: 15)),
                          ),
                          if (chat.unreadCount > 0)
                            Positioned(right: -6, top: -4,
                              child: Container(
                                constraints: const BoxConstraints(minWidth: 20),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 3),
                                decoration: BoxDecoration(color: _orange,
                                  border: Border.all(color: _bg, width: 1.3),
                                  borderRadius: BorderRadius.circular(20)),
                                child: Text(chat.unreadCount > 99
                                    ? '99+' : '${chat.unreadCount}',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(color: _bg,
                                    fontSize: 10, fontWeight: FontWeight.w800)),
                              )),
                        ])),
                      const SizedBox(height: 5),
                      Text(chat.title, maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 11,
                          color: identical(_selectedChat, chat)
                              ? _white : _muted,
                          fontWeight: identical(_selectedChat, chat)
                              ? FontWeight.w800 : FontWeight.w500)),
                    ]),
                  ),
                )),
              ),
            if (live.length < _maxLiveChats)
              SizedBox(width: 73, child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _busy ? null : _createInvite,
                child: Column(children: [
                  Container(
                    width: 54, height: 54,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _orange.withValues(alpha: 0.1),
                      border: Border.all(color: _orange, width: 1.5)),
                    child: const Icon(Icons.add_rounded,
                      color: _orange, size: 26)),
                  const SizedBox(height: 5),
                  const Text('New chat', style: TextStyle(
                    fontSize: 11, color: _orange)),
                ]),
              )),
          ],
        )),
      ]),
    );
  }

  void _showSafetyCode() {
    final code = _selectedChat?.safetyCode ?? 'Unavailable';
    showDialog<void>(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: _surface,
      title: const Text('Verify this conversation'),
      content: Text('Safety code: $code\n\nCompare it with your contact '
          'over another trusted channel. This alpha protocol is not audited.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx),
            child: const Text('Close')),
      ],
    ));
  }

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

  Future<void> _editServerAddress() async {
    if (!mounted) return;
    final chosen = await showDialog<String>(
      context: context,
      builder: (_) => PgServerAddressDialog(initialUrl: _apiBase),
    );
    if (!mounted || chosen == null) return;
    final trimmed = chosen.trim();
    final address = trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1) : trimmed;
    if (!_validPgServerUrl(address)) {
      _setError('Enter the exact HTTPS address from your Render dashboard.');
      return;
    }
    if (address == _apiBase) {
      if (_token == null) await _register();
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Switch PG servers?'),
        content: const Text(
          'This removes active chats and session keys from this phone. '
          'PG cannot confirm deletion on the previous server if it is '
          'unreachable. You will need new invitations.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Switch server')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _calls.close(sendEnd: false);
    _http?.close(force: true);
    _http = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    setState(() {
      for (final chat in _chats) chat.clearSensitive();
      _chats.clear();
      _selectedChat = null;
      _messageInput.clear();
      _inviteInput.clear();
      _replyTarget = null;
      _pickerMode = 'none';
      _apiBase = address;
      _token = null;
      _deviceId = null;
      _error = null;
    });
    try {
      await SharedPreferencesAsync().setString('pg_server_url_v1', address);
    } catch (_) {
      _setError('PG could not save the server URL for the next app launch.');
    }
    if (mounted) await _register();
  }

  Future<void> _testNotification() async {
    if (!mounted || !Platform.isAndroid) return;
    await _requestNotificationPermission();
    try {
      final delivered =
          await _privateAlerts.invokeMethod<bool>('showPrivateMessage');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(delivered == true
          ? 'PG sent a test alert. Check the notification shade.'
          : 'Notifications are blocked in Android settings.'),
      ));
    } catch (_) {
      _setError('Could not generate the test notification.');
    }
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
              const SizedBox(height: 16),
              _secondaryAction('Change server address', () {
                Navigator.pop(sheetContext);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) unawaited(_editServerAddress());
                });
              }, icon: Icons.settings_ethernet_rounded),
              const SizedBox(height: 10),
              _secondaryAction('Test Android notification', () {
                Navigator.pop(sheetContext);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) unawaited(_testNotification());
                });
              }, icon: Icons.notifications_active_outlined),
              const SizedBox(height: 12),
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
    // Keep the same widget positions when the keyboard opens. Moving the
    // TextField to another element slot used to make Android lose focus.
    final typing = online && _page == 'chat' &&
        MediaQuery.viewInsetsOf(context).bottom > 0;
    final connected = online && _page == 'chat';
    return PopScope<void>(
      // Back from a conversation returns to the list; back from home exits.
      canPop: _selectedChat == null && _pickerMode == 'none',
      onPopInvokedWithResult: (didPop, result) {
        if (didPop || !mounted) return;
        if (_pickerMode != 'none') {
          setState(() => _pickerMode = 'none');
        } else if (_selectedChat != null) {
          _returnHome();
        }
      },
      child: Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        toolbarHeight: 66,
        titleSpacing: _selectedChat == null ? 18 : 0,
        leading: _selectedChat == null ? null : IconButton(
          tooltip: 'All conversations',
          onPressed: _returnHome,
          icon: const Icon(Icons.arrow_back_rounded, color: _white),
        ),
        title: Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.asset('assets/pg_brandmark.png',
              width: 38, height: 38, fit: BoxFit.cover),
          ),
          const SizedBox(width: 9),
          const Flexible(child: Text('PG',
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(color: _white,
              fontWeight: FontWeight.w800, fontSize: 19))),
          const SizedBox(width: 9),
          Container(width: 8, height: 8, decoration: BoxDecoration(
            color: connected ? _teal : (online ? _orange : _muted),
            shape: BoxShape.circle,
          )),
        ]),
        actions: [
          if (_selectedChat != null && !_selectedChat!.cleared && _page != 'chat')
            IconButton(
              tooltip: 'Rename conversation',
              onPressed: () => _renameChat(_selectedChat!),
              icon: const Icon(Icons.edit_outlined, color: _orange),
            ),
          if (online && _page == 'chat') ...[
            IconButton(
              tooltip: 'PG voice call (experimental)',
              onPressed: () => _startCall(false),
              icon: const Icon(Icons.call_outlined, color: _white),
            ),
            IconButton(
              tooltip: 'PG video call (experimental)',
              onPressed: () => _startCall(true),
              icon: const Icon(Icons.videocam_outlined, color: _white),
            ),
            PopupMenuButton<String>(
              tooltip: 'Conversation actions',
              icon: const Icon(Icons.more_vert_rounded, color: _white),
              color: _surface,
              onSelected: (value) {
                if (value == 'rename' && _selectedChat != null) {
                  _renameChat(_selectedChat!);
                }
                if (value == 'verify') _showSafetyCode();
                if (value == 'end') _confirmEnd();
                if (value == 'about') _showPrivacyNote();
              },
              itemBuilder: (ctx) => const [
                PopupMenuItem(value: 'rename', child: Text('Rename conversation')),
                PopupMenuItem(value: 'verify',
                  child: Text('Verify safety code')),
                PopupMenuItem(value: 'end',
                  child: Text('End conversation')),
                PopupMenuItem(value: 'about',
                  child: Text('About this alpha')),
              ],
            ),
          ]
          else
            IconButton(
              tooltip: 'Privacy and build information',
              onPressed: _showPrivacyNote,
              icon: const Icon(Icons.info_outline_rounded, color: _muted),
            ),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(gradient: LinearGradient(
          begin: Alignment.topCenter, end: Alignment.bottomCenter,
          colors: [_bg, Color(0xFF101D2E)],
        )),
        child: SafeArea(child: Column(children: [
          Visibility(
            visible: !typing,
            maintainState: true,
            child: Container(
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
          ),
          Visibility(
            visible: _error != null,
            maintainState: true,
            child: _error != null ? _errorBanner() : const SizedBox.shrink(),
          ),
          Visibility(
            visible: !typing,
            maintainState: true,
            child: _sessionStrip(),
          ),
          Expanded(child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
            child: KeyedSubtree(
              key: ValueKey<String>(
                '${_selectedChat?.number ?? 0}:${_page}:${online ? "online" : "offline"}'),
              child: _renderBody(online),
            ),
          )),
          Visibility(
            visible: !typing,
            maintainState: true,
            child: _connectionFooter(online),
          ),
        ])),
      ),
      ),
    );
  }

  Widget _renderBody(bool online) {
    if (!online) return Center(child: SingleChildScrollView(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        _iconTile(Icons.cloud_off_outlined, color: _orange),
        const SizedBox(height: 20),
        const Text('Connecting to PG', style: TextStyle(
          fontSize: 23, fontWeight: FontWeight.w800, color: _white)),
        const SizedBox(height: 11),
        const Text('The app needs a reachable PG server before you can invite contacts or chat.',
          textAlign: TextAlign.center,
          style: TextStyle(color: _muted, fontSize: 14, height: 1.5)),
        const SizedBox(height: 22),
        _primaryAction('Try connecting again', _register,
          icon: Icons.refresh_rounded),
        const SizedBox(height: 12),
        _secondaryAction('Change server address', _editServerAddress,
          icon: Icons.settings_ethernet_rounded),
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
          _primaryAction(_inviteCode == null
              ? 'Creating invitation…' : 'Share invitation', _shareInvite,
            disabled: _inviteCode == null, icon: Icons.share_rounded),
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
      // No large contact card: status is the dot beside PrivateGet.
      // Safety verification remains available in the top toolbar.
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
                child: InkWell(
                  key: ValueKey('pg-message-$index'),
                  onLongPress: () => _replyTo(message),
                  borderRadius: BorderRadius.circular(16),
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
                        letterSpacing: 0.9, fontWeight: FontWeight.w800,
                        fontSize: 9)),
                    if (message.quotedText != null) ...[
                      const SizedBox(height: 7),
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: _bg.withValues(alpha: 0.55),
                          border: const Border(
                            left: BorderSide(color: _teal, width: 3)),
                        ),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(message.quotedMine == true ? 'You' : 'Contact',
                              style: const TextStyle(color: _teal, fontSize: 10,
                                fontWeight: FontWeight.w800)),
                            Text(message.quotedText!,
                              maxLines: 3, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: _muted, fontSize: 12)),
                          ]),
                      ),
                    ],
                    const SizedBox(height: 5),
                    if (PgAttachment.fromMessage(message.text) != null)
                      _buildAttachmentBubble(
                        PgAttachment.fromMessage(message.text)!, message.mine)
                    else if (message.text.startsWith(pgFilePrefix))
                      const Text('Unsupported attachment',
                        style: TextStyle(color: _muted))
                    else if (decodePgStatus(message.text) != null)
                      _pgStatusMessage(decodePgStatus(message.text)!)
                    else
                      Text(
                        decodePgSticker(message.text) ?? message.text,
                        style: TextStyle(
                          color: _white,
                          fontSize: decodePgSticker(message.text) == null ? 14 : 43,
                          height: 1.45,
                        ),
                      ),
                  ]),
                ),
                ),
              );
            },
          )),
      if (_pickerMode == 'sticker') _buildChatPicker(),
      if (_replyTarget != null) _replyPreviewBar(),
      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        IconButton(
          tooltip: 'Attach photo, video or document',
          icon: const Icon(Icons.add_circle_outline_rounded, color: _teal),
          onPressed: _busy ? null : _showAttachmentOptions,
        ),
        Expanded(child: TextField(
          controller: _messageInput,
          focusNode: _messageFocus,
          minLines: 1, maxLines: 3, maxLength: 2000,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            hintText: 'Message', counterText: '',
            filled: true,
            fillColor: _field,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16, vertical: 13),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(26),
              borderSide: const BorderSide(color: _stroke),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(26),
              borderSide: const BorderSide(color: _stroke),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(26),
              borderSide: const BorderSide(color: _orange, width: 1.5),
            ),
          ),
        )),
        IconButton(
          tooltip: 'Open emoji and sticker tray',
          icon: const Icon(Icons.emoji_emotions_outlined, color: _teal),
          onPressed: () => _togglePicker('sticker'),
        ),
        IconButton(
          tooltip: 'Take photo',
          icon: const Icon(Icons.camera_alt_outlined, color: _muted),
          onPressed: _busy ? null : () => _pickAndSendAttachment('camera'),
        ),
        SizedBox(width: 46, height: 48, child: IconButton.filled(
          tooltip: 'Send message',
          onPressed: _busy ? null : () => _sendMessage(),
          style: IconButton.styleFrom(
            backgroundColor: _orange, foregroundColor: _bg,
            shape: const CircleBorder(),
          ),
          icon: const Icon(Icons.send_rounded, size: 20),
        )),
      ]),

      // The composer remains the last child, fixed immediately above
      // the Android keyboard. Navigation/end controls live in the toolbar.
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
