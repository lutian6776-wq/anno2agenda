import 'dart:io';
import 'package:flutter/material.dart';
import '../repositories/agenda_repository.dart';
import '../services/ai_extractor_service.dart';
import '../services/floating_overlay_service.dart';
import '../services/lan_sync_service.dart';
import '../services/local_model_manager.dart';
import '../services/platform_bridge.dart';
import '../services/theme_manager.dart';

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

class _SettingsPageState extends State<SettingsPage> {
  bool _floatingRunning = false;
  bool _accessibilityEnabled = false;

  /// 记录当前展开了说明的设置项 key
  final Set<String> _expandedInfoKeys = <String>{};

  @override
  void initState() {
    super.initState();
    _checkNativeState();
    FloatingOverlayService.instance.isRunningNotifier.addListener(_onFloatingRunningChanged);
  }

  @override
  void dispose() {
    FloatingOverlayService.instance.isRunningNotifier.removeListener(_onFloatingRunningChanged);
    super.dispose();
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
    bool isDark = false,
  }) {
    final isExpanded = _expandedInfoKeys.contains(infoKey);
    final activeColor =
        isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB);
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
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isExpanded
                    ? activeColor.withValues(alpha: isDark ? 0.22 : 0.12)
                    : (isDark
                        ? const Color(0xFF1E293B)
                        : const Color(0xFFF8FAFC)),
                borderRadius: BorderRadius.circular(5),
                border: Border.all(
                  color: isExpanded
                      ? activeColor
                      : (isDark
                          ? const Color(0xFF475569)
                          : const Color(0xFF94A3B8)),
                  width: 1.2,
                ),
              ),
              child: Icon(
                Icons.info_outline,
                size: 13,
                color: isExpanded
                    ? activeColor
                    : (isDark
                        ? const Color(0xFF94A3B8)
                        : const Color(0xFF64748B)),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 统一构建展开后的说明文字卡片
  Widget _buildExpandedInfoBox(String text, {bool isDark = false}) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      child: Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 4),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1),
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
                  color:
                      isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(
                    fontSize: 12.5,
                    color:
                        isDark ? const Color(0xFFE2E8F0) : const Color(0xFF334155),
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 构建带有“加框 i”按钮的下拉菜单选项行
  Widget _buildDropdownSettingRow<T>({
    required IconData icon,
    required String title,
    required String infoKey,
    required String infoText,
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
    bool isDark = false,
  }) {
    final isExpanded = _expandedInfoKeys.contains(infoKey);
    final primaryColor =
        isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: primaryColor, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                          color: isDark ? Colors.white : const Color(0xFF0F172A),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    _buildInfoBoxButton(
                      infoKey: infoKey,
                      tooltip: '查看「$title」说明',
                      isDark: isDark,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              DropdownButtonHideUnderline(
                child: DropdownButton<T>(
                  value: value,
                  isDense: true,
                  dropdownColor:
                      isDark ? const Color(0xFF1E293B) : Colors.white,
                  items: items,
                  onChanged: onChanged,
                ),
              ),
            ],
          ),
          if (isExpanded) _buildExpandedInfoBox(infoText, isDark: isDark),
        ],
      ),
    );
  }

  /// 构建带有“加框 i”按钮的开关选项行
  Widget _buildSwitchSettingRow({
    required IconData icon,
    required String title,
    required String infoKey,
    required String infoText,
    required bool value,
    required ValueChanged<bool> onChanged,
    bool isDark = false,
  }) {
    final isExpanded = _expandedInfoKeys.contains(infoKey);
    final primaryColor =
        isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: primaryColor, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: InkWell(
                        onTap: () => onChanged(!value),
                        borderRadius: BorderRadius.circular(4),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Text(
                            title,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                              color:
                                  isDark ? Colors.white : const Color(0xFF0F172A),
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    _buildInfoBoxButton(
                      infoKey: infoKey,
                      tooltip: '查看「$title」说明',
                      isDark: isDark,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Switch(
                value: value,
                onChanged: onChanged,
              ),
            ],
          ),
          if (isExpanded) _buildExpandedInfoBox(infoText, isDark: isDark),
        ],
      ),
    );
  }

  /// 主题外观模块：支持浅色、深色、跟随系统选择卡
  Widget _buildThemeModeCard(bool isDark) {
    final currentMode = ThemeManager.instance.themeMode;
    final systemBrightness = MediaQuery.platformBrightnessOf(context);
    final isSystemDark = systemBrightness == Brightness.dark;
    final primaryColor =
        isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isDark ? const Color(0xFF334155) : Colors.grey.shade200,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.palette_outlined, color: primaryColor),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '外观与深浅色模式',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                ),
                _buildInfoBoxButton(
                  infoKey: 'themeCardOverview',
                  tooltip: '查看深浅色外观说明',
                  isDark: isDark,
                ),
              ],
            ),
            if (_expandedInfoKeys.contains('themeCardOverview'))
              _buildExpandedInfoBox(
                '• 浅色模式：清晰通透高对比度日间风格，适合白昼与明亮光照环境。\n'
                '• 深色模式：护眼沉浸暗黑风格，适合夜间或低光照环境，降低屏幕功耗与视觉疲劳。\n'
                '• 跟随系统：自动读取 Android 或 Windows 设备当前系统的深浅色设置并实时同步切换。',
                isDark: isDark,
              ),
            const SizedBox(height: 12),

            // 系统状态提示
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xFF0F172A)
                    : const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isDark
                      ? const Color(0xFF334155)
                      : const Color(0xFFE2E8F0),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    isSystemDark
                        ? Icons.dark_mode_outlined
                        : Icons.light_mode_outlined,
                    size: 15,
                    color: isDark
                        ? const Color(0xFF94A3B8)
                        : const Color(0xFF64748B),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '设备当前系统设置：${isSystemDark ? "深色模式 (Dark)" : "浅色模式 (Light)"}'
                      '${currentMode == ThemeMode.system ? " · 应用正自动生效中" : ""}',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark
                            ? const Color(0xFF94A3B8)
                            : const Color(0xFF64748B),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // 3 张选择卡：浅色、深色、跟随系统
            Row(
              children: [
                Expanded(
                  child: _buildThemeOptionCard(
                    title: '浅色',
                    subtitle: '日间模式',
                    icon: Icons.light_mode_rounded,
                    mode: ThemeMode.light,
                    currentMode: currentMode,
                    iconColor: const Color(0xFFF59E0B),
                    isDark: isDark,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildThemeOptionCard(
                    title: '深色',
                    subtitle: '夜间模式',
                    icon: Icons.dark_mode_rounded,
                    mode: ThemeMode.dark,
                    currentMode: currentMode,
                    iconColor: const Color(0xFF818CF8),
                    isDark: isDark,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildThemeOptionCard(
                    title: '跟随系统',
                    subtitle: isSystemDark ? '检测:深色' : '检测:浅色',
                    icon: Icons.brightness_auto_rounded,
                    mode: ThemeMode.system,
                    currentMode: currentMode,
                    iconColor: const Color(0xFF10B981),
                    isDark: isDark,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 构建单个外观选择卡
  Widget _buildThemeOptionCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required ThemeMode mode,
    required ThemeMode currentMode,
    required Color iconColor,
    required bool isDark,
  }) {
    final isSelected = mode == currentMode;
    final primaryColor =
        isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB);

    return InkWell(
      onTap: () async {
        await ThemeManager.instance.setThemeMode(mode);
        setState(() {});
        _showSnack(
          mode == ThemeMode.system
              ? '已设置为跟随系统深浅色切换'
              : mode == ThemeMode.dark
                  ? '已切换为深色夜间模式'
                  : '已切换为浅色日间模式',
        );
      },
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 11),
        decoration: BoxDecoration(
          color: isSelected
              ? primaryColor.withValues(alpha: isDark ? 0.22 : 0.08)
              : (isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC)),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected
                ? primaryColor
                : (isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Icon(icon, color: iconColor, size: 21),
                Icon(
                  isSelected
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked,
                  size: 16,
                  color: isSelected
                      ? primaryColor
                      : (isDark
                          ? const Color(0xFF64748B)
                          : const Color(0xFF94A3B8)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                  color: isSelected
                      ? primaryColor
                      : (isDark ? Colors.white : const Color(0xFF0F172A)),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(height: 2),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                subtitle,
                style: TextStyle(
                  fontSize: 10.5,
                  color: isDark
                      ? const Color(0xFF94A3B8)
                      : const Color(0xFF64748B),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 设置模块 1：端侧 AI 模型预热、内存释放与思考模式设置
  Widget _buildModelEngineSettingsCard(bool isDark) {
    final primaryColor =
        isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isDark ? const Color(0xFF334155) : Colors.grey.shade200,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.memory, color: primaryColor),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '端侧大模型预热与内存常驻设置',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                ),
                _buildInfoBoxButton(
                  infoKey: 'modelCardOverview',
                  tooltip: '查看端侧大模型设置总览说明',
                  isDark: isDark,
                ),
                const SizedBox(width: 4),
                TextButton.icon(
                  onPressed: widget.onOpenModelCenter,
                  icon: const Icon(Icons.download_rounded, size: 16),
                  label: const Text('模型管家'),
                ),
              ],
            ),
            if (_expandedInfoKeys.contains('modelCardOverview'))
              _buildExpandedInfoBox(
                '知程基于端侧 llama.cpp 与轻量级开源大模型，所有推理 100% 在本地设备执行，无网络依赖、无数据泄露风险。在此可配置模型显存常驻、空闲自动释放与深度思考策略。',
                isDark: isDark,
              ),
            const SizedBox(height: 10),

            // 1. 模型预热与常驻控制栏
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color:
                    isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isDark
                      ? const Color(0xFF334155)
                      : const Color(0xFFE2E8F0),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.info_outline, size: 16, color: primaryColor),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          widget.engineIndicatorDetail,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(width: 6),
                      _buildInfoBoxButton(
                        infoKey: 'modelPreloadControl',
                        tooltip: '查看预热与释放内存说明',
                        isDark: isDark,
                      ),
                    ],
                  ),
                  if (_expandedInfoKeys.contains('modelPreloadControl'))
                    _buildExpandedInfoBox(
                      '• 立即预热/加载：主动将模型权重加载到系统 RAM/显存中，避免用户首次提取时产生数秒的冷启动耗时。\n'
                      '• 释放内存 (卸载)：主动卸载大模型并释放 RAM/显存，提取完成或系统内存紧缺时可手动释放。',
                      isDark: isDark,
                    ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: widget.onPreloadModel,
                        icon: const Icon(Icons.bolt, size: 16),
                        label: const Text('🔥 立即预热/加载模型'),
                      ),
                      OutlinedButton.icon(
                        onPressed: widget.onUnloadModel,
                        icon: const Icon(Icons.delete_outline, size: 16),
                        label: const Text('释放内存 (卸载)'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),

            // 2. 内存自动释放时长设置
            _buildDropdownSettingRow<int>(
              icon: Icons.timer_outlined,
              title: '空闲内存自动释放',
              infoKey: 'idleUnload',
              infoText:
                  '无提取任务达到指定时长后，自动解除大模型在 RAM/显存中的常驻，防止系统杀后台，平衡待机功耗与解析速度。',
              value: LocalModelManager.idleUnloadMinutes,
              isDark: isDark,
              items: const [
                DropdownMenuItem(value: 1, child: Text('1分钟 (极速防杀)')),
                DropdownMenuItem(value: 3, child: Text('3分钟')),
                DropdownMenuItem(value: 5, child: Text('5分钟 (默认推荐)')),
                DropdownMenuItem(value: 10, child: Text('10分钟')),
                DropdownMenuItem(value: -1, child: Text('永不释放 (持续常驻)')),
              ],
              onChanged: (val) {
                if (val != null) {
                  setState(() {
                    LocalModelManager.idleUnloadMinutes = val;
                    LocalModelManager.markActivity();
                  });
                  _showSnack(
                      val > 0 ? '已设置为无任务 $val 分钟后自动释放内存' : '已设置为永不自动释放');
                }
              },
            ),
            const Divider(height: 12),

            // 3. 深度思考模式设置
            _buildSwitchSettingRow(
              icon: Icons.psychology_outlined,
              title: '开启深度思考模式 (Think Mode)',
              infoKey: 'thinkMode',
              infoText: LocalModelManager.enableThinkMode
                  ? '【当前已开启】大模型输出日程前将完整生成思维链推理过程，语义理解更周密，适合多时间点、多任务的复杂通知（耗时约增加 2~4 秒）。'
                  : '【当前已关闭】免思考极速模式，1 秒直出 JSON 结构化日程，响应更快更省电（默认推荐）。',
              value: LocalModelManager.enableThinkMode,
              isDark: isDark,
              onChanged: (val) {
                setState(() => LocalModelManager.enableThinkMode = val);
                _showSnack(
                    val ? '已开启深度思考模式' : '已关闭深度思考模式 (恢复 1 秒秒级直出)');
              },
            ),

            // 4. 悬浮窗展开时自动预热
            if (Platform.isAndroid) ...[
              const Divider(height: 12),
              _buildSwitchSettingRow(
                icon: Icons.flash_on_outlined,
                title: '展开悬浮窗时自动预热大模型',
                infoKey: 'autoPreload',
                infoText:
                    '当点击贴边悬浮胶囊展开操作卡时，后台立即异步预载模型权重，用户输入文本或识屏后无需等待模型冷启动，实现无缝秒级解析。',
                value: LocalModelManager.autoPreloadOnOverlayExpand,
                isDark: isDark,
                onChanged: (val) {
                  setState(
                      () => LocalModelManager.autoPreloadOnOverlayExpand = val);
                },
              ),
            ],
            const Divider(height: 12),

            // 5. 推理路线切换
            _buildDropdownSettingRow<AIEngineMode>(
              icon: Icons.alt_route,
              title: '推理路线与兜底策略',
              infoKey: 'engineMode',
              infoText: '当前路线说明：\n'
                  '${widget.engineMode == AIEngineMode.hybridAuto ? "• 混合自动 (推荐)：优先使用端侧大模型提取，模型未就绪或解析异常时自动由 0 延迟极速规则引擎兜底。" : widget.engineMode == AIEngineMode.builtInRuleEngine ? "• 纯端侧极速规则：0 延迟、0 显存开销，使用启发式中文时空正则，完全不占显存与电量。" : "• 强制端侧大模型：仅使用本地或局域网 LLM 推理，不启用正则引擎兜底。"}\n\n'
                  '策略特性对比：\n'
                  '1. 混合自动：端侧 LLM + 规则兜底，兼顾智能泛化与极速高可用。\n'
                  '2. 纯端侧极速规则：极速秒解析，适合老旧低配设备。\n'
                  '3. 强制大模型：要求完整结构化推理，未加载时提示预热。',
              value: widget.engineMode,
              isDark: isDark,
              items: const [
                DropdownMenuItem(
                  value: AIEngineMode.hybridAuto,
                  child: Text('混合自动 (推荐)'),
                ),
                DropdownMenuItem(
                  value: AIEngineMode.builtInRuleEngine,
                  child: Text('纯端侧极速规则'),
                ),
                DropdownMenuItem(
                  value: AIEngineMode.localLlmServer,
                  child: Text('强制大模型'),
                ),
              ],
              onChanged: (val) {
                if (val != null) {
                  widget.onEngineModeChanged(val);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 设置模块 2：Android 零跳转悬浮窗与无障碍服务引导
  Widget _buildAndroidNativeFeaturesGuideCard(bool isDark) {
    final primaryColor =
        isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);

    return Card(
      elevation: 0,
      color: isDark
          ? const Color(0xFF1E293B)
          : const Color(0xFFEFF6FF),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isDark ? const Color(0xFF334155) : Colors.transparent,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.phone_android, color: primaryColor),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Android 零跳转悬浮窗 · 端侧无感采集三件套',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                ),
                _buildInfoBoxButton(
                  infoKey: 'androidFloatingGuide',
                  tooltip: '查看悬浮窗采集功能说明',
                  isDark: isDark,
                ),
                const SizedBox(width: 6),
                TextButton.icon(
                  onPressed: _checkNativeState,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('刷新状态', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
            if (_expandedInfoKeys.contains('androidFloatingGuide'))
              _buildExpandedInfoBox(
                '1. 零跳转全局悬浮卡：点击贴边胶囊即可在微信/QQ/浏览器上方原地展开操作卡，不切回主程序！支持：\n'
                '   • 🖥️ 读屏幕文字：通过无障碍节点树 0ms 直读当前屏幕聊天/网页文字（免截屏、免 OCR）\n'
                '   • 📸 截屏 OCR：自动收起悬浮窗静默截屏 + 内置 ML Kit 离线中文 OCR 识别海报/图片通知\n'
                '   • 📋 读剪贴板：焦点切换自动读取复制的文本，并在悬浮卡内一键静默写入系统日历\n'
                '2. 系统划词直达与分享：选中任意文字点击「提取日程」或「分享 -> 知程」即可一键解析。',
                isDark: isDark,
              ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: isDark
                    ? (_accessibilityEnabled
                        ? const Color(0xFF064E3B)
                        : const Color(0xFF451A03))
                    : (_accessibilityEnabled
                        ? Colors.green.shade50
                        : Colors.amber.shade50),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isDark
                      ? (_accessibilityEnabled
                          ? const Color(0xFF059669)
                          : const Color(0xFFB45309))
                      : (_accessibilityEnabled
                          ? Colors.green.shade200
                          : Colors.amber.shade300),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _accessibilityEnabled
                        ? Icons.verified_user
                        : Icons.privacy_tip_outlined,
                    size: 16,
                    color: isDark
                        ? (_accessibilityEnabled
                            ? const Color(0xFF34D399)
                            : const Color(0xFFFBBF24))
                        : (_accessibilityEnabled
                            ? Colors.green.shade700
                            : Colors.amber.shade900),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _accessibilityEnabled
                          ? '无障碍识屏与静默截屏服务：已激活（支持 0ms 读屏 + 离线中文 OCR）'
                          : '无障碍识屏服务：未开启（开启后可在悬浮窗内 0ms 读取当前屏幕文字或静默截屏）',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark
                            ? (_accessibilityEnabled
                                ? const Color(0xFF6EE7B7)
                                : const Color(0xFFFDE68A))
                            : (_accessibilityEnabled
                                ? Colors.green.shade800
                                : Colors.amber.shade900),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: () async {
                    final res =
                        await FloatingOverlayService.instance.toggleFloatingWindow(
                            !_floatingRunning);
                    await _checkNativeState();
                    if (res['message'] != null) {
                      _showSnack(res['message'].toString());
                    }
                  },
                  icon:
                      Icon(_floatingRunning ? Icons.stop : Icons.bubble_chart),
                  label:
                      Text(_floatingRunning ? '关闭全局悬浮窗' : '开启零跳转全局悬浮窗'),
                ),
                FilledButton.tonalIcon(
                  onPressed: () async {
                    await FloatingOverlayService.instance.openAccessibilitySettings();
                    _showSnack('请在系统无障碍设置中找到「知程 AI 识屏与静默截屏助手」并开启');
                  },
                  icon: Icon(
                    _accessibilityEnabled
                        ? Icons.check_circle_outline
                        : Icons.accessibility_new,
                  ),
                  label: Text(
                    _accessibilityEnabled ? '无障碍识屏已开启' : '开启无障碍识屏/截屏权限',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 设置模块 3：局域网双端协同设置
  Widget _buildLanSyncCard(bool isDark) {
    final primaryColor =
        isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isDark ? const Color(0xFF334155) : Colors.grey.shade200,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.hub_outlined, size: 18, color: primaryColor),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '局域网双端协同与算力共享',
                    style: TextStyle(
                        fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                ),
                _buildInfoBoxButton(
                  infoKey: 'lanSyncGuide',
                  tooltip: '查看局域网协同说明',
                  isDark: isDark,
                ),
              ],
            ),
            if (_expandedInfoKeys.contains('lanSyncGuide'))
              _buildExpandedInfoBox(
                '• 双向日程合并：在同一 Wi-Fi 局域网下输入对端设备 IP 点击同步，自动合并两端所有日程并智能去重。\n'
                '• 跨设备算力借调：移动端可配置 PC 端的局域网 IP，免去手机运行大模型的发热和电量消耗，借调 PC 高性能算力秒级解析。',
                isDark: isDark,
              ),
            const SizedBox(height: 8),
            SelectableText(
              '本机局域网协同地址 (端口 ${LanSyncService.defaultPort}):\n'
              '${widget.localIps.isEmpty ? "未连接局域网" : widget.localIps.join(" / ")}',
              style: TextStyle(
                  fontSize: 12,
                  color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade700,
                  fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: widget.peerIpController,
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: '对端设备 IP (同步/共享算力)',
                      hintText: '如 192.168.x.x',
                      border: OutlineInputBorder(),
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
                    try {
                      final currentEvents = AgendaRepository.instance.allEvents;
                      final merged = await LanSyncService.syncWithPeer(
                        peerIp: ip,
                        localEvents: currentEvents,
                      );
                      await AgendaRepository.instance.mergeRemoteEvents(merged);
                      _showSnack('🎉 双端同步成功！当前共 ${merged.length} 项日程');
                    } catch (e) {
                      _showSnack('同步失败: $e');
                    }
                  },
                  icon: const Icon(Icons.sync, size: 16),
                  label: const Text('同步'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 设置模块 4：关于知程
  Widget _buildAboutCard(bool isDark) {
    final primaryColor =
        isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isDark ? const Color(0xFF334155) : Colors.grey.shade200,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.verified, color: primaryColor, size: 20),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '知程 Anno2Agenda v1.2.0',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                ),
                _buildInfoBoxButton(
                  infoKey: 'aboutGuide',
                  tooltip: '查看关于知程说明',
                  isDark: isDark,
                ),
              ],
            ),
            if (_expandedInfoKeys.contains('aboutGuide'))
              _buildExpandedInfoBox(
                '• 100% 端侧隐私安全：通知文本与日程数据全程在本地设备离线解析，无任何云端上传统计。\n'
                '• 基于 Flutter + llama.cpp (Vulkan GPU/ARM NEON) + Google ML Kit 离线中文 OCR。\n'
                '• 遵循 MIT 开源协议，专为高校通知与多节点日程痛点打造。',
                isDark: isDark,
              )
            else
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '100% 端侧隐私安全 · 跨平台多端协同 · MIT 开源',
                  style: TextStyle(
                    fontSize: 12,
                    color:
                        isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        _buildThemeModeCard(isDark),
        const SizedBox(height: 14),
        _buildModelEngineSettingsCard(isDark),
        const SizedBox(height: 14),
        if (Platform.isAndroid) ...[
          _buildAndroidNativeFeaturesGuideCard(isDark),
          const SizedBox(height: 14),
        ],
        _buildLanSyncCard(isDark),
        const SizedBox(height: 14),
        _buildAboutCard(isDark),
      ],
    );
  }
}
