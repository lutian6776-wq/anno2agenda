# UI 组件与页面交互契约规范 (Widgets & Pages Contract Specification)

本规范定义了「知程 Anno2Agenda」UI 组件（Widgets）与页面（Pages）之间的解耦原则、参数传递标准及事件冒泡契约，确保界面层高度可测试、易复用，并支持随时替换表现层框架。

---

## 1. 核心设计原则

1. **单向数据流（Unidirectional Data Flow）**：
   - **数据下行（Props In）**：Page 将业务状态（如 `AgendaEvent`、`isExtracting`、`filter`）通过构造函数参数传入 Widget；
   - **事件上行（Events Out）**：Widget 严禁在内部隐式操作网络或文件存储，所有用户意图（如点击入库、删除、重试）必须通过回调函数（`VoidCallback`, `ValueChanged<T>`）向上冒泡至 Page 或 Repository。
2. **状态受控（Controlled Components）**：
   - 避免在组件内部维护私有且不可同步的核心业务状态。如 `AgendaFilterBar` 的当前选中项由外部 Page 传入，确保 URL 路由或全局状态可直接控制视图显示。
3. **响应式与多端尺寸适配**：
   - 采用宽度断点设计：`isCompact = constraints.maxWidth < 760`。
   - 宽屏（桌面/平板横屏）：双栏并排展开（左侧投喂卡 + 右侧草稿预览与终端），左侧常驻 `NavigationRail`；
   - 紧凑屏（手机端）：单栏流式滚动，底部常驻 `NavigationBar`。

---

## 2. 核心组件接口契约 (Widgets)

### 2.1 `AgendaEventCard` (通用日程卡片)
负责渲染单个日程事件。

```dart
class AgendaEventCard extends StatelessWidget {
  final AgendaEvent event;          // [必填] 待展示的日程实体
  final bool isDraft;               // [可选] 是否处于待确认草稿态 (默认 false)
  final VoidCallback? onSyncCalendar; // [可选] 点击「确认写入系统日历」的回调
  final VoidCallback? onDelete;      // [可选] 点击「删除/放弃草稿」的回调
  final VoidCallback? onTap;         // [可选] 卡片整体点击回调 (查看详情/编辑)
}
```
- **视图自适应**：
  - 当 `isDraft == true` 时，边框为浅灰，操作按钮主文案为「确认写入日历」；
  - 当 `event.syncedToSystemCalendar == true` 时，边框变为绿色，状态胶囊显示「已入系统日历」；
  - 自动根据 `event.endTime` 与当前时间对比判定是否属于过期日程（文字灰度衰减）。

---

### 2.2 `AgendaFilterBar` (日程筛选与检索条)
负责提供文本关键字搜索框与分类状态 FilterChip 滚动栏。

```dart
class AgendaFilterBar extends StatefulWidget {
  final AgendaFilterStatus currentFilter;              // [必填] 当前选中的过滤状态
  final ValueChanged<AgendaFilterStatus> onFilterChanged; // [必填] 过滤状态切换回调
  final ValueChanged<String> onSearchChanged;          // [必填] 搜索关键字变动实时回调
  final Map<AgendaFilterStatus, int>? counts;           // [可选] 各分类下的日程数量统计字典
}
```
- **交互规范**：搜索输入框支持一键清空按钮；FilterChip 选中时显示对勾动画与主色强调高亮。

---

### 2.3 `AgendaEmptyState` (空状态占位组件)
用于日程列表为空、搜索无结果或未生成草稿时的引导占位。

```dart
class AgendaEmptyState extends StatelessWidget {
  final IconData icon;       // 图标，默认 Icons.event_available_outlined
  final String title;        // [必填] 主提示文案
  final String? subtitle;    // [可选] 辅助说明文字
  final String? actionLabel; // [可选] 引导动作按钮文案
  final VoidCallback? onAction; // [可选] 点击引导按钮的回调
}
```

---

### 2.4 `InferenceTerminal` (端侧推理打字机实况终端)
负责高亮输出端侧 AI 推理全过程（macOS 三色圆点、耗时、速率、折叠面板与实时 Token 打字机流）。

```dart
class InferenceTerminal extends StatefulWidget {
  final bool isExtracting;       // [必填] 是否正在进行推理 (活跃态闪烁指示)
  final List<String> processLogs; // [必填] 步骤诊断流水线日志行
  final String streamedTokens;   // [必填] 实时累积的打字机流式字符碎片
  final int tokenCount;          // [必填] 当前已生成的 Token 数量
  final double elapsedSeconds;   // [必填] 推理已耗时秒数
}
```
- **滚动体验**：当新 Token 或新步骤到达且处于展开状态时，终端内部自动平滑滚至最底端。

---

### 2.5 顶部状态指示徽章：`EngineStatusBadge` 与 `FloatingStatusBadge`

- **`EngineStatusBadge`**：
  - 输入参数：`EngineIndicatorState state` (stopped / starting / ready)、`String detail`、`AIEngineMode engineMode`、`String? selectedModelName`；
  - 回调参数：`onPreloadModel` (长按直接预热)、`onUnloadModel` (卸载释放内存)、`onNavigateToSettings` (跳转设置页)。
- **`FloatingStatusBadge`**：
  - 输入参数：`bool isRunning`；
  - 回调参数：`onToggle` (点击快捷切换开启/关闭悬浮窗)。

---

## 3. 页面职责与解耦规范 (Pages)

| 页面组件 | 对应业务 Tab | 职责与状态边界 |
| :--- | :---: | :--- |
| **`AIExtractPage`** | `0` (AI 提取) | 纯粹的输入投喂、推理实况终端以及生成的草稿预览列表。仅维护当前未入库的 `draftEvents` 临时内存状态。 |
| **`MyAgendaPage`** | `1` (我的日程) | 纯粹的数据检索与持久化管理。通过 `ValueListenableBuilder` 监听 `AgendaRepository.instance.eventsNotifier`，与投喂逻辑彻底解耦。 |
| **`SettingsPage`** | `2` (设置) | 端侧大模型预热与自动释放时长调节、Android 原生无障碍识屏服务引导、局域网协同 IP 配置及关于软件。 |
| **`HomeWorkbenchPage`** | 全局脚手架 | 整个主应用的控制枢纽。维护顶部栏徽章状态、自适应布局切换（Rail/Bar）、系统级划词与分享意图分发。 |
