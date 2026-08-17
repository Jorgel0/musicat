import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../library/presentation/library_providers.dart';
import 'musicat_server_config_controller.dart';

/// Downloads the shared track [trackId] (on [ownerNodeId]'s server) through
/// this device's own Musicat Server and imports it into the local library
/// catalog via the same scanner the folder picker and Soulseek downloads
/// already use (ADR 0029) — P2P sharing is "download a copy", not
/// streaming, per the plan's offline-first Phase 4 scope.
///
/// Used both for a friend's direct/profile shares (ADR 0025) and for a
/// joint-playlist item added by someone else (ADR 0026) — either way it's
/// the same `SharedTrack` mechanism underneath, just discovered
/// differently, so [ownerNodeId]/[trackId]/[extension] are all it needs.
Future<void> downloadAndImportSharedTrack(
  WidgetRef ref, {
  required String ownerNodeId,
  required String trackId,
  required String extension,
}) async {
  final client = ref.read(sharingClientProvider);
  if (client == null) throw StateError('Musicat Server not configured');

  final bytes = await client.downloadSharedTrackFile(ownerNodeId, trackId);

  final ownerDir = Directory(
    p.join(
      (await getApplicationSupportDirectory()).path,
      'shared_downloads',
      ownerNodeId,
    ),
  )..createSync(recursive: true);
  final file = File(p.join(ownerDir.path, '$trackId$extension'));
  await file.writeAsBytes(bytes);

  await ref.read(libraryScannerProvider).scanFolder(ownerDir.path);
}
