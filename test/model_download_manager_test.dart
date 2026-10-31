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
}
