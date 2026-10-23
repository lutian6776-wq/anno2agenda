# 仓储层接口契约规范 (Repositories Contract Specification)

仓储层（Repository Layer）作为「知程 Anno2Agenda」的**单一真实数据源（Single Source of Truth, SSOT）**，负责隔离上层 UI 与底层持久化存储，封装事件持久化、响应式订阅广播、状态过滤与多端冲突合并逻辑。

---

## 1. 核心接口定义：`IAgendaRepository`

任何持久化实现（内存、JSON 文件、SQLite、Hive、WebDAV 等）均须遵循以下抽象契约：

```dart
abstract class IAgendaRepository {
  /// 获取当前所有已入库日程的只读副本（按 startTime 升序排列）
  List<AgendaEvent> get allEvents;

  /// 响应式通知监听器：当日程列表发生新增、删除、更新或同步状态变化时触发
  ValueListenable<List<AgendaEvent>> get eventsNotifier;

  /// 初始化仓储：从磁盘持久化层载入历史日程数据
  Future<void> init();

  /// 添加单个日程（若 id 已存在则覆盖更新，保持幂等性）
  Future<void> addEvent(AgendaEvent event);

  /// 批量添加日程
  Future<void> addEvents(List<AgendaEvent> events);

  /// 根据唯一 ID 删除日程
  Future<void> removeEvent(String id);

  /// 清空所有已入库日程
  Future<void> clearAll();

  /// 更新指定日程的内容
  Future<void> updateEvent(AgendaEvent event);

  /// 标记指定日程为已同步至系统日历
  Future<void> markAsSynced(String id);

  /// 合并来自局域网对端设备的远程日程列表
  Future<List<AgendaEvent>> mergeRemoteEvents(List<AgendaEvent> remote);

  /// 条件检索与状态过滤
  List<AgendaEvent> filter({
    String query = '',
    AgendaFilterStatus status = AgendaFilterStatus.all,
  });

  /// 导出所有日程为符合 RFC 5545 标准的单一 .ics 文件字符串
  String exportAllToIcs();
}
```

---

## 2. 状态过滤枚举：`AgendaFilterStatus`

用于过滤工具条（`AgendaFilterBar`）与仓储层检索方法：

| 枚举项 | 含义 | 过滤判定逻辑 |
| :--- | :--- | :--- |
| `all` | 全部日程 | 无状态过滤，匹配全部条目 |
| `upcoming` | 未来待办 | `event.endTime.isAfter(DateTime.now())` |
| `past` | 历史过期 | `event.endTime.isBefore(DateTime.now())` |
| `synced` | 已同步至系统日历 | `event.syncedToSystemCalendar == true` |
| `unsynced` | 未写入系统日历 | `event.syncedToSystemCalendar == false` |

### 搜索关键字检索规则：
`filter(query: '...')` 对输入文本执行不区分大小写的模糊搜索，在以下任意维度命中即视作匹配：
1. `event.title.contains(query)`
2. `event.location.contains(query)`
3. `event.description.contains(query)`
4. `event.checklist.any((item) => item.contains(query))`

---

## 3. 多端局域网同步冲突合并规范：`mergeRemoteEvents`

双端设备（如 Android 手机与 Windows PC）进行局域网双向同步时，执行以下确定性合并算法：
1. **主键去重**：以 `event.id` 作为映射 Map 的主键；
2. **状态吸收**：若本地已存在相同 ID，且远程条目的 `syncedToSystemCalendar == true`，则将本地该事件的同步状态更新为 `true`；
3. **增量汇入**：若本地不存在该 ID，将远端条目完整吸收；
4. **重新排序**：合并完毕后按 `startTime` 重新升序排列并触发持久化落盘；
5. **事件广播**：通过 `eventsNotifier.value` 广播最新只读列表，驱动全应用所有监听界面响应式刷新。

---

## 4. 持久化落盘与容灾规范

1. **落盘触发时机**：每次调用 `addEvent`、`addEvents`、`removeEvent`、`clearAll`、`updateEvent`、`markAsSynced` 及 `mergeRemoteEvents` 成功修改内存状态后，必须触发持久化。
2. **原子化与异常保护**：磁盘 I/O 必须在 `try-catch` 保护下执行，即使出现磁盘无写入权限、存储空间不足等故障，必须打印可观测的诊断日志，严禁将异常抛至 UI 主线程导致界面闪退。
3. **数据完整性**：写入格式采用 JSON Array 编码（`AgendaEvent.encodeList`），启动时若检测到文件不存在或为空，自动初始化为空列表。
