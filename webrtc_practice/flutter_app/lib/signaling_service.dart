import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'chat_store.dart';
import 'discovery.dart';
import 'models.dart';
import 'ringer.dart';

enum CallPhase { idle, outgoing, incoming, connecting, inCall }

class SignalingService extends ChangeNotifier {
  SignalingService();

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();
  final ChatStore _store = ChatStore();
  final Ringer _ringer = Ringer();

  WebSocketChannel? _channel;
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;

  final List<RTCIceCandidate> _pendingCandidates = [];
  Map<String, dynamic>? _pendingOffer;
  Completer<Conversation?>? _openWait;
  Completer<bool>? _registerWait;
  String? _lastAttemptedUsername;
  bool _remoteDescriptionSet = false;
  bool _renderersReady = false;
  bool _closed = false;
  bool _videoCall = true;
  String? _callRoom;
  String? _activeCallId;
  int? _callConnectedAt;

  String? myId;
  String? serverHost;
  String? serverName;
  String status = 'Starting...';
  bool connected = false;
  bool socketReady = false;
  bool usernameTaken = false;
  String? openChatPeerId;
  CallPhase phase = CallPhase.idle;
  bool incomingIsVideo = true;
  String? incomingPeerId;

  final Map<String, Conversation> conversations = {};
  final Map<String, List<ChatMessage>> _messages = {};
  final List<CallRecord> callHistory = [];
  final List<StatusItem> statuses = [];
  final Set<String> viewedStatusIds = {};

  List<Conversation> get chatList {
    final items = conversations.values.toList()
      ..sort((a, b) => b.lastTs.compareTo(a.lastTs));
    return items;
  }

  List<ChatMessage> messagesFor(String peerId) =>
      List.unmodifiable(_messages[peerId] ?? const []);

  Conversation? conversation(String peerId) => conversations[peerId];

  int get totalUnread =>
      conversations.values.fold(0, (sum, chat) => sum + chat.unread);

  List<StatusItem> get liveStatuses {
    final items = statuses.where((item) => !item.expired).toList()
      ..sort((a, b) => a.ts.compareTo(b.ts));
    return items;
  }

  List<StatusItem> statusesBy(String author) =>
      liveStatuses.where((item) => item.author == author).toList();

  List<String> get otherStatusAuthors {
    final seen = <String>{};
    final authors = <String>[];
    for (final item in liveStatuses) {
      if (item.author == myId || seen.contains(item.author)) continue;
      seen.add(item.author);
      authors.add(item.author);
    }
    authors.sort((a, b) {
      final aUnseen = statusesBy(a).any((item) => !item.viewed);
      final bUnseen = statusesBy(b).any((item) => !item.viewed);
      if (aUnseen != bUnseen) return aUnseen ? -1 : 1;
      return (statusesBy(b).lastOrNull?.ts ?? 0).compareTo(
        statusesBy(a).lastOrNull?.ts ?? 0,
      );
    });
    return authors;
  }

  String? resolveMediaUrl(String? url) {
    if (url == null || url.isEmpty) return null;
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    if (serverHost == null) return null;
    final path = url.startsWith('/') ? url : '/$url';
    return 'http://$serverHost:8767$path';
  }

