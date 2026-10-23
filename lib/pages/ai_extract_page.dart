import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/agenda_event.dart';
import '../services/ai_extractor_service.dart';
import '../widgets/agenda_empty_state.dart';
import '../widgets/agenda_event_card.dart';
import '../widgets/inference_terminal.dart';

/// 「AI 提取」工作台页面（通知投喂、打字机终端实况、结构化草稿确认）
class AIExtractPage extends StatefulWidget {
  final TextEditingController inputController;
  final AIEngineMode engineMode;
  final String? selectedModelName;
  final String llmEndpoint;
  final String lastEngineInfo;
  final List<AgendaEvent> draftEvents;
  final bool isExtracting;
  final List<String> processLogs;
  final String streamedTokens;
  final int tokenCount;
  final double elapsedSeconds;
  final Future<void> Function({String sourceType}) onRunExtraction;
  final Future<void> Function(AgendaEvent event) onConfirmDraft;
  final Future<void> Function({bool writeSystemCalendar}) onConfirmAllDrafts;
  final void Function(AgendaEvent event) onRemoveDraft;

  const AIExtractPage({
    super.key,
    required this.inputController,
    required this.engineMode,
    required this.selectedModelName,
    required this.llmEndpoint,
    required this.lastEngineInfo,
    required this.draftEvents,
    required this.isExtracting,
    required this.processLogs,
    required this.streamedTokens,
    required this.tokenCount,
    required this.elapsedSeconds,
    required this.onRunExtraction,
    required this.onConfirmDraft,
    required this.onConfirmAllDrafts,
    required this.onRemoveDraft,
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
  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('剪贴板为空或无文本权限')),
      );
      return;
    }
    widget.inputController.text = text;
    await widget.onRunExtraction(sourceType: 'clipboard');
  }

  Widget _buildInputCard() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
          mainAxisSize: MainAxisSize.min,
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
                    Icon(Icons.description_outlined, color: primaryColor),
                    const SizedBox(width: 8),
                    const Text(
                      '1. 杂乱通知投喂区',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(width: 4),
                    PopupMenuButton<int>(
                      tooltip: '填入演示示例通知',
                      icon: Icon(
                        Icons.smart_display_outlined,
                        size: 20,
                        color: primaryColor,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      onSelected: (idx) {
                        final sample = AIExtractPage.sampleAnnouncements[idx];
                        widget.inputController.text = sample['text']!;
                        widget.onRunExtraction(sourceType: 'preset');
                      },
                      itemBuilder: (context) => [
                        for (int i = 0;
                            i < AIExtractPage.sampleAnnouncements.length;
                            i++)
                          PopupMenuItem(
                            value: i,
                            child: Text(
                              AIExtractPage.sampleAnnouncements[i]['label']!,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
                TextButton.icon(
                  onPressed: _pasteFromClipboard,
                  icon: const Icon(Icons.paste, size: 16),
                  label: const Text('粘贴提取'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: widget.inputController,
              maxLines: 6,
              decoration: InputDecoration(
                hintText: '粘贴班级群通知、教务长文或视频语音转写内容...\n也可点击标题旁的演示图标填入示例',
                hintStyle: TextStyle(
                  color: isDark ? const Color(0xFF64748B) : Colors.grey.shade500,
                ),
                filled: true,
                fillColor:
                    isDark ? const Color(0xFF0F172A) : Colors.grey.shade50,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: isDark
                        ? const Color(0xFF334155)
                        : Colors.grey.shade300,
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: isDark
                        ? const Color(0xFF334155)
                        : Colors.grey.shade300,
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: primaryColor,
                    width: 1.5,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed:
                    widget.isExtracting ? null : () => widget.onRunExtraction(),
                icon: widget.isExtracting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.auto_fix_high),
                label: Text(
                  widget.isExtracting ? '端侧 AI 解析中...' : 'AI 提取结构化日程',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDraftPreviewCard({bool shrinkWrap = false}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
          mainAxisSize: MainAxisSize.min,
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
                    Icon(Icons.event_available, color: primaryColor),
                    const SizedBox(width: 8),
                    Text(
                      '2. 结构化草稿 (${widget.draftEvents.length})',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                if (widget.draftEvents.isNotEmpty)
                  TextButton.icon(
                    onPressed: () =>
                        widget.onConfirmAllDrafts(writeSystemCalendar: true),
                    icon: const Icon(Icons.done_all, size: 16),
                    label: const Text('全部入库'),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              widget.lastEngineInfo,
              style: TextStyle(
                fontSize: 12,
                color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600,
              ),
            ),
            const Divider(height: 16),
            InferenceTerminal(
              isExtracting: widget.isExtracting,
              processLogs: widget.processLogs,
              streamedTokens: widget.streamedTokens,
              tokenCount: widget.tokenCount,
              elapsedSeconds: widget.elapsedSeconds,
            ),
            if (widget.draftEvents.isEmpty && !widget.isExtracting)
              const AgendaEmptyState(
                icon: Icons.event_note,
                title: '暂无提取出的日程草稿',
                subtitle: '请在上方粘贴通知或点击演示图标，或通过系统悬浮窗/划词直接提取',
              )
            else
              ListView.builder(
                shrinkWrap: shrinkWrap,
                physics: shrinkWrap
                    ? const NeverScrollableScrollPhysics()
                    : const ScrollPhysics(),
                itemCount: widget.draftEvents.length,
                itemBuilder: (context, idx) {
                  final ev = widget.draftEvents[idx];
                  return AgendaEventCard(
                    event: ev,
                    isDraft: true,
                    onSyncCalendar: () => widget.onConfirmDraft(ev),
                    onDelete: () => widget.onRemoveDraft(ev),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 760;
        if (isCompact) {
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              _buildInputCard(),
              const SizedBox(height: 12),
              _buildDraftPreviewCard(shrinkWrap: true),
            ],
          );
        } else {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 5,
                  child: SingleChildScrollView(child: _buildInputCard()),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 5,
                  child: SingleChildScrollView(
                    child: _buildDraftPreviewCard(shrinkWrap: true),
                  ),
                ),
              ],
            ),
          );
        }
      },
    );
  }
}
