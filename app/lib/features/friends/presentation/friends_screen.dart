import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/musicat_server_config.dart';
import 'friends_controller.dart';
import 'musicat_server_config_controller.dart';

class FriendsScreen extends ConsumerWidget {
  const FriendsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(musicatServerConfigControllerProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Friends'),
        actions: [
          IconButton(
            tooltip: 'Musicat Server settings',
            icon: const Icon(Icons.dns_outlined),
            onPressed: () => _showServerConfigSheet(context, ref),
          ),
        ],
      ),
      body: config.isConfigured
          ? const _FriendsList()
          : _ServerSetupPrompt(
              onConfigure: () => _showServerConfigSheet(context, ref),
            ),
      floatingActionButton: config.isConfigured
          ? FloatingActionButton(
              onPressed: () => _showAddFriendSheet(context, ref),
              child: const Icon(Icons.person_add_alt),
            )
          : null,
    );
  }

  void _showServerConfigSheet(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => const _ServerConfigSheet(),
    );
  }

  void _showAddFriendSheet(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => const _AddFriendSheet(),
    );
  }
}

class _ServerSetupPrompt extends StatelessWidget {
  const _ServerSetupPrompt({required this.onConfigure});

  final VoidCallback onConfigure;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.dns_outlined, size: 48),
            const SizedBox(height: 16),
            const Text(
              'Connect this device to your own Musicat Server to add '
              'friends and share music.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: onConfigure,
              child: const Text('Set up Musicat Server'),
            ),
          ],
        ),
      ),
    );
  }
}

class _FriendsList extends ConsumerWidget {
  const _FriendsList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(friendsControllerProvider);

    if (state.error != null) {
      return Center(child: Text('Could not reach your Musicat Server.'));
    }
    if (state.friends.isEmpty) {
      return const Center(child: Text('No friends yet — tap + to add one.'));
    }

    return RefreshIndicator(
      onRefresh: () => ref.read(friendsControllerProvider.notifier).refresh(),
      child: ListView.builder(
        itemCount: state.friends.length,
        itemBuilder: (context, index) {
          final entry = state.friends[index];
          final connected = entry.status?.connected ?? false;
          return ListTile(
            leading: CircleAvatar(
              backgroundColor: connected ? Colors.green : Colors.grey,
              child: const Icon(Icons.person, color: Colors.white),
            ),
            title: Text(entry.friend.displayName ?? entry.friend.nodeId),
            subtitle: Text(connected ? 'Connected' : 'Not connected'),
            trailing: IconButton(
              tooltip: 'Remove friend',
              icon: const Icon(Icons.person_remove_outlined),
              onPressed: () => ref
                  .read(friendsControllerProvider.notifier)
                  .removeFriend(entry.friend.nodeId),
            ),
          );
        },
      ),
    );
  }
}

class _ServerConfigSheet extends ConsumerStatefulWidget {
  const _ServerConfigSheet();

  @override
  ConsumerState<_ServerConfigSheet> createState() => _ServerConfigSheetState();
}

class _ServerConfigSheetState extends ConsumerState<_ServerConfigSheet> {
  late final TextEditingController _hostController;
  late final TextEditingController _portController;
  late final TextEditingController _myAddressController;

  @override
  void initState() {
    super.initState();
    final config = ref.read(musicatServerConfigControllerProvider);
    _hostController = TextEditingController(text: config.host);
    _portController = TextEditingController(text: config.port.toString());
    _myAddressController = TextEditingController(text: config.myPublicAddress);
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _myAddressController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final config = MusicatServerConfig(
      host: _hostController.text.trim(),
      port: int.tryParse(_portController.text.trim()) ?? 8080,
      myPublicAddress: _myAddressController.text.trim(),
    );
    await ref.read(musicatServerConfigControllerProvider.notifier).save(config);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Musicat Server', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            'Where this device reaches your own Musicat Server, and the '
            'address to give friends so their server can reach yours.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _hostController,
            decoration: const InputDecoration(
              labelText: 'Host',
              hintText: 'localhost',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _portController,
            decoration: const InputDecoration(labelText: 'Port'),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _myAddressController,
            decoration: const InputDecoration(
              labelText: 'Your address (given to friends)',
              hintText: 'mydomain.example:8080',
            ),
          ),
          const SizedBox(height: 24),
          FilledButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
    );
  }
}

class _AddFriendSheet extends ConsumerStatefulWidget {
  const _AddFriendSheet();

  @override
  ConsumerState<_AddFriendSheet> createState() => _AddFriendSheetState();
}

class _AddFriendSheetState extends ConsumerState<_AddFriendSheet> {
  final _friendAddressController = TextEditingController();
  final _codeController = TextEditingController();
  final _displayNameController = TextEditingController();
  String? _myCode;
  bool _generatingCode = false;
  bool _addingFriend = false;
  String? _error;

  @override
  void dispose() {
    _friendAddressController.dispose();
    _codeController.dispose();
    _displayNameController.dispose();
    super.dispose();
  }

  Future<void> _generateMyCode() async {
    setState(() => _generatingCode = true);
    try {
      final code = await ref
          .read(friendsControllerProvider.notifier)
          .generateMyPairingCode();
      setState(() => _myCode = code);
    } catch (e) {
      setState(() => _error = 'Could not generate a code: $e');
    } finally {
      setState(() => _generatingCode = false);
    }
  }

  Future<void> _addFriend() async {
    setState(() {
      _addingFriend = true;
      _error = null;
    });
    try {
      await ref
          .read(friendsControllerProvider.notifier)
          .addFriend(
            friendAddress: _friendAddressController.text.trim(),
            code: _codeController.text.trim(),
            displayName: _displayNameController.text.trim().isEmpty
                ? null
                : _displayNameController.text.trim(),
          );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() => _error = 'Could not add friend: $e');
    } finally {
      if (mounted) setState(() => _addingFriend = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final myPublicAddress = ref.watch(
      musicatServerConfigControllerProvider.select((c) => c.myPublicAddress),
    );

    return Padding(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Your invite', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Share this code and your address ($myPublicAddress) with a '
              'friend — they enter both on their own device.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            if (_myCode == null)
              OutlinedButton(
                onPressed: _generatingCode ? null : _generateMyCode,
                child: _generatingCode
                    ? const SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Generate a code'),
              )
            else
              Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      _myCode!,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy',
                    icon: const Icon(Icons.copy),
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: _myCode!)),
                  ),
                ],
              ),
            const Divider(height: 32),
            Text(
              'Add a friend',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _friendAddressController,
              decoration: const InputDecoration(
                labelText: "Friend's address",
                hintText: 'their-address.example:8080',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _codeController,
              decoration: const InputDecoration(labelText: "Friend's code"),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _displayNameController,
              decoration: const InputDecoration(labelText: 'Name (optional)'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _addingFriend ? null : _addFriend,
              child: _addingFriend
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Add friend'),
            ),
          ],
        ),
      ),
    );
  }
}