  static const _iceServers = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
    ],
  };

  static const _lastHostKey = 'last_server_host';
  static const _usernameKey = 'username';

  static String normalizeUsername(String value) =>
      value.trim().toLowerCase();

  bool get needsUsername => socketReady && !connected;

  Future<void> start({String? preferredHost}) async {
    await _channel?.sink.close();
    _channel = null;
    connected = false;
    socketReady = false;
    usernameTaken = false;
    myId = await _loadSavedUsername();
    try {
      await _hydrateHistory();
    } catch (_) {
      // Local history is optional; don't block connecting.
    }
    final prefs = await SharedPreferences.getInstance();
    final lastHost = (preferredHost != null && preferredHost.trim().isNotEmpty)
        ? preferredHost.trim()
        : prefs.getString(_lastHostKey);

    _setStatus('Looking for signaling server...');

    try {
      if (preferredHost != null && preferredHost.trim().isNotEmpty) {
        serverHost = preferredHost.trim();
      } else {
        final found = await ServerDiscovery.find(lastKnownHost: lastHost);
        serverHost = found.host;
        serverName = found.name;
      }
    } catch (_) {
      _setStatus(
        'Could not find the server automatically. Enter the Mac IP below or tap retry.',
      );
      return;
    }

    await _connectSocket();
    if (serverHost != null) {
      await prefs.setString(_lastHostKey, serverHost!);
    }
    if (myId != null) {
      await registerUsername(myId!);
    } else if (socketReady) {
      _setStatus('Choose a username to continue');
    }
  }

  Future<bool> registerUsername(String raw) async {
    final username = normalizeUsername(raw);
    if (!RegExp(r'^[a-z0-9_]{3,20}$').hasMatch(username)) {
      _setStatus('Username must be 3-20 letters, numbers, or underscores');
      return false;
    }
    if (!socketReady) {
      _setStatus('Not connected to the server yet');
      return false;
    }
    usernameTaken = false;
    myId = username;
    _finishRegister(false);
    final wait = Completer<bool>();
    _registerWait = wait;
    final saved = await _loadSavedUsername();
    _sendRaw({
      'type': 'register',
      'device_id': username,
      'username': username,
      'returning': saved == username || username == _lastAttemptedUsername,
    });
    final ok = await wait.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => false,
    );
    if (ok) {
      _lastAttemptedUsername = null;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_usernameKey, username);
      for (final chat in conversations.values) {
        _sendRaw({'type': 'open-chat', 'peer_id': chat.peerId});
      }
      _sendRaw({'type': 'status-request'});
    } else {
      if (!usernameTaken) _lastAttemptedUsername = username;
      myId = await _loadSavedUsername();
    }
    return ok;
  }

  Future<Conversation?> openChat(String rawPeerId) async {
    final peerId = normalizeUsername(rawPeerId);
    if (peerId.isEmpty || peerId == myId) {
      _setStatus('Enter another user\'s username');
      return null;
    }
    if (_openWait != null && !_openWait!.isCompleted) {
      _openWait!.complete(null);
    }
    final wait = Completer<Conversation?>();
    _openWait = wait;
    _sendRaw({'type': 'open-chat', 'peer_id': peerId});
    return wait.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => null,
    );
  }

  Future<void> sendChat(String peerId, String text) async {
    final chat = conversations[peerId];
    if (chat == null || text.trim().isEmpty) return;
    setTyping(peerId, false);
    final message = ChatMessage(
      id: const Uuid().v4(),
      roomId: chat.roomId,
      peerId: peerId,
      fromMe: true,
      text: text.trim(),
      ts: DateTime.now().millisecondsSinceEpoch,
      status: MessageStatus.sent,
    );
    await _saveMessage(message, incrementUnread: false);
    _sendRaw({
      'type': 'chat',
      'room': chat.roomId,
      'msg_id': message.id,
      'text': message.text,
      'ts': message.ts,
    });
  }

  void markChatOpen(String peerId) {
    final alreadyOpen = openChatPeerId == peerId;
    openChatPeerId = peerId;
    final chat = conversations[peerId];
    if (chat != null) {
      chat.unread = 0;
      chat.typing = false;
      _store.clearUnread(peerId);
      final incoming = (_messages[peerId] ?? [])
          .where((item) => !item.fromMe)
          .map((item) => item.id)
          .toList();
      if (incoming.isNotEmpty) {
        _sendRaw({
          'type': 'chat-read',
          'room': chat.roomId,
          'msg_ids': incoming,
        });
      }
    }
    if (!alreadyOpen) notifyListeners();
  }

  void markChatClosed() {
    if (openChatPeerId != null) {
      setTyping(openChatPeerId!, false);
    }
    openChatPeerId = null;
    notifyListeners();
  }

  void setTyping(String peerId, bool typing) {
    final chat = conversations[peerId];
    _sendRaw({
      'type': 'typing',
      'peer_id': peerId,
      if (chat != null) 'room': chat.roomId,
      'typing': typing,
    });
  }

  Future<void> startOutgoingCall(String peerId, {required bool video}) async {
    final chat = conversations[peerId];
    if (chat == null || !chat.online || phase != CallPhase.idle) return;
    _videoCall = video;
    _callRoom = chat.roomId;
    incomingPeerId = peerId;
    incomingIsVideo = video;
    phase = CallPhase.outgoing;
    await _beginCallRecord(peerId: peerId, video: video, outgoing: true);
    _setStatus(video ? 'Video calling...' : 'Audio calling...');
    _sendRaw({
      'type': 'call-invite',
      'room': chat.roomId,
      'call_type': video ? 'video' : 'audio',
    });
    await _prepareMediaAndPeerConnection(video: video);
  }

  Future<void> callPeer(String peerId, {required bool video}) async {
    var chat = conversations[peerId];
    chat ??= await openChat(peerId);
    if (chat == null) {
      _setStatus('Could not start a chat with $peerId');
      return;
    }
    if (!chat.online) {
      _setStatus('$peerId is offline');
      return;
    }
    await startOutgoingCall(peerId, video: video);
  }

  Future<void> acceptIncomingCall() async {
    if (phase != CallPhase.incoming) return;
    await _ringer.stop();
    phase = CallPhase.connecting;
    _markCallConnected();
    _setStatus('Connecting...');
    _sendRaw({'type': 'call-accept', 'room': _callRoom});
    await _prepareMediaAndPeerConnection(video: _videoCall);
    if (_pendingOffer != null) {
      final offer = _pendingOffer!;
      _pendingOffer = null;
      await _handleOffer(offer);
    }
  }

  void declineIncomingCall() {
    if (phase != CallPhase.incoming) return;
    _ringer.stop();
    _sendRaw({'type': 'call-decline', 'room': _callRoom});
    _endActiveCall(CallOutcome.declined);
    _setStatus('Call declined');
  }

  Future<void> endCall() async {
    if (phase == CallPhase.idle) return;
    final outgoingRing = phase == CallPhase.outgoing;
    final incomingRing = phase == CallPhase.incoming;
    if (outgoingRing) {
      _sendRaw({'type': 'call-cancel', 'room': _callRoom});
    } else if (incomingRing) {
      declineIncomingCall();
      return;
    } else {
      _sendRaw({'type': 'call-end', 'room': _callRoom});
    }
    await _ringer.stop();
    await _tearDownMedia();
    _endActiveCall(
      outgoingRing
          ? CallOutcome.cancelled
          : incomingRing
              ? CallOutcome.declined
              : CallOutcome.answered,
    );
    _setStatus('Call ended');
  }

  Future<void> postTextStatus(String text, int bg) async {
    final item = StatusItem(
      id: const Uuid().v4(),
      author: myId ?? '',
      kind: StatusKind.text,
      text: text.trim(),
      bg: bg,
      ts: DateTime.now().millisecondsSinceEpoch,
    );
    _upsertStatus(item);
    _sendRaw({
      'type': 'status-post',
      'id': item.id,
      'author': item.author,
      'kind': 'text',
      'text': item.text,
      'bg': item.bg,
      'ts': item.ts,
    });
  }

  Future<void> postMediaStatus({
    required File file,
    required StatusKind kind,
    String caption = '',
  }) async {
    if (serverHost == null) {
      _setStatus('Not connected to the server');
      return;
    }
    var ext = p.extension(file.path).replaceFirst('.', '').toLowerCase();
    if (ext.isEmpty) {
      ext = kind == StatusKind.video ? 'mp4' : 'jpg';
    }
    final name = '${const Uuid().v4()}.$ext';
    final mediaUrl = await _uploadStatusMedia(file, name);
    if (mediaUrl == null) {
      _setStatus('Could not upload status');
      return;
    }
    final item = StatusItem(
      id: const Uuid().v4(),
      author: myId ?? '',
      kind: kind,
      text: caption.trim(),
      mediaUrl: mediaUrl,
      ts: DateTime.now().millisecondsSinceEpoch,
    );
    _upsertStatus(item);
    _sendRaw({
      'type': 'status-post',
      'id': item.id,
      'author': item.author,
      'kind': kind == StatusKind.video ? 'video' : 'image',
      'text': item.text,
      'media_url': mediaUrl,
      'ts': item.ts,
    });
  }

  Future<void> deleteStatus(String id) async {
    statuses.removeWhere((item) => item.id == id);
    _sendRaw({'type': 'status-delete', 'id': id});
    if (!_closed) notifyListeners();
  }

  void markStatusViewed(String id) {
    for (final item in statuses) {
      if (item.id != id) continue;
      final already = item.viewed;
      item.viewed = true;
      viewedStatusIds.add(item.id);
      _store.markStatusViewed(item.id);
      if (!already && item.author != myId) {
        _sendRaw({'type': 'status-view', 'id': id});
      }
      if (!_closed) notifyListeners();
      return;
    }
  }

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

  bool get isVideoCall => _videoCall;

  int? get callConnectedAt => _callConnectedAt;

  String get liveCallDuration {
    final start = _callConnectedAt;
    if (start == null) return '00:00';
    return formatCallDuration(DateTime.now().millisecondsSinceEpoch - start);
  }

  int get myStatusViewerCount {
    final viewers = <String>{};
    for (final item in statusesBy(myId ?? '')) {
      for (final view in item.views) {
        viewers.add(view.viewer);
      }
    }
    return viewers.length;
  }

  Future<void> _connectSocket() async {
    await _ensureRenderers();
    _setStatus('Connecting to $serverHost...');
    _channel = WebSocketChannel.connect(Uri.parse('ws://$serverHost:8765'));
    try {
      await _channel!.ready;
    } catch (_) {
      _setStatus(
        'Found the server but WebSocket failed. Retry from the home screen.',
      );
      return;
    }

    _channel!.stream.listen(
      (raw) {
        final message = jsonDecode(raw as String) as Map<String, dynamic>;
        _handleSignalingMessage(message);
      },
      onDone: () {
        connected = false;
        socketReady = false;
        _setStatus('Disconnected from signaling server');
      },
      onError: (_) {
        connected = false;
        socketReady = false;
        _setStatus('Signaling connection error');
      },
    );

    socketReady = true;
    _setStatus(
      myId == null ? 'Choose a username to continue' : 'Signing in as $myId...',
    );
  }

  Future<void> _hydrateHistory() async {
    final chats = await _store.loadConversations();
    for (final chat in chats) {
      conversations[chat.peerId] = chat;
      _messages[chat.peerId] = await _store.loadMessages(chat.roomId);
    }
    callHistory
      ..clear()
      ..addAll(await _store.loadCalls());
    viewedStatusIds
      ..clear()
      ..addAll(await _store.loadViewedStatusIds());
    notifyListeners();
  }

  Future<String?> _loadSavedUsername() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_usernameKey);
    if (existing == null || existing.isEmpty) return null;
    return normalizeUsername(existing);
  }

  void _sendRaw(Map<String, dynamic> message) {
    _channel?.sink.add(
      jsonEncode({...message, if (myId != null) 'device_id': myId}),
    );
  }

  void _setStatus(String value) {
    status = value;
    if (!_closed) notifyListeners();
  }

  void _resetCallState() {
    phase = CallPhase.idle;
    _remoteDescriptionSet = false;
    _pendingCandidates.clear();
    _pendingOffer = null;
    _callRoom = null;
    incomingPeerId = null;
  }

  Future<void> _beginCallRecord({
    required String peerId,
    required bool video,
    required bool outgoing,
  }) async {
    final record = CallRecord(
      id: const Uuid().v4(),
      peerId: peerId,
      video: video,
      outgoing: outgoing,
      outcome: CallOutcome.ringing,
      ts: DateTime.now().millisecondsSinceEpoch,
    );
    _activeCallId = record.id;
    _callConnectedAt = null;
    callHistory.insert(0, record);
    await _store.insertCall(record);
    if (!_closed) notifyListeners();
  }

  void _markCallConnected() {
    _callConnectedAt ??= DateTime.now().millisecondsSinceEpoch;
    final id = _activeCallId;
    if (id == null) return;
    for (final record in callHistory) {
      if (record.id != id) continue;
      record.outcome = CallOutcome.answered;
      _store.updateCall(record);
      break;
    }
    if (!_closed) notifyListeners();
  }

  void _endActiveCall(CallOutcome outcome) {
    final id = _activeCallId;
    if (id != null) {
      for (final record in callHistory) {
        if (record.id != id) continue;
        if (record.outcome != CallOutcome.answered) {
          record.outcome = outcome;
        }
        if (record.outcome == CallOutcome.answered && _callConnectedAt != null) {
          record.durationMs =
              DateTime.now().millisecondsSinceEpoch - _callConnectedAt!;
        }
        _store.updateCall(record);
        break;
      }
    }
    _activeCallId = null;
    _callConnectedAt = null;
    _resetCallState();
    if (!_closed) notifyListeners();
  }

  void _upsertStatus(StatusItem item) {
    StatusItem? existing;
    for (final current in statuses) {
      if (current.id == item.id) {
        existing = current;
        break;
      }
    }
    if (existing != null && item.views.isEmpty && existing.views.isNotEmpty) {
      item.views.addAll(existing.views);
    }
    statuses.removeWhere((current) => current.id == item.id);
    if (!item.expired) {
      item.viewed = viewedStatusIds.contains(item.id) || item.author == myId;
      statuses.add(item);
    }
    if (!_closed) notifyListeners();
  }

  List<StatusView> _viewsFromMessage(dynamic raw) {
    if (raw is! List) return [];
    return [
      for (final entry in raw)
        if (entry is Map)
          StatusView(
            viewer: normalizeUsername('${entry['viewer'] ?? ''}'),
            ts: (entry['ts'] as num?)?.toInt() ?? 0,
          ),
    ].where((view) => view.viewer.isNotEmpty).toList();
  }

  StatusItem? _statusFromMessage(Map<String, dynamic> message) {
    final id = '${message['id'] ?? ''}'.trim();
    final author = normalizeUsername(
      '${message['author'] ?? message['device_id'] ?? ''}',
    );
    if (id.isEmpty || author.isEmpty) return null;
    final kindName = '${message['kind'] ?? 'text'}';
    final kind = StatusKind.values.firstWhere(
      (value) => value.name == kindName,
      orElse: () => StatusKind.text,
    );
    var ts = (message['ts'] as num?)?.toInt() ??
        DateTime.now().millisecondsSinceEpoch;
    if (ts > 0 && ts < 100000000000) ts *= 1000;
    return StatusItem(
      id: id,
      author: author,
      kind: kind,
      text: message['text'] as String? ?? '',
      bg: (message['bg'] as num?)?.toInt() ?? 0xFF075E54,
      mediaUrl: message['media_url'] as String? ?? '',
      ts: ts,
      views: _viewsFromMessage(message['views']),
    );
  }

  Future<String?> _uploadStatusMedia(File file, String name) async {
    try {
      final uri = Uri.parse('http://$serverHost:8767/status-media/$name');
      final request = await HttpClient().putUrl(uri);
      request.headers.contentType = ContentType.binary;
      request.add(await file.readAsBytes());
      final response = await request.close();
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return '/status-media/$name';
      }
    } catch (_) {}
    return null;
  }

  Conversation _upsertChat({
    required String peerId,
    required String roomId,
    required bool online,
  }) {
    final existing = conversations[peerId];
    if (existing != null) {
      existing.online = online;
      return existing;
    }
    final chat = Conversation(peerId: peerId, roomId: roomId, online: online);
    conversations[peerId] = chat;
    _messages.putIfAbsent(peerId, () => []);
    _store.upsertConversation(chat);
    return chat;
  }

  Future<void> _saveMessage(
    ChatMessage message, {
    required bool incrementUnread,
  }) async {
    _messages.putIfAbsent(message.peerId, () => []);
    if (_messages[message.peerId]!.any((item) => item.id == message.id)) return;
    _messages[message.peerId]!.add(message);
    await _store.insertMessage(message);

    final chat = conversations[message.peerId];
    if (chat != null) {
      chat.lastText = message.text;
      chat.lastTs = message.ts;
      if (incrementUnread && openChatPeerId != message.peerId) {
        chat.unread += 1;
      }
      await _store.upsertConversation(chat);
    }
    if (!_closed) notifyListeners();
  }

  void _finishRegister(bool ok) {
    final wait = _registerWait;
    _registerWait = null;
    if (wait != null && !wait.isCompleted) {
      wait.complete(ok);
    }
  }

  void _applyReceipt(String? msgId, MessageStatus status) {
    if (msgId == null) return;
    for (final messages in _messages.values) {
      for (final item in messages) {
        if (item.id != msgId || !item.fromMe) continue;
        if (status.index > item.status.index) {
          item.status = status;
          _store.updateMessageStatus(msgId, status);
          if (!_closed) notifyListeners();
        }
        return;
      }
    }
  }

  Future<void> _handleSignalingMessage(Map<String, dynamic> message) async {
    switch (message['type']) {
      case 'registered':
        connected = true;
        usernameTaken = false;
        myId = normalizeUsername(
          (message['device_id'] as String?) ?? myId ?? '',
        );
        _finishRegister(true);
        _setStatus('Connected as $myId');
        _sendRaw({'type': 'status-request'});
        break;

      case 'username-taken':
        usernameTaken = true;
        connected = false;
        _finishRegister(false);
        _setStatus('That username is already in use');
        break;

      case 'joined':
      case 'chat-opened':
        final peerId = normalizeUsername(message['peer_id'] as String? ?? '');
        final roomId = message['room'] as String?;
        if (peerId.isEmpty || roomId == null) break;
        final online =
            message['peer_online'] == true ||
            message['status'] == 'online' ||
            (message['member_count'] as num?)?.toInt() == 2;
        final chat = _upsertChat(
          peerId: peerId,
          roomId: roomId,
          online: online,
        );
        if (_openWait != null && !_openWait!.isCompleted) {
          _openWait!.complete(chat);
        }
        _openWait = null;
        _setStatus(online ? '$peerId is online' : '$peerId is offline');
        break;

      case 'peer-status':
        final otherId = normalizeUsername(message['device_id'] as String? ?? '');
        if (otherId.isEmpty || otherId == myId) break;
        final chat = conversations[otherId];
        if (chat != null) {
          chat.online = message['status'] == 'online';
          if (!chat.online) chat.typing = false;
        }
        if (message['status'] != 'online' &&
            incomingPeerId == otherId &&
            phase != CallPhase.idle) {
          final ringingIn = phase == CallPhase.incoming;
          final ringingOut = phase == CallPhase.outgoing;
          await _ringer.stop();
          await _tearDownMedia();
          _endActiveCall(
            ringingIn
                ? CallOutcome.missed
                : ringingOut
                    ? CallOutcome.cancelled
                    : CallOutcome.answered,
          );
        }
        if (!_closed) notifyListeners();
        break;

      case 'chat':
        final roomId = message['room'] as String?;
        final sender = normalizeUsername(message['device_id'] as String? ?? '');
        final text = message['text'] as String?;
        if (roomId == null || sender.isEmpty || text == null) break;
        _upsertChat(
          peerId: sender,
          roomId: roomId,
          online: conversations[sender]?.online ?? true,
        );
        final msgId = (message['msg_id'] as String?) ?? const Uuid().v4();
        await _saveMessage(
          ChatMessage(
            id: msgId,
            roomId: roomId,
            peerId: sender,
            fromMe: false,
            text: text,
            ts:
                (message['ts'] as num?)?.toInt() ??
                DateTime.now().millisecondsSinceEpoch,
          ),
          incrementUnread: true,
        );
        _sendRaw({
          'type': 'chat-delivered',
          'room': roomId,
          'msg_id': msgId,
        });
        if (openChatPeerId == sender) {
          _sendRaw({
            'type': 'chat-read',
            'room': roomId,
            'msg_ids': [msgId],
          });
        }
        break;

      case 'chat-delivered':
        _applyReceipt(
          message['msg_id'] as String?,
          MessageStatus.delivered,
        );
        break;

      case 'chat-read':
        final ids = message['msg_ids'];
        if (ids is List) {
          for (final id in ids) {
            if (id is String) _applyReceipt(id, MessageStatus.read);
          }
        } else {
          _applyReceipt(message['msg_id'] as String?, MessageStatus.read);
        }
        break;

      case 'typing':
        final typer = normalizeUsername(
          (message['device_id'] as String?) ??
              (message['author'] as String?) ??
              '',
        );
        if (typer.isEmpty || typer == myId) break;
        final roomId = message['room'] as String? ?? '';
        var chat = conversations[typer];
        if (chat == null && roomId.isNotEmpty) {
          for (final existing in conversations.values) {
            if (existing.roomId == roomId) {
              chat = existing;
              break;
            }
          }
        }
        chat ??= _upsertChat(
          peerId: typer,
          roomId: roomId.isNotEmpty ? roomId : 'dm:$myId:$typer',
          online: true,
        );
        chat.typing = message['typing'] == true || message['typing'] == 1;
        if (!_closed) notifyListeners();
        break;

      case 'error':
        if (_openWait != null && !_openWait!.isCompleted) {
          _openWait!.complete(null);
        }
        _openWait = null;
        _finishRegister(false);
        _setStatus(message['message'] as String? ?? 'Something went wrong');
        break;

      case 'call-invite':
        if (phase != CallPhase.idle) break;
        _callRoom = message['room'] as String?;
        incomingIsVideo = message['call_type'] != 'audio';
        _videoCall = incomingIsVideo;
        incomingPeerId = normalizeUsername(message['device_id'] as String? ?? '');
        phase = CallPhase.incoming;
        await _beginCallRecord(
          peerId: incomingPeerId ?? '',
          video: incomingIsVideo,
          outgoing: false,
        );
        _setStatus(
          incomingIsVideo ? 'Incoming video call...' : 'Incoming audio call...',
        );
        await _ringer.start();
        break;

      case 'call-accept':
        if (phase != CallPhase.outgoing) break;
        phase = CallPhase.connecting;
        _markCallConnected();
        _setStatus('Answered — connecting...');
        await _prepareMediaAndPeerConnection(video: _videoCall);
        await _createAndSendOffer();
        break;

      case 'call-decline':
        if (phase == CallPhase.outgoing) {
          await _tearDownMedia();
          _endActiveCall(CallOutcome.declined);
          _setStatus('Call declined');
        }
        break;

      case 'call-cancel':
        if (phase == CallPhase.incoming) {
          await _ringer.stop();
          _endActiveCall(CallOutcome.missed);
          _setStatus('Caller cancelled');
        }
        break;

      case 'call-end':
        await _ringer.stop();
        await _tearDownMedia();
        _endActiveCall(CallOutcome.answered);
        _setStatus('Call ended');
        break;

      case 'status-list':
        final items = message['items'];
        if (items is List) {
          statuses.removeWhere((item) => item.author != myId);
          for (final raw in items) {
            if (raw is Map) {
              final item = _statusFromMessage(Map<String, dynamic>.from(raw));
              if (item != null) _upsertStatus(item);
            }
          }
        }
        break;

      case 'status-new':
        final item = _statusFromMessage(message);
        if (item != null) _upsertStatus(item);
        break;

      case 'status-delete':
        final id = message['id'] as String?;
        if (id == null) break;
        statuses.removeWhere((item) => item.id == id);
        if (!_closed) notifyListeners();
        break;

      case 'status-viewed':
        final viewedId = message['id'] as String?;
        if (viewedId == null) break;
        final views = _viewsFromMessage(message['views']);
        for (final item in statuses) {
          if (item.id != viewedId) continue;
          item.views
            ..clear()
            ..addAll(views);
          break;
        }
        if (!_closed) notifyListeners();
        break;

      case 'offer':
        if (_peerConnection == null) {
          _pendingOffer = message;
          break;
        }
        await _handleOffer(message);
        break;

      case 'answer':
        final pc = _peerConnection;
        if (pc == null) break;
        final sdpData = message['sdp'] as Map<String, dynamic>;
        await pc.setRemoteDescription(
          RTCSessionDescription(
            sdpData['sdp'] as String,
            sdpData['type'] as String,
          ),
        );
        _remoteDescriptionSet = true;
        await _applyPendingCandidates();
        break;

      case 'ice-candidate':
        final candidateData = message['candidate'] as Map<String, dynamic>?;
        if (candidateData == null) break;
        final candidate = RTCIceCandidate(
          candidateData['candidate'] as String?,
          candidateData['sdpMid'] as String?,
          (candidateData['sdpMLineIndex'] as num?)?.toInt(),
        );
        final pc = _peerConnection;
        if (pc != null && _remoteDescriptionSet) {
          await pc.addCandidate(candidate);
        } else {
          _pendingCandidates.add(candidate);
        }
        break;
    }
  }

  Future<void> _prepareMediaAndPeerConnection({required bool video}) async {
    await _ensureRenderers();
    if (_localStream == null) {
      await _openLocalMedia(video: video);
    }
    if (_peerConnection == null) {
      await _createPeerConnection();
    }
  }

  Future<void> _ensureRenderers() async {
    if (_renderersReady) return;
    await localRenderer.initialize();
    await remoteRenderer.initialize();
    _renderersReady = true;
  }

  Future<void> _openLocalMedia({required bool video}) async {
    final stream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': video
          ? {'facingMode': 'user', 'width': 640, 'height': 480}
          : false,
    });
    _localStream = stream;
    localRenderer.srcObject = stream;
    if (!_closed) notifyListeners();
  }

  Future<void> _createPeerConnection() async {
    final pc = await createPeerConnection(_iceServers);
    for (final track in _localStream!.getTracks()) {
      await pc.addTrack(track, _localStream!);
    }
    pc.onIceCandidate = (candidate) {
      _sendRaw({
        'type': 'ice-candidate',
        'room': _callRoom,
        'candidate': candidate.toMap(),
      });
    };
    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        remoteRenderer.srcObject = event.streams.first;
        phase = CallPhase.inCall;
        _markCallConnected();
        _setStatus('Connected');
      }
    };
    pc.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        phase = CallPhase.inCall;
        _markCallConnected();
        _setStatus('Connected');
      }
    };
    _peerConnection = pc;
  }

  Future<void> _handleOffer(Map<String, dynamic> message) async {
    final pc = _peerConnection;
    if (pc == null) return;
    phase = CallPhase.connecting;
    final sdpData = message['sdp'] as Map<String, dynamic>;
    await pc.setRemoteDescription(
      RTCSessionDescription(
        sdpData['sdp'] as String,
        sdpData['type'] as String,
      ),
    );
    _remoteDescriptionSet = true;
    await _applyPendingCandidates();
    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    _sendRaw({
      'type': 'answer',
      'room': _callRoom,
      'sdp': {'type': answer.type, 'sdp': answer.sdp},
    });
  }

  Future<void> _createAndSendOffer() async {
    final pc = _peerConnection;
    if (pc == null) return;
    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    _sendRaw({
      'type': 'offer',
      'room': _callRoom,
      'sdp': {'type': offer.type, 'sdp': offer.sdp},
    });
  }

  Future<void> _applyPendingCandidates() async {
    final pc = _peerConnection;
    if (pc == null) return;
    for (final candidate in _pendingCandidates) {
      await pc.addCandidate(candidate);
    }
    _pendingCandidates.clear();
  }

  Future<void> _tearDownMedia() async {
    remoteRenderer.srcObject = null;
    localRenderer.srcObject = null;
    for (final track in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
      await track.stop();
    }
    await _localStream?.dispose();
    _localStream = null;
    await _peerConnection?.close();
    await _peerConnection?.dispose();
    _peerConnection = null;
  }
}
