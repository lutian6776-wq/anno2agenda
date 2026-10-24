import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:llama_flutter_android/llama_flutter_android.dart';

/// 预置的端侧量化 GGUF 模型规格（对接阿里云魔搭社区 ModelScope 国内高速直链）
class BuiltInModelSpec {
  final String id;
  final String name;
  final String tag;
  final String fileName;
  final String downloadUrl;
  final int expectedSizeMB;
  final String description;
  final bool recommendedForMobile;

  const BuiltInModelSpec({
    required this.id,
    required this.name,
    required this.tag,
    required this.fileName,
    required this.downloadUrl,
    required this.expectedSizeMB,
    required this.description,
    this.recommendedForMobile = false,
  });
}

class ModelDownloadProgress {
  final String modelId;
  final int receivedBytes;
  final int totalBytes;
  final double speedMBps;
  final bool isCompleted;
  final String? error;

  const ModelDownloadProgress({
    required this.modelId,
    required this.receivedBytes,
    required this.totalBytes,
    required this.speedMBps,
    this.isCompleted = false,
    this.error,
  });

  double get progress =>
      totalBytes > 0 ? (receivedBytes / totalBytes).clamp(0.0, 1.0) : 0.0;
}

class LocalModelManager {
  /// 国内高速直链模型库（基于最新 Qwen3.5 混合线性注意力多模态小模型，对接阿里云魔搭 ModelScope 直链）
  static const List<BuiltInModelSpec> catalog = [
    BuiltInModelSpec(
      id: 'qwen3.5-0.8b',
      name: 'Qwen3.5-0.8B 极速端侧版',
      tag: '推荐手机与轻薄本 · 约 530MB',
      fileName: 'Qwen3.5-0.8B-Q4_K_M.gguf',
      downloadUrl:
          'https://modelscope.cn/models/unsloth/Qwen3.5-0.8B-GGUF/resolve/master/Qwen3.5-0.8B-Q4_K_M.gguf',
      expectedSizeMB: 530,
      description: '新一代 Gated DeltaNet 混合线性注意力架构，支持超长上下文与快速非思考模式，手机后台共生不杀进程。',
      recommendedForMobile: true,
    ),
    BuiltInModelSpec(
      id: 'qwen3.5-2b',
      name: 'Qwen3.5-2B 全能多模态版',
      tag: '推荐桌面端与旗舰手机 · 约 1.35GB',
      fileName: 'Qwen3.5-2B-Q4_K_M.gguf',
      downloadUrl:
          'https://modelscope.cn/models/unsloth/Qwen3.5-2B-GGUF/resolve/master/Qwen3.5-2B-Q4_K_M.gguf',
      expectedSizeMB: 1350,
      description: '原生融合视觉理解、工具调用与思维链控制（支持 think:false 秒级输出 JSON），轻松拆解多节点长通知与视频字幕。',
      recommendedForMobile: false,
    ),
  ];

  static Process? _managedRuntimeProcess;
  static bool _isCancelled = false;
  static String? _cachedAndroidModelsDir;

  /// Android 端内嵌 llama.cpp 原生控制器（基于 ARM64 NEON + Vulkan GPU）
  static LlamaController? _androidLlamaController;
  static String? _loadedAndroidModelPath;

  /// 模型常驻与生命周期状态
  static bool _isModelLoading = false;
  static bool get isModelLoading => _isModelLoading;
  static String? _currentlyLoadedModelId;
  static String? get currentlyLoadedModelId => _currentlyLoadedModelId;

  /// 设置项：是否开启思考模式（默认关闭以实现 1 秒极速直出日程）
  static bool enableThinkMode = false;

  /// 设置项：空闲自动释放内存时长（分钟，-1 为永不自动释放）
  static int idleUnloadMinutes = 5;

  /// 设置项：展开悬浮窗时是否提前自动预热模型
  static bool autoPreloadOnOverlayExpand = true;

  /// 空闲释放定时器与外部通知回调
  static Timer? _idleTimer;
  static void Function(String statusMsg)? onModelStatusChanged;

