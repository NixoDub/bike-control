import 'dart:async';
import 'dart:io';

import 'package:prop/utils/shared.dart';

/// A TCP server that keeps going when the network does not cooperate: it falls
/// back to the next free port when the preferred one is taken, listens on IPv4
/// and IPv6 together, and by default serves a single client at a time, a new
/// connection superseding the old one (a trainer app that reconnects after a
/// drop must not be refused because the dead socket is still around).
class ResilientTcpServer {
  ResilientTcpServer({
    required this.preferredPort,
    this.portAttempts = 5,
    this.forceIPv4 = false,
    this.allowConcurrentClients = false,
    this.maxConcurrentClients = 8,
    this.label,
    this.owner,
    required this.onClientConnected,
    required this.onData,
    required this.onClientDisconnected,
    this.onClientLeft,
  }) : assert(portAttempts >= 1),
       assert(maxConcurrentClients >= 1);

  final int preferredPort;
  final int portAttempts;
  final bool forceIPv4;
  final bool allowConcurrentClients;
  final int maxConcurrentClients;
  final String? label;

  /// Whoever this server serves on behalf of — the emulator instance, or a
  /// stable key. Compared with `==`.
  final Object? owner;

  /// Every currently-running server, for the diagnostics block.
  static final List<ResilientTcpServer> activeServers = [];

  final void Function(Socket socket) onClientConnected;
  final void Function(Socket socket, List<int> data) onData;
  final void Function() onClientDisconnected;

  /// One client went away, while others may remain.
  final void Function(Socket socket)? onClientLeft;

  ServerSocket? _server;
  int? _boundPort;
  final List<Socket> _clients = [];
  final List<({String address, int sourcePort, DateTime until})> _probes = [];

  bool get isRunning => _server != null;
  bool get hasClient => _clients.isNotEmpty;
  Socket? get client => _clients.isEmpty ? null : _clients.last;
  int get boundPort => _boundPort ?? preferredPort;

  Future<void> start() async {
    if (_server != null) return;
    Object? lastError;
    ServerSocket? server;
    for (var attempt = 0; attempt < portAttempts && server == null; attempt++) {
      try {
        server = await _bind(preferredPort + attempt);
      } on SocketException catch (e) {
        lastError = e;
      }
    }
    if (server == null) throw lastError ?? StateError('Could not bind a TCP port from $preferredPort');
    _server = server;
    _boundPort = server.port;
    activeServers.add(this);
    server.listen(_onSocket, onError: (Object _) {}, cancelOnError: false);
    Logger.info('TCP server ${label ?? ''} listening on port $_boundPort');
  }

  /// Dual-stack unless [forceIPv4]; hosts without an IPv6 stack get IPv4 only.
  Future<ServerSocket> _bind(int port) async {
    if (!forceIPv4) {
      try {
        return await ServerSocket.bind(InternetAddress.anyIPv6, port, v6Only: false);
      } on SocketException {
        // No IPv6 here, or the port is taken: the IPv4 attempt below tells which.
      }
    }
    return ServerSocket.bind(InternetAddress.anyIPv4, port);
  }

  /// Announces that this process is about to open a throwaway TCP connection
  /// to its own server, so the next matching accepted socket is ignored.
  void expectProbe({
    required String address,
    required int sourcePort,
    Duration validity = const Duration(seconds: 5),
  }) {
    _probes.add((address: _plainAddress(address), sourcePort: sourcePort, until: DateTime.now().add(validity)));
  }

  static String _plainAddress(String address) =>
      address.startsWith('::ffff:') ? address.substring('::ffff:'.length) : address;

  bool _isExpectedProbe(Socket socket) {
    final now = DateTime.now();
    _probes.removeWhere((p) => p.until.isBefore(now));
    final address = _plainAddress(socket.remoteAddress.address);
    final index = _probes.indexWhere((p) => p.address == address && p.sourcePort == socket.remotePort);
    if (index < 0) return false;
    _probes.removeAt(index);
    return true;
  }

  void _onSocket(Socket socket) {
    if (_isExpectedProbe(socket)) {
      socket.destroy();
      return;
    }
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {
      // Not every platform lets the option be set on an accepted socket.
    }
    if (allowConcurrentClients) {
      if (_clients.length >= maxConcurrentClients) {
        socket.destroy();
        return;
      }
    } else {
      // The new connection replaces the old one; the old one leaving is not
      // reported, or the owner would see a disconnect right after the connect.
      for (final old in List<Socket>.of(_clients)) {
        _clients.remove(old);
        old.destroy();
      }
    }
    _clients.add(socket);
    onClientConnected(socket);
    socket.listen(
      (data) => onData(socket, data),
      onError: (Object _) => _remove(socket),
      onDone: () => _remove(socket),
      cancelOnError: true,
    );
  }

  void _remove(Socket socket) {
    if (!_clients.remove(socket)) return;
    socket.destroy();
    onClientLeft?.call(socket);
    if (_clients.isEmpty) onClientDisconnected();
  }

  /// Disconnects every client, reporting each as having left.
  void dropClient() {
    for (final socket in List<Socket>.of(_clients)) {
      _remove(socket);
    }
  }

  /// Stops listening and closes every client without reporting them: the
  /// caller asked for this and already knows.
  Future<void> stop() async {
    activeServers.remove(this);
    final server = _server;
    _server = null;
    for (final socket in List<Socket>.of(_clients)) {
      _clients.remove(socket);
      socket.destroy();
    }
    _probes.clear();
    await server?.close();
  }
}
