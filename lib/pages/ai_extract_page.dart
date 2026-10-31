import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/agenda_event.dart';
import '../services/ai_extractor_service.dart';
import '../theme/app_theme.dart';
import '../widgets/agenda_event_card.dart';
import '../widgets/app_toast.dart';
import '../widgets/inference_terminal.dart';

/// 「AI 提取」工作台页面（桌面端双列布局 + 移动端自适应 + 即刻收起抽屉）
class AIExtractPage extends StatefulWidget {
  final TextEditingController inputController;
  final AIEngineMode engineMode;
  final String? selectedModelName;
  final String llmEndpoint;
  final String lastEngineInfo;
  final List<AgendaEvent> draftEvents;
  final InferenceTerminalModel? terminalModel;
  final bool isExtracting;
  final List<String> processLogs;
  final String streamedTokens;
  final int tokenCount;
  final double elapsedSeconds;
  final Future<void> Function({String sourceType}) onRunExtraction;
  final Future<void> Function(AgendaEvent event) onConfirmDraft;
  final Future<void> Function({bool writeSystemCalendar}) onConfirmAllDrafts;
  final void Function(AgendaEvent event) onRemoveDraft;
  final void Function(AgendaEvent event)? onUpdateDraft;

  const AIExtractPage({
    super.key,
    required this.inputController,
    required this.engineMode,
    required this.selectedModelName,
    required this.llmEndpoint,
    required this.lastEngineInfo,
    required this.draftEvents,
    this.terminalModel,
    this.isExtracting = false,
    this.processLogs = const [],
    this.streamedTokens = '',
    this.tokenCount = 0,
    this.elapsedSeconds = 0.0,
    required this.onRunExtraction,
    required this.onConfirmDraft,
    required this.onConfirmAllDrafts,
    required this.onRemoveDraft,
    this.onUpdateDraft,
  });

  static const List<Map<String, String>> sampleAnnouncements = [
    {
      'label': '🏆 竞赛多节点通知',
      'text': '【AI与开源创新大赛】各位队长请注意：1. 明天下午14:30在综合楼302报告厅举行赛题宣讲会，请携带学生证签到；'
          '2. 本周日晚上20:00在腾讯会议：884-291-003 开展端侧模型微调线上培训；'
          '3. 10月25日截止提交初赛立项策划书与开源仓库链接，请务必准时提交项目源码。'
    },
    {
      'label': '📚 教务调课与实验',
      'text': '【教务处通知】接任课教师通知，原定本周三的《操作系统实验》课程调整至后天下午2点半在计算机楼B405实验室进行，'
          '请携带实验报告册与U盘。另外下周二晚上7点在科技楼101进行期中机试测验。'
    },
    {
      'label': '🎬 视频转写字幕示例',
      'text': '【宣讲视频ASR转写】同学们好，欢迎大家回看本次开源之夏宣讲录像。这里重点强调两个时间节点：'
          '第一，明天晚上19:30我们会在飞书会议：661-902-118 举办导师答疑专场；'
          '第二，10月28日下午17:00前请将个人简历与项目规划书PDF发送至组委会邮箱。'
    },
  ];

  @override
  State<AIExtractPage> createState() => _AIExtractPageState();
}