  /// 检查大模型当前是否已常驻在内存/显存中
  static Future<bool> isModelLoadedInRam() async {
    if (Platform.isAndroid) {
      if (_androidLlamaController == null || _loadedAndroidModelPath == null) {
        return false;
      }
      try {
        return await _androidLlamaController!.isModelLoaded();
      } catch (_) {
        return false;
      }
    } else if (Platform.isWindows) {
      // 优先通过 Ollama 原生 /api/ps 查询真实常驻内存/显存的模型
      final active = await queryActiveMemoryModels();
      if (active.isNotEmpty) {
        _currentlyLoadedModelId ??= active.first;
        return true;
      }
      // 若 /api/ps 明确返回空（无模型常驻），同步清空 _currentlyLoadedModelId
      final localServerRunning = (await queryRunningLocalModels()).isNotEmpty;
      if (localServerRunning) {
        _currentlyLoadedModelId = null;
        return false;
      }
      return _currentlyLoadedModelId != null;
    }
    return false;
  }

  /// 标记模型已载入内存/显存并激活空闲释放计时器
  static void markLoaded(String modelId) {
    _currentlyLoadedModelId = modelId;
    markActivity();
  }

  /// 标记模型活跃状态，重置空闲自动释放定时器
  static void markActivity() {
    _idleTimer?.cancel();
    if (idleUnloadMinutes > 0) {
      _idleTimer = Timer(Duration(minutes: idleUnloadMinutes), () async {
        await unloadModel(reason: '空闲达到 $idleUnloadMinutes 分钟，已自动卸载释放内存');
      });
    }
  }

  /// 预热并提前常驻加载大模型（消除首次提取时的冷启动等待）
  static Future<bool> preloadModel({String? preferredModelId}) async {
    if (_isModelLoading) return false;

    while (_activeInferenceLock != null) {
      try {
        await _activeInferenceLock!.future.timeout(const Duration(seconds: 60));
      } catch (_) {
        _activeInferenceLock = null;
        break;
      }
    }

    final currentLock = Completer<void>();
    _activeInferenceLock = currentLock;
    _isModelLoading = true;
    onModelStatusChanged?.call('⏳ 正在加载模型权重至内存/GPU...');

    try {
      if (Platform.isAndroid) {
        final ggufFile = await findLocalGgufFile(preferredModelId);
        if (ggufFile == null || !ggufFile.existsSync()) {
          onModelStatusChanged?.call('⚠️ 未检测到本地模型文件，请先下载');
          return false;
        }

        _androidLlamaController ??= LlamaController();
        final controller = _androidLlamaController!;
        final alreadyLoaded = await controller.isModelLoaded();

        if (!alreadyLoaded || _loadedAndroidModelPath != ggufFile.path) {
          if (alreadyLoaded) {
            await controller.dispose();
            _androidLlamaController = LlamaController();
          }
          int gpuLayers = 0;
          try {
            final gpu = await _androidLlamaController!.detectGpu();
            if (gpu.vulkanSupported && gpu.recommendedGpuLayers > 0) {
              gpuLayers = gpu.recommendedGpuLayers;
            }
          } catch (_) {}

          await _androidLlamaController!.loadModel(
            modelPath: ggufFile.path,
            threads: 6,
            contextSize: 4096,
            gpuLayers: gpuLayers,
          );
          _loadedAndroidModelPath = ggufFile.path;
        }

        _currentlyLoadedModelId =
            preferredModelId ?? ggufFile.path.split(Platform.pathSeparator).last;
        markActivity();
        onModelStatusChanged?.call('🟢 端侧模型预热完成，已就绪');
        return true;
      } else if (Platform.isWindows) {
        final models = await ensureLocalRuntimeAndListModels();
        final target = (preferredModelId != null && preferredModelId.isNotEmpty)
            ? preferredModelId
            : (models.isNotEmpty ? models.first : 'qwen3.5:2b');

        final client = createDirectHttpClient(timeout: const Duration(seconds: 4));
        try {
          final uri = Uri.parse('http://127.0.0.1:11434/api/generate');
          final req = await client.postUrl(uri);
          req.headers.contentType =
              ContentType('application', 'json', charset: 'utf-8');
          req.add(utf8.encode(jsonEncode({
            'model': target,
            'prompt': 'hi',
            'stream': false,
            'keep_alive': '${idleUnloadMinutes > 0 ? idleUnloadMinutes : 60}m',
          })));
          final resp = await req.close();
          await resp.drain();
        } catch (_) {} finally {
          client.close();
        }

        _currentlyLoadedModelId = target;
        markActivity();
        onModelStatusChanged?.call('🟢 本地模型服务已预热就绪 ($target)');
        return true;
      }
    } catch (e) {
      onModelStatusChanged?.call('⚠️ 预热失败: $e');
      return false;
    } finally {
      _isModelLoading = false;
      if (_activeInferenceLock == currentLock) {
        _activeInferenceLock = null;
      }
      if (!currentLock.isCompleted) {
        currentLock.complete();
      }
    }
    return false;
  }

