import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/agenda_event.dart';
import '../services/ai_extractor_service.dart';
import '../services/local_model_manager.dart';
import '../widgets/agenda_event_card.dart';
import '../widgets/inference_terminal.dart';
import 'ai_extract_page.dart';

/// 系统提示词修改与端侧推理测试调优工作台
class PromptTestingPage extends StatefulWidget {
  const PromptTestingPage({super.key});

  @override
  State<PromptTestingPage> createState() => _PromptTestingPageState();
}

class _PromptTestingPageState extends State<PromptTestingPage> {
  final TextEditingController _promptController = TextEditingController();
  final TextEditingController _testTextController = TextEditingController();

  bool _isTesting = false;
  bool _thinkMode = false;
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

  @override
  void initState() {
    super.initState();
    final currentPrompt = AIExtractorService.customSystemPromptTemplate ??
        AIExtractorService.defaultSystemPromptTemplate;
    _promptController.text = currentPrompt;
    _testTextController.text =
        AIExtractPage.sampleAnnouncements.first['text']!;
    _thinkMode = LocalModelManager.enableThinkMode;

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

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor =
        isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB);

    return Scaffold(
      body: NestedScrollView(
        headerSliverBuilder: (context, innerBoxIsScrolled) => [
          SliverAppBar(
            titleSpacing: 0,
            floating: true,
            snap: true,
            pinned: false,
            title: const Text(
              '系统提示词修改与测试',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            actions: [
              FilledButton.icon(
                onPressed: _savePrompt,
                icon: const Icon(Icons.save, size: 16),
                label: Text(_isDirty ? '保存修改*' : '已保存'),
              ),
              const SizedBox(width: 12),
            ],
          ),
        ],
        body: LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= 840;
            if (isWide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 5,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: _buildInputEditorSection(isDark, primaryColor),
                    ),
                  ),
                  const VerticalDivider(width: 1, thickness: 1),
                  Expanded(
                    flex: 6,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child:
                          _buildOutputDiagnosticSection(isDark, primaryColor),
                    ),
                  ),
                ],
              );
            } else {
              return SingleChildScrollView(
                padding: const EdgeInsets.all(14),
                child: Column(
                  children: [
                    _buildInputEditorSection(isDark, primaryColor),
                    const SizedBox(height: 16),
                    const Divider(),
                    const SizedBox(height: 12),
                    _buildOutputDiagnosticSection(isDark, primaryColor),
                  ],
                ),
              );
            }
          },
        ),
      ),
    );
  }

  /// 构建左侧/上方的系统提示词与输入编辑器区域
  Widget _buildInputEditorSection(bool isDark, Color primaryColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. 系统提示词卡片
        Card(
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
                        Icon(Icons.terminal, color: primaryColor, size: 18),
                        const SizedBox(width: 6),
                        const Text(
                          'System Prompt (系统指令模板)',
                          style: TextStyle(
                              fontSize: 14, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    ActionChip(
                      visualDensity: VisualDensity.compact,
                      avatar: const Icon(Icons.add, size: 14),
                      label: const Text('{TIME_ANCHOR} 宏',
                          style: TextStyle(fontSize: 11.5)),
                      tooltip: '在光标处插入动态时间锚点占位符',
                      onPressed: _insertTimeAnchorMacro,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '说明：用于约束大模型输出严格的 JSON Schema 结构。支持使用 {TIME_ANCHOR} 宏自动注入换算相对时间的系统时间锚点。',
                  style: TextStyle(
                    fontSize: 11.5,
                    color:
                        isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _promptController,
                  maxLines: 12,
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
                  children: [
                    OutlinedButton.icon(
                      onPressed: _resetToDefault,
                      icon: const Icon(Icons.restart_alt, size: 15),
                      label:
                          const Text('恢复默认提示词', style: TextStyle(fontSize: 12)),
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                      ),
                    ),
                    const Spacer(),
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
        ),

        const SizedBox(height: 14),

        // 2. 测试输入通知文本卡片
        Card(
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
                          'User Prompt (测试杂乱通知)',
                          style: TextStyle(
                              fontSize: 14, fontWeight: FontWeight.bold),
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
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _testTextController,
                  maxLines: 5,
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
        ),

        const SizedBox(height: 14),

        // 3. 运行控制卡片
        Container(
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
                  label: Text(_isTesting ? '正在调用大模型推理测试...' : '🚀 运行提示词推理测试'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 构建右侧/下方的端侧推理实况与 JSON 格式诊断输出区域
  Widget _buildOutputDiagnosticSection(bool isDark, Color primaryColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. 端侧推理实况终端（直接复用 InferenceTerminal，传入更大的 maxHeight: 360）
        InferenceTerminal(
          isExtracting: _isTesting,
          processLogs: _processLogs,
          streamedTokens: _tokenBuffer.toString(),
          tokenCount: _tokenCount,
          elapsedSeconds: _elapsedSeconds,
          maxHeight: 360, // 调试模式下提供更大的视窗
          initialExpanded: true,
        ),

        // 2. JSON 结构化诊断卡片
        if (_hasTested) ...[
          const SizedBox(height: 6),
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
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.data_object,
                              size: 16, color: Color(0xFF10B981)),
                          const SizedBox(width: 6),
                          const Text(
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
                    constraints: const BoxConstraints(maxHeight: 180),
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
                isDraft: true,
                onDelete: () {
                  setState(() {
                    _parsedEvents.removeWhere((e) => e.id == event.id);
                  });
                },
              ),
            ),
        ],
      ],
    );
  }

  /// 构建 JSON 格式与有效性诊断状态卡片
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
                color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF334155),
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
