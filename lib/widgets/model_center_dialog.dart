import 'package:flutter/material.dart';
import '../services/ai_extractor_service.dart';
import '../services/local_model_manager.dart';

/// 端侧 AI 模型中心（零配置管理弹窗）
class ModelCenterDialog extends StatefulWidget {
  final List<String> activeLocalModels;
  final String? selectedModelName;
  final Set<String> downloadedSpecIds;
  final Map<String, double> partialCacheMB;
  final ModelDownloadProgress? activeDownload;
  final Map<String, ModelDownloadProgress>? activeDownloads;
  final Future<void> Function() onRefreshState;
  final ValueChanged<String> onSelectModel;
  final void Function(AIEngineMode mode) onEngineModeChanged;
  final void Function(String message) onShowSnack;

  const ModelCenterDialog({
    super.key,
    required this.activeLocalModels,
    required this.selectedModelName,
    required this.downloadedSpecIds,
    required this.partialCacheMB,
    this.activeDownload,
    this.activeDownloads,
    required this.onRefreshState,
    required this.onSelectModel,
    required this.onEngineModeChanged,
    required this.onShowSnack,
  });

  static Future<void> show(
    BuildContext context, {
    required List<String> activeLocalModels,
    required String? selectedModelName,
    required Set<String> downloadedSpecIds,
    required Map<String, double> partialCacheMB,
    ModelDownloadProgress? activeDownload,
    Map<String, ModelDownloadProgress>? activeDownloads,
    required Future<void> Function() onRefreshState,
    required ValueChanged<String> onSelectModel,
    required void Function(AIEngineMode mode) onEngineModeChanged,
    required void Function(String message) onShowSnack,
  }) {
    return showDialog(
      context: context,
      builder: (ctx) => ModelCenterDialog(
        activeLocalModels: activeLocalModels,
        selectedModelName: selectedModelName,
        downloadedSpecIds: downloadedSpecIds,
        partialCacheMB: partialCacheMB,
        activeDownload: activeDownload,
        activeDownloads: activeDownloads,
        onRefreshState: onRefreshState,
        onSelectModel: onSelectModel,
        onEngineModeChanged: onEngineModeChanged,
        onShowSnack: onShowSnack,
      ),
    );
  }

  @override
  State<ModelCenterDialog> createState() => _ModelCenterDialogState();
}

class _ModelCenterDialogState extends State<ModelCenterDialog> {
  late List<String> _activeLocalModels;
  String? _selectedModelName;
  late Set<String> _downloadedSpecIds;
  late Map<String, double> _partialCacheMB;

  /// 多模型独立下载状态表 (modelId -> ModelDownloadProgress)
  Map<String, ModelDownloadProgress> _activeDownloads = {};

  @override
  void initState() {
    super.initState();
    _activeLocalModels = List.from(widget.activeLocalModels);
    _selectedModelName = widget.selectedModelName;
    _downloadedSpecIds = Set.from(widget.downloadedSpecIds);
    _partialCacheMB = Map.from(widget.partialCacheMB);

    // 优先从全局管理器同步所有当前正在进行的下载任务状态
    _activeDownloads = Map.from(LocalModelManager.activeDownloads);
    if (widget.activeDownloads != null) {
      _activeDownloads.addAll(widget.activeDownloads!);
    }
    if (widget.activeDownload != null) {
      _activeDownloads[widget.activeDownload!.modelId] = widget.activeDownload!;
    }

    // 注册全局下载进度监听器（切出页面再次打开也能持续实时刷新进度与速度）
    LocalModelManager.activeDownloadsNotifier.addListener(_onDownloadUpdates);

    // 打开窗口时自动异步刷新最新的本地磁盘已下载状态和缓存
    _refresh();
  }

  @override
  void dispose() {
    LocalModelManager.activeDownloadsNotifier.removeListener(_onDownloadUpdates);
    super.dispose();
  }

  void _onDownloadUpdates() {
    if (!mounted) return;
    final newDownloads = LocalModelManager.activeDownloads;
    bool shouldRefresh = false;

    for (final entry in newDownloads.entries) {
      final prev = _activeDownloads[entry.key];
      // 某个模型下载刚刚完成，触发磁盘模型列表刷新
      if (entry.value.isCompleted && (prev == null || !prev.isCompleted)) {
        shouldRefresh = true;
      }
    }

    setState(() {
      _activeDownloads = Map.from(newDownloads);
      // 实时同步未完成的下载体积到缓存字典，避免按钮闪烁
      for (final entry in newDownloads.entries) {
        if (entry.value.receivedBytes > 0) {
          _partialCacheMB[entry.key] =
              entry.value.receivedBytes / (1024 * 1024);
        }
      }
    });

    if (shouldRefresh) {
      _refresh();
    }
  }

