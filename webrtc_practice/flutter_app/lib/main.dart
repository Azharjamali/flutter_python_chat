import 'package:flutter/material.dart';

import 'call_screen.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WebRTC Practice',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const JoinScreen(),
    );
  }
}

class JoinScreen extends StatefulWidget {
  const JoinScreen({super.key});

  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> {
  // The server's IP changes depending on whatever WiFi network you're on
  // (see signaling_server/README.md for how to find it with `ipconfig`),
  // so we leave it blank rather than hardcoding one.
  final _serverIpController = TextEditingController();
  final _roomIdController = TextEditingController(text: 'room1');

  @override
  void dispose() {
    _serverIpController.dispose();
    _roomIdController.dispose();
    super.dispose();
  }

  void _joinCall() {
    final ip = _serverIpController.text.trim();
    final room = _roomIdController.text.trim();
    if (ip.isEmpty || room.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter both a server IP and a room ID')),
      );
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CallScreen(serverIp: ip, room: room),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('WebRTC Practice')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _serverIpController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Signaling server IP',
                hintText: 'e.g. 192.168.1.42',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _roomIdController,
              decoration: const InputDecoration(
                labelText: 'Room ID',
                hintText: 'room1',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _joinCall,
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Text('Join Call'),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Both phones/emulators must be on the same WiFi network, '
              'enter the same server IP (your PC\'s LAN IP running '
              'server.py), and use the same room ID.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
