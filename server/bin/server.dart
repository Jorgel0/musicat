import 'dart:io';

import 'package:musicat_server/musicat_server_runtime.dart';
import 'package:musicat_server/src/soulseek/slskd_config.dart';

/// Thin CLI/Docker/self-hosting entry point: reads the same environment
/// variables it always has and hands them to [startMusicatServer], which is
/// the real, reusable implementation (also used by the Flutter app to embed
/// the server in-process -- see ADR 0040/0041). The startup lines this
/// prints are real operator-facing output depended on by deployed
/// infrastructure (Docker/systemd), not just a convenience -- see
/// `docs/self-hosting.md` and the relay's own systemd setup -- so they must
/// keep printing exactly as before.
void main(List<String> args) async {
  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  final dataDir = Directory(
    Platform.environment['MUSICAT_DATA_DIR'] ?? './data',
  );
  final udpPort =
      int.tryParse(Platform.environment['MUSICAT_UDP_PORT'] ?? '') ?? 0;
  final relayUrl = Platform.environment['MUSICAT_RELAY_URL'];
  final slskdConfig = SlskdConfig.fromEnvironment(Platform.environment);
  final appApiKey = Platform.environment['MUSICAT_APP_API_KEY'];

  await startMusicatServer(
    dataDir: dataDir,
    port: port,
    udpPort: udpPort,
    relayUrl: relayUrl,
    slskdConfig: slskdConfig,
    onLog: print,
    appApiKey: appApiKey,
  );
}