class _AIExtractPageState extends State<AIExtractPage> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  bool _isSourceTextExpanded = true;
  bool _lastExtracting = false;
  int _lastDraftCount = 0;

  // 响应式桌面端让位抽屉与移动端底部弹窗状态
  bool _isWide = false;
  String? _activeDrawerId;
  String _drawerTitle = '';
  String _drawerSubtitle = '';
  IconData _drawerIcon = Icons.event_note_outlined;
  Widget Function(
    BuildContext context,
    StateSetter setDrawerState,
    VoidCallback onClose,
  )? _drawerFormBuilder;
  final Map<String, GlobalKey> _tileKeys = {};

  bool get _isExtracting =>
      widget.terminalModel?.isExtracting ?? widget.isExtracting;

  @override
  void initState() {
    super.initState();
    _isSourceTextExpanded = true;
    _lastExtracting = _isExtracting;
    _lastDraftCount = widget.draftEvents.length;
    widget.terminalModel?.addListener(_onTerminalModelUpdated);
  }

  @override
  void didUpdateWidget(covariant AIExtractPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.terminalModel != widget.terminalModel) {
      oldWidget.terminalModel?.removeListener(_onTerminalModelUpdated);
      widget.terminalModel?.addListener(_onTerminalModelUpdated);
    }
    final currentExtracting = _isExtracting;
    final currentDraftCount = widget.draftEvents.length;
    // 当生成完成或产生新草稿时，默认保持/恢复通知原文卡片展开，方便用户校对
    if ((_lastExtracting && !currentExtracting) ||
        (currentDraftCount > 0 && currentDraftCount != _lastDraftCount)) {
      _isSourceTextExpanded = true;
    }
    // 若当前正在编辑的草稿被删除，折叠关闭抽屉
    if (_activeDrawerId != null &&
        !widget.draftEvents.any((e) => 'event_${e.id}' == _activeDrawerId)) {
      _closeDrawer();
    }
    _lastExtracting = currentExtracting;
    _lastDraftCount = currentDraftCount;
  }

  void _onTerminalModelUpdated() {
    final currentExtracting = _isExtracting;
    if (_lastExtracting && !currentExtracting) {
      // 模型提取与结构化解析完成后：自动展开通知原文卡片，方便用户校对
      if (mounted) {
        setState(() {
          _isSourceTextExpanded = true;
        });
      }
    }
    _lastExtracting = currentExtracting;
  }

  @override
  void dispose() {
    widget.terminalModel?.removeListener(_onTerminalModelUpdated);
    super.dispose();
  }

  /// 获取当前已粘贴或已解析的通知原文
  String get _currentRawText {
    final text = widget.inputController.text.trim();
    if (text.isNotEmpty) return text;
    for (final ev in widget.draftEvents) {
      if (ev.sourceText.trim().isNotEmpty) {
        return ev.sourceText.trim();
      }
    }
    return '';
  }

  // ================= 自动让位抽屉与参数项体系（符合 DRAWER_DESIGN_SPEC.md） =================

  void _closeDrawer() {
    if (_activeDrawerId != null && mounted) {
      setState(() => _activeDrawerId = null);
    }
  }

  /// 抽屉内容与状态统一管理器
  void _openCustomOptionDrawer({
    required String drawerId,
    required String title,
    required String subtitle,
    required IconData icon,
    GlobalKey? anchorKey,
    required Widget Function(
      BuildContext context,
      StateSetter setDrawerState,
      VoidCallback onClose,
    ) formBuilder,
  }) async {
    // 再次点击同一行则折叠关闭
    if (_activeDrawerId == drawerId) {
      _closeDrawer();
      return;
    }

    final isWide = _isWide;
    if (isWide) {
      setState(() {
        _activeDrawerId = drawerId;
        _drawerTitle = title;
        _drawerSubtitle = subtitle;
        _drawerIcon = icon;
        _drawerFormBuilder = formBuilder;
      });
      if (anchorKey?.currentContext != null) {
        Scrollable.ensureVisible(
          anchorKey!.currentContext!,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          alignment: 0.25,
        );
      }
    } else {
      if (anchorKey?.currentContext != null) {
        Scrollable.ensureVisible(
          anchorKey!.currentContext!,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
          alignment: 0.12,
        );
      }
      setState(() {
        _activeDrawerId = drawerId;
        _drawerTitle = title;
        _drawerSubtitle = subtitle;
        _drawerIcon = icon;
        _drawerFormBuilder = formBuilder;
      });

      await Future.delayed(const Duration(milliseconds: 60));
      if (!mounted) return;

      final primaryColor = context.colorScheme.primary;

      await showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (ctx) {
          return _buildMobileCustomBottomSheet(
            ctx,
            title: title,
            subtitle: subtitle,
            icon: icon,
            primaryColor: primaryColor,
            formBuilder: formBuilder,
          );
        },
      );

      if (mounted) {
        setState(() {
          _activeDrawerId = null;
        });
      }
    }
  }

  /// 统一标准紧凑参数列表项（整行可点击，右侧展示参数/状态 Badge）
  Widget _buildCompactParamTile({
    Key? key,
    required IconData icon,
    required String title,
    required String subtitle,
    String? valueBadge,
    Widget? badgeWidget,
    required VoidCallback onTap,
    bool isEditing = false,
  }) {
    final colors = context.appColors;
    final primaryColor = context.colorScheme.primary;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: isEditing
            ? primaryColor.withValues(alpha: 0.08)
            : colors.surfaceCard,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isEditing ? primaryColor : colors.borderSubtle,
          width: isEditing ? 1.0 : 0.8,
        ),
      ),
      child: InkWell(
        key: key,
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          child: Row(
            children: [
              SizedBox(
                width: 20,
                child: Center(
                  child: Icon(
                    icon,
                    size: 20,
                    color: isEditing ? primaryColor : primaryColor,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: isEditing ? primaryColor : colors.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: isEditing
                            ? primaryColor.withValues(alpha: 0.8)
                            : colors.textSecondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              if (badgeWidget != null)
                badgeWidget
              else if (valueBadge != null)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: isEditing
                        ? primaryColor.withValues(alpha: 0.16)
                        : colors.surfaceLow,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: isEditing ? primaryColor : colors.borderSubtle,
                      width: 0.8,
                    ),
                  ),
                  child: Text(
                    valueBadge,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12.5,
                      fontWeight: FontWeight.bold,
                      color: isEditing ? primaryColor : colors.textPrimary,
                    ),
                  ),
                ),
              const SizedBox(width: 4),
              Icon(
                Icons.chevron_right,
                size: 18,
                color: isEditing ? primaryColor : colors.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 构建状态/参数 Badge 组件
  Widget _buildEventStatusBadge(
    AgendaEvent ev,
    bool isEditing,
    AppCustomColors appColors,
    Color primaryColor,
  ) {
    if (ev.syncedToSystemCalendar) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: appColors.tagWork.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: appColors.tagWork,
            width: 0.8,
          ),
        ),
        child: Text(
          '[ ✓ 已同步 ]',
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: appColors.tagWork,
          ),
        ),
      );
    }

    final isCross = AgendaEventCard.isCrossDayEvent(ev.startTime, ev.endTime);
    final badgeLabel = isCross
        ? '[ 跨天日程 ]'
        : '[ ${AgendaEventCard.getSourceLabel(ev.sourceType)} ]';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: isEditing
            ? primaryColor.withValues(alpha: 0.16)
            : appColors.surfaceLow,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: isEditing ? primaryColor : appColors.borderSubtle,
          width: 0.8,
        ),
      ),
      child: Text(
        badgeLabel,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: isEditing ? primaryColor : appColors.textPrimary,
        ),
      ),
    );
  }

  /// 列表单行日程项构建
  Widget _buildEventTile(AgendaEvent ev) {
    final anchorKey = _tileKeys.putIfAbsent(ev.id, () => GlobalKey());
    final isEditing = _activeDrawerId == 'event_${ev.id}';
    final appColors = context.appColors;
    final primaryColor = context.colorScheme.primary;

    final timeStr =
        AgendaEventCard.formatSpan(ev.startTime, ev.endTime, showDate: true);
    final details = <String>[timeStr];
    if (ev.location.isNotEmpty) {
      details.add('📍 ${ev.location}');
    }
    if (ev.description.isNotEmpty) {
      details.add('📝 ${ev.description}');
    }
    if (ev.checklist.isNotEmpty) {
      details.add('${ev.checklist.length}项待办');
    }
    final subtitle = details.join('  ·  ');

    return _buildCompactParamTile(
      key: anchorKey,
      icon: Icons.event_note_outlined,
      title: ev.title,
      subtitle: subtitle,
      badgeWidget:
          _buildEventStatusBadge(ev, isEditing, appColors, primaryColor),
      isEditing: isEditing,
      onTap: () {
        _openCustomOptionDrawer(
          drawerId: 'event_${ev.id}',
          title: '修改日程详情',
          subtitle: ev.title,
          icon: Icons.event_note_outlined,
          anchorKey: anchorKey,
          formBuilder: (ctx, setDrawerState, onClose) {
            return AgendaEventCard(
              event: ev,
              isDraft: true,
              showDate: true,
              onSyncCalendar: () {
                widget.onConfirmDraft(ev);
                onClose();
              },
              onDelete: () {
                widget.onRemoveDraft(ev);
                onClose();
              },
              onEventChanged: (updated) {
                _drawerSubtitle = updated.title;
                widget.onUpdateDraft?.call(updated);
                setDrawerState(() {});
                setState(() {});
              },
            );
          },
        );
      },
    );
  }

  /// 桌面端右侧 380dp 抽屉内容容器（包裹统一 Header 与表单）
  Widget _buildDesktopDrawerContent(Color primaryColor) {
    return StatefulBuilder(
      builder: (context, setDrawerState) {
        final colors = context.appColors;
        return Container(
          width: 380,
          color: colors.surfaceModal,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 统一顶部 Header
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 10, 12),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: primaryColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(_drawerIcon, color: primaryColor, size: 18),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _drawerTitle,
                            style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.bold,
                              color: colors.textPrimary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _drawerSubtitle,
                            style: TextStyle(
                              fontSize: 11,
                              color: colors.textSecondary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      tooltip: '关闭面板',
                      onPressed: _closeDrawer,
                    ),
                  ],
                ),
              ),
              Divider(height: 1, thickness: 1, color: colors.borderSubtle),
              // 统一表单内容滚动区
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: _drawerFormBuilder?.call(
                        context,
                        setDrawerState,
                        _closeDrawer,
                      ) ??
                      const SizedBox.shrink(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 移动端底部 BottomSheet 容器（带小把手与最大 85% 高度约束）
  Widget _buildMobileCustomBottomSheet(
    BuildContext ctx, {
    required String title,
    required String subtitle,
    required IconData icon,
    required Color primaryColor,
    required Widget Function(
      BuildContext context,
      StateSetter setSheetState,
      VoidCallback onClose,
    ) formBuilder,
  }) {
    final colors = ctx.appColors;
    return StatefulBuilder(
      builder: (context, setSheetState) {
        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.85,
          ),
          decoration: BoxDecoration(
            color: colors.surfaceModal,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 移动端顶部小把手
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(top: 8, bottom: 8),
                  decoration: BoxDecoration(
                    color: colors.borderSubtle,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              // 移动端头部 Header
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 10, 10),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: primaryColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(icon, color: primaryColor, size: 18),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.bold,
                              color: colors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            style: TextStyle(
                              fontSize: 11,
                              color: colors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      tooltip: '关闭面板',
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, thickness: 1, color: colors.borderSubtle),
              Flexible(
                child: SingleChildScrollView(
                  padding: EdgeInsets.only(
                    left: 16,
                    right: 16,
                    top: 14,
                    bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
                  ),
                  child: formBuilder(
                    ctx,
                    setSheetState,
                    () => Navigator.of(ctx).pop(),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 统一抽屉呼出入口：手机从下方滑出，电脑/大屏从右侧滑出
  void _openInputDrawer(BuildContext context) {
    final isCompact = MediaQuery.of(context).size.width < 760;
    if (isCompact) {
      _openBottomDrawer(context);
    } else {
      _scaffoldKey.currentState?.openEndDrawer();
    }
  }

  /// 手机端底部抽屉 (Bottom Drawer)
  void _openBottomDrawer(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final appColors = sheetContext.appColors;
        return Container(
          decoration: BoxDecoration(
            color: appColors.surfaceModal,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border(
              top: BorderSide(
                color: appColors.borderSubtle.withValues(alpha: 0.5),
                width: 1,
              ),
            ),
          ),
          child: SafeArea(
            top: false,
            child: _AIExtractDrawerContent(
              controller: widget.inputController,
              isExtracting: _isExtracting,
              onRunExtraction: widget.onRunExtraction,
              isBottom: true,
              onClose: () {
                Navigator.of(sheetContext).pop();
                if (mounted) {
                  setState(() {
                    _isSourceTextExpanded = true;
                  });
                }
              },
            ),
          ),
        );
      },
    );
  }

  /// 电脑端右侧抽屉 (End Drawer)
  Widget _buildRightDrawer(BuildContext context) {
    final appColors = context.appColors;
    final screenWidth = MediaQuery.of(context).size.width;
    final drawerWidth = (screenWidth * 0.42).clamp(380.0, 520.0);

    return Drawer(
      width: drawerWidth,
      backgroundColor: appColors.surfaceModal,
      elevation: 16,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(left: Radius.circular(20)),
      ),
      child: SafeArea(
        child: _AIExtractDrawerContent(
          controller: widget.inputController,
          isExtracting: _isExtracting,
          onRunExtraction: widget.onRunExtraction,
          isBottom: false,
          onClose: () {
            Navigator.of(context).pop();
            if (mounted) {
              setState(() {
                _isSourceTextExpanded = true;
              });
            }
          },
        ),
      ),
    );
  }

  /// 空状态主引导操作：直接读取剪贴板解析，并在界面顶部即时呈现原文反馈
  Future<void> _handleEmptyStatePasteAndExtract(BuildContext context) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isNotEmpty) {
      widget.inputController.text = text;
      _isSourceTextExpanded = true;
      if (mounted) setState(() {});
      await widget.onRunExtraction(sourceType: 'clipboard');
    } else {
      if (context.mounted) {
        AppToast.show(context, '剪贴板为空，已为您打开输入抽屉');
        _openInputDrawer(context);
      }
    }
  }

  /// 顶部通知原文回显卡片（轻量微质感，支持折叠展开与重新编辑）
  Widget _buildSourceTextBanner(
    AppCustomColors appColors,
    Color primaryColor,
    String rawText,
  ) {
    final isLong = rawText.length > 70 || rawText.contains('\n');

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: appColors.surfaceCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _isExtracting
              ? primaryColor.withValues(alpha: 0.5)
              : appColors.borderSubtle.withValues(alpha: 0.8),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 标题与操作栏
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
            child: Row(
              children: [
                Icon(
                  Icons.article_outlined,
                  size: 16,
                  color: primaryColor,
                ),
                const SizedBox(width: 6),
                Text(
                  '通知原文',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: appColors.textPrimary,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: appColors.surfaceLow,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: appColors.borderSubtle.withValues(alpha: 0.5),
                    ),
                  ),
                  child: Text(
                    '${rawText.length} 字',
                    style: TextStyle(
                      fontSize: 11,
                      color: appColors.textTertiary,
                    ),
                  ),
                ),
                if (_isExtracting) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: primaryColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 10,
                          height: 10,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: primaryColor,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          '正在解析...',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: primaryColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const Spacer(),
                Tooltip(
                  message: '重新编辑原文',
                  child: InkWell(
                    onTap: () => _openInputDrawer(context),
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.edit_outlined,
                            size: 13,
                            color: appColors.textSecondary,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            '编辑',
                            style: TextStyle(
                              fontSize: 12,
                              color: appColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (isLong) ...[
                  const SizedBox(width: 4),
                  Tooltip(
                    message: _isSourceTextExpanded ? '收起全文' : '展开全文',
                    child: InkWell(
                      onTap: () {
                        setState(() {
                          _isSourceTextExpanded = !_isSourceTextExpanded;
                        });
                      },
                      borderRadius: BorderRadius.circular(6),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _isSourceTextExpanded ? '收起' : '展开',
                              style: TextStyle(
                                fontSize: 12,
                                color: primaryColor,
                              ),
                            ),
                            Icon(
                              _isSourceTextExpanded
                                  ? Icons.keyboard_arrow_up
                                  : Icons.keyboard_arrow_down,
                              size: 14,
                              color: primaryColor,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: 2),
                Tooltip(
                  message: '清除此条原文',
                  child: InkWell(
                    onTap: () {
                      setState(() {
                        widget.inputController.clear();
                      });
                    },
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        Icons.close,
                        size: 14,
                        color: appColors.textTertiary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // 原文正文文本（默认完整展开，方便校对，同时加约束滚动防超高溢出）
          InkWell(
            onTap: isLong
                ? () {
                    setState(() {
                      _isSourceTextExpanded = !_isSourceTextExpanded;
                    });
                  }
                : null,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 10),
              child: _isSourceTextExpanded
                  ? ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 280),
                      child: SingleChildScrollView(
                        physics: const ClampingScrollPhysics(),
                        child: Text(
                          rawText,
                          style: TextStyle(
                            fontSize: 13,
                            color: appColors.textSecondary,
                            height: 1.45,
                          ),
                        ),
                      ),
                    )
                  : Text(
                      rawText,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: appColors.textSecondary,
                        height: 1.45,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  /// 悬浮触发按钮组件
  Widget _buildFab(BuildContext context, Color primaryColor) {
    return FloatingActionButton.extended(
      onPressed: () => _openInputDrawer(context),
      backgroundColor: primaryColor,
      foregroundColor: context.colorScheme.onPrimary,
      elevation: 3,
      highlightElevation: 6,
      icon: _isExtracting
          ? SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: context.colorScheme.onPrimary,
              ),
            )
          : const Icon(Icons.add, size: 20),
      label: Text(
        _isExtracting ? '解析中...' : '粘贴解析',
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
    );
  }

  /// 极简居中空状态视图（移动端使用）
  Widget _buildEmptyState(
    BuildContext context,
    AppCustomColors appColors,
    Color primaryColor,
  ) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.calendar_today_outlined,
              size: 64,
              color: appColors.textTertiary.withValues(alpha: 0.55),
            ),
            const SizedBox(height: 16),
            Text(
              '暂无待处理日程，点击下方或右下角粘贴解析',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: appColors.textTertiary,
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => _handleEmptyStatePasteAndExtract(context),
              icon: const Icon(Icons.add, size: 20),
              label: const Text(
                '粘贴并解析',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: primaryColor,
                foregroundColor: context.colorScheme.onPrimary,
                padding:
                    const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                elevation: 2,
              ),
            ),
            const SizedBox(height: 10),
            TextButton.icon(
              onPressed: () => _openInputDrawer(context),
              icon: Icon(
                Icons.edit_note,
                size: 18,
                color: appColors.textSecondary,
              ),
              label: Text(
                '手动输入或填入示例',
                style: TextStyle(
                  fontSize: 13,
                  color: appColors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 列表头部（待处理日程计数与右上角全部入库操作）
  Widget _buildListHeader(AppCustomColors appColors, Color primaryColor) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            '待处理日程',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.bold,
              color: appColors.textPrimary,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: primaryColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '${widget.draftEvents.length}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: primaryColor,
              ),
            ),
          ),
          const Spacer(),
          if (widget.draftEvents.isNotEmpty)
            FilledButton.tonalIcon(
              onPressed: () =>
                  widget.onConfirmAllDrafts(writeSystemCalendar: true),
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 44),
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                elevation: 1,
              ),
              icon: const Icon(Icons.done_all, size: 18),
              label: const Text(
                '全部入库',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.3,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 桌面端左侧空通知占位引导
  Widget _buildDesktopLeftEmptyPrompt(
    BuildContext context,
    AppCustomColors appColors,
    Color primaryColor,
  ) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: appColors.surfaceCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: appColors.borderSubtle.withValues(alpha: 0.8),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.article_outlined, size: 18, color: primaryColor),
              const SizedBox(width: 8),
              Text(
                '通知原文',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: appColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '暂无待处理通知文本。可点击下方按钮直接粘贴剪贴板内容，或打开右侧抽屉输入。',
            style: TextStyle(
              fontSize: 13,
              color: appColors.textSecondary,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: () => _handleEmptyStatePasteAndExtract(context),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('粘贴并解析'),
                style: FilledButton.styleFrom(
                  backgroundColor: primaryColor,
                  foregroundColor: context.colorScheme.onPrimary,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
              OutlinedButton.icon(
                onPressed: () => _openInputDrawer(context),
                icon: Icon(
                  Icons.edit_note,
                  size: 16,
                  color: appColors.textSecondary,
                ),
                label: Text(
                  '手动输入',
                  style: TextStyle(color: appColors.textSecondary),
                ),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: appColors.borderSubtle),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 桌面端右侧草稿空状态
  Widget _buildDesktopRightEmptyState(AppCustomColors appColors) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.calendar_today_outlined,
              size: 52,
              color: appColors.textTertiary.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 14),
            Text(
              '暂无草稿日程',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: appColors.textSecondary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '在左侧粘贴并解析通知后，提取的日程节点将直接展示于此处',
              style: TextStyle(
                fontSize: 12,
                color: appColors.textTertiary,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  /// 桌面端双列布局（左栏：通知原文与运行状态 + 右下角悬浮按钮；右栏：纯粹草稿区）
  Widget _buildDesktopLayout(
    BuildContext context,
    AppCustomColors appColors,
    Color primaryColor,
    String rawText,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 左侧栏：通知原文与运行监控仪表盘，右下角配有“粘贴解析”按钮
        Expanded(
          flex: 5,
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 1. 顶部通知原文卡片
                    if (rawText.isNotEmpty)
                      _buildSourceTextBanner(appColors, primaryColor, rawText)
                    else
                      _buildDesktopLeftEmptyPrompt(
                        context,
                        appColors,
                        primaryColor,
                      ),

                    const SizedBox(height: 12),

                    // 2. 运行状态与思考流区域（基于 Flex 精确填充剩余高度，绝不超标）
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, terminalConstraints) {
                          // 精确扣除 InferenceTerminal 内非思考框区域的总高度：
                          // 状态栏 (~72px) + 分割线 (1px) + 边距 (~20px) + 完成折叠条 (~36px) + 安全缓冲 (~20px) = 149px
                          final hasFoldBar = !_isExtracting && rawText.isNotEmpty;
                          final nonBoxOverhead = hasFoldBar ? 152.0 : 108.0;
                          final maxThinkingHeight =
                              (terminalConstraints.maxHeight - nonBoxOverhead)
                                  .clamp(80.0, 2000.0);

                          return Align(
                            alignment: Alignment.topCenter,
                            child: InferenceTerminal(
                              model: widget.terminalModel,
                              isExtracting: widget.isExtracting,
                              processLogs: widget.processLogs,
                              streamedTokens: widget.streamedTokens,
                              tokenCount: widget.tokenCount,
                              elapsedSeconds: widget.elapsedSeconds,
                              maxHeight: maxThinkingHeight,
                            ),
                          );
                        },
                      ),
                    ),

                    // 3. 严格预留底部 94px（16底边距 + 48按钮高 + 30按钮上方要求间距）
                    // 确保思考流无论如何扩展，底部都精确停在按钮上方 30px 处，绝不超标遮挡
                    const SizedBox(height: 94),
                  ],
                ),
              ),

              // 4. 右下角粘贴解析按钮
              Positioned(
                bottom: 16,
                right: 16,
                child: _buildFab(context, primaryColor),
              ),
            ],
          ),
        ),

        // 中间分隔线
        VerticalDivider(
          width: 1,
          thickness: 1,
          color: appColors.borderSubtle.withValues(alpha: 0.6),
        ),

        // 右侧栏：纯粹的日程草稿管理区
        Expanded(
          flex: 5,
          child: widget.draftEvents.isEmpty
              ? _buildDesktopRightEmptyState(appColors)
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  children: [
                    _buildListHeader(appColors, primaryColor),
                    for (final ev in widget.draftEvents)
                      _buildEventTile(ev),
                  ],
                ),
        ),
      ],
    );
  }

  /// 移动端单列布局（保持原有的列表堆叠顺序）
  Widget _buildMobileLayout(
    BuildContext context,
    AppCustomColors appColors,
    Color primaryColor,
    String rawText,
    bool hasContentToShow,
  ) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: !hasContentToShow
            ? _buildEmptyState(context, appColors, primaryColor)
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
                children: [
                  if (rawText.isNotEmpty)
                    _buildSourceTextBanner(appColors, primaryColor, rawText),
                  InferenceTerminal(
                    model: widget.terminalModel,
                    isExtracting: widget.isExtracting,
                    processLogs: widget.processLogs,
                    streamedTokens: widget.streamedTokens,
                    tokenCount: widget.tokenCount,
                    elapsedSeconds: widget.elapsedSeconds,
                  ),
                  if (widget.draftEvents.isEmpty && _isExtracting)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 36),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 26,
                              height: 26,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: primaryColor,
                              ),
                            ),
                            const SizedBox(height: 14),
                            Text(
                              '端侧模型正在智能解析日程中...',
                              style: TextStyle(
                                fontSize: 13,
                                color: appColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  else if (widget.draftEvents.isEmpty && rawText.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 32),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.info_outline,
                              size: 32,
                              color: appColors.textTertiary,
                            ),
                            const SizedBox(height: 10),
                            Text(
                              '未在上述通知中检测到明确的时间/日程节点',
                              style: TextStyle(
                                fontSize: 13,
                                color: appColors.textTertiary,
                              ),
                            ),
                            const SizedBox(height: 8),
                            TextButton.icon(
                              onPressed: () => _openInputDrawer(context),
                              icon: const Icon(Icons.edit_note, size: 16),
                              label: const Text('修改原文或填入示例'),
                            ),
                          ],
                        ),
                      ),
                    )
                  else if (widget.draftEvents.isNotEmpty) ...[
                    _buildListHeader(appColors, primaryColor),
                    for (final ev in widget.draftEvents)
                      _buildEventTile(ev),
                  ],
                ],
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appColors = context.appColors;
    final primaryColor = context.colorScheme.primary;
    final rawText = _currentRawText;

    final hasTerminalContent = (widget.terminalModel?.hasContent ?? false) ||
        widget.processLogs.isNotEmpty ||
        widget.streamedTokens.isNotEmpty ||
        _isExtracting;

    final hasContentToShow = widget.draftEvents.isNotEmpty ||
        hasTerminalContent ||
        rawText.isNotEmpty;

    return LayoutBuilder(
      builder: (context, constraints) {
        _isWide = constraints.maxWidth >= 880;
        final isDrawerOpen = _isWide && _activeDrawerId != null;

        if (_isWide) {
          return Scaffold(
            key: _scaffoldKey,
            backgroundColor: Colors.transparent,
            endDrawer: _buildRightDrawer(context),
            body: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _buildDesktopLayout(
                    context,
                    appColors,
                    primaryColor,
                    rawText,
                  ),
                ),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 280),
                  curve: Curves.easeInOutCubic,
                  width: isDrawerOpen ? 380 : 0,
                  decoration: BoxDecoration(
                    color: appColors.surfaceModal,
                    border: Border(
                      left: BorderSide(
                        color: appColors.borderSubtle,
                        width: isDrawerOpen ? 1 : 0,
                      ),
                    ),
                    boxShadow: isDrawerOpen
                        ? [
                            BoxShadow(
                              color: context.colorScheme.shadow
                                  .withValues(alpha: 0.16),
                              blurRadius: 16,
                              offset: const Offset(-4, 0),
                            ),
                          ]
                        : null,
                  ),
                  clipBehavior: Clip.hardEdge,
                  child: isDrawerOpen
                      ? OverflowBox(
                          minWidth: 380,
                          maxWidth: 380,
                          alignment: Alignment.topRight,
                          child: _buildDesktopDrawerContent(primaryColor),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          );
        } else {
          return Scaffold(
            key: _scaffoldKey,
            backgroundColor: Colors.transparent,
            endDrawer: _buildRightDrawer(context),
            body: _buildMobileLayout(
              context,
              appColors,
              primaryColor,
              rawText,
              hasContentToShow,
            ),
            floatingActionButton: _buildFab(context, primaryColor),
          );
        }
      },
    );
  }
}

