# 核心服务层契约规范 (Services Contract Specification)

服务层（Services Layer）封装了底层操作系统 Native 交互、端侧 AI 推理引擎加载调度、局域网协同网络服务及端侧大模型生命周期管理。

---

## 1. 平台原生桥接层：`PlatformBridge`

负责 Flutter 与 Android/Windows 原生代码之间的 `MethodChannel` 双向通信（通道标识：`com.anno2agenda/native`）。

### 1.1 Flutter 调用原生平台 (Method Invocations)

| 方法名 | 入参 | 返回值 | 语义说明 |
| :--- | :--- | :--- | :--- |
| `writeCalendarEvent` | `AgendaEvent event` | `Future<CalendarWriteResult>` | 结构化写入系统日历 Provider（免跳出确认），返回事件 ID 与细粒度结果。 |
| `writeEventToSystemCalendar` | `AgendaEvent event` | `Future<String>` | 兼容老版本，写入系统日历并返回成功文字提示。 |
| `isFloatingWindowRunning` | 无 | `Future<bool>` | 检查 Android 全局悬浮窗服务（`FloatingBubbleService`）是否正在前台运行。 |
| `toggleAndroidFloatingWindow` | `bool enable` | `Future<Map<String, dynamic>>` | 启动或关闭全局悬浮窗。若缺少 `SYSTEM_ALERT_WINDOW` 权限，自动跳转授权页。 |
| `isAccessibilityEnabled` | 无 | `Future<bool>` | 检查「无障碍识屏与截屏助手」服务是否激活。 |
| `openAccessibilitySettings` | 无 | `Future<void>` | 直达系统无障碍服务设置界面。 |
| `getModelsDir` | 无 | `Future<String?>` | 获取 Android 内部专有外部存储目录，作为端侧 GGUF 权重落地路径。 |
| `getAppStorageDir` | 无 | `Future<String?>` | 获取应用内部沙盒数据存储目录，供原生悬浮窗与 Flutter 共享 `agenda_events.json` 本地持久化文件。 |

### 1.2 原生反向调用 Flutter (Method Call Handlers)

原生平台发生外部事件时，通过通道主动回调 Flutter：
1. **`onExternalTextCaptured`**：
   - 触发时机：用户在微信/QQ/浏览器中划词点击「提取日程」，或通过系统分享选择「知程」；
   - 载荷参数：`{ "text": String, "sourceType": "process_text" | "share" }`；
   - 响应动作：触发全局注册的 `onExternalCapture` 回调，唤醒工作台并执行解析。
2. **`extractAgendaForOverlay`**：
   - 触发时机：用户在悬浮窗内点击「读屏解析」、「截屏OCR」或「剪贴板提取」，不切回 Flutter 主界面；
   - 载荷参数：`{ "text": String, "sourceType": String }`；
   - 响应动作：在后台调用 `AIExtractorService.extractFromText()`，以完整 `AgendaEvent` 规范字典集合回传给原生悬浮窗渲染与直写。
3. **`onOverlayAgendaWritten`**：
   - 触发时机：Android 原生悬浮窗一键静默写入系统日历成功后；
   - 载荷参数：`List<Map<String, dynamic>>`（含完整的 id、时间戳、systemCalendarEventId 等）；
   - 响应动作：调用 `AgendaWriteService.syncOverlayWrittenEvents()`，自动去重入库、持久化并通知「我的日程」与工作台即时刷新。
4. **`onFloatingWindowStateChanged`**：
   - 触发时机：原生悬浮窗 Service 启动、关闭或销毁时；
   - 载荷参数：`bool isRunning`；
   - 响应动作：通知 `FloatingOverlayService.isRunningNotifier`，各页面徽章与开关无感联动。
5. **`preloadModelForOverlay` / `isModelReadyForOverlay`**：
   - 供原生悬浮窗在用户展开面板前预判模型就绪状态，或提前请求后台预热加载权重。

### 1.3 跨平台 MethodChannel 传输数据协议 (Channel Map Protocol)

悬浮窗与 Flutter 引擎间交互的日程对象必须包含以下完整字段：

```json
{
  "id": "1697523120000000",
  "title": "操作系统期中机试",
  "startTime": "2026-10-28T19:00:00.000",
  "startMillis": 1793185200000,
  "endTime": "2026-10-28T21:00:00.000",
  "endMillis": 1793192400000,
  "location": "科技楼101",
  "description": "请携带学生证提前10分钟入场",
  "sourceText": "下周二晚上7点在科技楼101进行期中机试测验...",
  "sourceType": "screen_a11y",
  "reminderMinutes": 30,
  "checklist": ["学生证", "草稿纸"],
  "confidence": 0.95,
  "syncedToSystemCalendar": true,
  "systemCalendarEventId": "1024",
  "deviceOrigin": "android"
}
```

---

## 2. 统一日程写入核心服务：`AgendaWriteService`

统管应用内主工作台、我的日程页面、局域网协同以及 Android 全局悬浮窗的原生直写。

### 2.1 核心方法契约

