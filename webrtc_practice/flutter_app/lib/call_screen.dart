import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'signaling_service.dart';

class CallScreen extends StatefulWidget {
  const CallScreen({super.key, required this.serverIp, required this.room});

  final String serverIp;
  final String room;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  late final SignalingService _signalingService;
  String _status = 'Starting...';
  bool _micEnabled = true;
  bool _cameraEnabled = true;

  @override
  void initState() {
    super.initState();
    _signalingService = SignalingService(serverIp: widget.serverIp, room: widget.room)
      ..onStatusChange = (status) {
        if (mounted) setState(() => _status = status);
      };
    _signalingService.start();
  }

  @override
  void dispose() {
    _signalingService.hangUp();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: RTCVideoView(
                _signalingService.remoteRenderer,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              ),
            ),
            Positioned(
              top: 16,
              right: 16,
              width: 120,
              height: 160,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: RTCVideoView(
                  _signalingService.localRenderer,
                  mirror: true,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
              ),
            ),
            Positioned(
              top: 16,
              left: 16,
              right: 152,
              child: Text(
                _status,
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
            Positioned(
              bottom: 24,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _ControlButton(
                    icon: _micEnabled ? Icons.mic : Icons.mic_off,
                    onPressed: () {
                      setState(() => _micEnabled = !_micEnabled);
                      _signalingService.toggleMic(_micEnabled);
                    },
                  ),
                  const SizedBox(width: 16),
                  _ControlButton(
                    icon: Icons.call_end,
                    background: Colors.red,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 16),
                  _ControlButton(
                    icon: _cameraEnabled ? Icons.videocam : Icons.videocam_off,
                    onPressed: () {
                      setState(() => _cameraEnabled = !_cameraEnabled);
                      _signalingService.toggleCamera(_cameraEnabled);
                    },
                  ),
                  const SizedBox(width: 16),
                  _ControlButton(
                    icon: Icons.cameraswitch,
                    onPressed: _signalingService.switchCamera,
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
