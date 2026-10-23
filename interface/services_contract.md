# 核心服务层契约规范 (Services Contract Specification)

服务层（Services Layer）封装了底层操作系统 Native 交互、端侧 AI 推理引擎加载调度、局域网协同网络服务及端侧大模型生命周期管理。

---

## 1. 平台原生桥接层：`PlatformBridge`

负责 Flutter 与 Android/Windows 原生代码之间的 `MethodChannel` 双向通信（通道标识：`com.anno2agenda/native`）。

### 1.1 Flutter 调用原生平台 (Method Invocations)

| 方法名 | 入参 | 返回值 | 语义说明 |
| :--- | :--- | :--- | :--- |
| `writeEventToSystemCalendar` | `AgendaEvent event` | `Future<String>` | 静默写入系统日历 Provider（免跳出、免用户点保存确认），返回成功提示。 |
| `isFloatingWindowRunning` | 无 | `Future<bool>` | 检查 Android 全局悬浮窗服务（`OverlayService`）是否正在前台运行。 |
| `toggleAndroidFloatingWindow` | `bool enable` | `Future<Map<String, dynamic>>` | 启动或关闭全局悬浮窗。若缺少 `SYSTEM_ALERT_WINDOW` 权限，自动跳转授权页。 |
| `isAccessibilityEnabled` | 无 | `Future<bool>` | 检查「无障碍识屏与截屏助手」服务是否激活。 |
| `openAccessibilitySettings` | 无 | `Future<void>` | 直达系统无障碍服务设置界面。 |
| `getModelsDir` | 无 | `Future<String?>` | 获取 Android 内部专有外部存储目录，作为端侧 GGUF 权重落地路径。 |

### 1.2 原生反向调用 Flutter (Method Call Handlers)

原生平台发生外部事件时，通过通道主动回调 Flutter：
1. **`onExternalTextCaptured`**：
   - 触发时机：用户在微信/QQ/浏览器中划词点击「提取日程」，或通过系统分享选择「知程」；
   - 载荷参数：`{ "text": String, "sourceType": "process_text" | "share" }`；
   - 响应动作：触发全局注册的 `onExternalCapture` 回调，唤醒工作台并执行解析。
2. **`extractAgendaForOverlay`**：
   - 触发时机：用户在悬浮窗内点击「读屏解析」或「剪贴板提取」，不切回 Flutter 主界面；
   - 响应动作：直接在后台调用 `AIExtractorService.extractFromText()`，将结构化 JSON 直接回传给原生悬浮窗渲染。
3. **`preloadModelForOverlay` / `isModelReadyForOverlay`**：
   - 供原生悬浮窗在用户展开面板前预判模型就绪状态，或提前请求后台预热加载权重。

---

## 2. AI 推理调度层：`AIExtractorService`

负责多模式推理路由调度（纯端侧规则引擎、端侧 llama.cpp、Ollama 本地服务、局域网算力节点）与降级保护。

### 2.1 推理模式枚举：`AIEngineMode`
- `hybridAuto`：**混合自动（推荐默认）**。优先调用端侧或局域网大模型，若未就绪或超时，毫秒级降级至内置规则引擎。
- `builtInRuleEngine`：**纯端侧极速规则**。0 内存开销、0 毫秒冷启动，使用启发式时空正则匹配。
- `localLlmServer`：**强制大模型**。仅使用大模型推理，若失败则抛出明确错误。

### 2.2 推理主方法签名契约
```dart
static Future<ExtractionResult> extractFromText({
  required String rawText,
  String sourceType = 'manual',
  AIEngineMode mode = AIEngineMode.hybridAuto,
  String llmEndpoint = 'http://127.0.0.1:11434/api/generate',
  String? llmModelName,
  bool thinkMode = false,
  void Function({String? stepLog, String? token, int? tokenCount})? onProgress,
})
```

### 2.3 进度与流式 Token 回调契约 (`onProgress`)
- `stepLog`：推理流水线步骤诊断日志，如 `[流水线 1/4] 启动端侧预热权重...`；
- `token`：大模型生成的单个增量 Token（字符碎片），直接驱动打字机终端实况展示；
- `tokenCount`：当前累计已生成的 Token 数量，用于实时计算推理速率（tokens/s）。

---

## 3. 端侧大模型生命周期管理：`LocalModelManager`

管理端侧 GGUF 模型的下载、魔搭国内直链镜像、内存常驻、空闲自动卸载与 Think 思考模式。

### 3.1 核心方法契约

| 方法名 | 签名与参数 | 说明 |
| :--- | :--- | :--- |
| `preloadModel` | `({String? preferredModelId}) -> Future<bool>` | 立即将选定的 GGUF 权重加载至 RAM/GPU 显存，使后续提取具备秒级响应能力。 |
| `unloadModel` | `({required String reason}) -> Future<void>` | 显式解除大模型常驻，完全释放占用的数百兆至 2GB 内存空间。 |
| `isModelLoadedInRam` | `() -> Future<bool>` | 检查当前内存中是否已挂载可用模型实例。 |
| `downloadModel` | `({required ModelSpec spec, required Function(ModelDownloadProgress) onProgress})` | 通过阿里云魔搭 ModelScope 国内直链下载模型，支持断点续传与速度计算。 |
| `cancelDownload` | `() -> void` | 暂停当前下载任务，保留已下载的 `.part` 缓存文件。 |
| `deleteDownloadedModel`| `(ModelSpec spec) -> Future<double>` | 彻底删除本地落地模型权重，返回释放的磁盘空间（MB）。 |
| `markActivity` | `() -> void` | 刷新空闲活动计时器，防止在用户正在交互时触发自动释放。 |

### 3.2 自动释放策略（防系统杀后台机制）
- `idleUnloadMinutes`：空闲释放时长配置（1、3、5、10 分钟或 -1 永不释放）；
- 内部启动周期性心跳定时器（每 10 秒校验一次），当 `DateTime.now().difference(_lastActiveTime) > idleUnloadMinutes` 时，自动调用 `unloadModel(reason: '空闲超时自动卸载')`。

---

## 4. 局域网协同与算力反哺服务：`LanSyncService`

利用设备间局域网互通，实现手机与 PC 双向数据同步，并将 PC 的强大 GPU 算力反哺给手机端进行无网络离线推理。
（详见 [局域网协同与算力反哺协议规范](./lan_protocol_spec.md)）
