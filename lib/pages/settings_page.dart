import 'dart:io';
import 'package:flutter/material.dart';
import '../repositories/agenda_repository.dart';
import '../services/ai_extractor_service.dart';
import '../services/app_settings_service.dart';
import '../services/floating_overlay_service.dart';
import '../services/lan_sync_service.dart';
import '../services/local_model_manager.dart';
import '../services/theme_manager.dart' hide AppTheme;
import '../theme/app_theme.dart';
import '../widgets/app_toast.dart';
import '../widgets/calendar_sync_dialog.dart';
import '../widgets/model_center_dialog.dart';
import 'prompt_testing_page.dart';

/// 「设置」页面（大模型常驻、Android 原生无障碍悬浮窗、局域网协同与关于）
class SettingsPage extends StatefulWidget {
  final AIEngineMode engineMode;
  final ValueChanged<AIEngineMode> onEngineModeChanged;
  final String engineIndicatorDetail;
  final VoidCallback onPreloadModel;
  final VoidCallback onUnloadModel;
  final VoidCallback? onOpenModelCenter;
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
    this.onOpenModelCenter,
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
  final GlobalKey _cloudKey = GlobalKey();
  final GlobalKey _modelKey = GlobalKey();
  final GlobalKey _floatingKey = GlobalKey();
  final GlobalKey _calendarKey = GlobalKey();
  final GlobalKey _lanKey = GlobalKey();
  final GlobalKey _advancedKey = GlobalKey();
  final GlobalKey _aboutKey = GlobalKey();

  // 抽屉与参数锚点 GlobalKey，用于桌面/移动端背景定位
  final GlobalKey _paramCloudManagerKey = GlobalKey();
  final GlobalKey _paramCloudModelSelectKey = GlobalKey();
  final GlobalKey _paramModelManagerKey = GlobalKey();
  final GlobalKey _paramIdleUnloadKey = GlobalKey();
  final GlobalKey _paramEngineModeKey = GlobalKey();
  final GlobalKey _paramDesktopBackendKey = GlobalKey();
  final GlobalKey _paramCalendarSyncKey = GlobalKey();
  final GlobalKey _paramContextSizeKey = GlobalKey();
  final GlobalKey _paramMaxTokensKey = GlobalKey();
  final GlobalKey _paramTemperatureKey = GlobalKey();
  final GlobalKey _paramTopPKey = GlobalKey();
  final GlobalKey _paramRepeatPenaltyKey = GlobalKey();

  // 当前激活的抽屉标识（可以是参数 title、'cloudServiceManager'、'cloudModelSelector'、'modelManager'、'idleUnload'、'engineMode'、'desktopBackend' 或 'calendarSync'）
  String? _activeDrawerId;
  _ModelParamConfig? _activeParamConfig;
  double _tempParamValue = 0.0;
  final TextEditingController _paramTextController = TextEditingController();
  final TextEditingController _cloudUrlController = TextEditingController();
  final TextEditingController _cloudKeyController = TextEditingController();
  bool _obscureCloudKey = true;
  String? _cloudDrawerFeedback;
  bool _cloudDrawerFeedbackSuccess = false;
  int _cloudServiceStep = 0;
  bool _isFavoriteDropdownExpanded = false;
  bool _isFetchingCloudModels = false;