  Future<bool> _confirmDeleteDialog(String title, String detail) async {
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(detail),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade600),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    return res == true;
  }

  Future<void> _refresh() async {
    await widget.onRefreshState();
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
    if (mounted) {
      setState(() {
        _downloadedSpecIds = downloaded;
        _partialCacheMB = partial;
        _activeLocalModels = models;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return AlertDialog(
      title: Row(
        children: [
          Icon(
            Icons.memory,
            color: isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB),
          ),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              '端侧 AI 模型中心（零配置管理）',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 运行环境状态卡
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _activeLocalModels.isNotEmpty
                      ? (isDark ? const Color(0xFF064E3B) : Colors.green.shade50)
                      : (isDark ? const Color(0xFF1E3A8A) : Colors.blue.shade50),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          _activeLocalModels.isNotEmpty
                              ? Icons.check_circle
                              : Icons.info_outline,
                          color: _activeLocalModels.isNotEmpty
                              ? (isDark
                                  ? const Color(0xFF34D399)
                                  : Colors.green.shade700)
                              : (isDark
                                  ? const Color(0xFF60A5FA)
                                  : Colors.blue.shade700),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _activeLocalModels.isNotEmpty
                                ? '本机推理引擎运行中（已挂载 ${_activeLocalModels.length} 个模型）'
                                : '无需手动安装命令行工具！点击下方按钮即可高速下载离线模型包。',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: _refresh,
                          child: const Text('刷新检测'),
                        ),
                      ],
                    ),
                    if (_activeLocalModels.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _activeLocalModels.map((modelName) {
                          final isCurrent = (_selectedModelName ??
                                  _activeLocalModels.first) ==
                              modelName;
                          return InputChip(
                            selected: isCurrent,
                            label: Text(
                              isCurrent ? '当前使用: $modelName' : modelName,
                              style: const TextStyle(fontSize: 12),
                            ),
                            onSelected: (_) {
                              setState(() => _selectedModelName = modelName);
                              widget.onSelectModel(modelName);
                            },
                            deleteIcon: const Icon(
                              Icons.delete_outline,
                              size: 16,
                              color: Colors.redAccent,
                            ),
                            deleteButtonTooltipMessage: '卸载并删除此模型',
                            onDeleted: () async {
                              final ok = await _confirmDeleteDialog(
                                '删除本地模型 $modelName？',
                                '删除后将从本机推理引擎中卸载「$modelName」并释放对应磁盘空间。确定继续吗？',
                              );
                              if (!ok) return;
                              final deleted = await LocalModelManager
                                  .deleteRuntimeModel(modelName);
                              await _refresh();
                              widget.onShowSnack(deleted
                                  ? '🗑️ 已卸载并删除模型：$modelName'
                                  : '删除请求已执行，请刷新查看');
                            },
                          );
                        }).toList(),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                '📦 官方预置端侧量化模型库（阿里云魔搭 ModelScope 国内直链）',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
              const SizedBox(height: 8),
              ...LocalModelManager.catalog.map((spec) {
                final isDownloaded = _downloadedSpecIds.contains(spec.id);
                final partMB = _partialCacheMB[spec.id] ?? 0.0;
                final downloadProgress = _activeDownloads[spec.id];
                final isDownloadingThis = downloadProgress != null &&
                    !downloadProgress.isCompleted &&
                    downloadProgress.error == null;

                return Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  elevation: 0,
                  color: isDark
                      ? const Color(0xFF0F172A)
                      : const Color(0xFFF8FAFC),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(
                      color: isDark
                          ? const Color(0xFF334155)
                          : const Color(0xFFE2E8F0),
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
                            Text(
                              spec.name,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFFDBEAFE),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                spec.tag,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFF1D4ED8),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          spec.description,
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade700),
                        ),
                        if (isDownloadingThis) ...[
                          const SizedBox(height: 10),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: LinearProgressIndicator(
                              value: downloadProgress.progress,
                              minHeight: 8,
                              backgroundColor: isDark
                                  ? const Color(0xFF1E293B)
                                  : const Color(0xFFE2E8F0),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                '正在下载: ${(downloadProgress.receivedBytes / (1024 * 1024)).toStringAsFixed(1)} MB / '
                                '${(downloadProgress.totalBytes / (1024 * 1024)).toStringAsFixed(1)} MB '
                                '(${(downloadProgress.progress * 100).toStringAsFixed(1)}%)',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF2563EB),
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              Text(
                                '${downloadProgress.speedMBps.toStringAsFixed(1)} MB/s',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF2563EB),
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ],
                        if (downloadProgress != null &&
                            downloadProgress.error != null) ...[
                          const SizedBox(height: 6),
                          Text(
                            '提示: ${downloadProgress.error}',
                            style: TextStyle(
                                fontSize: 12, color: Colors.orange.shade800),
                          ),
                        ],
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerRight,
                          child: Wrap(
                            alignment: WrapAlignment.end,
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              if (isDownloadingThis)
                                OutlinedButton.icon(
                                  onPressed: () {
                                    LocalModelManager.cancelDownload(spec.id);
                                    widget.onShowSnack(
                                        '⏸️ 已暂停 ${spec.name} 下载');
                                  },
                                  icon: const Icon(Icons.pause, size: 16),
                                  label: const Text('暂停（支持断点续传）'),
                                ),
                              if (!isDownloadingThis &&
                                  (isDownloaded || partMB > 0.1))
                                OutlinedButton.icon(
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.red.shade700,
                                  ),
                                  onPressed: () async {
                                    final ok = await _confirmDeleteDialog(
                                      isDownloaded
                                          ? '删除模型「${spec.name}」？'
                                          : '清理未完成的下载缓存？',
                                      isDownloaded
                                          ? '将从设备中彻底删除 ${spec.fileName} 权重文件，预计释放约 ${spec.expectedSizeMB} MB 空间。'
                                          : '将删除已缓存的 ${partMB.toStringAsFixed(1)} MB 临时文件。',
                                    );
                                    if (!ok) return;
                                    final freedMB = await LocalModelManager
                                        .deleteDownloadedModel(spec);
                                    if (mounted) {
                                      setState(() {
                                        _activeDownloads.remove(spec.id);
                                        _partialCacheMB.remove(spec.id);
                                      });
                                    }
                                    await _refresh();
                                    widget.onShowSnack(
                                        '🗑️ 已删除 ${spec.name}（释放 ${freedMB.toStringAsFixed(1)} MB 空间）');
                                  },
                                  icon: const Icon(Icons.delete_outline,
                                      size: 16),
                                  label: Text(isDownloaded
                                      ? '删除模型'
                                      : '清理缓存 (${partMB.toStringAsFixed(0)}MB)'),
                                ),
                              if (!isDownloadingThis && isDownloaded)
                                FilledButton.tonalIcon(
                                  onPressed: () async {
                                    await LocalModelManager
                                        .registerDownloadedGgufToRuntime(spec);
                                    await _refresh();
                                    if (mounted) {
                                      setState(
                                          () => _selectedModelName = spec.id);
                                    }
                                    widget.onSelectModel(spec.id);
                                    widget.onEngineModeChanged(
                                        AIEngineMode.hybridAuto);
                                    widget.onShowSnack('✅ 已切换并激活模型：${spec.name}');
                                  },
                                  icon: const Icon(Icons.check_circle,
                                      size: 16),
                                  label: const Text('已下载 · 设为默认'),
                                ),
                              if (!isDownloadingThis && !isDownloaded)
                                FilledButton.icon(
                                  onPressed: () {
                                    if (LocalModelManager.isModelDownloading(
                                        spec.id)) {
                                      return;
                                    }
                                    widget.onShowSnack(
                                        '🚀 开始高速下载 ${spec.name}...');
                                    LocalModelManager.downloadModel(
                                      spec: spec,
                                      onProgress: (prog) async {
                                        if (!mounted) return;
                                        if (prog.isCompleted ||
                                            prog.error != null) {
                                          await _refresh();
                                          if (prog.isCompleted) {
                                            widget.onShowSnack(
                                                '🎉 ${spec.name} 下载并自动挂载完成！');
                                          }
                                        }
                                      },
                                    );
                                  },
                                  icon: const Icon(Icons.download_rounded,
                                      size: 16),
                                  label: Text(partMB > 0.1
                                      ? '继续断点续传'
                                      : '一键下载并自动配置'),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('完成'),
        ),
      ],
    );
  }
}
