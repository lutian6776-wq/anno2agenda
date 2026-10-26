import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/agenda_event.dart';
import '../services/ai_extractor_service.dart';
import '../services/local_model_manager.dart';
import '../widgets/agenda_event_card.dart';
import '../widgets/inference_terminal.dart';
import 'ai_extract_page.dart';

/// 系统提示词修改与端侧推理测试调优工作台（支持多种屏幕比例与桌面端自适应）
class PromptTestingPage extends StatefulWidget {
  const PromptTestingPage({super.key});

  @override
  State<PromptTestingPage> createState() => _PromptTestingPageState();
}

class _PromptTestingPageState extends State<PromptTestingPage> {
  final TextEditingController _promptController = TextEditingController();
  final TextEditingController _testTextController = TextEditingController();

  // 独立滚动控制器，确保桌面端 Scrollbar 正确绑定且各栏平滑滚动
  final ScrollController _leftScrollController = ScrollController();
  final ScrollController _midScrollController = ScrollController();
  final ScrollController _rightScrollController = ScrollController();
  final ScrollController _singleScrollController = ScrollController();

  bool _isTesting = false;
  bool _thinkMode = false;
  bool _useGbnf = true;
  String? _selectedModel;
  List<String> _availableModels = [];

  // 终端实况状态
  final List<String> _processLogs = [];
  final StringBuffer _tokenBuffer = StringBuffer();
  int _tokenCount = 0;
  double _elapsedSeconds = 0.0;
  Stopwatch? _stopwatch;
  Timer? _ticker;

  // 诊断与输出
  String _rawOutput = '';
  String? _diagnosticError;
  List<AgendaEvent> _parsedEvents = [];
  bool _hasTested = false;
  bool _isDirty = false;

  bool get _isDesktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  @override
  void initState() {
    super.initState();
    final currentPrompt = AIExtractorService.customSystemPromptTemplate ??
        AIExtractorService.defaultSystemPromptTemplate;
    _promptController.text = currentPrompt;
    _testTextController.text =
        AIExtractPage.sampleAnnouncements.first['text']!;
    _thinkMode = LocalModelManager.enableThinkMode;
    _useGbnf = AIExtractorService.enableGbnfConstraint;

    _promptController.addListener(() {
      if (!_isDirty) setState(() => _isDirty = true);
    });

    _loadModels();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _promptController.dispose();
    _testTextController.dispose();
    _leftScrollController.dispose();
    _midScrollController.dispose();
    _rightScrollController.dispose();
    _singleScrollController.dispose();
    super.dispose();
  }

  Future<void> _loadModels() async {
    final list = await LocalModelManager.ensureLocalRuntimeAndListModels();
    if (!mounted) return;
    setState(() {
      _availableModels = list;
      if (list.isNotEmpty) {
        _selectedModel = list.first;
      }
    });
  }

  void _insertTimeAnchorMacro() {
    const macro = '{TIME_ANCHOR}';
    final text = _promptController.text;
    final selection = _promptController.selection;
    if (selection.isValid && selection.start >= 0) {
      final newText = text.replaceRange(selection.start, selection.end, macro);
      _promptController.value = TextEditingValue(
        text: newText,
        selection:
            TextSelection.collapsed(offset: selection.start + macro.length),
      );
    } else {
      _promptController.text = '$text\n$macro';
    }
  }

