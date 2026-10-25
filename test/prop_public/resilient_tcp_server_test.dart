import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:prop/utils/resilient_tcp_server.dart';

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 40));

void main() {
  final servers = <ResilientTcpServer>[];
  final sockets = <Socket>[];

  late List<String> events;
  ResilientTcpServer make({
    int port = 0,
    int attempts = 5,
    bool concurrent = false,
    int max = 8,
    bool forceIPv4 = false,
  }) {
    final server = ResilientTcpServer(
      preferredPort: port,
      portAttempts: attempts,
      allowConcurrentClients: concurrent,
      maxConcurrentClients: max,
      forceIPv4: forceIPv4,
      label: 'test',
      onClientConnected: (_) => events.add('connected'),
      onData: (_, data) => events.add('data:${String.fromCharCodes(data)}'),
      onClientDisconnected: () => events.add('disconnected'),
      onClientLeft: (_) => events.add('left'),
    );
    servers.add(server);
    return server;
  }

  Future<Socket> connect(ResilientTcpServer server) async {
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, server.boundPort);
    sockets.add(socket);
    return socket;
  }

  setUp(() => events = []);

  tearDown(() async {
    for (final socket in sockets) {
      socket.destroy();
    }
    sockets.clear();
    for (final server in servers) {
      await server.stop();
    }
    servers.clear();
  });

  test('listens, registers itself for diagnostics, and unregisters on stop', () async {
    final server = make();
    expect(server.isRunning, isFalse);
    await server.start();
    expect(server.isRunning, isTrue);
    expect(server.boundPort, isNonZero);
    expect(ResilientTcpServer.activeServers, contains(server));
    await server.stop();
    expect(server.isRunning, isFalse);
    expect(ResilientTcpServer.activeServers, isNot(contains(server)));
  });

  test('starting twice is harmless', () async {
    final server = make();
    await server.start();
    final port = server.boundPort;
    await server.start();
    expect(server.boundPort, port);
  });

  test('falls back to the next port when the preferred one is taken', () async {
    final blocker = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    addTearDown(blocker.close);
    final server = make(port: blocker.port, attempts: 5);
    await server.start();
    expect(server.boundPort, isNot(blocker.port));
    expect(server.boundPort, greaterThan(blocker.port));
    expect(server.boundPort, lessThan(blocker.port + 5));
  });

  test('with one attempt a taken port is an error, not a walk to another', () async {
    final blocker = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    addTearDown(blocker.close);
    final server = make(port: blocker.port, attempts: 1);
    await expectLater(server.start(), throwsA(isA<SocketException>()));
    expect(server.isRunning, isFalse);
    expect(ResilientTcpServer.activeServers, isNot(contains(server)));
  });

  test('reports a client and the bytes it sends', () async {
    final server = make();
    await server.start();
    final client = await connect(server);
    client.write('hello');
    await client.flush();
    await settle();
    expect(events, ['connected', 'data:hello']);
    expect(server.hasClient, isTrue);
    expect(server.client, isNotNull);
  });

  test('reports the disconnect once the only client leaves', () async {
    final server = make();
    await server.start();
    final client = await connect(server);
    await settle();
    client.destroy();
    await settle();
    expect(events, ['connected', 'left', 'disconnected']);
    expect(server.hasClient, isFalse);
  });

  test('a new client supersedes the old one without reporting a disconnect', () async {
    final server = make();
    await server.start();
    final first = await connect(server);
    await settle();
    final firstClosed = Completer<void>();
    first.listen((_) {}, onDone: firstClosed.complete, onError: (Object _) => firstClosed.complete());
    final second = await connect(server);
    await settle();
    await firstClosed.future.timeout(const Duration(seconds: 5));
    expect(events, ['connected', 'connected']);
    expect(server.hasClient, isTrue);
    second.write('x');
    await second.flush();
    await settle();
    expect(events.last, 'data:x');
  });

  test('with concurrent clients, each leaving is reported and the disconnect comes with the last', () async {
    final server = make(concurrent: true);
    await server.start();
    final a = await connect(server);
    final b = await connect(server);
    await settle();
    expect(events, ['connected', 'connected']);
    a.destroy();
    await settle();
    expect(events.last, 'left');
    expect(events, isNot(contains('disconnected')));
    b.destroy();
    await settle();
    expect(events.sublist(events.length - 2), ['left', 'disconnected']);
  });

  test('turns away clients beyond the limit', () async {
    final server = make(concurrent: true, max: 1);
    await server.start();
    await connect(server);
    final extra = await connect(server);
    final closed = Completer<void>();
    extra.listen((_) {}, onDone: closed.complete, onError: (Object _) => closed.complete());
    await closed.future.timeout(const Duration(seconds: 5));
    expect(events.where((e) => e == 'connected'), hasLength(1));
  });

  test('dropClient disconnects everyone and says so', () async {
    final server = make();
    await server.start();
    final client = await connect(server);
    final closed = Completer<void>();
    client.listen((_) {}, onDone: closed.complete, onError: (Object _) => closed.complete());
    await settle();
    server.dropClient();
    await closed.future.timeout(const Duration(seconds: 5));
    expect(events, ['connected', 'left', 'disconnected']);
  });

  test('stopping closes the clients without reporting them', () async {
    final server = make();
    await server.start();
    final client = await connect(server);
    final closed = Completer<void>();
    client.listen((_) {}, onDone: closed.complete, onError: (Object _) => closed.complete());
    await settle();
    await server.stop();
    await closed.future.timeout(const Duration(seconds: 5));
    expect(events, ['connected']);
  });

  test('can be forced to IPv4 only', () async {
    final server = make(forceIPv4: true);
    await server.start();
    await connect(server);
    await settle();
    expect(events, ['connected']);
  });
}
