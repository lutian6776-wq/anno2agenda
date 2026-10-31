import 'package:flutter/material.dart';
import '../repositories/agenda_repository.dart';
import '../services/app_settings_service.dart';
import '../services/calendar_sync_service.dart';
import '../theme/app_theme.dart';

/// 系统日历双向同步中心核心面板组件 (CalendarSyncPanel)
///
/// 既可作为桌面端右侧滑入抽屉 (Right Slide Drawer) 的内容视图，
/// 亦可供移动端从屏幕下方滑出底部抽屉 (Bottom Sheet)，
/// 或作为 Dialog 弹窗展示。
class CalendarSyncPanel extends StatefulWidget {
  final VoidCallback? onClose;
  final VoidCallback? onSyncCompleted;
  final bool isDrawerMode;
  final bool showHeader;

  const CalendarSyncPanel({
    super.key,
    this.onClose,
    this.onSyncCompleted,
    this.isDrawerMode = true,
    this.showHeader = true,
  });

  /// 供移动端从下方滑出底部抽屉 (Bottom Sheet)
  static Future<void> showBottomSheet(
    BuildContext context, {
    VoidCallback? onSyncCompleted,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(ctx).viewInsets.bottom,
        ),
        child: Container(
          decoration: BoxDecoration(
            color: ctx.appColors.surfaceModal,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            border: Border.all(color: ctx.appColors.borderSubtle),
          ),
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 移动端底部抽屉专用的极简顶部小把手
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(top: 4, bottom: 12),
                      decoration: BoxDecoration(
                        color: ctx.appColors.borderSubtle,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  CalendarSyncPanel(
                    onClose: () => Navigator.pop(ctx),
                    onSyncCompleted: onSyncCompleted,
                    isDrawerMode: true,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  State<CalendarSyncPanel> createState() => _CalendarSyncPanelState();
}

class _CalendarSyncPanelState extends State<CalendarSyncPanel> {
  CalendarTimeSpanOption _span = CalendarTimeSpanOption.threeMonths;
  CalendarSyncResult? _lastSyncResult = CalendarSyncService.instance.lastResult;
  bool _isSyncing = false;

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _runSync(CalendarSyncDirection direction) async {
    setState(() => _isSyncing = true);
    try {
      final res = await CalendarSyncService.instance.performTwoWaySync(
        options: CalendarSyncOptions(
          direction: direction,
          timeSpan: _span,
          autoDeleteSystemWhenAppDeleted:
              AppSettingsService.instance.syncDeleteFromSystemCalendar,
        ),
      );

      if (mounted) {
        setState(() {
          _isSyncing = false;
          _lastSyncResult = res;
        });
      }

      widget.onSyncCompleted?.call();

      final prefix = direction == CalendarSyncDirection.twoWay
          ? '🎉'
          : (direction == CalendarSyncDirection.pullOnly ? '📥' : '📤');
      _showSnack('$prefix ${res.summary}');
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSyncing = false;
          _lastSyncResult = CalendarSyncResult(
            success: false,
            message: '同步出错: $e',
          );
        });
      }
      _showSnack('❌ 同步异常: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final appColors = context.appColors;
    final primaryColor = context.colorScheme.primary;

    final allEvents = AgendaRepository.instance.allEvents;
    final syncedCount = allEvents.where((e) => e.syncedToSystemCalendar).length;
    final unsyncedCount = allEvents.length - syncedCount;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. 标题栏（无技术性冗余描述，优雅紧凑）
        if (widget.showHeader) ...[
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: appColors.tagWorkContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.sync,
                  size: 20,
                  color: appColors.tagWork,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '系统日历双向同步中心',
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.bold,
                    color: appColors.textPrimary,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 20),
                color: appColors.textSecondary,
                visualDensity: VisualDensity.compact,
                tooltip: '关闭',
                onPressed: () {
                  if (widget.onClose != null) {
                    widget.onClose!();
                  } else {
                    Navigator.maybePop(context);
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 14),
        ],

        // 2. 三联数据统计卡片
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: appColors.surfaceLow,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: appColors.borderSubtle),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildStatItem(
                label: '本地日程',
                value: '${allEvents.length}',
                color: appColors.tagRest,
                labelColor: appColors.textSecondary,
              ),
              _buildStatItem(
                label: '已同步系统',
                value: '$syncedCount',
                color: appColors.tagWork,
                labelColor: appColors.textSecondary,
              ),
              _buildStatItem(
                label: '未同步待推',
                value: '$unsyncedCount',
                color: unsyncedCount > 0
                    ? appColors.tagStudy
                    : appColors.textTertiary,
                labelColor: appColors.textSecondary,
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // 3. 时间跨度筛选行
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
                  final isSelected = _span == opt;
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
                      color: isSelected ? primaryColor : appColors.borderSubtle,
                    ),
                    onSelected: _isSyncing
                        ? null
                        : (sel) {
                            if (sel) {
                              setState(() => _span = opt);
                            }
                          },
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // 4. 联动删除开关项
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
                value: AppSettingsService.instance.syncDeleteFromSystemCalendar,
                activeTrackColor: primaryColor,
                onChanged: (v) async {
                  await AppSettingsService.instance
                      .setSyncDeleteFromSystemCalendar(v);
                  if (mounted) setState(() {});
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // 5. 核心同步操作按钮组
        if (_isSyncing)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Center(
              child: Column(
                children: [
                  const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '正在执行系统日历双向同步与对齐...',
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
            onPressed: () => _runSync(CalendarSyncDirection.twoWay),
            icon: const Icon(Icons.sync, size: 18),
            label: const Text(
              '一键双向智能同步 (推拉对齐)',
              style: TextStyle(
                fontSize: 14,
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
                    side: BorderSide(color: appColors.borderSubtle),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: () => _runSync(CalendarSyncDirection.pullOnly),
                  icon: Icon(
                    Icons.download,
                    size: 16,
                    color: appColors.tagWork,
                  ),
                  label: const Text(
                    '从系统日历导入',
                    style: TextStyle(fontSize: 12.5),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: appColors.textPrimary,
                    side: BorderSide(color: appColors.borderSubtle),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: () => _runSync(CalendarSyncDirection.pushOnly),
                  icon: Icon(
                    Icons.upload,
                    size: 16,
                    color: appColors.tagRest,
                  ),
                  label: const Text(
                    '全部推送到系统',
                    style: TextStyle(fontSize: 12.5),
                  ),
                ),
              ),
            ],
          ),
        ],

        // 6. 最下方圆角矩形指示条（精简状态，绝不与上方三联卡片冗余重复）
        const SizedBox(height: 14),
        _buildStatusIndicator(
          appColors: appColors,
          errorColor: context.colorScheme.error,
          unsyncedCount: unsyncedCount,
        ),
      ],
    );
  }

  Widget _buildStatItem({
    required String label,
    required String value,
    required Color color,
    required Color labelColor,
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
            color: labelColor,
          ),
        ),
      ],
    );
  }

  /// 最下方圆角矩形指示条：简略呈现当前同步就绪状态
  Widget _buildStatusIndicator({
    required AppCustomColors appColors,
    required Color errorColor,
    required int unsyncedCount,
  }) {
    // 1. 若上次同步报错，展示异常信息
    if (_lastSyncResult != null && !_lastSyncResult!.success) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: appColors.errorContainer,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: errorColor.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            Icon(Icons.error_outline, size: 16, color: errorColor),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _lastSyncResult!.message,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: errorColor,
                ),
              ),
            ),
          ],
        ),
      );
    }

    // 2. 正常状态：根据未同步数量展示极其简短精准的指示说明
    final isUpToDate = unsyncedCount == 0;
    final statusText = isUpToDate ? '所有日程已是最新' : '有 $unsyncedCount 条日程待同步';
    final statusIcon =
        isUpToDate ? Icons.check_circle_outline : Icons.info_outline;
    final statusColor = isUpToDate ? appColors.tagWork : appColors.tagStudy;
    final containerColor =
        isUpToDate ? appColors.successContainer : appColors.surfaceLow;
    final borderColor = isUpToDate
        ? appColors.tagWork.withValues(alpha: 0.25)
        : appColors.borderSubtle;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: containerColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        children: [
          Icon(statusIcon, size: 16, color: statusColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              statusText,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: statusColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 系统日历双向同步中心模态对话框 (CalendarSyncDialog)
///
/// 保持向后兼容，提供以普通 Dialog 弹窗展示的形态。
class CalendarSyncDialog extends StatelessWidget {
  final VoidCallback? onSyncCompleted;

  const CalendarSyncDialog({
    super.key,
    this.onSyncCompleted,
  });

  /// 唤起系统日历双向同步中心 Modal
  static Future<void> show(
    BuildContext context, {
    VoidCallback? onSyncCompleted,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Dialog(
        backgroundColor: ctx.appColors.surfaceModal,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: ctx.appColors.borderSubtle),
        ),
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: CalendarSyncPanel(
              onClose: () => Navigator.pop(ctx),
              onSyncCompleted: onSyncCompleted,
              isDrawerMode: false,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CalendarSyncPanel(
      onSyncCompleted: onSyncCompleted,
      onClose: () => Navigator.maybePop(context),
      isDrawerMode: false,
    );
  }
}
