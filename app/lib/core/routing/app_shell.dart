import 'package:flutter/material.dart';

import '../../features/player/presentation/mini_player.dart';

/// Wraps every top-level route with the persistent mini-player.
class AppShell extends StatelessWidget {
  const AppShell({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: child, bottomNavigationBar: const MiniPlayer());
  }
}