```dart
class AgendaWriteService {
  /// 写入单条日程
  Future<AgendaWriteResult> writeEvent(
    AgendaEvent event, {
    bool writeToSystemCalendar = true,
  });

  /// 批量写入日程
  Future<AgendaBatchWriteResult> writeEvents(
    List<AgendaEvent> events, {
    bool writeToSystemCalendar = true,
  });

  /// 悬浮窗写入完成后的反向同步
  Future<AgendaBatchWriteResult> syncOverlayWrittenEvents(
    List<AgendaEvent> events,
  );
}
```

### 2.2 统一写入流程与去重规则
1. **去重检查**：优先按 `AgendaEvent.id` 去重；若 ID 不同但核心三要素（`title`、`startTime`、`location` 且时间偏差在 60 秒内）一致，视为相同日程；
2. **系统日历查重**：若本地或系统日历中已存在并已同步，不再重复向 CalendarContract 插入新事件，仅更新本地属性；
3. **状态回填**：日历写入成功后回填 `syncedToSystemCalendar = true` 及 `systemCalendarEventId`；
4. **持久化保障**：同步写入 `AgendaRepository`，触发 `eventsNotifier` 通知 UI 刷新；
5. **细粒度返回**：通过 `AgendaWriteResult`（包含 `eventId`、`success`、`message`、`persisted`、`systemCalendarEventId`）反馈每条事件的精确结果。

---

## 3. 悬浮窗控制与同步服务：`FloatingOverlayService`

Flutter 侧封装与 Android 原生 FloatingBubbleService 交互的高级业务服务。

### 3.1 核心接口契约
- `ValueNotifier<bool> isRunningNotifier`：悬浮窗运行状态监听；
- `ValueNotifier<bool> isAccessibilityEnabledNotifier`：无障碍服务激活监听；
- `Future<Map<String, dynamic>> toggleFloatingWindow(bool enable)`：启闭悬浮窗；
- `Future<void> openAccessibilitySettings()`：跳转系统无障碍设置；
- `Future<AgendaBatchWriteResult> handleOverlayWrittenEvents(List<AgendaEvent> events)`：接管悬浮窗传回的日程。

---

## 4. Android 原生端悬浮窗架构规范

原生悬浮窗（`com.anno2agenda.anno2agenda.floating`）遵循单一职责拆分架构：

1. **`FloatingBubbleService`**：
   - 仅负责 Service 生命周期管理；
   - 实例化与调度各下层组件；
   - 不承载 UI、AI 与日历具体细节。
2. **`FloatingWindowController`**：
   - 管理 WindowManager 图层；
   - 调度折叠/展开、贴边吸附及焦点控制（展开时移除 `FLAG_NOT_FOCUSABLE` 以支持键盘输入）；
   - 截屏前临时隐身，避免悬浮窗遮挡底层应用；
   - 销毁时移除 View 防止 `WindowLeaked`。
3. **`FloatingBubbleView`**：
   - 折叠态胶囊 UI 与闲置呼吸半透明控制；
   - 拖拽与点击手势检测并通过回调通知控制器。
4. **`FloatingPanelView`**：
   - 展开态操作卡片 UI（采集快捷键、输入框、状态、日程列表卡片、写入按钮）；
   - 通过回调对外分发用户交互；
   - 权限缺失时弹出友好引导横幅。
5. **`FloatingCaptureCoordinator`**：
   - 统一管理四大采集通道：无障碍直接读屏、Android 11+ 静默截屏 OCR、剪贴板读取、手动微调；
   - 输出统一的 `FloatingCaptureResult`。
6. **`FloatingAiGateway`**：
   - 封装与 Flutter AI 引擎的 MethodChannel 通信；
   - 处理引擎未就绪与超时熔断；
   - 内置高校通知原生时空启发式正则兜底引擎；
   - 向 Flutter 发送日程同步通知与状态广播。
7. **`FloatingCalendarGateway`**：
   - 检查系统日历权限；
   - 底层系统日历查重与写入；
   - 离线持久化：即使 Flutter 未打开，直接合并落盘至应用沙盒 `agenda_events.json`；
   - 返回 `FloatingBatchWriteResult`。

---

## 5. AI 推理调度层：`AIExtractorService`

负责多模式推理路由调度（纯端侧规则引擎、端侧 llama.cpp、Ollama 本地服务、局域网算力节点）与降级保护。

### 5.1 推理模式枚举：`AIEngineMode`
- `hybridAuto`：**混合自动（推荐默认）**。优先调用端侧或局域网大模型，若未就绪或超时，毫秒级降级至内置规则引擎。
- `builtInRuleEngine`：**纯端侧极速规则**。0 内存开销、0 毫秒冷启动，使用启发式时空正则匹配。
- `localLlmServer`：**强制大模型**。仅使用大模型推理，若失败则抛出明确错误。

---

## 6. 端侧大模型生命周期管理：`LocalModelManager`

管理端侧 GGUF 模型的下载、国内 ModelScope 镜像、内存常驻、空闲自动卸载与 Think 思考模式。
