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
    required this.activeDownload,
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
    required ModelDownloadProgress? activeDownload,
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
  ModelDownloadProgress? _activeDownload;

  @override
  void initState() {
    super.initState();
    _activeLocalModels = List.from(widget.activeLocalModels);
    _selectedModelName = widget.selectedModelName;
    _downloadedSpecIds = Set.from(widget.downloadedSpecIds);
    _partialCacheMB = Map.from(widget.partialCacheMB);
    _activeDownload = widget.activeDownload;
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
                final isDownloadingThis = _activeDownload?.modelId == spec.id &&
                    !_activeDownload!.isCompleted &&
                    _activeDownload!.error == null;

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
                        if (isDownloadingThis && _activeDownload != null) ...[
                          const SizedBox(height: 10),
                          LinearProgressIndicator(
                            value: _activeDownload!.progress,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '正在下载: ${(_activeDownload!.receivedBytes / (1024 * 1024)).toStringAsFixed(1)} MB / '
                            '${(_activeDownload!.totalBytes / (1024 * 1024)).toStringAsFixed(1)} MB '
                            '(${(_activeDownload!.progress * 100).toStringAsFixed(1)}% · ${_activeDownload!.speedMBps.toStringAsFixed(1)} MB/s)',
                            style: const TextStyle(
                                fontSize: 12, color: Color(0xFF2563EB)),
                          ),
                        ],
                        if (_activeDownload?.modelId == spec.id &&
                            _activeDownload?.error != null) ...[
                          const SizedBox(height: 6),
                          Text(
                            '提示: ${_activeDownload!.error}',
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
                                    LocalModelManager.cancelDownload();
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
                                    setState(() {
                                      if (_activeDownload?.modelId == spec.id) {
                                        _activeDownload = null;
                                      }
                                    });
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
                                    setState(
                                        () => _selectedModelName = spec.id);
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
                                    LocalModelManager.downloadModel(
                                      spec: spec,
                                      onProgress: (prog) async {
                                        if (!mounted) return;
                                        setState(() => _activeDownload = prog);
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
