import 'package:flutter/material.dart';

import 'call_screen.dart';
import 'home_screen.dart';
import 'signaling_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final SignalingService _service = SignalingService();
  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();
  bool _incomingOpen = false;
  bool _outgoingOpen = false;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onService);
    _service.start();
  }

  @override
  void dispose() {
    _service.removeListener(_onService);
    super.dispose();
  }

  void _onService() {
    final nav = _navKey.currentState;
    if (nav == null) return;

    if (_service.phase == CallPhase.incoming && !_incomingOpen) {
      _incomingOpen = true;
      nav
          .push(
            MaterialPageRoute(
              builder: (_) => _IncomingCallPage(service: _service),
            ),
          )
          .whenComplete(() {
            _incomingOpen = false;
          });
    }

    if (_service.phase == CallPhase.outgoing && !_outgoingOpen) {
      _outgoingOpen = true;
      nav
          .push(
            MaterialPageRoute(builder: (_) => CallScreen(service: _service)),
          )
          .whenComplete(() {
            _outgoingOpen = false;
            if (_service.phase != CallPhase.idle) {
              _service.endCall();
            }
          });
    }

    if (_service.phase == CallPhase.idle) {
      _incomingOpen = false;
    }
  }

  @override
  Widget build(BuildContext conAtext) {
    return MaterialApp(
      navigatorKey: _navKey,
      title: 'azharChating',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: HomeScreen(service: _service),
    );
  }
}

class _IncomingCallPage extends StatelessWidget {
  const _IncomingCallPage({required this.service});

  final SignalingService service;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        if (service.phase == CallPhase.idle && Navigator.of(context).canPop()) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted && Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            }
          });
        }
        return Scaffold(
          backgroundColor: const Color(0xFF102018),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CircleAvatar(
                    radius: 48,
                    child: Icon(Icons.person, size: 48),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    service.incomingIsVideo
                        ? 'Incoming video call'
                        : 'Incoming audio call',
                    style: const TextStyle(color: Colors.white, fontSize: 24),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    service.incomingPeerId ?? '',
                    style: const TextStyle(color: Colors.white70, fontSize: 18),
                  ),
                  const SizedBox(height: 48),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _RoundAction(
                        color: Colors.red,
                        icon: Icons.call_end,
                        label: 'Decline',
                        onPressed: () {
                          service.declineIncomingCall();
                          Navigator.of(context).pop();
                        },
                      ),
                      _RoundAction(
                        color: Colors.green,
                        icon: service.incomingIsVideo
                            ? Icons.videocam
                            : Icons.call,
                        label: 'Accept',
                        onPressed: () async {
                          await service.acceptIncomingCall();
                          if (!context.mounted) return;
                          Navigator.of(context).pushReplacement(
                            MaterialPageRoute(
                              builder: (_) => CallScreen(service: service),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.color,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final Color color;
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        CircleAvatar(
          radius: 32,
          backgroundColor: color,
          child: IconButton(
            icon: Icon(icon, color: Colors.white),
            onPressed: onPressed,
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(color: Colors.white70)),
      ],
    );
  }
}