/// 抽屉核心内容模组（自适应手机底部滑出与电脑侧边滑出）
class _AIExtractDrawerContent extends StatefulWidget {
  final TextEditingController controller;
  final bool isExtracting;
  final Future<void> Function({String sourceType}) onRunExtraction;
  final bool isBottom;
  final VoidCallback onClose;

  const _AIExtractDrawerContent({
    required this.controller,
    required this.isExtracting,
    required this.onRunExtraction,
    required this.isBottom,
    required this.onClose,
  });

  @override
  State<_AIExtractDrawerContent> createState() =>
      _AIExtractDrawerContentState();
}

class _AIExtractDrawerContentState extends State<_AIExtractDrawerContent> {
  bool _isLoading = false;

  bool get _effectiveExtracting => _isLoading || widget.isExtracting;

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      if (!mounted) return;
      AppToast.show(context, '剪贴板为空或无文本权限');
      return;
    }
    setState(() {
      widget.controller.text = text;
      widget.controller.selection = TextSelection.fromPosition(
        TextPosition(offset: text.length),
      );
    });
  }

  void _fillSample(int idx) {
    final sample = AIExtractPage.sampleAnnouncements[idx];
    setState(() {
      widget.controller.text = sample['text']!;
      widget.controller.selection = TextSelection.fromPosition(
        TextPosition(offset: widget.controller.text.length),
      );
    });
  }

  Future<void> _handleExtract() async {
    final text = widget.controller.text.trim();
    if (text.isEmpty) {
      AppToast.show(context, '请先输入或粘贴通知内容');
      return;
    }

    // 1. 在抽屉中点击开始解析按钮后立刻收起抽屉，平滑回到主界面
    widget.onClose();

    // 2. 触发端侧/云端提取流程
    widget.onRunExtraction(sourceType: 'manual');
  }

  @override
  Widget build(BuildContext context) {
    final appColors = context.appColors;
    final primaryColor = context.colorScheme.primary;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // 输入框背景稍亮于抽屉底色 (Surface 层级递进)
    final inputFillColor = isDark
        ? Color.alphaBlend(
            Colors.white.withValues(alpha: 0.05),
            appColors.surfaceModal,
          )
        : appColors.surfaceLow;

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: widget.isBottom ? 12 : 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 手机底部抽屉显示顶部把手条；电脑端侧边抽屉不显示
            if (widget.isBottom)
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: appColors.borderSubtle,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

            // 1. 抽屉标题栏：标题“添加通知文本”与关闭图标
            Row(
              children: [
                Icon(
                  Icons.psychology,
                  size: 24,
                  color: primaryColor,
                ),
                const SizedBox(width: 8),
                Text(
                  '添加通知文本',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: appColors.textPrimary,
                  ),
                ),
                const Spacer(),
                PopupMenuButton<int>(
                  tooltip: '填入示例通知',
                  color: appColors.surfaceModal,
                  icon: Icon(
                    Icons.smart_display_outlined,
                    size: 20,
                    color: appColors.textSecondary,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  onSelected: _fillSample,
                  itemBuilder: (context) => [
                    for (int i = 0;
                        i < AIExtractPage.sampleAnnouncements.length;
                        i++)
                      PopupMenuItem(
                        value: i,
                        child: Text(
                          AIExtractPage.sampleAnnouncements[i]['label']!,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: appColors.textPrimary,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 4),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  color: appColors.textSecondary,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: '关闭',
                  onPressed: widget.onClose,
                ),
              ],
            ),
            const SizedBox(height: 14),

            // 2. 顶部轻量操作项：“快速粘贴剪贴板内容”
            Align(
              alignment: Alignment.centerLeft,
              child: InkWell(
                onTap: _effectiveExtracting ? null : _pasteFromClipboard,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: inputFillColor,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: appColors.borderSubtle.withValues(alpha: 0.6),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.content_paste, size: 15, color: primaryColor),
                      const SizedBox(width: 6),
                      Text(
                        '快速粘贴剪贴板内容',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: appColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),

            // 3. 核心区域多行文本输入框 (TextField)
            TextField(
              controller: widget.controller,
              maxLines: widget.isBottom ? 6 : 10,
              minLines: 4,
              enabled: !_effectiveExtracting,
              style: TextStyle(
                fontSize: 14,
                color: appColors.textPrimary,
                height: 1.4,
              ),
              decoration: InputDecoration(
                hintText: '粘贴或输入包含时间、地点的通知消息...',
                hintStyle: TextStyle(
                  fontSize: 14,
                  color: appColors.textTertiary,
                ),
                filled: true,
                fillColor: inputFillColor,
                contentPadding: const EdgeInsets.all(14),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: appColors.borderSubtle.withValues(alpha: 0.4),
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: appColors.borderSubtle.withValues(alpha: 0.4),
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: primaryColor.withValues(alpha: 0.8),
                    width: 1.5,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // 4. 底部主操作按钮：“AI 提取结构化日程”（导航栏人工智能图标，无 emoji）
            SizedBox(
              height: 48,
              child: FilledButton.icon(
                onPressed: _effectiveExtracting ? null : _handleExtract,
                style: FilledButton.styleFrom(
                  backgroundColor: primaryColor,
                  foregroundColor: context.colorScheme.onPrimary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: _effectiveExtracting
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: context.colorScheme.onPrimary,
                        ),
                      )
                    : const Icon(Icons.psychology, size: 20),
                label: Text(
                  _effectiveExtracting ? '正在解析日程...' : 'AI 提取结构化日程',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
