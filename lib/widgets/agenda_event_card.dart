import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/agenda_event.dart';
import 'app_toast.dart';

/// 统一模块化日程事项卡片组件
///
/// 具备「我的日程」精简现代视觉风格，支持：
/// 1. 支持单日与跨天日程（开始与结束可以是不同一天）；
/// 2. 点击起止日期分别弹出 DatePicker；
/// 3. 点击起止时间分别弹出 TimePicker，跨午夜时自动智能跨天；
/// 4. 点击标题、地点、备注、待办事项原地切换为文本输入框编辑；
/// 5. 完整的待办事项（Checklist）交互与删除按钮；
/// 6. 通过 [showDate] 控制是否显示日期（首页显示，日历单日视图隐藏）；
/// 7. 静态方法 [showEditModal] 供在弹窗 Modal 中直接调起全量编辑界面；
/// 8. 多端与深浅主题自适应。
class AgendaEventCard extends StatefulWidget {
  final AgendaEvent event;
  final bool isDraft;
  final bool showDate;
  final VoidCallback? onSyncCalendar;
  final VoidCallback? onDelete;
  final VoidCallback? onTap;
  final ValueChanged<AgendaEvent>? onEventChanged;

  const AgendaEventCard({
    super.key,
    required this.event,
    this.isDraft = false,
    this.showDate = true,
    this.onSyncCalendar,
    this.onDelete,
    this.onTap,
    this.onEventChanged,
  });

  /// 判断日程是否为跨天日程（起止年月日不一致）
  static bool isCrossDayEvent(DateTime start, DateTime end) {
    return start.year != end.year ||
        start.month != end.month ||
        start.day != end.day;
  }

  /// 格式化日期与时间全称（例如：10月25日 (周日) 10:10）
  static String formatDateTime(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    const wk = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return '${dt.month}月${dt.day}日 (${wk[dt.weekday - 1]}) ${two(dt.hour)}:${two(dt.minute)}';
  }

  /// 格式化单日期
  static String formatDate(DateTime dt) {
    const wk = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return '${dt.month}月${dt.day}日 (${wk[dt.weekday - 1]})';
  }

  /// 格式化简短日期（如 10月25日）
  static String formatDateShort(DateTime dt) {
    return '${dt.month}月${dt.day}日';
  }

  /// 格式化时分（如 10:00）
  static String formatTime(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.hour)}:${two(dt.minute)}';
  }

  /// 格式化完整跨度文案（支持单日与跨天）
  static String formatSpan(DateTime start, DateTime end, {bool showDate = true}) {
    final cross = isCrossDayEvent(start, end);
    if (!cross) {
      if (showDate) {
        return '${formatDate(start)} ${formatTime(start)} – ${formatTime(end)}';
      } else {
        return '${formatTime(start)} – ${formatTime(end)}';
      }
    } else {
      // 跨天日程：显示起止月日与时分
      return '${formatDateShort(start)} ${formatTime(start)} – ${formatDateShort(end)} ${formatTime(end)}';
    }
  }

  /// 来源标签文案
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
        return 'AI草稿';
    }
  }

  /// 调起全功能日程修改 Modal 弹窗
  static Future<AgendaEvent?> showEditModal(
    BuildContext context, {
    required AgendaEvent event,
    bool isDraft = false,
    bool showDate = true,
    VoidCallback? onSyncCalendar,
    VoidCallback? onDelete,
    ValueChanged<AgendaEvent>? onEventChanged,
  }) {
    return showModalBottomSheet<AgendaEvent>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _AgendaEditBottomSheet(
        initialEvent: event,
        isDraft: isDraft,
        showDate: showDate,
        onSyncCalendar: onSyncCalendar,
        onDelete: onDelete,
        onEventChanged: onEventChanged,
      ),
    );
  }

  @override
  State<AgendaEventCard> createState() => _AgendaEventCardState();
}

class _AgendaEventCardState extends State<AgendaEventCard> {
  late AgendaEvent _currentEvent;

  // 当前正在编辑的字段: 'title' | 'location' | 'description' | 'add_checklist' | 'checklist_$idx'
  String? _editingField;
  late final TextEditingController _editController;
  late final FocusNode _editFocusNode;

  bool get _isCrossDay => AgendaEventCard.isCrossDayEvent(
        _currentEvent.startTime,
        _currentEvent.endTime,
      );

  @override
  void initState() {
    super.initState();
    _currentEvent = widget.event;
    _editController = TextEditingController();
    _editFocusNode = FocusNode();
  }

