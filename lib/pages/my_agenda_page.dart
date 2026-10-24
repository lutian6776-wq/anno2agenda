import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/agenda_event.dart';
import '../repositories/agenda_repository.dart';
import '../services/agenda_write_service.dart';
import '../services/chinese_calendar_helper.dart';
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

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _selectedDate = DateTime(now.year, now.month, now.day);
    _displayedMonth = DateTime(now.year, now.month, 1);
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? const Color(0xFF1E1E22) : Colors.white,
        title: Text(
          '删除日程事项',
          style: TextStyle(
            color: isDark ? Colors.white : const Color(0xFF0F172A),
          ),
        ),
        content: Text(
          '确定要删除「${event.title}」吗？',
          style: TextStyle(
            color: isDark ? const Color(0xFFD1D5DB) : const Color(0xFF475569),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              '取消',
              style: TextStyle(
                color: isDark ? const Color(0xFF9CA3AF) : const Color(0xFF64748B),
              ),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade600),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _repo.removeEvent(event.id);
      _showSnack('🗑️ 已删除日程：${event.title}');
    }
  }

  Future<void> _confirmClearAll() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? const Color(0xFF1E1E22) : Colors.white,
        title: Text(
          '清空全部日程',
          style: TextStyle(
            color: isDark ? Colors.white : const Color(0xFF0F172A),
          ),
        ),
        content: Text(
          '此操作将清空本地全部已入库日程，确定继续吗？',
          style: TextStyle(
            color: isDark ? const Color(0xFFD1D5DB) : const Color(0xFF475569),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              '取消',
              style: TextStyle(
                color: isDark ? const Color(0xFF9CA3AF) : const Color(0xFF64748B),
              ),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade600),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
        builder: (context, setDlgState) => AlertDialog(
          backgroundColor: isDark ? const Color(0xFF1E1E22) : Colors.white,
          title: Text(
            '新建日程安排',
            style: TextStyle(
              color: isDark ? Colors.white : const Color(0xFF0F172A),
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
                      color: isDark ? Colors.white : const Color(0xFF0F172A),
                    ),
                    decoration: InputDecoration(
                      labelText: '日程标题 *',
                      labelStyle: TextStyle(
                        color:
                            isDark ? const Color(0xFF9CA3AF) : const Color(0xFF64748B),
                      ),
                      hintText: '如：高等数学讲座、项目开题答辩',
                      hintStyle: TextStyle(
                        color:
                            isDark ? const Color(0xFF6B7280) : const Color(0xFF94A3B8),
                      ),
                      filled: true,
                      fillColor:
                          isDark ? const Color(0xFF27272A) : const Color(0xFFF1F5F9),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(
                          color: isDark
                              ? const Color(0xFF3F3F46)
                              : const Color(0xFFE2E8F0),
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(
                          color: isDark
                              ? const Color(0xFF3F3F46)
                              : const Color(0xFFE2E8F0),
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
                            foregroundColor:
                                isDark ? Colors.white : const Color(0xFF0F172A),
                            side: BorderSide(
                              color: isDark
                                  ? const Color(0xFF3F3F46)
                                  : const Color(0xFFCBD5E1),
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
                          icon: const Icon(Icons.access_time,
                              size: 16, color: Color(0xFF60A5FA)),
                          label: Text(
                              '开始 ${_two(start.hour)}:${_two(start.minute)}',
                              style: const TextStyle(fontSize: 12)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor:
                                isDark ? Colors.white : const Color(0xFF0F172A),
                            side: BorderSide(
                              color: isDark
                                  ? const Color(0xFF3F3F46)
                                  : const Color(0xFFCBD5E1),
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
                          icon: const Icon(Icons.timer_outlined,
                              size: 16, color: Color(0xFF60A5FA)),
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
                      color: isDark ? Colors.white : const Color(0xFF0F172A),
                    ),
                    decoration: InputDecoration(
                      labelText: '地点 / 线上会议号',
                      labelStyle: TextStyle(
                        color:
                            isDark ? const Color(0xFF9CA3AF) : const Color(0xFF64748B),
                      ),
                      hintText: '如：主楼A203、腾讯会议：884-291',
                      hintStyle: TextStyle(
                        color:
                            isDark ? const Color(0xFF6B7280) : const Color(0xFF94A3B8),
                      ),
                      filled: true,
                      fillColor:
                          isDark ? const Color(0xFF27272A) : const Color(0xFFF1F5F9),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(
                          color: isDark
                              ? const Color(0xFF3F3F46)
                              : const Color(0xFFE2E8F0),
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(
                          color: isDark
                              ? const Color(0xFF3F3F46)
                              : const Color(0xFFE2E8F0),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: descCtrl,
                    maxLines: 2,
                    style: TextStyle(
                      color: isDark ? Colors.white : const Color(0xFF0F172A),
                    ),
                    decoration: InputDecoration(
                      labelText: '日程备注说明',
                      labelStyle: TextStyle(
                        color:
                            isDark ? const Color(0xFF9CA3AF) : const Color(0xFF64748B),
                      ),
                      hintText: '添加备忘或重点事项',
                      hintStyle: TextStyle(
                        color:
                            isDark ? const Color(0xFF6B7280) : const Color(0xFF94A3B8),
                      ),
                      filled: true,
                      fillColor:
                          isDark ? const Color(0xFF27272A) : const Color(0xFFF1F5F9),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(
                          color: isDark
                              ? const Color(0xFF3F3F46)
                              : const Color(0xFFE2E8F0),
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(
                          color: isDark
                              ? const Color(0xFF3F3F46)
                              : const Color(0xFFE2E8F0),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // 提前提醒时间
                  Row(
                    children: [
                      Icon(Icons.notifications_outlined,
                          size: 16,
                          color: isDark
                              ? const Color(0xFF9CA3AF)
                              : const Color(0xFF64748B)),
                      const SizedBox(width: 8),
                      Text('提前提醒：',
                          style: TextStyle(
                              color: isDark
                                  ? const Color(0xFFD1D5DB)
                                  : const Color(0xFF334155),
                              fontSize: 13)),
                      const Spacer(),
                      DropdownButton<int>(
                        value: reminder,
                        dropdownColor:
                            isDark ? const Color(0xFF27272A) : Colors.white,
                        style: TextStyle(
                          color: isDark ? Colors.white : const Color(0xFF0F172A),
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
                      title: Text('同时写入手机系统日历',
                          style: TextStyle(
                              color: isDark ? Colors.white : const Color(0xFF0F172A),
                              fontSize: 13)),
                      activeColor: const Color(0xFF2563EB),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('取消',
                  style: TextStyle(
                      color: isDark
                          ? const Color(0xFF9CA3AF)
                          : const Color(0xFF64748B))),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF2563EB)),
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
        ),
      ),
    );
  }

  /// 弹出查看日程详情卡片
  void _showEventDetailSheet(AgendaEvent event) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? const Color(0xFF1E1E22) : Colors.white,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 540),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
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
                    color: isDark
                        ? const Color(0xFF3F3F46)
                        : const Color(0xFFCBD5E1),
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
                    decoration: const BoxDecoration(
                      color: Color(0xFF3B82F6),
                      shape: BoxShape.circle,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      event.title,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                      ),
                    ),
                  ),
                  if (event.syncedToSystemCalendar)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: isDark
                            ? const Color(0xFF064E3B)
                            : const Color(0xFFDCFCE7),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.check,
                              size: 12,
                              color: isDark
                                  ? const Color(0xFF34D399)
                                  : const Color(0xFF16A34A)),
                          const SizedBox(width: 4),
                          Text('已入系统日历',
                              style: TextStyle(
                                  color: isDark
                                      ? const Color(0xFF34D399)
                                      : const Color(0xFF16A34A),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),

              // 时间段
              Row(
                children: [
                  const Icon(Icons.access_time,
                      size: 16, color: Color(0xFF60A5FA)),
                  const SizedBox(width: 8),
                  Text(
                    '${_formatDate(event.startTime)}  ${_two(event.startTime.hour)}:${_two(event.startTime.minute)} - ${_two(event.endTime.hour)}:${_two(event.endTime.minute)}',
                    style: TextStyle(
                        color: isDark
                            ? const Color(0xFFE5E7EB)
                            : const Color(0xFF1E293B),
                        fontSize: 14,
                        fontWeight: FontWeight.w500),
                  ),
                ],
              ),

              // 地点
              if (event.location.isNotEmpty) ...[
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.location_on_outlined,
                        size: 16, color: Color(0xFF60A5FA)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        event.location,
                        style: TextStyle(
                            color: isDark
                                ? const Color(0xFFD1D5DB)
                                : const Color(0xFF475569),
                            fontSize: 13.5),
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
                    color: isDark
                        ? const Color(0xFF27272A)
                        : const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isDark
                          ? const Color(0xFF3F3F46)
                          : const Color(0xFFE2E8F0),
                    ),
                  ),
                  child: Text(
                    event.description,
                    style: TextStyle(
                        color: isDark
                            ? const Color(0xFFD1D5DB)
                            : const Color(0xFF334155),
                        fontSize: 13,
                        height: 1.4),
                  ),
                ),
              ],

              // 备忘打勾清单
              if (event.checklist.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('待办事项清单：',
                    style: TextStyle(
                        color: isDark
                            ? const Color(0xFF9CA3AF)
                            : const Color(0xFF64748B),
                        fontSize: 12,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                ...event.checklist.map((item) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          const Icon(Icons.check_circle_outline,
                              size: 15, color: Color(0xFF34D399)),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(item,
                                style: TextStyle(
                                    color: isDark
                                        ? const Color(0xFFE5E7EB)
                                        : const Color(0xFF1E293B),
                                    fontSize: 13)),
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
                  collapsedIconColor: isDark
                      ? const Color(0xFF9CA3AF)
                      : const Color(0xFF64748B),
                  iconColor: const Color(0xFF60A5FA),
                  title: Text('提取自原始通知内容',
                      style: TextStyle(
                          color: isDark
                              ? const Color(0xFF9CA3AF)
                              : const Color(0xFF64748B),
                          fontSize: 12)),
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: isDark
                            ? const Color(0xFF18181B)
                            : const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isDark
                              ? const Color(0xFF27272A)
                              : const Color(0xFFE2E8F0),
                        ),
                      ),
                      child: Text(
                        event.sourceText,
                        style: TextStyle(
                            color: isDark
                                ? const Color(0xFF9CA3AF)
                                : const Color(0xFF64748B),
                            fontSize: 12,
                            height: 1.35),
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
                        foregroundColor: Colors.red.shade400,
                        side: BorderSide(
                            color: isDark
                                ? Colors.red.shade800
                                : Colors.red.shade300),
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
                            ? const Color(0xFF059669)
                            : const Color(0xFF2563EB),
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
        ),
      ),
    );
  }

  // ================= 时间跨度弹出选择器（用户核心定制需求） =================

  /// 用户核心需求：通过按钮弹出复选框来选择时间跨度与偏好设置
  void _showSpanSelectionModal() {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 540),
      backgroundColor: isDark ? const Color(0xFF1E1E22) : Colors.white,
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
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 拖动条
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: isDark
                            ? const Color(0xFF3F3F46)
                            : const Color(0xFFCBD5E1),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '选择时间跨度与日历视图',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          color:
                              isDark ? Colors.white : const Color(0xFF0F172A),
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          setModalState(() {
                            _viewSpan = AgendaViewSpan.month;
                            _showHolidays = true;
                            _showLunar = true;
                            _onlyUpcoming = false;
                            _onlySynced = false;
                          });
                          setState(() {});
                        },
                        child: const Text('恢复默认',
                            style: TextStyle(
                                color: Color(0xFF60A5FA), fontSize: 13)),
                      ),
                    ],
                  ),
                  Divider(
                    color: isDark
                        ? const Color(0xFF27272A)
                        : const Color(0xFFE2E8F0),
                    height: 16,
                  ),

                  Text('视图与时间跨度模式',
                      style: TextStyle(
                          color: isDark
                              ? const Color(0xFF9CA3AF)
                              : const Color(0xFF64748B),
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),

                  // 单选跨度模式
                  _buildSpanRadioTile(
                    title: '月跨度 (月视图)',
                    subtitle: '呈现整月日历网格、农历节气、调休角标与每日排程点',
                    span: AgendaViewSpan.month,
                    icon: Icons.calendar_view_month,
                    current: _viewSpan,
                    isDark: isDark,
                    onSelected: (s) {
                      setModalState(() => _viewSpan = s);
                      setState(() => _viewSpan = s);
                    },
                  ),
                  _buildSpanRadioTile(
                    title: '周跨度 (周视图)',
                    subtitle: '聚焦当前周 7 天时间轴，释放下方列表展示更多待办',
                    span: AgendaViewSpan.week,
                    icon: Icons.view_week_outlined,
                    current: _viewSpan,
                    isDark: isDark,
                    onSelected: (s) {
                      setModalState(() => _viewSpan = s);
                      setState(() => _viewSpan = s);
                    },
                  ),
                  _buildSpanRadioTile(
                    title: '日跨度 (单日视图)',
                    subtitle: '聚焦单日详细日程安排、备忘清单与回溯文本',
                    span: AgendaViewSpan.day,
                    icon: Icons.calendar_today_outlined,
                    current: _viewSpan,
                    isDark: isDark,
                    onSelected: (s) {
                      setModalState(() => _viewSpan = s);
                      setState(() => _viewSpan = s);
                    },
                  ),
                  _buildSpanRadioTile(
                    title: '全部跨度 (列表检索模式)',
                    subtitle: '纵向流式检索全部已入库日程，支持关键词搜索与分类筛选',
                    span: AgendaViewSpan.all,
                    icon: Icons.format_list_bulleted,
                    current: _viewSpan,
                    isDark: isDark,
                    onSelected: (s) {
                      setModalState(() => _viewSpan = s);
                      setState(() => _viewSpan = s);
                    },
                  ),

                  const SizedBox(height: 10),
                  Text('日历显示偏好与筛选复选框',
                      style: TextStyle(
                          color: isDark
                              ? const Color(0xFF9CA3AF)
                              : const Color(0xFF64748B),
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),

                  // 复选框偏好
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: _showHolidays,
                    activeColor: const Color(0xFF2563EB),
                    title: Text('显示法定节假日与调休标识 (休 / 班)',
                        style: TextStyle(
                            color: isDark
                                ? Colors.white
                                : const Color(0xFF0F172A),
                            fontSize: 13.5)),
                    subtitle: Text('国务院节假日办公布的放假及周末补班状态',
                        style: TextStyle(
                            color: isDark
                                ? const Color(0xFF9CA3AF)
                                : const Color(0xFF64748B),
                            fontSize: 11.5)),
                    onChanged: (v) {
                      setModalState(() => _showHolidays = v ?? true);
                      setState(() => _showHolidays = v ?? true);
                    },
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: _showLunar,
                    activeColor: const Color(0xFF2563EB),
                    title: Text('显示中国传统农历与二十四节气',
                        style: TextStyle(
                            color: isDark
                                ? Colors.white
                                : const Color(0xFF0F172A),
                            fontSize: 13.5)),
                    subtitle: Text('农历月日、二十四节气及核心纪念日',
                        style: TextStyle(
                            color: isDark
                                ? const Color(0xFF9CA3AF)
                                : const Color(0xFF64748B),
                            fontSize: 11.5)),
                    onChanged: (v) {
                      setModalState(() => _showLunar = v ?? true);
                      setState(() => _showLunar = v ?? true);
                    },
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: _onlyUpcoming,
                    activeColor: const Color(0xFF2563EB),
                    title: Text('仅显示未过期的有效日程',
                        style: TextStyle(
                            color: isDark
                                ? Colors.white
                                : const Color(0xFF0F172A),
                            fontSize: 13.5)),
                    onChanged: (v) {
                      setModalState(() => _onlyUpcoming = v ?? false);
                      setState(() => _onlyUpcoming = v ?? false);
                    },
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: _onlySynced,
                    activeColor: const Color(0xFF2563EB),
                    title: Text('仅显示已同步至系统日历的日程',
                        style: TextStyle(
                            color: isDark
                                ? Colors.white
                                : const Color(0xFF0F172A),
                            fontSize: 13.5)),
                    onChanged: (v) {
                      setModalState(() => _onlySynced = v ?? false);
                      setState(() => _onlySynced = v ?? false);
                    },
                  ),

                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF2563EB),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('确定应用',
                          style: TextStyle(
                              fontSize: 14, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSpanRadioTile({
    required String title,
    required String subtitle,
    required AgendaViewSpan span,
    required IconData icon,
    required AgendaViewSpan current,
    required ValueChanged<AgendaViewSpan> onSelected,
    bool isDark = false,
  }) {
    final isSelected = span == current;
    return InkWell(
      onTap: () => onSelected(span),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          children: [
            Icon(icon,
                size: 20,
                color: isSelected
                    ? const Color(0xFF60A5FA)
                    : (isDark
                        ? const Color(0xFF9CA3AF)
                        : const Color(0xFF64748B))),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: isSelected
                          ? (isDark ? Colors.white : const Color(0xFF2563EB))
                          : (isDark
                              ? const Color(0xFFD1D5DB)
                              : const Color(0xFF0F172A)),
                      fontSize: 13.5,
                      fontWeight:
                          isSelected ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(
                        color: isDark
                            ? const Color(0xFF9CA3AF)
                            : const Color(0xFF64748B),
                        fontSize: 11),
                  ),
                ],
              ),
            ),
            Icon(
              isSelected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off,
              color: isSelected
                  ? const Color(0xFF2563EB)
                  : (isDark ? const Color(0xFF6B7280) : const Color(0xFFCBD5E1)),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;

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
                color: isDark ? const Color(0xFF0F0F12) : Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isDark
                      ? const Color(0xFF1E1E24)
                      : const Color(0xFFE2E8F0),
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
                        backgroundColor: const Color(0xFF2563EB),
                        elevation: 4,
                        shape: const CircleBorder(),
                        onPressed: _jumpToToday,
                        child: const Text(
                          '今',
                          style: TextStyle(
                            color: Colors.white,
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
                  builder: (context, child) => Theme(
                    data: (isDark ? ThemeData.dark() : ThemeData.light())
                        .copyWith(
                      colorScheme: isDark
                          ? const ColorScheme.dark(
                              primary: Color(0xFF2563EB),
                              onPrimary: Colors.white,
                              surface: Color(0xFF1E1E22),
                              onSurface: Colors.white,
                            )
                          : const ColorScheme.light(
                              primary: Color(0xFF2563EB),
                              onPrimary: Colors.white,
                              surface: Colors.white,
                              onSurface: Color(0xFF0F172A),
                            ),
                    ),
                    child: child!,
                  ),
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
                        fontSize: 23,
                        fontWeight: FontWeight.w800,
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        relativeText,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: isDark
                              ? const Color(0xFF9CA3AF)
                              : const Color(0xFF64748B),
                        ),
                      ),
                    ),
                    Icon(Icons.arrow_drop_down,
                        size: 16,
                        color: isDark
                            ? const Color(0xFF9CA3AF)
                            : const Color(0xFF64748B)),
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
                foregroundColor:
                    isDark ? Colors.white : const Color(0xFF0F172A),
                side: BorderSide(
                  color: isDark
                      ? const Color(0xFF3F3F46)
                      : const Color(0xFFCBD5E1),
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              ),
              onPressed: _jumpToToday,
              icon: const Icon(Icons.today, size: 14, color: Color(0xFF60A5FA)),
              label: const Text('今天', style: TextStyle(fontSize: 11.5)),
            ),
          ],

          const SizedBox(width: 4),

          // 用户核心需求：通过按钮弹出复选框来选时间跨度
          InkWell(
            onTap: _showSpanSelectionModal,
            borderRadius: BorderRadius.circular(18),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xFF24242A)
                    : const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: isDark
                      ? const Color(0xFF3F3F46)
                      : const Color(0xFFCBD5E1),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.tune_outlined,
                      size: 13, color: Color(0xFF60A5FA)),
                  const SizedBox(width: 4),
                  Text(
                    '跨度: ${_getSpanLabel(_viewSpan)}',
                    style: TextStyle(
                      color: isDark ? Colors.white : const Color(0xFF0F172A),
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Icon(Icons.arrow_drop_down,
                      size: 15,
                      color: isDark ? Colors.white70 : const Color(0xFF64748B)),
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
            icon: Icon(Icons.add,
                size: 22,
                color: isDark ? Colors.white : const Color(0xFF0F172A)),
            onPressed: _showAddEventDialog,
          ),

          // 更多菜单（⋮ 图标，截图对应）
          PopupMenuButton<String>(
            tooltip: '更多操作',
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            padding: const EdgeInsets.all(4),
            icon: Icon(Icons.more_vert,
                size: 19,
                color: isDark ? Colors.white : const Color(0xFF0F172A)),
            color: isDark ? const Color(0xFF1E1E22) : Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: isDark
                    ? const Color(0xFF2C2C32)
                    : const Color(0xFFE2E8F0),
              ),
            ),
            onSelected: (val) {
              switch (val) {
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
                value: 'today',
                child: Row(
                  children: [
                    const Icon(Icons.today, size: 16, color: Color(0xFF60A5FA)),
                    const SizedBox(width: 8),
                    Text(
                      '回今天',
                      style: TextStyle(
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'sample',
                child: Row(
                  children: [
                    const Icon(Icons.auto_stories_outlined,
                        size: 16, color: Color(0xFF60A5FA)),
                    const SizedBox(width: 8),
                    Text(
                      '载入示范课表日程',
                      style: TextStyle(
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'search',
                child: Row(
                  children: [
                    const Icon(Icons.search, size: 16, color: Color(0xFF60A5FA)),
                    const SizedBox(width: 8),
                    Text(
                      '搜索日程',
                      style: TextStyle(
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'export',
                child: Row(
                  children: [
                    const Icon(Icons.file_download_outlined,
                        size: 16, color: Color(0xFF60A5FA)),
                    const SizedBox(width: 8),
                    Text(
                      '导出全部 ICS 日历',
                      style: TextStyle(
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
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
                    Icon(Icons.delete_outline,
                        size: 16, color: Colors.red.shade400),
                    const SizedBox(width: 8),
                    Text('清空所有日程',
                        style: TextStyle(color: Colors.red.shade400)),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E24) : const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isDark ? const Color(0xFF2E2E36) : const Color(0xFFE2E8F0),
        ),
      ),
      child: TextField(
        controller: _searchController,
        style: TextStyle(
          color: isDark ? Colors.white : const Color(0xFF0F172A),
          fontSize: 13.5,
        ),
        decoration: InputDecoration(
          hintText: '搜索日程标题、地点、备忘或原通知...',
          hintStyle: TextStyle(
            color: isDark ? const Color(0xFF6B7280) : const Color(0xFF94A3B8),
            fontSize: 13,
          ),
          prefixIcon: Icon(
            Icons.search,
            size: 18,
            color: isDark ? const Color(0xFF9CA3AF) : const Color(0xFF64748B),
          ),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: Icon(
                    Icons.clear,
                    size: 16,
                    color: isDark
                        ? const Color(0xFF9CA3AF)
                        : const Color(0xFF64748B),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final info = ChineseCalendarHelper.getInfo(_selectedDate);
    const wk = ['一', '二', '三', '四', '五', '六', '日'];
    final wkStr = wk[_selectedDate.weekday - 1];
    final leftWidth = width > 900 ? 370.0 : (width > 720 ? 340.0 : 315.0);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 左侧主面板：自适应宽度 330~370px，专注日历视图与选中状态概览
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
                          color: isDark
                              ? const Color(0xFF18181C)
                              : const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isDark
                                ? const Color(0xFF27272A)
                                : const Color(0xFFE2E8F0),
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
                                  decoration: const BoxDecoration(
                                    color: Color(0xFF3B82F6),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '${_selectedDate.month}月${_selectedDate.day}日 周$wkStr',
                                  style: TextStyle(
                                    color: isDark
                                        ? Colors.white
                                        : const Color(0xFF0F172A),
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
                                          ? const Color(0xFF1D4ED8)
                                          : const Color(0xFFEA580C),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      info.holidayBadge!,
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '农历 ${info.lunarText}${info.fullFestivalName != null ? " · ${info.fullFestivalName}" : ""}',
                              style: TextStyle(
                                color: isDark
                                    ? const Color(0xFF9CA3AF)
                                    : const Color(0xFF64748B),
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
                                        ? const Color(0xFF60A5FA)
                                        : (isDark
                                            ? const Color(0xFF6B7280)
                                            : const Color(0xFF94A3B8)),
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
                                  icon: const Icon(Icons.today,
                                      size: 13, color: Color(0xFF60A5FA)),
                                  label: const Text('回今天',
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF60A5FA))),
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

        // 纵向分割线
        VerticalDivider(
          width: 1,
          thickness: 1,
          color: isDark ? const Color(0xFF24242A) : const Color(0xFFE2E8F0),
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
                      color: isDark
                          ? const Color(0xFF1E1E24)
                          : const Color(0xFFE2E8F0),
                      width: 1,
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.event_note,
                        size: 18, color: Color(0xFF3B82F6)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${_selectedDate.month}月${_selectedDate.day}日 详细排程清单',
                        style: TextStyle(
                          color:
                              isDark ? Colors.white : const Color(0xFF0F172A),
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
                        color: isDark
                            ? const Color(0xFF27272A)
                            : const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '共 ${selectedDayEvents.length} 项',
                        style: TextStyle(
                          color: isDark
                              ? const Color(0xFF9CA3AF)
                              : const Color(0xFF64748B),
                          fontSize: 11.5,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor:
                            isDark ? Colors.white : const Color(0xFF0F172A),
                        side: BorderSide(
                          color: isDark
                              ? const Color(0xFF3F3F46)
                              : const Color(0xFFCBD5E1),
                        ),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: _showAddEventDialog,
                      icon: const Icon(Icons.add,
                          size: 15, color: Color(0xFF60A5FA)),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;

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
                  color: isDark
                      ? const Color(0xFF374151)
                      : const Color(0xFFCBD5E1),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ),

        // 下半部：选中日期的日程排程卡片列表（高度还原截图深色卡片与蓝色指示圆点）
        Expanded(
          child: _buildSelectedDayAgendaList(selectedDayEvents, allEvents,
              isDesktop: false),
        ),
      ],
    );
  }

  // ================= 星期标头行 =================

  Widget _buildWeekdaysHeader() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
                  // 周末使用与截图一致的清透淡蓝色
                  color: isWeekend
                      ? const Color(0xFF60A5FA)
                      : (isDark
                          ? const Color(0xFF9CA3AF)
                          : const Color(0xFF64748B)),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final info = ChineseCalendarHelper.getInfo(_selectedDate);
    const wk = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    final wkStr = wk[_selectedDate.weekday - 1];

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E24) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? const Color(0xFF2E2E36) : const Color(0xFFE2E8F0),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF2563EB),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              children: [
                Text(
                  '${_selectedDate.day}',
                  style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Colors.white),
                ),
                Text(wkStr,
                    style:
                        const TextStyle(fontSize: 11, color: Colors.white70)),
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
                    color: isDark ? Colors.white : const Color(0xFF0F172A),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '农历 ${info.lunarText}${info.fullFestivalName != null ? " · ${info.fullFestivalName}" : ""}',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: isDark
                        ? const Color(0xFF9CA3AF)
                        : const Color(0xFF64748B),
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
                    ? const Color(0xFF1D4ED8)
                    : const Color(0xFFEA580C),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                info.holidayBadge!,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.bold),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
      dateColor = Colors.white;
      lunarColor = const Color(0xFFE0E7FF);
    } else if (!isCurrentMonth) {
      dateColor = isDark ? const Color(0xFF4B5563) : const Color(0xFF94A3B8);
      lunarColor = isDark ? const Color(0xFF374151) : const Color(0xFFCBD5E1);
    } else if (isWeekend) {
      dateColor = isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB);
      lunarColor = isDark ? const Color(0xFF9CA3AF) : const Color(0xFF64748B);
    } else {
      dateColor = isDark ? Colors.white : const Color(0xFF1E293B);
      lunarColor = isDark ? const Color(0xFF9CA3AF) : const Color(0xFF64748B);
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
          // 选中日期：亮蓝色圆角矩形背景（截图 21 号效果）
          color: isSelected ? const Color(0xFF2563EB) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            // 今天（若未选中）：蓝色外框线（以浮层绘制，不产生内边距挤压内部排版，彻底避免溢出）
            if (isToday && !isSelected)
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: const Color(0xFF3B82F6),
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
                        ? const Color(0xFF1D4ED8) // 休：蓝底
                        : const Color(0xFFEA580C), // 班：橙底
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      info.holidayBadge!,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 8.5,
                        fontWeight: FontWeight.bold,
                        height: 1.0,
                      ),
                    ),
                  ),
                ),
              ),

            // 日期数字、农历文本及日程蓝点指示器
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
                        color: isSelected
                            ? Colors.white
                            : const Color(0xFF3B82F6),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;

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
                  color: isDark
                      ? const Color(0xFF1E1E24)
                      : const Color(0xFFF1F5F9),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.event_available_outlined,
                  size: 32,
                  color: Color(0xFF60A5FA),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '${_selectedDate.month}月${_selectedDate.day}日 暂无日程安排',
                style: TextStyle(
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '点击右上角「+」快速添加，或前往 AI 提取区从通知中一键解析',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: isDark
                      ? const Color(0xFF9CA3AF)
                      : const Color(0xFF64748B),
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
                      foregroundColor: const Color(0xFF60A5FA),
                      side: const BorderSide(color: Color(0xFF3B82F6)),
                    ),
                    onPressed: _showAddEventDialog,
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('添加日程'),
                  ),
                  if (allEvents.isEmpty)
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF2563EB),
                      ),
                      onPressed: _loadSampleSchedules,
                      icon: const Icon(Icons.auto_stories, size: 16),
                      label: const Text('载入示例课表'),
                    )
                  else if (widget.onNavigateToExtractor != null)
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF2563EB),
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
        return _buildNormalCalendarAgendaCard(ev, isDesktop: isDesktop);
      },
    );
  }

  /// 手机与桌面自适应风格日程卡片（移动端契合截图，桌面端展开快捷操作不遮挡）
  Widget _buildNormalCalendarAgendaCard(AgendaEvent event,
      {bool isDesktop = false}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      color: isDark ? const Color(0xFF1E1E22) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: event.syncedToSystemCalendar
              ? (isDark ? const Color(0xFF065F46) : const Color(0xFFBBF7D0))
              : (isDark ? const Color(0xFF2C2C32) : const Color(0xFFE2E8F0)),
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _showEventDetailSheet(event),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 标题行：左侧指示蓝点 + 标题加粗大字 + 桌面端快捷动作
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: const BoxDecoration(
                      color: Color(0xFF3B82F6),
                      shape: BoxShape.circle,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      event.title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                      ),
                    ),
                  ),
                  if (event.syncedToSystemCalendar) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: isDark
                            ? const Color(0xFF064E3B)
                            : const Color(0xFFDCFCE7),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.check,
                              size: 11,
                              color: isDark
                                  ? const Color(0xFF34D399)
                                  : const Color(0xFF16A34A)),
                          const SizedBox(width: 3),
                          Text('已同步日历',
                              style: TextStyle(
                                  color: isDark
                                      ? const Color(0xFF34D399)
                                      : const Color(0xFF16A34A),
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  if (isDesktop) ...[
                    if (!event.syncedToSystemCalendar)
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: () => _writeToCalendar(event),
                        icon: const Icon(Icons.calendar_month,
                            size: 13, color: Color(0xFF60A5FA)),
                        label: const Text('写入系统日历',
                            style: TextStyle(
                                fontSize: 11.5, color: Color(0xFF60A5FA))),
                      ),
                    IconButton(
                      icon: Icon(Icons.edit_outlined,
                          size: 16,
                          color: isDark
                              ? const Color(0xFF9CA3AF)
                              : const Color(0xFF64748B)),
                      tooltip: '查看与编辑详情',
                      constraints:
                          const BoxConstraints(minWidth: 28, minHeight: 28),
                      padding: EdgeInsets.zero,
                      onPressed: () => _showEventDetailSheet(event),
                    ),
                    IconButton(
                      icon: Icon(Icons.delete_outline,
                          size: 16, color: Colors.red.shade400),
                      tooltip: '删除日程',
                      constraints:
                          const BoxConstraints(minWidth: 28, minHeight: 28),
                      padding: EdgeInsets.zero,
                      onPressed: () => _confirmDelete(event),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 5),

              // 时间段：如 10:10-12:00
              Padding(
                padding: const EdgeInsets.only(left: 15),
                child: Row(
                  children: [
                    Icon(Icons.access_time,
                        size: 13,
                        color: isDark
                            ? const Color(0xFF9CA3AF)
                            : const Color(0xFF64748B)),
                    const SizedBox(width: 5),
                    Text(
                      '${_two(event.startTime.hour)}:${_two(event.startTime.minute)}–${_two(event.endTime.hour)}:${_two(event.endTime.minute)}',
                      style: TextStyle(
                        fontSize: 13,
                        color: isDark
                            ? const Color(0xFF9CA3AF)
                            : const Color(0xFF64748B),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),

              // 地点/主讲人说明：如 南校区 南6-A507 季永运
              if (event.location.isNotEmpty) ...[
                const SizedBox(height: 3),
                Padding(
                  padding: const EdgeInsets.only(left: 15),
                  child: Row(
                    children: [
                      Icon(Icons.location_on_outlined,
                          size: 13,
                          color: isDark
                              ? const Color(0xFF9CA3AF)
                              : const Color(0xFF64748B)),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          event.location,
                          style: TextStyle(
                            fontSize: 13,
                            color: isDark
                                ? const Color(0xFF9CA3AF)
                                : const Color(0xFF64748B),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              // 桌面宽屏下展示清单或备注概览
              if (isDesktop && event.checklist.isNotEmpty) ...[
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.only(left: 15),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: event.checklist.map((item) {
                      return Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: isDark
                              ? const Color(0xFF27272A)
                              : const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.check,
                                size: 10, color: Color(0xFF34D399)),
                            const SizedBox(width: 4),
                            Text(item,
                                style: TextStyle(
                                    color: isDark
                                        ? const Color(0xFFD1D5DB)
                                        : const Color(0xFF334155),
                                    fontSize: 11)),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ================= 全部跨度视图 (全量检索列表) =================

  Widget _buildAllEventsListView(List<AgendaEvent> allEvents) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
          color: isDark ? const Color(0xFF27272A) : const Color(0xFFE2E8F0),
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
                      isDraft: false,
                      onSyncCalendar: () => _writeToCalendar(ev),
                      onDelete: () => _confirmDelete(ev),
                      onTap: () => _showEventDetailSheet(ev),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
