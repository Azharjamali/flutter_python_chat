import 'dart:convert';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// SignalingService
/// =================
///
/// This class contains ALL the logic needed to set up one WebRTC video
/// call: talking to the Python signaling server over WebSocket, AND
/// driving the [RTCPeerConnection] that carries the actual audio/video.
///
/// If you're new to WebRTC, here's the mental model:
///
///   - A `RTCPeerConnection` is the object that actually sends/receives
///     audio+video directly between the two phones (peer-to-peer).
///   - Before it can do that, both sides need to swap two things:
///       1. SDP (Session Description Protocol) - a text blob describing
///          "what audio/video codecs and formats I support".
///          One side creates an "offer", the other replies with an
///          "answer".
///       2. ICE candidates - little chunks of "here's an IP/port you
///          might be able to reach me on". Each side can gather several
///          of these (e.g. one for WiFi, one via STUN) and sends them to
///          the other side as they're discovered ("trickle ICE").
///   - Our Python server's ONLY job is to act as the "postal service" for
///     that handshake: it relays these JSON messages between the two
///     clients in the same room. It never looks at audio/video itself.
///   - Once both sides have exchanged SDP + enough ICE candidates, the
///     `RTCPeerConnection`s connect directly to each other and start
///     streaming audio/video peer-to-peer. The signaling server is no
///     longer involved at that point.
class SignalingService {
  SignalingService({
    required this.serverIp,
    required this.room,
    this.serverPort = 8765,
  });

  final String serverIp;
  final int serverPort;
  final String room;

  // --- WebRTC objects ---------------------------------------------------

  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;

  /// These renderers are what the UI (`CallScreen`) actually displays in
  /// its two `RTCVideoView` widgets. We just point their `.srcObject` at
  /// the right `MediaStream` whenever it becomes available.
  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();

  // --- WebSocket (signaling) ---------------------------------------------

  WebSocketChannel? _channel;
  String? _deviceId;
  bool _isOfferer = false;

  /// UI callback so `CallScreen` can show a human-readable status string
  /// ("Waiting for peer...", "Connecting...", etc) as the handshake
  /// progresses. Purely cosmetic - not part of the WebRTC logic itself.
  void Function(String status)? onStatusChange;

  /// ICE candidates that arrive from the other peer BEFORE we've finished
  /// setting our own remote description are stashed here and applied
  /// afterwards - `RTCPeerConnection.addCandidate()` will throw if called
  /// before `setRemoteDescription()` has completed.
  final List<RTCIceCandidate> _pendingCandidates = [];
  bool _remoteDescriptionSet = false;