  /// 释放大模型占用的内存/显存（关闭常驻或设置 keep_alive: 0）
  static Future<bool> unloadModel({String reason = '用户手动释放'}) async {
    _idleTimer?.cancel();
    try {
      if (Platform.isAndroid) {
        if (_androidLlamaController != null) {
          try {
            if (_androidLlamaController!.isGenerating) {
              await _androidLlamaController!.stop();
            }
          } catch (_) {}
          await _androidLlamaController!.dispose();
          _androidLlamaController = null;
        }
        _loadedAndroidModelPath = null;
        _currentlyLoadedModelId = null;
        onModelStatusChanged?.call('🗑️ $reason（已释放手机 RAM）');
        return true;
      } else if (Platform.isWindows) {
        // 先查询当前常驻在显存/内存中的模型列表
        final activeList = await queryActiveMemoryModels();
        final targets = <String>{...activeList};
        if (_currentlyLoadedModelId != null) {
          targets.add(_currentlyLoadedModelId!);
        }

        for (final target in targets) {
          final client = createDirectHttpClient(timeout: const Duration(seconds: 3));
          try {
            final uri = Uri.parse('http://127.0.0.1:11434/api/generate');
            final req = await client.postUrl(uri);
            req.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
            req.add(utf8.encode(jsonEncode({
              'model': target,
              'keep_alive': 0,
            })));
            final resp = await req.close();
            await resp.drain();
          } catch (_) {} finally {
            client.close();
          }
        }
        _currentlyLoadedModelId = null;
        onModelStatusChanged?.call('🗑️ $reason（已释放系统显存）');
        return true;
      }
    } catch (_) {}
    return false;
  }

  /// 设置 Android 端私有模型存储目录（由 PlatformBridge 初始化时注入）
  static void setAndroidModelsDir(String path) {
    _cachedAndroidModelsDir = path;
  }

  /// 获取本地 `.gguf` 模型存放目录（支持直接将模型放入该目录制作绿色离线完整版）
  static Future<Directory> getModelsDirectory() async {
    if (Platform.isAndroid) {
      final base =
          _cachedAndroidModelsDir ?? '/data/local/tmp/anno2agenda_models';
      final dir = Directory(base);
      if (!dir.existsSync()) {
        await dir.create(recursive: true);
      }
      return dir;
    } else {
      final dir = Directory(
          '${Directory.current.path}${Platform.pathSeparator}models');
      if (!dir.existsSync()) {
        await dir.create(recursive: true);
      }
      return dir;
    }
  }

