import 'package:flutter/material.dart';

import 'models.dart';
import 'signaling_service.dart';

class CallsTab extends StatelessWidget {
  const CallsTab({
    super.key,
    required this.service,
    required this.onOpenChat,
  });

  final SignalingService service;
  final void Function(String peerId) onOpenChat;

  @override
  Widget build(BuildContext context) {
    final calls = service.callHistory;
    if (calls.isEmpty) {
      return const Center(
        child: Text(
          'No calls yet.\nCall someone from a chat or tap +.',
          textAlign: TextAlign.center,
        ),
      );
    }
    return ListView.builder(
      itemCount: calls.length,
      itemBuilder: (context, index) {
        final call = calls[index];
        final missed = call.outcome == CallOutcome.missed ||
            call.outcome == CallOutcome.declined;
        return ListTile(
          leading: CircleAvatar(
            child: Text(
              call.peerId.isEmpty ? '?' : call.peerId.characters.first,
            ),
          ),
          title: Text(
            call.peerId,
            style: TextStyle(
              color: missed && !call.outgoing ? Colors.red : null,
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: Row(
            children: [
              Icon(
                call.outgoing ? Icons.call_made : Icons.call_received,
                size: 14,
                color: missed ? Colors.red : Colors.green,
              ),
              const SizedBox(width: 6),
              Text(_subtitle(call)),
            ],
          ),
          trailing: IconButton(
            tooltip: call.video ? 'Video call' : 'Audio call',
            onPressed: () => service.callPeer(call.peerId, video: call.video),
            icon: Icon(call.video ? Icons.videocam : Icons.call),
          ),
          onTap: () => onOpenChat(call.peerId),
        );
      },
    );
  }

  String _subtitle(CallRecord call) {
    final when = formatRelativeTime(call.ts);
    final label = switch (call.outcome) {
      CallOutcome.answered => call.durationMs > 0
          ? formatCallDuration(call.durationMs)
          : 'Answered',
      CallOutcome.missed => 'Missed',
      CallOutcome.declined => 'Declined',
      CallOutcome.cancelled => 'Cancelled',
      CallOutcome.ringing => 'Ringing',
    };
    return '$label · $when';
  }
}