  Future<void> _savePrompt() async {
    final text = _promptController.text.trim();
    if (text == AIExtractorService.defaultSystemPromptTemplate.trim()) {
      await AIExtractorService.resetDefaultPrompt();
    } else {
      await AIExtractorService.saveCustomPrompt(text);
    }
    setState(() => _isDirty = false);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('✅ 系统提示词已保存，将全局应用于常规提取与悬浮窗！'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _resetToDefault() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.restart_alt, color: Color(0xFFEF4444)),
            SizedBox(width: 8),
            Text('恢复默认提示词'),
          ],
        ),
        content: const Text(
          '确定要放弃当前对 System Prompt 的修改，恢复为官方内置的标准结构化提取提示词吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFEF4444),
            ),
            child: const Text('确认恢复'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await AIExtractorService.resetDefaultPrompt();
      setState(() {
        _promptController.text = AIExtractorService.defaultSystemPromptTemplate;
        _isDirty = false;
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已恢复为官方内置默认系统提示词'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _runPromptTest() async {
    final prompt = _promptController.text.trim();
    final userText = _testTextController.text.trim();
    if (prompt.isEmpty) {
      _showSnack('系统提示词不能为空');
      return;
    }
    if (userText.isEmpty) {
      _showSnack('请先输入测试通知文本');
      return;
    }

    _stopwatch = Stopwatch()..start();
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted && _isTesting) {
        setState(() {
          _elapsedSeconds = (_stopwatch?.elapsedMilliseconds ?? 0) / 1000.0;
        });
      }
    });

    setState(() {
      _isTesting = true;
      _hasTested = true;
      _processLogs.clear();
      _tokenBuffer.clear();
      _tokenCount = 0;
      _elapsedSeconds = 0.0;
      _rawOutput = '';
      _diagnosticError = null;
      _parsedEvents = [];
    });

    try {
      final result = await AIExtractorService.testInference(
        userPrompt: userText,
        systemPrompt: prompt,
        modelName: _selectedModel,
        thinkMode: _thinkMode,
        useGbnf: _useGbnf,
        onProgress: ({stepLog, token, tokenCount}) {
          if (!mounted) return;
          setState(() {
            if (stepLog != null) {
              final now = DateTime.now();
              final timeStr =
                  '${now.hour.toString().padLeft(2, "0")}:${now.minute.toString().padLeft(2, "0")}:${now.second.toString().padLeft(2, "0")}.${(now.millisecond ~/ 100)}';
              _processLogs.add('[$timeStr] $stepLog');
            }
            if (token != null) {
              _tokenBuffer.write(token);
              if (tokenCount != null) {
                _tokenCount = tokenCount;
              }
            }
          });
        },
      );

      if (!mounted) return;
      setState(() {
        _rawOutput = result.rawResponse ?? _tokenBuffer.toString();
        _diagnosticError = result.jsonParseError;
        _parsedEvents = result.events;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _diagnosticError = '测试异常: $e';
          _processLogs.add('[异常] $e');
        });
      }
    } finally {
      _ticker?.cancel();
      _stopwatch?.stop();
      if (mounted) setState(() => _isTesting = false);
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _showGbnfInspectorDialog() async {
    final gbnfController = TextEditingController(
      text: AIExtractorService.activeGbnfGrammar,
    );
    final screenWidth = MediaQuery.of(context).size.width;
    final dialogWidth = math.min(640.0, screenWidth - 40.0);

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.rule_folder_outlined, color: Color(0xFF10B981)),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'GBNF (GGML BNF) 强制语法规则',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: dialogWidth,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '在 Token 采样阶段将不符合该 BNF 产生式的候选词概率置为 -∞，从根源杜绝非法键名、Markdown 包裹、类型错误与截断未闭合。',
                style: TextStyle(fontSize: 12, height: 1.4),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: gbnfController,
                maxLines: 14,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11.5,
                  height: 1.4,
                ),
                decoration: InputDecoration(
                  filled: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              gbnfController.text =
                  AIExtractorService.defaultAgendaGbnfGrammar.trim();
            },
            child: const Text('恢复默认 GBNF'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final next = gbnfController.text.trim();
              AIExtractorService.customGbnfGrammar =
                  (next.isEmpty ||
                          next ==
                              AIExtractorService.defaultAgendaGbnfGrammar
                                  .trim())
                      ? null
                      : next;
              Navigator.pop(ctx);
              _showSnack('✅ GBNF 语法产生式已更新生效');
            },
            child: const Text('应用规则'),
          ),
        ],
      ),
    );
    gbnfController.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor =
        isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB);

    // 桌面端快捷键映射 (Ctrl+S 保存，Ctrl+Enter 运行测试)
    final shortcuts = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.keyS, control: true): _savePrompt,
      const SingleActivator(LogicalKeyboardKey.keyS, meta: true): _savePrompt,
      const SingleActivator(LogicalKeyboardKey.enter, control: true): () {
        if (!_isTesting) _runPromptTest();
      },
      const SingleActivator(LogicalKeyboardKey.enter, meta: true): () {
        if (!_isTesting) _runPromptTest();
      },
    };

    return CallbackShortcuts(
      bindings: shortcuts,
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 12,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '系统提示词修改与测试',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  if (_isDirty) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1.5),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF59E0B).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: const Color(0xFFF59E0B)),
                      ),
                      child: const Text(
                        '未保存*',
                        style: TextStyle(
                          fontSize: 10.5,
                          color: Color(0xFFF59E0B),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              Text(
                '实时调试 System / User Prompt 与 GBNF 语法约束',
                style: TextStyle(
                  fontSize: 11,
                  color: isDark
                      ? const Color(0xFF94A3B8)
                      : const Color(0xFF64748B),
                  fontWeight: FontWeight.normal,
                ),
              ),
            ],
          ),
          actions: [
            if (_isDesktop) ...[
              Tooltip(
                message: '快捷键: Ctrl + Enter (Mac: Cmd + Enter)',
                child: FilledButton.tonalIcon(
                  onPressed: _isTesting ? null : _runPromptTest,
                  icon: _isTesting
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow_rounded, size: 16),
                  label: const Text('运行测试'),
                ),
              ),
              const SizedBox(width: 8),
            ],
            Tooltip(
              message: _isDesktop ? '快捷键: Ctrl + S (Mac: Cmd + S)' : '保存提示词',
              child: FilledButton.icon(
                onPressed: _savePrompt,
                icon: const Icon(Icons.save, size: 16),
                label: Text(_isDirty ? '保存修改*' : '已保存'),
              ),
            ),
            const SizedBox(width: 12),
          ],
        ),
        body: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final height = constraints.maxHeight;

            // 1. 超宽比例 / 极宽屏 (21:9, 大屏 16:9, width >= 1320)
            // 采用三栏 Playground: [Prompt编辑] | [测试样本与控制] | [推理终端与诊断]
            if (width >= 1320) {
              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1800),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 第一栏：System Prompt 编辑器
                      Expanded(
                        flex: 38,
                        child: Scrollbar(
                          controller: _leftScrollController,
                          thumbVisibility: true,
                          child: SingleChildScrollView(
                            controller: _leftScrollController,
                            padding: const EdgeInsets.all(16),
                            child: _buildPromptCard(
                              isDark,
                              primaryColor,
                              isThreeCol: true,
                            ),
                          ),
                        ),
                      ),
                      const VerticalDivider(width: 1, thickness: 1),
                      // 第二栏：User Prompt 待测文本与控制面板
                      Expanded(
                        flex: 32,
                        child: Scrollbar(
                          controller: _midScrollController,
                          thumbVisibility: true,
                          child: SingleChildScrollView(
                            controller: _midScrollController,
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _buildUserPromptCard(
                                  isDark,
                                  primaryColor,
                                  isThreeCol: true,
                                ),
                                const SizedBox(height: 14),
                                _buildRunControlsCard(isDark, primaryColor),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const VerticalDivider(width: 1, thickness: 1),
                      // 第三栏：推理终端实况、JSON诊断与提取结果
                      Expanded(
                        flex: 42,
                        child: Scrollbar(
                          controller: _rightScrollController,
                          thumbVisibility: true,
                          child: SingleChildScrollView(
                            controller: _rightScrollController,
                            padding: const EdgeInsets.all(16),
                            child: _buildOutputDiagnosticSection(
                              isDark,
                              primaryColor,
                              terminalMaxHeight:
                                  (height - 180).clamp(340.0, 560.0),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }

            // 2. 标准桌面 / 笔记本 (860 <= width < 1320, 16:9 / 16:10 / 3:2)
            // 采用经典双栏工作台: [输入与配置栏] | [输出实况与诊断栏]
            else if (width >= 860) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 5,
                    child: Scrollbar(
                      controller: _leftScrollController,
                      thumbVisibility: true,
                      child: SingleChildScrollView(
                        controller: _leftScrollController,
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildPromptCard(isDark, primaryColor),
                            const SizedBox(height: 14),
                            _buildUserPromptCard(isDark, primaryColor),
                            const SizedBox(height: 14),
                            _buildRunControlsCard(isDark, primaryColor),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const VerticalDivider(width: 1, thickness: 1),
                  Expanded(
                    flex: 6,
                    child: Scrollbar(
                      controller: _rightScrollController,
                      thumbVisibility: true,
                      child: SingleChildScrollView(
                        controller: _rightScrollController,
                        padding: const EdgeInsets.all(16),
                        child: _buildOutputDiagnosticSection(
                          isDark,
                          primaryColor,
                          terminalMaxHeight:
                              (height - 200).clamp(340.0, 560.0),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            }

            // 3. 紧凑屏幕 / 窄分屏 / 移动端 (width < 860)
            // 采用单列顺畅纵向流式排布
            else {
              return Scrollbar(
                controller: _singleScrollController,
                child: SingleChildScrollView(
                  controller: _singleScrollController,
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildPromptCard(isDark, primaryColor),
                      const SizedBox(height: 12),
                      _buildUserPromptCard(isDark, primaryColor),
                      const SizedBox(height: 12),
                      _buildRunControlsCard(isDark, primaryColor),
                      const SizedBox(height: 16),
                      const Divider(),
                      const SizedBox(height: 12),
                      _buildOutputDiagnosticSection(
                        isDark,
                        primaryColor,
                        terminalMaxHeight: 340,
                      ),
                    ],
                  ),
                ),
              );
            }
          },
        ),
      ),
    );
  }

  /// 1. 构建 System Prompt 编辑卡片
  Widget _buildPromptCard(
    bool isDark,
    Color primaryColor, {
    bool isThreeCol = false,
  }) {
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
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 6,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.terminal, color: primaryColor, size: 18),
                    const SizedBox(width: 6),
                    const Text(
                      'System Prompt (系统指令模板)',
                      style:
                          TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    ActionChip(
                      visualDensity: VisualDensity.compact,
                      avatar: const Icon(Icons.add, size: 14),
                      label: const Text('{TIME_ANCHOR} 宏',
                          style: TextStyle(fontSize: 11.5)),
                      tooltip: '在光标处插入动态时间锚点占位符',
                      onPressed: _insertTimeAnchorMacro,
                    ),
                    OutlinedButton.icon(
                      onPressed: _resetToDefault,
                      icon: const Icon(Icons.restart_alt, size: 14),
                      label:
                          const Text('恢复默认', style: TextStyle(fontSize: 11.5)),
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '说明：用于约束模型生成严格的 events 结构化日程。可插入 {TIME_ANCHOR} 宏自动注入当前系统时间供模型换算“明天/下周”。',
              style: TextStyle(
                fontSize: 11.5,
                color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _promptController,
              maxLines: isThreeCol ? 16 : 11,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.45,
              ),
              decoration: InputDecoration(
                filled: true,
                fillColor: isDark
                    ? const Color(0xFF0F172A)
                    : const Color(0xFFF8FAFC),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(
                    color: isDark
                        ? const Color(0xFF334155)
                        : const Color(0xFFCBD5E1),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  '${_promptController.text.length} 字符',
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark
                        ? const Color(0xFF64748B)
                        : Colors.grey.shade500,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 2. 构建 User Prompt 测试样本卡片
  Widget _buildUserPromptCard(
    bool isDark,
    Color primaryColor, {
    bool isThreeCol = false,
  }) {
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
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.description_outlined,
                        color: primaryColor, size: 18),
                    const SizedBox(width: 6),
                    const Text(
                      'User Prompt (待测通知文本)',
                      style:
                          TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    PopupMenuButton<int>(
                      tooltip: '填入典型测试通知示例',
                      icon: const Icon(Icons.smart_display_outlined, size: 18),
                      onSelected: (idx) {
                        final sample =
                            AIExtractPage.sampleAnnouncements[idx];
                        _testTextController.text = sample['text']!;
                      },
                      itemBuilder: (context) => [
                        for (int i = 0;
                            i < AIExtractPage.sampleAnnouncements.length;
                            i++)
                          PopupMenuItem(
                            value: i,
                            child: Text(
                              AIExtractPage.sampleAnnouncements[i]['label']!,
                              style: const TextStyle(fontSize: 12.5),
                            ),
                          ),
                      ],
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '从剪贴板粘贴',
                      icon: const Icon(Icons.paste, size: 18),
                      onPressed: () async {
                        final data =
                            await Clipboard.getData(Clipboard.kTextPlain);
                        if (data?.text != null && data!.text!.isNotEmpty) {
                          _testTextController.text = data.text!;
                        }
                      },
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '清空文本',
                      icon: const Icon(Icons.clear_all, size: 18),
                      onPressed: () {
                        _testTextController.clear();
                      },
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _testTextController,
              maxLines: isThreeCol ? 6 : 5,
              decoration: InputDecoration(
                hintText: '输入或粘贴用于测试的群通知、调课或会议通知...',
                filled: true,
                fillColor: isDark
                    ? const Color(0xFF0F172A)
                    : const Color(0xFFF8FAFC),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(
                    color: isDark
                        ? const Color(0xFF334155)
                        : const Color(0xFFCBD5E1),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 3. 构建运行控制与参数配置卡片
  Widget _buildRunControlsCard(bool isDark, Color primaryColor) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color:
              isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.memory, size: 18),
              const SizedBox(width: 8),
              const Text('选择模型:',
                  style:
                      TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _selectedModel,
                    isDense: true,
                    isExpanded: true,
                    hint: const Text('未检测到本地模型'),
                    items: _availableModels.map((m) {
                      return DropdownMenuItem(
                        value: m,
                        child: Text(m,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12.5)),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) setState(() => _selectedModel = val);
                    },
                  ),
                ),
              ),
            ],
          ),
          const Divider(height: 14),
          Row(
            children: [
              const Icon(Icons.psychology_outlined, size: 18),
              const SizedBox(width: 8),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('深度思考 (Think Mode)',
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.bold)),
                    Text('输出思维链。关掉则强制直出纯 JSON',
                        style: TextStyle(fontSize: 11, color: Colors.grey)),
                  ],
                ),
              ),
              Switch(
                value: _thinkMode,
                onChanged: (val) => setState(() => _thinkMode = val),
              ),
            ],
          ),
          const Divider(height: 14),
          Row(
            children: [
              const Icon(Icons.verified_user_outlined,
                  size: 18, color: Color(0xFF10B981)),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text('GBNF 强制语法约束',
                            style: TextStyle(
                                fontSize: 13, fontWeight: FontWeight.bold)),
                        const SizedBox(width: 6),
                        InkWell(
                          onTap: _showGbnfInspectorDialog,
                          borderRadius: BorderRadius.circular(4),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: 4, vertical: 2),
                            child: Text(
                              '查看/编辑 GBNF',
                              style: TextStyle(
                                fontSize: 11,
                                color: Color(0xFF2563EB),
                                decoration: TextDecoration.underline,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const Text(
                      '在采样层强制锁定 events 结构与 ISO-8601 时间格式',
                      style: TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ],
                ),
              ),
              Switch(
                value: _useGbnf,
                onChanged: (val) {
                  setState(() {
                    _useGbnf = val;
                    AIExtractorService.enableGbnfConstraint = val;
                  });
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 44,
            child: FilledButton.icon(
              onPressed: _isTesting ? null : _runPromptTest,
              icon: _isTesting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.play_arrow_rounded),
              label: Text(_isTesting
                  ? '正在调用大模型推理测试...'
                  : _isDesktop
                      ? '🚀 运行提示词推理测试 (Ctrl+Enter)'
                      : '🚀 运行提示词推理测试'),
            ),
          ),
        ],
      ),
    );
  }

  /// 4. 构建右侧/下方的推理实况终端与格式诊断输出区域
  Widget _buildOutputDiagnosticSection(
    bool isDark,
    Color primaryColor, {
    required double terminalMaxHeight,
  }) {
    final hasTerminalContent =
        _processLogs.isNotEmpty || _tokenBuffer.isNotEmpty || _isTesting;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 尚未执行测试时的优雅引导占位卡片
        if (!hasTerminalContent && !_hasTested) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color:
                    isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
              ),
            ),
            child: Column(
              children: [
                Icon(
                  Icons.developer_board_outlined,
                  size: 48,
                  color: primaryColor.withValues(alpha: 0.8),
                ),
                const SizedBox(height: 12),
                const Text(
                  '端侧推理实况与 JSON 诊断就绪',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text(
                  '在左侧配置好系统提示词、待测通知文本与模型参数后，点击「运行提示词推理测试」或按 Ctrl+Enter，即可在此处全屏/分屏实时观测 Token 流式生成、语法诊断与日程草稿提取效果。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark
                        ? const Color(0xFF94A3B8)
                        : Colors.grey.shade600,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],

        // 1. 端侧推理实况终端（自适应高度）
        if (hasTerminalContent) ...[
          InferenceTerminal(
            isExtracting: _isTesting,
            processLogs: _processLogs,
            streamedTokens: _tokenBuffer.toString(),
            tokenCount: _tokenCount,
            elapsedSeconds: _elapsedSeconds,
            maxHeight: terminalMaxHeight,
            initialExpanded: true,
          ),
        ],

        // 2. JSON 结构化诊断卡片
        if (_hasTested) ...[
          const SizedBox(height: 4),
          _buildDiagnosticCard(isDark),
          const SizedBox(height: 12),
        ],

        // 3. 原始返回输出折叠卡片 (Raw Output)
        if (_rawOutput.isNotEmpty) ...[
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(
                color: isDark ? const Color(0xFF334155) : Colors.grey.shade200,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.data_object,
                              size: 16, color: Color(0xFF10B981)),
                          SizedBox(width: 6),
                          Text(
                            '模型生成原始全文 (Raw Output)',
                            style: TextStyle(
                                fontSize: 13, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: '复制原始输出',
                        icon: const Icon(Icons.copy, size: 15),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: _rawOutput));
                          _showSnack('已复制原始文本到剪贴板');
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: isDark
                          ? const Color(0xFF0F172A)
                          : const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isDark
                            ? const Color(0xFF1E293B)
                            : const Color(0xFFE2E8F0),
                      ),
                    ),
                    constraints: const BoxConstraints(maxHeight: 200),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        _rawOutput,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],

        // 4. 解析成功的日程草稿预览列表
        if (_parsedEvents.isNotEmpty) ...[
          Row(
            children: [
              const Icon(Icons.event_available,
                  color: Color(0xFF10B981), size: 18),
              const SizedBox(width: 6),
              Text(
                '提取出的结构化日程草稿 (${_parsedEvents.length})',
                style:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final event in _parsedEvents)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: AgendaEventCard(
                event: event,
                showDate: true,
                isDraft: true,
                onDelete: () {
                  setState(() {
                    _parsedEvents.removeWhere((e) => e.id == event.id);
                  });
                },
                onEventChanged: (updated) {
                  setState(() {
                    final idx =
                        _parsedEvents.indexWhere((e) => e.id == updated.id);
                    if (idx >= 0) {
                      _parsedEvents[idx] = updated;
                    }
                  });
                },
              ),
            ),
        ],
      ],
    );
  }

  /// 5. 构建 JSON 格式与有效性诊断状态卡片
  Widget _buildDiagnosticCard(bool isDark) {
    final hasEvents = _parsedEvents.isNotEmpty;
    final hasError = _diagnosticError != null;

    final Color statusColor;
    final IconData statusIcon;
    final String statusTitle;

    if (hasEvents && !hasError) {
      statusColor = const Color(0xFF10B981);
      statusIcon = Icons.check_circle;
      statusTitle = '严格标准 JSON · 成功提取出 ${_parsedEvents.length} 项日程';
    } else if (hasEvents && hasError) {
      statusColor = const Color(0xFFF59E0B);
      statusIcon = Icons.warning_amber_rounded;
      statusTitle = '容错提取成功 (共 ${_parsedEvents.length} 项)，但 JSON 格式存在缺陷';
    } else {
      statusColor = const Color(0xFFEF4444);
      statusIcon = Icons.error_outline;
      statusTitle = 'JSON 解析失败 · 未能提取出有效日程';
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: statusColor.withValues(alpha: isDark ? 0.15 : 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: statusColor.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(statusIcon, color: statusColor, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  statusTitle,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: statusColor,
                  ),
                ),
              ),
            ],
          ),
          if (_diagnosticError != null) ...[
            const SizedBox(height: 6),
            Text(
              '诊断详情: $_diagnosticError',
              style: TextStyle(
                fontSize: 11.5,
                color:
                    isDark ? const Color(0xFFE2E8F0) : const Color(0xFF334155),
                height: 1.4,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '💡 调优建议：可在 System Prompt 中强调：\n'
              '1. “只允许输出符合 JSON 语法的字符串，严禁输出任何 markdown 标记如 ```json 或前导/后置解释文字”。\n'
              '2. “必须以 {"events": 开头，以 ]} 结尾”。',
              style: TextStyle(
                fontSize: 11,
                color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade700,
                height: 1.35,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
