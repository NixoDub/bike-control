import 'dart:io';

import 'package:bike_control/utils/network_server_teardown.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:prop/utils/resilient_tcp_server.dart';

/// A port that is free right now (bound ephemerally, then released).
Future<int> _freePort() async {
  final probe = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
  final port = probe.port;
  await probe.close();
  return port;
}

ResilientTcpServer _server(int port, {int portAttempts = 5}) => ResilientTcpServer(
  preferredPort: port,
  portAttempts: portAttempts,
  forceIPv4: true,
  onClientConnected: (_) {},
  onData: (_, _) {},
  onClientDisconnected: () {},
);

void main() {
  tearDown(() async {
    for (final s in List.of(ResilientTcpServer.activeServers)) {
      await s.stop();
    }
  });

  test('a detached engine releases every network server port', () async {
    final walkingPort = await _freePort();
    final fixedPort = await _freePort();
    final walking = _server(walkingPort);
    final fixed = _server(fixedPort, portAttempts: 1);
    await walking.start();
    await fixed.start();

    await stopNetworkServersOnLifecycleChange(AppLifecycleState.detached);

    expect(walking.isRunning, isFalse);
    expect(fixed.isRunning, isFalse);
    expect(ResilientTcpServer.activeServers, isEmpty);

    // The next engine in the same process must get the preferred ports back
    // instead of walking past (or failing on) the previous engine's sockets.
    final rebound = await ServerSocket.bind(InternetAddress.anyIPv4, walkingPort);
    final reboundFixed = await ServerSocket.bind(InternetAddress.anyIPv4, fixedPort);
    await rebound.close();
    await reboundFixed.close();
  });

  test('merely backgrounding keeps the servers running', () async {
    final server = _server(await _freePort());
    await server.start();

    for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      await stopNetworkServersOnLifecycleChange(state);
    }

    expect(server.isRunning, isTrue);
    expect(ResilientTcpServer.activeServers, contains(server));
  });
}
