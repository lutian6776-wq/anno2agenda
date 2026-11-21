import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:anno2agenda/services/ai_extractor_service.dart';
import 'package:anno2agenda/services/app_settings_service.dart';
import 'package:anno2agenda/services/local_model_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('anno_settings_test_');
  });

  tearDown(() async {
    AppSettingsService.instance.resetForTest();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('AppSettingsService saves and restores all configuration items', () async {
    final service = AppSettingsService.instance;
    await service.init(tempDir.path);

    // Initial default values verify
    expect(service.desktopBackendMode, DesktopBackendMode.autoGpuFallbackCpu);
    expect(
      LocalModelManager.desktopBackendMode,
      DesktopBackendMode.autoGpuFallbackCpu,
    );
    expect(service.contextSize, 2048);
    expect(service.maxThinkingTokens, 1536);
    expect(service.temperature, 0.30);
    expect(service.topP, 0.90);
    expect(service.repeatPenalty, 1.10);

    // 1. Modify settings
    await service.setEngineMode(AIEngineMode.localLlmServer);
    await service.setDesktopBackendMode(DesktopBackendMode.cpuOnly);
    await service.setIdleUnloadMinutes(10);
    await service.setEnableThinkMode(true);
    await service.setAutoPreloadOnOverlayExpand(false);
    await service.setEnableGbnfConstraint(false);
    await service.setPreferredModel('qwen3.5-custom');
    await service.setLlmEndpoint('http://192.168.1.50:11434/api/generate');
    await service.setPeerIp('192.168.1.123');

    await service.setContextSize(8192);
    await service.setMaxThinkingTokens(2048);
    await service.setTemperature(0.35);
    await service.setTopP(0.92);
    await service.setRepeatPenalty(1.15);

    // Verify synced to static services
    expect(AIExtractorService.currentEngineMode, AIEngineMode.localLlmServer);
    expect(AIExtractorService.currentPreferredModel, 'qwen3.5-custom');
    expect(AIExtractorService.currentLlmEndpoint, 'http://192.168.1.50:11434/api/generate');
    expect(AIExtractorService.enableGbnfConstraint, false);

    expect(LocalModelManager.idleUnloadMinutes, 10);
    expect(LocalModelManager.desktopBackendMode, DesktopBackendMode.cpuOnly);
    expect(LocalModelManager.enableThinkMode, true);
    expect(LocalModelManager.autoPreloadOnOverlayExpand, false);
    expect(LocalModelManager.contextSize, 8192);
    expect(LocalModelManager.maxThinkingTokens, 2048);
    expect(LocalModelManager.temperature, 0.35);
    expect(LocalModelManager.topP, 0.92);
    expect(LocalModelManager.repeatPenalty, 1.15);

    // Verify written file
    final file = File('${tempDir.path}${Platform.pathSeparator}app_settings.json');
    expect(await file.exists(), isTrue);

    final content = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect(content['engineMode'], 'localLlmServer');
    expect(content['desktopBackendMode'], 'cpuOnly');
    expect(content['idleUnloadMinutes'], 10);
    expect(content['enableThinkMode'], true);
    expect(content['contextSize'], 8192);
    expect(content['maxThinkingTokens'], 2048);
    expect(content['temperature'], 0.35);
    expect(content['topP'], 0.92);
    expect(content['repeatPenalty'], 1.15);
    expect(content['peerIp'], '192.168.1.123');

    // 2. Test boundary clamping
    await service.setContextSize(100); // Below min (512)
    expect(service.contextSize, AppSettingsService.minContextSize);

    await service.setContextSize(100000); // Above max (32768)
    expect(service.contextSize, AppSettingsService.maxContextSize);

    await service.setTemperature(-0.5); // Below min (0.0)
    expect(service.temperature, AppSettingsService.minTemperature);

    await service.setTemperature(3.0); // Above max (1.5)
    expect(service.temperature, AppSettingsService.maxTemperature);

    // 3. Test reset to default
    await service.resetModelParamsToDefault();
    expect(service.contextSize, AppSettingsService.defaultContextSize);
    expect(service.maxThinkingTokens, AppSettingsService.defaultThinkingTokens);
    expect(service.temperature, AppSettingsService.defaultTemperature);
    expect(service.topP, AppSettingsService.defaultTopP);
    expect(service.repeatPenalty, AppSettingsService.defaultRepeatPenalty);
  });

  test('AppSettingsService saves and restores cloud engine configuration', () async {
    final service = AppSettingsService.instance;
    await service.init(tempDir.path);

    // Defaults
    expect(service.enableCloudEngine, isFalse);
    expect(service.cloudRiskAccepted, isFalse);
    expect(service.cloudApiUrl, isEmpty);
    expect(service.cloudApiKey, isEmpty);
    expect(service.cloudModelName, isEmpty);
    expect(service.enableCloudThinkMode, isFalse);
    expect(service.isCloudConfigured, isFalse);

    // Update cloud settings
    await service.setCloudRiskAccepted(true);
    await service.setEnableCloudEngine(true);
    await service.setCloudServiceConfig(
      apiUrl: 'https://api.deepseek.com/v1',
      apiKey: 'sk-test-cloud-key',
      modelName: 'deepseek-chat',
    );
    await service.setEnableCloudThinkMode(true);
    await service.setFavoriteCloudModels(['deepseek-chat', 'deepseek-reasoner']);
    await service.setFetchedCloudModels(['deepseek-chat']);

    expect(service.isCloudConfigured, isTrue);
    expect(service.isFavoriteCloudModelAvailable('deepseek-chat'), isTrue);
    expect(service.isFavoriteCloudModelAvailable('deepseek-reasoner'), isFalse);
    expect(AIExtractorService.enableCloudEngine, isTrue);
    expect(AIExtractorService.cloudApiUrl, 'https://api.deepseek.com/v1');
    expect(AIExtractorService.cloudApiKey, 'sk-test-cloud-key');
    expect(AIExtractorService.cloudModelName, 'deepseek-chat');
    expect(AIExtractorService.enableCloudThinkMode, isTrue);
    expect(AIExtractorService.favoriteCloudModels,
        ['deepseek-chat', 'deepseek-reasoner']);
    expect(AIExtractorService.fetchedCloudModels, ['deepseek-chat']);

    // Reload from disk into clean singleton state
    service.resetForTest();
    expect(service.enableCloudEngine, isFalse);
    expect(service.favoriteCloudModels, isEmpty);

    await service.init(tempDir.path);
    expect(service.enableCloudEngine, isTrue);
    expect(service.cloudRiskAccepted, isTrue);
    expect(service.cloudApiUrl, 'https://api.deepseek.com/v1');
    expect(service.cloudApiKey, 'sk-test-cloud-key');
    expect(service.cloudModelName, 'deepseek-chat');
    expect(service.enableCloudThinkMode, isTrue);
    expect(service.favoriteCloudModels,
        ['deepseek-chat', 'deepseek-reasoner']);
    expect(service.fetchedCloudModels, ['deepseek-chat']);
    expect(AIExtractorService.isCloudEngineReadyToRoute, isTrue);
  });

  test('AppSettingsService persists and restores desktopBackendMode across reload', () async {
    final service = AppSettingsService.instance;
    await service.init(tempDir.path);

    expect(service.desktopBackendMode, DesktopBackendMode.autoGpuFallbackCpu);
    expect(
      LocalModelManager.desktopBackendMode,
      DesktopBackendMode.autoGpuFallbackCpu,
    );

    await service.setDesktopBackendMode(DesktopBackendMode.cpuOnly);
    expect(service.desktopBackendMode, DesktopBackendMode.cpuOnly);
    expect(LocalModelManager.desktopBackendMode, DesktopBackendMode.cpuOnly);

    service.resetForTest();
    expect(service.desktopBackendMode, DesktopBackendMode.autoGpuFallbackCpu);
    expect(
      LocalModelManager.desktopBackendMode,
      DesktopBackendMode.autoGpuFallbackCpu,
    );

    await service.init(tempDir.path);
    expect(service.desktopBackendMode, DesktopBackendMode.cpuOnly);
    expect(LocalModelManager.desktopBackendMode, DesktopBackendMode.cpuOnly);
  });
}
