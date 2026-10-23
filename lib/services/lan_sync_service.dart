import 'dart:convert';
import 'dart:io';
import '../models/agenda_event.dart';
import 'ai_extractor_service.dart';

class LanSyncService {
  static HttpServer? _server;
  static const int defaultPort = 9527;

  /// 获取本机局域网 IPv4 地址列表（自动过滤代理虚拟网卡并优先展示真实局域网 IP）
  static Future<List<String>> getLocalIps() async {
    final ips = <String>[];
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (!addr.isLoopback &&
              !ip.startsWith('198.18.') &&
              !ip.startsWith('169.254.')) {
            ips.add(ip);
          }
        }
      }
      ips.sort((a, b) {
        final aIsLan = a.startsWith('192.168.');
        final bIsLan = b.startsWith('192.168.');
        if (aIsLan && !bIsLan) return -1;
        if (!aIsLan && bIsLan) return 1;
        return a.compareTo(b);
      });
    } catch (_) {}
    return ips;
  }

  /// 启动局域网双向同步与桌面端 AI 算力共享服务
  static Future<bool> startServer({
    required List<AgendaEvent> Function() getLocalEvents,
    required void Function(List<AgendaEvent> mergedEvents) onRemoteEventsMerged,
  }) async {
    if (_server != null) return true;
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, defaultPort);
      _server!.listen((HttpRequest req) async {
        req.response.headers.contentType = ContentType.json;
        req.response.headers.add('Access-Control-Allow-Origin', '*');

        try {
          if (req.method == 'GET' && req.uri.path == '/ping') {
            req.response.write(jsonEncode({
              'status': 'ok',
              'platform': Platform.operatingSystem,
              'count': getLocalEvents().length,
            }));
          } else if (req.method == 'GET' && req.uri.path == '/sync') {
            req.response.write(AgendaEvent.encodeList(getLocalEvents()));
          } else if (req.method == 'POST' && req.uri.path == '/sync') {
            final body = await utf8.decoder.bind(req).join();
            final incoming = AgendaEvent.decodeList(body);
            final merged = _mergeEvents(getLocalEvents(), incoming);
            onRemoteEventsMerged(merged);
            req.response.write(AgendaEvent.encodeList(merged));
          } else if (req.method == 'POST' && req.uri.path == '/extract') {
            // 桌面端算力反哺移动端接口：手机发来长文本，电脑执行推理并返回日程 JSON
            final body = await utf8.decoder.bind(req).join();
            final map = jsonDecode(body) as Map<String, dynamic>;
            final text = map['text']?.toString() ?? '';
            final sourceType = map['sourceType']?.toString() ?? 'lan_offload';
            final res = await AIExtractorService.extractFromText(
              rawText: text,
              sourceType: sourceType,
            );
            req.response.write(jsonEncode({
              'engineUsed': 'Windows 桌面算力节点 (${res.engineUsed})',
              'events': res.events.map((e) => e.toJson()).toList(),
            }));
          } else {
            req.response.statusCode = HttpStatus.notFound;
            req.response.write(jsonEncode({'error': 'Not Found'}));
          }
        } catch (e) {
          req.response.statusCode = HttpStatus.internalServerError;
          req.response.write(jsonEncode({'error': e.toString()}));
        } finally {
          await req.response.close();
        }
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 与对端设备（如手机连电脑，或电脑连手机）一键双向合并日程
  static Future<List<AgendaEvent>> syncWithPeer({
    required String peerIp,
    required List<AgendaEvent> localEvents,
    int port = defaultPort,
  }) async {
    final client = HttpClient()
      ..findProxy = ((_) => 'DIRECT')
      ..connectionTimeout = const Duration(seconds: 3);
    try {
      final uri = Uri.parse('http://${peerIp.trim()}:$port/sync');
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(AgendaEvent.encodeList(localEvents)));
      final resp = await req.close().timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) {
        throw Exception('对端返回状态码 ${resp.statusCode}');
      }
      final respBody = await resp.transform(utf8.decoder).join();
      return AgendaEvent.decodeList(respBody);
    } finally {
      client.close();
    }
  }

  /// 按 ID 去重合并双端日程（CRDT 简化版状态合并）
  static List<AgendaEvent> _mergeEvents(
    List<AgendaEvent> local,
    List<AgendaEvent> remote,
  ) {
    final map = <String, AgendaEvent>{};
    for (final e in local) {
      map[e.id] = e;
    }
    for (final r in remote) {
      final existing = map[r.id];
      if (existing == null) {
        map[r.id] = r;
      } else if (r.syncedToSystemCalendar && !existing.syncedToSystemCalendar) {
        existing.syncedToSystemCalendar = true;
      }
    }
    final merged = map.values.toList()
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
    return merged;
  }
}
