import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:video_player/video_player.dart';

import 'models.dart';
import 'signaling_service.dart';

class StatusTab extends StatelessWidget {
  const StatusTab({super.key, required this.service});

  final SignalingService service;

  Future<void> addStatus(BuildContext context) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.text_fields),
              title: const Text('Text'),
              onTap: () => Navigator.pop(context, 'text'),
            ),
            ListTile(
              leading: const Icon(Icons.photo),
              title: const Text('Photo'),
              onTap: () => Navigator.pop(context, 'image'),
            ),
            ListTile(
              leading: const Icon(Icons.videocam),
              title: const Text('Video'),
              onTap: () => Navigator.pop(context, 'video'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !context.mounted) return;
    if (choice == 'text') {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TextStatusComposer(service: service),
        ),
      );
      return;
    }
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Camera'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Gallery'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null || !context.mounted) return;
    if (source == ImageSource.camera) {
      await Permission.camera.request();
    }
    final picker = ImagePicker();
    final file = choice == 'video'
        ? await picker.pickVideo(source: source, maxDuration: const Duration(seconds: 30))
        : await picker.pickImage(source: source, imageQuality: 80, maxWidth: 1280);
    if (file == null || !context.mounted) return;
    await service.postMediaStatus(
      file: File(file.path),
      kind: choice == 'video' ? StatusKind.video : StatusKind.image,
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Status posted')),
    );
  }

  void _openViewer(BuildContext context, String author) {
    final items = service.statusesBy(author);
    if (items.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => StatusViewer(
          service: service,
          author: author,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mine = service.statusesBy(service.myId ?? '');
    final others = service.otherStatusAuthors;
    final unseenMine = mine.any((item) => !item.viewed);
    final viewCount = service.myStatusViewerCount;
    return ListView(
      children: [
        ListTile(
          leading: _StatusAvatar(
            letter: (service.myId ?? '?').characters.first,
            unseen: mine.isNotEmpty && unseenMine,
            showAdd: mine.isEmpty,
          ),
          title: const Text('My status'),
          subtitle: Text(
            mine.isEmpty
                ? 'Tap to add a status'
                : viewCount == 0
                    ? formatRelativeTime(mine.last.ts)
                    : '$viewCount ${viewCount == 1 ? 'view' : 'views'} · ${formatRelativeTime(mine.last.ts)}',
          ),
          onTap: () {
            if (mine.isEmpty) {
              addStatus(context);
            } else {
              _openViewer(context, service.myId ?? '');
            }
          },
          trailing: mine.isNotEmpty
              ? IconButton(
                  tooltip: 'Add status',
                  onPressed: () => addStatus(context),
                  icon: const Icon(Icons.add_circle_outline),
                )
              : null,
        ),
        if (others.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'Recent updates',
              style: TextStyle(
                color: Colors.grey.shade700,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        for (final author in others)
          ListTile(
            leading: _StatusAvatar(
              letter: author.characters.first,
              unseen: service.statusesBy(author).any((item) => !item.viewed),
            ),
            title: Text(author),
            subtitle: Text(
              formatRelativeTime(service.statusesBy(author).last.ts),
            ),
            onTap: () => _openViewer(context, author),
          ),
        if (others.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 24, 16, 0),
            child: Text(
              'When someone on this server posts a status, it will show up here.',
              textAlign: TextAlign.center,
            ),
          ),
      ],
    );
  }
}

class _StatusAvatar extends StatelessWidget {
  const _StatusAvatar({
    required this.letter,
    required this.unseen,
    this.showAdd = false,
  });

  final String letter;
  final bool unseen;
  final bool showAdd;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Container(
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: unseen
                  ? Theme.of(context).colorScheme.primary
                  : Colors.grey.shade400,
              width: 2.5,
            ),
          ),
          child: CircleAvatar(child: Text(letter.toUpperCase())),
        ),
        if (showAdd)
          Positioned(
            right: 0,
            bottom: 0,
            child: CircleAvatar(
              radius: 8,
              backgroundColor: Theme.of(context).colorScheme.primary,
              child: const Icon(Icons.add, size: 12, color: Colors.white),
            ),
          ),
      ],
    );
  }
}

