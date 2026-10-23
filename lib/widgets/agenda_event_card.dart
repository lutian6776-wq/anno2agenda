import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/agenda_event.dart';

/// 日程事项详情卡片
class AgendaEventCard extends StatelessWidget {
  final AgendaEvent event;
  final bool isDraft;
  final VoidCallback? onSyncCalendar;
  final VoidCallback? onDelete;
  final VoidCallback? onTap;

  const AgendaEventCard({
    super.key,
    required this.event,
    this.isDraft = false,
    this.onSyncCalendar,
    this.onDelete,
    this.onTap,
  });

  static String formatDateTime(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    const wk = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return '${dt.month}月${dt.day}日 (${wk[dt.weekday - 1]}) ${two(dt.hour)}:${two(dt.minute)}';
  }

  static String getSourceLabel(String sourceType) {
    switch (sourceType) {
      case 'process_text':
        return '系统划词';
      case 'share':
        return '系统分享';
      case 'floating':
        return '全局悬浮窗';
      case 'clipboard':
        return '剪贴板识别';
      case 'lan_sync':
      case 'lan_offload':
        return '局域网协同';
      case 'preset':
        return '演示通知';
      case 'ocr_screenshot':
        return '截屏 OCR';
      case 'accessibility_screen':
        return '无障碍读屏';
      default:
        return '手工投喂';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isUpcoming = event.endTime.isAfter(DateTime.now());

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      color: isDraft
          ? (isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC))
          : (isDark ? const Color(0xFF0F172A) : Colors.white),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: isDark
              ? (event.syncedToSystemCalendar
                  ? const Color(0xFF065F46)
                  : const Color(0xFF334155))
              : (isDraft
                  ? const Color(0xFFE2E8F0)
                  : event.syncedToSystemCalendar
                      ? const Color(0xFFBBF7D0)
                      : const Color(0xFFE2E8F0)),
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 顶部标题与状态标签
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Icon(
                          isDraft
                              ? Icons.pending_actions_outlined
                              : event.syncedToSystemCalendar
                                  ? Icons.check_circle
                                  : Icons.schedule,
                          size: 18,
                          color: isDraft
                              ? (isDark
                                  ? const Color(0xFF60A5FA)
                                  : const Color(0xFF2563EB))
                              : event.syncedToSystemCalendar
                                  ? (isDark
                                      ? const Color(0xFF34D399)
                                      : const Color(0xFF16A34A))
                                  : (isDark
                                      ? const Color(0xFF94A3B8)
                                      : const Color(0xFF64748B)),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            event.title,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: isDark
                                  ? Colors.white
                                  : const Color(0xFF0F172A),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 来源或状态 Chip
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: event.syncedToSystemCalendar
                          ? (isDark
                              ? const Color(0xFF064E3B)
                              : const Color(0xFFDCFCE7))
                          : (isDark
                              ? const Color(0xFF1E293B)
                              : const Color(0xFFF1F5F9)),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      event.syncedToSystemCalendar
                          ? '已入系统日历'
                          : getSourceLabel(event.sourceType),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: event.syncedToSystemCalendar
                            ? (isDark
                                ? const Color(0xFF34D399)
                                : const Color(0xFF16A34A))
                            : (isDark
                                ? const Color(0xFF94A3B8)
                                : const Color(0xFF475569)),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // 时间行
              Row(
                children: [
                  Icon(Icons.access_time,
                      size: 14,
                      color: isDark
                          ? const Color(0xFF94A3B8)
                          : const Color(0xFF64748B)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${formatDateTime(event.startTime)} - ${formatDateTime(event.endTime)}',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: isUpcoming
                            ? (isDark
                                ? const Color(0xFFE2E8F0)
                                : const Color(0xFF1E293B))
                            : (isDark
                                ? const Color(0xFF64748B)
                                : const Color(0xFF94A3B8)),
                        fontWeight:
                            isUpcoming ? FontWeight.w500 : FontWeight.normal,
                      ),
                    ),
                  ),
                ],
              ),

              // 地点行
              if (event.location.isNotEmpty) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(Icons.location_on_outlined,
                        size: 14,
                        color: isDark
                            ? const Color(0xFF94A3B8)
                            : const Color(0xFF64748B)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        event.location,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: isDark
                              ? const Color(0xFFCBD5E1)
                              : const Color(0xFF475569),
                        ),
                      ),
                    ),
                  ],
                ),
              ],

              // 备忘清单 (Checklist)
              if (event.checklist.isNotEmpty) ...[
                const SizedBox(height: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF1E293B)
                        : const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isDark
                          ? const Color(0xFF334155)
                          : const Color(0xFFF1F5F9),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.checklist,
                          size: 14,
                          color: isDark
                              ? const Color(0xFF60A5FA)
                              : const Color(0xFF2563EB)),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '备忘清单：${event.checklist.join("、")}',
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark
                                ? const Color(0xFFE2E8F0)
                                : const Color(0xFF334155),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              // 描述详情
              if (event.description.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  event.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark
                        ? const Color(0xFF94A3B8)
                        : Colors.grey.shade600,
                  ),
                ),
              ],

              const SizedBox(height: 10),
              const Divider(height: 1, thickness: 0.5),
              const SizedBox(height: 6),

              // 底部动作栏
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // 提前提醒时间
                  Text(
                    '提前 ${event.reminderMinutes} 分钟提醒',
                    style: TextStyle(
                      fontSize: 11,
                      color: isDark
                          ? const Color(0xFF64748B)
                          : Colors.grey.shade500,
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 导出 .ics 日历文件内容到剪贴板
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.copy_all, size: 16),
                        tooltip: '复制 iCalendar (.ics) 代码',
                        onPressed: () {
                          Clipboard.setData(
                              ClipboardData(text: event.toIcsString()));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('已复制 iCalendar (.ics) 日历内容至剪贴板'),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        },
                      ),
                      if (onDelete != null)
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.delete_outline,
                              size: 16, color: Colors.grey),
                          tooltip: isDraft ? '放弃此草稿' : '删除日程',
                          onPressed: onDelete,
                        ),
                      if (onSyncCalendar != null) ...[
                        const SizedBox(width: 4),
                        FilledButton.tonalIcon(
                          style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 0),
                            textStyle: const TextStyle(fontSize: 12),
                          ),
                          onPressed: onSyncCalendar,
                          icon: Icon(
                            event.syncedToSystemCalendar
                                ? Icons.done
                                : Icons.calendar_today,
                            size: 14,
                          ),
                          label: Text(
                            event.syncedToSystemCalendar
                                ? '重新同步日历'
                                : (isDraft ? '确认写入日历' : '写入系统日历'),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
