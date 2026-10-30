import 'dart:io';
import 'package:flutter/material.dart';
import '../repositories/agenda_repository.dart';
import '../services/ai_extractor_service.dart';
import '../services/app_settings_service.dart';
import '../services/calendar_sync_service.dart';
import '../services/floating_overlay_service.dart';
import '../services/lan_sync_service.dart';
import '../services/local_model_manager.dart';
import '../services/theme_manager.dart' hide AppTheme;
import '../theme/app_theme.dart';
import 'prompt_testing_page.dart';

/// 「设置」页面（大模型常驻、Android 原生无障碍悬浮窗、局域网协同与关于）
class SettingsPage extends StatefulWidget {
  final AIEngineMode engineMode;
  final ValueChanged<AIEngineMode> onEngineModeChanged;
  final String engineIndicatorDetail;
  final VoidCallback onPreloadModel;
  final VoidCallback onUnloadModel;
  final VoidCallback onOpenModelCenter;
  final List<String> localIps;
  final TextEditingController peerIpController;
  final VoidCallback onStateRefreshed;

  const SettingsPage({
    super.key,
    required this.engineMode,
    required this.onEngineModeChanged,
    required this.engineIndicatorDetail,
    required this.onPreloadModel,
    required this.onUnloadModel,
    required this.onOpenModelCenter,
    required this.localIps,
    required this.peerIpController,
    required this.onStateRefreshed,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsNavSection {
  final String id;
  final String label;
  final IconData icon;
  final GlobalKey key;

  const _SettingsNavSection({
    required this.id,
    required this.label,
    required this.icon,
    required this.key,
  });
}

class _ModelParamConfig {
  final String title;
  final String description;
  final String unit;
  final double currentValue;
  final double min;
  final double max;
  final int divisions;
  final bool isInteger;
  final List<double> presets;
  final Future<void> Function(double val) onConfirm;
  final GlobalKey? anchorKey;

  const _ModelParamConfig({
    required this.title,
    required this.description,
    required this.unit,
    required this.currentValue,
    required this.min,
    required this.max,
    required this.divisions,
    required this.isInteger,
    required this.presets,
    required this.onConfirm,
    this.anchorKey,
  });
}

class _SettingsPageState extends State<SettingsPage> {
  bool _floatingRunning = false;
  bool _accessibilityEnabled = false;

  /// 记录当前展开了说明的设置项 key
  final Set<String> _expandedInfoKeys = <String>{};

  // 各设置栏目 GlobalKey，用于桌面端侧边导航平滑锚点跳转
  final GlobalKey _themeKey = GlobalKey();
  final GlobalKey _modelKey = GlobalKey();
  final GlobalKey _floatingKey = GlobalKey();
  final GlobalKey _calendarKey = GlobalKey();
  final GlobalKey _lanKey = GlobalKey();
  final GlobalKey _advancedKey = GlobalKey();
  final GlobalKey _aboutKey = GlobalKey();

  // 模型参数锚点 GlobalKey，用于移动端抽屉升起时背景定位
  final GlobalKey _paramContextSizeKey = GlobalKey();
  final GlobalKey _paramMaxTokensKey = GlobalKey();
  final GlobalKey _paramTemperatureKey = GlobalKey();
  final GlobalKey _paramTopPKey = GlobalKey();
  final GlobalKey _paramRepeatPenaltyKey = GlobalKey();

  // 当前正在通过 Drawer 调节的参数配置与临时值
  _ModelParamConfig? _activeParamConfig;
  double _tempParamValue = 0.0;
  final TextEditingController _paramTextController = TextEditingController();

  final ScrollController _scrollController = ScrollController();
  int _activeNavIndex = 0;
  bool _isAutoScrolling = false;

  @override
  void initState() {
    super.initState();
    _checkNativeState();
    FloatingOverlayService.instance.isRunningNotifier
        .addListener(_onFloatingRunningChanged);
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _paramTextController.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    FloatingOverlayService.instance.isRunningNotifier
        .removeListener(_onFloatingRunningChanged);
    super.dispose();
  }

  void _closeParamDrawer() {
    if (mounted) {
      setState(() {
        _activeParamConfig = null;
      });
    }
  }

  void _handleParamEdit(_ModelParamConfig config) {
    if (_activeParamConfig?.title == config.title) {
      _closeParamDrawer();
      return;
    }

    final isWide = MediaQuery.of(context).size.width >= 880;
    if (isWide) {
      _openDesktopParameterDrawer(config);
    } else {
      _openMobileParameterDrawer(config);
    }
  }

  void _openDesktopParameterDrawer(_ModelParamConfig config) {
    setState(() {
      _activeParamConfig = config;
      _tempParamValue = config.currentValue.clamp(config.min, config.max);
      _paramTextController.text = config.isInteger
          ? _tempParamValue.round().toString()
          : _tempParamValue.toStringAsFixed(2);
    });

    if (config.anchorKey?.currentContext != null) {
      Scrollable.ensureVisible(
        config.anchorKey!.currentContext!,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        alignment: 0.25,
      );
    }
  }

  void _openMobileParameterDrawer(_ModelParamConfig config) async {
    if (config.anchorKey?.currentContext != null) {
      Scrollable.ensureVisible(
        config.anchorKey!.currentContext!,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
        alignment: 0.12,
      );
    }

    setState(() {
      _activeParamConfig = config;
      _tempParamValue = config.currentValue.clamp(config.min, config.max);
      _paramTextController.text = config.isInteger
          ? _tempParamValue.round().toString()
          : _tempParamValue.toStringAsFixed(2);
    });

    await Future.delayed(const Duration(milliseconds: 60));
    if (!mounted) return;

    final primaryColor = context.colorScheme.primary;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return _buildMobileBottomSheetContent(
          ctx,
          config,
          primaryColor,
        );
      },
    );

    if (mounted) {
      setState(() {
        _activeParamConfig = null;
      });
    }
  }

  List<_SettingsNavSection> _getSections() {
    return [
      _SettingsNavSection(
        id: 'theme',
        label: '外观主题',
        icon: Icons.palette_outlined,
        key: _themeKey,
      ),
      _SettingsNavSection(
        id: 'model',
        label: '端侧引擎',
        icon: Icons.memory,
        key: _modelKey,
      ),
      if (Platform.isAndroid)
        _SettingsNavSection(
          id: 'android',
          label: '悬浮窗与识屏',
          icon: Icons.phone_android,
          key: _floatingKey,
        ),
      _SettingsNavSection(
        id: 'calendar',
        label: '日历与同步',
        icon: Icons.calendar_month_outlined,
        key: _calendarKey,
      ),
      _SettingsNavSection(
        id: 'lan',
        label: '局域网协同',
        icon: Icons.hub_outlined,
        key: _lanKey,
      ),
      _SettingsNavSection(
        id: 'advanced',
        label: '高级设置',
        icon: Icons.tune,
        key: _advancedKey,
      ),
      _SettingsNavSection(
        id: 'about',
        label: '关于知程',
        icon: Icons.info_outline,
        key: _aboutKey,
      ),
    ];
  }

  void _scrollToSection(int index, GlobalKey key) {
    setState(() => _activeNavIndex = index);
    final targetCtx = key.currentContext;
    if (targetCtx == null) return;

    _isAutoScrolling = true;
    Scrollable.ensureVisible(
      targetCtx,
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeInOutCubic,
      alignment: 0.04,
    ).then((_) {
      Future.delayed(const Duration(milliseconds: 100), () {
        _isAutoScrolling = false;
      });
    });
  }

  void _onScroll() {
    if (_isAutoScrolling || !mounted) return;
    final sections = _getSections();
    if (sections.isEmpty) return;

    int currentActive = 0;
    for (int i = 0; i < sections.length; i++) {
      final ctx = sections[i].key.currentContext;
      if (ctx != null) {
        final box = ctx.findRenderObject() as RenderBox?;
        if (box != null && box.hasSize) {
          final pos = box.localToGlobal(Offset.zero);
          if (pos.dy <= 200) {
            currentActive = i;
          }
        }
      }
    }

    if (currentActive != _activeNavIndex && mounted) {
      setState(() {
        _activeNavIndex = currentActive;
      });
    }
  }

  void _onFloatingRunningChanged() {
    if (mounted) {
      setState(() {
        _floatingRunning = FloatingOverlayService.instance.isRunning;
      });
    }
  }

  Future<void> _checkNativeState() async {
    if (!Platform.isAndroid) return;
    final flt = await FloatingOverlayService.instance.checkRunningState();
    final a11y = await FloatingOverlayService.instance.checkAccessibilityState();
    if (mounted) {
      setState(() {
        _floatingRunning = flt;
        _accessibilityEnabled = a11y;
      });
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  void _toggleInfo(String key) {
    setState(() {
      if (_expandedInfoKeys.contains(key)) {
        _expandedInfoKeys.remove(key);
      } else {
        _expandedInfoKeys.add(key);
      }
    });
  }

  /// 统一构建“加框 i”说明展开/收起按钮
  Widget _buildInfoBoxButton({
    required String infoKey,
    String tooltip = '查看设置说明',
  }) {
    final appColors = context.appColors;
    final isExpanded = _expandedInfoKeys.contains(infoKey);
    final activeColor = context.colorScheme.primary;
    return Tooltip(
      message: isExpanded ? '点击收起说明' : tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _toggleInfo(infoKey),
          borderRadius: BorderRadius.circular(5),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 20,
              height: 20,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isExpanded
                    ? context.colorScheme.primaryContainer
                    : appColors.surfaceLow,
                borderRadius: BorderRadius.circular(5),
                border: Border.all(
                  color: isExpanded ? activeColor : appColors.borderSubtle,
                  width: 1.0,
                ),
              ),
              child: Icon(
                Icons.info_outline,
                size: 12,
                color: isExpanded ? activeColor : appColors.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 统一构建展开后的说明文字卡片
  Widget _buildExpandedInfoBox(String text) {
    final appColors = context.appColors;
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: appColors.surfaceLow,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: appColors.borderSubtle,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  Icons.help_outline_rounded,
                  size: 15,
                  color: context.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(
                    fontSize: 12,
                    color: appColors.textSecondary,
                    height: 1.45,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 统一的分组头部（Group Section Header）
  Widget _buildSectionHeader({
    required String title,
    Widget? trailing,
    String? infoKey,
    String? tooltip,
  }) {
    final appColors = context.appColors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Row(
        children: [
          Expanded(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: appColors.textSecondary,
                    letterSpacing: 0.2,
                  ),
                ),
                if (infoKey != null) ...[
                  const SizedBox(width: 6),
                  _buildInfoBoxButton(
                    infoKey: infoKey,
                    tooltip: tooltip ?? '查看说明',
                  ),
                ],
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }

  /// 标准连续圆角分组容器（Grouped Surface Container）
  Widget _buildGroupContainer({required List<Widget> children}) {
    final appColors = context.appColors;
    return Container(
      decoration: BoxDecoration(
        color: appColors.surfaceCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: appColors.borderSubtle,
          width: 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  /// 极浅 0.5dp 分割线
  Widget _buildDivider() {
    final appColors = context.appColors;
    return Divider(
      height: 0.5,
      thickness: 0.5,
      color: appColors.borderSubtle,
      indent: 16,
      endIndent: 16,
    );
  }

  // ==========================================
  // 模块一：外观设置（单行收敛）
  // ==========================================
  Widget _buildThemeSection() {
    final appColors = context.appColors;
    final primaryColor = context.colorScheme.primary;
    final currentMode = ThemeManager.instance.themeMode;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSectionHeader(
          title: '外观与显示',
          infoKey: 'themeCardOverview',
          tooltip: '查看深浅色外观说明',
        ),
        if (_expandedInfoKeys.contains('themeCardOverview'))
          _buildExpandedInfoBox(
            '• 浅色模式：清晰通透高对比度日间风格，适合白昼与明亮光照环境。\n'
            '• 深色模式：沉浸暗黑风格，适合夜间或低光照环境，降低屏幕功耗与视觉疲劳。\n'
            '• 跟随系统：自动读取设备系统深浅色设置并实时同步切换。',
          ),
        _buildGroupContainer(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Icon(Icons.palette_outlined, color: primaryColor, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '外观主题',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: appColors.textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 紧凑 Segmented Control：[浅色 | 深色 | 跟随系统]
                  _buildThemeSegmentedControl(currentMode, primaryColor, appColors),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildThemeSegmentedControl(
    ThemeMode currentMode,
    Color primaryColor,
    AppCustomColors appColors,
  ) {
    const segments = [
      (mode: ThemeMode.light, label: '浅色'),
      (mode: ThemeMode.dark, label: '深色'),
      (mode: ThemeMode.system, label: '跟随系统'),
    ];

    return Container(
      height: 32,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: appColors.surfaceLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: appColors.borderSubtle,
          width: 0.8,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: segments.map((item) {
          final isSelected = item.mode == currentMode;
          return InkWell(
            onTap: () async {
              await ThemeManager.instance.setThemeMode(item.mode);
              setState(() {});
              _showSnack(
                item.mode == ThemeMode.system
                    ? '已设置为跟随系统深浅色切换'
                    : item.mode == ThemeMode.dark
                        ? '已切换为深色夜间模式'
                        : '已切换为浅色日间模式',
              );
            },
            borderRadius: BorderRadius.circular(6),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeInOut,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: isSelected ? primaryColor : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                boxShadow: isSelected
                    ? [
                        BoxShadow(
                          color: primaryColor.withValues(alpha: 0.25),
                          blurRadius: 4,
                          offset: const Offset(0, 1),
                        ),
                      ]
                    : null,
              ),
              alignment: Alignment.center,
              child: Text(
                item.label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                  color: isSelected
                      ? context.colorScheme.onPrimary
                      : appColors.textSecondary,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // ==========================================
  // 模块二：端侧模型与推理设置（紧凑化管理）
  // ==========================================
  Widget _buildModelEngineSection() {
    final appColors = context.appColors;
    final primaryColor = context.colorScheme.primary;

    final isLoaded = widget.engineIndicatorDetail.contains('已常驻') ||
        widget.engineIndicatorDetail.contains('已载入') ||
        widget.engineIndicatorDetail.contains('已就绪') ||
        widget.engineIndicatorDetail.contains('0延迟就绪');
    final isLoading = widget.engineIndicatorDetail.contains('正在') ||
        LocalModelManager.isModelLoading;

    // 状态文案
    String statusTitle;
    if (isLoaded) {
      statusTitle = widget.engineIndicatorDetail.contains('已常驻')
          ? widget.engineIndicatorDetail
          : '引擎已就绪';
    } else if (isLoading) {
      statusTitle = '正在预热加载中...';
    } else {
      statusTitle = widget.engineIndicatorDetail.contains('未')
          ? widget.engineIndicatorDetail
          : '引擎待命中';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 分组头部：标题简洁为“端侧引擎”，右侧放置按钮“模型管家”
        _buildSectionHeader(
          title: '端侧引擎',
          trailing: TextButton.icon(
            onPressed: widget.onOpenModelCenter,
            icon: Icon(Icons.tune_rounded, size: 15, color: primaryColor),
            label: Text(
              '模型管家',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: primaryColor,
              ),
            ),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            ),
          ),
          infoKey: 'modelOverviewGuide',
          tooltip: '查看端侧引擎说明',
        ),
        if (_expandedInfoKeys.contains('modelOverviewGuide'))
          _buildExpandedInfoBox(
            '• 端侧推理：基于 llama.cpp 与轻量开源大模型，全程离线运行，无数据外传风险。\n'
            '• 内存常驻与预热：常驻可消除每次解析数秒的加载耗时；空闲时自动回收以平衡续航。',
          ),

        _buildGroupContainer(
          children: [
            // 1. 引擎状态与操作（单行聚合）
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  // 绿色状态呼吸灯
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isLoaded
                          ? appColors.tagWork
                          : (isLoading ? appColors.tagStudy : appColors.textTertiary),
                      boxShadow: isLoaded
                          ? [
                              BoxShadow(
                                color: appColors.tagWork.withValues(alpha: 0.5),
                                blurRadius: 5,
                                spreadRadius: 1,
                              ),
                            ]
                          : null,
                    ),
                  ),
                  const SizedBox(width: 10),
                  // 文案区（使用 Expanded 确保不截断）
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          statusTitle,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: appColors.textPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (isLoaded &&
                            LocalModelManager.currentlyLoadedModelId != null) ...[
                          const SizedBox(height: 1),
                          Text(
                            '当前模型: ${LocalModelManager.currentlyLoadedModelId}',
                            style: TextStyle(
                              fontSize: 11,
                              color: appColors.textSecondary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  // 小型次级按钮（根据状态切换为“预热”或“释放内存”）
                  OutlinedButton.icon(
                    onPressed: isLoaded
                        ? widget.onUnloadModel
                        : widget.onPreloadModel,
                    icon: Icon(
                      isLoaded ? Icons.delete_outline : Icons.bolt,
                      size: 14,
                      color: isLoaded ? appColors.textSecondary : primaryColor,
                    ),
                    label: Text(
                      isLoaded ? '释放内存' : '预热',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: isLoaded ? appColors.textSecondary : primaryColor,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      minimumSize: const Size(0, 30),
                      side: BorderSide(
                        color: isLoaded
                            ? appColors.borderSubtle
                            : primaryColor.withValues(alpha: 0.5),
                        width: 1,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            _buildDivider(),

            // 2. 深度思考开关（单行 Switch 列表项）
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '深度思考模式',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: appColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '开启 Thinking 增强，提升复杂日程解析精准度',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: appColors.textSecondary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Switch(
                    value: LocalModelManager.enableThinkMode,
                    onChanged: (val) {
                      setState(() => LocalModelManager.enableThinkMode = val);
                      AppSettingsService.instance.setEnableThinkMode(val);
                      _showSnack(
                          val ? '已开启深度思考模式' : '已关闭深度思考模式 (极速直出)');
                    },
                  ),
                ],
              ),
            ),
            _buildDivider(),

            // 3. 常驻策略选择（单行列表项，点击唤起底部 Picker）
            InkWell(
              onTap: () => _showIdleUnloadPicker(context),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '空闲内存回收',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: appColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '无提取任务后自动解除大模型内存占用',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: appColors.textSecondary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _getIdleMinutesText(LocalModelManager.idleUnloadMinutes),
                      style: TextStyle(
                        fontSize: 13,
                        color: appColors.textSecondary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.chevron_right,
                      size: 16,
                      color: appColors.textTertiary,
                    ),
                  ],
                ),
              ),
            ),

            // 4. Android 专属：展开悬浮窗时自动预热
            if (Platform.isAndroid) ...[
              _buildDivider(),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '展开悬浮窗自动预热',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: appColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '展开悬浮卡时预先唤醒大模型权重，消除冷启动耗时',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: appColors.textSecondary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Switch(
                      value: LocalModelManager.autoPreloadOnOverlayExpand,
                      onChanged: (val) {
                        setState(() =>
                            LocalModelManager.autoPreloadOnOverlayExpand = val);
                        AppSettingsService.instance
                            .setAutoPreloadOnOverlayExpand(val);
                      },
                    ),
                  ],
                ),
              ),
            ],

            _buildDivider(),
            // 5. 推理路线切换（单行列表项）
            InkWell(
              onTap: () => _showEngineModePicker(context),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '推理路线与兜底策略',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: appColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _getEngineModeText(widget.engineMode),
                            style: TextStyle(
                              fontSize: 11.5,
                              color: appColors.textSecondary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _getEngineModeShortName(widget.engineMode),
                      style: TextStyle(
                        fontSize: 13,
                        color: appColors.textSecondary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.chevron_right,
                      size: 16,
                      color: appColors.textTertiary,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _getIdleMinutesText(int minutes) {
    if (minutes <= 0) return '永不回收';
    return '$minutes 分钟';
  }

  String _getEngineModeShortName(AIEngineMode mode) {
    return switch (mode) {
      AIEngineMode.hybridAuto => '混合自动',
      AIEngineMode.builtInRuleEngine => '纯端侧极速',
      AIEngineMode.localLlmServer => '强制大模型',
    };
  }

  String _getEngineModeText(AIEngineMode mode) {
    return switch (mode) {
      AIEngineMode.hybridAuto => '优先端侧大模型，未就绪时自动极速规则兜底',
      AIEngineMode.builtInRuleEngine => '0 延迟、0 显存开销启发式规则正则',
      AIEngineMode.localLlmServer => '仅使用本地或局域网 LLM 推理',
    };
  }

  void _showIdleUnloadPicker(BuildContext context) {
    final appColors = context.appColors;
    final primaryColor = context.colorScheme.primary;
    final current = LocalModelManager.idleUnloadMinutes;

    final options = [
      {'title': '1 分钟', 'subtitle': '极速防杀，省电低功耗', 'val': 1},
      {'title': '3 分钟', 'subtitle': '快速回收显存', 'val': 3},
      {'title': '5 分钟', 'subtitle': '默认推荐，平衡体验与功耗', 'val': 5},
      {'title': '10 分钟', 'subtitle': '较长常驻，减少频繁冷启动', 'val': 10},
      {'title': '永不回收', 'subtitle': '持续常驻内存/显存', 'val': -1},
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: appColors.surfaceModal,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '空闲内存回收策略',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: appColors.textPrimary,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: () => Navigator.pop(ctx),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                ),
                Divider(
                    height: 1, thickness: 0.5, color: appColors.borderSubtle),
                ...options.map((opt) {
                  final isSelected = opt['val'] == current;
                  return ListTile(
                    title: Text(
                      opt['title'] as String,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight:
                            isSelected ? FontWeight.bold : FontWeight.normal,
                        color: isSelected ? primaryColor : appColors.textPrimary,
                      ),
                    ),
                    subtitle: Text(
                      opt['subtitle'] as String,
                      style: TextStyle(
                        fontSize: 12,
                        color: appColors.textSecondary,
                      ),
                    ),
                    trailing: isSelected
                        ? Icon(Icons.check_circle_rounded,
                            color: primaryColor, size: 20)
                        : null,
                    onTap: () {
                      final val = opt['val'] as int;
                      setState(() {
                        LocalModelManager.idleUnloadMinutes = val;
                        LocalModelManager.markActivity();
                      });
                      AppSettingsService.instance.setIdleUnloadMinutes(val);
                      Navigator.pop(ctx);
                      _showSnack(val > 0
                          ? '已设置为无任务 $val 分钟后自动释放内存'
                          : '已设置为永不自动释放');
                    },
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showEngineModePicker(BuildContext context) {
    final appColors = context.appColors;
    final primaryColor = context.colorScheme.primary;

    final options = [
      {
        'mode': AIEngineMode.hybridAuto,
        'title': '混合自动 (推荐)',
        'subtitle': '优先使用端侧大模型提取，模型未就绪或解析异常时自动由 0 延迟极速规则引擎兜底',
      },
      {
        'mode': AIEngineMode.builtInRuleEngine,
        'title': '纯端侧极速规则',
        'subtitle': '0 延迟、0 显存开销，使用启发式中文时空正则匹配，完全不占显存与电量',
      },
      {
        'mode': AIEngineMode.localLlmServer,
        'title': '强制端侧大模型',
        'subtitle': '仅使用本地或局域网 LLM 推理，不启用正则引擎兜底',
      },
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: appColors.surfaceModal,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '推理路线与兜底策略',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: appColors.textPrimary,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: () => Navigator.pop(ctx),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                ),
                Divider(
                    height: 1, thickness: 0.5, color: appColors.borderSubtle),
                ...options.map((opt) {
                  final mode = opt['mode'] as AIEngineMode;
                  final isSelected = widget.engineMode == mode;
                  return ListTile(
                    title: Text(
                      opt['title'] as String,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight:
                            isSelected ? FontWeight.bold : FontWeight.normal,
                        color: isSelected ? primaryColor : appColors.textPrimary,
                      ),
                    ),
                    subtitle: Text(
                      opt['subtitle'] as String,
                      style: TextStyle(
                        fontSize: 12,
                        color: appColors.textSecondary,
                      ),
                    ),
                    trailing: isSelected
                        ? Icon(Icons.check_circle_rounded,
                            color: primaryColor, size: 20)
                        : null,
                    onTap: () {
                      widget.onEngineModeChanged(mode);
                      Navigator.pop(ctx);
                    },
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }

  // ==========================================
  // 模块三：高级设置与推理参数微调（紧凑参数列表重构）
  // ==========================================
  Widget _buildAdvancedSection() {
    final appColors = context.appColors;
    final primaryColor = context.colorScheme.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 分组头部
        _buildSectionHeader(
          title: '高级设置',
          infoKey: 'advancedGuide',
          tooltip: '查看高级设置说明',
        ),
        if (_expandedInfoKeys.contains('advancedGuide'))
          _buildExpandedInfoBox(
            '• 系统提示词模板：支持自定义 System Prompt 并注入 {TIME_ANCHOR} 宏，配有全尺寸推理实况诊断调试终端。\n'
            '• 采样与推理参数：可针对设备显存与响应速度精细调整 Context Size、Temperature 等核心推理超参数。',
          ),

        // 统一收拢至同一个连续圆角卡片（Surface）内
        _buildGroupContainer(
          children: [
            // 1. 跳转入口优化（系统提示词模板）
            InkWell(
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => const PromptTestingPage(),
                  ),
                );
              },
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Icon(Icons.psychology_alt_outlined,
                        color: primaryColor, size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '系统提示词模板',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: appColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '系统提示词修改与测试 · 自定义 Prompt 注入时间锚点',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: appColors.textSecondary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      Icons.chevron_right,
                      size: 18,
                      color: appColors.textTertiary,
                    ),
                  ],
                ),
              ),
            ),
            _buildDivider(),

            // 2. 上下文窗口 (Context Size)
            _buildCompactParamTile(
              key: _paramContextSizeKey,
              title: '上下文窗口 (Context Size)',
              subtitle: '最大 Token 容量 · 默认 4096',
              valueBadge: '${LocalModelManager.contextSize}',
              isEditing: _activeParamConfig?.title == '上下文窗口大小 (Context Size)',
              onTap: () => _handleParamEdit(
                _ModelParamConfig(
                  title: '上下文窗口大小 (Context Size)',
                  description:
                      '控制端侧 llama.cpp 与本地推理服务分配的 KV Cache 与上下文大小。增大可支持超长复杂通知，但会成比例增加 RAM / 显存占用。',
                  unit: 'Tokens',
                  currentValue: LocalModelManager.contextSize.toDouble(),
                  min: AppSettingsService.minContextSize.toDouble(),
                  max: AppSettingsService.maxContextSize.toDouble(),
                  divisions: (AppSettingsService.maxContextSize -
                          AppSettingsService.minContextSize) ~/
                      256,
                  isInteger: true,
                  presets: const [1024, 2048, 4096, 8192, 16384],
                  anchorKey: _paramContextSizeKey,
                  onConfirm: (val) async {
                    await AppSettingsService.instance
                        .setContextSize(val.round());
                  },
                ),
              ),
            ),
            _buildDivider(),

            // 3. 思考 Token 上限 (Max Tokens)
            _buildCompactParamTile(
              key: _paramMaxTokensKey,
              title: '思考 Token 上限 (Max Tokens)',
              subtitle: '深度思考最大预算 · 默认 1024',
              valueBadge: '${LocalModelManager.maxThinkingTokens}',
              isEditing: _activeParamConfig?.title == '思考与生成 Token 上限 (Max Tokens)',
              onTap: () => _handleParamEdit(
                _ModelParamConfig(
                  title: '思考与生成 Token 上限 (Max Tokens)',
                  description:
                      '限制开启深度思考时模型允许输出的最大 Token 额度。有效防止小模型在思维链中过度自反思耗光上下文。',
                  unit: 'Tokens',
                  currentValue:
                      LocalModelManager.maxThinkingTokens.toDouble(),
                  min: AppSettingsService.minThinkingTokens.toDouble(),
                  max: AppSettingsService.maxThinkingTokensLimit.toDouble(),
                  divisions: (AppSettingsService.maxThinkingTokensLimit -
                          AppSettingsService.minThinkingTokens) ~/
                      64,
                  isInteger: true,
                  presets: const [256, 512, 1024, 1536, 2048],
                  anchorKey: _paramMaxTokensKey,
                  onConfirm: (val) async {
                    await AppSettingsService.instance
                        .setMaxThinkingTokens(val.round());
                  },
                ),
              ),
            ),
            _buildDivider(),

            // 4. 采样温度 (Temperature)
            _buildCompactParamTile(
              key: _paramTemperatureKey,
              title: '采样温度 (Temperature)',
              subtitle: '输出随机度，越低越严谨 · 默认 0.10',
              valueBadge: LocalModelManager.temperature.toStringAsFixed(2),
              isEditing: _activeParamConfig?.title == '采样温度 (Temperature)',
              onTap: () => _handleParamEdit(
                _ModelParamConfig(
                  title: '采样温度 (Temperature)',
                  description:
                      '值越低 (如 0.05~0.20)，模型越趋向于确定性输出，日程时间格式更精准；值越高，创造性和自由度越大，但格式出错概率上升。',
                  unit: '',
                  currentValue: LocalModelManager.temperature,
                  min: AppSettingsService.minTemperature,
                  max: AppSettingsService.maxTemperature,
                  divisions: 30, // 0.05 step
                  isInteger: false,
                  presets: const [0.0, 0.05, 0.10, 0.30, 0.70],
                  anchorKey: _paramTemperatureKey,
                  onConfirm: (val) async {
                    await AppSettingsService.instance.setTemperature(val);
                  },
                ),
              ),
            ),
            _buildDivider(),

            // 5. 核采样阈值 (Top-P)
            _buildCompactParamTile(
              key: _paramTopPKey,
              title: '核采样阈值 (Top-P)',
              subtitle: '候选词概率截断门限 · 默认 0.85',
              valueBadge: LocalModelManager.topP.toStringAsFixed(2),
              isEditing: _activeParamConfig?.title == '核采样阈值 (Top-P)',
              onTap: () => _handleParamEdit(
                _ModelParamConfig(
                  title: '核采样阈值 (Top-P)',
                  description:
                      '仅从累积概率达到此阈值的最高概率候选词中采样。0.85 兼顾了高确定性与常用词丰富度。',
                  unit: '',
                  currentValue: LocalModelManager.topP,
                  min: AppSettingsService.minTopP,
                  max: AppSettingsService.maxTopP,
                  divisions: 18, // 0.05 step
                  isInteger: false,
                  presets: const [0.50, 0.70, 0.85, 0.95, 1.00],
                  anchorKey: _paramTopPKey,
                  onConfirm: (val) async {
                    await AppSettingsService.instance.setTopP(val);
                  },
                ),
              ),
            ),
            _buildDivider(),

            // 6. 重复词惩罚 (Repeat Penalty)
            _buildCompactParamTile(
              key: _paramRepeatPenaltyKey,
              title: '重复词惩罚 (Repeat Penalty)',
              subtitle: '抑制自言自语死循环 · 默认 1.05',
              valueBadge: LocalModelManager.repeatPenalty.toStringAsFixed(2),
              isEditing: _activeParamConfig?.title == '重复词惩罚 (Repeat Penalty)',
              onTap: () => _handleParamEdit(
                _ModelParamConfig(
                  title: '重复词惩罚 (Repeat Penalty)',
                  description:
                      '对已生成的词施加打折惩罚（1.0 为无惩罚，1.05~1.15 为轻微惩罚），有效抑制小模型在生成长文本时的复述死循环。',
                  unit: '',
                  currentValue: LocalModelManager.repeatPenalty,
                  min: AppSettingsService.minRepeatPenalty,
                  max: AppSettingsService.maxRepeatPenalty,
                  divisions: 20, // 0.05 step
                  isInteger: false,
                  presets: const [1.00, 1.05, 1.10, 1.15, 1.25],
                  anchorKey: _paramRepeatPenaltyKey,
                  onConfirm: (val) async {
                    await AppSettingsService.instance
                        .setRepeatPenalty(val);
                  },
                ),
              ),
            ),
          ],
        ),

        // 底部轻量辅助操作：恢复参数默认值（带二次确认）
        Padding(
          padding: const EdgeInsets.only(top: 8, right: 4),
          child: Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _showResetConfirmDialog,
              icon: Icon(Icons.refresh, size: 14, color: appColors.textSecondary),
              label: Text(
                '恢复参数默认值',
                style: TextStyle(
                  fontSize: 12,
                  color: appColors.textSecondary,
                ),
              ),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 紧凑参数微调项（消除重复“调节”按钮，整行作为可点击热区）
  Widget _buildCompactParamTile({
    Key? key,
    required String title,
    required String subtitle,
    required String valueBadge,
    required VoidCallback onTap,
    bool isEditing = false,
  }) {
    final appColors = context.appColors;
    final primaryColor = context.colorScheme.primary;

    return InkWell(
      key: key,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        color: isEditing
            ? primaryColor.withValues(alpha: 0.08)
            : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(
          children: [
            // 左侧说明区（主标题带中英文对照，副标题单行简述默认值）
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: isEditing ? primaryColor : appColors.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: appColors.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            // 右侧展示区：数值徽章（等宽代码字体）
            Container(
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
                valueBadge,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12.5,
                  fontWeight: FontWeight.bold,
                  color: isEditing ? primaryColor : appColors.textPrimary,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.chevron_right,
              size: 16,
              color: isEditing ? primaryColor : appColors.textTertiary,
            ),
          ],
        ),
      ),
    );
  }

  void _showResetConfirmDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('恢复参数默认值'),
        content: const Text(
            '确定将上下文大小、采样温度、Top-P 等所有模型采样参数重置为初始默认值吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              await AppSettingsService.instance.resetModelParamsToDefault();
              if (_activeParamConfig != null) {
                _closeParamDrawer();
              }
              if (mounted) setState(() {});
              _showSnack('已重置所有推理与采样参数为默认值');
            },
            child: const Text('确定恢复'),
          ),
        ],
      ),
    );
  }

  // ==========================================
  // 模块四：Android 悬浮窗与识屏
  // ==========================================
  Widget _buildAndroidFloatingSection() {
    final appColors = context.appColors;
    final primaryColor = context.colorScheme.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSectionHeader(
          title: 'Android 悬浮窗与识屏',
          infoKey: 'androidFloatingGuide',
          tooltip: '查看悬浮窗采集说明',
        ),
        if (_expandedInfoKeys.contains('androidFloatingGuide'))
          _buildExpandedInfoBox(
            '1. 零跳转全局悬浮卡：贴边胶囊在微信/QQ/浏览器上方原地展开，支持：\n'
            '   • 🖥️ 读屏幕文字：通过无障碍节点树 0ms 直读屏幕文字\n'
            '   • 📸 截屏 OCR：静默截屏并使用 ML Kit 离线中文 OCR 识别海报\n'
            '   • 📋 读剪贴板：焦点切换时自动提取复制的文本并静默入历\n'
            '2. 系统划词与分享：选中文字点击「分享 -> 知程」即可一键解析。',
          ),
        _buildGroupContainer(
          children: [
            // 全局悬浮窗开关
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '零跳转全局悬浮卡',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: appColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '点击贴边胶囊在其他应用上方原地呼出，支持 0ms 直读屏幕',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: appColors.textSecondary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Switch(
                    value: _floatingRunning,
                    onChanged: (val) async {
                      final res = await FloatingOverlayService.instance
                          .toggleFloatingWindow(val);
                      await _checkNativeState();
                      if (res['message'] != null) {
                        _showSnack(res['message'].toString());
                      }
                    },
                  ),
                ],
              ),
            ),
            _buildDivider(),

            // 无障碍识屏服务
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '无障碍识屏与静默截屏服务',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: appColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _accessibilityEnabled
                              ? '已激活 · 支持 0ms 读屏 + 离线中文 OCR'
                              : '未开启 · 点击开启权限以支持读屏与静默截屏',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: _accessibilityEnabled
                                ? appColors.tagWork
                                : appColors.tagStudy,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () async {
                      await FloatingOverlayService.instance
                          .openAccessibilitySettings();
                      _showSnack('请在系统无障碍设置中开启「知程 AI 识屏与静默截屏助手」');
                    },
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      side: BorderSide(
                        color: _accessibilityEnabled
                            ? appColors.borderSubtle
                            : primaryColor,
                        width: 1,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: Text(
                      _accessibilityEnabled ? '已激活' : '开启权限',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _accessibilityEnabled
                            ? appColors.textSecondary
                            : primaryColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ==========================================
  // 模块五：日历双向同步
  // ==========================================
  Widget _buildCalendarSyncSection() {
    final appColors = context.appColors;
    final primaryColor = context.colorScheme.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSectionHeader(
          title: '日历双向同步',
          infoKey: 'calendarSyncGuide',
          tooltip: '查看系统日历同步说明',
        ),
        if (_expandedInfoKeys.contains('calendarSyncGuide'))
          _buildExpandedInfoBox(
            '1. 双向同步：支持从系统日历导入已有事件，亦可将知程日程一键批量推送入系统日历。\n'
            '2. 同步删除联动：在知程中删除已同步的日程时，可自动静默抹除系统日历中的对应事件，两端始终保持整洁一致。\n'
            '3. 跨平台支持：Android 端直连系统 CalendarProvider，Windows 端基于 ICS 互通。',
          ),
        _buildGroupContainer(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '联动删除系统日历对应事件',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: appColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '在知程日程中删除已同步事项时，同步从底层日历抹除',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: appColors.textSecondary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Switch(
                    value: AppSettingsService.instance.syncDeleteFromSystemCalendar,
                    onChanged: (val) async {
                      await AppSettingsService.instance
                          .setSyncDeleteFromSystemCalendar(val);
                      setState(() {});
                    },
                  ),
                ],
              ),
            ),
            _buildDivider(),
            InkWell(
              onTap: () async {
                final res =
                    await CalendarSyncService.instance.performTwoWaySync();
                if (!mounted) return;
                _showSnack('🎉 ${res.summary}');
              },
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Icon(Icons.sync, color: primaryColor, size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '立即执行双向同步',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: appColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '从底层系统日历导入日程并将本地新增日程推送入历',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: appColors.textSecondary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      Icons.chevron_right,
                      size: 18,
                      color: appColors.textTertiary,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ==========================================
  // 模块六：局域网协同
  // ==========================================
  Widget _buildLanSyncSection() {
    final appColors = context.appColors;
    final primaryColor = context.colorScheme.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSectionHeader(
          title: '局域网协同与算力借调',
          infoKey: 'lanSyncGuide',
          tooltip: '查看局域网协同说明',
        ),
        if (_expandedInfoKeys.contains('lanSyncGuide'))
          _buildExpandedInfoBox(
            '• 双向日程合并：在同一 Wi-Fi 局域网下输入对端设备 IP 点击同步，自动合并两端所有日程并智能去重。\n'
            '• 跨设备算力借调：移动端可配置 PC 端的局域网 IP，免去手机运行大模型的发热和电量消耗，借调 PC 高性能算力秒级解析。',
          ),
        _buildGroupContainer(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.hub_outlined, color: primaryColor, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '本机协同地址 (端口 ${LanSyncService.defaultPort})',
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: appColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 3),
                        SelectableText(
                          widget.localIps.isEmpty
                              ? '未连接局域网 Wi-Fi'
                              : widget.localIps.join(' / '),
                          style: TextStyle(
                            fontSize: 12,
                            color: appColors.textSecondary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            _buildDivider(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: widget.peerIpController,
                      style: TextStyle(
                        fontSize: 13,
                        color: appColors.textPrimary,
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        labelText: '对端设备 IP (同步 / 借调算力)',
                        labelStyle: TextStyle(
                          fontSize: 12,
                          color: appColors.textSecondary,
                        ),
                        hintText: '如 192.168.x.x',
                        hintStyle: TextStyle(
                          fontSize: 12,
                          color: appColors.textTertiary,
                        ),
                        filled: true,
                        fillColor: appColors.surfaceLow,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 8),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(color: appColors.borderSubtle),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(color: appColors.borderSubtle),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonalIcon(
                    onPressed: () async {
                      final ip = widget.peerIpController.text.trim();
                      if (ip.isEmpty) {
                        _showSnack('请先输入对端设备的局域网 IP');
                        return;
                      }
                      await AppSettingsService.instance.setPeerIp(ip);
                      try {
                        final currentEvents =
                            AgendaRepository.instance.allEvents;
                        final merged = await LanSyncService.syncWithPeer(
                          peerIp: ip,
                          localEvents: currentEvents,
                        );
                        await AgendaRepository.instance
                            .mergeRemoteEvents(merged);
                        _showSnack('🎉 双端同步成功！当前共 ${merged.length} 项日程');
                      } catch (e) {
                        _showSnack('同步失败: $e');
                      }
                    },
                    icon: const Icon(Icons.sync, size: 15),
                    label: const Text('同步', style: TextStyle(fontSize: 12)),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      minimumSize: const Size(0, 36),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ==========================================
  // 模块七：关于知程
  // ==========================================
  Widget _buildAboutSection() {
    final appColors = context.appColors;
    final primaryColor = context.colorScheme.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSectionHeader(
          title: '关于',
          infoKey: 'aboutGuide',
          tooltip: '查看隐私与技术栈说明',
        ),
        if (_expandedInfoKeys.contains('aboutGuide'))
          _buildExpandedInfoBox(
            '• 100% 端侧隐私安全：通知文本与日程数据全程在本地设备离线解析，无任何云端上传统计。\n'
            '• 技术架构：Flutter + llama.cpp (Vulkan GPU/ARM NEON) + Google ML Kit 离线中文 OCR。\n'
            '• 开源许可：遵循 MIT 开源协议，专为高校通知与多节点日程痛点打造。',
          ),
        _buildGroupContainer(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Icon(Icons.verified, color: primaryColor, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '知程 Anno2Agenda v1.2.0',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: appColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '100% 端侧隐私安全 · 跨平台多端协同 · MIT 开源',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: appColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ==========================================
  // 通用参数抽屉表单构建
  // ==========================================
  Widget _buildParamEditorForm({
    required _ModelParamConfig config,
    required Color primaryColor,
    required StateSetter updateState,
    required VoidCallback onClose,
  }) {
    final colors = context.appColors;

    void updateValue(double val) {
      final clamped = val.clamp(config.min, config.max);
      updateState(() {
        _tempParamValue = clamped;
        _paramTextController.text = config.isInteger
            ? clamped.round().toString()
            : clamped.toStringAsFixed(2);
      });
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. 详细说明卡片
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colors.surfaceLow,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: colors.borderSubtle,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(Icons.info_outline, size: 16, color: primaryColor),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  config.description,
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.textSecondary,
                    height: 1.45,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // 2. 当前设定值卡片与文本框精准输入
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: colors.surfaceLow,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: colors.borderSubtle,
            ),
          ),
          child: Row(
            children: [
              Text(
                '设定数值：',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: colors.textPrimary,
                ),
              ),
              const Spacer(),
              SizedBox(
                width: 120,
                child: TextField(
                  controller: _paramTextController,
                  keyboardType: TextInputType.numberWithOptions(
                    decimal: !config.isInteger,
                  ),
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: primaryColor,
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    suffixText: config.unit.isNotEmpty ? ' ${config.unit}' : null,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  onSubmitted: (valStr) {
                    final parsed = double.tryParse(valStr);
                    if (parsed != null) {
                      updateValue(parsed);
                    }
                  },
                  onChanged: (valStr) {
                    final parsed = double.tryParse(valStr);
                    if (parsed != null &&
                        parsed >= config.min &&
                        parsed <= config.max) {
                      updateState(() {
                        _tempParamValue = parsed;
                      });
                    }
                  },
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // 3. 滑块快速调节
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: primaryColor,
            thumbColor: primaryColor,
          ),
          child: Slider(
            value: _tempParamValue.clamp(config.min, config.max),
            min: config.min,
            max: config.max,
            divisions: config.divisions > 0 ? config.divisions : null,
            label: config.isInteger
                ? '${_tempParamValue.round()} ${config.unit}'
                : '${_tempParamValue.toStringAsFixed(2)} ${config.unit}',
            onChanged: (val) {
              updateValue(config.isInteger ? val.roundToDouble() : val);
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '最小: ${config.isInteger ? config.min.round() : config.min.toStringAsFixed(2)} ${config.unit}',
                style: TextStyle(
                  fontSize: 11,
                  color: colors.textTertiary,
                ),
              ),
              Text(
                '最大: ${config.isInteger ? config.max.round() : config.max.toStringAsFixed(2)} ${config.unit}',
                style: TextStyle(
                  fontSize: 11,
                  color: colors.textTertiary,
                ),
              ),
            ],
          ),
        ),

        // 4. 快速预设档位
        if (config.presets.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            '常用推荐预设档位：',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: config.presets.map((p) {
              final isSelected = config.isInteger
                  ? (_tempParamValue.round() == p.round())
                  : ((_tempParamValue - p).abs() < 0.01);
              final pStr =
                  config.isInteger ? '${p.round()}' : p.toStringAsFixed(2);
              return InkWell(
                onTap: () => updateValue(p),
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? primaryColor.withValues(alpha: 0.15)
                        : colors.surfaceLow,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: isSelected ? primaryColor : colors.borderSubtle,
                    ),
                  ),
                  child: Text(
                    pStr,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight:
                          isSelected ? FontWeight.bold : FontWeight.normal,
                      color: isSelected ? primaryColor : colors.textPrimary,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
        const SizedBox(height: 24),

        // 5. 保存与取消操作按钮
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: onClose,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: const Text('取消'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: FilledButton.icon(
                onPressed: () async {
                  final finalVal = (double.tryParse(_paramTextController.text) ??
                          _tempParamValue)
                      .clamp(config.min, config.max);
                  await config.onConfirm(
                      config.isInteger ? finalVal.roundToDouble() : finalVal);
                  onClose();
                  if (mounted) setState(() {});
                  _showSnack(
                      '已更新 ${config.title}：${config.isInteger ? finalVal.round() : finalVal.toStringAsFixed(2)} ${config.unit}');
                },
                icon: const Icon(Icons.check, size: 18),
                label: const Text('保存修改'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 构建桌面端右侧滑出抽屉内容
  Widget _buildDesktopDrawerContent(
    _ModelParamConfig config,
    Color primaryColor,
  ) {
    return StatefulBuilder(
      builder: (context, setDrawerState) {
        final colors = context.appColors;
        return Container(
          width: 380,
          color: colors.surfaceModal,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
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
                      child: Icon(Icons.tune, color: primaryColor, size: 18),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            config.title,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: colors.textPrimary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '调节推理参数并保存生效',
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
                      onPressed: _closeParamDrawer,
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
              ),
              Divider(height: 1, thickness: 1, color: colors.borderSubtle),
              // Body
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: _buildParamEditorForm(
                    config: config,
                    primaryColor: primaryColor,
                    updateState: setDrawerState,
                    onClose: _closeParamDrawer,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 构建移动端底部滑出 Bottom Sheet 内容
  Widget _buildMobileBottomSheetContent(
    BuildContext ctx,
    _ModelParamConfig config,
    Color primaryColor,
  ) {
    return StatefulBuilder(
      builder: (context, setSheetState) {
        final colors = context.appColors;
        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.75,
          ),
          decoration: BoxDecoration(
            color: colors.surfaceModal,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            boxShadow: [
              BoxShadow(
                color: context.colorScheme.shadow.withValues(alpha: 0.25),
                blurRadius: 16,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 10, bottom: 6),
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colors.borderSubtle,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    Icon(Icons.tune, color: primaryColor, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        config.title,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: colors.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => Navigator.of(ctx).pop(),
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: colors.borderSubtle),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: _buildParamEditorForm(
                    config: config,
                    primaryColor: primaryColor,
                    updateState: setSheetState,
                    onClose: () => Navigator.of(ctx).pop(),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 构建桌面端左侧 Side Nav 设置分类索引导航栏
  Widget _buildSideNav(Color primaryColor) {
    final sections = _getSections();
    final colors = context.appColors;

    return Container(
      width: 200,
      decoration: BoxDecoration(
        color: colors.surfaceCard,
        border: Border(
          right: BorderSide(
            color: colors.borderSubtle,
            width: 1,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
            child: Row(
              children: [
                Icon(Icons.tune_rounded, size: 18, color: primaryColor),
                const SizedBox(width: 8),
                Text(
                  '设置导航',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: colors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, thickness: 1, color: colors.borderSubtle),
          const SizedBox(height: 6),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              itemCount: sections.length,
              itemBuilder: (context, index) {
                final item = sections[index];
                final isSelected = _activeNavIndex == index;

                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => _scrollToSection(index, item.key),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 9),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? primaryColor.withValues(alpha: 0.12)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: isSelected
                                ? primaryColor.withValues(alpha: 0.25)
                                : Colors.transparent,
                            width: 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              item.icon,
                              size: 17,
                              color: isSelected
                                  ? primaryColor
                                  : colors.textSecondary,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                item.label,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: isSelected
                                      ? FontWeight.bold
                                      : FontWeight.w500,
                                  color: isSelected
                                      ? primaryColor
                                      : colors.textPrimary,
                                ),
                              ),
                            ),
                            if (isSelected)
                              Container(
                                width: 4,
                                height: 14,
                                decoration: BoxDecoration(
                                  color: primaryColor,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Divider(height: 1, thickness: 1, color: colors.borderSubtle),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Icon(
                  Icons.verified_outlined,
                  size: 14,
                  color: colors.textTertiary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '知程 Anno2Agenda v1.2.0',
                    style: TextStyle(
                      fontSize: 11,
                      color: colors.textTertiary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 构建各分类分组内容列表
  Widget _buildSettingsContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KeyedSubtree(key: _themeKey, child: _buildThemeSection()),
        KeyedSubtree(key: _modelKey, child: _buildModelEngineSection()),
        if (Platform.isAndroid)
          KeyedSubtree(
              key: _floatingKey, child: _buildAndroidFloatingSection()),
        KeyedSubtree(key: _calendarKey, child: _buildCalendarSyncSection()),
        KeyedSubtree(key: _lanKey, child: _buildLanSyncSection()),
        KeyedSubtree(key: _advancedKey, child: _buildAdvancedSection()),
        KeyedSubtree(key: _aboutKey, child: _buildAboutSection()),
        const SizedBox(height: 48),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = context.colorScheme.primary;
    final colors = context.appColors;

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 880;

        if (isWide) {
          final isDrawerOpen = _activeParamConfig != null;

          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildSideNav(primaryColor),
              Expanded(
                child: Scrollbar(
                  controller: _scrollController,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 16),
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 820),
                        child: _buildSettingsContent(),
                      ),
                    ),
                  ),
                ),
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeInOutCubic,
                width: isDrawerOpen ? 380 : 0,
                decoration: BoxDecoration(
                  color: colors.surfaceModal,
                  border: Border(
                    left: BorderSide(
                      color: colors.borderSubtle,
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
                    ? _buildDesktopDrawerContent(
                        _activeParamConfig!,
                        primaryColor,
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          );
        } else {
          return Scrollbar(
            controller: _scrollController,
            child: SingleChildScrollView(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 14),
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 820),
                  child: _buildSettingsContent(),
                ),
              ),
            ),
          );
        }
      },
    );
  }
}