  /// 检查某个预置 GGUF 模型是否已下载到本地
  static Future<bool> isModelDownloaded(BuiltInModelSpec spec) async {
    try {
      final dir = await getModelsDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}${spec.fileName}');
      if (!file.existsSync()) return false;
      final lenMB = file.lengthSync() / (1024 * 1024);
      // 文件大小达到预期的 85% 以上视为完整下载
      return lenMB >= spec.expectedSizeMB * 0.85;
    } catch (_) {
      return false;
    }
  }

  /// 获取已下载到本地的 `.gguf` 文件列表
  static Future<List<File>> listDownloadedGgufFiles() async {
    try {
      final dir = await getModelsDirectory();
      if (!dir.existsSync()) return [];
      return dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.gguf'))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 根据模型 ID 或文件名查找本地已下载的 `.gguf` 文件
  static Future<File?> findLocalGgufFile([String? preferredIdOrName]) async {
    final files = await listDownloadedGgufFiles();
    if (files.isEmpty) return null;

    if (preferredIdOrName != null && preferredIdOrName.isNotEmpty) {
      for (final spec in catalog) {
        if (spec.id == preferredIdOrName ||
            spec.fileName.toLowerCase() == preferredIdOrName.toLowerCase()) {
          for (final f in files) {
            if (f.path.toLowerCase().endsWith(spec.fileName.toLowerCase())) {
              return f;
            }
          }
        }
      }
      for (final f in files) {
        if (f.path.toLowerCase().contains(preferredIdOrName.toLowerCase())) {
          return f;
        }
      }
    }
    return files.first;
  }

  /// 串行互斥锁：防止并发调用导致底层 JNI 静态全局指针竞争与 Use-After-Free 崩溃
  static Completer<void>? _activeInferenceLock;

  /// 在 Android 端使用内嵌的 llama.cpp (ARM64 NEON / Vulkan) 直接加载本地 GGUF 模型并执行推理
  static Future<String?> runAndroidNativeInference({
    required String systemPrompt,
    required String userPrompt,
    String? preferredModelId,
    bool? thinkMode,
    void Function(String token)? onToken,
  }) async {
    if (!Platform.isAndroid) return null;

    final ggufFile = await findLocalGgufFile(preferredModelId);
    if (ggufFile == null || !ggufFile.existsSync()) return null;

    // 模型文件完整性保护（至少 10MB）
    try {
      if (ggufFile.lengthSync() < 10 * 1024 * 1024) {
        return null;
      }
    } catch (_) {}

    // 串行互斥排队：防止并发调用导致底层 JNI 静态全局指针竞争与 Use-After-Free 崩溃
    while (_activeInferenceLock != null) {
      try {
        await _activeInferenceLock!.future.timeout(const Duration(seconds: 90));
      } catch (_) {
        _activeInferenceLock = null;
        break;
      }
    }

    final currentLock = Completer<void>();
    _activeInferenceLock = currentLock;

    try {
      _androidLlamaController ??= LlamaController();
      final controller = _androidLlamaController!;

      // 若尚未加载模型或切换了不同模型，则先加载 GGUF 权重并常驻内存
      final alreadyLoaded = await controller.isModelLoaded();
      if (!alreadyLoaded || _loadedAndroidModelPath != ggufFile.path) {
        _isModelLoading = true;
        try {
          if (alreadyLoaded) {
            await controller.dispose();
            _androidLlamaController = LlamaController();
          }
          int gpuLayers = 0;
          try {
            final gpu = await _androidLlamaController!.detectGpu();
            if (gpu.vulkanSupported && gpu.recommendedGpuLayers > 0) {
              gpuLayers = gpu.recommendedGpuLayers;
            }
          } catch (_) {}

          await _androidLlamaController!.loadModel(
            modelPath: ggufFile.path,
            threads: 6,
            contextSize: 4096,
            gpuLayers: gpuLayers,
          );
          _loadedAndroidModelPath = ggufFile.path;
        } finally {
          _isModelLoading = false;
        }
      }

      _currentlyLoadedModelId =
          preferredModelId ?? ggufFile.path.split(Platform.pathSeparator).last;
      markActivity();

      if (_androidLlamaController!.isGenerating) {
        await _androidLlamaController!.stop();
      }

      // 无论是否为首次加载，每次独立日程提取前均严格清空重置上下文与 KV Cache，
      // 将底层的已处理位置 g_n_past 归零，彻底规避多次提取累计导致的窗口溢出与 GGML_ASSERT 崩溃
      try {
        await controller.clearContext();
      } catch (_) {}

      // 对输入文本中的特殊标记进行安全清洗，防止用户文本中的特殊符号干扰分词器导致非法 Token 越界
      final sanitizedUserPrompt = userPrompt
          .replaceAll('<|im_start|>', '')
          .replaceAll('<|im_end|>', '')
          .replaceAll('<|endoftext|>', '')
          .replaceAll('<think>', '')
          .replaceAll('</think>', '')
          .trim();

      final isThink = thinkMode ?? enableThinkMode;
      final String fullPrompt;
      final int maxTokensToGen;
      final StringBuffer buffer;

      if (!isThink) {
        // 免思考极速模式：Qwen3.5 预填充绕过思维链，直接从 {"events":[ 开始输出 JSON
        const jsonPrefill = '{"events":[';
        fullPrompt = '<|im_start|>system\n'
            '$systemPrompt<|im_end|>\n'
            '<|im_start|>user\n'
            '$sanitizedUserPrompt /no_think<|im_end|>\n'
            '<|im_start|>assistant\n'
            '<think>\n\n</think>\n'
            '$jsonPrefill';
        buffer = StringBuffer(jsonPrefill);
        maxTokensToGen = 512;
        onToken?.call(jsonPrefill);
      } else {
        // 深度思考模式：允许输出思维链推理过程，然后输出合法 JSON
        fullPrompt = '<|im_start|>system\n'
            '$systemPrompt<|im_end|>\n'
            '<|im_start|>user\n'
            '$sanitizedUserPrompt<|im_end|>\n'
            '<|im_start|>assistant\n';
        buffer = StringBuffer();
        maxTokensToGen = 1024;
      }

      final completer = Completer<String>();
      StreamSubscription<String>? sub;

      sub = _androidLlamaController!
          .generate(
            prompt: fullPrompt,
            maxTokens: maxTokensToGen,
            temperature: 0.1,
            topP: 0.85,
            repeatPenalty: 1.05,
          )
          .listen(
        (token) {
          buffer.write(token);
          onToken?.call(token);
          final current = buffer.toString();
          if (current.contains('<|im_end|>') || current.contains('<|endoftext|>')) {
            _androidLlamaController?.stop();
            if (!completer.isCompleted) {
              completer.complete(current);
            }
          }
        },
        onDone: () {
          if (!completer.isCompleted) {
            completer.complete(buffer.toString());
          }
        },
        onError: (err) {
          if (!completer.isCompleted) {
            completer.completeError(err);
          }
        },
      );

      try {
        final rawOut = await completer.future
            .timeout(Duration(seconds: isThink ? 180 : 120));
        await sub.cancel();
        markActivity();
        return _cleanModelJsonOutput(rawOut);
      } catch (_) {
        await sub.cancel();
        try {
          await _androidLlamaController?.stop();
        } catch (_) {}
        final partial = buffer.toString().trim();
        if (partial.length > 15) {
          return _cleanModelJsonOutput(partial);
        }
        return null;
      }
    } finally {
      if (_activeInferenceLock == currentLock) {
        _activeInferenceLock = null;
      }
      if (!currentLock.isCompleted) {
        currentLock.complete();
      }
    }
  }

  /// 清理端侧模型生成文本中的特殊结束符并修补预填充 JSON 结构
  static String _cleanModelJsonOutput(String raw) {
    var cleaned = raw
        .replaceAll('<|im_end|>', '')
        .replaceAll('<|endoftext|>', '')
        .replaceAll('```json', '')
        .replaceAll('```', '')
        .trim();

    // 移除深度思考块 <think>...</think>
    final thinkEnd = cleaned.indexOf('</think>');
    if (thinkEnd != -1) {
      cleaned = cleaned.substring(thinkEnd + '</think>'.length).trim();
    }

    // 若因预填充 '{"events":[' 导致模型重复输出了 '{"events":['，剔除重复前缀
    final dupPrefix = RegExp(r'^\{\s*"events"\s*:\s*\[\s*\{\s*"events"\s*:\s*\[');
    if (dupPrefix.hasMatch(cleaned)) {
      cleaned = cleaned.replaceFirst(RegExp(r'^\{\s*"events"\s*:\s*\[\s*'), '');
    }

    final startObj = cleaned.indexOf('{');
    final endObj = cleaned.lastIndexOf('}');
    if (startObj != -1 && endObj > startObj) {
      cleaned = cleaned.substring(startObj, endObj + 1);
    }

    // 若以 '{"events":[' 开头但结尾仅闭合了内部对象 '}' 而未闭合 ']}'，自动补齐
    final trimmed = cleaned.trim();
    if (trimmed.startsWith('{"events":[') && !trimmed.endsWith(']}')) {
      if (trimmed.endsWith(']')) {
        cleaned = '$trimmed}';
      } else if (trimmed.endsWith('}')) {
        cleaned = '$trimmed]}';
      }
    }

    return cleaned;
  }

  /// 创建强制直连（绕过系统 VPN/Clash 代理）的 HttpClient，防止 127.0.0.1 被代理拦截超时
  static HttpClient createDirectHttpClient({Duration? timeout}) {
    final client = HttpClient();
    client.findProxy = (_) => 'DIRECT';
    client.connectionTimeout = timeout ?? const Duration(seconds: 3);
    return client;
  }

  /// 自动检测并静默启动本地大模型推理运行时（支持 Android 内嵌 llama.cpp 与 Windows 守护进程）
  static Future<List<String>> ensureLocalRuntimeAndListModels() async {
    // 1. Android 端：直接扫描手机沙盒内已下载的 GGUF 模型（由内置 llama_flutter_android 引擎直接加载）
    if (Platform.isAndroid) {
      final androidModels = <String>[];
      for (final spec in catalog) {
        if (await isModelDownloaded(spec)) {
          androidModels.add(spec.id);
        }
      }
      final extraFiles = await listDownloadedGgufFiles();
      for (final f in extraFiles) {
        final name = f.path.split(Platform.pathSeparator).last;
        final matchedSpec = catalog
            .where((s) => s.fileName.toLowerCase() == name.toLowerCase());
        if (matchedSpec.isEmpty && !androidModels.contains(name)) {
          androidModels.add(name);
        }
      }
      return androidModels;
    }

    // 2. Windows 端：查询或自动拉起本地推理服务
    final activeModels = await queryRunningLocalModels();
    if (activeModels.isNotEmpty) {
      return activeModels;
    }

    if (Platform.isWindows) {
      final bundledServer =
          File('${Directory.current.path}\\runtime\\llama-server.exe');
      final ggufFiles = await listDownloadedGgufFiles();
      if (bundledServer.existsSync() && ggufFiles.isNotEmpty) {
        try {
          _managedRuntimeProcess ??= await Process.start(
            bundledServer.path,
            [
              '-m',
              ggufFiles.first.path,
              '--port',
              '11434',
              '--host',
              '0.0.0.0',
              '-ngl',
              '99',
            ],
            mode: ProcessStartMode.detached,
          );
          await Future.delayed(const Duration(seconds: 2));
        } catch (_) {}
      }

      final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
      final ollamaExe = File('$localAppData\\Programs\\Ollama\\ollama.exe');
      if (ollamaExe.existsSync()) {
        try {
          final cleanEnv = Map<String, String>.from(Platform.environment)
            ..['HTTP_PROXY'] = ''
            ..['HTTPS_PROXY'] = ''
            ..['http_proxy'] = ''
            ..['https_proxy'] = ''
            ..['NO_PROXY'] = '127.0.0.1,localhost,0.0.0.0'
            ..['OLLAMA_HOST'] = '0.0.0.0:11434';

          _managedRuntimeProcess ??= await Process.start(
            ollamaExe.path,
            ['serve'],
            environment: cleanEnv,
            mode: ProcessStartMode.detached,
          );

          for (var i = 0; i < 7; i++) {
            await Future.delayed(const Duration(milliseconds: 500));
            final models = await queryRunningLocalModels();
            if (models.isNotEmpty) {
              return models;
            }
          }
        } catch (_) {}
      }
    }

    return queryRunningLocalModels();
  }

  /// 查询本地正在运行的推理引擎（127.0.0.1:11434）中已挂载的模型列表
  static Future<List<String>> queryRunningLocalModels({
    String host = '127.0.0.1',
    int port = 11434,
  }) async {
    final client =
        createDirectHttpClient(timeout: const Duration(milliseconds: 1200));
    try {
      final req = await client.getUrl(Uri.parse('http://$host:$port/api/tags'));
      final resp =
          await req.close().timeout(const Duration(milliseconds: 1500));
      if (resp.statusCode != 200) return [];
      final body = await resp.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['models'] is List) {
        return (decoded['models'] as List)
            .map((m) => (m as Map)['name']?.toString() ?? '')
            .where((name) => name.isNotEmpty)
            .toList();
      }
      return [];
    } catch (_) {
      return [];
    } finally {
      client.close();
    }
  }

  /// 查询本地推理引擎（127.0.0.1:11434/api/ps）中当前真实常驻在显存/内存中的活跃模型列表
  static Future<List<String>> queryActiveMemoryModels({
    String host = '127.0.0.1',
    int port = 11434,
  }) async {
    final client =
        createDirectHttpClient(timeout: const Duration(milliseconds: 1200));
    try {
      final req = await client.getUrl(Uri.parse('http://$host:$port/api/ps'));
      final resp =
          await req.close().timeout(const Duration(milliseconds: 1500));
      if (resp.statusCode != 200) return [];
      final body = await resp.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['models'] is List) {
        return (decoded['models'] as List)
            .map((m) => (m as Map)['name']?.toString() ?? '')
            .where((name) => name.isNotEmpty)
            .toList();
      }
      return [];
    } catch (_) {
      return [];
    } finally {
      client.close();
    }
  }

  /// 将应用内一键下载的 `.gguf` 权重自动注册进本地推理引擎，无需用户手动导入
  static Future<String?> registerDownloadedGgufToRuntime(
      BuiltInModelSpec spec) async {
    final dir = await getModelsDirectory();
    final ggufFile =
        File('${dir.path}${Platform.pathSeparator}${spec.fileName}');
    if (!ggufFile.existsSync()) return null;

    if (Platform.isAndroid) {
      // Android 端无需外部服务注册，直接由内置 LlamaController 按需加载
      return spec.id;
    }

    if (Platform.isWindows) {
      final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
      final ollamaExe = File('$localAppData\\Programs\\Ollama\\ollama.exe');
      if (ollamaExe.existsSync()) {
        try {
          await ensureLocalRuntimeAndListModels();
          final modelfile = File('${dir.path}\\Modelfile_${spec.id}');
          await modelfile.writeAsString(
            'FROM "${ggufFile.path.replaceAll('\\', '\\\\')}"\n'
            'PARAMETER temperature 0.1\n'
            'PARAMETER num_ctx 4096\n',
          );
          final cleanEnv = Map<String, String>.from(Platform.environment)
            ..['HTTP_PROXY'] = ''
            ..['HTTPS_PROXY'] = ''
            ..['NO_PROXY'] = '127.0.0.1,localhost';
          final res = await Process.run(
            ollamaExe.path,
            ['create', spec.id, '-f', modelfile.path],
            environment: cleanEnv,
          );
          if (res.exitCode == 0) {
            return spec.id;
          }
        } catch (_) {}
      }
    }
    return spec.fileName;
  }

  /// 一键高速断点续传下载 GGUF 模型权重（对接国内 ModelScope CDN）
  static Future<void> downloadModel({
    required BuiltInModelSpec spec,
    required void Function(ModelDownloadProgress progress) onProgress,
  }) async {
    _isCancelled = false;
    final dir = await getModelsDirectory();
    final targetFile =
        File('${dir.path}${Platform.pathSeparator}${spec.fileName}');
    final tempFile = File('${targetFile.path}.part');

    int existingBytes = 0;
    if (tempFile.existsSync()) {
      existingBytes = tempFile.lengthSync();
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(Uri.parse(spec.downloadUrl));
      req.headers.set(
        HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (Anno2Agenda On-Device AI Downloader)',
      );
      if (existingBytes > 0) {
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=$existingBytes-');
      }

      final resp = await req.close();
      if (resp.statusCode != 200 && resp.statusCode != 206) {
        throw Exception('下载服务器响应异常 (HTTP ${resp.statusCode})');
      }

      final isResumed = resp.statusCode == 206;
      if (!isResumed) {
        existingBytes = 0;
      }

      final contentLength = resp.contentLength;
      final totalBytes = contentLength > 0
          ? existingBytes + contentLength
          : spec.expectedSizeMB * 1024 * 1024;

      final sink = tempFile.openWrite(
        mode: isResumed ? FileMode.append : FileMode.write,
      );

      int received = existingBytes;
      final sw = Stopwatch()..start();
      int bytesSinceLastTick = 0;
      double currentSpeedMBps = 0.0;

      await for (final chunk in resp) {
        if (_isCancelled) {
          await sink.close();
          onProgress(ModelDownloadProgress(
            modelId: spec.id,
            receivedBytes: received,
            totalBytes: totalBytes,
            speedMBps: 0,
            error: '已暂停下载（下次点击可继续断点续传）',
          ));
          return;
        }

        sink.add(chunk);
        received += chunk.length;
        bytesSinceLastTick += chunk.length;

        if (sw.elapsedMilliseconds >= 300) {
          currentSpeedMBps = (bytesSinceLastTick / (1024 * 1024)) /
              (sw.elapsedMilliseconds / 1000.0);
          sw.reset();
          bytesSinceLastTick = 0;
          onProgress(ModelDownloadProgress(
            modelId: spec.id,
            receivedBytes: received,
            totalBytes: totalBytes,
            speedMBps: currentSpeedMBps,
          ));
        }
      }

      await sink.flush();
      await sink.close();

      if (targetFile.existsSync()) {
        await targetFile.delete();
      }
      await tempFile.rename(targetFile.path);

      await registerDownloadedGgufToRuntime(spec);

      onProgress(ModelDownloadProgress(
        modelId: spec.id,
        receivedBytes: totalBytes,
        totalBytes: totalBytes,
        speedMBps: currentSpeedMBps,
        isCompleted: true,
      ));
    } catch (e) {
      onProgress(ModelDownloadProgress(
        modelId: spec.id,
        receivedBytes: existingBytes,
        totalBytes: spec.expectedSizeMB * 1024 * 1024,
        speedMBps: 0,
        error: e.toString(),
      ));
    } finally {
      client.close();
    }
  }

  static void cancelDownload() {
    _isCancelled = true;
  }

  /// 获取某模型未完成断点续传缓存（.part 文件）占用的 MB 大小
  static Future<double> getPartialDownloadSizeMB(BuiltInModelSpec spec) async {
    try {
      final dir = await getModelsDirectory();
      final tempFile =
          File('${dir.path}${Platform.pathSeparator}${spec.fileName}.part');
      if (tempFile.existsSync()) {
        return tempFile.lengthSync() / (1024 * 1024);
      }
    } catch (_) {}
    return 0.0;
  }

  /// 删除应用内下载的 GGUF 模型文件（含断点续传缓存），并同步从本地推理运行时移除，释放磁盘空间
  static Future<double> deleteDownloadedModel(BuiltInModelSpec spec) async {
    _isCancelled = true;
    double freedBytes = 0;
    try {
      final dir = await getModelsDirectory();
      final targetPath = '${dir.path}${Platform.pathSeparator}${spec.fileName}';
      if (Platform.isAndroid && _loadedAndroidModelPath == targetPath) {
        try {
          await _androidLlamaController?.dispose();
        } catch (_) {}
        _androidLlamaController = null;
        _loadedAndroidModelPath = null;
      }

      final filesToRemove = [
        File(targetPath),
        File('$targetPath.part'),
        File('${dir.path}${Platform.pathSeparator}Modelfile_${spec.id}'),
      ];
      for (final file in filesToRemove) {
        if (file.existsSync()) {
          freedBytes += file.lengthSync();
          await file.delete();
        }
      }
    } catch (_) {}

    if (Platform.isWindows) {
      await deleteRuntimeModel(spec.id);
    }
    return freedBytes / (1024 * 1024);
  }

  /// 从本机推理引擎中卸载/删除指定模型
  static Future<bool> deleteRuntimeModel(
    String modelName, {
    String host = '127.0.0.1',
    int port = 11434,
  }) async {
    if (Platform.isAndroid) {
      for (final spec in catalog) {
        if (spec.id == modelName || spec.fileName == modelName) {
          final freed = await deleteDownloadedModel(spec);
          return freed > 0;
        }
      }
      final f = await findLocalGgufFile(modelName);
      if (f != null && f.existsSync()) {
        if (_loadedAndroidModelPath == f.path) {
          try {
            await _androidLlamaController?.dispose();
          } catch (_) {}
          _androidLlamaController = null;
          _loadedAndroidModelPath = null;
        }
        await f.delete();
        return true;
      }
      return false;
    }

    final client =
        createDirectHttpClient(timeout: const Duration(milliseconds: 2000));
    try {
      final req = await client.openUrl(
        'DELETE',
        Uri.parse('http://$host:$port/api/delete'),
      );
      req.headers.contentType =
          ContentType('application', 'json', charset: 'utf-8');
      req.add(utf8.encode(jsonEncode({'name': modelName})));
      final resp =
          await req.close().timeout(const Duration(milliseconds: 3000));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }
}
