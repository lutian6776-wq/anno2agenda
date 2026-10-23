# 数据模型契约规范 (Models Contract Specification)

本文档定义了「知程 Anno2Agenda」核心实体与数据传输对象（DTO）的数据契约，规范各字段类型、校验规则、JSON 序列化标准及 RFC 5545 iCalendar 标准。

---

## 1. 核心日程实体：`AgendaEvent`

### 1.1 字段定义契约

| 字段名称 | 类型 | 必填 | 默认值 | 语义与约束说明 |
| :--- | :--- | :---: | :--- | :--- |
| `id` | `String` | 是 | 纳秒时间戳 | 全局唯一标识符（UUID 或纳秒级数字串）。多端合并时作为去重主键。 |
| `title` | `String` | 是 | `'未命名日程'` | 日程摘要/标题。限制在 1~100 字符内，不得包含未转义换行。 |
| `startTime` | `DateTime` | 是 | - | 事件开始时间。必须精确到分钟，且必须早于或等于 `endTime`。 |
| `endTime` | `DateTime` | 是 | - | 事件结束时间。若原文未提及结束时间，默认推断为 `startTime` 起算 1 小时。 |
| `location` | `String` | 否 | `''` | 地点信息（如教室、会议室、腾讯会议号、飞书链接）。 |
| `description`| `String` | 否 | `''` | 补充描述、核心注意事项或背景说明。 |
| `sourceText` | `String` | 是 | `''` | 被提取的原通知文本原文，用于可信度溯源与复核。 |
| `sourceType` | `String` | 否 | `'manual'` | 提取渠道标识：`manual` (手动)、`process_text` (划词)、`share` (分享)、`floating` (悬浮窗)、`clipboard` (剪贴板)、`preset` (示例)、`lan_sync` (局域网)、`ocr_screenshot` (截屏)、`accessibility_screen` (读屏)。 |
| `reminderMinutes` | `int` | 否 | `30` | 提前提醒分钟数（如 15、30、60、1440）。写入系统日历时映射为 VALARM 触发器。 |
| `checklist` | `List<String>`| 否 | `[]` | 待办清单事项（如准考证、报告册、U盘）。 |
| `confidence` | `double` | 否 | `0.9` | 提取置信度评分（0.0 ~ 1.0）。 |
| `syncedToSystemCalendar` | `bool` | 否 | `false` | 是否已成功写入操作系统自带的日历 Provider。 |
| `deviceOrigin` | `String` | 否 | `'local'` | 初始生成此日程的平台标识（如 `android`, `windows`, `local`）。 |

### 1.2 JSON 序列化协议

```json
{
  "id": "1697523120000",
  "title": "操作系统期中机试",
  "startTime": "2026-10-28T19:00:00.000",
  "endTime": "2026-10-28T21:00:00.000",
  "location": "科技楼101",
  "description": "请携带学生证提前10分钟入场",
  "sourceText": "下周二晚上7点在科技楼101进行期中机试测验，请携带学生证提前10分钟入场。",
  "sourceType": "process_text",
  "reminderMinutes": 30,
  "checklist": [
    "学生证",
    "草稿纸"
  ],
  "confidence": 0.95,
  "syncedToSystemCalendar": false,
  "deviceOrigin": "android"
}
```

- **兼容性原则**：反序列化时（`fromJson`），所有非基本数值与日期必须使用安全转换函数（如 `DateTime.tryParse` 与 `int.tryParse`），缺省时必须自动回退至默认值，禁止直接强转导致运行时崩溃。

### 1.3 RFC 5545 iCalendar (`.ics`) 导出契约

通过 `AgendaEvent.toIcsString()` 生成标准日历文本：
- **`DTSTAMP` / `DTSTART` / `DTEND`**：必须采用 UTC 格式：`YYYYMMDDTHHMMSSZ`。
- **`UID`**：格式固定为 `${id}@anno2agenda.local`。
- **`VALARM` 规范**：
  ```text
  BEGIN:VALARM
  TRIGGER:-PT${reminderMinutes}M
  ACTION:DISPLAY
  DESCRIPTION:Reminder
  END:VALARM
  ```
- **特殊字符转义**：逗号、分号及换行符必须安全转义为 `\,`, `\;`, `\n`。

---

## 2. 推理结果载荷：`ExtractionResult`

定义于 `services/ai_extractor_service.dart`，作为 AI 提取引擎完成推理后的标准交付实体：

```dart
class ExtractionResult {
  final List<AgendaEvent> events; // 解析出的日程事件集合
  final String engineUsed;        // 实际生效的引擎描述（如 '端侧量化模型 (qwen2.5:1.5b)'）
  final int elapsedMs;            // 端到端总推理耗时（毫秒）
  final double confidence;        // 综合置信度

  ExtractionResult({
    required this.events,
    required this.engineUsed,
    required this.elapsedMs,
    this.confidence = 0.9,
  });
}
```

---

## 3. 端侧模型元数据：`ModelSpec` 与 `ModelDownloadProgress`

定义于 `services/local_model_manager.dart`：

### 3.1 `ModelSpec` 规格定义
```dart
class ModelSpec {
  final String id;              // 模型唯一代号（如 'qwen2.5-1.5b-instruct-q4'）
  final String name;            // 用户友好显示名称（如 'Qwen2.5 1.5B (轻量高智商推荐)'）
  final String fileName;        // 本地落地 GGUF 文件名
  final String downloadUrl;     // 官方托管直链（国内 ModelScope 高速 CDN）
  final double expectedSizeMB;  // 预计占用磁盘大小（MB）
  final String description;     // 规格说明与硬件需求提示
  final String tag;             // 分类标签（如 '推荐 / 约1.1GB / 适合所有机型'）
}
```

### 3.2 `ModelDownloadProgress` 进度载荷
```dart
class ModelDownloadProgress {
  final String modelId;         // 当前正在下载的模型 ID
  final int receivedBytes;      // 已接收字节数
  final int totalBytes;         // 总文件字节数
  final double progress;        // 归一化进度 (0.0 ~ 1.0)
  final double speedMBps;       // 当前实时下载速率 (MB/s)
  final bool isCompleted;       // 是否已校验完成
  final String? error;          // 失败原因或断点恢复提示
}
```

---

## 4. 原生采集传输载荷：`IncomingCapturePayload`

定义于 `services/platform_bridge.dart`，当 Android 系统通知、划词直达、分享面板或全局悬浮窗截获文本时，通过原生通道传入 Flutter 层：

```dart
class IncomingCapturePayload {
  final String text;        // 捕获的文本内容
  final String sourceType;  // 触发源类型 ('process_text', 'share', 'floating', 'ocr_screenshot')
  IncomingCapturePayload({required this.text, required this.sourceType});
}
```
