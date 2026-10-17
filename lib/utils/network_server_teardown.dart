import 'package:bike_control/main.dart' show recordError;
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:prop/utils/resilient_tcp_server.dart';

/// Closes every network emulator server (OpenBikeControl, MyWhoosh Link,
/// DirCon, Click) once the Flutter engine is being torn down.
///
/// On Android a still-running foreground service can keep the process alive
/// after the activity — and with it this engine — is destroyed. The Dart VM
/// outlives the engine, and server sockets the dying isolate never closed stay
/// bound. The next launch starts a fresh engine in that same process, whose
/// [ResilientTcpServer.activeServers] is empty, so it can neither supersede nor
/// close them: the walking OpenBikeControl server lands one port higher on
/// every such relaunch until it runs out, and the fixed-port MyWhoosh Link
/// fails outright.
///
/// Every stop is kicked off before any is awaited: the close requests leave
/// synchronously, so they go out even if the isolate is shut down before the
/// futures complete. Backgrounding (inactive/hidden/paused) leaves the servers
/// running — that is when the bridge is used.
Future<void> stopNetworkServersOnLifecycleChange(AppLifecycleState state) async {
  if (state != AppLifecycleState.detached) return;
  await Future.wait([
    for (final server in List.of(ResilientTcpServer.activeServers))
      server.stop().catchError(
        (Object e, StackTrace s) => recordError(
          e,
          s,
          context: 'stopNetworkServersOnLifecycleChange(${server.label ?? server.preferredPort})',
        ),
      ),
  ]);
}
