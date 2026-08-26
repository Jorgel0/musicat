import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

/// `mobile_scanner` only has a real implementation on Android, iOS, macOS,
/// and web — not Linux/Windows (two of this app's three targets). Gate the
/// "Scan QR" affordance on this rather than crash on an unsupported
/// platform; same `Platform.isAndroid` gating precedent as
/// `pick_and_scan_folder.dart`'s storage-permission check, since Android is
/// the only supported platform this app also targets.
bool get qrScanningSupported => Platform.isAndroid;

/// Full-screen camera QR scanner, shared by the friend-invite
/// (`friends_screen.dart`) and joint-playlist-invite
/// (`create_or_join_joint_playlist_sheet.dart`) flows — both only need "the
/// raw text a QR code encoded"; the caller runs it through
/// `InviteUri.parse`.
class QrScannerScreen extends StatefulWidget {
  const QrScannerScreen({super.key, this.title = 'Scan a QR code'});

  final String title;

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen> {
  final MobileScannerController _controller = MobileScannerController();
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    String? value;
    for (final barcode in capture.barcodes) {
      if (barcode.rawValue != null) {
        value = barcode.rawValue;
        break;
      }
    }
    if (value == null) return;
    _handled = true;
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: MobileScanner(controller: _controller, onDetect: _onDetect),
    );
  }
}

/// Requests the camera permission, then opens [QrScannerScreen] and
/// returns the raw string it scanned — or `null` if the user backed out,
/// or permission was denied (a SnackBar explains why in that case).
///
/// Mirrors `pick_and_scan_folder.dart`'s runtime-permission pattern: the
/// storage permission there is requested right before the action that
/// needs it, not eagerly at app startup.
Future<String?> scanQrCode(
  BuildContext context, {
  String title = 'Scan a QR code',
}) async {
  if (!await _ensureCameraPermission()) {
    if (!context.mounted) return null;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Musicat needs camera access to scan a QR code.'),
      ),
    );
    return null;
  }
  if (!context.mounted) return null;
  return Navigator.of(context).push<String>(
    MaterialPageRoute(builder: (_) => QrScannerScreen(title: title)),
  );
}

Future<bool> _ensureCameraPermission() async {
  if (!Platform.isAndroid) return true;
  final status = await Permission.camera.request();
  return status.isGranted;
}
