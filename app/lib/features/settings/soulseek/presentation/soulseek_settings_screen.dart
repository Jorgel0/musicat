import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/network/soulseek/soulseek_client_factory.dart';
import '../../../../core/network/soulseek/soulseek_config.dart';
import 'soulseek_config_controller.dart';

const _defaultPorts = {
  SoulseekBackendType.slskd: 5030,
  SoulseekBackendType.musicatServer: 8080,
};

class SoulseekSettingsScreen extends ConsumerStatefulWidget {
  const SoulseekSettingsScreen({super.key});

  @override
  ConsumerState<SoulseekSettingsScreen> createState() =>
      _SoulseekSettingsScreenState();
}

class _SoulseekSettingsScreenState
    extends ConsumerState<SoulseekSettingsScreen> {
  late SoulseekBackendType _backendType;
  late final TextEditingController _hostController;
  late final TextEditingController _portController;
  late final TextEditingController _apiKeyController;
  bool _obscureApiKey = true;
  bool _testingConnection = false;

  @override
  void initState() {
    super.initState();
    final config = ref.read(soulseekConfigControllerProvider);
    _backendType = config.backendType;
    _hostController = TextEditingController(text: config.host);
    _portController = TextEditingController(text: config.port.toString());
    _apiKeyController = TextEditingController(text: config.apiKey);
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  void _selectBackendType(SoulseekBackendType type) {
    setState(() {
      // Only nudge the port field if it's still at the *other* backend's
      // default — leave an already-customized value alone.
      if (int.tryParse(_portController.text.trim()) ==
          _defaultPorts[_backendType]) {
        _portController.text = _defaultPorts[type].toString();
      }
      _backendType = type;
    });
  }

  SoulseekConfig get _formConfig => SoulseekConfig(
    backendType: _backendType,
    host: _hostController.text.trim(),
    port: int.tryParse(_portController.text.trim()) ?? 5030,
    apiKey: _apiKeyController.text.trim(),
  );

  Future<void> _save() async {
    await ref.read(soulseekConfigControllerProvider.notifier).save(_formConfig);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Saved.')));
  }

  Future<void> _testConnection() async {
    final config = _formConfig;
    if (!config.isConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a host (and API key) first.')),
      );
      return;
    }

    setState(() => _testingConnection = true);
    final client = buildSoulseekClient(config);
    String message;
    try {
      message = await client.isConnected()
          ? 'Connected — logged into the Soulseek network.'
          : 'Reached the backend, but not logged into Soulseek yet.';
    } catch (e) {
      message = 'Could not reach the backend: $e';
    }
    if (!mounted) return;
    setState(() => _testingConnection = false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final isMusicatServer = _backendType == SoulseekBackendType.musicatServer;

    return Scaffold(
      appBar: AppBar(title: const Text('Soulseek backend')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SegmentedButton<SoulseekBackendType>(
            segments: const [
              ButtonSegment(
                value: SoulseekBackendType.slskd,
                label: Text('Direct slskd'),
              ),
              ButtonSegment(
                value: SoulseekBackendType.musicatServer,
                label: Text('Musicat Server'),
              ),
            ],
            selected: {_backendType},
            onSelectionChanged: (selection) =>
                _selectBackendType(selection.first),
          ),
          const SizedBox(height: 16),
          Text(
            isMusicatServer
                ? 'Musicat searches and downloads via a self-hosted Musicat '
                      'Server instance, which wraps slskd for you — no API '
                      'key needed here.'
                : 'Musicat searches and downloads via a self-hosted slskd '
                      'instance. Point it at one on your network below.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _hostController,
            decoration: const InputDecoration(
              labelText: 'Host',
              hintText: '192.168.1.140',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _portController,
            decoration: const InputDecoration(labelText: 'Port'),
            keyboardType: TextInputType.number,
          ),
          if (!isMusicatServer) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _apiKeyController,
              obscureText: _obscureApiKey,
              decoration: InputDecoration(
                labelText: 'API key',
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscureApiKey ? Icons.visibility : Icons.visibility_off,
                  ),
                  onPressed: () =>
                      setState(() => _obscureApiKey = !_obscureApiKey),
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Text(
            'If the reported downloads directory exists on this device, '
            'finished downloads are added to your library automatically — '
            'no extra setup needed.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _testingConnection ? null : _testConnection,
                  child: _testingConnection
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Test connection'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _save,
                  child: const Text('Save'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
