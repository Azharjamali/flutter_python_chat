import 'dart:async';

import 'package:flutter/material.dart';

import 'models.dart';
import 'signaling_service.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.service, required this.peerId});

  final SignalingService service;
  final String peerId;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _textController = TextEditingController();
  Timer? _typingTimer;
  bool _sentTyping = false;

  @override
  void initState() {
    super.initState();
    widget.service.addListener(_onChange);
    _textController.addListener(_onTextChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.service.markChatOpen(widget.peerId);
    });
  }

  @override
  void dispose() {
    _typingTimer?.cancel();
    if (_sentTyping) {
      widget.service.setTyping(widget.peerId, false);
    }
    widget.service.removeListener(_onChange);
    widget.service.markChatClosed();
    _textController.dispose();
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  void _onTextChanged() {
    final hasText = _textController.text.trim().isNotEmpty;
    if (!hasText) {
      _stopTyping();
      return;
    }
    if (!_sentTyping) {
      _sentTyping = true;
      widget.service.setTyping(widget.peerId, true);
    }
    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(seconds: 2), _stopTyping);
  }

  void _stopTyping() {
    _typingTimer?.cancel();
    if (!_sentTyping) return;
    _sentTyping = false;
    widget.service.setTyping(widget.peerId, false);
  }

  Future<void> _startCall({required bool video}) async {
    final chat = widget.service.conversation(widget.peerId);
    if (chat == null || !chat.online) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('User is offline')),
      );
      return;
    }
    await widget.service.startOutgoingCall(widget.peerId, video: video);
  }

  void _send() {
    final text = _textController.text;
    if (text.trim().isEmpty) return;
    _stopTyping();
    _textController.clear();
    widget.service.sendChat(widget.peerId, text);
  }

  String _subtitle() {
    final chat = widget.service.conversation(widget.peerId);
    if (chat?.typing == true) return 'typing...';
    return chat?.online == true ? 'online' : 'offline';
  }

  @override
  Widget build(BuildContext context) {
    final chat = widget.service.conversation(widget.peerId);
    final messages = widget.service.messagesFor(widget.peerId);
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.peerId),
            Text(
              _subtitle(),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.normal,
                fontStyle: chat?.typing == true
                    ? FontStyle.italic
                    : FontStyle.normal,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Audio call',
            onPressed: () => _startCall(video: false),
            icon: const Icon(Icons.call),
          ),
          IconButton(
            tooltip: 'Video call',
            onPressed: () => _startCall(video: true),
            icon: const Icon(Icons.videocam),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: messages.isEmpty
                ? const Center(child: Text('Say hello'))
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final message = messages[index];
                      return Align(
                        alignment: message.fromMe
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          constraints: BoxConstraints(
                            maxWidth: MediaQuery.of(context).size.width * 0.75,
                          ),
                          decoration: BoxDecoration(
                            color: message.fromMe
                                ? Theme.of(context)
                                    .colorScheme
                                    .primaryContainer
                                : Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Flexible(child: Text(message.text)),
                              if (message.fromMe) ...[
                                const SizedBox(width: 6),
                                _MessageTicks(status: message.status),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          if (chat?.typing == true)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'typing...',
                  style: TextStyle(fontStyle: FontStyle.italic),
                ),
              ),
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(
                        hintText: 'Message',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _send,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageTicks extends StatelessWidget {
  const _MessageTicks({required this.status});

  final MessageStatus status;

  @override
  Widget build(BuildContext context) {
    final read = status == MessageStatus.read;
    return Icon(
      status == MessageStatus.sent ? Icons.done : Icons.done_all,
      size: 16,
      color: read ? const Color(0xFF34B7F1) : Colors.grey,
    );
  }
}
