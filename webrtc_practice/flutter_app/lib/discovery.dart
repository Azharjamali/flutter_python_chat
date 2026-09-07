import 'dart:async';
import 'dart:convert';
import 'dart:io';

class DiscoveredServer {
  DiscoveredServer({required this.host, required this.port, this.name});

  final String host;
  final int port;
  final String? name;
}

/// Finds the LAN signaling server without blocking the UI.
class ServerDiscovery {
  static const discoveryPort = 8766;
  static const wsPort = 8765;

  static Future<DiscoveredServer> find({String? lastKnownHost}) async {
    return _find(lastKnownHost: lastKnownHost).timeout(
      const Duration(seconds: 6),
      onTimeout: () => throw Exception('Signaling server not found'),
    );
  }

  static Future<DiscoveredServer> _find({String? lastKnownHost}) async {
    final quickHosts = <String>[
      if (lastKnownHost != null && lastKnownHost.isNotEmpty) lastKnownHost,
      '10.0.2.2',
    ];
    for (final host in quickHosts) {
      if (await _portOpen(host, wsPort)) {
        return DiscoveredServer(host: host, port: wsPort);
      }
    }

    try {
      return await _udpDiscover();
    } catch (_) {}

    throw Exception('Signaling server not found');
  }

  static Future<DiscoveredServer> _udpDiscover() async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;

    final payload = utf8.encode(jsonEncode({
      'type': 'discover',
      'app': 'azharChating',
      'proto': 1,
    }));

    final completer = Completer<DiscoveredServer>();
    socket.listen((event) {
      if (event != RawSocketEvent.read || completer.isCompleted) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      try {
        final message = jsonDecode(utf8.decode(datagram.data));
        if (message is! Map || message['type'] != 'discover-reply') return;
        final hosts = <String>[
          if (message['host'] is String) message['host'] as String,
          ..._asStringList(message['hosts']),
          datagram.address.address,
        ];
        final host = hosts.firstWhere(
          (item) => item.isNotEmpty && item != '0.0.0.0',
          orElse: () => datagram.address.address,
        );
        completer.complete(DiscoveredServer(
          host: host,
          port: (message['ws_port'] as num?)?.toInt() ?? wsPort,
          name: message['server_name'] as String?,
        ));
      } catch (_) {}
    });

    try {
      final targets = [
        InternetAddress('255.255.255.255'),
        InternetAddress('10.0.2.2'),
      ];
      for (var i = 0; i < 2; i++) {
        for (final target in targets) {
          socket.send(payload, target, discoveryPort);
        }
        if (i == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
      return await completer.future.timeout(const Duration(seconds: 2));
    } finally {
      socket.close();
    }
  }

  static Future<bool> _portOpen(String host, int port) async {
    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(milliseconds: 400),
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  static List<String> _asStringList(Object? value) {
    if (value is! List) return const [];
    return [for (final item in value) if (item is String) item];
  }
}