  final ScrollController _scrollController = ScrollController();
  int _activeNavIndex = 0;
  bool _isAutoScrolling = false;
  bool _isWide = false;

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
    _cloudUrlController.dispose();
    _cloudKeyController.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    FloatingOverlayService.instance.isRunningNotifier
        .removeListener(_onFloatingRunningChanged);
    super.dispose();
  }

  void _closeDrawer() {
    if (mounted) {
      setState(() {
        _activeDrawerId = null;
        _activeParamConfig = null;
      });
    }
  }

  void _handleParamEdit(_ModelParamConfig config) {
    if (_activeDrawerId == config.title) {
      _closeDrawer();
      return;
    }

    final isWide = _isWide;
    if (isWide) {
      _openDesktopParameterDrawer(config);
    } else {
      _openMobileParameterDrawer(config);
    }
  }

  void _openDesktopParameterDrawer(_ModelParamConfig config) {
    setState(() {
      _activeDrawerId = config.title;
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
      _activeDrawerId = config.title;
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
        return _buildMobileParamBottomSheet(
          ctx,
          config,
          primaryColor,
        );
      },
    );

    if (mounted) {
      setState(() {
        _activeDrawerId = null;
        _activeParamConfig = null;
      });
    }
  }

  /// 通用自定义选项抽屉打开（空闲内存回收、推理路线等）
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
    if (_activeDrawerId == drawerId) {
      _closeDrawer();
      return;
    }

    final isWide = _isWide;
    if (isWide) {
      setState(() {
        _activeDrawerId = drawerId;
        _activeParamConfig = null;
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
        _activeParamConfig = null;
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

  List<_SettingsNavSection> _getSections() {
    return [
      _SettingsNavSection(
        id: 'theme',
        label: '外观主题',
        icon: Icons.palette_outlined,
        key: _themeKey,
      ),
      _SettingsNavSection(
        id: 'cloud',
        label: '云端引擎',
        icon: Icons.cloud_outlined,
        key: _cloudKey,
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
    AppToast.show(context, msg);
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

  /// 统一的紧凑参数/选项微调项（带统一左侧图标、标题副标题、圆角矩形 Badge、选中展开行变色与全行热区点击）
  Widget _buildCompactParamTile({
    Key? key,
    required IconData icon,
    required String title,
    required String subtitle,
    String? valueBadge,
    Widget? badgeWidget,
    required VoidCallback? onTap,
    bool isEditing = false,
    bool enabled = true,
  }) {
    final appColors = context.appColors;
    final primaryColor = context.colorScheme.primary;
    final effectiveEditing = enabled && isEditing;

    return InkWell(
      key: key,
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        color: effectiveEditing
            ? primaryColor.withValues(alpha: 0.08)
            : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(
          children: [
            Icon(
              icon,
              size: 20,
              color: enabled ? primaryColor : appColors.textTertiary,
            ),
            const SizedBox(width: 12),
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
                      color: !enabled
                          ? appColors.textTertiary
                          : (effectiveEditing
                              ? primaryColor
                              : appColors.textPrimary),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: !enabled
                          ? appColors.textTertiary
                          : (effectiveEditing
                              ? primaryColor.withValues(alpha: 0.8)
                              : appColors.textSecondary),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            // 右侧展示区：圆角矩形 Badge（等宽代码字体或自定义 Badge 状态组件）
            if (badgeWidget != null)
              badgeWidget
            else if (valueBadge != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: effectiveEditing
                      ? primaryColor.withValues(alpha: 0.16)
                      : appColors.surfaceLow,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: effectiveEditing
                        ? primaryColor
                        : appColors.borderSubtle,
                    width: 0.8,
                  ),
                ),
                child: Text(
                  valueBadge,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12.5,
                    fontWeight: FontWeight.bold,
                    color: !enabled
                        ? appColors.textTertiary
                        : (effectiveEditing
                            ? primaryColor
                            : appColors.textPrimary),
                  ),
                ),
              ),
            const SizedBox(width: 4),
            Icon(
              Icons.chevron_right,
              size: 16,
              color: effectiveEditing ? primaryColor : appColors.textTertiary,
            ),
          ],
        ),
      ),
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
  // 模块二（前）：云端大模型引擎（OpenAI-Compatible）
  // ==========================================
  static const List<Map<String, String>> _cloudProviderPresets = [
    {
      'name': 'DeepSeek',
      'tag': '高性价比推理',
      'url': 'https://api.deepseek.com/v1',
      'model': 'deepseek-chat',
    },
    {
      'name': '硅基流动 SiliconFlow',
      'tag': '国内高速',
      'url': 'https://api.siliconflow.cn/v1',
      'model': 'Qwen/Qwen2.5-7B-Instruct',
    },
    {
      'name': '阿里云百炼',
      'tag': 'Qwen 官方',
      'url': 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      'model': 'qwen-plus',
    },
    {
      'name': 'OpenAI 官方',
      'tag': '标准接口',
      'url': 'https://api.openai.com/v1',
      'model': 'gpt-4o-mini',
    },
  ];

  Widget _buildCloudEngineSection() {
    final appColors = context.appColors;
    final primaryColor = context.colorScheme.primary;
    final settings = AppSettingsService.instance;
    final isCloudEnabled = settings.enableCloudEngine;
    final isConfigured = settings.isCloudConfigured;
    final connState = AIExtractorService.cloudConnectionState;
    final isConnected = connState == CloudConnectionState.connected;
    final isTesting = connState == CloudConnectionState.testing;
    final isError = connState == CloudConnectionState.error;

    final statusColor = isConnected
        ? appColors.tagWork
        : (isTesting
            ? appColors.tagStudy
            : (isError ? context.colorScheme.error : appColors.textTertiary));

    final String statusTitle;
    if (isConnected) {
      statusTitle = '引擎已就绪';
    } else if (isTesting) {
      statusTitle = '正在检测连接中...';
    } else if (isError) {
      statusTitle = '连接异常';
    } else {
      statusTitle = '引擎待命中';
    }

    final effectiveModel = AIExtractorService.getEffectiveCloudModel(
      settings.cloudApiUrl,
      settings.cloudModelName,
    );
    final latency = AIExtractorService.lastCloudLatencyMs;
    final String statusSubtitle;
    if (isConnected) {
      statusSubtitle =
          '当前模型: $effectiveModel · 网络通畅${latency != null ? " (${latency}ms)" : ""}';
    } else if (isTesting) {
      statusSubtitle = '正在检测 API 提供商网络通畅性...';
    } else if (isError) {
      statusSubtitle = AIExtractorService.cloudStatusDetail;
    } else if (isConfigured) {
      statusSubtitle = '当前模型: $effectiveModel · 点击测试连接';
    } else {
      statusSubtitle = '暂未配置 API 地址与密钥';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSectionHeader(
          title: '云端引擎',
          infoKey: 'cloudOverviewGuide',
          tooltip: '查看云端引擎说明',
        ),
        if (_expandedInfoKeys.contains('cloudOverviewGuide'))
          _buildExpandedInfoBox(
            '• 云端大模型推理：支持接入 OpenAI-Compatible 格式的云端大模型接口（DeepSeek、通义千问、OpenAI 等），提升超长复杂通知解析准确度。\n'
            '• 隐私提醒与回退：启用后通知文本会发送至您配置的第三方 API 提供商；若云端超时或异常，系统将自动无缝回退至端侧引擎。',
          ),
        _buildGroupContainer(
          children: [
            // 1. 启动云端引擎 - 开关（首次点击弹出风险提示 Modal 窗）
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Icon(Icons.cloud_outlined, color: primaryColor, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '启动云端引擎',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: appColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '开启后优先调用 OpenAI 兼容云端大模型协同解析日程',
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
                    key: const Key('cloud_engine_master_switch'),
                    value: isCloudEnabled,
                    onChanged: _handleCloudEngineSwitchChanged,
                  ),
                ],
              ),
            ),
            _buildDivider(),

            // 下方三栏在未开启「启动云端引擎」时统一置灰并禁用交互
            Opacity(
              opacity: isCloudEnabled ? 1.0 : 0.45,
              child: IgnorePointer(
                ignoring: !isCloudEnabled,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 2. 服务管家 - 调出抽屉（填写 OpenAI-Compatible API 地址与 Key，拉取并收藏模型）
                    _buildCompactParamTile(
                      key: _paramCloudManagerKey,
                      icon: Icons.dns_outlined,
                      title: '服务管家',
                      subtitle: '配置 OpenAI-Compatible 格式 API 地址与密钥',
                      valueBadge: _getCloudManagerBadge(),
                      enabled: isCloudEnabled,
                      isEditing: _activeDrawerId == 'cloudServiceManager',
                      onTap: isCloudEnabled
                          ? () => _openCloudServiceManagerDrawer(primaryColor)
                          : null,
                    ),
                    _buildDivider(),

                    // 3. 选择模型 - 调出模型选择抽屉（草图结构：拉取列表 / 收藏 / 全部）
                    _buildCompactParamTile(
                      key: _paramCloudModelSelectKey,
                      icon: Icons.model_training_outlined,
                      title: '选择模型',
                      subtitle: '从收藏或全部服务商模型列表中选用推理模型',
                      valueBadge: _getCloudSelectedModelBadge(),
                      enabled: isCloudEnabled,
                      isEditing: _activeDrawerId == 'cloudModelSelector',
                      onTap: isCloudEnabled
                          ? () => _openCloudModelSelectorDrawer(primaryColor)
                          : null,
                    ),
                    _buildDivider(),

                    // 4. 云端模型状态（同端侧状态球机制与顺序，预热键改为测试连接按键）
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 20,
                            height: 20,
                            child: Center(
                              child: OverflowBox(
                                maxWidth: 24,
                                maxHeight: 24,
                                child: Container(
                                  width: 24,
                                  height: 24,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: statusColor.withValues(
                                      alpha: isConnected
                                          ? 0.14
                                          : (isTesting ? 0.12 : 0.06),
                                    ),
                                    border: Border.all(
                                      color: statusColor,
                                      width: 1.6,
                                    ),
                                    boxShadow: isConnected
                                        ? [
                                            BoxShadow(
                                              color: statusColor.withValues(
                                                  alpha: 0.45),
                                              blurRadius: 6,
                                              spreadRadius: 1,
                                            ),
                                          ]
                                        : (isTesting
                                            ? [
                                                BoxShadow(
                                                  color: statusColor.withValues(
                                                      alpha: 0.35),
                                                  blurRadius: 4,
                                                  spreadRadius: 0.5,
                                                ),
                                              ]
                                            : null),
                                  ),
                                  child: Icon(
                                    Icons.cloud_done_outlined,
                                    size: 13,
                                    color: statusColor,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  statusTitle,
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w600,
                                    color: isCloudEnabled
                                        ? appColors.textPrimary
                                        : appColors.textTertiary,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 1),
                                Text(
                                  statusSubtitle,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: isCloudEnabled
                                        ? appColors.textSecondary
                                        : appColors.textTertiary,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          OutlinedButton.icon(
                            onPressed: (isCloudEnabled && !isTesting)
                                ? () => _handleTestCloudConnection()
                                : null,
                            icon: isTesting
                                ? SizedBox(
                                    width: 12,
                                    height: 12,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 1.8,
                                      color: primaryColor,
                                    ),
                                  )
                                : Icon(
                                    isConnected
                                        ? Icons.wifi_tethering
                                        : Icons.network_check,
                                    size: 14,
                                    color: isCloudEnabled
                                        ? (isConnected
                                            ? appColors.tagWork
                                            : primaryColor)
                                        : appColors.textTertiary,
                                  ),
                            label: Text(
                              isTesting ? '测试中...' : '测试连接',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: isCloudEnabled
                                    ? (isConnected
                                        ? appColors.tagWork
                                        : primaryColor)
                                    : appColors.textTertiary,
                              ),
                            ),
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                              minimumSize: const Size(0, 30),
                              side: BorderSide(
                                color: isCloudEnabled
                                    ? (isConnected
                                        ? appColors.tagWork
                                            .withValues(alpha: 0.5)
                                        : primaryColor.withValues(alpha: 0.5))
                                    : appColors.borderSubtle,
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

                    // 4. 深度思考模式 - 开关按钮
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                      child: Row(
                        children: [
                          Icon(
                            Icons.psychology_outlined,
                            color: isCloudEnabled
                                ? primaryColor
                                : appColors.textTertiary,
                            size: 20,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '深度思考模式',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: isCloudEnabled
                                        ? appColors.textPrimary
                                        : appColors.textTertiary,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '开启云端 Thinking 增强，提升复杂日程解析精准度',
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    color: isCloudEnabled
                                        ? appColors.textSecondary
                                        : appColors.textTertiary,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Switch(
                            key: const Key('cloud_think_mode_switch'),
                            value: settings.enableCloudThinkMode,
                            onChanged: isCloudEnabled
                                ? (val) {
                                    AppSettingsService.instance
                                        .setEnableCloudThinkMode(val);
                                    setState(() {});
                                    _showSnack(
                                      val
                                          ? '已开启云端深度思考模式'
                                          : '已关闭云端深度思考模式 (极速直出)',
                                    );
                                  }
                                : null,
                          ),
                        ],
                      ),
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

  String _getCloudManagerBadge() {
    final settings = AppSettingsService.instance;
    if (!settings.isCloudConfigured) return '未配置';
    return '已配置';
  }

  String _getCloudSelectedModelBadge() {
    final settings = AppSettingsService.instance;
    final model = settings.cloudModelName.trim();
    if (model.isEmpty || !settings.isFavoriteCloudModelAvailable(model)) {
      return '未选择';
    }
    return model.length > 14 ? '${model.substring(0, 12)}..' : model;
  }

  Future<void> _handleCloudEngineSwitchChanged(bool val) async {
    final settings = AppSettingsService.instance;
    if (!val) {
      settings.setEnableCloudEngine(false);
      if (_activeDrawerId == 'cloudServiceManager' ||
          _activeDrawerId == 'cloudModelSelector') {
        _closeDrawer();
      }
      if (mounted) setState(() {});
      widget.onStateRefreshed();
      _showSnack('已关闭云端引擎，将使用端侧引擎处理日程');
      return;
    }

    if (!settings.cloudRiskAccepted) {
      final confirmed = await _showCloudRiskConfirmDialog();
      if (confirmed != true) return;
      settings.setCloudRiskAccepted(true);
    }

    settings.setEnableCloudEngine(true);
    if (mounted) setState(() {});
    widget.onStateRefreshed();
    _showSnack(
      settings.isCloudConfigured
          ? '☁️ 已启用云端大模型引擎'
          : '☁️ 已启用云端引擎，请点击服务管家填写 API 地址与密钥',
    );
  }

  Future<bool?> _showCloudRiskConfirmDialog() {
    final colors = context.appColors;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surfaceModal,
        title: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: colors.tagStudy),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '启用云端引擎风险提示',
                style: TextStyle(
                  fontSize: 16.5,
                  fontWeight: FontWeight.bold,
                  color: colors.textPrimary,
                ),
              ),
            ),
          ],
        ),
        content: Text(
          '开启云端大模型引擎后，待解析的通知文本与提示词将会通过网络发送至您所配置的第三方 OpenAI-Compatible API 服务提供商进行推理。\n\n'
          '• 请勿上传涉密文件、密码或高度敏感的个人隐私信息；\n'
          '• 请妥善保管您的 API Key 并留意服务商计费与速率限制；\n'
          '• 随时关闭此开关即可恢复为纯端侧本地离线运行。',
          style: TextStyle(
            fontSize: 13,
            height: 1.5,
            color: colors.textSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('知晓并开启'),
          ),
        ],
      ),
    );
  }

  Future<CloudConnectionTestResult> _handleTestCloudConnection({
    StateSetter? updateDrawerState,
    String? overrideUrl,
    String? overrideKey,
    String? overrideModel,
  }) async {
    final settings = AppSettingsService.instance;
    final future = AIExtractorService.testCloudConnection(
      apiUrl: overrideUrl ?? settings.cloudApiUrl,
      apiKey: overrideKey ?? settings.cloudApiKey,
      modelName: overrideModel ?? settings.cloudModelName,
    );
    if (mounted) setState(() {});
    updateDrawerState?.call(() {});

    final result = await future;
    if (mounted) {
      setState(() {});
      updateDrawerState?.call(() {});
      widget.onStateRefreshed();
      _showSnack(
        result.success ? '🟢 ${result.message}' : '⚠️ ${result.message}',
      );
    }
    return result;
  }

  Future<CloudModelListFetchResult> _handleFetchCloudModels({
    StateSetter? updateDrawerState,
    String? overrideUrl,
    String? overrideKey,
    bool showToast = true,
  }) async {
    final settings = AppSettingsService.instance;
    _isFetchingCloudModels = true;
    if (mounted) setState(() {});
    updateDrawerState?.call(() {});

    final res = await AIExtractorService.fetchCloudModels(
      apiUrl: overrideUrl ?? settings.cloudApiUrl,
      apiKey: overrideKey ?? settings.cloudApiKey,
    );

    _isFetchingCloudModels = false;
    if (res.success) {
      AppSettingsService.instance.setFetchedCloudModels(res.models);
    }

    if (mounted) {
      setState(() {});
      updateDrawerState?.call(() {});
      widget.onStateRefreshed();
      if (showToast) {
        _showSnack(res.success ? '🟢 ${res.message}' : '⚠️ ${res.message}');
      }
    }
    return res;
  }

  void _openCloudServiceManagerDrawer(Color primaryColor) {
    final settings = AppSettingsService.instance;
    _cloudUrlController.text = settings.cloudApiUrl;
    _cloudKeyController.text = settings.cloudApiKey;
    _cloudDrawerFeedback = null;
    _cloudDrawerFeedbackSuccess = false;
    _cloudServiceStep = 0;
    _isFavoriteDropdownExpanded = false;

    _openCustomOptionDrawer(
      drawerId: 'cloudServiceManager',
      title: '云端服务管家',
      subtitle: '配置 OpenAI-Compatible 格式 API 地址与密钥',
      icon: Icons.dns_outlined,
      anchorKey: _paramCloudManagerKey,
      formBuilder: (ctx, setDrawerState, onClose) {
        return _buildCloudServiceManagerForm(
          primaryColor: primaryColor,
          updateState: setDrawerState,
          onClose: onClose,
        );
      },
    );
  }

  /// 构建云端服务管家抽屉表单（两步式：第一步填服务商与 Key，第二步从 Dropdown 多选收藏模型）
  Widget _buildCloudServiceManagerForm({
    required Color primaryColor,
    required StateSetter updateState,
    required VoidCallback onClose,
  }) {
    if (_cloudServiceStep == 1) {
      return _buildCloudServiceFavoriteStepForm(
        primaryColor: primaryColor,
        updateState: updateState,
        onClose: onClose,
      );
    }

    final colors = context.appColors;
    final settings = AppSettingsService.instance;
    final connState = AIExtractorService.cloudConnectionState;
    final isConnected = connState == CloudConnectionState.connected;
    final isTesting =
        connState == CloudConnectionState.testing || _isFetchingCloudModels;
    final isConfigured = settings.isCloudConfigured;
    final effectiveModel = AIExtractorService.getEffectiveCloudModel(
      _cloudUrlController.text,
      settings.cloudModelName,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. 运行环境状态卡（与 ModelCenterView 顶部状态卡样式一致）
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isConnected ? colors.tagWorkContainer : colors.surfaceLow,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isConnected
                  ? colors.tagWork.withValues(alpha: 0.3)
                  : colors.borderSubtle,
              width: 0.8,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    isConnected ? Icons.check_circle : Icons.info_outline,
                    size: 18,
                    color: isConnected ? colors.tagWork : primaryColor,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      isConnected
                          ? '云端引擎已连通 · 网络通畅'
                          : (isConfigured
                              ? '已保存云端接口配置，保存后将拉取可用模型'
                              : '暂未配置云端 API，请在下方填写服务商地址与密钥'),
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                  if (isConfigured)
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      onPressed: isTesting
                          ? null
                          : () {
                              _cloudUrlController.clear();
                              _cloudKeyController.clear();
                              updateState(() {
                                _cloudDrawerFeedback = null;
                              });
                            },
                      icon: Icon(Icons.cleaning_services_outlined,
                          size: 14, color: primaryColor),
                      label: Text(
                        '清空',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: primaryColor,
                        ),
                      ),
                    ),
                ],
              ),
              if (isConfigured) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    Chip(
                      label: Text(
                        '当前: $effectiveModel',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.bold,
                          color: primaryColor,
                        ),
                      ),
                      backgroundColor: primaryColor.withValues(alpha: 0.12),
                      side: BorderSide(color: primaryColor, width: 0.8),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),

        // 2. 常用兼容服务商预设（样式对齐端侧模型库标题与卡片）
        Row(
          children: [
            Icon(Icons.cloud_queue_rounded, size: 16, color: primaryColor),
            const SizedBox(width: 6),
            Text(
              '常用 OpenAI-Compatible 服务商',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
                color: colors.textPrimary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _cloudProviderPresets.map((preset) {
            final url = preset['url']!;
            final isSelected = _cloudUrlController.text.trim() == url;
            return InkWell(
              onTap: () {
                updateState(() {
                  _cloudUrlController.text = url;
                  _cloudDrawerFeedback = null;
                });
              },
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: isSelected
                      ? primaryColor.withValues(alpha: 0.10)
                      : colors.surfaceLow,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isSelected
                        ? primaryColor.withValues(alpha: 0.7)
                        : colors.borderSubtle,
                    width: isSelected ? 1.3 : 0.8,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      preset['name']!,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: isSelected ? primaryColor : colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      preset['tag']!,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 14),

        // 3. API 凭据填写卡片（与 ModelCenterView 卡片容器风格一致）
        Row(
          children: [
            Icon(Icons.vpn_key_outlined, size: 16, color: primaryColor),
            const SizedBox(width: 6),
            Text(
              'OpenAI-Compatible 接口凭据',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
                color: colors.textPrimary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colors.surfaceLow,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: colors.borderSubtle, width: 0.8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const Key('cloud_api_url_field'),
                controller: _cloudUrlController,
                keyboardType: TextInputType.url,
                style: TextStyle(fontSize: 13, color: colors.textPrimary),
                decoration: InputDecoration(
                  isDense: true,
                  labelText: 'API 地址 (OpenAI-Compatible)',
                  hintText: 'https://api.deepseek.com/v1',
                  helperText: '支持基础路径（自动补全 /models 与 /chat/completions）',
                  helperMaxLines: 2,
                  filled: true,
                  fillColor: colors.surfaceCard,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: colors.borderSubtle),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: colors.borderSubtle),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('cloud_api_key_field'),
                controller: _cloudKeyController,
                obscureText: _obscureCloudKey,
                style: TextStyle(fontSize: 13, color: colors.textPrimary),
                decoration: InputDecoration(
                  isDense: true,
                  labelText: 'API Key',
                  hintText: 'sk-...',
                  filled: true,
                  fillColor: colors.surfaceCard,
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureCloudKey
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      size: 18,
                      color: colors.textSecondary,
                    ),
                    tooltip: _obscureCloudKey ? '显示密钥' : '隐藏密钥',
                    onPressed: () {
                      updateState(() {
                        _obscureCloudKey = !_obscureCloudKey;
                      });
                    },
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: colors.borderSubtle),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: colors.borderSubtle),
                  ),
                ),
              ),
            ],
          ),
        ),

        if (_cloudDrawerFeedback != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: _cloudDrawerFeedbackSuccess
                  ? colors.tagWorkContainer
                  : colors.errorContainer,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: _cloudDrawerFeedbackSuccess
                    ? colors.tagWork.withValues(alpha: 0.4)
                    : context.colorScheme.error.withValues(alpha: 0.4),
              ),
            ),
            child: Text(
              _cloudDrawerFeedback!,
              style: TextStyle(
                fontSize: 12,
                color: _cloudDrawerFeedbackSuccess
                    ? colors.tagWork
                    : context.colorScheme.error,
              ),
            ),
          ),
        ],
        const SizedBox(height: 20),

        // 4. 抽屉底部操作按键：“取消”与“保存并测试”（成功后自动拉取模型列表并进入下一页）
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: isTesting ? null : onClose,
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
                onPressed: isTesting
                    ? null
                    : () async {
                        final apiUrl = _cloudUrlController.text.trim();
                        final apiKey = _cloudKeyController.text.trim();

                        if (apiUrl.isEmpty || apiKey.isEmpty) {
                          updateState(() {
                            _cloudDrawerFeedbackSuccess = false;
                            _cloudDrawerFeedback =
                                '请完整填写 OpenAI-Compatible API 地址与 API Key';
                          });
                          _showSnack('请先填写 API 地址与 API Key');
                          return;
                        }

                        AppSettingsService.instance.setCloudServiceConfig(
                          apiUrl: apiUrl,
                          apiKey: apiKey,
                        );

                        updateState(() {
                          _cloudDrawerFeedback = null;
                        });

                        final res = await _handleFetchCloudModels(
                          updateDrawerState: updateState,
                          overrideUrl: apiUrl,
                          overrideKey: apiKey,
                        );

                        if (res.success) {
                          updateState(() {
                            _cloudServiceStep = 1;
                            _isFavoriteDropdownExpanded = false;
                            _cloudDrawerFeedback = null;
                          });
                        } else {
                          updateState(() {
                            _cloudDrawerFeedbackSuccess = false;
                            _cloudDrawerFeedback = res.message;
                          });
                        }
                      },
                icon: isTesting
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: context.colorScheme.onPrimary,
                        ),
                      )
                    : const Icon(Icons.network_check, size: 18),
                label: Text(isTesting ? '拉取模型中...' : '保存并测试'),
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

  /// 云端服务管家第二页：从 Dropdown 下拉多选要收藏的模型
  Widget _buildCloudServiceFavoriteStepForm({
    required Color primaryColor,
    required StateSetter updateState,
    required VoidCallback onClose,
  }) {
    final colors = context.appColors;
    final settings = AppSettingsService.instance;
    final fetchedModels = settings.fetchedCloudModels;
    final favorites = settings.favoriteCloudModels;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 顶部状态提示卡
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colors.tagWorkContainer,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: colors.tagWork.withValues(alpha: 0.35),
              width: 0.8,
            ),
          ),
          child: Row(
            children: [
              Icon(Icons.check_circle, size: 18, color: colors.tagWork),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  fetchedModels.isNotEmpty
                      ? '已拉取到 ${fetchedModels.length} 个模型，请从下方下拉框勾选需要收藏的模型（可多选）'
                      : '接口连接成功，但服务商当前未返回可选模型',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        Row(
          children: [
            Icon(Icons.star_outline_rounded, size: 16, color: primaryColor),
            const SizedBox(width: 6),
            Text(
              '收藏常用模型（可多选）',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
                color: colors.textPrimary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),

        // 可多选 Dropdown 选择框
        InkWell(
          key: const Key('cloud_favorite_models_dropdown'),
          onTap: fetchedModels.isEmpty
              ? null
              : () {
                  updateState(() {
                    _isFavoriteDropdownExpanded = !_isFavoriteDropdownExpanded;
                  });
                },
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              color: colors.surfaceLow,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: _isFavoriteDropdownExpanded
                    ? primaryColor
                    : colors.borderSubtle,
                width: _isFavoriteDropdownExpanded ? 1.2 : 0.8,
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    favorites.isEmpty
                        ? '点击展开下拉列表选择收藏模型'
                        : '已收藏 ${favorites.length} 个模型：${favorites.join("、")}',
                    style: TextStyle(
                      fontSize: 13,
                      color: favorites.isEmpty
                          ? colors.textSecondary
                          : colors.textPrimary,
                      fontWeight: favorites.isEmpty
                          ? FontWeight.normal
                          : FontWeight.w600,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  _isFavoriteDropdownExpanded
                      ? Icons.arrow_drop_up_rounded
                      : Icons.arrow_drop_down_rounded,
                  color: primaryColor,
                  size: 22,
                ),
              ],
            ),
          ),
        ),

        if (_isFavoriteDropdownExpanded && fetchedModels.isNotEmpty) ...[
          const SizedBox(height: 6),
          Container(
            decoration: BoxDecoration(
              color: colors.surfaceCard,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: colors.borderSubtle, width: 0.9),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (int i = 0; i < fetchedModels.length; i++) ...[
                  if (i > 0) _buildDivider(),
                  InkWell(
                    key: Key('dropdown_fav_item_${fetchedModels[i]}'),
                    onTap: () {
                      AppSettingsService.instance
                          .toggleFavoriteCloudModel(fetchedModels[i]);
                      updateState(() {});
                      if (mounted) setState(() {});
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      child: Row(
                        children: [
                          Checkbox(
                            value: favorites.contains(fetchedModels[i]),
                            visualDensity: VisualDensity.compact,
                            onChanged: (_) {
                              AppSettingsService.instance
                                  .toggleFavoriteCloudModel(fetchedModels[i]);
                              updateState(() {});
                              if (mounted) setState(() {});
                            },
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              fetchedModels[i],
                              style: TextStyle(
                                fontSize: 13,
                                color: favorites.contains(fetchedModels[i])
                                    ? primaryColor
                                    : colors.textPrimary,
                                fontWeight:
                                    favorites.contains(fetchedModels[i])
                                        ? FontWeight.w600
                                        : FontWeight.normal,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],

        if (favorites.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: favorites.map((modelId) {
              return InputChip(
                label: Text(
                  modelId,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: primaryColor,
                  ),
                ),
                backgroundColor: primaryColor.withValues(alpha: 0.12),
                side: BorderSide(color: primaryColor.withValues(alpha: 0.5)),
                visualDensity: VisualDensity.compact,
                deleteIcon: Icon(Icons.close, size: 14, color: primaryColor),
                onDeleted: () {
                  AppSettingsService.instance.removeFavoriteCloudModel(modelId);
                  updateState(() {});
                  if (mounted) setState(() {});
                },
              );
            }).toList(),
          ),
        ],

        const SizedBox(height: 20),

        // 底部按键：上一步 与 完成
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () {
                  updateState(() {
                    _cloudServiceStep = 0;
                    _isFavoriteDropdownExpanded = false;
                  });
                },
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: const Text('上一步'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: FilledButton.icon(
                onPressed: () {
                  final curModel = settings.cloudModelName.trim();
                  if ((curModel.isEmpty ||
                          !settings.isFavoriteCloudModelAvailable(curModel)) &&
                      favorites.isNotEmpty) {
                    final firstAvailable = favorites.firstWhere(
                      (m) => settings.isFavoriteCloudModelAvailable(m),
                      orElse: () => '',
                    );
                    if (firstAvailable.isNotEmpty) {
                      AppSettingsService.instance
                          .setCloudModelName(firstAvailable);
                    }
                  }
                  if (mounted) setState(() {});
                  widget.onStateRefreshed();
                  onClose();
                  _showSnack('✅ 已保存云端服务与收藏模型');
                },
                icon: const Icon(Icons.check, size: 18),
                label: const Text('完成'),
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

  void _openCloudModelSelectorDrawer(Color primaryColor) {
    _openCustomOptionDrawer(
      drawerId: 'cloudModelSelector',
      title: '模型选择',
      subtitle: '管理收藏模型或从全部列表中选用',
      icon: Icons.model_training_outlined,
      anchorKey: _paramCloudModelSelectKey,
      formBuilder: (ctx, setDrawerState, onClose) {
        return _buildCloudModelSelectorForm(
          primaryColor: primaryColor,
          updateState: setDrawerState,
          onClose: onClose,
        );
      },
    );
  }

  /// 构建「模型选择」抽屉表单（严格对照草图：拉取模型列表按钮 + 收藏分组 + 全部分组）
  Widget _buildCloudModelSelectorForm({
    required Color primaryColor,
    required StateSetter updateState,
    required VoidCallback onClose,
  }) {
    final colors = context.appColors;
    final settings = AppSettingsService.instance;
    final favorites = settings.favoriteCloudModels;
    final allModels = settings.fetchedCloudModels;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. 顶部通栏按钮：[ 拉取模型列表 ↻ ]
        OutlinedButton(
          key: const Key('fetch_cloud_models_button'),
          onPressed: _isFetchingCloudModels
              ? null
              : () async {
                  if (!settings.isCloudConfigured) {
                    _showSnack('请先在“服务管家”中配置 API 地址与密钥');
                    return;
                  }
                  await _handleFetchCloudModels(updateDrawerState: updateState);
                },
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            backgroundColor: colors.surfaceLow,
            side: BorderSide(color: colors.borderSubtle, width: 1.0),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                _isFetchingCloudModels ? '正在拉取模型列表...' : '拉取模型列表',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(width: 8),
              if (_isFetchingCloudModels)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: primaryColor,
                  ),
                )
              else
                Icon(
                  Icons.refresh_rounded,
                  size: 18,
                  color: primaryColor,
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // 2. 「收藏」分区
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            '收藏',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: colors.textSecondary,
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: colors.surfaceLow,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: colors.borderSubtle, width: 1.0),
          ),
          clipBehavior: Clip.antiAlias,
          child: favorites.isEmpty
              ? Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
                  child: Text(
                    '暂无收藏模型，可从下方“全部”列表中点击 + 加入收藏',
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.textTertiary,
                    ),
                    textAlign: TextAlign.center,
                  ),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (int i = 0; i < favorites.length; i++) ...[
                      if (i > 0) _buildDivider(),
                      _buildFavoriteModelRow(
                        modelId: favorites[i],
                        isAvailable:
                            settings.isFavoriteCloudModelAvailable(favorites[i]),
                        isSelected: settings.isFavoriteCloudModelAvailable(
                                favorites[i]) &&
                            settings.cloudModelName == favorites[i],
                        primaryColor: primaryColor,
                        updateState: updateState,
                      ),
                    ],
                  ],
                ),
        ),
        const SizedBox(height: 18),

        // 3. 「全部」分区
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            '全部',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: colors.textSecondary,
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: colors.surfaceLow,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: colors.borderSubtle, width: 1.0),
          ),
          clipBehavior: Clip.antiAlias,
          child: allModels.isEmpty
              ? Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
                  child: Text(
                    '暂未拉取到模型列表，请点击上方“拉取模型列表”',
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.textTertiary,
                    ),
                    textAlign: TextAlign.center,
                  ),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (int i = 0; i < allModels.length; i++) ...[
                      if (i > 0) _buildDivider(),
                      _buildAllModelRow(
                        modelId: allModels[i],
                        isFavorited: favorites.contains(allModels[i]),
                        isSelected: settings.cloudModelName == allModels[i],
                        primaryColor: primaryColor,
                        updateState: updateState,
                      ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  /// 「收藏」区单行：可用时点击空白处选用（显示 ✓）；失效时整行置灰不可点击，仅右侧垃圾桶按钮可点按
  Widget _buildFavoriteModelRow({
    required String modelId,
    required bool isAvailable,
    required bool isSelected,
    required Color primaryColor,
    required StateSetter updateState,
  }) {
    final colors = context.appColors;
    return AnimatedContainer(
      key: Key('fav_model_row_$modelId'),
      duration: const Duration(milliseconds: 160),
      color: isSelected
          ? primaryColor.withValues(alpha: 0.08)
          : Colors.transparent,
      child: Row(
        children: [
          Expanded(
            child: Opacity(
              opacity: isAvailable ? 1.0 : 0.42,
              child: InkWell(
                key: Key('fav_select_$modelId'),
                onTap: isAvailable
                    ? () {
                        AppSettingsService.instance.setCloudModelName(modelId);
                        updateState(() {});
                        if (mounted) setState(() {});
                        widget.onStateRefreshed();
                        _showSnack('✅ 已选用云端模型：$modelId');
                      }
                    : null,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          modelId,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight:
                                isSelected ? FontWeight.bold : FontWeight.w500,
                            color: !isAvailable
                                ? colors.textTertiary
                                : (isSelected
                                    ? primaryColor
                                    : colors.textPrimary),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isSelected) ...[
                        const SizedBox(width: 8),
                        Icon(
                          Icons.check_rounded,
                          size: 18,
                          color: primaryColor,
                        ),
                      ] else if (!isAvailable) ...[
                        const SizedBox(width: 8),
                        Text(
                          '已下线',
                          style: TextStyle(
                            fontSize: 11,
                            color: colors.textTertiary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            key: Key('fav_delete_$modelId'),
            icon: Icon(
              Icons.delete_outline_rounded,
              size: 18,
              color: colors.textSecondary,
            ),
            tooltip: '移出收藏',
            visualDensity: VisualDensity.compact,
            onPressed: () {
              AppSettingsService.instance.removeFavoriteCloudModel(modelId);
              updateState(() {});
              if (mounted) setState(() {});
              widget.onStateRefreshed();
            },
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  /// 「全部」区单行：点击空白处直接选用；右侧 + 键加入收藏（变成 - 键，再次按下移出收藏）
  Widget _buildAllModelRow({
    required String modelId,
    required bool isFavorited,
    required bool isSelected,
    required Color primaryColor,
    required StateSetter updateState,
  }) {
    final colors = context.appColors;
    return AnimatedContainer(
      key: Key('all_model_row_$modelId'),
      duration: const Duration(milliseconds: 160),
      color: isSelected
          ? primaryColor.withValues(alpha: 0.08)
          : Colors.transparent,
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              key: Key('all_select_$modelId'),
              onTap: () {
                AppSettingsService.instance.setCloudModelName(modelId);
                updateState(() {});
                if (mounted) setState(() {});
                widget.onStateRefreshed();
                _showSnack('✅ 已选用云端模型：$modelId');
              },
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        modelId,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight:
                              isSelected ? FontWeight.bold : FontWeight.w500,
                          color: isSelected ? primaryColor : colors.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isSelected) ...[
                      const SizedBox(width: 8),
                      Icon(
                        Icons.check_rounded,
                        size: 18,
                        color: primaryColor,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            key: Key('all_fav_toggle_$modelId'),
            icon: Icon(
              isFavorited ? Icons.remove_rounded : Icons.add_rounded,
              size: 20,
              color: isFavorited ? colors.tagLife : primaryColor,
            ),
            tooltip: isFavorited ? '从收藏中移除' : '加入收藏',
            visualDensity: VisualDensity.compact,
            onPressed: () {
              AppSettingsService.instance.toggleFavoriteCloudModel(modelId);
              updateState(() {});
              if (mounted) setState(() {});
              widget.onStateRefreshed();
            },
          ),
          const SizedBox(width: 4),
        ],
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
    final statusColor = isLoaded
        ? appColors.tagWork
        : (isLoading ? appColors.tagStudy : appColors.textTertiary);

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
        // 分组头部：标题简洁为“端侧引擎”
        _buildSectionHeader(
          title: '端侧引擎',
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
            // 1. 模型管家（端侧引擎第一行，抽屉/Sheet展示，统一 Badge 与选中高亮）
            _buildCompactParamTile(
              key: _paramModelManagerKey,
              icon: Icons.tune_rounded,
              title: '模型管家',
              subtitle: '管理本地已下载模型权重，或在线下载推荐开源大模型',
              valueBadge: _getModelManagerBadge(),
              isEditing: _activeDrawerId == 'modelManager',
              onTap: () {
                widget.onOpenModelCenter?.call();
                _openCustomOptionDrawer(
                  drawerId: 'modelManager',
                  title: '端侧模型管家',
                  subtitle: '管理本地离线模型与在线极速下载',
                  icon: Icons.tune_rounded,
                  anchorKey: _paramModelManagerKey,
                  formBuilder: (ctx, setDrawerState, onClose) {
                    return ModelCenterView(
                      onRefreshState: () async {
                        widget.onStateRefreshed();
                      },
                      onSelectModel: (model) {
                        widget.onStateRefreshed();
                        setState(() {});
                      },
                      onEngineModeChanged: (mode) {
                        widget.onEngineModeChanged(mode);
                        widget.onStateRefreshed();
                        setState(() {});
                      },
                      onShowSnack: _showSnack,
                      onClose: onClose,
                    );
                  },
                );
              },
            ),
            _buildDivider(),

            // 2. 引擎状态与操作（单行聚合）
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  // 引擎状态指示环（环形呼吸灯直接包裹图标，与各行严格对齐）
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: Center(
                      child: OverflowBox(
                        maxWidth: 24,
                        maxHeight: 24,
                        child: Container(
                          width: 24,
                          height: 24,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: statusColor.withValues(
                              alpha: isLoaded ? 0.14 : (isLoading ? 0.12 : 0.06),
                            ),
                            border: Border.all(
                              color: statusColor,
                              width: 1.6,
                            ),
                            boxShadow: isLoaded
                                ? [
                                    BoxShadow(
                                      color: statusColor.withValues(alpha: 0.45),
                                      blurRadius: 6,
                                      spreadRadius: 1,
                                    ),
                                  ]
                                : (isLoading
                                    ? [
                                        BoxShadow(
                                          color: statusColor.withValues(alpha: 0.35),
                                          blurRadius: 4,
                                          spreadRadius: 0.5,
                                        ),
                                      ]
                                    : null),
                          ),
                          child: Icon(
                            Icons.memory,
                            size: 13,
                            color: statusColor,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
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
                            '当前模型: ${LocalModelManager.currentlyLoadedModelId}'
                            '${(Platform.isWindows && LocalModelManager.activeWindowsBackend != null) ? (LocalModelManager.lastWindowsStartFellBackToCpu ? ' · CPU 兜底' : (LocalModelManager.activeWindowsBackend == 'cpu' ? ' · CPU' : ' · GPU')) : ''}',
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

            // 3. 深度思考开关（单行 Switch 列表项，带统一左侧图标）
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Icon(Icons.psychology_outlined,
                      color: primaryColor, size: 20),
                  const SizedBox(width: 12),
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

            // 4. 常驻策略选择（统一抽屉与圆角矩形 Badge，整行可点击触发，选中展开行变色）
            _buildCompactParamTile(
              key: _paramIdleUnloadKey,
              icon: Icons.timer_outlined,
              title: '空闲内存回收',
              subtitle: '无提取任务后自动解除大模型内存占用',
              valueBadge: _getIdleMinutesText(LocalModelManager.idleUnloadMinutes),
              isEditing: _activeDrawerId == 'idleUnload',
              onTap: () {
                _openCustomOptionDrawer(
                  drawerId: 'idleUnload',
                  title: '空闲内存回收策略',
                  subtitle: '设置模型在无任务时的显存自动回收策略',
                  icon: Icons.timer_outlined,
                  anchorKey: _paramIdleUnloadKey,
                  formBuilder: (ctx, setDrawerState, onClose) {
                    return _buildIdleUnloadForm(
                      primaryColor: primaryColor,
                      updateState: setDrawerState,
                      onClose: onClose,
                    );
                  },
                );
              },
            ),

            // 5. Android 专属：展开悬浮窗时自动预热
            if (Platform.isAndroid) ...[
              _buildDivider(),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    Icon(Icons.flash_on_outlined,
                        color: primaryColor, size: 20),
                    const SizedBox(width: 12),
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
            // 6. 推理路线切换（统一抽屉与圆角矩形 Badge，整行可点击触发，选中展开行变色）
            _buildCompactParamTile(
              key: _paramEngineModeKey,
              icon: Icons.alt_route_rounded,
              title: '推理路线与兜底策略',
              subtitle: _getEngineModeText(widget.engineMode),
              valueBadge: _getEngineModeShortName(widget.engineMode),
              isEditing: _activeDrawerId == 'engineMode',
              onTap: () {
                _openCustomOptionDrawer(
                  drawerId: 'engineMode',
                  title: '推理路线与兜底策略',
                  subtitle: '选择日程提取时的 AI 推理模式与兜底机制',
                  icon: Icons.alt_route_rounded,
                  anchorKey: _paramEngineModeKey,
                  formBuilder: (ctx, setDrawerState, onClose) {
                    return _buildEngineModeForm(
                      primaryColor: primaryColor,
                      updateState: setDrawerState,
                      onClose: onClose,
                    );
                  },
                );
              },
            ),
            if (Platform.isWindows) ...[
              _buildDivider(),
              // 7. 桌面端推理硬件加速策略（Vulkan GPU / CPU）
              _buildCompactParamTile(
                key: _paramDesktopBackendKey,
                icon: Icons.developer_board_outlined,
                title: '推理硬件加速',
                subtitle: _getDesktopBackendSubtitle(
                  LocalModelManager.desktopBackendMode,
                ),
                valueBadge: _getDesktopBackendShortName(
                  LocalModelManager.desktopBackendMode,
                ),
                isEditing: _activeDrawerId == 'desktopBackend',
                onTap: () {
                  _openCustomOptionDrawer(
                    drawerId: 'desktopBackend',
                    title: '桌面端推理硬件加速',
                    subtitle: '配置 Windows 本地 llama-server 的 GPU / CPU 运行策略',
                    icon: Icons.developer_board_outlined,
                    anchorKey: _paramDesktopBackendKey,
                    formBuilder: (ctx, setDrawerState, onClose) {
                      return _buildDesktopBackendForm(
                        primaryColor: primaryColor,
                        updateState: setDrawerState,
                        onClose: onClose,
                      );
                    },
                  );
                },
              ),
            ],
          ],
        ),
      ],
    );
  }

  String _getModelManagerBadge() {
    final loaded = LocalModelManager.currentlyLoadedModelId;
    if (loaded != null && loaded.isNotEmpty) {
      if (loaded.contains('0.5B') || loaded.contains('0.5b')) {
        return 'Qwen-0.5B';
      } else if (loaded.contains('1.5B') || loaded.contains('1.5b')) {
        return 'Qwen-1.5B';
      } else if (loaded.contains('3B') || loaded.contains('3b')) {
        return 'Llama-3B';
      }
      return '已挂载';
    }
    return '模型库';
  }

  Widget _buildCalendarSyncBadge(AppCustomColors appColors) {
    final allEvents = AgendaRepository.instance.allEvents;
    final syncedCount = allEvents.where((e) => e.syncedToSystemCalendar).length;
    final unsyncedCount = allEvents.length - syncedCount;
    final isAllSynced = unsyncedCount <= 0;
    final isEditing = _activeDrawerId == 'calendarSync';

    if (isAllSynced) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: appColors.tagWork.withValues(alpha: isEditing ? 0.22 : 0.12),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: appColors.tagWork.withValues(alpha: 0.5),
            width: 0.8,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check, size: 14, color: appColors.tagWork),
            const SizedBox(width: 3),
            Text(
              '已同步',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: appColors.tagWork,
              ),
            ),
          ],
        ),
      );
    } else {
      final errorColor = context.colorScheme.error;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: errorColor.withValues(alpha: isEditing ? 0.22 : 0.12),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: errorColor.withValues(alpha: 0.5),
            width: 0.8,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$unsyncedCount 未同步',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: errorColor,
              ),
            ),
          ],
        ),
      );
    }
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

  /// 构建空闲内存回收抽屉/Sheet表单
  Widget _buildIdleUnloadForm({
    required Color primaryColor,
    required StateSetter updateState,
    required VoidCallback onClose,
  }) {
    final colors = context.appColors;
    final current = LocalModelManager.idleUnloadMinutes;

    final options = [
      {'title': '1 分钟', 'subtitle': '极速防杀，省电低功耗', 'val': 1},
      {'title': '3 分钟', 'subtitle': '快速回收显存，适合频繁切换应用', 'val': 3},
      {'title': '5 分钟 (默认推荐)', 'subtitle': '平衡日常解析体验与后台能耗', 'val': 5},
      {'title': '10 分钟', 'subtitle': '较长常驻，减少频繁冷启动等待', 'val': 10},
      {'title': '永不回收 (持续常驻)', 'subtitle': '权重持续驻留内存 / 显存', 'val': -1},
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. 说明卡片
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colors.surfaceLow,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: colors.borderSubtle),
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
                  '无提取任务达到指定时长后，自动解除大模型在 RAM / 显存中的常驻占用，防止移动端系统杀后台，在待机功耗与解析响应速度之间取得最佳平衡。',
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

        // 2. 选项列表
        ...options.map((opt) {
          final val = opt['val'] as int;
          final isSelected = val == current;
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: InkWell(
              onTap: () {
                updateState(() {
                  LocalModelManager.idleUnloadMinutes = val;
                  LocalModelManager.markActivity();
                });
                AppSettingsService.instance.setIdleUnloadMinutes(val);
                if (mounted) setState(() {});
                _showSnack(val > 0
                    ? '已设置为无任务 $val 分钟后自动释放内存'
                    : '已设置为永不自动释放');
                onClose();
              },
              borderRadius: BorderRadius.circular(10),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: isSelected
                      ? primaryColor.withValues(alpha: 0.10)
                      : colors.surfaceLow,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isSelected ? primaryColor : colors.borderSubtle,
                    width: isSelected ? 1.5 : 1.0,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      isSelected
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 18,
                      color: isSelected ? primaryColor : colors.textTertiary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            opt['title'] as String,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight:
                                  isSelected ? FontWeight.bold : FontWeight.w600,
                              color: isSelected
                                  ? primaryColor
                                  : colors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            opt['subtitle'] as String,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: colors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
        const SizedBox(height: 16),

        // 3. 完成按钮
        FilledButton(
          onPressed: onClose,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          child: const Text('完成'),
        ),
      ],
    );
  }

  /// 构建推理路线抽屉/Sheet表单
  Widget _buildEngineModeForm({
    required Color primaryColor,
    required StateSetter updateState,
    required VoidCallback onClose,
  }) {
    final colors = context.appColors;

    final options = [
      {
        'mode': AIEngineMode.hybridAuto,
        'title': '混合自动 (推荐)',
        'subtitle': '优先使用端侧大模型提取，模型未就绪或解析异常时自动由 0 延迟极速规则引擎兜底',
        'tag': '智能 + 兜底',
      },
      {
        'mode': AIEngineMode.builtInRuleEngine,
        'title': '纯端侧极速规则',
        'subtitle': '0 延迟、0 显存开销，使用启发式中文时空正则匹配，完全不占显存与电量',
        'tag': '0内存 · 极速',
      },
      {
        'mode': AIEngineMode.localLlmServer,
        'title': '强制端侧大模型',
        'subtitle': '仅使用本地或局域网 LLM 推理，不启用正则引擎兜底',
        'tag': '纯大模型',
      },
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. 说明卡片
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colors.surfaceLow,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: colors.borderSubtle),
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
                  '知程支持端侧大模型与启发式正则双引擎。推荐使用“混合自动”模式，在保证深度语义理解的同时获得高可用秒级保底。',
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

        // 2. 选项列表
        ...options.map((opt) {
          final mode = opt['mode'] as AIEngineMode;
          final isSelected = widget.engineMode == mode;
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: InkWell(
              onTap: () {
                updateState(() {
                  widget.onEngineModeChanged(mode);
                });
                if (mounted) setState(() {});
                onClose();
              },
              borderRadius: BorderRadius.circular(10),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: isSelected
                      ? primaryColor.withValues(alpha: 0.10)
                      : colors.surfaceLow,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isSelected ? primaryColor : colors.borderSubtle,
                    width: isSelected ? 1.5 : 1.0,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      isSelected
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 18,
                      color: isSelected ? primaryColor : colors.textTertiary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                opt['title'] as String,
                                style: TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: isSelected
                                      ? FontWeight.bold
                                      : FontWeight.w600,
                                  color: isSelected
                                      ? primaryColor
                                      : colors.textPrimary,
                                ),
                              ),
                              const Spacer(),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? primaryColor.withValues(alpha: 0.18)
                                      : colors.borderSubtle
                                          .withValues(alpha: 0.5),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  opt['tag'] as String,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.bold,
                                    color: isSelected
                                        ? primaryColor
                                        : colors.textSecondary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text(
                            opt['subtitle'] as String,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: colors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
        const SizedBox(height: 16),

        // 3. 完成按钮
        FilledButton(
          onPressed: onClose,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          child: const Text('完成'),
        ),
      ],
    );
  }

  String _getDesktopBackendShortName(DesktopBackendMode mode) {
    return switch (mode) {
      DesktopBackendMode.autoGpuFallbackCpu => '自动 (GPU优先)',
      DesktopBackendMode.cpuOnly => '纯 CPU',
      DesktopBackendMode.gpuOnly => '仅 GPU',
    };
  }

  String _getDesktopBackendSubtitle(DesktopBackendMode mode) {
    return switch (mode) {
      DesktopBackendMode.autoGpuFallbackCpu =>
        '优先 Vulkan/GPU 加速，启动异常自动降级 CPU',
      DesktopBackendMode.cpuOnly => '强制纯 CPU 推理（-ngl 0），零显存占用、最高兼容',
      DesktopBackendMode.gpuOnly => '强制 GPU 加速且不回退 CPU，适合高性能独显',
    };
  }

  /// 构建 Windows 桌面端推理硬件加速策略抽屉/Sheet 表单
  Widget _buildDesktopBackendForm({
    required Color primaryColor,
    required StateSetter updateState,
    required VoidCallback onClose,
  }) {
    final colors = context.appColors;
    final current = LocalModelManager.desktopBackendMode;

    final options = [
      {
        'mode': DesktopBackendMode.autoGpuFallbackCpu,
        'title': '自动模式 (GPU 优先 · CPU 兜底)',
        'subtitle':
            '默认启用 Vulkan / GPU 自适应显存卸载；若驱动异常、显存不足或启动崩溃，自动降级为纯 CPU 推理',
        'tag': '推荐',
      },
      {
        'mode': DesktopBackendMode.cpuOnly,
        'title': '纯 CPU 模式 (省显存 · 高兼容)',
        'subtitle':
            '强制关闭显卡卸载（-ngl 0 --device none），完全使用系统内存与 CPU 指令集，适合核显或低显存设备',
        'tag': '零显存',
      },
      {
        'mode': DesktopBackendMode.gpuOnly,
        'title': '仅 GPU 模式 (高性能 · 不降级)',
        'subtitle':
            '强制使用 GPU 自适应卸载，启动失败时不自动切换至 CPU，便于排查独显加速或保证最高吞吐',
        'tag': '独显直连',
      },
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colors.surfaceLow,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: colors.borderSubtle),
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
                  '内置 llama-server 支持 Vulkan GPU 与 CPU 多指令集动态后端加载。切换与当前运行状态不兼容的策略时，将自动卸载旧服务并在下次推理或预热时生效。',
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
        ...options.map((opt) {
          final mode = opt['mode'] as DesktopBackendMode;
          final isSelected = current == mode;
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: InkWell(
              onTap: () async {
                updateState(() {
                  LocalModelManager.desktopBackendMode = mode;
                });
                await AppSettingsService.instance.setDesktopBackendMode(mode);
                if (LocalModelManager.loadedWindowsModelPath != null &&
                    !LocalModelManager.isWindowsBackendCompatible(
                      preference: mode,
                      activeBackend: LocalModelManager.activeWindowsBackend,
                    )) {
                  await LocalModelManager.unloadModel(
                    reason: '切换推理硬件后端',
                  );
                  widget.onStateRefreshed();
                }
                if (!mounted) return;
                setState(() {});
                _showSnack('已切换为「${opt['title']}」');
                onClose();
              },
              borderRadius: BorderRadius.circular(10),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: isSelected
                      ? primaryColor.withValues(alpha: 0.10)
                      : colors.surfaceLow,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isSelected ? primaryColor : colors.borderSubtle,
                    width: isSelected ? 1.5 : 1.0,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      isSelected
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 18,
                      color: isSelected ? primaryColor : colors.textTertiary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  opt['title'] as String,
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: isSelected
                                        ? FontWeight.bold
                                        : FontWeight.w600,
                                    color: isSelected
                                        ? primaryColor
                                        : colors.textPrimary,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? primaryColor.withValues(alpha: 0.18)
                                      : colors.borderSubtle
                                          .withValues(alpha: 0.5),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  opt['tag'] as String,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.bold,
                                    color: isSelected
                                        ? primaryColor
                                        : colors.textSecondary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text(
                            opt['subtitle'] as String,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: colors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: onClose,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          child: const Text('完成'),
        ),
      ],
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
              icon: Icons.view_agenda_outlined,
              title: '上下文窗口 (Context Size)',
              subtitle: '最大 Token 容量 · 默认 2048',
              valueBadge: '${LocalModelManager.contextSize}',
              isEditing: _activeDrawerId == '上下文窗口大小 (Context Size)',
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
              icon: Icons.hourglass_bottom_outlined,
              title: '思考 Token 上限 (Max Tokens)',
              subtitle: '深度思考最大预算 · 默认 1536',
              valueBadge: '${LocalModelManager.maxThinkingTokens}',
              isEditing: _activeDrawerId == '思考与生成 Token 上限 (Max Tokens)',
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
              icon: Icons.device_thermostat_outlined,
              title: '采样温度 (Temperature)',
              subtitle: '输出随机度，越低越严谨 · 默认 0.30',
              valueBadge: LocalModelManager.temperature.toStringAsFixed(2),
              isEditing: _activeDrawerId == '采样温度 (Temperature)',
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
              icon: Icons.filter_alt_outlined,
              title: '核采样阈值 (Top-P)',
              subtitle: '候选词概率截断门限 · 默认 0.90',
              valueBadge: LocalModelManager.topP.toStringAsFixed(2),
              isEditing: _activeDrawerId == '核采样阈值 (Top-P)',
              onTap: () => _handleParamEdit(
                _ModelParamConfig(
                  title: '核采样阈值 (Top-P)',
                  description:
                      '仅从累积概率达到此阈值的最高概率候选词中采样。0.90 兼顾了高确定性与常用词丰富度。',
                  unit: '',
                  currentValue: LocalModelManager.topP,
                  min: AppSettingsService.minTopP,
                  max: AppSettingsService.maxTopP,
                  divisions: 18, // 0.05 step
                  isInteger: false,
                  presets: const [0.50, 0.70, 0.85, 0.90, 0.95, 1.00],
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
              icon: Icons.replay_rounded,
              title: '重复词惩罚 (Repeat Penalty)',
              subtitle: '抑制自言自语死循环 · 默认 1.10',
              valueBadge: LocalModelManager.repeatPenalty.toStringAsFixed(2),
              isEditing: _activeDrawerId == '重复词惩罚 (Repeat Penalty)',
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
              _closeDrawer();
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
            // 全局悬浮窗开关（统一带左侧图标）
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Icon(Icons.bubble_chart_outlined,
                      color: primaryColor, size: 20),
                  const SizedBox(width: 12),
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

            // 无障碍识屏服务（统一带左侧图标）
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Icon(Icons.accessibility_new_rounded,
                      color: primaryColor, size: 20),
                  const SizedBox(width: 12),
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
                  Icon(Icons.auto_delete_outlined,
                      color: primaryColor, size: 20),
                  const SizedBox(width: 12),
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
            // 2. 打开同步中心（抽屉/Sheet展示，保留抽屉机制，带同步状态 Badge）
            _buildCompactParamTile(
              key: _paramCalendarSyncKey,
              icon: Icons.sync,
              title: '打开同步中心',
              subtitle: '从底层系统日历导入日程并将本地新增日程推送入历',
              badgeWidget: _buildCalendarSyncBadge(appColors),
              isEditing: _activeDrawerId == 'calendarSync',
              onTap: () {
                _openCustomOptionDrawer(
                  drawerId: 'calendarSync',
                  title: '日历同步中心',
                  subtitle: '系统日历双向推拉对齐与底层事件同步',
                  icon: Icons.sync,
                  anchorKey: _paramCalendarSyncKey,
                  formBuilder: (ctx, setDrawerState, onClose) {
                    return CalendarSyncPanel(
                      showHeader: false,
                      isDrawerMode: true,
                      onClose: onClose,
                      onSyncCompleted: () {
                        setDrawerState(() {});
                        setState(() {});
                        widget.onStateRefreshed();
                      },
                    );
                  },
                );
              },
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
                  Icon(Icons.lan_outlined, color: primaryColor, size: 20),
                  const SizedBox(width: 12),
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
              Flexible(
                child: Text(
                  '最小: ${config.isInteger ? config.min.round() : config.min.toStringAsFixed(2)} ${config.unit}',
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.textTertiary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  '最大: ${config.isInteger ? config.max.round() : config.max.toStringAsFixed(2)} ${config.unit}',
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.textTertiary,
                  ),
                  textAlign: TextAlign.end,
                  overflow: TextOverflow.ellipsis,
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
    Color primaryColor,
  ) {
    return StatefulBuilder(
      builder: (context, setDrawerState) {
        final colors = context.appColors;

        String drawerTitle = '';
        String drawerSubtitle = '';
        IconData drawerIcon = Icons.tune;
        Widget formContent = const SizedBox.shrink();

        if (_activeParamConfig != null) {
          drawerTitle = _activeParamConfig!.title;
          drawerSubtitle = '调节推理参数并保存生效';
          drawerIcon = Icons.tune;
          formContent = _buildParamEditorForm(
            config: _activeParamConfig!,
            primaryColor: primaryColor,
            updateState: setDrawerState,
            onClose: _closeDrawer,
          );
        } else if (_activeDrawerId == 'cloudServiceManager') {
          drawerTitle = '云端服务管家';
          drawerSubtitle = '配置 OpenAI-Compatible 格式 API 地址与密钥';
          drawerIcon = Icons.dns_outlined;
          formContent = _buildCloudServiceManagerForm(
            primaryColor: primaryColor,
            updateState: setDrawerState,
            onClose: _closeDrawer,
          );
        } else if (_activeDrawerId == 'cloudModelSelector') {
          drawerTitle = '模型选择';
          drawerSubtitle = '管理收藏模型或从全部列表中选用';
          drawerIcon = Icons.model_training_outlined;
          formContent = _buildCloudModelSelectorForm(
            primaryColor: primaryColor,
            updateState: setDrawerState,
            onClose: _closeDrawer,
          );
        } else if (_activeDrawerId == 'modelManager') {
          drawerTitle = '端侧模型管家';
          drawerSubtitle = '管理本地离线模型与在线极速下载';
          drawerIcon = Icons.tune_rounded;
          formContent = ModelCenterView(
            onRefreshState: () async {
              widget.onStateRefreshed();
            },
            onSelectModel: (model) {
              widget.onStateRefreshed();
              setState(() {});
            },
            onEngineModeChanged: (mode) {
              widget.onEngineModeChanged(mode);
              widget.onStateRefreshed();
              setState(() {});
            },
            onShowSnack: _showSnack,
            onClose: _closeDrawer,
          );
        } else if (_activeDrawerId == 'idleUnload') {
          drawerTitle = '空闲内存回收策略';
          drawerSubtitle = '设置模型在无任务时的显存自动回收策略';
          drawerIcon = Icons.timer_outlined;
          formContent = _buildIdleUnloadForm(
            primaryColor: primaryColor,
            updateState: setDrawerState,
            onClose: _closeDrawer,
          );
        } else if (_activeDrawerId == 'engineMode') {
          drawerTitle = '推理路线与兜底策略';
          drawerSubtitle = '选择日程提取时的 AI 推理模式与兜底机制';
          drawerIcon = Icons.alt_route_rounded;
          formContent = _buildEngineModeForm(
            primaryColor: primaryColor,
            updateState: setDrawerState,
            onClose: _closeDrawer,
          );
        } else if (_activeDrawerId == 'desktopBackend') {
          drawerTitle = '桌面端推理硬件加速';
          drawerSubtitle = '配置 Windows 本地 llama-server 的 GPU / CPU 运行策略';
          drawerIcon = Icons.developer_board_outlined;
          formContent = _buildDesktopBackendForm(
            primaryColor: primaryColor,
            updateState: setDrawerState,
            onClose: _closeDrawer,
          );
        } else if (_activeDrawerId == 'calendarSync') {
          drawerTitle = '日历同步中心';
          drawerSubtitle = '系统日历双向推拉对齐与底层事件同步';
          drawerIcon = Icons.sync;
          formContent = CalendarSyncPanel(
            showHeader: false,
            isDrawerMode: true,
            onClose: _closeDrawer,
            onSyncCompleted: () {
              setDrawerState(() {});
              setState(() {});
              widget.onStateRefreshed();
            },
          );
        }

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
                      child: Icon(drawerIcon, color: primaryColor, size: 18),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            drawerTitle,
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
                            drawerSubtitle,
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
                      onPressed: _closeDrawer,
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
                  child: formContent,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 构建移动端底部滑出参数修改 Bottom Sheet 内容
  Widget _buildMobileParamBottomSheet(
    BuildContext ctx,
    _ModelParamConfig config,
    Color primaryColor,
  ) {
    return StatefulBuilder(
      builder: (context, setSheetState) {
        final colors = context.appColors;
        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.85,
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

  /// 构建移动端底部滑出通用选项（空闲回收、推理路线）Bottom Sheet 内容
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
    return StatefulBuilder(
      builder: (context, setSheetState) {
        final colors = context.appColors;
        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.85,
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
                    Icon(icon, color: primaryColor, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: colors.textPrimary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 1),
                          Text(
                            subtitle,
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
                  child: formBuilder(ctx, setSheetState, () => Navigator.of(ctx).pop()),
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
        KeyedSubtree(key: _cloudKey, child: _buildCloudEngineSection()),
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
        _isWide = constraints.maxWidth >= 880;
        final isWide = _isWide;

        if (isWide) {
          final isDrawerOpen = _activeDrawerId != null;

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
                    ? OverflowBox(
                        minWidth: 380,
                        maxWidth: 380,
                        alignment: Alignment.topRight,
                        child: _buildDesktopDrawerContent(primaryColor),
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
