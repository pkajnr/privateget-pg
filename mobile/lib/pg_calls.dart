// Experimental 1:1 audio/video calling over WebRTC.
// DTLS-SRTP encrypts transport, but the current PG relay/signaling and
// identity model are NOT audited and do not guarantee authenticated E2EE.
import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

typedef PgSendCallSignal = Future<void> Function(
  String sessionId, String callId, String type, Map<String, dynamic> data);

class PgCallService extends ChangeNotifier {
  PgCallService(this.send);
  final PgSendCallSignal send;
  final RTCVideoRenderer localVideo = RTCVideoRenderer();
  final RTCVideoRenderer remoteVideo = RTCVideoRenderer();

  RTCPeerConnection? _peer;
  MediaStream? _localMedia;
  String? sessionId, callId;
  bool video = false, muted = false, connecting = false, active = false;
  bool _remoteDescriptionReady = false;
  bool _renderersReady = false;
  final List<RTCIceCandidate> _earlyIce = [];

  Future<void> _ensureRenderers() async {
    if (_renderersReady) return;
    await localVideo.initialize();
    await remoteVideo.initialize();
    _renderersReady = true;
  }

  String _newCallId() {
    final rng = Random.secure();
    return List<int>.generate(16, (_) => rng.nextInt(256))
        .map((n) => n.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<void> _preparePeer(String sid, String cid, bool withVideo) async {
    sessionId = sid;
    callId = cid;
    video = withVideo;
    muted = false;
    connecting = true;
    notifyListeners();
    await _ensureRenderers();
    // STUN is for alpha connectivity, and may expose public IP addresses
    // to the STUN service. Production requires an audited, trusted TURN relay.
    _peer = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
    });
    _peer!.onIceCandidate = (candidate) {
      final id = callId, current = sessionId;
      if (id == null || current == null || candidate.candidate == null) return;
      unawaited(send(current, id, 'ice', {
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      }).catchError((Object _) {}));
    };
    _peer!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        remoteVideo.srcObject = event.streams.first;
        active = true;
        connecting = false;
        notifyListeners();
      }
    };
    _peer!.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        active = true;
        connecting = false;
        notifyListeners();
      }
    };
    _localMedia = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': withVideo ? {'facingMode': 'user'} : false,
    });
    localVideo.srcObject = _localMedia;
    for (final track in _localMedia!.getTracks()) {
      await _peer!.addTrack(track, _localMedia!);
    }
  }

  Future<void> dial(String sid, {required bool withVideo}) async {
    if (callId != null || connecting) throw StateError('A call is already open');
    final id = _newCallId();
    try {
      await _preparePeer(sid, id, withVideo);
      final offer = await _peer!.createOffer();
      await _peer!.setLocalDescription(offer);
      await send(sid, id, 'offer', {
        'sdp': offer.sdp ?? '', 'video': withVideo,
      });
    } catch (_) {
      await close(sendEnd: false);
      rethrow;
    }
  }

  Future<void> handle(
    String sid,
    Map<String, dynamic> event, {
    required Future<bool> Function(bool video) confirmIncoming,
  }) async {
    final incomingId = event['callId'];
    final type = event['type'];
    final data = event['data'];
    if (incomingId is! String || type is! String ||
        data is! Map<String, dynamic>) return;
    if (type == 'offer') {
      if (callId != null) {
        await send(sid, incomingId, 'decline', {});
        return;
      }
      final allowed = await confirmIncoming(data['video'] == true);
      if (!allowed) {
        await send(sid, incomingId, 'decline', {});
        return;
      }
      try {
        await _preparePeer(sid, incomingId, data['video'] == true);
        await _peer!.setRemoteDescription(
          RTCSessionDescription(data['sdp'] as String, 'offer'));
        _remoteDescriptionReady = true;
        await _applyEarlyIce();
        final answer = await _peer!.createAnswer();
        await _peer!.setLocalDescription(answer);
        await send(sid, incomingId, 'answer', {'sdp': answer.sdp ?? ''});
      } catch (_) {
        await close(sendEnd: true);
        rethrow;
      }
      return;
    }
    if (callId != incomingId || sessionId != sid) return;
    if (type == 'answer') {
      await _peer?.setRemoteDescription(
        RTCSessionDescription(data['sdp'] as String, 'answer'));
      _remoteDescriptionReady = true;
      await _applyEarlyIce();
    } else if (type == 'ice') {
      final candidate = data['candidate'];
      if (candidate is! String) return;
      final mline = data['sdpMLineIndex'];
      final ice = RTCIceCandidate(
        candidate, data['sdpMid'] as String?,
        mline is int ? mline : null,
      );
      if (_remoteDescriptionReady && _peer != null) {
        await _peer!.addCandidate(ice);
      } else {
        _earlyIce.add(ice);
      }
    } else if (type == 'end' || type == 'decline') {
      await close(sendEnd: false);
    }
  }

  Future<void> _applyEarlyIce() async {
    for (final candidate in _earlyIce) {
      await _peer?.addCandidate(candidate);
    }
    _earlyIce.clear();
  }

  void toggleMute() {
    muted = !muted;
    for (final track in _localMedia?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = !muted;
    }
    notifyListeners();
  }

  void toggleCamera() {
    for (final track in _localMedia?.getVideoTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = !track.enabled;
    }
    notifyListeners();
  }

  Future<void> close({bool sendEnd = true}) async {
    final sid = sessionId, cid = callId;
    callId = null; sessionId = null;
    _remoteDescriptionReady = false;
    _earlyIce.clear();
    active = false; connecting = false;
    notifyListeners();
    if (sendEnd && sid != null && cid != null) {
      try { await send(sid, cid, 'end', {}); } catch (_) {}
    }
    for (final track in _localMedia?.getTracks() ?? <MediaStreamTrack>[]) {
      track.stop();
    }
    await _localMedia?.dispose();
    _localMedia = null;
    localVideo.srcObject = null;
    remoteVideo.srcObject = null;
    await _peer?.close();
    await _peer?.dispose();
    _peer = null;
  }

  Future<void> shutdown() async {
    await close(sendEnd: false);
    if (_renderersReady) {
      await localVideo.dispose();
      await remoteVideo.dispose();
    }
    super.dispose();
  }
}
