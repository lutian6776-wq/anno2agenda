import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';
import 'ai_extractor_service.dart';

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
  static String? _cachedAndroidModelsDir;

  /// 正在进行的模型下载任务进度跟踪表 (modelId -> ModelDownloadProgress)
  static final Map<String, ModelDownloadProgress> _activeDownloads = {};
  static Map<String, ModelDownloadProgress> get activeDownloads =>
      Map.unmodifiable(_activeDownloads);

  /// 模型下载任务状态变更通知器 (用于多组件、跨页面以及多次打开弹窗时持续同步进度与速度)
  static final ValueNotifier<Map<String, ModelDownloadProgress>>
      activeDownloadsNotifier =
          ValueNotifier<Map<String, ModelDownloadProgress>>({});

  /// 被主动取消/暂停的模型下载 ID 集合（支持独立按模型取消，互不干扰打扰）
  static final Set<String> _cancelledModelIds = {};

  /// 正在进行下载的网络客户端 (modelId -> HttpClient)
  static final Map<String, HttpClient> _downloadHttpClients = {};

  /// 检查指定模型当前是否正在下载中
  static bool isModelDownloading(String modelId) {
    final p = _activeDownloads[modelId];
    return p != null && !p.isCompleted && p.error == null;
  }

  /// 获取指定模型的当前下载进度
  static ModelDownloadProgress? getDownloadProgress(String modelId) =>
      _activeDownloads[modelId];

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

  /// 高级设置项：模型上下文大小（默认 4096）
  static int contextSize = 4096;

  /// 高级设置项：思考与生成 Token 上限（默认 1024）
  static int maxThinkingTokens = 1024;

  /// 高级设置项：采样温度（默认 0.1）
  static double temperature = 0.1;

  /// 高级设置项：核采样阈值 Top-P（默认 0.85）
  static double topP = 0.85;

  /// 高级设置项：重复词惩罚 Repeat Penalty（默认 1.05）
  static double repeatPenalty = 1.05;

  static int? _loadedContextSize;

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

        if (!alreadyLoaded ||
            _loadedAndroidModelPath != ggufFile.path ||
            _loadedContextSize != contextSize) {
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
            contextSize: contextSize,
            gpuLayers: gpuLayers,
          );
          _loadedAndroidModelPath = ggufFile.path;
          _loadedContextSize = contextSize;
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
          if (resp.statusCode == 404) {
            await resp.drain();
            // 兼容 llama-server: 检测 /health 探活
            final healthReq = await client.getUrl(Uri.parse('http://127.0.0.1:11434/health'));
            final healthResp = await healthReq.close();
            await healthResp.drain();
          } else {
            await resp.drain();
          }
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
        _loadedContextSize = null;
        _currentlyLoadedModelId = null;
        onModelStatusChanged?.call('🗑️ $reason（已释放手机 RAM）');
        return true;
      } else if (Platform.isWindows) {
        // 若存在知程拉起的独立 llama-server 进程，直接终止以彻底释放 GPU/RAM
        if (_managedRuntimeProcess != null) {
          try {
            _managedRuntimeProcess!.kill();
          } catch (_) {}
          _managedRuntimeProcess = null;
        }

        // 先查询当前常驻在显存/内存中的模型列表（针对外部 Ollama）
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

  /// 寻找本地打包自带的 llama-server.exe（支持安装包同级、运行目录以及向上查找工程根目录）
  static File? findBundledLlamaServer() {
    if (!Platform.isWindows) return null;
    final candidates = <String>[
      '${File(Platform.resolvedExecutable).parent.path}\\runtime\\llama-server.exe',
      '${Directory.current.path}\\runtime\\llama-server.exe',
    ];
    var probeDir = Directory.current;
    for (var i = 0; i < 5; i++) {
      candidates.add('${probeDir.path}\\runtime\\llama-server.exe');
      final parent = probeDir.parent;
      if (parent.path == probeDir.path) break;
      probeDir = parent;
    }
    for (final p in candidates) {
      final f = File(p);
      if (f.existsSync()) return f;
    }
    return null;
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
      // 1. 优先探测可执行文件同级 models
      final exeParent = File(Platform.resolvedExecutable).parent.path;
      final exeModels = Directory('$exeParent${Platform.pathSeparator}models');
      if (exeModels.existsSync() &&
          exeModels.listSync().whereType<File>().any((e) => e.path.toLowerCase().endsWith('.gguf'))) {
        return exeModels;
      }

      // 2. 探测当前运行工作目录 models
      final curModels =
          Directory('${Directory.current.path}${Platform.pathSeparator}models');
      if (curModels.existsSync() &&
          curModels.listSync().whereType<File>().any((e) => e.path.toLowerCase().endsWith('.gguf'))) {
        return curModels;
      }

      // 3. 向上逐级回溯寻找包含 GGUF 模型的 models 目录（例如从 build/windows/Release 回溯到根目录）
      var probeDir = Directory.current;
      for (var i = 0; i < 5; i++) {
        final candidate =
            Directory('${probeDir.path}${Platform.pathSeparator}models');
        if (candidate.existsSync() &&
            candidate.listSync().whereType<File>().any((e) => e.path.toLowerCase().endsWith('.gguf'))) {
          return candidate;
        }
        final parent = probeDir.parent;
        if (parent.path == probeDir.path) break;
        probeDir = parent;
      }

      // 若未找到已有模型目录，优先返回已有目录或当前工作目录 models
      if (exeModels.existsSync()) return exeModels;
      if (!curModels.existsSync()) {
        await curModels.create(recursive: true);
      }
      return curModels;
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
    String? gbnfGrammar,
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
      if (!alreadyLoaded ||
          _loadedAndroidModelPath != ggufFile.path ||
          _loadedContextSize != contextSize) {
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
            contextSize: contextSize,
            gpuLayers: gpuLayers,
          );
          _loadedAndroidModelPath = ggufFile.path;
          _loadedContextSize = contextSize;
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

      // 通过底层通道向 llama.cpp 注入 GBNF 语法规则（免思考模式直接强制约束；深度思考模式在 </think> 后惰性触发 GBNF）
      try {
        if (gbnfGrammar != null && gbnfGrammar.trim().isNotEmpty) {
          final grammarKey =
              isThink ? '__gbnf_grammar_lazy__' : '__gbnf_grammar__';
          await controller.registerCustomTemplate(
            grammarKey,
            gbnfGrammar.trim(),
          );
        } else {
          await controller.unregisterCustomTemplate('__gbnf_grammar__');
        }
      } catch (_) {}

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
        maxTokensToGen = maxThinkingTokens;
      }

      final completer = Completer<String>();
      StreamSubscription<String>? sub;

      sub = _androidLlamaController!
          .generate(
            prompt: fullPrompt,
            maxTokens: maxTokensToGen,
            temperature: temperature,
            topP: topP,
            repeatPenalty: repeatPenalty,
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

      String rawOut = '';
      try {
        rawOut = await completer.future
            .timeout(Duration(seconds: isThink ? 180 : 120));
      } catch (_) {
        try {
          await _androidLlamaController?.stop();
        } catch (_) {}
        rawOut = buffer.toString();
      } finally {
        await sub.cancel();
      }

      markActivity();

      // 🚨 思考截断抢救机制（Prefill Rescue）：
      // 当开启深度思考，但因达到最大 Token 上限或超时被截断，导致没有完整输出 </think> 或未能输出完整 JSON
      if (isThink) {
        final currentText = rawOut.isNotEmpty ? rawOut : buffer.toString();
        final thinkEnd = currentText.indexOf('</think>');
        final bool hasUnclosedThink =
            currentText.contains('<think>') && thinkEnd == -1;
        final bool jsonMissingAfterThink = thinkEnd != -1 &&
            !currentText.substring(thinkEnd + '</think>'.length).contains('}');

        if (hasUnclosedThink || jsonMissingAfterThink) {
          String thinkContent = '';
          if (hasUnclosedThink) {
            final tStart = currentText.indexOf('<think>');
            thinkContent = currentText.substring(tStart + '<think>'.length).trim();
          } else {
            final tStart = currentText.indexOf('<think>');
            thinkContent = currentText
                .substring(
                    tStart != -1 ? tStart + '<think>'.length : 0, thinkEnd)
                .trim();
          }

          thinkContent = thinkContent
              .replaceAll('<|im_end|>', '')
              .replaceAll('<|endoftext|>', '')
              .trim();

          // 保护 Prompt 不至于溢出上下文，若思考过长保留最有价值的后半段推论
          if (thinkContent.length > 2500) {
            thinkContent =
                '...[前略]\n${thinkContent.substring(thinkContent.length - 2000)}';
          }

          onToken?.call(
            '\n\n[知程调度] ⚠️ 思考预算耗尽，自动闭合思维链并强制直出日程 JSON...\n{"events":[',
          );

          const jsonPrefill = '{"events":[';
          final rescuePrompt = '<|im_start|>system\n'
              '$systemPrompt<|im_end|>\n'
              '<|im_start|>user\n'
              '$sanitizedUserPrompt<|im_end|>\n'
              '<|im_start|>assistant\n'
              '<think>\n'
              '$thinkContent\n'
              '</think>\n'
              '$jsonPrefill';

          try {
            if (_androidLlamaController!.isGenerating) {
              await _androidLlamaController!.stop();
            }
            try {
              await controller.clearContext();
            } catch (_) {}

            // 注册针对续写的 GBNF 语法机（强制从内部字段开始闭合）
            try {
              await controller.unregisterCustomTemplate('__gbnf_grammar_lazy__');
              await controller.registerCustomTemplate(
                '__gbnf_grammar__',
                AIExtractorService.prefilledAgendaGbnfGrammar.trim(),
              );
            } catch (_) {}

            final rescueBuffer = StringBuffer(jsonPrefill);
            final rescueCompleter = Completer<String>();
            StreamSubscription<String>? rescueSub;

            rescueSub = controller
                .generate(
                  prompt: rescuePrompt,
                  maxTokens: 512,
                  temperature: 0.1,
                  topP: 0.85,
                  repeatPenalty: 1.05,
                )
                .listen(
              (tok) {
                rescueBuffer.write(tok);
                onToken?.call(tok);
                final cur = rescueBuffer.toString();
                if (cur.contains('<|im_end|>') ||
                    cur.contains('<|endoftext|>')) {
                  _androidLlamaController?.stop();
                  if (!rescueCompleter.isCompleted) {
                    rescueCompleter.complete(cur);
                  }
                }
              },
              onDone: () {
                if (!rescueCompleter.isCompleted) {
                  rescueCompleter.complete(rescueBuffer.toString());
                }
              },
              onError: (e) {
                if (!rescueCompleter.isCompleted) {
                  rescueCompleter.completeError(e);
                }
              },
            );

            try {
              final rescueOut = await rescueCompleter.future
                  .timeout(const Duration(seconds: 45));
              await rescueSub.cancel();
              markActivity();
              return _cleanModelJsonOutput(rescueOut);
            } catch (_) {
              await rescueSub.cancel();
              try {
                await _androidLlamaController?.stop();
              } catch (_) {}
              final partial = rescueBuffer.toString().trim();
              if (partial.length > 15) {
                return _cleanModelJsonOutput(partial);
              }
            }
          } catch (_) {}
        }
      }

      if (rawOut.isNotEmpty) {
        return _cleanModelJsonOutput(rawOut);
      }
      final partial = buffer.toString().trim();
      if (partial.length > 15) {
        return _cleanModelJsonOutput(partial);
      }
      return null;
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
      final bundledServer = findBundledLlamaServer();
      final ggufFiles = await listDownloadedGgufFiles();
      if (bundledServer != null && ggufFiles.isNotEmpty) {
        try {
          final runtimeDir = bundledServer.parent.path;
          final cleanEnv = Map<String, String>.from(Platform.environment)
            ..['PATH'] = '$runtimeDir;${Platform.environment['PATH'] ?? ''}'
            ..['HTTP_PROXY'] = ''
            ..['HTTPS_PROXY'] = ''
            ..['http_proxy'] = ''
            ..['https_proxy'] = ''
            ..['NO_PROXY'] = '127.0.0.1,localhost,0.0.0.0';

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
              '-c',
              '4096',
            ],
            workingDirectory: runtimeDir,
            environment: cleanEnv,
            mode: ProcessStartMode.detached,
          );
          // 等待 llama-server 初始化并载入 GPU 显存（模型加载时返回 503，就绪后返回 200）
          for (var i = 0; i < 20; i++) {
            await Future.delayed(const Duration(milliseconds: 600));
            final models = await queryRunningLocalModels();
            if (models.isNotEmpty) {
              return models;
            }
          }
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

  /// 查询本地正在运行的推理引擎（127.0.0.1:11434）中已挂载的模型列表（自适应 Ollama 与 llama-server）
  static Future<List<String>> queryRunningLocalModels({
    String host = '127.0.0.1',
    int port = 11434,
  }) async {
    // 1. 尝试 Ollama: GET /api/tags
    final client1 =
        createDirectHttpClient(timeout: const Duration(milliseconds: 1000));
    try {
      final req = await client1.getUrl(Uri.parse('http://$host:$port/api/tags'));
      final resp =
          await req.close().timeout(const Duration(milliseconds: 1200));
      if (resp.statusCode == 200) {
        final body = await resp.transform(utf8.decoder).join();
        final decoded = jsonDecode(body);
        if (decoded is Map && decoded['models'] is List) {
          final list = (decoded['models'] as List)
              .map((m) => (m as Map)['name']?.toString() ?? '')
              .where((name) => name.isNotEmpty)
              .toList();
          if (list.isNotEmpty) return list;
        }
      }
    } catch (_) {
    } finally {
      client1.close();
    }

    // 2. 尝试 llama-server: GET /v1/models (OpenAI 兼容端点)
    final client2 =
        createDirectHttpClient(timeout: const Duration(milliseconds: 1000));
    try {
      final req = await client2.getUrl(Uri.parse('http://$host:$port/v1/models'));
      final resp =
          await req.close().timeout(const Duration(milliseconds: 1200));
      if (resp.statusCode == 200) {
        final body = await resp.transform(utf8.decoder).join();
        final decoded = jsonDecode(body);
        if (decoded is Map && decoded['data'] is List) {
          final list = (decoded['data'] as List)
              .map((m) => (m as Map)['id']?.toString() ?? '')
              .where((name) => name.isNotEmpty)
              .toList();
          if (list.isNotEmpty) return list;
        }
      }
    } catch (_) {
    } finally {
      client2.close();
    }

    // 3. 尝试 llama-server: GET /health
    final client3 =
        createDirectHttpClient(timeout: const Duration(milliseconds: 800));
    try {
      final req = await client3.getUrl(Uri.parse('http://$host:$port/health'));
      final resp =
          await req.close().timeout(const Duration(milliseconds: 1000));
      if (resp.statusCode == 200) {
        final ggufFiles = await listDownloadedGgufFiles();
        if (ggufFiles.isNotEmpty) {
          return [ggufFiles.first.path.split(Platform.pathSeparator).last];
        }
        return ['llama-server:default'];
      }
    } catch (_) {
    } finally {
      client3.close();
    }

    return [];
  }

  /// 查询本地推理引擎（127.0.0.1:11434）中当前真实常驻在显存/内存中的活跃模型列表
  static Future<List<String>> queryActiveMemoryModels({
    String host = '127.0.0.1',
    int port = 11434,
  }) async {
    // 1. 尝试 Ollama: GET /api/ps
    final client1 =
        createDirectHttpClient(timeout: const Duration(milliseconds: 1000));
    try {
      final req = await client1.getUrl(Uri.parse('http://$host:$port/api/ps'));
      final resp =
          await req.close().timeout(const Duration(milliseconds: 1200));
      if (resp.statusCode == 200) {
        final body = await resp.transform(utf8.decoder).join();
        final decoded = jsonDecode(body);
        if (decoded is Map && decoded['models'] is List) {
          final list = (decoded['models'] as List)
              .map((m) => (m as Map)['name']?.toString() ?? '')
              .where((name) => name.isNotEmpty)
              .toList();
          if (list.isNotEmpty) return list;
        }
      }
    } catch (_) {
    } finally {
      client1.close();
    }

    // 2. 尝试 llama-server: 检查 /health。只要为 200，说明挂载模型常驻在内存/显存
    final client2 =
        createDirectHttpClient(timeout: const Duration(milliseconds: 800));
    try {
      final req = await client2.getUrl(Uri.parse('http://$host:$port/health'));
      final resp =
          await req.close().timeout(const Duration(milliseconds: 1000));
      if (resp.statusCode == 200) {
        final running = await queryRunningLocalModels(host: host, port: port);
        if (running.isNotEmpty) return running;
        return ['llama-server:active'];
      }
    } catch (_) {
    } finally {
      client2.close();
    }

    return [];
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

  /// 一键高速断点续传下载 GGUF 模型权重（对接国内 ModelScope CDN，支持多模型并发与单模型独立启停）
  static Future<void> downloadModel({
    required BuiltInModelSpec spec,
    void Function(ModelDownloadProgress progress)? onProgress,
  }) async {
    // 防止重复触发同个模型的下载任务
    if (isModelDownloading(spec.id)) {
      return;
    }

    _cancelledModelIds.remove(spec.id);
    final dir = await getModelsDirectory();
    final targetFile =
        File('${dir.path}${Platform.pathSeparator}${spec.fileName}');
    final tempFile = File('${targetFile.path}.part');

    int existingBytes = 0;
    if (tempFile.existsSync()) {
      existingBytes = tempFile.lengthSync();
    }

    int totalBytes = spec.expectedSizeMB * 1024 * 1024;
    int received = existingBytes;

    void notifyProgress(ModelDownloadProgress prog) {
      _activeDownloads[spec.id] = prog;
      activeDownloadsNotifier.value =
          Map<String, ModelDownloadProgress>.from(_activeDownloads);
      onProgress?.call(prog);
    }

    // 初始状态通知
    notifyProgress(ModelDownloadProgress(
      modelId: spec.id,
      receivedBytes: existingBytes,
      totalBytes: totalBytes,
      speedMBps: 0.0,
    ));

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    _downloadHttpClients[spec.id] = client;
    IOSink? sink;

    try {
      final req = await client.getUrl(Uri.parse(spec.downloadUrl));
      req.followRedirects = false;
      req.headers.set(
        HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (Anno2Agenda On-Device AI Downloader)',
      );
      if (existingBytes > 0) {
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=$existingBytes-');
      }

      var resp = await req.close();

      // 处理 301/302/307 重定向并保留 Range 请求头（确保 ModelScope CDN 正常断点续传）
      var redirects = 0;
      while ((resp.statusCode == HttpStatus.movedPermanently ||
              resp.statusCode == HttpStatus.found ||
              resp.statusCode == HttpStatus.seeOther ||
              resp.statusCode == HttpStatus.temporaryRedirect ||
              resp.statusCode == HttpStatus.permanentRedirect) &&
          redirects < 5) {
        final loc = resp.headers.value(HttpHeaders.locationHeader);
        if (loc == null) break;
        await resp.drain();
        final redirectUri = Uri.parse(loc);
        final redirectReq = await client.getUrl(redirectUri);
        redirectReq.followRedirects = false;
        redirectReq.headers.set(
          HttpHeaders.userAgentHeader,
          'Mozilla/5.0 (Anno2Agenda On-Device AI Downloader)',
        );
        if (existingBytes > 0) {
          redirectReq.headers.set(HttpHeaders.rangeHeader, 'bytes=$existingBytes-');
        }
        resp = await redirectReq.close();
        redirects++;
      }

      if (resp.statusCode != 200 && resp.statusCode != 206) {
        throw Exception('下载服务器响应异常 (HTTP ${resp.statusCode})');
      }

      final isResumed = resp.statusCode == 206;
      if (!isResumed) {
        existingBytes = 0;
        received = 0;
      }

      final contentRange = resp.headers.value(HttpHeaders.contentRangeHeader);
      if (contentRange != null && contentRange.contains('/')) {
        final totalStr = contentRange.split('/').last.trim();
        final parsed = int.tryParse(totalStr);
        if (parsed != null && parsed > 0) {
          totalBytes = parsed;
        }
      }
      if (totalBytes <= existingBytes) {
        final contentLength = resp.contentLength;
        totalBytes = contentLength > 0
            ? (isResumed ? existingBytes + contentLength : contentLength)
            : spec.expectedSizeMB * 1024 * 1024;
      }

      sink = tempFile.openWrite(
        mode: isResumed ? FileMode.append : FileMode.write,
      );

      final sw = Stopwatch()..start();
      int bytesSinceLastTick = 0;
      double currentSpeedMBps = 0.0;

      await for (final chunk in resp) {
        if (_cancelledModelIds.contains(spec.id)) {
          await sink?.close();
          sink = null;
          _cancelledModelIds.remove(spec.id);
          notifyProgress(ModelDownloadProgress(
            modelId: spec.id,
            receivedBytes: received,
            totalBytes: totalBytes,
            speedMBps: 0,
            error: '已暂停下载（下次点击可继续断点续传）',
          ));
          return;
        }

        sink?.add(chunk);
        received += chunk.length;
        bytesSinceLastTick += chunk.length;

        if (sw.elapsedMilliseconds >= 300) {
          currentSpeedMBps = (bytesSinceLastTick / (1024 * 1024)) /
              (sw.elapsedMilliseconds / 1000.0);
          sw.reset();
          bytesSinceLastTick = 0;
          notifyProgress(ModelDownloadProgress(
            modelId: spec.id,
            receivedBytes: received,
            totalBytes: totalBytes,
            speedMBps: currentSpeedMBps,
          ));
        }
      }

      await sink?.flush();
      await sink?.close();
      sink = null;

      if (_cancelledModelIds.contains(spec.id)) {
        _cancelledModelIds.remove(spec.id);
        notifyProgress(ModelDownloadProgress(
          modelId: spec.id,
          receivedBytes: received,
          totalBytes: totalBytes,
          speedMBps: 0,
          error: '已暂停下载（下次点击可继续断点续传）',
        ));
        return;
      }

      if (targetFile.existsSync()) {
        await targetFile.delete();
      }
      await tempFile.rename(targetFile.path);

      await registerDownloadedGgufToRuntime(spec);

      notifyProgress(ModelDownloadProgress(
        modelId: spec.id,
        receivedBytes: totalBytes,
        totalBytes: totalBytes,
        speedMBps: 0.0,
        isCompleted: true,
      ));

      onModelStatusChanged?.call('🎉 ${spec.name} 下载并自动挂载完成！');
    } catch (e) {
      try {
        await sink?.flush();
        await sink?.close();
      } catch (_) {}

      if (_cancelledModelIds.contains(spec.id)) {
        _cancelledModelIds.remove(spec.id);
        notifyProgress(ModelDownloadProgress(
          modelId: spec.id,
          receivedBytes: received,
          totalBytes: totalBytes,
          speedMBps: 0,
          error: '已暂停下载（下次点击可继续断点续传）',
        ));
        return;
      }

      notifyProgress(ModelDownloadProgress(
        modelId: spec.id,
        receivedBytes: received,
        totalBytes: totalBytes,
        speedMBps: 0,
        error: '下载异常: $e',
      ));
    } finally {
      _downloadHttpClients.remove(spec.id);
      _cancelledModelIds.remove(spec.id);
      try {
        client.close(force: true);
      } catch (_) {}
    }
  }

  /// 取消或暂停模型下载（可传入指定 modelId 进行独立暂停；不传参数则暂停所有下载）
  static void cancelDownload([String? modelId]) {
    if (modelId != null) {
      _cancelledModelIds.add(modelId);
      final client = _downloadHttpClients[modelId];
      if (client != null) {
        try {
          client.close(force: true);
        } catch (_) {}
      }
    } else {
      _cancelledModelIds.addAll(_downloadHttpClients.keys);
      for (final client in _downloadHttpClients.values) {
        try {
          client.close(force: true);
        } catch (_) {}
      }
    }
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
    cancelDownload(spec.id);
    _activeDownloads.remove(spec.id);
    activeDownloadsNotifier.value =
        Map<String, ModelDownloadProgress>.from(_activeDownloads);
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