  /// STUN server: lets each peer discover its own public-facing IP/port
  /// when it's behind a router doing NAT. We're on the same WiFi network
  /// for this practice project, so a TURN server (which relays media when
  /// a direct connection isn't possible at all) isn't needed - STUN alone
  /// is enough to gather usable ICE candidates.
  static const Map<String, dynamic> _iceServers = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
    ],
  };

  // ------------------------------------------------------------------
  // STEP 0: kick everything off.
  // ------------------------------------------------------------------

  /// Call this once when the call screen opens. It sets up local media,
  /// creates the peer connection, then connects to the signaling server.
  Future<void> start() async {
    await localRenderer.initialize();
    await remoteRenderer.initialize();

    await _openLocalCamera();
    await _createPeerConnection();
    await _connectToSignalingServer();
  }

  // ------------------------------------------------------------------
  // STEP 1: connect to the Python signaling server over WebSocket.
  // ------------------------------------------------------------------

  /// Opens a WebSocket to `ws://<serverIp>:<serverPort>`, registers a
  /// stable device_id (required by the v2 server), then joins the room.
  Future<void> _connectToSignalingServer() async {
    onStatusChange?.call('Connecting to signaling server...');

    _deviceId = await _loadOrCreateDeviceId();
    final uri = Uri.parse('ws://$serverIp:$serverPort');
    _channel = WebSocketChannel.connect(uri);

    try {
      await _channel!.ready;
    } catch (_) {
      onStatusChange?.call(
        'Could not reach $serverIp:$serverPort. Is server.py running?',
      );
      return;
    }

    _channel!.stream.listen(
      (raw) {
        final message = jsonDecode(raw as String) as Map<String, dynamic>;
        _handleSignalingMessage(message);
      },
      onDone: () => onStatusChange?.call('Disconnected from signaling server'),
      onError: (_) => onStatusChange?.call('Signaling connection error'),
    );

    _sendMessage({'type': 'register', 'device_id': _deviceId});
    _sendMessage({'type': 'join', 'room': room, 'device_id': _deviceId});
  }

  Future<String> _loadOrCreateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    const key = 'webrtc_device_id';
    final existing = prefs.getString(key);
    if (existing != null && existing.isNotEmpty) return existing;

    final created = const Uuid().v4();
    await prefs.setString(key, created);
    return created;
  }

  /// Small helper: JSON-encode a message and send it over the WebSocket.
  /// Every message we send always includes "room" so the server knows
  /// which pair of clients to relay it between.
  void _sendMessage(Map<String, dynamic> message) {
    _channel?.sink.add(jsonEncode({
      ...message,
      'room': room,
      if (_deviceId != null) 'device_id': _deviceId,
    }));
  }

  // ------------------------------------------------------------------
  // STEP 2: create the RTCPeerConnection.
  // ------------------------------------------------------------------

  /// Creates the object that will actually carry audio/video between the
  /// two phones, and wires up its event callbacks:
  ///   - `onIceCandidate`: fires whenever WebRTC discovers a new possible
  ///     network path to us - we forward each one to the other peer via
  ///     the signaling server (step 6).
  ///   - `onTrack`: fires when the *other* peer's audio/video track
  ///     arrives - we display it (step 7).
  Future<void> _createPeerConnection() async {
    final pc = await createPeerConnection(_iceServers);

    // Attach our own camera+mic tracks so the other side receives them.
    // (getUserMedia already ran in `_openLocalCamera`.)
    for (final track in _localStream!.getTracks()) {
      await pc.addTrack(track, _localStream!);
    }

    // STEP 6 (send half): whenever our ICE agent finds a new candidate
    // (e.g. "here's my WiFi IP:port"), send it straight to the other peer.
    pc.onIceCandidate = (RTCIceCandidate candidate) {
      _sendMessage({
        'type': 'ice-candidate',
        'candidate': candidate.toMap(),
      });
    };

    // STEP 7: the other peer's media arrived - show it on screen by
    // pointing our remote renderer at their stream.
    pc.onTrack = (RTCTrackEvent event) {
      if (event.streams.isNotEmpty) {
        remoteRenderer.srcObject = event.streams.first;
        onStatusChange?.call('Remote video connected');
      }
    };

    pc.onConnectionState = (RTCPeerConnectionState state) {
      onStatusChange?.call('Connection state: $state');
    };

    _peerConnection = pc;
  }

  // ------------------------------------------------------------------
  // STEP 3: getUserMedia - grab the local camera + microphone.
  // ------------------------------------------------------------------

  /// flutter_webrtc's equivalent of the browser's
  /// `navigator.mediaDevices.getUserMedia()`. Returns a `MediaStream`
  /// containing one audio track and one video track from the device's
  /// default camera/mic, and immediately shows it in the local preview.
  Future<void> _openLocalCamera() async {
    final stream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': {
        'facingMode': 'user', // front-facing camera
        'width': 640,
        'height': 480,
      },
    });

    _localStream = stream;
    localRenderer.srcObject = stream; // show our own camera preview
  }

  // ------------------------------------------------------------------
  // Incoming signaling messages - this is the heart of the handshake.
  // ------------------------------------------------------------------

  Future<void> _handleSignalingMessage(Map<String, dynamic> message) async {
    final pc = _peerConnection;
    if (pc == null) return;

    switch (message['type']) {
      case 'joined':
        final memberCount =
            message['member_count'] as int? ?? message['peer_count'] as int? ?? 1;
        if (memberCount >= 2) {
          // The other phone is already a member; they will send the offer
          // after receiving our peer-status.
          onStatusChange?.call('Joined room ($memberCount/2). Waiting for offer...');
        } else {
          onStatusChange?.call('Joined room ($memberCount/2). Waiting for peer...');
        }
        break;

      // Server v2 notifies existing members this way when the other
      // phone joins or reconnects. The peer already in the room is
      // the offerer.
      case 'peer-status':
        final status = message['status'] as String?;
        final otherId = message['device_id'] as String?;
        if (otherId != null && otherId == _deviceId) break;
        if (status == 'online' && !_remoteDescriptionSet && !_isOfferer) {
          await _createAndSendOffer(pc);
        } else if (status == 'offline') {
          onStatusChange?.call('Peer disconnected');
          remoteRenderer.srcObject = null;
          _remoteDescriptionSet = false;
          _isOfferer = false;
          _pendingCandidates.clear();
        }
        break;

      case 'peer-joined':
        if (!_remoteDescriptionSet && !_isOfferer) {
          await _createAndSendOffer(pc);
        }
        break;

      // ------------------------------------------------------------
      // STEP 5: we received an offer from the other peer (this means
      // we were the "second" one to join) -> create an answer.
      // ------------------------------------------------------------
      case 'offer':
        onStatusChange?.call('Received offer - creating answer...');

        final sdpData = message['sdp'] as Map<String, dynamic>;

        // Tell our peer connection what the OTHER side offered.
        await pc.setRemoteDescription(
          RTCSessionDescription(sdpData['sdp'] as String, sdpData['type'] as String),
        );
        _remoteDescriptionSet = true;
        await _applyPendingCandidates();

        // Generate our answer (our own SDP, describing what WE support)
        // and send it back.
        final RTCSessionDescription answer = await pc.createAnswer();
        await pc.setLocalDescription(answer);
        _sendMessage({
          'type': 'answer',
          'sdp': {'type': answer.type, 'sdp': answer.sdp},
        });
        break;

      // The first peer (the one who sent the offer) receives the
      // answer here, completing the SDP exchange.
      case 'answer':
        onStatusChange?.call('Received answer - connecting...');

        final sdpData = message['sdp'] as Map<String, dynamic>;
        await pc.setRemoteDescription(
          RTCSessionDescription(sdpData['sdp'] as String, sdpData['type'] as String),
        );
        _remoteDescriptionSet = true;
        await _applyPendingCandidates();
        break;

      // ------------------------------------------------------------
      // STEP 6 (receive half): the other peer found a new network path
      // to itself and sent it to us - add it to our peer connection so
      // WebRTC can try connecting through it.
      // ------------------------------------------------------------
      case 'ice-candidate':
        final candidateData = message['candidate'] as Map<String, dynamic>?;
        if (candidateData == null) break;
        final candidate = RTCIceCandidate(
          candidateData['candidate'] as String?,
          candidateData['sdpMid'] as String?,
          (candidateData['sdpMLineIndex'] as num?)?.toInt(),
        );

        if (_remoteDescriptionSet) {
          await pc.addCandidate(candidate);
        } else {
          // Remote description isn't set yet (candidates can arrive
          // before the offer/answer does) - save it for later.
          _pendingCandidates.add(candidate);
        }
        break;

      case 'peer-left':
        onStatusChange?.call('Peer disconnected');
        remoteRenderer.srcObject = null;
        _remoteDescriptionSet = false;
        _isOfferer = false;
        _pendingCandidates.clear();
        break;

      case 'room-full':
        onStatusChange?.call('Room is full (2 peers already connected)');
        break;
    }
  }

  Future<void> _createAndSendOffer(RTCPeerConnection pc) async {
    _isOfferer = true;
    onStatusChange?.call('Peer joined - creating offer...');
    final RTCSessionDescription offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    _sendMessage({
      'type': 'offer',
      'sdp': {'type': offer.type, 'sdp': offer.sdp},
    });
  }

  /// Applies any ICE candidates that arrived before we finished
  /// `setRemoteDescription` (see the "ice-candidate" case above).
  Future<void> _applyPendingCandidates() async {
    final pc = _peerConnection;
    if (pc == null) return;
    for (final candidate in _pendingCandidates) {
      await pc.addCandidate(candidate);
    }
    _pendingCandidates.clear();
  }

  // ------------------------------------------------------------------
  // Simple call controls used by the UI.
  // ------------------------------------------------------------------

  void toggleMic(bool enabled) {
    _localStream?.getAudioTracks().forEach((track) => track.enabled = enabled);
  }

  void toggleCamera(bool enabled) {
    _localStream?.getVideoTracks().forEach((track) => track.enabled = enabled);
  }

  Future<void> switchCamera() async {
    final videoTrack = _localStream?.getVideoTracks().firstOrNull;
    if (videoTrack != null) {
      await Helper.switchCamera(videoTrack);
    }
  }

  /// Tears everything down when the call screen closes: tells the server
  /// we're leaving, closes the WebSocket, stops our camera/mic, and
  /// releases the peer connection + renderers.
  Future<void> hangUp() async {
    _sendMessage({'type': 'leave'});
    await _channel?.sink.close();

    for (final track in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
      await track.stop();
    }
    await _localStream?.dispose();

    await _peerConnection?.close();
    await _peerConnection?.dispose();

    await localRenderer.dispose();
    await remoteRenderer.dispose();
  }
}
