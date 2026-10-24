import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../models/agenda_event.dart';
import '../repositories/agenda_repository.dart';
import '../services/agenda_write_service.dart';
import '../services/ai_extractor_service.dart';
import '../services/floating_overlay_service.dart';
import '../services/lan_sync_service.dart';
import '../services/local_model_manager.dart';
import '../services/platform_bridge.dart';
import '../services/theme_manager.dart';
import '../widgets/engine_status_badge.dart';
import '../widgets/floating_status_badge.dart';
import '../widgets/model_center_dialog.dart';
import '../widgets/quick_capture_bottom_sheet.dart';
import 'ai_extract_page.dart';
import 'my_agenda_page.dart';
import 'settings_page.dart';

/// 主工作台页面（调度顶部状态栏、侧边栏/底栏导航与核心业务交互）
class HomeWorkbenchPage extends StatefulWidget {
  const HomeWorkbenchPage({super.key});

  @override
  State<HomeWorkbenchPage> createState() => _HomeWorkbenchPageState();
}

class _HomeWorkbenchPageState extends State<HomeWorkbenchPage> {
  final TextEditingController _inputController = TextEditingController();
  final TextEditingController _peerIpController = TextEditingController();
  final TextEditingController _llmEndpointController = TextEditingController(
    text: 'http://127.0.0.1:11434/api/generate',
  );

  AIEngineMode _engineMode = AIEngineMode.hybridAuto;
  bool _isExtracting = false;

  /// 解析引擎状态指示器（红 / 黄 / 绿）
  EngineIndicatorState _engineIndicator = EngineIndicatorState.stopped;
  String _engineIndicatorDetail = '引擎未启动 (长按启动)';

  String _lastEngineInfo = '正在检测本机端侧 AI 模型环境...';
  List<String> _localIps = [];

  /// 本机已激活可用的大模型列表
  List<String> _activeLocalModels = [];
  String? _selectedModelName;
  Set<String> _downloadedSpecIds = {};
  Map<String, double> _partialCacheMB = {};
  ModelDownloadProgress? _activeDownload;

  /// 待确认的 AI 提取草稿列表
  final List<AgendaEvent> _draftEvents = [];

  /// 底部 Dock 栏切换（0: AI 提取, 1: 我的日程, 2: 设置）
  int _tabIndex = 0;

  /// 推理过程可视化实况终端状态
  final List<String> _processLogs = [];
  final StringBuffer _streamedTokenBuffer = StringBuffer();
  int _tokenCount = 0;
  Stopwatch? _extractStopwatch;
  Timer? _stopwatchTicker;
  double _elapsedSeconds = 0.0;

  @override
  void initState() {
    super.initState();
    AIExtractorService.currentEngineMode = _engineMode;
    AIExtractorService.currentPreferredModel = _selectedModelName;
    _inputController.text =
        AIExtractPage.sampleAnnouncements.first['text']!;

    LocalModelManager.onModelStatusChanged = (msg) {
      if (!mounted) return;
      _refreshLocalModelState();
      _showSnack(msg);
    };

    _initServices();
  }

  @override
  void dispose() {
    _stopwatchTicker?.cancel();
    _inputController.dispose();
    _peerIpController.dispose();
    _llmEndpointController.dispose();
    super.dispose();
  }

  Future<void> _initServices() async {
    await AgendaRepository.instance.init();

    final ips = await LanSyncService.getLocalIps();
    await LanSyncService.startServer(
      getLocalEvents: () => AgendaRepository.instance.allEvents,
      onRemoteEventsMerged: (merged) async {
        if (!mounted) return;
        await AgendaRepository.instance.mergeRemoteEvents(merged);
        _showSnack('🔄 收到局域网对端同步请求，已合并最新日程（共 ${merged.length} 项）');
      },
    );

    await FloatingOverlayService.instance.init();
    if (mounted) {
      setState(() {
        _localIps = ips;
      });
    }

    await PlatformBridge.initialize(
      onCaptureReceived: (payload) async {
        if (!mounted) return;
        setState(() {
          _inputController.text = payload.text;
          _tabIndex = 0;
        });
        await _runExtraction(sourceType: payload.sourceType);
        if (!mounted) return;
        if (_draftEvents.isNotEmpty) {
          QuickCaptureBottomSheet.show(
            context,
            sourceType: payload.sourceType,
            draftEvents: _draftEvents,
            onConfirmAll: () =>
                _confirmAllDrafts(writeSystemCalendar: true),
          );
        }
      },
      onOverlayExtracted: (events, engineUsed) {
        if (!mounted) return;
        setState(() {
          _draftEvents.clear();
          _draftEvents.addAll(events);
          _lastEngineInfo = '$engineUsed · 悬浮窗原地提取';
        });
      },
      onOverlayExtract: (text, sourceType) =>
          _runExtractionFromOverlay(text, sourceType),
    );

    await ThemeManager.instance.init();
    await _refreshLocalModelState();
  }

