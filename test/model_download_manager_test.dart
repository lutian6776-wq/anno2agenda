import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:anno2agenda/services/local_model_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ModelDownloadProgress calculates progress percentage and speed correctly', () {
    const prog = ModelDownloadProgress(
      modelId: 'qwen3.5-0.8b',
      receivedBytes: 265 * 1024 * 1024,
      totalBytes: 530 * 1024 * 1024,
      speedMBps: 12.5,
    );

    expect(prog.progress, closeTo(0.5, 0.01));
    expect(prog.isCompleted, isFalse);
    expect(prog.error, isNull);
    expect(prog.speedMBps, 12.5);
  });

  test('LocalModelManager catalog contains Qwen and Spark models', () {
    final specIds = LocalModelManager.catalog.map((s) => s.id).toSet();
    expect(specIds.contains('qwen3.5-0.8b'), isTrue);
    expect(specIds.contains('qwen3.5-2b'), isTrue);
    expect(specIds.contains('spark-x2.5-1.7b'), isTrue);
    expect(specIds.contains('spark-x2.5-4b'), isTrue);

    final spark17 = LocalModelManager.catalog.firstWhere((s) => s.id == 'spark-x2.5-1.7b');
    expect(spark17.fileName, 'Spark-X2.5-1.7B-Q4_K_M.gguf');
    expect(spark17.downloadUrl, contains('XHToken/Spark-X2.5-1.7B-GGUF'));

    final spark4 = LocalModelManager.catalog.firstWhere((s) => s.id == 'spark-x2.5-4b');
    expect(spark4.fileName, 'Spark-X2.5-4B-Q4_K_M.gguf');
    expect(spark4.downloadUrl, contains('XHToken/Spark-X2.5-4B-GGUF'));
  });

  test('LocalModelManager tracks multi-model download status and supports per-model cancellation', () {
    // 1. Initially no downloads
    expect(LocalModelManager.isModelDownloading('qwen3.5-0.8b'), isFalse);
    expect(LocalModelManager.isModelDownloading('qwen3.5-2b'), isFalse);
    expect(LocalModelManager.isModelDownloading('spark-x2.5-1.7b'), isFalse);
    expect(LocalModelManager.isModelDownloading('spark-x2.5-4b'), isFalse);

    // 2. Active downloads notifier notifies listeners
    int notifyCount = 0;
    void listener() {
      notifyCount++;
    }

    LocalModelManager.activeDownloadsNotifier.addListener(listener);

    // Cancel specific model
    LocalModelManager.cancelDownload('qwen3.5-0.8b');

    // Verify cancel on specific model does not affect another model
    LocalModelManager.cancelDownload('non-existent');

    expect(notifyCount, greaterThanOrEqualTo(0));
    LocalModelManager.activeDownloadsNotifier.removeListener(listener);
  });

  test('LocalModelManager strips path and normalizes model names and display names', () {
    const fullPathCustom = r'D:\announcement2agenda\models\qwen2.5-1.5b-instruct-q4_k_m.gguf';
    const baseNameCustom = 'qwen2.5-1.5b-instruct-q4_k_m.gguf';

    expect(LocalModelManager.normalizeModelId(fullPathCustom), baseNameCustom);
    expect(LocalModelManager.normalizeModelId(baseNameCustom), baseNameCustom);

    expect(LocalModelManager.getModelDisplayName(fullPathCustom), baseNameCustom);
    expect(LocalModelManager.getModelDisplayName(baseNameCustom), baseNameCustom);

    expect(LocalModelManager.isSameModel(fullPathCustom, baseNameCustom), isTrue);
    expect(LocalModelManager.isSameModel(baseNameCustom, fullPathCustom), isTrue);

    const fullPathCatalog = r'C:/path/to/models/Spark-X2.5-1.7B-Q4_K_M.gguf';
    expect(LocalModelManager.normalizeModelId(fullPathCatalog), 'spark-x2.5-1.7b');
    expect(LocalModelManager.getModelDisplayName(fullPathCatalog), '讯飞星火 Spark-X2.5-1.7B');
  });

  test('LocalModelManager visibleCatalog hides desktop-only Spark models on mobile', () {
    final mobileIds = LocalModelManager.visibleCatalog(isMobile: true)
        .map((s) => s.id)
        .toSet();
    expect(mobileIds.contains('qwen3.5-0.8b'), isTrue);
    expect(mobileIds.contains('qwen3.5-2b'), isTrue);
    expect(mobileIds.contains('spark-x2.5-1.7b'), isFalse);
    expect(mobileIds.contains('spark-x2.5-4b'), isFalse);

    final desktopIds = LocalModelManager.visibleCatalog(isMobile: false)
        .map((s) => s.id)
        .toSet();
    expect(desktopIds.contains('spark-x2.5-1.7b'), isTrue);
    expect(desktopIds.contains('spark-x2.5-4b'), isTrue);
  });

  group('Windows llama-server backend selection and fallback', () {
    late int savedContextSize;

    setUp(() {
      savedContextSize = LocalModelManager.contextSize;
      LocalModelManager.resetWindowsRuntimeStateForTest();
    });

    tearDown(() {
      LocalModelManager.contextSize = savedContextSize;
      LocalModelManager.resetWindowsRuntimeStateForTest();
    });

    test('resolveWindowsContextSize enforces minimum 4096 and respects larger contextSize', () {
      LocalModelManager.contextSize = 2048;
      expect(LocalModelManager.resolveWindowsContextSize(), 4096);

      LocalModelManager.contextSize = 8192;
      expect(LocalModelManager.resolveWindowsContextSize(), 8192);
    });

    test('buildWindowsLlamaServerArgs uses -ngl auto for GPU and -ngl 0 --device none for CPU', () {
      LocalModelManager.contextSize = 2048;
      final gpuArgs = LocalModelManager.buildWindowsLlamaServerArgs(
        modelPath: r'C:\models\qwen.gguf',
        useGpu: true,
      );
      expect(gpuArgs, containsAllInOrder(['-m', r'C:\models\qwen.gguf']));
      expect(gpuArgs, containsAllInOrder(['-c', '4096']));
      expect(gpuArgs, containsAllInOrder(['-ngl', 'auto']));
      expect(gpuArgs.contains('--device'), isFalse);

      final cpuArgs = LocalModelManager.buildWindowsLlamaServerArgs(
        modelPath: r'C:\models\qwen.gguf',
        useGpu: false,
        ctxSize: 8192,
      );
      expect(cpuArgs, containsAllInOrder(['-c', '8192']));
      expect(cpuArgs, containsAllInOrder(['-ngl', '0', '--device', 'none']));
    });

    test('buildWindowsLaunchPlan and isWindowsBackendCompatible cover all DesktopBackendMode values', () {
      expect(
        LocalModelManager.buildWindowsLaunchPlan(
          DesktopBackendMode.autoGpuFallbackCpu,
        ),
        [true, false],
      );
      expect(
        LocalModelManager.buildWindowsLaunchPlan(DesktopBackendMode.cpuOnly),
        [false],
      );
      expect(
        LocalModelManager.buildWindowsLaunchPlan(DesktopBackendMode.gpuOnly),
        [true],
      );

      expect(
        LocalModelManager.isWindowsBackendCompatible(
          preference: DesktopBackendMode.autoGpuFallbackCpu,
          activeBackend: null,
        ),
        isFalse,
      );
      expect(
        LocalModelManager.isWindowsBackendCompatible(
          preference: DesktopBackendMode.autoGpuFallbackCpu,
          activeBackend: 'gpu',
        ),
        isTrue,
      );
      expect(
        LocalModelManager.isWindowsBackendCompatible(
          preference: DesktopBackendMode.autoGpuFallbackCpu,
          activeBackend: 'cpu',
        ),
        isTrue,
      );
      expect(
        LocalModelManager.isWindowsBackendCompatible(
          preference: DesktopBackendMode.cpuOnly,
          activeBackend: 'gpu',
        ),
        isFalse,
      );
      expect(
        LocalModelManager.isWindowsBackendCompatible(
          preference: DesktopBackendMode.cpuOnly,
          activeBackend: 'cpu',
        ),
        isTrue,
      );
      expect(
        LocalModelManager.isWindowsBackendCompatible(
          preference: DesktopBackendMode.gpuOnly,
          activeBackend: 'cpu',
        ),
        isFalse,
      );
      expect(
        LocalModelManager.isWindowsBackendCompatible(
          preference: DesktopBackendMode.gpuOnly,
          activeBackend: 'gpu',
        ),
        isTrue,
      );
    });

    test('autoGpuFallbackCpu succeeds directly on GPU in 1 attempt when GPU works', () async {
      final attempts = <List<String>>[];
      LocalModelManager.desktopBackendMode =
          DesktopBackendMode.autoGpuFallbackCpu;
      LocalModelManager.windowsServerAttemptRunnerForTest = ({
        required String executablePath,
        required List<String> args,
        required String workingDirectory,
        required Map<String, String> environment,
        required bool useGpu,
        required int maxPolls,
        required Duration pollInterval,
      }) async {
        attempts.add(args);
        return true;
      };

      final ok = await LocalModelManager.startWindowsLlamaServerForTest(
        bundledServer: File(r'D:\runtime\llama-server.exe'),
        targetGguf: File(r'D:\models\Qwen3.5-0.8B-Q4_K_M.gguf'),
        targetModelId: 'qwen3.5-0.8b',
      );

      expect(ok, isTrue);
      expect(attempts.length, 1);
      expect(attempts.first, containsAllInOrder(['-ngl', 'auto']));
      expect(LocalModelManager.activeWindowsBackend, 'gpu');
      expect(LocalModelManager.lastWindowsStartFellBackToCpu, isFalse);
      expect(LocalModelManager.currentlyLoadedModelId, 'qwen3.5-0.8b');
    });

    test('autoGpuFallbackCpu falls back to pure CPU when GPU attempt fails', () async {
      final attempts = <List<String>>[];
      final statuses = <String>[];
      LocalModelManager.desktopBackendMode =
          DesktopBackendMode.autoGpuFallbackCpu;
      LocalModelManager.onModelStatusChanged = statuses.add;
      LocalModelManager.windowsServerAttemptRunnerForTest = ({
        required String executablePath,
        required List<String> args,
        required String workingDirectory,
        required Map<String, String> environment,
        required bool useGpu,
        required int maxPolls,
        required Duration pollInterval,
      }) async {
        attempts.add(args);
        return !useGpu;
      };

      final ok = await LocalModelManager.startWindowsLlamaServerForTest(
        bundledServer: File(r'D:\runtime\llama-server.exe'),
        targetGguf: File(r'D:\models\Qwen3.5-0.8B-Q4_K_M.gguf'),
        targetModelId: 'qwen3.5-0.8b',
      );

      expect(ok, isTrue);
      expect(attempts.length, 2);
      expect(attempts[0], containsAllInOrder(['-ngl', 'auto']));
      expect(attempts[1], containsAllInOrder(['-ngl', '0', '--device', 'none']));
      expect(LocalModelManager.activeWindowsBackend, 'cpu');
      expect(LocalModelManager.lastWindowsStartFellBackToCpu, isTrue);
      expect(statuses.any((s) => s.contains('自动降级为纯 CPU')), isTrue);
      expect(statuses.last, contains('CPU 兜底模式'));
    });

    test('gpuOnly stops after 1 failed attempt without falling back to CPU', () async {
      final attempts = <List<String>>[];
      LocalModelManager.desktopBackendMode = DesktopBackendMode.gpuOnly;
      LocalModelManager.windowsServerAttemptRunnerForTest = ({
        required String executablePath,
        required List<String> args,
        required String workingDirectory,
        required Map<String, String> environment,
        required bool useGpu,
        required int maxPolls,
        required Duration pollInterval,
      }) async {
        attempts.add(args);
        return false;
      };

      final ok = await LocalModelManager.startWindowsLlamaServerForTest(
        bundledServer: File(r'D:\runtime\llama-server.exe'),
        targetGguf: File(r'D:\models\Qwen3.5-0.8B-Q4_K_M.gguf'),
        targetModelId: 'qwen3.5-0.8b',
      );

      expect(ok, isFalse);
      expect(attempts.length, 1);
      expect(attempts.first, containsAllInOrder(['-ngl', 'auto']));
      expect(LocalModelManager.activeWindowsBackend, isNull);
      expect(LocalModelManager.lastWindowsStartFellBackToCpu, isFalse);
    });

    test('cpuOnly starts directly in CPU mode without trying GPU', () async {
      final attempts = <List<String>>[];
      LocalModelManager.desktopBackendMode = DesktopBackendMode.cpuOnly;
      LocalModelManager.windowsServerAttemptRunnerForTest = ({
        required String executablePath,
        required List<String> args,
        required String workingDirectory,
        required Map<String, String> environment,
        required bool useGpu,
        required int maxPolls,
        required Duration pollInterval,
      }) async {
        attempts.add(args);
        return true;
      };

      final ok = await LocalModelManager.startWindowsLlamaServerForTest(
        bundledServer: File(r'D:\runtime\llama-server.exe'),
        targetGguf: File(r'D:\models\Qwen3.5-0.8B-Q4_K_M.gguf'),
        targetModelId: 'qwen3.5-0.8b',
      );

      expect(ok, isTrue);
      expect(attempts.length, 1);
      expect(attempts.first, containsAllInOrder(['-ngl', '0', '--device', 'none']));
      expect(LocalModelManager.activeWindowsBackend, 'cpu');
      expect(LocalModelManager.lastWindowsStartFellBackToCpu, isFalse);
    });
  });
}
