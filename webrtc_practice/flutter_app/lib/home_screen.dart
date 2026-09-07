import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'calls_tab.dart';
import 'chat_screen.dart';
import 'signaling_service.dart';
import 'status_tab.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.service});

  final SignalingService service;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _takenDialogOpen = false;
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    widget.service.addListener(_onService);
  }

  @override
  void dispose() {
    widget.service.removeListener(_onService);
    super.dispose();
  }

  void _onService() {
    if (!mounted) return;
    if (widget.service.usernameTaken && !_takenDialogOpen) {
      _takenDialogOpen = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _showUsernameTakenDialog();
      });
    }
    if (!widget.service.usernameTaken) {
      _takenDialogOpen = false;
    }
  }

  Future<void> _showUsernameTakenDialog() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Username already in use'),
        content: const Text(
          'Try another username. This one is already in use.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _newChat() async {
    final controller = TextEditingController();
    final peerId = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New chat'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Their username',
            hintText: 'e.g. azhar',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Chat'),
          ),
        ],
      ),
    );
    if (peerId == null || peerId.trim().isEmpty || !mounted) return;
    final chat = await widget.service.openChat(peerId);
    if (!mounted) return;
    if (chat == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.service.status)),
      );
      return;
    }
    _openChat(chat.peerId);
  }

  Future<void> _newCall() async {
    final controller = TextEditingController();
    final peerId = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New call'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Their username',
            hintText: 'e.g. azhar',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'audio:${controller.text}'),
            child: const Text('Audio'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'video:${controller.text}'),
            child: const Text('Video'),
          ),
        ],
      ),
    );
    if (peerId == null || !mounted) return;
    final video = peerId.startsWith('video:');
    final name = peerId.split(':').skip(1).join(':');
    if (name.trim().isEmpty) return;
    await widget.service.callPeer(name, video: video);
  }

  void _openChat(String peerId) {
    widget.service.markChatOpen(peerId);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(service: widget.service, peerId: peerId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.service,
      builder: (context, _) {
        final service = widget.service;
        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('azharChating'),
                if (service.myId != null)
                  Text(
                    service.myId!,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.normal,
                    ),
                  ),
              ],
            ),
            actions: [
              if (!service.connected)
                IconButton(
                  tooltip: 'Retry connection',
                  onPressed: service.start,
                  icon: const Icon(Icons.refresh),
                ),
              if (service.myId != null)
                IconButton(
                  tooltip: 'Copy username',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: service.myId!));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Username copied')),
                    );
                  },
                  icon: const Icon(Icons.copy),
                ),
            ],
          ),
          floatingActionButton: service.connected
              ? FloatingActionButton(
                  onPressed: () {
                    if (_tab == 0) _newChat();
                    if (_tab == 1) _newCall();
                    if (_tab == 2) {
                      StatusTab(service: service).addStatus(context);
                    }
                  },
                  child: Icon(
                    _tab == 0
                        ? Icons.chat
                        : _tab == 1
                            ? Icons.add_call
                            : Icons.camera_alt,
                  ),
                )
              : null,
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (index) => setState(() => _tab = index),
            destinations: [
              NavigationDestination(
                icon: Badge(
                  isLabelVisible: service.totalUnread > 0,
                  label: Text('${service.totalUnread}'),
                  child: const Icon(Icons.chat_outlined),
                ),
                selectedIcon: Badge(
                  isLabelVisible: service.totalUnread > 0,
                  label: Text('${service.totalUnread}'),
                  child: const Icon(Icons.chat),
                ),
                label: 'Chats',
              ),
              const NavigationDestination(
                icon: Icon(Icons.call_outlined),
                selectedIcon: Icon(Icons.call),
                label: 'Calls',
              ),
              NavigationDestination(
                icon: Badge(
                  isLabelVisible: service.otherStatusAuthors.any(
                    (author) => service
                        .statusesBy(author)
                        .any((item) => !item.viewed),
                  ),
                  child: const Icon(Icons.circle_outlined),
                ),
                selectedIcon: Badge(
                  isLabelVisible: service.otherStatusAuthors.any(
                    (author) => service
                        .statusesBy(author)
                        .any((item) => !item.viewed),
                  ),
                  child: const Icon(Icons.circle),
                ),
                label: 'Status',
              ),
            ],
          ),
          body: Column(
            children: [
              if (service.needsUsername) _UsernameSetup(service: service),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    service.status,
                    style: TextStyle(color: Colors.grey.shade700, fontSize: 12),
                  ),
                ),
              ),
              if (!service.connected && !service.needsUsername) ...[
                if (service.status.contains('Looking') ||
                    service.status.contains('Starting') ||
                    service.status.contains('Opening') ||
                    service.status.contains('Signing'))
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                _ManualServerField(
                  onConnect: (ip) => service.start(preferredHost: ip),
                ),
              ],
              Expanded(
                child: IndexedStack(
                  index: _tab,
                  children: [
                    _ChatList(service: service, onOpenChat: _openChat),
                    CallsTab(service: service, onOpenChat: _openChat),
                    StatusTab(service: service),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ChatList extends StatelessWidget {
  const _ChatList({required this.service, required this.onOpenChat});

  final SignalingService service;
  final void Function(String peerId) onOpenChat;

  @override
  Widget build(BuildContext context) {
    final chats = service.chatList;
    if (chats.isEmpty) {
      return Center(
        child: Text(
          service.connected
              ? 'No chats yet.\nTap + and enter the other user\'s username.'
              : 'Connect and choose a username to start chatting.',
          textAlign: TextAlign.center,
        ),
      );
    }
    return ListView.builder(
      itemCount: chats.length,
      itemBuilder: (context, index) {
        final chat = chats[index];
        return ListTile(
          leading: CircleAvatar(
            child: Text(chat.peerId.characters.first),
          ),
          title: Text(chat.peerId),
          subtitle: Text(
            chat.typing
                ? 'typing...'
                : chat.lastText.isEmpty
                    ? 'No messages yet'
                    : chat.lastText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: chat.typing
                ? TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontStyle: FontStyle.italic,
                  )
                : null,
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (chat.unread > 0) ...[
                CircleAvatar(
                  radius: 11,
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  child: Text(
                    chat.unread > 99 ? '99+' : '${chat.unread}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onPrimary,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Text(
                chat.online ? 'online' : 'offline',
                style: TextStyle(
                  color: chat.online ? Colors.green : Colors.grey,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          onTap: () => onOpenChat(chat.peerId),
        );
      },
    );
  }
}

class _UsernameSetup extends StatefulWidget {
  const _UsernameSetup({required this.service});

  final SignalingService service;

  @override
  State<_UsernameSetup> createState() => _UsernameSetupState();
}

class _UsernameSetupState extends State<_UsernameSetup> {
  final _controller = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok = await widget.service.registerUsername(_controller.text);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok && !widget.service.usernameTaken) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.service.status)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Choose a username',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              '3-20 letters, numbers, or underscores',
              style: TextStyle(color: Colors.grey.shade700, fontSize: 12),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    enabled: !_busy,
                    autofocus: true,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submit(),
                    decoration: const InputDecoration(
                      labelText: 'Username',
                      hintText: 'e.g. azhar',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ManualServerField extends StatefulWidget {
  const _ManualServerField({required this.onConnect});

  final Future<void> Function(String ip) onConnect;

  @override
  State<_ManualServerField> createState() => _ManualServerFieldState();
}

class _ManualServerFieldState extends State<_ManualServerField> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Mac IP (if auto-find fails)',
                hintText: '192.168.18.129',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: () {
              final ip = _controller.text.trim();
              if (ip.isNotEmpty) widget.onConnect(ip);
            },
            child: const Text('Connect'),
          ),
        ],
      ),
    );
  }
}
