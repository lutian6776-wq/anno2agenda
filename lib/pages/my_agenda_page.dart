import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/agenda_event.dart';
import '../repositories/agenda_repository.dart';
import '../services/agenda_write_service.dart';
import '../services/app_settings_service.dart';
import '../services/calendar_sync_service.dart';
import '../services/chinese_calendar_helper.dart';
import '../theme/app_theme.dart';
import '../widgets/agenda_empty_state.dart';
import '../widgets/agenda_event_card.dart';
import '../widgets/agenda_filter_bar.dart';

/// 时间跨度视图模式
enum AgendaViewSpan {
  month, // 月视图（经典全月大日历网格）
  week, // 周视图（紧凑 7 天周日程滑轨）
  day, // 日视图（聚焦单日小时刻度轴）
  all, // 全部日程（纵向流式检索列表）
}

/// 「我的日程」核心日历与时间轴管理页面
class MyAgendaPage extends StatefulWidget {
  final VoidCallback? onNavigateToExtractor;

  const MyAgendaPage({
    super.key,
    this.onNavigateToExtractor,
  });

  @override
  State<MyAgendaPage> createState() => _MyAgendaPageState();
}

class _MyAgendaPageState extends State<MyAgendaPage> {
  final AgendaRepository _repo = AgendaRepository.instance;

  // 核心时间与视图状态
  late DateTime _selectedDate;
  late DateTime _displayedMonth;
  AgendaViewSpan _viewSpan = AgendaViewSpan.month;

  // 跨度与显示筛选偏好（通过跨度弹出复选框控制）
  bool _showHolidays = true; // 显示法定节假日与调休（休/班）
  bool _showLunar = true; // 显示农历节气与传统节日
  bool _onlyUpcoming = false; // 仅显示未过期的日程
  bool _onlySynced = false; // 仅显示已同步至系统日历的日程

  // 全量列表搜索与筛选状态
  AgendaFilterStatus _listFilter = AgendaFilterStatus.all;
  String _searchQuery = '';
  bool _isSearchExpanded = false;
  final TextEditingController _searchController = TextEditingController();

  // 桌面端专属：可鼠标拖动调节的分栏比例与悬浮/拖拽状态
  static double? _persistedDesktopSplitRatio;
  double? _desktopSplitRatio;
  bool _isHoveringSplitter = false;
  bool _isDraggingSplitter = false;

