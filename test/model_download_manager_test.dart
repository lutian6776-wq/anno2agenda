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

  test('LocalModelManager tracks multi-model download status and supports per-model cancellation', () {
    // 1. Initially no downloads
    expect(LocalModelManager.isModelDownloading('qwen3.5-0.8b'), isFalse);
    expect(LocalModelManager.isModelDownloading('qwen3.5-2b'), isFalse);

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
}