  Future<void> _refreshLocalModelState({bool preserveLastEngineInfo = false}) async {
    final downloaded = <String>{};
    final partial = <String, double>{};
    for (final spec in LocalModelManager.catalog) {
      if (await LocalModelManager.isModelDownloaded(spec)) {
        downloaded.add(spec.id);
      }
      final partMB = await LocalModelManager.getPartialDownloadSizeMB(spec);
      if (partMB > 0.1) {
        partial[spec.id] = partMB;
      }
    }
    final models = await LocalModelManager.ensureLocalRuntimeAndListModels();
    final isLoadedInRam = await LocalModelManager.isModelLoadedInRam();
    final isLoading = LocalModelManager.isModelLoading;

    EngineIndicatorState ind;
    String indDetail;

    if (isLoading) {
      ind = EngineIndicatorState.starting;
      indDetail = '正在启动/预热加载权重...';
    } else if (_engineMode == AIEngineMode.builtInRuleEngine) {
      ind = EngineIndicatorState.ready;
      indDetail = '纯端侧极速时空规则引擎 (0延迟就绪)';
    } else if (isLoadedInRam) {
      ind = EngineIndicatorState.ready;
      final cur = LocalModelManager.currentlyLoadedModelId ??
          _selectedModelName ??
          (models.isNotEmpty ? models.first : '已就绪');
      indDetail = '大模型已常驻内存 ($cur)';
    } else if (models.isNotEmpty || downloaded.isNotEmpty) {
      ind = EngineIndicatorState.stopped;
      indDetail = '模型未载入内存 (长按启动预热)';
    } else {
      ind = EngineIndicatorState.stopped;
      indDetail = '大模型未安装 (长按前往下载)';
    }

    if (!mounted) return;
    setState(() {
      _downloadedSpecIds = downloaded;
      _partialCacheMB = partial;
      _activeLocalModels = models;
      _engineIndicator = ind;
      _engineIndicatorDetail = indDetail;

      if (_selectedModelName != null && !models.contains(_selectedModelName)) {
        _selectedModelName = models.isNotEmpty ? models.first : null;
      }
      if (_selectedModelName == null && models.isNotEmpty) {
        _selectedModelName = models.first;
      }
      AIExtractorService.currentPreferredModel = _selectedModelName;
      AIExtractorService.currentEngineMode = _engineMode;

      // 仅在非保留战报且非提取中时，更新待机引擎描述，绝不在未载入时显示“大模型就绪”
      if (!preserveLastEngineInfo && !_isExtracting) {
        _updateStandbyEngineInfo(
          isLoadedInRam: isLoadedInRam,
          models: models,
          downloaded: downloaded,
        );
      }
    });
  }

  void _updateStandbyEngineInfo({
    required bool isLoadedInRam,
    required List<String> models,
    required Set<String> downloaded,
  }) {
    if (_engineMode == AIEngineMode.builtInRuleEngine) {
      _lastEngineInfo = '⚡ 内置纯端侧极速时空规则引擎 (0延迟 · 离线就绪)';
    } else if (isLoadedInRam) {
      final cur = LocalModelManager.currentlyLoadedModelId ??
          _selectedModelName ??
          (models.isNotEmpty ? models.first : '已就绪');
      _lastEngineInfo = '🟢 端侧大模型已常驻内存 ($cur) · 秒级提取就绪';
    } else if (models.isNotEmpty || downloaded.isNotEmpty) {
      final cur = _selectedModelName ??
          (models.isNotEmpty ? models.first : downloaded.first);
      _lastEngineInfo = '⚪ 本地大模型未载入内存 ($cur) · 点击提取自动唤起，或长按右上角预热';
    } else {
      _lastEngineInfo = '⚡ 内置极速时空规则引擎就绪（可在设置一键下载端侧大模型）';
    }
  }