  // 跨度选择按钮锚点 Key（供桌面端在点击处展开浮动 Popup 窗）
  final GlobalKey _spanButtonKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _selectedDate = DateTime(now.year, now.month, now.day);
    _displayedMonth = DateTime(now.year, now.month, 1);
    _desktopSplitRatio = _persistedDesktopSplitRatio;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(milliseconds: 2400),
      ),
    );
  }

  // ================= 业务动作方法 =================

  Future<void> _writeToCalendar(AgendaEvent event) async {
    try {
      final res = await AgendaWriteService.instance.writeEvent(
        event,
        writeToSystemCalendar: true,
      );
      if (res.success) {
        _showSnack('✅ ${res.message}');
      } else {
        _showSnack('⚠️ ${res.message}');
      }
    } catch (e) {
      _showSnack('⚠️ 写入系统日历失败: $e');
    }
  }

  Future<void> _confirmDelete(AgendaEvent event) async {
    final hasSystemCal = event.syncedToSystemCalendar &&
        event.systemCalendarEventId != null &&
        event.systemCalendarEventId!.isNotEmpty;
    bool deleteFromSystem = hasSystemCal &&
        AppSettingsService.instance.syncDeleteFromSystemCalendar;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlgState) {
          final appColors = context.appColors;
          return AlertDialog(
            backgroundColor: appColors.surfaceModal,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Row(
              children: [
                Icon(Icons.delete_outline,
                    color: context.colorScheme.error, size: 22),
                const SizedBox(width: 8),
                Text(
                  '删除日程事项',
                  style: TextStyle(
                    color: appColors.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '确定要删除「${event.title}」吗？',
                  style: TextStyle(
                    color: appColors.textSecondary,
                    fontSize: 14.5,
                  ),
                ),
                if (hasSystemCal) ...[
                  const SizedBox(height: 14),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: appColors.surfaceLow,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: appColors.borderSubtle,
                      ),
                    ),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () {
                        setDlgState(() => deleteFromSystem = !deleteFromSystem);
                      },
                      child: Row(
                        children: [
                          Checkbox(
                            value: deleteFromSystem,
                            activeColor: context.colorScheme.primary,
                            onChanged: (v) {
                              setDlgState(() => deleteFromSystem = v ?? true);
                            },
                          ),
                          Expanded(
                            child: Text(
                              '同时从系统日历中删除此日程',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: appColors.textPrimary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(
                  '取消',
                  style: TextStyle(
                    color: appColors.textSecondary,
                  ),
                ),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: context.colorScheme.error,
                  foregroundColor: context.colorScheme.onError,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('确认删除'),
              ),
            ],
          );
        },
      ),
    );

    if (confirmed == true) {
      final delRes = await CalendarSyncService.instance.deleteEventWithSync(
        event,
        deleteFromSystem: deleteFromSystem,
      );
      if (deleteFromSystem && hasSystemCal) {
        _showSnack(delRes.success
            ? '🗑️ 已从知程及系统日历中同步删除：${event.title}'
            : '⚠️ 已从应用删除，但系统日历删除反馈: ${delRes.message}');
      } else {
        _showSnack('🗑️ 已删除本地日程：${event.title}');
      }
    }
  }

  /// 弹出系统日历双向同步管理弹窗
  Future<void> _showCalendarSyncModal() async {
    var span = CalendarTimeSpanOption.threeMonths;
    CalendarSyncResult? localSyncResult =
        CalendarSyncService.instance.lastResult;
    bool isSyncing = false;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.colorScheme.surface.withValues(alpha: 0),
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) {
          final appColors = context.appColors;
          final primaryColor = context.colorScheme.primary;
          final allEvents = _repo.allEvents;
          final syncedCount =
              allEvents.where((e) => e.syncedToSystemCalendar).length;
          final unsyncedCount = allEvents.length - syncedCount;

          return Center(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 580),
              margin: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
              ),
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              decoration: BoxDecoration(
                color: appColors.surfaceModal,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(20)),
                border: Border.all(
                  color: appColors.borderSubtle,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 顶部小把手
                  Center(
                    child: Container(
                      width: 38,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 14),
                      decoration: BoxDecoration(
                        color: appColors.borderSubtle,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),

                  // 标题栏
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: appColors.tagWorkContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          Icons.sync,
                          size: 22,
                          color: appColors.tagWork,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '系统日历双向同步中心',
                              style: TextStyle(
                                fontSize: 16.5,
                                fontWeight: FontWeight.bold,
                                color: appColors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              Platform.isAndroid
                                  ? '原生直连 Android CalendarProvider，支持导入/推送/联动删除'
                                  : '支持与 Windows 本地日历 (.ics) 双向读写与同步清理',
                              style: TextStyle(
                                fontSize: 12,
                                color: appColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 20),
                        color: appColors.textSecondary,
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // 统计卡片
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: appColors.surfaceLow,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: appColors.borderSubtle,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _buildSyncStatItem(
                          label: '本地日程',
                          value: '${allEvents.length}',
                          color: appColors.tagRest,
                        ),
                        _buildSyncStatItem(
                          label: '已同步系统',
                          value: '$syncedCount',
                          color: appColors.tagWork,
                        ),
                        _buildSyncStatItem(
                          label: '未同步待推',
                          value: '$unsyncedCount',
                          color: unsyncedCount > 0
                              ? appColors.tagStudy
                              : appColors.textTertiary,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),

                  // 时间跨度筛选行
                  Row(
                    children: [
                      Text(
                        '同步跨度：',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: appColors.textPrimary,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: CalendarTimeSpanOption.values.map((opt) {
                            final isSelected = span == opt;
                            return ChoiceChip(
                              label: Text(
                                opt.label,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: isSelected
                                      ? context.colorScheme.onPrimary
                                      : appColors.textSecondary,
                                ),
                              ),
                              selected: isSelected,
                              selectedColor: primaryColor,
                              backgroundColor: appColors.surfaceLow,
                              side: BorderSide(
                                color: isSelected
                                    ? primaryColor
                                    : appColors.borderSubtle,
                              ),
                              onSelected: isSyncing
                                  ? null
                                  : (sel) {
                                      if (sel) {
                                        setModalState(() => span = opt);
                                      }
                                    },
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                            );
                          }).toList(),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // 联动删除开关提示
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: appColors.surfaceLow,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.auto_delete_outlined,
                          size: 16,
                          color: primaryColor,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '在知程删除已同步日程时，默认联动删除系统日历对应事件',
                            style: TextStyle(
                              fontSize: 12,
                              color: appColors.textPrimary,
                            ),
                          ),
                        ),
                        Switch(
                          value: AppSettingsService
                              .instance.syncDeleteFromSystemCalendar,
                          activeTrackColor: primaryColor,
                          onChanged: (v) async {
                            await AppSettingsService.instance
                                .setSyncDeleteFromSystemCalendar(v);
                            setModalState(() {});
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // 核心同步操作按钮组
                  if (isSyncing)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: Center(
                        child: Column(
                          children: [
                            const CircularProgressIndicator(strokeWidth: 2.5),
                            const SizedBox(height: 10),
                            Text(
                              '正在执行系统日历双向智能同步与对齐...',
                              style: TextStyle(
                                fontSize: 13,
                                color: primaryColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  else ...[
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: primaryColor,
                        foregroundColor: context.colorScheme.onPrimary,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () async {
                        setModalState(() => isSyncing = true);
                        final res = await CalendarSyncService.instance
                            .performTwoWaySync(
                          options: CalendarSyncOptions(
                            direction: CalendarSyncDirection.twoWay,
                            timeSpan: span,
                            autoDeleteSystemWhenAppDeleted: AppSettingsService
                                .instance.syncDeleteFromSystemCalendar,
                          ),
                        );
                        setModalState(() {
                          isSyncing = false;
                          localSyncResult = res;
                        });
                        _showSnack('🎉 ${res.summary}');
                      },
                      icon: const Icon(Icons.sync, size: 18),
                      label: const Text(
                        '一键双向智能同步 (推拉对齐)',
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: appColors.textPrimary,
                              side: BorderSide(
                                color: appColors.borderSubtle,
                              ),
                              padding:
                                  const EdgeInsets.symmetric(vertical: 10),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            onPressed: () async {
                              setModalState(() => isSyncing = true);
                              final res = await CalendarSyncService.instance
                                  .performTwoWaySync(
                                options: CalendarSyncOptions(
                                  direction: CalendarSyncDirection.pullOnly,
                                  timeSpan: span,
                                ),
                              );
                              setModalState(() {
                                isSyncing = false;
                                localSyncResult = res;
                              });
                              _showSnack('📥 ${res.summary}');
                            },
                            icon: Icon(
                              Icons.download,
                              size: 16,
                              color: appColors.tagWork,
                            ),
                            label: const Text(
                              '从系统日历导入',
                              style: TextStyle(fontSize: 13),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: appColors.textPrimary,
                              side: BorderSide(
                                color: appColors.borderSubtle,
                              ),
                              padding:
                                  const EdgeInsets.symmetric(vertical: 10),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            onPressed: () async {
                              setModalState(() => isSyncing = true);
                              final res = await CalendarSyncService.instance
                                  .performTwoWaySync(
                                options: CalendarSyncOptions(
                                  direction: CalendarSyncDirection.pushOnly,
                                  timeSpan: span,
                                ),
                              );
                              setModalState(() {
                                isSyncing = false;
                                localSyncResult = res;
                              });
                              _showSnack('📤 ${res.summary}');
                            },
                            icon: Icon(
                              Icons.upload,
                              size: 16,
                              color: appColors.tagRest,
                            ),
                            label: const Text(
                              '全部推送到系统',
                              style: TextStyle(fontSize: 13),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],

                  // 同步结果报告卡片
                  if (localSyncResult != null) ...[
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: localSyncResult!.success
                            ? appColors.successContainer
                            : appColors.errorContainer,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: localSyncResult!.success
                              ? appColors.tagWork
                              : context.colorScheme.error,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                localSyncResult!.success
                                    ? Icons.check_circle_outline
                                    : Icons.error_outline,
                                size: 16,
                                color: localSyncResult!.success
                                    ? appColors.tagWork
                                    : context.colorScheme.error,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  localSyncResult!.summary,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.bold,
                                    color: localSyncResult!.success
                                        ? appColors.tagWork
                                        : context.colorScheme.error,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (localSyncResult!.errorLogs.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              localSyncResult!.errorLogs.take(2).join('\n'),
                              style: TextStyle(
                                fontSize: 11,
                                color: context.colorScheme.error,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSyncStatItem({
    required String label,
    required String value,
    required Color color,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: context.appColors.textSecondary,
          ),
        ),
      ],
    );
  }

  Future<void> _confirmClearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.appColors.surfaceModal,
        title: Text(
          '清空全部日程',
          style: TextStyle(
            color: ctx.appColors.textPrimary,
          ),
        ),
        content: Text(
          '此操作将清空本地全部已入库日程，确定继续吗？',
          style: TextStyle(
            color: ctx.appColors.textSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              '取消',
              style: TextStyle(
                color: ctx.appColors.textSecondary,
              ),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: ctx.colorScheme.error,
              foregroundColor: ctx.colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('全部清空'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _repo.clearAll();
      _showSnack('已清空本地时间轴列表');
    }
  }

  void _exportAllIcs() {
    final icsText = _repo.exportAllToIcs();
    Clipboard.setData(ClipboardData(text: icsText));
    _showSnack('🎉 已将全部 ${_repo.allEvents.length} 个日程的 .ics 日历文件内容复制到剪贴板！');
  }

  /// 快速载入预设示范课表（对应截图中的“线性代数A”、“大学生职业生涯规划”等）
  Future<void> _loadSampleSchedules() async {
    final base = _selectedDate;
    final samples = [
      AgendaEvent(
        id: 'sample_linalg_${base.millisecondsSinceEpoch}',
        title: '线性代数A',
        startTime: DateTime(base.year, base.month, base.day, 10, 10),
        endTime: DateTime(base.year, base.month, base.day, 12, 0),
        location: '南校区 南6-A507 季永运',
        description: '高等数学与线性代数第7讲：特征值与二次型求解',
        sourceText: '【教务通知】周三第3-4节在南校区南6-A507进行线性代数A课程，主讲人：季永运教授。',
        sourceType: 'preset',
        reminderMinutes: 30,
        checklist: ['带教材与演算草稿纸', '提交第6周课后作业'],
      ),
      AgendaEvent(
        id: 'sample_career_${base.millisecondsSinceEpoch + 1}',
        title: '大学生职业生涯发展与就业指导(一)',
        startTime: DateTime(base.year, base.month, base.day, 14, 30),
        endTime: DateTime(base.year, base.month, base.day, 16, 30),
        location: '南校区 南9-B301 张瀚睿',
        description: '毕业生就业形势与职业素养规划专题辅导讲座',
        sourceText: '【学生处通知】本周大学生职业生涯发展与就业指导(一)在南校区南9-B301开展，主讲教师：张瀚睿。',
        sourceType: 'preset',
        reminderMinutes: 30,
        checklist: ['提前10分钟刷卡签到', '携带个人简历初稿'],
      ),
      AgendaEvent(
        id: 'sample_os_${base.millisecondsSinceEpoch + 2}',
        title: '操作系统内核实验',
        startTime: DateTime(base.year, base.month, base.day + 4, 9, 0),
        endTime: DateTime(base.year, base.month, base.day + 4, 11, 30),
        location: '计算机楼 B405 实验室',
        description: '进程调度算法与 Linux 模块编译验证',
        sourceText: '【实验安排】操作系统实验在计算机楼B405进行，请自备实验报告册。',
        sourceType: 'preset',
        reminderMinutes: 60,
        checklist: ['U盘备份源码', '完成实验预习报告'],
      ),
      AgendaEvent(
        id: 'sample_seminar_${base.millisecondsSinceEpoch + 3}',
        title: '端侧 AI 模型研讨会',
        startTime: DateTime(base.year, base.month, base.day + 6, 20, 0),
        endTime: DateTime(base.year, base.month, base.day + 6, 21, 30),
        location: '腾讯会议：884-291-003',
        description: 'Anno2Agenda 端侧推理轻量化微调研讨',
        sourceText: '【技术沙龙】端侧AI研讨会于线上举行，腾讯会议：884-291-003。',
        sourceType: 'preset',
        reminderMinutes: 15,
        checklist: ['接入降噪耳机', '调试本地 Ollama/Llama 环境'],
      ),
    ];

    await _repo.addEvents(samples);
    _showSnack('✨ 已载入 ${samples.length} 项标准高校示范课表日程！');
  }

  /// 弹出新建日程对话框
  Future<void> _showAddEventDialog() async {
    final titleCtrl = TextEditingController();
    final locCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    DateTime start = DateTime(
        _selectedDate.year, _selectedDate.month, _selectedDate.day, 10, 0);
    DateTime end = DateTime(
        _selectedDate.year, _selectedDate.month, _selectedDate.day, 11, 30);
    int reminder = 30;
    bool syncSys = Platform.isAndroid;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlgState) {
          final appColors = context.appColors;
          final primaryColor = context.colorScheme.primary;
          return AlertDialog(
            backgroundColor: appColors.surfaceModal,
            title: Text(
              '新建日程安排',
              style: TextStyle(
                color: appColors.textPrimary,
                fontWeight: FontWeight.bold,
              ),
            ),
            content: SingleChildScrollView(
              child: SizedBox(
                width: 360,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: titleCtrl,
                      style: TextStyle(
                        color: appColors.textPrimary,
                      ),
                      decoration: InputDecoration(
                        labelText: '日程标题 *',
                        labelStyle: TextStyle(
                          color: appColors.textSecondary,
                        ),
                        hintText: '如：高等数学讲座、项目开题答辩',
                        hintStyle: TextStyle(
                          color: appColors.textTertiary,
                        ),
                        filled: true,
                        fillColor: appColors.surfaceLow,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(
                            color: appColors.borderSubtle,
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(
                            color: appColors.borderSubtle,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // 时间段选择
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: appColors.textPrimary,
                              side: BorderSide(
                                color: appColors.borderSubtle,
                              ),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 10),
                            ),
                            onPressed: () async {
                              final pickedTime = await showTimePicker(
                                context: context,
                                initialTime: TimeOfDay.fromDateTime(start),
                              );
                              if (pickedTime != null) {
                                setDlgState(() {
                                  start = DateTime(
                                    start.year,
                                    start.month,
                                    start.day,
                                    pickedTime.hour,
                                    pickedTime.minute,
                                  );
                                  if (end.isBefore(start)) {
                                    end = start.add(const Duration(hours: 1));
                                  }
                                });
                              }
                            },
                            icon: Icon(
                              Icons.access_time,
                              size: 16,
                              color: primaryColor,
                            ),
                            label: Text(
                                '开始 ${_two(start.hour)}:${_two(start.minute)}',
                                style: const TextStyle(fontSize: 12)),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: appColors.textPrimary,
                              side: BorderSide(
                                color: appColors.borderSubtle,
                              ),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 10),
                            ),
                            onPressed: () async {
                              final pickedTime = await showTimePicker(
                                context: context,
                                initialTime: TimeOfDay.fromDateTime(end),
                              );
                              if (pickedTime != null) {
                                setDlgState(() {
                                  end = DateTime(
                                    end.year,
                                    end.month,
                                    end.day,
                                    pickedTime.hour,
                                    pickedTime.minute,
                                  );
                                });
                              }
                            },
                            icon: Icon(
                              Icons.timer_outlined,
                              size: 16,
                              color: primaryColor,
                            ),
                            label: Text(
                                '结束 ${_two(end.hour)}:${_two(end.minute)}',
                                style: const TextStyle(fontSize: 12)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: locCtrl,
                      style: TextStyle(
                        color: appColors.textPrimary,
                      ),
                      decoration: InputDecoration(
                        labelText: '地点 / 线上会议号',
                        labelStyle: TextStyle(
                          color: appColors.textSecondary,
                        ),
                        hintText: '如：主楼A203、腾讯会议：884-291',
                        hintStyle: TextStyle(
                          color: appColors.textTertiary,
                        ),
                        filled: true,
                        fillColor: appColors.surfaceLow,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(
                            color: appColors.borderSubtle,
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(
                            color: appColors.borderSubtle,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: descCtrl,
                      maxLines: 2,
                      style: TextStyle(
                        color: appColors.textPrimary,
                      ),
                      decoration: InputDecoration(
                        labelText: '日程备注说明',
                        labelStyle: TextStyle(
                          color: appColors.textSecondary,
                        ),
                        hintText: '添加备忘或重点事项',
                        hintStyle: TextStyle(
                          color: appColors.textTertiary,
                        ),
                        filled: true,
                        fillColor: appColors.surfaceLow,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(
                            color: appColors.borderSubtle,
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(
                            color: appColors.borderSubtle,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // 提前提醒时间
                    Row(
                      children: [
                        Icon(
                          Icons.notifications_outlined,
                          size: 16,
                          color: appColors.textSecondary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '提前提醒：',
                          style: TextStyle(
                            color: appColors.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                        const Spacer(),
                        DropdownButton<int>(
                          value: reminder,
                          dropdownColor: appColors.surfaceModal,
                          style: TextStyle(
                            color: appColors.textPrimary,
                            fontSize: 13,
                          ),
                          underline: const SizedBox(),
                          items: const [
                            DropdownMenuItem(value: 0, child: Text('准时')),
                            DropdownMenuItem(value: 15, child: Text('15分钟前')),
                            DropdownMenuItem(value: 30, child: Text('30分钟前')),
                            DropdownMenuItem(value: 60, child: Text('1小时前')),
                            DropdownMenuItem(value: 120, child: Text('2小时前')),
                          ],
                          onChanged: (val) {
                            if (val != null) setDlgState(() => reminder = val);
                          },
                        ),
                      ],
                    ),
                    if (Platform.isAndroid) ...[
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: syncSys,
                        onChanged: (v) =>
                            setDlgState(() => syncSys = v ?? false),
                        title: Text(
                          '同时写入手机系统日历',
                          style: TextStyle(
                            color: appColors.textPrimary,
                            fontSize: 13,
                          ),
                        ),
                        activeColor: primaryColor,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(
                  '取消',
                  style: TextStyle(
                    color: appColors.textSecondary,
                  ),
                ),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: primaryColor,
                  foregroundColor: context.colorScheme.onPrimary,
                ),
                onPressed: () async {
                  final title = titleCtrl.text.trim();
                  if (title.isEmpty) {
                    _showSnack('请输入日程标题');
                    return;
                  }
                  final newEvent = AgendaEvent(
                    id: 'manual_${DateTime.now().microsecondsSinceEpoch}',
                    title: title,
                    startTime: start,
                    endTime: end,
                    location: locCtrl.text.trim(),
                    description: descCtrl.text.trim(),
                    sourceText: '手工创建日程',
                    sourceType: 'manual',
                    reminderMinutes: reminder,
                  );
                  await _repo.addEvent(newEvent);
                  if (syncSys) {
                    await _writeToCalendar(newEvent);
                  }
                  if (ctx.mounted) Navigator.pop(ctx);
                  _showSnack('✅ 已成功创建日程：$title');
                },
                child: const Text('保存入库'),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 弹出查看日程详情卡片
  void _showEventDetailSheet(AgendaEvent event) {
    showModalBottomSheet(
      context: context,
      backgroundColor: context.appColors.surfaceModal,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 540),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (context, setSheetState) {
          final appColors = context.appColors;
          final primaryColor = context.colorScheme.primary;
          return Padding(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: 16,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 拖动把手
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: appColors.borderSubtle,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // 标题与来源标签
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      margin: const EdgeInsets.only(top: 6, right: 10),
                      decoration: BoxDecoration(
                        color: appColors.tagWork,
                        shape: BoxShape.circle,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        event.title,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: appColors.textPrimary,
                        ),
                      ),
                    ),
                    if (event.syncedToSystemCalendar)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: appColors.tagWorkContainer,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.check,
                              size: 12,
                              color: appColors.tagWork,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '已入系统日历',
                              style: TextStyle(
                                color: appColors.tagWork,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),

                // 时间段
                Row(
                  children: [
                    Icon(Icons.access_time, size: 16, color: primaryColor),
                    const SizedBox(width: 8),
                    Text(
                      '${_formatDate(event.startTime)}  ${_two(event.startTime.hour)}:${_two(event.startTime.minute)} - ${_two(event.endTime.hour)}:${_two(event.endTime.minute)}',
                      style: TextStyle(
                        color: appColors.textSecondary,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),

                // 地点
                if (event.location.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.location_on_outlined,
                        size: 16,
                        color: primaryColor,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          event.location,
                          style: TextStyle(
                            color: appColors.textSecondary,
                            fontSize: 13.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],

                // 说明备注
                if (event.description.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: appColors.surfaceLow,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: appColors.borderSubtle,
                      ),
                    ),
                    child: Text(
                      event.description,
                      style: TextStyle(
                        color: appColors.textSecondary,
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],

                // 备忘打勾清单
                if (event.checklist.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    '待办事项清单：',
                    style: TextStyle(
                      color: appColors.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 6),
                  ...event.checklist.map((item) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          children: [
                            Icon(
                              Icons.check_circle_outline,
                              size: 15,
                              color: appColors.tagWork,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                item,
                                style: TextStyle(
                                  color: appColors.textPrimary,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ],
                        ),
                      )),
                ],

                // 原文提取回溯
                if (event.sourceText.isNotEmpty &&
                    event.sourceType != 'manual') ...[
                  const SizedBox(height: 10),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    collapsedIconColor: appColors.textSecondary,
                    iconColor: primaryColor,
                    title: Text(
                      '提取自原始通知内容',
                      style: TextStyle(
                        color: appColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: appColors.surfaceLow,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: appColors.borderSubtle,
                          ),
                        ),
                        child: Text(
                          event.sourceText,
                          style: TextStyle(
                            color: appColors.textSecondary,
                            fontSize: 12,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],

                const SizedBox(height: 16),
                // 底部动作按钮栏
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: context.colorScheme.error,
                          side: BorderSide(
                            color: context.colorScheme.error
                                .withValues(alpha: 0.5),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _confirmDelete(event);
                        },
                        icon: const Icon(Icons.delete_outline, size: 16),
                        label: const Text('删除日程'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: event.syncedToSystemCalendar
                              ? appColors.tagWork
                              : primaryColor,
                          foregroundColor: context.colorScheme.onPrimary,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _writeToCalendar(event);
                        },
                        icon: Icon(
                          event.syncedToSystemCalendar
                              ? Icons.check
                              : Icons.calendar_month,
                          size: 16,
                        ),
                        label: Text(
                          event.syncedToSystemCalendar
                              ? '再次同步至系统日历'
                              : '写入系统日历',
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ================= 时间跨度弹出选择器（用户核心定制需求） =================

  /// 移动端：通过底部抽屉（BottomSheet）选择时间跨度与偏好设置
  void _showSpanSelectionModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 540),
      backgroundColor: context.appColors.surfaceModal,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) {
          return ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.88,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              child: _buildSpanSelectionForm(
                context: ctx,
                updateState: (fn) {
                  setModalState(fn);
                  setState(fn);
                },
                onClose: () => Navigator.pop(ctx),
                isDesktop: false,
              ),
            ),
          );
        },
      ),
    );
  }

  /// 桌面端：在按钮点击处展开浮动 Popup 窗（非底部 Drawer 抽屉）
  void _showSpanSelectionDesktopPopup(GlobalKey anchorKey) {
    final renderBox =
        anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) {
      _showSpanSelectionModal();
      return;
    }

    final buttonOffset = renderBox.localToGlobal(Offset.zero);
    final buttonSize = renderBox.size;
    final screenSize = MediaQuery.of(context).size;

    const popupWidth = 385.0;
    // 水平对齐：优先与按钮左对齐，超出屏幕右边界时向左对齐
    double left = buttonOffset.dx;
    if (left + popupWidth > screenSize.width - 16) {
      left = (screenSize.width - popupWidth - 16).clamp(16.0, double.infinity);
    }
    if (left < 16) left = 16;

    // 垂直对齐：优先在下方展开，下方空间不足时在上方展开
    final availableBelow =
        screenSize.height - (buttonOffset.dy + buttonSize.height) - 16;
    double top;
    double maxPopupHeight;
    if (availableBelow >= 360 || availableBelow >= buttonOffset.dy) {
      top = buttonOffset.dy + buttonSize.height + 6;
      maxPopupHeight = math.min(540.0, availableBelow);
    } else {
      maxPopupHeight = math.min(540.0, buttonOffset.dy - 16);
      top = (buttonOffset.dy - maxPopupHeight - 6).clamp(16.0, double.infinity);
    }

    showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.06),
      barrierDismissible: true,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setPopupState) {
          final appColors = ctx.appColors;
          return Dialog(
            backgroundColor: Colors.transparent,
            elevation: 0,
            insetPadding: EdgeInsets.zero,
            child: Stack(
              children: [
                Positioned(
                  left: left,
                  top: top,
                  child: Material(
                    elevation: 12,
                    shadowColor: Colors.black.withOpacity(0.18),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                      side: BorderSide(
                        color: appColors.borderSubtle,
                        width: 1,
                      ),
                    ),
                    color: appColors.surfaceModal,
                    clipBehavior: Clip.antiAlias,
                    child: SizedBox(
                      width: popupWidth,
                      height: math.min(520.0, maxPopupHeight),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                        child: _buildSpanSelectionDesktopContent(
                          context: dialogCtx,
                          updateState: (fn) {
                            setPopupState(fn);
                            setState(fn);
                          },
                          onClose: () => Navigator.pop(dialogCtx),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 桌面端浮动 Popup 专属内容视图（固定顶部标题栏 + 滚动选项 + 固定底部确定按钮）
  Widget _buildSpanSelectionDesktopContent({
    required BuildContext context,
    required void Function(void Function()) updateState,
    required VoidCallback onClose,
  }) {
    final appColors = context.appColors;
    final primaryColor = context.colorScheme.primary;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 顶部标题栏（固定且防溢出）
        Row(
          children: [
            Icon(Icons.tune_outlined, size: 16, color: primaryColor),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '选择时间跨度与日历视图',
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.bold,
                  color: appColors.textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            TextButton(
              style: TextButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () {
                updateState(() {
                  _viewSpan = AgendaViewSpan.month;
                  _showHolidays = true;
                  _showLunar = true;
                  _onlyUpcoming = false;
                  _onlySynced = false;
                });
              },
              child: Text(
                '恢复默认',
                style: TextStyle(
                  color: primaryColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: '关闭',
              style: IconButton.styleFrom(
                padding: const EdgeInsets.all(4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              constraints:
                  const BoxConstraints(minWidth: 26, minHeight: 26),
              icon: Icon(Icons.close,
                  size: 16, color: appColors.textSecondary),
              onPressed: onClose,
            ),
          ],
        ),
        Divider(
          color: appColors.borderSubtle,
          height: 10,
        ),

        // 可滚动的选项列表
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '视图与时间跨度模式',
                  style: TextStyle(
                    color: appColors.textSecondary,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),

                _buildSpanRadioTile(
                  title: '月跨度 (月视图)',
                  subtitle: '呈现整月日历网格、农历节气、调休角标与每日排程点',
                  span: AgendaViewSpan.month,
                  icon: Icons.calendar_view_month,
                  current: _viewSpan,
                  onSelected: (s) => updateState(() => _viewSpan = s),
                ),
                _buildSpanRadioTile(
                  title: '周跨度 (周视图)',
                  subtitle: '聚焦当前周 7 天时间轴，释放下方列表展示更多待办',
                  span: AgendaViewSpan.week,
                  icon: Icons.view_week_outlined,
                  current: _viewSpan,
                  onSelected: (s) => updateState(() => _viewSpan = s),
                ),
                _buildSpanRadioTile(
                  title: '日跨度 (单日视图)',
                  subtitle: '聚焦单日详细日程安排、备忘清单与回溯文本',
                  span: AgendaViewSpan.day,
                  icon: Icons.calendar_today_outlined,
                  current: _viewSpan,
                  onSelected: (s) => updateState(() => _viewSpan = s),
                ),
                _buildSpanRadioTile(
                  title: '全部跨度 (列表检索模式)',
                  subtitle: '纵向流式检索全部已入库日程，支持关键词搜索与分类筛选',
                  span: AgendaViewSpan.all,
                  icon: Icons.format_list_bulleted,
                  current: _viewSpan,
                  onSelected: (s) => updateState(() => _viewSpan = s),
                ),

                const SizedBox(height: 8),
                Text(
                  '日历显示偏好与筛选复选框',
                  style: TextStyle(
                    color: appColors.textSecondary,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),

                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _showHolidays,
                  activeColor: primaryColor,
                  title: Text(
                    '显示法定节假日与调休标识 (休 / 班)',
                    style: TextStyle(
                      color: appColors.textPrimary,
                      fontSize: 13,
                    ),
                  ),
                  subtitle: Text(
                    '国务院节假日办公布的放假及周末补班状态',
                    style: TextStyle(
                      color: appColors.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                  onChanged: (v) => updateState(() => _showHolidays = v ?? true),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _showLunar,
                  activeColor: primaryColor,
                  title: Text(
                    '显示中国传统农历与二十四节气',
                    style: TextStyle(
                      color: appColors.textPrimary,
                      fontSize: 13,
                    ),
                  ),
                  subtitle: Text(
                    '农历月日、二十四节气及核心纪念日',
                    style: TextStyle(
                      color: appColors.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                  onChanged: (v) => updateState(() => _showLunar = v ?? true),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _onlyUpcoming,
                  activeColor: primaryColor,
                  title: Text(
                    '仅显示未过期的有效日程',
                    style: TextStyle(
                      color: appColors.textPrimary,
                      fontSize: 13,
                    ),
                  ),
                  onChanged: (v) => updateState(() => _onlyUpcoming = v ?? false),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _onlySynced,
                  activeColor: primaryColor,
                  title: Text(
                    '仅显示已同步至系统日历的日程',
                    style: TextStyle(
                      color: appColors.textPrimary,
                      fontSize: 13,
                    ),
                  ),
                  onChanged: (v) => updateState(() => _onlySynced = v ?? false),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 8),
        // 底部固定确定按钮
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: primaryColor,
              foregroundColor: context.colorScheme.onPrimary,
              padding: const EdgeInsets.symmetric(vertical: 9),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(9),
              ),
            ),
            onPressed: onClose,
            child: const Text('确定应用',
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold)),
          ),
        ),
      ],
    );
  }

  /// 跨度与偏好统一配置表单组件（移动端 BottomSheet 与桌面端 Popup 共用）
  Widget _buildSpanSelectionForm({
    required BuildContext context,
    required void Function(void Function()) updateState,
    required VoidCallback onClose,
    bool isDesktop = false,
  }) {
    final appColors = context.appColors;
    final primaryColor = context.colorScheme.primary;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!isDesktop) ...[
          // 移动端顶部拖动手柄条
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: appColors.borderSubtle,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 14),
        ],

        Row(
          children: [
            Expanded(
              child: Text(
                '选择时间跨度与日历视图',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: appColors.textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              style: TextButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () {
                updateState(() {
                  _viewSpan = AgendaViewSpan.month;
                  _showHolidays = true;
                  _showLunar = true;
                  _onlyUpcoming = false;
                  _onlySynced = false;
                });
              },
              child: Text(
                '恢复默认',
                style: TextStyle(
                  color: primaryColor,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
        Divider(
          color: appColors.borderSubtle,
          height: isDesktop ? 12 : 16,
        ),

        Text(
          '视图与时间跨度模式',
          style: TextStyle(
            color: appColors.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),

        // 单选跨度模式
        _buildSpanRadioTile(
          title: '月跨度 (月视图)',
          subtitle: '呈现整月日历网格、农历节气、调休角标与每日排程点',
          span: AgendaViewSpan.month,
          icon: Icons.calendar_view_month,
          current: _viewSpan,
          onSelected: (s) => updateState(() => _viewSpan = s),
        ),
        _buildSpanRadioTile(
          title: '周跨度 (周视图)',
          subtitle: '聚焦当前周 7 天时间轴，释放下方列表展示更多待办',
          span: AgendaViewSpan.week,
          icon: Icons.view_week_outlined,
          current: _viewSpan,
          onSelected: (s) => updateState(() => _viewSpan = s),
        ),
        _buildSpanRadioTile(
          title: '日跨度 (单日视图)',
          subtitle: '聚焦单日详细日程安排、备忘清单与回溯文本',
          span: AgendaViewSpan.day,
          icon: Icons.calendar_today_outlined,
          current: _viewSpan,
          onSelected: (s) => updateState(() => _viewSpan = s),
        ),
        _buildSpanRadioTile(
          title: '全部跨度 (列表检索模式)',
          subtitle: '纵向流式检索全部已入库日程，支持关键词搜索与分类筛选',
          span: AgendaViewSpan.all,
          icon: Icons.format_list_bulleted,
          current: _viewSpan,
          onSelected: (s) => updateState(() => _viewSpan = s),
        ),

        const SizedBox(height: 10),
        Text(
          '日历显示偏好与筛选复选框',
          style: TextStyle(
            color: appColors.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),

        // 复选框偏好
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: _showHolidays,
          activeColor: primaryColor,
          title: Text(
            '显示法定节假日与调休标识 (休 / 班)',
            style: TextStyle(
              color: appColors.textPrimary,
              fontSize: 13,
            ),
          ),
          subtitle: Text(
            '国务院节假日办公布的放假及周末补班状态',
            style: TextStyle(
              color: appColors.textSecondary,
              fontSize: 11,
            ),
          ),
          onChanged: (v) => updateState(() => _showHolidays = v ?? true),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: _showLunar,
          activeColor: primaryColor,
          title: Text(
            '显示中国传统农历与二十四节气',
            style: TextStyle(
              color: appColors.textPrimary,
              fontSize: 13,
            ),
          ),
          subtitle: Text(
            '农历月日、二十四节气及核心纪念日',
            style: TextStyle(
              color: appColors.textSecondary,
              fontSize: 11,
            ),
          ),
          onChanged: (v) => updateState(() => _showLunar = v ?? true),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: _onlyUpcoming,
          activeColor: primaryColor,
          title: Text(
            '仅显示未过期的有效日程',
            style: TextStyle(
              color: appColors.textPrimary,
              fontSize: 13,
            ),
          ),
          onChanged: (v) => updateState(() => _onlyUpcoming = v ?? false),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: _onlySynced,
          activeColor: primaryColor,
          title: Text(
            '仅显示已同步至系统日历的日程',
            style: TextStyle(
              color: appColors.textPrimary,
              fontSize: 13,
            ),
          ),
          onChanged: (v) => updateState(() => _onlySynced = v ?? false),
        ),

        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: primaryColor,
              foregroundColor: context.colorScheme.onPrimary,
              padding: const EdgeInsets.symmetric(vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            onPressed: onClose,
            child: const Text('确定应用',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
          ),
        ),
      ],
    );
  }

  Widget _buildSpanRadioTile({
    required String title,
    required String subtitle,
    required AgendaViewSpan span,
    required IconData icon,
    required AgendaViewSpan current,
    required ValueChanged<AgendaViewSpan> onSelected,
  }) {
    final appColors = context.appColors;
    final primaryColor = context.colorScheme.primary;
    final isSelected = span == current;
    return InkWell(
      onTap: () => onSelected(span),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          children: [
            Icon(
              icon,
              size: 20,
              color: isSelected ? primaryColor : appColors.textSecondary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: isSelected ? primaryColor : appColors.textPrimary,
                      fontSize: 13.5,
                      fontWeight:
                          isSelected ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: appColors.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              isSelected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off,
              color: isSelected ? primaryColor : appColors.textTertiary,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }

  String _getSpanLabel(AgendaViewSpan span) {
    switch (span) {
      case AgendaViewSpan.month:
        return '月视图';
      case AgendaViewSpan.week:
        return '周视图';
      case AgendaViewSpan.day:
        return '日视图';
      case AgendaViewSpan.all:
        return '全部日程';
    }
  }

  // ================= 辅助时间计算 =================

  String _two(int n) => n.toString().padLeft(2, '0');

  String _formatDate(DateTime dt) => '${dt.month}月${dt.day}日';

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  String _getRelativeDaysText(DateTime target, DateTime base) {
    final tOnly = DateTime(target.year, target.month, target.day);
    final bOnly = DateTime(base.year, base.month, base.day);
    final diff = tOnly.difference(bOnly).inDays;

    if (diff == 0) return '今天';
    if (diff == 1) return '明天';
    if (diff == 2) return '后天';
    if (diff == -1) return '昨天';
    if (diff == -2) return '前天';
    if (diff > 0) return '$diff天后';
    return '${-diff}天前';
  }

  void _jumpToToday() {
    final now = DateTime.now();
    setState(() {
      _selectedDate = DateTime(now.year, now.month, now.day);
      _displayedMonth = DateTime(now.year, now.month, 1);
    });
    _showSnack('已跳转至今日 (${now.month}月${now.day}日)');
  }

  void _prevMonth() {
    setState(() {
      _displayedMonth =
          DateTime(_displayedMonth.year, _displayedMonth.month - 1, 1);
    });
  }

  void _nextMonth() {
    setState(() {
      _displayedMonth =
          DateTime(_displayedMonth.year, _displayedMonth.month + 1, 1);
    });
  }

  // ================= 主构建函数 =================

  @override
  Widget build(BuildContext context) {
    final appColors = context.appColors;
    final primaryColor = context.colorScheme.primary;

    return ValueListenableBuilder<List<AgendaEvent>>(
      valueListenable: _repo.eventsNotifier,
      builder: (context, allEvents, _) {
        // 构建日期 -> 日程列表映射
        final eventsMap = <String, List<AgendaEvent>>{};
        for (final ev in allEvents) {
          if (_onlyUpcoming && ev.endTime.isBefore(DateTime.now())) continue;
          if (_onlySynced && !ev.syncedToSystemCalendar) continue;

          final k =
              '${ev.startTime.year}-${ev.startTime.month}-${ev.startTime.day}';
          eventsMap.putIfAbsent(k, () => []).add(ev);
        }

        // 筛选选中日期当天的日程列表
        final selectedKey =
            '${_selectedDate.year}-${_selectedDate.month}-${_selectedDate.day}';
        final selectedDayEvents = eventsMap[selectedKey] ?? [];

        return LayoutBuilder(
          builder: (context, constraints) {
            final isDesktop = constraints.maxWidth >= 640;

            return Container(
              decoration: BoxDecoration(
                color: appColors.surfaceCard,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: appColors.borderSubtle,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 1. 顶部状态栏：月份、相对天数、跨度复选框选择按钮与动作项
                      _buildTopHeader(allEvents, isDesktop: isDesktop),

                      // 2. 搜索条（如展开）
                      if (_isSearchExpanded) _buildSearchBar(),

                      // 3. 核心内容区（桌面端双栏并列无遮挡，移动端单栏流式纵向展示）
                      Expanded(
                        child: _viewSpan == AgendaViewSpan.all
                            ? _buildAllEventsListView(allEvents)
                            : isDesktop
                                ? _buildDesktopLayout(
                                    eventsMap, selectedDayEvents, allEvents,
                                    width: constraints.maxWidth)
                                : _buildMobileCalendarAndTimeline(
                                    eventsMap, selectedDayEvents, allEvents),
                      ),
                    ],
                  ),

                  // 4. 浮动在右下角的经典“今”字圆形按钮（仅在移动窄屏下悬浮展示，桌面端在控制区内集成，彻底避免遮挡）
                  if (!isDesktop && _viewSpan != AgendaViewSpan.all)
                    Positioned(
                      right: 18,
                      bottom: 24,
                      child: FloatingActionButton(
                        heroTag: 'calendar_today_fab',
                        mini: false,
                        backgroundColor: primaryColor,
                        elevation: 4,
                        shape: const CircleBorder(),
                        onPressed: _jumpToToday,
                        child: Text(
                          '今',
                          style: TextStyle(
                            color: context.colorScheme.onPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // ================= 顶部导航与操作工具条 =================

  Widget _buildTopHeader(List<AgendaEvent> allEvents,
      {bool isDesktop = false}) {
    final appColors = context.appColors;
    final primaryColor = context.colorScheme.primary;
    final now = DateTime.now();
    final relativeText = _getRelativeDaysText(_selectedDate, now);
    final monthStr = '${_displayedMonth.month}月';

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 6),
      child: Row(
        children: [
          // 月份与相对天数标签
          Flexible(
            child: InkWell(
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _selectedDate,
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2035),
                );
                if (picked != null) {
                  setState(() {
                    _selectedDate = picked;
                    _displayedMonth = DateTime(picked.year, picked.month, 1);
                  });
                }
              },
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      monthStr,
                      style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w800,
                        color: appColors.textPrimary,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(width: 3),
                    Flexible(
                      child: Text(
                        relativeText,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: appColors.textSecondary,
                        ),
                      ),
                    ),
                    Icon(
                      Icons.arrow_drop_down,
                      size: 16,
                      color: appColors.textSecondary,
                    ),
                  ],
                ),
              ),
            ),
          ),

          if (isDesktop) ...[
            const SizedBox(width: 8),
            // 桌面端专属：直接集成回今天按钮，免除悬浮遮挡
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: appColors.textPrimary,
                side: BorderSide(
                  color: appColors.borderSubtle,
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              ),
              onPressed: _jumpToToday,
              icon: Icon(Icons.today, size: 14, color: primaryColor),
              label: const Text('今天', style: TextStyle(fontSize: 11.5)),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: '系统日历双向同步中心',
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: const EdgeInsets.all(4),
              icon: Icon(Icons.sync, size: 20, color: primaryColor),
              onPressed: _showCalendarSyncModal,
            ),
          ],

          const SizedBox(width: 4),

          // 用户核心需求：通过按钮弹出复选框来选时间跨度（桌面端在点击处展开浮动Popup，移动端弹出BottomSheet）
          InkWell(
            key: _spanButtonKey,
            onTap: () {
              if (isDesktop) {
                _showSpanSelectionDesktopPopup(_spanButtonKey);
              } else {
                _showSpanSelectionModal();
              }
            },
            borderRadius: BorderRadius.circular(18),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: appColors.surfaceLow,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: appColors.borderSubtle,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.tune_outlined, size: 13, color: primaryColor),
                  const SizedBox(width: 4),
                  Text(
                    '跨度: ${_getSpanLabel(_viewSpan)}',
                    style: TextStyle(
                      color: appColors.textPrimary,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Icon(
                    Icons.arrow_drop_down,
                    size: 15,
                    color: appColors.textSecondary,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 2),

          // 新建日程动作（+ 图标，截图对应）
          IconButton(
            tooltip: '新建日程',
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: const EdgeInsets.all(4),
            icon: Icon(
              Icons.add,
              size: 22,
              color: appColors.textPrimary,
            ),
            onPressed: _showAddEventDialog,
          ),

          // 更多菜单（⋮ 图标，截图对应）
          PopupMenuButton<String>(
            tooltip: '更多操作',
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            padding: const EdgeInsets.all(4),
            icon: Icon(
              Icons.more_vert,
              size: 19,
              color: appColors.textPrimary,
            ),
            color: appColors.surfaceModal,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: appColors.borderSubtle,
              ),
            ),
            onSelected: (val) {
              switch (val) {
                case 'calendar_sync':
                  _showCalendarSyncModal();
                  break;
                case 'sample':
                  _loadSampleSchedules();
                  break;
                case 'search':
                  setState(() => _isSearchExpanded = !_isSearchExpanded);
                  break;
                case 'export':
                  _exportAllIcs();
                  break;
                case 'clear':
                  _confirmClearAll();
                  break;
                case 'today':
                  _jumpToToday();
                  break;
              }
            },
            itemBuilder: (ctx) => [
              PopupMenuItem(
                value: 'calendar_sync',
                child: Row(
                  children: [
                    Icon(Icons.sync, size: 16, color: primaryColor),
                    const SizedBox(width: 8),
                    Text(
                      '系统日历双向同步',
                      style: TextStyle(
                        color: appColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'today',
                child: Row(
                  children: [
                    Icon(Icons.today, size: 16, color: primaryColor),
                    const SizedBox(width: 8),
                    Text(
                      '回今天',
                      style: TextStyle(
                        color: appColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'sample',
                child: Row(
                  children: [
                    Icon(
                      Icons.auto_stories_outlined,
                      size: 16,
                      color: primaryColor,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '载入示范课表日程',
                      style: TextStyle(
                        color: appColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'search',
                child: Row(
                  children: [
                    Icon(Icons.search, size: 16, color: primaryColor),
                    const SizedBox(width: 8),
                    Text(
                      '搜索日程',
                      style: TextStyle(
                        color: appColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'export',
                child: Row(
                  children: [
                    Icon(
                      Icons.file_download_outlined,
                      size: 16,
                      color: primaryColor,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '导出全部 ICS 日历',
                      style: TextStyle(
                        color: appColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              const PopupMenuDivider(height: 1),
              PopupMenuItem(
                value: 'clear',
                child: Row(
                  children: [
                    Icon(
                      Icons.delete_outline,
                      size: 16,
                      color: context.colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '清空所有日程',
                      style: TextStyle(color: context.colorScheme.error),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    final appColors = context.appColors;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: appColors.surfaceLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: appColors.borderSubtle,
        ),
      ),
      child: TextField(
        controller: _searchController,
        style: TextStyle(
          color: appColors.textPrimary,
          fontSize: 13.5,
        ),
        decoration: InputDecoration(
          hintText: '搜索日程标题、地点、备忘或原通知...',
          hintStyle: TextStyle(
            color: appColors.textTertiary,
            fontSize: 13,
          ),
          prefixIcon: Icon(
            Icons.search,
            size: 18,
            color: appColors.textSecondary,
          ),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: Icon(
                    Icons.clear,
                    size: 16,
                    color: appColors.textSecondary,
                  ),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
                )
              : null,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
        ),
        onChanged: (val) => setState(() => _searchQuery = val),
      ),
    );
  }

  // ================= 桌面端双栏工作台布局 (左日历控制 + 右全高排程清单) =================

  Widget _buildDesktopLayout(
    Map<String, List<AgendaEvent>> eventsMap,
    List<AgendaEvent> selectedDayEvents,
    List<AgendaEvent> allEvents, {
    double width = 800,
  }) {
    final appColors = context.appColors;
    final primaryColor = context.colorScheme.primary;
    final info = ChineseCalendarHelper.getInfo(_selectedDate);
    const wk = ['一', '二', '三', '四', '五', '六', '日'];
    final wkStr = wk[_selectedDate.weekday - 1];

    // 用户核心需求：左侧日历栏与右侧日程栏比例支持鼠标拖动调节
    final minLeftWidth = 270.0;
    final maxLeftWidth = math.max(minLeftWidth, width - 300.0);
    final defaultLeftWidth =
        width > 900 ? 370.0 : (width > 720 ? 340.0 : 315.0);
    final targetRatio = _desktopSplitRatio ?? (defaultLeftWidth / width);
    final leftWidth =
        (width * targetRatio).clamp(minLeftWidth, maxLeftWidth);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 左侧主面板：自适应/拖拽调节宽度，专注日历视图与选中状态概览
        SizedBox(
          width: leftWidth,
          child: Column(
            children: [
              // 星期标头
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: _buildWeekdaysHeader(),
              ),

              // 日历主体（支持横向滑动或月份切换）
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      _viewSpan == AgendaViewSpan.week
                          ? _buildWeekViewStrip(eventsMap)
                          : _viewSpan == AgendaViewSpan.day
                              ? _buildDayViewBanner()
                              : _buildMonthCalendarGrid(eventsMap,
                                  isDesktop: true),
                      const SizedBox(height: 8),

                      // 左侧：选中日期概况卡片
                      Container(
                        margin: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: appColors.surfaceLow,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: appColors.borderSubtle,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: appColors.tagWork,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '${_selectedDate.month}月${_selectedDate.day}日 周$wkStr',
                                  style: TextStyle(
                                    color: appColors.textPrimary,
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const Spacer(),
                                if (info.holidayBadge != null)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: info.isRest
                                          ? appColors.tagRestContainer
                                          : appColors.tagLifeContainer,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      info.holidayBadge!,
                                      style: TextStyle(
                                        color: info.isRest
                                            ? appColors.tagRest
                                            : appColors.tagLife,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '农历 ${info.lunarText}${info.fullFestivalName != null ? " · ${info.fullFestivalName}" : ""}',
                              style: TextStyle(
                                color: appColors.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Text(
                                  '当天排程：${selectedDayEvents.length} 项',
                                  style: TextStyle(
                                    color: selectedDayEvents.isNotEmpty
                                        ? primaryColor
                                        : appColors.textTertiary,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const Spacer(),
                                TextButton.icon(
                                  style: TextButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 4),
                                    minimumSize: Size.zero,
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  onPressed: _jumpToToday,
                                  icon: Icon(
                                    Icons.today,
                                    size: 13,
                                    color: primaryColor,
                                  ),
                                  label: Text(
                                    '回今天',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: primaryColor,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),

        // 用户核心需求：支持鼠标拖动调节左右分栏比例的分栏调节器
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (_) {
            setState(() => _isDraggingSplitter = true);
          },
          onHorizontalDragEnd: (_) {
            setState(() => _isDraggingSplitter = false);
          },
          onHorizontalDragCancel: () {
            setState(() => _isDraggingSplitter = false);
          },
          onHorizontalDragUpdate: (details) {
            setState(() {
              final newLeft = (leftWidth + details.delta.dx)
                  .clamp(minLeftWidth, maxLeftWidth);
              _desktopSplitRatio = newLeft / width;
              _persistedDesktopSplitRatio = _desktopSplitRatio;
            });
          },
          onDoubleTap: () {
            // 双击分栏把手，一键恢复自适应默认比例
            setState(() {
              _desktopSplitRatio = null;
              _persistedDesktopSplitRatio = null;
            });
          },
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeColumn,
            onEnter: (_) => setState(() => _isHoveringSplitter = true),
            onExit: (_) => setState(() => _isHoveringSplitter = false),
            child: Container(
              width: 12,
              color: Colors.transparent, // 宽阔的鼠标触达区域
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // 纵向分割线
                  Container(
                    width: (_isDraggingSplitter || _isHoveringSplitter)
                        ? 2.5
                        : 1.0,
                    height: double.infinity,
                    color: (_isDraggingSplitter || _isHoveringSplitter)
                        ? primaryColor
                        : appColors.borderSubtle,
                  ),
                  // 中心拖拽指示把手
                  AnimatedOpacity(
                    opacity:
                        (_isDraggingSplitter || _isHoveringSplitter) ? 1.0 : 0.6,
                    duration: const Duration(milliseconds: 150),
                    child: Container(
                      width: 14,
                      height: 38,
                      decoration: BoxDecoration(
                        color: (_isDraggingSplitter || _isHoveringSplitter)
                            ? primaryColor
                            : appColors.surfaceLow,
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(
                          color: (_isDraggingSplitter || _isHoveringSplitter)
                              ? primaryColor
                              : appColors.borderSubtle,
                          width: 1,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.06),
                            blurRadius: 3,
                            offset: const Offset(0, 1),
                          ),
                        ],
                      ),
                      child: Icon(
                        Icons.drag_indicator,
                        size: 11,
                        color: (_isDraggingSplitter || _isHoveringSplitter)
                            ? Colors.white
                            : appColors.textTertiary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        // 右侧栏：全高度流式日程卡片与详情轴（桌面宽屏完全展开，绝不遮挡）
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 右侧顶部标题栏
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: appColors.borderSubtle,
                      width: 1,
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(Icons.event_note, size: 18, color: primaryColor),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${_selectedDate.month}月${_selectedDate.day}日 详细排程清单',
                        style: TextStyle(
                          color: appColors.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: appColors.surfaceLow,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '共 ${selectedDayEvents.length} 项',
                        style: TextStyle(
                          color: appColors.textSecondary,
                          fontSize: 11.5,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: appColors.textPrimary,
                        side: BorderSide(
                          color: appColors.borderSubtle,
                        ),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: _showAddEventDialog,
                      icon: Icon(Icons.add, size: 15, color: primaryColor),
                      label: const Text('添加日程',
                          style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ),

              // 右侧日程列表主体（流式平滑滚动，全高度展开）
              Expanded(
                child: _buildSelectedDayAgendaList(
                  selectedDayEvents,
                  allEvents,
                  isDesktop: true,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ================= 移动端单栏垂直流式布局 =================

  Widget _buildMobileCalendarAndTimeline(
    Map<String, List<AgendaEvent>> eventsMap,
    List<AgendaEvent> selectedDayEvents,
    List<AgendaEvent> allEvents,
  ) {
    final appColors = context.appColors;

    return Column(
      children: [
        // 星期标题栏（一 二 三 四 五 六 日，周末蓝字，贴合截图设计）
        _buildWeekdaysHeader(),

        // 日历网格（月视图或周视图，支持横滑翻月）
        GestureDetector(
          onHorizontalDragEnd: (details) {
            if (details.primaryVelocity == null) return;
            if (details.primaryVelocity! < -200) {
              if (_viewSpan == AgendaViewSpan.week) {
                setState(() => _selectedDate =
                    _selectedDate.add(const Duration(days: 7)));
              } else {
                _nextMonth();
              }
            } else if (details.primaryVelocity! > 200) {
              if (_viewSpan == AgendaViewSpan.week) {
                setState(() => _selectedDate =
                    _selectedDate.subtract(const Duration(days: 7)));
              } else {
                _prevMonth();
              }
            }
          },
          child: _viewSpan == AgendaViewSpan.week
              ? _buildWeekViewStrip(eventsMap)
              : _viewSpan == AgendaViewSpan.day
                  ? _buildDayViewBanner()
                  : _buildMonthCalendarGrid(eventsMap, isDesktop: false),
        ),

        // 分割把手（胶囊条，点击可快捷切换月视图与周视图）
        InkWell(
          onTap: () {
            setState(() {
              _viewSpan = _viewSpan == AgendaViewSpan.month
                  ? AgendaViewSpan.week
                  : AgendaViewSpan.month;
            });
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Center(
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: appColors.borderSubtle,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ),

        // 下半部：选中日期的日程排程卡片列表
        Expanded(
          child: _buildSelectedDayAgendaList(selectedDayEvents, allEvents,
              isDesktop: false),
        ),
      ],
    );
  }

  // ================= 星期标头行 =================

  Widget _buildWeekdaysHeader() {
    final appColors = context.appColors;
    final primaryColor = context.colorScheme.primary;
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: List.generate(7, (idx) {
          final isWeekend = idx >= 5; // 周六、周日
          return Expanded(
            child: Center(
              child: Text(
                weekdays[idx],
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: isWeekend ? primaryColor : appColors.textSecondary,
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  // ================= 月视图大日历网格 =================

  Widget _buildMonthCalendarGrid(Map<String, List<AgendaEvent>> eventsMap,
      {bool isDesktop = false}) {
    final year = _displayedMonth.year;
    final month = _displayedMonth.month;

    // 确定当月第一天是星期几（Dart: 1=周一, 7=周日）
    final firstDayOfMonth = DateTime(year, month, 1);
    final int firstWeekday = firstDayOfMonth.weekday; // 1 ~ 7
    final int leadingDays = firstWeekday - 1; // 需要展示的上月天数

    // 当月总天数
    final int daysInMonth = DateTime(year, month + 1, 0).day;

    // 计算总格数（35 或 42 格，保持规整）
    final int totalCellsSoFar = leadingDays + daysInMonth;
    final int totalCells = totalCellsSoFar <= 35 ? 35 : 42;

    // 网格起始日期
    final gridStartDate =
        firstDayOfMonth.subtract(Duration(days: leadingDays));

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: totalCells,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 7,
          childAspectRatio: isDesktop ? 1.0 : 0.95, // 桌面固定左栏紧凑方正，移动端饱满
        ),
        itemBuilder: (context, idx) {
          final cellDate = gridStartDate.add(Duration(days: idx));
          return _buildDateCell(cellDate, eventsMap, currentMonth: month);
        },
      ),
    );
  }

  // ================= 周视图 7 天滑轨 =================

  Widget _buildWeekViewStrip(Map<String, List<AgendaEvent>> eventsMap) {
    final int curWeekday = _selectedDate.weekday; // 1 ~ 7
    final weekStart = _selectedDate.subtract(Duration(days: curWeekday - 1));

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: List.generate(7, (idx) {
          final cellDate = weekStart.add(Duration(days: idx));
          return Expanded(
            child: SizedBox(
              height: 60,
              child: _buildDateCell(cellDate, eventsMap,
                  currentMonth: cellDate.month),
            ),
          );
        }),
      ),
    );
  }

  // ================= 日视图顶部 Banner =================

  Widget _buildDayViewBanner() {
    final appColors = context.appColors;
    final primaryColor = context.colorScheme.primary;
    final onPrimary = context.colorScheme.onPrimary;
    final info = ChineseCalendarHelper.getInfo(_selectedDate);
    const wk = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    final wkStr = wk[_selectedDate.weekday - 1];

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: appColors.surfaceLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: appColors.borderSubtle,
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: primaryColor,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              children: [
                Text(
                  '${_selectedDate.day}',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: onPrimary,
                  ),
                ),
                Text(
                  wkStr,
                  style: TextStyle(
                    fontSize: 11,
                    color: onPrimary.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_selectedDate.year}年${_selectedDate.month}月${_selectedDate.day}日 $wkStr',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: appColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '农历 ${info.lunarText}${info.fullFestivalName != null ? " · ${info.fullFestivalName}" : ""}',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: appColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (info.holidayBadge != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: info.isRest
                    ? appColors.tagRestContainer
                    : appColors.tagLifeContainer,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                info.holidayBadge!,
                style: TextStyle(
                  color: info.isRest ? appColors.tagRest : appColors.tagLife,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ================= 单个日历格子组件 (核心像素还原) =================

  Widget _buildDateCell(
    DateTime date,
    Map<String, List<AgendaEvent>> eventsMap, {
    required int currentMonth,
  }) {
    final appColors = context.appColors;
    final primaryColor = context.colorScheme.primary;
    final onPrimary = context.colorScheme.onPrimary;
    final now = DateTime.now();
    final bool isCurrentMonth = date.month == currentMonth;
    final bool isSelected = _isSameDay(date, _selectedDate);
    final bool isToday = _isSameDay(date, now);
    final bool isWeekend = date.weekday >= 6;

    // 农历与节假日数据
    final info = ChineseCalendarHelper.getInfo(date);

    // 查询当天排程
    final key = '${date.year}-${date.month}-${date.day}';
    final hasEvents = (eventsMap[key]?.isNotEmpty) ?? false;

    // 字体颜色判定
    Color dateColor;
    Color lunarColor;

    if (isSelected) {
      dateColor = onPrimary;
      lunarColor = onPrimary.withValues(alpha: 0.85);
    } else if (!isCurrentMonth) {
      dateColor = appColors.textTertiary;
      lunarColor = appColors.textTertiary;
    } else if (isWeekend) {
      dateColor = primaryColor;
      lunarColor = appColors.textSecondary;
    } else {
      dateColor = appColors.textPrimary;
      lunarColor = appColors.textSecondary;
    }

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        setState(() {
          _selectedDate = date;
          // 若点击了上月或下月的日期，平滑切换月份
          if (date.month != _displayedMonth.month) {
            _displayedMonth = DateTime(date.year, date.month, 1);
          }
        });
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 1.5),
        decoration: BoxDecoration(
          color: isSelected ? primaryColor : null,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            // 今天（若未选中）：主色外框线（以浮层绘制，不产生内边距挤压内部排版，彻底避免溢出）
            if (isToday && !isSelected)
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: primaryColor,
                        width: 1.6,
                      ),
                    ),
                  ),
                ),
              ),

            // 右上角法定节假日角标（休 / 班）
            if (_showHolidays && info.holidayBadge != null)
              Positioned(
                top: 2,
                right: 3,
                child: Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    color: info.isRest
                        ? appColors.tagRest
                        : appColors.tagLife,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      info.holidayBadge!,
                      style: TextStyle(
                        color: onPrimary,
                        fontSize: 8.5,
                        fontWeight: FontWeight.bold,
                        height: 1.0,
                      ),
                    ),
                  ),
                ),
              ),

            // 日期数字、农历文本及日程圆点指示器
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${date.day}',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight:
                          isSelected ? FontWeight.bold : FontWeight.w600,
                      color: dateColor,
                      height: 1.1,
                    ),
                  ),
                  if (_showLunar) ...[
                    const SizedBox(height: 1),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1),
                      child: Text(
                        info.lunarText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 9.5,
                          color: lunarColor,
                          height: 1.1,
                        ),
                      ),
                    ),
                  ],
                  // 当天有日程安排时的排程指示圆点
                  if (hasEvents) ...[
                    const SizedBox(height: 2),
                    Container(
                      width: 4,
                      height: 4,
                      decoration: BoxDecoration(
                        color: isSelected ? onPrimary : appColors.tagWork,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ] else ...[
                    const SizedBox(height: 6),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ================= 选中日期的日程排程卡片列表 =================

  Widget _buildSelectedDayAgendaList(
    List<AgendaEvent> selectedEvents,
    List<AgendaEvent> allEvents, {
    bool isDesktop = false,
  }) {
    final appColors = context.appColors;
    final primaryColor = context.colorScheme.primary;

    if (selectedEvents.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: appColors.surfaceLow,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.event_available_outlined,
                  size: 32,
                  color: primaryColor,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '${_selectedDate.month}月${_selectedDate.day}日 暂无日程安排',
                style: TextStyle(
                  color: appColors.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '点击右上角「+」快速添加，或前往 AI 提取区从通知中一键解析',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: appColors.textSecondary,
                  fontSize: 12.5,
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: primaryColor,
                      side: BorderSide(color: primaryColor),
                    ),
                    onPressed: _showAddEventDialog,
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('添加日程'),
                  ),
                  if (allEvents.isEmpty)
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: primaryColor,
                        foregroundColor: context.colorScheme.onPrimary,
                      ),
                      onPressed: _loadSampleSchedules,
                      icon: const Icon(Icons.auto_stories, size: 16),
                      label: const Text('载入示例课表'),
                    )
                  else if (widget.onNavigateToExtractor != null)
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: primaryColor,
                        foregroundColor: context.colorScheme.onPrimary,
                      ),
                      onPressed: widget.onNavigateToExtractor,
                      icon: const Icon(Icons.psychology, size: 16),
                      label: const Text('去 AI 提取区'),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: EdgeInsets.fromLTRB(16, 6, 16, isDesktop ? 20 : 80),
      itemCount: selectedEvents.length,
      itemBuilder: (context, idx) {
        final ev = selectedEvents[idx];
        return AgendaEventCard(
          event: ev,
          showDate: false,
          isDraft: false,
          onSyncCalendar: () => _writeToCalendar(ev),
          onDelete: () => _confirmDelete(ev),
          onEventChanged: (updated) => _repo.updateEvent(updated),
          onTap: () => _showEventDetailSheet(ev),
        );
      },
    );
  }

  // ================= 全部跨度视图 (全量检索列表) =================

  Widget _buildAllEventsListView(List<AgendaEvent> allEvents) {
    final appColors = context.appColors;
    final filtered = _repo.filter(
      query: _searchQuery,
      status: _listFilter,
    );

    final counts = {
      AgendaFilterStatus.all: allEvents.length,
      AgendaFilterStatus.upcoming:
          allEvents.where((e) => e.endTime.isAfter(DateTime.now())).length,
      AgendaFilterStatus.past:
          allEvents.where((e) => e.endTime.isBefore(DateTime.now())).length,
      AgendaFilterStatus.synced:
          allEvents.where((e) => e.syncedToSystemCalendar).length,
      AgendaFilterStatus.unsynced:
          allEvents.where((e) => !e.syncedToSystemCalendar).length,
    };

    return Column(
      children: [
        // 筛选栏
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: AgendaFilterBar(
            currentFilter: _listFilter,
            counts: counts,
            onFilterChanged: (st) => setState(() => _listFilter = st),
            onSearchChanged: (q) => setState(() => _searchQuery = q),
          ),
        ),
        Divider(
          color: appColors.borderSubtle,
          height: 1,
        ),
        Expanded(
          child: filtered.isEmpty
              ? AgendaEmptyState(
                  icon: Icons.filter_alt_off_outlined,
                  title: '未找到符合条件的日程',
                  subtitle: '可尝试更改搜索关键字或调整分类标签',
                  actionLabel: '重置筛选',
                  onAction: () {
                    setState(() {
                      _listFilter = AgendaFilterStatus.all;
                      _searchQuery = '';
                      _searchController.clear();
                    });
                  },
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: filtered.length,
                  itemBuilder: (context, idx) {
                    final ev = filtered[idx];
                    return AgendaEventCard(
                      event: ev,
                      showDate: true,
                      isDraft: false,
                      onSyncCalendar: () => _writeToCalendar(ev),
                      onDelete: () => _confirmDelete(ev),
                      onEventChanged: (updated) => _repo.updateEvent(updated),
                      onTap: () => _showEventDetailSheet(ev),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
