import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'signaling_service.dart';

class CallScreen extends StatefulWidget {
  const CallScreen({super.key, required this.service});

  final SignalingService service;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  bool _micEnabled = true;
  bool _cameraEnabled = true;
  bool _popping = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    widget.service.addListener(_onServiceChanged);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && widget.service.callConnectedAt != null) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.service.removeListener(_onServiceChanged);
    super.dispose();
  }

  void _onServiceChanged() {
    if (!mounted) return;
    setState(() {});
    if (widget.service.phase == CallPhase.idle && !_popping) {
      _popping = true;
      Navigator.of(context).pop();
    }
  }

  void _hangUp() {
    _popping = true;
    widget.service.endCall();
    Navigator.of(context).pop();
  }

  String _phaseLabel() {
    final service = widget.service;
    if (service.phase == CallPhase.outgoing) return 'Ringing…';
    if (service.callConnectedAt != null) return service.liveCallDuration;
    if (service.phase == CallPhase.connecting) return 'Connecting…';
    return service.isVideoCall ? 'Video call' : 'Audio call';
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    final ringing = service.phase == CallPhase.outgoing;
    final audioOnly = !service.isVideoCall;
    final live = service.callConnectedAt != null;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: ringing || audioOnly
                  ? const ColoredBox(color: Colors.black)
                  : RTCVideoView(
                      service.remoteRenderer,
                      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    ),
            ),
            if (ringing || audioOnly)
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircleAvatar(radius: 48, child: Icon(Icons.person, size: 48)),
                    const SizedBox(height: 16),
                    Text(
                      service.incomingPeerId ?? '',
                      style: const TextStyle(color: Colors.white, fontSize: 22),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _phaseLabel(),
                      style: TextStyle(
                        color: live ? Colors.white : Colors.white70,
                        fontSize: live ? 20 : 16,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            if (service.isVideoCall && !audioOnly)
              Positioned(
                top: 16,
                right: 16,
                width: 120,
                height: 160,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: RTCVideoView(
                    service.localRenderer,
                    mirror: true,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
                ),
              ),
            Positioned(
              top: 16,
              left: 16,
              right: service.isVideoCall ? 152 : 16,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (service.isVideoCall && !ringing) ...[
                    Text(
                      service.incomingPeerId ?? '',
                      style: const TextStyle(color: Colors.white, fontSize: 18),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _phaseLabel(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                  Text(
                    service.status,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
            Positioned(
              bottom: 24,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (!ringing) ...[
                    _ControlButton(
                      icon: _micEnabled ? Icons.mic : Icons.mic_off,
                      onPressed: () {
                        setState(() => _micEnabled = !_micEnabled);
                        service.toggleMic(_micEnabled);
                      },
                    ),
                    const SizedBox(width: 16),
                  ],
                  _ControlButton(
                    icon: Icons.call_end,
                    background: Colors.red,
                    onPressed: _hangUp,
                  ),
                  if (!ringing && service.isVideoCall) ...[
                    const SizedBox(width: 16),
                    _ControlButton(
                      icon: _cameraEnabled ? Icons.videocam : Icons.videocam_off,
                      onPressed: () {
                        setState(() => _cameraEnabled = !_cameraEnabled);
                        service.toggleCamera(_cameraEnabled);
                      },
                    ),
                    const SizedBox(width: 16),
                    _ControlButton(
                      icon: Icons.cameraswitch,
                      onPressed: service.switchCamera,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.icon,
    required this.onPressed,
    this.background = Colors.white24,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: 28,
      backgroundColor: background,
      child: IconButton(
        icon: Icon(icon, color: Colors.white),
        onPressed: onPressed,
      ),
    );
  }
}
