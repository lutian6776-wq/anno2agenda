# 局域网协同与算力反哺协议规范 (LAN Protocol Specification)

本协议定义了「知程 Anno2Agenda」多端（如 Android 手机与 Windows PC）在同一 Wi-Fi 或热点局域网内的通信协议，涵盖设备探活、双向日程数据同步以及**桌面端算力反哺移动端（LAN Compute Offload）**规范。

---

## 1. 网络与端口规范

- **默认监听端口**：`9527`（支持通过 `LanSyncService.defaultPort` 统一配置）。
- **传输协议**：HTTP/1.1 RESTful JSON API。
- **CORS 跨域支持**：响应头强制包含 `Access-Control-Allow-Origin: *`。
- **IPv4 智能过滤与排序**：
  - 自动过滤 `127.0.0.1` 环回地址；
  - 自动过滤 Clash/VPN 常见虚拟网卡网段（如 `198.18.x.x`）及链路本地地址（`169.254.x.x`）；
  - 优先排序展示标准的家庭/校园网内网段（`192.168.x.x` 与 `10.x.x.x`）。

---

## 2. API 端点契约

### 2.1 设备探活与握手：`GET /ping`
用于快速检测对端节点是否在线，以及获取对端操作环境信息。

- **请求方式**：`GET`
- **请求路径**：`/ping`
- **响应示例**：
  ```json
  {
    "status": "ok",
    "platform": "windows",
    "count": 12
  }
  ```

---

### 2.2 拉取全量日程：`GET /sync`
用于从对端设备获取当前存储的所有日程数据。

- **请求方式**：`GET`
- **请求路径**：`/sync`
- **响应示例**：`AgendaEvent` JSON 数组
  ```json
  [
    {
      "id": "1697523120000",
      "title": "操作系统期中机试",
      "startTime": "2026-10-28T19:00:00.000",
      "endTime": "2026-10-28T21:00:00.000",
      "location": "科技楼101",
      "description": "请携带学生证",
      "sourceText": "下周二晚上7点...",
      "sourceType": "process_text",
      "reminderMinutes": 30,
      "checklist": ["学生证"],
      "confidence": 0.95,
      "syncedToSystemCalendar": true,
      "deviceOrigin": "android"
    }
  ]
  ```

---

### 2.3 双向合并同步：`POST /sync`
双端对等同步核心接口。调用方将本机日程列表通过 POST 提交至对端，对端执行增量吸收后，返回合并后的全量数据。

- **请求方式**：`POST`
- **请求路径**：`/sync`
- **请求体（Body）**：调用方当前的全量 `AgendaEvent` JSON 数组字符串。
- **处理契约**：
  1. 服务端反序列化请求体中的日程集合；
  2. 服务端调用 `_mergeEvents(localEvents, incomingEvents)` 进行无损合并；
  3. 服务端触发 `onRemoteEventsMerged` 回调持久化到磁盘；
  4. 响应体回传合并后的完整日程 JSON 数组，调用方更新自身数据库。
- **响应格式**：合并后的 `AgendaEvent` JSON 数组。

---

### 2.4 移动端算力反哺接口：`POST /extract`
针对部分低配手机无法流畅运行 2B/7B 大模型的场景，手机可在局域网内将待提取文本发送给同一局域网的 Windows PC 节点，由电脑端显卡执行推理后将日程 JSON 返还给手机。

- **请求方式**：`POST`
- **请求路径**：`/extract`
- **请求体（Body）**：
  ```json
  {
    "text": "【AI与开源创新大赛】各位队长请注意：明天下午14:30在综合楼302报告厅举行宣讲会...",
    "sourceType": "lan_offload"
  }
  ```
- **服务端处理流程**：
  1. PC 端接收请求后调用本机的 `AIExtractorService.extractFromText(rawText: text)`；
  2. 本地 llama.cpp GPU 节点执行推理并提取出多个事件；
  3. 包装响应并回传。
- **响应示例**：
  ```json
  {
    "engineUsed": "Windows 桌面算力节点 (端侧量化模型 (qwen2.5:1.5b))",
    "events": [
      {
        "id": "1697523190000",
        "title": "赛题宣讲会",
        "startTime": "2026-10-24T14:30:00.000",
        "endTime": "2026-10-24T15:30:00.000",
        "location": "综合楼302报告厅",
        "description": "请携带学生证签到",
        "sourceText": "明天下午14:30在综合楼302报告厅举行宣讲会...",
        "sourceType": "lan_offload",
        "reminderMinutes": 30,
        "checklist": ["学生证"],
        "confidence": 0.96,
        "syncedToSystemCalendar": false,
        "deviceOrigin": "windows"
      }
    ]
  }
  ```

---

## 3. 容错与状态码规范

| HTTP 状态码 | 含义 | 触发场景 |
| :--- | :--- | :--- |
| `200 OK` | 成功 | 请求正常处理并返回合法 JSON。 |
| `400 Bad Request` | 请求格式错误 | JSON 解析异常或缺少必须字段。 |
| `404 Not Found` | 未知路由 | 请求了除 `/ping`、`/sync`、`/extract` 之外的路径。 |
| `500 Internal Error` | 服务端执行异常 | 本地推理失败或 I/O 异常，响应体包含 `{"error": "详细描述"}`。 |