class TextStatusComposer extends StatefulWidget {
  const TextStatusComposer({super.key, required this.service});

  final SignalingService service;

  @override
  State<TextStatusComposer> createState() => _TextStatusComposerState();
}

class _TextStatusComposerState extends State<TextStatusComposer> {
  final _controller = TextEditingController();
  int _colorIndex = 0;

  static const _colors = <int>[
    0xFF075E54,
    0xFF128C7E,
    0xFF1E88E5,
    0xFF8E24AA,
    0xFFD81B60,
    0xFFF4511E,
    0xFF6D4C41,
    0xFF37474F,
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _post() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    await widget.service.postTextStatus(text, _colors[_colorIndex]);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final color = Color(_colors[_colorIndex]);
    return Scaffold(
      backgroundColor: color,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: 'Change color',
            onPressed: () {
              setState(() => _colorIndex = (_colorIndex + 1) % _colors.length);
            },
            icon: const Icon(Icons.palette),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: TextField(
                    controller: _controller,
                    autofocus: true,
                    maxLines: null,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w600,
                    ),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      hintText: 'Type a status',
                      hintStyle: TextStyle(color: Colors.white70),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Align(
                alignment: Alignment.centerRight,
                child: FloatingActionButton(
                  onPressed: _post,
                  child: const Icon(Icons.send),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class StatusViewer extends StatefulWidget {
  const StatusViewer({
    super.key,
    required this.service,
    required this.author,
  });

  final SignalingService service;
  final String author;

  @override
  State<StatusViewer> createState() => _StatusViewerState();
}

class _StatusViewerState extends State<StatusViewer>
    with SingleTickerProviderStateMixin {
  late AnimationController _progress;
  int _index = 0;
  VideoPlayerController? _video;

  List<StatusItem> get _items => widget.service.statusesBy(widget.author);

  @override
  void initState() {
    super.initState();
    widget.service.addListener(_onService);
    _progress = AnimationController(vsync: this)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) _next();
      });
    WidgetsBinding.instance.addPostFrameCallback((_) => _playCurrent());
  }

  @override
  void dispose() {
    widget.service.removeListener(_onService);
    _video?.dispose();
    _progress.dispose();
    super.dispose();
  }

  void _onService() {
    if (mounted) setState(() {});
  }

  Future<void> _playCurrent() async {
    final items = _items;
    if (items.isEmpty) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    if (_index >= items.length) _index = items.length - 1;
    final item = items[_index];
    widget.service.markStatusViewed(item.id);
    await _video?.dispose();
    _video = null;
    if (item.kind == StatusKind.video) {
      final url = widget.service.resolveMediaUrl(item.mediaUrl);
      if (url != null) {
        final controller = VideoPlayerController.networkUrl(Uri.parse(url));
        _video = controller;
        await controller.initialize();
        if (!mounted) return;
        await controller.play();
        _progress.duration = controller.value.duration == Duration.zero
            ? const Duration(seconds: 5)
            : controller.value.duration;
        _progress.forward(from: 0);
        setState(() {});
        return;
      }
    }
    _progress.duration = const Duration(seconds: 5);
    _progress.forward(from: 0);
    if (mounted) setState(() {});
  }

  void _next() {
    if (_index >= _items.length - 1) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _index += 1);
    _playCurrent();
  }

  void _previous() {
    if (_index == 0) {
      _progress.forward(from: 0);
      return;
    }
    setState(() => _index -= 1);
    _playCurrent();
  }

  Future<void> _showViews(StatusItem item) async {
    _progress.stop();
    _video?.pause();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => _StatusViewsSheet(item: item),
    );
    if (!mounted) return;
    _video?.play();
    _progress.forward();
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    if (items.isEmpty) {
      return const Scaffold(backgroundColor: Colors.black);
    }
    final item = items[_index];
    return Scaffold(
      backgroundColor: item.kind == StatusKind.text
          ? Color(item.bg)
          : Colors.black,
      body: GestureDetector(
        onTapUp: (details) {
          final mid = MediaQuery.of(context).size.width / 2;
          if (details.globalPosition.dx < mid) {
            _previous();
          } else {
            _next();
          }
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            _StatusBody(service: widget.service, item: item, video: _video),
            if (widget.author == widget.service.myId)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SafeArea(
                  child: _StatusViewsBar(
                    item: item,
                    onOpen: () => _showViews(item),
                  ),
                ),
              ),
            SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                    child: Row(
                      children: [
                        for (var i = 0; i < items.length; i++)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 2),
                              child: AnimatedBuilder(
                                animation: _progress,
                                builder: (context, _) {
                                  final value = i < _index
                                      ? 1.0
                                      : i == _index
                                          ? _progress.value
                                          : 0.0;
                                  return LinearProgressIndicator(
                                    value: value,
                                    minHeight: 3,
                                    backgroundColor: Colors.white24,
                                    color: Colors.white,
                                  );
                                },
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  ListTile(
                    textColor: Colors.white,
                    iconColor: Colors.white,
                    leading: CircleAvatar(
                      child: Text(widget.author.characters.first.toUpperCase()),
                    ),
                    title: Text(widget.author),
                    subtitle: Text(
                      formatRelativeTime(item.ts),
                      style: const TextStyle(color: Colors.white70),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.author == widget.service.myId)
                          IconButton(
                            onPressed: () async {
                              await widget.service.deleteStatus(item.id);
                              if (!context.mounted) return;
                              if (_items.isEmpty) {
                                Navigator.of(context).pop();
                                return;
                              }
                              if (_index >= _items.length) {
                                _index = _items.length - 1;
                              }
                              _playCurrent();
                            },
                            icon: const Icon(Icons.delete_outline),
                          ),
                        IconButton(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusViewsBar extends StatelessWidget {
  const _StatusViewsBar({required this.item, required this.onOpen});

  final StatusItem item;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final count = item.views.length;
    return Material(
      color: Colors.black54,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.remove_red_eye, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Text(
                count == 0
                    ? 'No views yet'
                    : '$count ${count == 1 ? 'view' : 'views'}',
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusViewsSheet extends StatelessWidget {
  const _StatusViewsSheet({required this.item});

  final StatusItem item;

  @override
  Widget build(BuildContext context) {
    final views = [...item.views]
      ..sort((a, b) => b.ts.compareTo(a.ts));
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 0, 0, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                views.isEmpty
                    ? 'No views yet'
                    : '${views.length} ${views.length == 1 ? 'view' : 'views'}',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
            if (views.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('When someone watches this status, they will show up here.'),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: views.length,
                  itemBuilder: (context, index) {
                    final view = views[index];
                    return ListTile(
                      leading: CircleAvatar(
                        child: Text(view.viewer.characters.first.toUpperCase()),
                      ),
                      title: Text(view.viewer),
                      subtitle: Text(formatRelativeTime(view.ts)),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _StatusBody extends StatelessWidget {
  const _StatusBody({
    required this.service,
    required this.item,
    required this.video,
  });

  final SignalingService service;
  final StatusItem item;
  final VideoPlayerController? video;

  @override
  Widget build(BuildContext context) {
    if (item.kind == StatusKind.text) {
      return ColoredBox(
        color: Color(item.bg),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              item.text,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      );
    }
    final url = service.resolveMediaUrl(item.mediaUrl);
    if (item.kind == StatusKind.video) {
      final player = video;
      if (player == null || !player.value.isInitialized) {
        return const Center(child: CircularProgressIndicator());
      }
      return Center(
        child: AspectRatio(
          aspectRatio: player.value.aspectRatio == 0
              ? 9 / 16
              : player.value.aspectRatio,
          child: VideoPlayer(player),
        ),
      );
    }
    if (url == null) {
      return const Center(
        child: Icon(Icons.broken_image, color: Colors.white54, size: 48),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.network(url, fit: BoxFit.contain),
        if (item.text.isNotEmpty)
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              width: double.infinity,
              color: Colors.black54,
              padding: const EdgeInsets.all(16),
              child: Text(
                item.text,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),
          ),
      ],
    );
  }
}
