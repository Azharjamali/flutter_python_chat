enum MessageStatus { sent, delivered, read }

String formatRelativeTime(int ts) {
  final when = DateTime.fromMillisecondsSinceEpoch(ts);
  final diff = DateTime.now().difference(when);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inHours < 1) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 2) return 'yesterday';
  return '${when.day}/${when.month}/${when.year}';
}

String formatCallDuration(int ms) {
  final total = Duration(milliseconds: ms < 0 ? 0 : ms);
  final hours = total.inHours;
  final minutes = total.inMinutes.remainder(60);
  final seconds = total.inSeconds.remainder(60);
  final mm = minutes.toString().padLeft(2, '0');
  final ss = seconds.toString().padLeft(2, '0');
  if (hours > 0) return '$hours:$mm:$ss';
  return '$mm:$ss';
}

enum CallOutcome { ringing, answered, missed, declined, cancelled }

enum StatusKind { text, image, video }

class CallRecord {
  CallRecord({
    required this.id,
    required this.peerId,
    required this.video,
    required this.outgoing,
    required this.outcome,
    required this.ts,
    this.durationMs = 0,
  });

  final String id;
  final String peerId;
  final bool video;
  final bool outgoing;
  CallOutcome outcome;
  final int ts;
  int durationMs;
}

class StatusView {
  StatusView({required this.viewer, required this.ts});

  final String viewer;
  final int ts;
}

class StatusItem {
  StatusItem({
    required this.id,
    required this.author,
    required this.kind,
    required this.ts,
    this.text = '',
    this.bg = 0xFF075E54,
    this.mediaUrl = '',
    this.viewed = false,
    List<StatusView>? views,
  }) : views = views ?? [];

  final String id;
  final String author;
  final StatusKind kind;
  final int ts;
  final String text;
  final int bg;
  final String mediaUrl;
  bool viewed;
  final List<StatusView> views;

  bool get expired {
    final age = DateTime.now().millisecondsSinceEpoch - ts;
    return age > const Duration(hours: 24).inMilliseconds;
  }
}

class Conversation {
  Conversation({
    required this.peerId,
    required this.roomId,
    this.lastText = '',
    this.lastTs = 0,
    this.online = false,
    this.unread = 0,
    this.typing = false,
  });

  final String peerId;
  final String roomId;
  String lastText;
  int lastTs;
  bool online;
  int unread;
  bool typing;
}

class ChatMessage {
  ChatMessage({
    required this.id,
    required this.roomId,
    required this.peerId,
    required this.fromMe,
    required this.text,
    required this.ts,
    this.status = MessageStatus.sent,
  });

  final String id;
  final String roomId;
  final String peerId;
  final bool fromMe;
  final String text;
  final int ts;
  MessageStatus status;
}