  Future<void> _handleEnginePreload() async {
    if (_engineIndicator == EngineIndicatorState.starting) {
      _showSnack('⏳ 引擎正在加载中，请稍候...');
      return;
    }
    if (_engineIndicator == EngineIndicatorState.ready &&
        await LocalModelManager.isModelLoadedInRam()) {
      _showSnack('🟢 端侧大模型已处于常驻内存就绪状态，无需重复启动');
      return;
    }

    _showSnack('🚀 正在启动并预热端侧大模型权重...');
    setState(() {
      _engineIndicator = EngineIndicatorState.starting;
      _engineIndicatorDetail = '正在预热加载权重至内存/GPU...';
      _lastEngineInfo = '🟡 正在预热加载大模型权重至系统内存/显存...';
    });

    final ok = await LocalModelManager.preloadModel(
      preferredModelId: _selectedModelName,
    );
    await _refreshLocalModelState();
    if (ok) {
      _showSnack('🟢 端侧大模型已成功预热常驻内存！提取时将秒级响应');
    } else {
      _showSnack('⚠️ 启动失败：未检测到本地模型文件，请在设置中下载');
    }
  }

  Future<void> _handleEngineUnload() async {
    await LocalModelManager.unloadModel(reason: '手动释放内存');
    await _refreshLocalModelState();
    _showSnack('🗑️ 大模型已卸载，已释放系统 RAM/显存');
  }

