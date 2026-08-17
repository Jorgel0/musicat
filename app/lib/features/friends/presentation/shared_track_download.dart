import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/network/social/sharing_client.dart';
import '../../library/presentation/library_providers.dart';
import 'musicat_server_config_controller.dart';

/// Downloads [track] (shared by [friendNodeId]) through this device's own
/// Musicat Server and imports it into the local library catalog via the
/// same scanner the folder picker and Soulseek downloads already use
/// (ADR 0029) — P2P sharing is "download a copy", not streaming, per the
/// plan's offline-first Phase 4 scope.
Future<void> downloadAndImportSharedTrack(
  WidgetRef ref, {
  required String friendNodeId,
  required SharedTrackSummary track,
}) async {
  final client = ref.read(sharingClientProvider);
  if (client == null) throw StateError('Musicat Server not configured');

  final bytes = await client.downloadSharedTrackFile(friendNodeId, track.id);

  final friendDir = Directory(
    p.join(
      (await getApplicationSupportDirectory()).path,
      'shared_downloads',
      friendNodeId,
    ),
  )..createSync(recursive: true);
  final file = File(p.join(friendDir.path, '${track.id}${track.extension}'));
  await file.writeAsBytes(bytes);

  await ref.read(libraryScannerProvider).scanFolder(friendDir.path);
}
