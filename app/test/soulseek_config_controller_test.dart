import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicat/core/network/soulseek/soulseek_config.dart';
import 'package:musicat/features/settings/soulseek/presentation/soulseek_config_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late ProviderContainer container;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    container = ProviderContainer();
  });

  tearDown(() => container.dispose());

  test('defaults to an empty, unconfigured config', () {
    final config = container.read(soulseekConfigControllerProvider);
    expect(config.isConfigured, isFalse);
    expect(config.host, isEmpty);
    expect(config.port, 5030);
  });

  test('save updates state and persists the config', () async {
    const config = SoulseekConfig(
      backendType: SoulseekBackendType.slskd,
      host: '192.168.1.140',
      port: 5030,
      apiKey: 'k',
    );

    await container
        .read(soulseekConfigControllerProvider.notifier)
        .save(config);

    final state = container.read(soulseekConfigControllerProvider);
    expect(state.host, '192.168.1.140');
    expect(state.port, 5030);
    expect(state.apiKey, 'k');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('soulseekBackendType'), 'slskd');
    expect(prefs.getString('soulseekHost'), '192.168.1.140');
    expect(prefs.getInt('soulseekPort'), 5030);
    expect(prefs.getString('soulseekApiKey'), 'k');
  });

  test('loadSoulseekConfigPreference defaults to an empty config', () async {
    final config = await loadSoulseekConfigPreference();
    expect(config.isConfigured, isFalse);
    expect(config.port, 5030);
  });

  test('loadSoulseekConfigPreference returns the persisted config', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('soulseekBackendType', 'musicatServer');
    await prefs.setString('soulseekHost', '10.0.0.5');
    await prefs.setInt('soulseekPort', 5555);
    await prefs.setString('soulseekApiKey', 'abc');

    final config = await loadSoulseekConfigPreference();
    expect(config.backendType, SoulseekBackendType.musicatServer);
    expect(config.host, '10.0.0.5');
    expect(config.port, 5555);
    expect(config.apiKey, 'abc');
  });

  test(
    'loadSoulseekConfigPreference defaults to slskd for an unset backend type',
    () async {
      final config = await loadSoulseekConfigPreference();
      expect(config.backendType, SoulseekBackendType.slskd);
    },
  );

  group('soulseekClientProvider', () {
    test('is null when not configured', () {
      expect(container.read(soulseekClientProvider), isNull);
    });

    test('is non-null once configured for direct slskd', () async {
      await container
          .read(soulseekConfigControllerProvider.notifier)
          .save(
            const SoulseekConfig(
              backendType: SoulseekBackendType.slskd,
              host: 'h',
              port: 5030,
              apiKey: 'k',
            ),
          );

      expect(container.read(soulseekClientProvider), isNotNull);
    });

    test(
      'is non-null once configured for Musicat Server, without an API key',
      () async {
        await container
            .read(soulseekConfigControllerProvider.notifier)
            .save(
              const SoulseekConfig(
                backendType: SoulseekBackendType.musicatServer,
                host: 'h',
                port: 8080,
                apiKey: '',
              ),
            );

        expect(container.read(soulseekClientProvider), isNotNull);
      },
    );
  });
}