  Future<void> _runExtraction({String sourceType = 'manual'}) async {
    final raw = _inputController.text.trim();
    if (raw.isEmpty) {
      _showSnack('请先输入或粘贴通知文本');
      return;
    }

    _extractStopwatch = Stopwatch()..start();
    _stopwatchTicker?.cancel();
    _stopwatchTicker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted && _isExtracting) {
        setState(() {
          _elapsedSeconds =
              (_extractStopwatch?.elapsedMilliseconds ?? 0) / 1000.0;
        });
      }
    });

    final willUseLlm = _engineMode != AIEngineMode.builtInRuleEngine;
    final isAlreadyLoaded = await LocalModelManager.isModelLoadedInRam();

    setState(() {
      _isExtracting = true;
      _processLogs.clear();
      _streamedTokenBuffer.clear();
      _tokenCount = 0;
      _elapsedSeconds = 0.0;

      // 立即联动同步右上角药丸指示标与右侧状态描述
      if (willUseLlm) {
        if (isAlreadyLoaded) {
          _engineIndicator = EngineIndicatorState.ready;
          _engineIndicatorDetail =
              '端侧模型活跃推理中 (${LocalModelManager.currentlyLoadedModelId ?? _selectedModelName ?? "本地模型"})...';
        } else {
          _engineIndicator = EngineIndicatorState.starting;
          _engineIndicatorDetail = '正在唤起/载入端侧大模型权重...';
        }
        _lastEngineInfo = '⏳ 正在唤起端侧大模型并生成结构化日程...';
      } else {
        _engineIndicator = EngineIndicatorState.ready;
        _engineIndicatorDetail = '纯端侧极速时空规则引擎 (0延迟就绪)';
        _lastEngineInfo = '⚡ 纯端侧极速时空规则引擎正在解析...';
      }
    });

    try {
      String endpoint = _llmEndpointController.text.trim();
      final peerIp = _peerIpController.text.trim();
      if (Platform.isAndroid &&
          peerIp.isNotEmpty &&
          _activeLocalModels.isEmpty) {
        endpoint = 'http://$peerIp:${LanSyncService.defaultPort}/extract';
      }

      final result = await AIExtractorService.extractFromText(
        rawText: raw,
        sourceType: sourceType,
        mode: _engineMode,
        llmEndpoint: endpoint,
        llmModelName: _selectedModelName,
        thinkMode: LocalModelManager.enableThinkMode,
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
              _streamedTokenBuffer.write(token);
              if (tokenCount != null) {
                _tokenCount = tokenCount;
              }
              // 当第一个 Token 出来时，说明大模型已完成加载并在极速流式输出，立即同步指示标为就绪活跃
              if (_engineIndicator != EngineIndicatorState.ready) {
                _engineIndicator = EngineIndicatorState.ready;
                _engineIndicatorDetail =
                    '大模型推理中 (${_selectedModelName ?? "本地大模型"})';
              }
            }
          });
        },
      );

      if (!mounted) return;
      setState(() {
        _draftEvents.clear();
        _draftEvents.addAll(result.events);
        _lastEngineInfo = '${result.engineUsed} · 耗时 ${result.elapsedMs}ms';
      });
      await _refreshLocalModelState(preserveLastEngineInfo: true);
      _showSnack('✨ 成功提取出 ${result.events.length} 个日程节点！');
    } catch (e) {
      if (mounted) {
        setState(() {
          _processLogs.add('[错误] 解析异常: $e');
        });
      }
      _showSnack('解析出错: $e');
      await _refreshLocalModelState();
    } finally {
      _stopwatchTicker?.cancel();
      _extractStopwatch?.stop();
      if (mounted) setState(() => _isExtracting = false);
    }
  }

  /// 供原生悬浮窗直接拉起主程序 LLM 提取管线（与主界面 100% 共享模型配置、进度流与结果状态）
  Future<ExtractionResult> _runExtractionFromOverlay(
    String rawText,
    String sourceType,
  ) async {
    final raw = rawText.trim();
    if (mounted) {
      setState(() {
        _inputController.text = raw;
      });
    }

    _extractStopwatch = Stopwatch()..start();
    _stopwatchTicker?.cancel();
    _stopwatchTicker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted && _isExtracting) {
        setState(() {
          _elapsedSeconds =
              (_extractStopwatch?.elapsedMilliseconds ?? 0) / 1000.0;
        });
      }
    });

    final willUseLlm = _engineMode != AIEngineMode.builtInRuleEngine;
    final isAlreadyLoaded = await LocalModelManager.isModelLoadedInRam();

    if (mounted) {
      setState(() {
        _isExtracting = true;
        _processLogs.clear();
        _streamedTokenBuffer.clear();
        _tokenCount = 0;
        _elapsedSeconds = 0.0;

        if (willUseLlm) {
          if (isAlreadyLoaded) {
            _engineIndicator = EngineIndicatorState.ready;
            _engineIndicatorDetail =
                '端侧模型活跃推理中 (${LocalModelManager.currentlyLoadedModelId ?? _selectedModelName ?? "本地模型"})...';
          } else {
            _engineIndicator = EngineIndicatorState.starting;
            _engineIndicatorDetail = '正在唤起/载入端侧大模型权重...';
          }
          _lastEngineInfo = '⏳ 悬浮窗正在唤起端侧大模型并生成日程...';
        } else {
          _engineIndicator = EngineIndicatorState.ready;
          _engineIndicatorDetail = '纯端侧极速时空规则引擎 (0延迟就绪)';
          _lastEngineInfo = '⚡ 纯端侧极速时空规则引擎正在解析...';
        }
      });
    }

    try {
      String endpoint = _llmEndpointController.text.trim();
      final peerIp = _peerIpController.text.trim();
      if (Platform.isAndroid &&
          peerIp.isNotEmpty &&
          _activeLocalModels.isEmpty) {
        endpoint = 'http://$peerIp:${LanSyncService.defaultPort}/extract';
      }
      AIExtractorService.currentLlmEndpoint = endpoint;

      final result = await AIExtractorService.extractFromText(
        rawText: raw,
        sourceType: sourceType,
        mode: _engineMode,
        llmEndpoint: endpoint,
        llmModelName: _selectedModelName,
        thinkMode: LocalModelManager.enableThinkMode,
        onProgress: ({stepLog, token, tokenCount}) {
          if (tokenCount != null && tokenCount % 6 == 1) {
            PlatformBridge.sendOverlayProgress(
              '🧠 端侧大模型推理中 (已生成 $tokenCount tokens)...',
            );
          } else if (stepLog != null) {
            PlatformBridge.sendOverlayProgress('⏳ $stepLog');
          }

          if (!mounted) return;
          setState(() {
            if (stepLog != null) {
              final now = DateTime.now();
              final timeStr =
                  '${now.hour.toString().padLeft(2, "0")}:${now.minute.toString().padLeft(2, "0")}:${now.second.toString().padLeft(2, "0")}.${(now.millisecond ~/ 100)}';
              _processLogs.add('[$timeStr] $stepLog');
            }
            if (token != null) {
              _streamedTokenBuffer.write(token);
              if (tokenCount != null) {
                _tokenCount = tokenCount;
              }
              if (_engineIndicator != EngineIndicatorState.ready) {
                _engineIndicator = EngineIndicatorState.ready;
                _engineIndicatorDetail =
                    '大模型推理中 (${_selectedModelName ?? "本地大模型"})';
              }
            }
          });
        },
      );

      if (mounted) {
        setState(() {
          _draftEvents.clear();
          _draftEvents.addAll(result.events);
          _lastEngineInfo =
              '${result.engineUsed} · 悬浮窗原地提取 (${result.elapsedMs}ms)';
        });
      }
      await _refreshLocalModelState(preserveLastEngineInfo: true);
      return result;
    } finally {
      _stopwatchTicker?.cancel();
      _extractStopwatch?.stop();
      if (mounted) setState(() => _isExtracting = false);
    }
  }

  Future<void> _confirmDraftEvent(AgendaEvent event) async {
    try {
      final res = await AgendaWriteService.instance.writeEvent(
        event,
        writeToSystemCalendar: true,
      );
      if (res.persisted) {
        setState(() {
          _draftEvents.removeWhere((e) => e.id == event.id);
        });
      }
      if (res.success) {
        _showSnack('✅ ${res.message}');
      } else {
        _showSnack('⚠️ ${res.message}');
      }
    } catch (e) {
      _showSnack('⚠️ 写入日程失败：$e');
    }
  }

  Future<void> _confirmAllDrafts({bool writeSystemCalendar = true}) async {
    final copy = List<AgendaEvent>.from(_draftEvents);
    final batchRes = await AgendaWriteService.instance.writeEvents(
      copy,
      writeToSystemCalendar: writeSystemCalendar,
    );
    for (final res in batchRes.results) {
      if (res.persisted) {
        setState(() {
          _draftEvents.removeWhere((e) => e.id == res.eventId);
        });
      }
    }
    _showSnack(batchRes.summaryMessage);
  }

  void _showModelCenter() {
    ModelCenterDialog.show(
      context,
      activeLocalModels: _activeLocalModels,
      selectedModelName: _selectedModelName,
      downloadedSpecIds: _downloadedSpecIds,
      partialCacheMB: _partialCacheMB,
      activeDownload: _activeDownload,
      onRefreshState: _refreshLocalModelState,
      onSelectModel: (model) {
        AIExtractorService.currentPreferredModel = model;
        setState(() => _selectedModelName = model);
      },
      onEngineModeChanged: (mode) {
        AIExtractorService.currentEngineMode = mode;
        setState(() => _engineMode = mode);
      },
      onShowSnack: _showSnack,
    );
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !Platform.isAndroid,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && Platform.isAndroid) {
          PlatformBridge.moveTaskToBack();
        }
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final isCompact = width < 760;

          return Scaffold(
          appBar: AppBar(
            titleSpacing: 12,
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.auto_awesome,
                  color: Theme.of(context).colorScheme.primary,
                  size: 22,
                ),
                const SizedBox(width: 6),
                const Flexible(
                  child: Text(
                    '知程 Anno2Agenda',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
                  ),
                ),
              ],
            ),
            actions: [
              EngineStatusBadge(
                state: _engineIndicator,
                detail: _engineIndicatorDetail,
                engineMode: _engineMode,
                selectedModelName: _selectedModelName,
                onPreloadModel: _handleEnginePreload,
                onUnloadModel: _handleEngineUnload,
                onNavigateToSettings: () => setState(() => _tabIndex = 2),
              ),
              const SizedBox(width: 6),
              if (Platform.isAndroid) ...[
                ValueListenableBuilder<bool>(
                  valueListenable:
                      FloatingOverlayService.instance.isRunningNotifier,
                  builder: (context, isRunning, _) => FloatingStatusBadge(
                    isRunning: isRunning,
                    onToggle: () async {
                      final res = await FloatingOverlayService.instance
                          .toggleFloatingWindow(!isRunning);
                      if (res['message'] != null) {
                        _showSnack(res['message'].toString());
                      }
                    },
                  ),
                ),
                const SizedBox(width: 10),
              ] else ...[
                const SizedBox(width: 10),
              ],
            ],
          ),
          body: isCompact
              ? _buildCurrentPage()
              : Row(
                  children: [
                    NavigationRail(
                      selectedIndex: _tabIndex,
                      onDestinationSelected: (idx) =>
                          setState(() => _tabIndex = idx),
                      labelType: NavigationRailLabelType.all,
                      destinations: [
                        NavigationRailDestination(
                          icon: Badge(
                            isLabelVisible: _draftEvents.isNotEmpty,
                            label: Text('${_draftEvents.length}'),
                            child: const Icon(Icons.psychology_outlined),
                          ),
                          selectedIcon: const Icon(Icons.psychology),
                          label: const Text('AI 提取'),
                        ),
                        NavigationRailDestination(
                          icon: ValueListenableBuilder<List<AgendaEvent>>(
                            valueListenable:
                                AgendaRepository.instance.eventsNotifier,
                            builder: (context, events, _) => Badge(
                              isLabelVisible: events.isNotEmpty,
                              label: Text('${events.length}'),
                              child: const Icon(Icons.event_note_outlined),
                            ),
                          ),
                          selectedIcon: const Icon(Icons.event_note),
                          label: const Text('我的日程'),
                        ),
                        const NavigationRailDestination(
                          icon: Icon(Icons.settings_outlined),
                          selectedIcon: Icon(Icons.settings),
                          label: Text('设置'),
                        ),
                      ],
                    ),
                    const VerticalDivider(thickness: 1, width: 1),
                    Expanded(child: _buildCurrentPage()),
                  ],
                ),
          bottomNavigationBar: isCompact
              ? NavigationBar(
                  selectedIndex: _tabIndex,
                  onDestinationSelected: (idx) =>
                      setState(() => _tabIndex = idx),
                  destinations: [
                    NavigationDestination(
                      icon: Badge(
                        isLabelVisible: _draftEvents.isNotEmpty,
                        label: Text('${_draftEvents.length}'),
                        child: const Icon(Icons.psychology_outlined),
                      ),
                      selectedIcon: const Icon(Icons.psychology),
                      label: 'AI 提取',
                    ),
                    NavigationDestination(
                      icon: ValueListenableBuilder<List<AgendaEvent>>(
                        valueListenable:
                            AgendaRepository.instance.eventsNotifier,
                        builder: (context, events, _) => Badge(
                          isLabelVisible: events.isNotEmpty,
                          label: Text('${events.length}'),
                          child: const Icon(Icons.event_note_outlined),
                        ),
                      ),
                      selectedIcon: const Icon(Icons.event_note),
                      label: '我的日程',
                    ),
                    const NavigationDestination(
                      icon: Icon(Icons.settings_outlined),
                      selectedIcon: Icon(Icons.settings),
                      label: '设置',
                    ),
                  ],
                )
              : null,
          );
        },
      ),
    );
  }

  Widget _buildCurrentPage() {
    switch (_tabIndex) {
      case 0:
        return AIExtractPage(
          inputController: _inputController,
          engineMode: _engineMode,
          selectedModelName: _selectedModelName,
          llmEndpoint: _llmEndpointController.text,
          lastEngineInfo: _lastEngineInfo,
          draftEvents: _draftEvents,
          isExtracting: _isExtracting,
          processLogs: _processLogs,
          streamedTokens: _streamedTokenBuffer.toString(),
          tokenCount: _tokenCount,
          elapsedSeconds: _elapsedSeconds,
          onRunExtraction: _runExtraction,
          onConfirmDraft: _confirmDraftEvent,
          onConfirmAllDrafts: _confirmAllDrafts,
          onRemoveDraft: (ev) {
            setState(() => _draftEvents.removeWhere((e) => e.id == ev.id));
          },
        );
      case 1:
        return Padding(
          padding: const EdgeInsets.all(12),
          child: MyAgendaPage(
            onNavigateToExtractor: () => setState(() => _tabIndex = 0),
          ),
        );
      case 2:
      default:
        return SettingsPage(
          engineMode: _engineMode,
          onEngineModeChanged: (mode) {
            AIExtractorService.currentEngineMode = mode;
            setState(() => _engineMode = mode);
            _refreshLocalModelState();
          },
          engineIndicatorDetail: _engineIndicatorDetail,
          onPreloadModel: _handleEnginePreload,
          onUnloadModel: _handleEngineUnload,
          onOpenModelCenter: _showModelCenter,
          localIps: _localIps,
          peerIpController: _peerIpController,
          onStateRefreshed: _refreshLocalModelState,
        );
    }
  }
}