  @override
  void didUpdateWidget(covariant AgendaEventCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.event != widget.event) {
      _currentEvent = widget.event;
    }
  }

  @override
  void dispose() {
    _editController.dispose();
    _editFocusNode.dispose();
    super.dispose();
  }

  // ================= 编辑控制动作 =================

  void _startEditing(String field, String initialText) {
    setState(() {
      _editingField = field;
      _editController.text = initialText;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _editFocusNode.requestFocus();
      }
    });
  }

  void _cancelEditing() {
    setState(() {
      _editingField = null;
    });
  }

  void _saveEditing() {
    if (_editingField == null) return;
    final val = _editController.text.trim();
    late AgendaEvent updated;

    if (_editingField == 'title') {
      if (val.isEmpty) {
        _cancelEditing();
        return;
      }
      updated = _currentEvent.copyWith(title: val);
    } else if (_editingField == 'location') {
      updated = _currentEvent.copyWith(location: val);
    } else if (_editingField == 'description') {
      updated = _currentEvent.copyWith(description: val);
    } else if (_editingField == 'add_checklist') {
      if (val.isNotEmpty) {
        final newList = List<String>.from(_currentEvent.checklist)..add(val);
        updated = _currentEvent.copyWith(checklist: newList);
      } else {
        _cancelEditing();
        return;
      }
    } else if (_editingField!.startsWith('checklist_')) {
      final idx = int.tryParse(_editingField!.substring('checklist_'.length));
      if (idx != null && idx >= 0 && idx < _currentEvent.checklist.length) {
        final newList = List<String>.from(_currentEvent.checklist);
        if (val.isNotEmpty) {
          newList[idx] = val;
        } else {
          newList.removeAt(idx);
        }
        updated = _currentEvent.copyWith(checklist: newList);
      } else {
        _cancelEditing();
        return;
      }
    } else {
      _cancelEditing();
      return;
    }

    setState(() {
      _currentEvent = updated;
      _editingField = null;
    });
    widget.onEventChanged?.call(updated);
  }

  void _removeChecklistItem(int idx) {
    if (idx >= 0 && idx < _currentEvent.checklist.length) {
      final newList = List<String>.from(_currentEvent.checklist)..removeAt(idx);
      final updated = _currentEvent.copyWith(checklist: newList);
      setState(() {
        _currentEvent = updated;
        if (_editingField == 'checklist_$idx') {
          _editingField = null;
        }
      });
      widget.onEventChanged?.call(updated);
    }
  }

  // ================= 日期与时间选择器动作 =================

  /// 选择开始日期（兼备单日修改与跨天联动）
  Future<void> _pickStartDate(BuildContext context) async {
    final initial = _currentEvent.startTime;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
    );

    if (picked != null) {
      final oldStart = _currentEvent.startTime;
      final oldEnd = _currentEvent.endTime;
      final duration = oldEnd.difference(oldStart);

      final newStart = DateTime(
        picked.year,
        picked.month,
        picked.day,
        oldStart.hour,
        oldStart.minute,
      );

      // 保持原有起止跨度不变
      var newEnd = newStart.add(duration);
      if (newEnd.isBefore(newStart)) {
        newEnd = newStart.add(const Duration(hours: 1));
      }

      final updated = _currentEvent.copyWith(
        startTime: newStart,
        endTime: newEnd,
      );

      setState(() {
        _currentEvent = updated;
      });
      widget.onEventChanged?.call(updated);
    }
  }

  /// 选择结束日期（实现跨天修改）
  Future<void> _pickEndDate(BuildContext context) async {
    final start = _currentEvent.startTime;
    final initial = _currentEvent.endTime.isBefore(start)
        ? start
        : _currentEvent.endTime;

    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(start.year, start.month, start.day),
      lastDate: DateTime(2035),
    );

    if (picked != null) {
      final oldEnd = _currentEvent.endTime;
      var newEnd = DateTime(
        picked.year,
        picked.month,
        picked.day,
        oldEnd.hour,
        oldEnd.minute,
      );

      // 如果选为同一天且时分早于开始时间，自动向后顺延1小时
      if (newEnd.isBefore(start)) {
        newEnd = start.add(const Duration(hours: 1));
      }

      final updated = _currentEvent.copyWith(
        endTime: newEnd,
      );

      setState(() {
        _currentEvent = updated;
      });
      widget.onEventChanged?.call(updated);
    }
  }

  Future<void> _pickStartTime(BuildContext context) async {
    final initial = _currentEvent.startTime;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );

    if (picked != null) {
      final oldStart = _currentEvent.startTime;
      final newStart = DateTime(
        oldStart.year,
        oldStart.month,
        oldStart.day,
        picked.hour,
        picked.minute,
      );
      var newEnd = _currentEvent.endTime;
      if (newEnd.isBefore(newStart)) {
        newEnd = newStart.add(const Duration(hours: 1));
      }

      final updated = _currentEvent.copyWith(
        startTime: newStart,
        endTime: newEnd,
      );

      setState(() {
        _currentEvent = updated;
      });
      widget.onEventChanged?.call(updated);
    }
  }

  Future<void> _pickEndTime(BuildContext context) async {
    final initial = _currentEvent.endTime;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );

    if (picked != null) {
      final oldEnd = _currentEvent.endTime;
      final oldStart = _currentEvent.startTime;
      var newEnd = DateTime(
        oldEnd.year,
        oldEnd.month,
        oldEnd.day,
        picked.hour,
        picked.minute,
      );

      // 智能跨天判断：
      // 如果结束日期与开始日期为同一天，但用户选择的时分早于开始时间（例如开始 22:00，选择 02:00）
      // 则智能跨天，自动将结束日期顺延至次日！
      if (!_isCrossDay && newEnd.isBefore(oldStart)) {
        newEnd = DateTime(
          oldStart.year,
          oldStart.month,
          oldStart.day + 1,
          picked.hour,
          picked.minute,
        );
      } else if (newEnd.isBefore(oldStart)) {
        newEnd = oldStart.add(const Duration(hours: 1));
      }

      final updated = _currentEvent.copyWith(
        endTime: newEnd,
      );

      setState(() {
        _currentEvent = updated;
      });
      widget.onEventChanged?.call(updated);
    }
  }

  // ================= 视图构建 =================

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      color: isDark ? const Color(0xFF1E1E22) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: _currentEvent.syncedToSystemCalendar
              ? (isDark ? const Color(0xFF065F46) : const Color(0xFFBBF7D0))
              : (isDark ? const Color(0xFF2C2C32) : const Color(0xFFE2E8F0)),
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1. 标题行：指示圆点 + 标题（可就地编辑）+ 状态 Chip + 删除按钮
              _buildTitleRow(isDark),

              const SizedBox(height: 8),

              // 2. 时间与日期行：支持单日与跨天分别选择
              _buildDateTimeRow(context, isDark),

              // 3. 地点行（可就地编辑）
              _buildLocationRow(isDark),

              // 4. 描述说明（可就地编辑）
              _buildDescriptionRow(isDark),

              const SizedBox(height: 8),

              // 5. 待办事项清单（Checklist，支持就地编辑、添加、删除）
              _buildChecklistSection(isDark),

              const SizedBox(height: 10),
              Divider(
                height: 1,
                thickness: 0.5,
                color:
                    isDark ? const Color(0xFF27272A) : const Color(0xFFF1F5F9),
              ),
              const SizedBox(height: 8),

              // 6. 底部状态与操作栏（提前提醒、.ics导出、写入/同步日历）
              _buildFooterRow(context, isDark),
            ],
          ),
        ),
      ),
    );
  }

  /// 标题行
  Widget _buildTitleRow(bool isDark) {
    if (_editingField == 'title') {
      return Row(
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
            child: TextField(
              controller: _editController,
              focusNode: _editFocusNode,
              autofocus: true,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : const Color(0xFF0F172A),
              ),
              decoration: InputDecoration(
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                hintText: '输入日程标题',
                hintStyle: TextStyle(
                  color:
                      isDark ? const Color(0xFF6B7280) : const Color(0xFF94A3B8),
                  fontSize: 14,
                ),
                filled: true,
                fillColor:
                    isDark ? const Color(0xFF27272A) : const Color(0xFFF8FAFC),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFF3B82F6)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide:
                      const BorderSide(color: Color(0xFF3B82F6), width: 1.5),
                ),
              ),
              onSubmitted: (_) => _saveEditing(),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.check, size: 18, color: Color(0xFF10B981)),
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            padding: EdgeInsets.zero,
            tooltip: '保存标题',
            onPressed: _saveEditing,
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18, color: Color(0xFF6B7280)),
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            padding: EdgeInsets.zero,
            tooltip: '取消',
            onPressed: _cancelEditing,
          ),
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // 指示蓝点
        Container(
          width: 7,
          height: 7,
          margin: const EdgeInsets.only(right: 8),
          decoration: BoxDecoration(
            color: widget.isDraft
                ? const Color(0xFF3B82F6)
                : (_currentEvent.syncedToSystemCalendar
                    ? const Color(0xFF10B981)
                    : const Color(0xFF3B82F6)),
            shape: BoxShape.circle,
          ),
        ),

        // 标题文本（点击就地编辑）
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => _startEditing('title', _currentEvent.title),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      _currentEvent.title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                      ),
                    ),
                  ),
                  const SizedBox(width: 5),
                  Icon(
                    Icons.edit_outlined,
                    size: 13,
                    color: isDark
                        ? const Color(0xFF6B7280)
                        : const Color(0xFF94A3B8),
                  ),
                ],
              ),
            ),
          ),
        ),

        const SizedBox(width: 6),

        // 状态 Chip
        if (_currentEvent.syncedToSystemCalendar) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF064E3B) : const Color(0xFFDCFCE7),
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
          const SizedBox(width: 4),
        ] else if (widget.isDraft) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E293B) : const Color(0xFFEFF6FF),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color:
                    isDark ? const Color(0xFF3B82F6) : const Color(0xFFBFDBFE),
                width: 0.5,
              ),
            ),
            child: Text(
              AgendaEventCard.getSourceLabel(_currentEvent.sourceType),
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color:
                    isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB),
              ),
            ),
          ),
          const SizedBox(width: 4),
        ],

        // 删除按钮
        if (widget.onDelete != null)
          IconButton(
            icon: Icon(
              Icons.delete_outline,
              size: 18,
              color: Colors.red.shade400,
            ),
            tooltip: widget.isDraft ? '放弃此草稿' : '删除日程',
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            padding: EdgeInsets.zero,
            onPressed: widget.onDelete,
          ),
      ],
    );
  }

  /// 日期与时间行（支持跨天）
  Widget _buildDateTimeRow(BuildContext context, bool isDark) {
    final isCross = _isCrossDay;
    final diffDays = _currentEvent.endTime
        .difference(_currentEvent.startTime)
        .inDays;

    return Padding(
      padding: const EdgeInsets.only(left: 15),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 6,
        children: [
          // 开始日期选择胶囊
          if (widget.showDate || isCross)
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => _pickStartDate(context),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF27272A)
                      : const Color(0xFFEFF6FF),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: isDark
                        ? const Color(0xFF3F3F46)
                        : const Color(0xFFBFDBFE),
                    width: 0.8,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.calendar_today_outlined,
                      size: 12,
                      color: isDark
                          ? const Color(0xFF60A5FA)
                          : const Color(0xFF2563EB),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      AgendaEventCard.formatDate(_currentEvent.startTime),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: isDark
                            ? const Color(0xFF93C5FD)
                            : const Color(0xFF1D4ED8),
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      Icons.arrow_drop_down,
                      size: 14,
                      color: isDark
                          ? const Color(0xFF60A5FA)
                          : const Color(0xFF2563EB),
                    ),
                  ],
                ),
              ),
            ),

          // 开始时间胶囊
          _buildTimeCapsule(
            timeText: AgendaEventCard.formatTime(_currentEvent.startTime),
            onTap: () => _pickStartTime(context),
            isDark: isDark,
          ),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Text(
              isCross ? '至' : '–',
              style: TextStyle(
                fontSize: 13,
                color: isDark
                    ? const Color(0xFF9CA3AF)
                    : const Color(0xFF64748B),
                fontWeight: FontWeight.bold,
              ),
            ),
          ),

          // 跨天时显示的结束日期胶囊
          if (isCross)
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => _pickEndDate(context),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF27272A)
                      : const Color(0xFFEFF6FF),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: isDark
                        ? const Color(0xFF3F3F46)
                        : const Color(0xFFBFDBFE),
                    width: 0.8,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.event_repeat_outlined,
                      size: 12,
                      color: isDark
                          ? const Color(0xFF60A5FA)
                          : const Color(0xFF2563EB),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      AgendaEventCard.formatDate(_currentEvent.endTime),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: isDark
                            ? const Color(0xFF93C5FD)
                            : const Color(0xFF1D4ED8),
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      Icons.arrow_drop_down,
                      size: 14,
                      color: isDark
                          ? const Color(0xFF60A5FA)
                          : const Color(0xFF2563EB),
                    ),
                  ],
                ),
              ),
            ),

          // 结束时间胶囊
          _buildTimeCapsule(
            timeText: AgendaEventCard.formatTime(_currentEvent.endTime),
            onTap: () => _pickEndTime(context),
            isDark: isDark,
          ),

          // 跨天指示徽标或添加跨天快捷按钮
          if (isCross)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color:
                    isDark ? const Color(0xFF312E81) : const Color(0xFFEEF2FF),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color:
                      isDark ? const Color(0xFF6366F1) : const Color(0xFFC7D2FE),
                  width: 0.6,
                ),
              ),
              child: Text(
                diffDays > 0 ? '跨 $diffDays 天' : '跨天',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color:
                      isDark ? const Color(0xFFA5B4FC) : const Color(0xFF4F46E5),
                ),
              ),
            )
          else
            InkWell(
              borderRadius: BorderRadius.circular(4),
              onTap: () => _pickEndDate(context),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: isDark
                        ? const Color(0xFF3F3F46)
                        : const Color(0xFFCBD5E1),
                    width: 0.6,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.add,
                      size: 10,
                      color: isDark
                          ? const Color(0xFF9CA3AF)
                          : const Color(0xFF64748B),
                    ),
                    const SizedBox(width: 2),
                    Text(
                      '设为跨天',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: isDark
                            ? const Color(0xFF9CA3AF)
                            : const Color(0xFF64748B),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 单独的时间展示胶囊
  Widget _buildTimeCapsule({
    required String timeText,
    required VoidCallback onTap,
    required bool isDark,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF27272A) : const Color(0xFFF1F5F9),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isDark ? const Color(0xFF3F3F46) : const Color(0xFFE2E8F0),
            width: 0.8,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.access_time,
              size: 12,
              color: isDark ? const Color(0xFF9CA3AF) : const Color(0xFF64748B),
            ),
            const SizedBox(width: 3),
            Text(
              timeText,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white : const Color(0xFF0F172A),
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              Icons.arrow_drop_down,
              size: 13,
              color: isDark ? const Color(0xFF9CA3AF) : const Color(0xFF64748B),
            ),
          ],
        ),
      ),
    );
  }

  /// 地点行
  Widget _buildLocationRow(bool isDark) {
    if (_editingField == 'location') {
      return Padding(
        padding: const EdgeInsets.only(left: 15, top: 6),
        child: Row(
          children: [
            Icon(Icons.location_on_outlined,
                size: 14,
                color:
                    isDark ? const Color(0xFF9CA3AF) : const Color(0xFF64748B)),
            const SizedBox(width: 6),
            Expanded(
              child: TextField(
                controller: _editController,
                focusNode: _editFocusNode,
                autofocus: true,
                style: TextStyle(
                  fontSize: 12.5,
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                ),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  hintText: '输入地点 / 线上会议号',
                  hintStyle: TextStyle(
                    color: isDark
                        ? const Color(0xFF6B7280)
                        : const Color(0xFF94A3B8),
                    fontSize: 12,
                  ),
                  filled: true,
                  fillColor:
                      isDark ? const Color(0xFF27272A) : const Color(0xFFF8FAFC),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: const BorderSide(color: Color(0xFF3B82F6)),
                  ),
                ),
                onSubmitted: (_) => _saveEditing(),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.check, size: 16, color: Color(0xFF10B981)),
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              padding: EdgeInsets.zero,
              onPressed: _saveEditing,
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 16, color: Color(0xFF6B7280)),
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              padding: EdgeInsets.zero,
              onPressed: _cancelEditing,
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(left: 15, top: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => _startEditing('location', _currentEvent.location),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Icon(Icons.location_on_outlined,
                  size: 13,
                  color: isDark
                      ? const Color(0xFF9CA3AF)
                      : const Color(0xFF64748B)),
              const SizedBox(width: 5),
              Expanded(
                child: _currentEvent.location.isNotEmpty
                    ? Text(
                        _currentEvent.location,
                        style: TextStyle(
                          fontSize: 13,
                          color: isDark
                              ? const Color(0xFF9CA3AF)
                              : const Color(0xFF64748B),
                        ),
                      )
                    : Text(
                        '+ 点击添加地点 / 会议号',
                        style: TextStyle(
                          fontSize: 12,
                          fontStyle: FontStyle.italic,
                          color: isDark
                              ? const Color(0xFF60A5FA)
                              : const Color(0xFF2563EB),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 备注描述行
  Widget _buildDescriptionRow(bool isDark) {
    if (_editingField == 'description') {
      return Padding(
        padding: const EdgeInsets.only(left: 15, top: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.notes_outlined,
                size: 14,
                color:
                    isDark ? const Color(0xFF9CA3AF) : const Color(0xFF64748B)),
            const SizedBox(width: 6),
            Expanded(
              child: TextField(
                controller: _editController,
                focusNode: _editFocusNode,
                autofocus: true,
                maxLines: 2,
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                ),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  hintText: '输入日程备注说明',
                  hintStyle: TextStyle(
                    color: isDark
                        ? const Color(0xFF6B7280)
                        : const Color(0xFF94A3B8),
                    fontSize: 12,
                  ),
                  filled: true,
                  fillColor:
                      isDark ? const Color(0xFF27272A) : const Color(0xFFF8FAFC),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: const BorderSide(color: Color(0xFF3B82F6)),
                  ),
                ),
              ),
            ),
            Column(
              children: [
                IconButton(
                  icon: const Icon(Icons.check,
                      size: 16, color: Color(0xFF10B981)),
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  padding: EdgeInsets.zero,
                  onPressed: _saveEditing,
                ),
                IconButton(
                  icon: const Icon(Icons.close,
                      size: 16, color: Color(0xFF6B7280)),
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  padding: EdgeInsets.zero,
                  onPressed: _cancelEditing,
                ),
              ],
            )
          ],
        ),
      );
    }

    if (_currentEvent.description.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(left: 15, top: 2),
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: () => _startEditing('description', ''),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Icon(Icons.notes_outlined,
                    size: 13,
                    color: isDark
                        ? const Color(0xFF6B7280)
                        : const Color(0xFF94A3B8)),
                const SizedBox(width: 5),
                Text(
                  '+ 点击添加日程备注说明',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: isDark
                        ? const Color(0xFF6B7280)
                        : const Color(0xFF94A3B8),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(left: 15, top: 3),
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () => _startEditing('description', _currentEvent.description),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.notes_outlined,
                  size: 13,
                  color: isDark
                      ? const Color(0xFF9CA3AF)
                      : const Color(0xFF64748B)),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  _currentEvent.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark
                        ? const Color(0xFF9CA3AF)
                        : const Color(0xFF64748B),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 待办事项（Checklist）区域
  Widget _buildChecklistSection(bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(left: 15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 待办标题与添加按钮
          Row(
            children: [
              Icon(Icons.checklist,
                  size: 13,
                  color: isDark
                      ? const Color(0xFF60A5FA)
                      : const Color(0xFF2563EB)),
              const SizedBox(width: 5),
              Text(
                '待办事项 (${_currentEvent.checklist.length})',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isDark
                      ? const Color(0xFFD1D5DB)
                      : const Color(0xFF334155),
                ),
              ),
              const Spacer(),
              if (_editingField != 'add_checklist')
                InkWell(
                  borderRadius: BorderRadius.circular(4),
                  onTap: () => _startEditing('add_checklist', ''),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.add,
                            size: 13,
                            color: isDark
                                ? const Color(0xFF60A5FA)
                                : const Color(0xFF2563EB)),
                        const SizedBox(width: 2),
                        Text(
                          '添加待办',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: isDark
                                ? const Color(0xFF60A5FA)
                                : const Color(0xFF2563EB),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),

          const SizedBox(height: 5),

          // 新增待办事项输入行
          if (_editingField == 'add_checklist') ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _editController,
                      focusNode: _editFocusNode,
                      autofocus: true,
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 5),
                        hintText: '输入新的待办事项内容',
                        hintStyle: TextStyle(
                          color: isDark
                              ? const Color(0xFF6B7280)
                              : const Color(0xFF94A3B8),
                          fontSize: 11.5,
                        ),
                        filled: true,
                        fillColor: isDark
                            ? const Color(0xFF27272A)
                            : const Color(0xFFF8FAFC),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(6),
                          borderSide:
                              const BorderSide(color: Color(0xFF3B82F6)),
                        ),
                      ),
                      onSubmitted: (_) => _saveEditing(),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.check,
                        size: 16, color: Color(0xFF10B981)),
                    constraints:
                        const BoxConstraints(minWidth: 28, minHeight: 28),
                    padding: EdgeInsets.zero,
                    onPressed: _saveEditing,
                  ),
                  IconButton(
                    icon: const Icon(Icons.close,
                        size: 16, color: Color(0xFF6B7280)),
                    constraints:
                        const BoxConstraints(minWidth: 28, minHeight: 28),
                    padding: EdgeInsets.zero,
                    onPressed: _cancelEditing,
                  ),
                ],
              ),
            ),
          ],

          // 待办事项胶囊列表
          if (_currentEvent.checklist.isEmpty &&
              _editingField != 'add_checklist')
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 2),
              child: Text(
                '暂无待办项目，可点击右侧「添加待办」扩充',
                style: TextStyle(
                  fontSize: 11.5,
                  color: isDark
                      ? const Color(0xFF6B7280)
                      : const Color(0xFF94A3B8),
                ),
              ),
            )
          else
            Wrap(
              spacing: 6,
              runSpacing: 5,
              children: [
                for (int i = 0; i < _currentEvent.checklist.length; i++)
                  _buildChecklistItem(i, _currentEvent.checklist[i], isDark),
              ],
            ),
        ],
      ),
    );
  }

  /// 单个待办事项项
  Widget _buildChecklistItem(int idx, String item, bool isDark) {
    final isEditingThis = _editingField == 'checklist_$idx';

    if (isEditingThis) {
      return Container(
        width: 220,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF27272A) : const Color(0xFFF1F5F9),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFF3B82F6)),
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _editController,
                focusNode: _editFocusNode,
                autofocus: true,
                style: TextStyle(
                  fontSize: 11.5,
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                ),
                decoration: const InputDecoration(
                  isDense: true,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  border: InputBorder.none,
                ),
                onSubmitted: (_) => _saveEditing(),
              ),
            ),
            InkWell(
              onTap: _saveEditing,
              child: const Icon(Icons.check, size: 14, color: Color(0xFF10B981)),
            ),
            const SizedBox(width: 4),
            InkWell(
              onTap: _cancelEditing,
              child: const Icon(Icons.close, size: 14, color: Color(0xFF6B7280)),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF27272A) : const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check, size: 11, color: Color(0xFF34D399)),
          const SizedBox(width: 4),
          InkWell(
            onTap: () => _startEditing('checklist_$idx', item),
            child: Text(
              item,
              style: TextStyle(
                fontSize: 11.5,
                color:
                    isDark ? const Color(0xFFD1D5DB) : const Color(0xFF334155),
              ),
            ),
          ),
          const SizedBox(width: 4),
          InkWell(
            onTap: () => _removeChecklistItem(idx),
            child: Icon(
              Icons.close,
              size: 12,
              color: isDark ? const Color(0xFF9CA3AF) : const Color(0xFF64748B),
            ),
          ),
        ],
      ),
    );
  }

  /// 底部状态与操作栏
  Widget _buildFooterRow(BuildContext context, bool isDark) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // 提前提醒时间提示
        Text(
          '提前 ${_currentEvent.reminderMinutes} 分钟提醒',
          style: TextStyle(
            fontSize: 11,
            color: isDark ? const Color(0xFF64748B) : Colors.grey.shade500,
          ),
        ),

        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 复制 iCalendar (.ics) 代码
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.copy_all, size: 16),
              tooltip: '复制 iCalendar (.ics) 代码',
              onPressed: () {
                Clipboard.setData(
                    ClipboardData(text: _currentEvent.toIcsString()));
                AppToast.show(context, '已复制 iCalendar (.ics) 日历内容至剪贴板');
              },
            ),

            // 写入系统日历或确认草稿按钮
            if (widget.onSyncCalendar != null) ...[
              const SizedBox(width: 4),
              FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                  textStyle: const TextStyle(fontSize: 12),
                ),
                onPressed: widget.onSyncCalendar,
                icon: Icon(
                  _currentEvent.syncedToSystemCalendar
                      ? Icons.done
                      : Icons.calendar_today,
                  size: 14,
                ),
                label: Text(
                  _currentEvent.syncedToSystemCalendar
                      ? '重新同步日历'
                      : (widget.isDraft ? '确认写入日历' : '写入系统日历'),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// 精简轻量日程卡片组件（CompactAgendaCard）
///
/// 相比于全量编辑卡片，具备显著精简的纵向高度，节省页面空间：
/// 1. 包含核心要素：事件（标题）、时间（支持跨天）、地点、须知（备注/待办清单摘要）；
/// 2. 元素为轻量展示态，无需就地变输入框，保持界面清爽整洁；
/// 3. 点击卡片或右上方编辑按钮直接弹出包含全功能编辑界面的 Modal 弹窗；
/// 4. 紧凑集成状态徽标、日历写入同步以及删除操作。
class CompactAgendaCard extends StatelessWidget {
  final AgendaEvent event;
  final bool isDraft;
  final bool showDate;
  final bool isEditing;
  final VoidCallback? onSyncCalendar;
  final VoidCallback? onDelete;
  final VoidCallback? onTap;
  final VoidCallback? onEdit;
  final ValueChanged<AgendaEvent>? onEventChanged;

  const CompactAgendaCard({
    super.key,
    required this.event,
    this.isDraft = false,
    this.showDate = true,
    this.isEditing = false,
    this.onSyncCalendar,
    this.onDelete,
    this.onTap,
    this.onEdit,
    this.onEventChanged,
  });

  bool get _isCrossDay => AgendaEventCard.isCrossDayEvent(
        event.startTime,
        event.endTime,
      );

  void _openEditModal(BuildContext context) {
    AgendaEventCard.showEditModal(
      context,
      event: event,
      isDraft: isDraft,
      showDate: showDate,
      onSyncCalendar: onSyncCalendar,
      onDelete: onDelete,
      onEventChanged: onEventChanged,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isCross = _isCrossDay;

    // 格式化时间显示
    final timeStr = isCross
        ? '${AgendaEventCard.formatDateShort(event.startTime)} ${AgendaEventCard.formatTime(event.startTime)} – ${AgendaEventCard.formatDateShort(event.endTime)} ${AgendaEventCard.formatTime(event.endTime)}'
        : (showDate
            ? '${AgendaEventCard.formatDate(event.startTime)} ${AgendaEventCard.formatTime(event.startTime)} – ${AgendaEventCard.formatTime(event.endTime)}'
            : '${AgendaEventCard.formatTime(event.startTime)} – ${AgendaEventCard.formatTime(event.endTime)}');

    // 汇总须知内容（结合备注说明与待办事项清单）
    final hasChecklist = event.checklist.isNotEmpty;
    final hasDescription = event.description.isNotEmpty;
    String noticeText = '';
    if (hasDescription && hasChecklist) {
      noticeText = '${event.description} · ${event.checklist.length}项待办';
    } else if (hasDescription) {
      noticeText = event.description;
    } else if (hasChecklist) {
      noticeText = '待办(${event.checklist.length}): ${event.checklist.join('、')}';
    }

    final primaryColor = Theme.of(context).colorScheme.primary;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: isEditing
          ? primaryColor.withValues(alpha: 0.08)
          : (isDark ? const Color(0xFF1E1E22) : Colors.white),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: isEditing
              ? primaryColor
              : (event.syncedToSystemCalendar
                  ? (isDark ? const Color(0xFF065F46) : const Color(0xFFBBF7D0))
                  : (isDark ? const Color(0xFF2C2C32) : const Color(0xFFE2E8F0))),
          width: isEditing ? 1.2 : 1.0,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap ?? () => _openEditModal(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 1. 首行：圆点 + 标题（事件）+ 状态 Chip + 修改按钮 + 删除按钮
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      color: event.syncedToSystemCalendar
                          ? const Color(0xFF10B981)
                          : const Color(0xFF3B82F6),
                      shape: BoxShape.circle,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      event.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.bold,
                        color: isEditing
                            ? primaryColor
                            : (isDark ? Colors.white : const Color(0xFF0F172A)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),

                  // 同步或草稿来源标签
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
                      child: Text(
                        '已同步',
                        style: TextStyle(
                          color: isDark
                              ? const Color(0xFF34D399)
                              : const Color(0xFF16A34A),
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                  ] else if (isDraft) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: isDark
                            ? const Color(0xFF1E293B)
                            : const Color(0xFFEFF6FF),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: isDark
                              ? const Color(0xFF3B82F6)
                              : const Color(0xFFBFDBFE),
                          width: 0.5,
                        ),
                      ),
                      child: Text(
                        AgendaEventCard.getSourceLabel(event.sourceType),
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: isDark
                              ? const Color(0xFF60A5FA)
                              : const Color(0xFF2563EB),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],

                  // 点击编辑小图标
                  IconButton(
                    icon: Icon(
                      Icons.edit_note_outlined,
                      size: 18,
                      color: isEditing
                          ? primaryColor
                          : (isDark
                              ? const Color(0xFF9CA3AF)
                              : const Color(0xFF64748B)),
                    ),
                    tooltip: '修改日程详情',
                    constraints:
                        const BoxConstraints(minWidth: 26, minHeight: 26),
                    padding: EdgeInsets.zero,
                    onPressed: onEdit ?? () => _openEditModal(context),
                  ),

                  // 删除按钮
                  if (onDelete != null)
                    IconButton(
                      icon: Icon(
                        Icons.delete_outline,
                        size: 17,
                        color: Colors.red.shade400,
                      ),
                      tooltip: isDraft ? '放弃此草稿' : '删除日程',
                      constraints:
                          const BoxConstraints(minWidth: 26, minHeight: 26),
                      padding: EdgeInsets.zero,
                      onPressed: onDelete,
                    ),
                ],
              ),

              const SizedBox(height: 6),

              // 2. 时间行（支持跨天展示）
              Padding(
                padding: const EdgeInsets.only(left: 15),
                child: Row(
                  children: [
                    Icon(
                      Icons.access_time_rounded,
                      size: 12.5,
                      color: isDark
                          ? const Color(0xFF60A5FA)
                          : const Color(0xFF2563EB),
                    ),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        timeStr,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: isDark
                              ? const Color(0xFFD1D5DB)
                              : const Color(0xFF334155),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isCross) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1.5),
                        decoration: BoxDecoration(
                          color: isDark
                              ? const Color(0xFF312E81)
                              : const Color(0xFFEEF2FF),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '跨天',
                          style: TextStyle(
                            fontSize: 9.5,
                            fontWeight: FontWeight.bold,
                            color: isDark
                                ? const Color(0xFFA5B4FC)
                                : const Color(0xFF4F46E5),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              // 3. 地点行（地点不为空时轻量显示）
              if (event.location.isNotEmpty) ...[
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.only(left: 15),
                  child: Row(
                    children: [
                      Icon(
                        Icons.location_on_outlined,
                        size: 12.5,
                        color: isDark
                            ? const Color(0xFF9CA3AF)
                            : const Color(0xFF64748B),
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          event.location,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
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

              // 4. 须知行（包含备注与待办事项摘要，轻量展示）
              if (noticeText.isNotEmpty) ...[
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.only(left: 15),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.info_outline_rounded,
                        size: 12.5,
                        color: isDark
                            ? const Color(0xFF9CA3AF)
                            : const Color(0xFF64748B),
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          noticeText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
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

              // 5. 底部紧凑操作栏（写入/同步快捷按钮）
              if (onSyncCalendar != null) ...[
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.only(left: 15),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '提前 ${event.reminderMinutes} 分钟提醒',
                        style: TextStyle(
                          fontSize: 10.5,
                          color: isDark
                              ? const Color(0xFF64748B)
                              : Colors.grey.shade500,
                        ),
                      ),
                      InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: onSyncCalendar,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                event.syncedToSystemCalendar
                                    ? Icons.check
                                    : Icons.calendar_today,
                                size: 12,
                                color: event.syncedToSystemCalendar
                                    ? const Color(0xFF10B981)
                                    : (isDark
                                        ? const Color(0xFF60A5FA)
                                        : const Color(0xFF2563EB)),
                              ),
                              const SizedBox(width: 3),
                              Text(
                                event.syncedToSystemCalendar
                                    ? '重新同步'
                                    : (isDraft ? '确认写入日历' : '写入系统日历'),
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: event.syncedToSystemCalendar
                                      ? const Color(0xFF10B981)
                                      : (isDark
                                          ? const Color(0xFF60A5FA)
                                          : const Color(0xFF2563EB)),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 兼容别名
typedef CompactAgendaEventCard = CompactAgendaCard;

/// 点击精简卡片弹出的修改详情 Modal 底部抽屉
class _AgendaEditBottomSheet extends StatefulWidget {
  final AgendaEvent initialEvent;
  final bool isDraft;
  final bool showDate;
  final VoidCallback? onSyncCalendar;
  final VoidCallback? onDelete;
  final ValueChanged<AgendaEvent>? onEventChanged;

  const _AgendaEditBottomSheet({
    required this.initialEvent,
    this.isDraft = false,
    this.showDate = true,
    this.onSyncCalendar,
    this.onDelete,
    this.onEventChanged,
  });

  @override
  State<_AgendaEditBottomSheet> createState() => _AgendaEditBottomSheetState();
}

class _AgendaEditBottomSheetState extends State<_AgendaEditBottomSheet> {
  late AgendaEvent _event;

  @override
  void initState() {
    super.initState();
    _event = widget.initialEvent;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.88,
      ),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E22) : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 拖动把手
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  margin: const EdgeInsets.only(top: 10, bottom: 8),
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF3F3F46)
                        : const Color(0xFFCBD5E1),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

              // Modal 头部标题栏
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(
                  children: [
                    Text(
                      widget.isDraft ? '修改草稿日程' : '修改日程详情',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                      ),
                    ),
                    const Spacer(),
                    TextButton(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                      ),
                      onPressed: () => Navigator.of(context).pop(_event),
                      child: const Text('完成',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ),

              const Divider(height: 1, thickness: 0.5),

              // 内部承载 AgendaEventCard（全量可编辑界面）
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  child: AgendaEventCard(
                    event: _event,
                    isDraft: widget.isDraft,
                    showDate: widget.showDate,
                    onSyncCalendar: widget.onSyncCalendar,
                    onDelete: () {
                      widget.onDelete?.call();
                      Navigator.of(context).pop();
                    },
                    onEventChanged: (updated) {
                      setState(() {
                        _event = updated;
                      });
                      widget.onEventChanged?.call(updated);
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
