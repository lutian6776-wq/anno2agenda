import 'dart:io';
import 'package:flutter/material.dart';
import '../services/ai_extractor_service.dart';
import '../services/local_model_manager.dart';
import '../theme/app_theme.dart';
import 'app_toast.dart';

/// 端侧 AI 模型管理视图（适配抽屉 Drawer、底部弹窗 BottomSheet 以及弹窗 Dialog）
class ModelCenterView extends StatefulWidget {
  final List<String>? initialActiveLocalModels;
  final String? initialSelectedModelName;
  final Set<String>? initialDownloadedSpecIds;
  final Map<String, double>? initialPartialCacheMB;
  final Map<String, ModelDownloadProgress>? initialActiveDownloads;
  final Future<void> Function()? onRefreshState;
  final ValueChanged<String>? onSelectModel;
  final void Function(AIEngineMode mode)? onEngineModeChanged;
  final void Function(String message)? onShowSnack;
  final VoidCallback? onClose;

  const ModelCenterView({
    super.key,
    this.initialActiveLocalModels,
    this.initialSelectedModelName,
    this.initialDownloadedSpecIds,
    this.initialPartialCacheMB,
    this.initialActiveDownloads,
    this.onRefreshState,
    this.onSelectModel,
    this.onEngineModeChanged,
    this.onShowSnack,
    this.onClose,
  });

  @override
  State<ModelCenterView> createState() => _ModelCenterViewState();
}

class _ModelCenterViewState extends State<ModelCenterView> {
  late List<String> _activeLocalModels;
  String? _selectedModelName;
  late Set<String> _downloadedSpecIds;
  late Map<String, double> _partialCacheMB;
  List<File> _customGgufFiles = [];

  /// 多模型独立下载状态表 (modelId -> ModelDownloadProgress)
  Map<String, ModelDownloadProgress> _activeDownloads = {};

  @override
  void initState() {
    super.initState();
    _activeLocalModels = List.from(widget.initialActiveLocalModels ?? []);
    _selectedModelName = widget.initialSelectedModelName ??
        AIExtractorService.currentPreferredModel ??
        LocalModelManager.currentlyLoadedModelId;
    _downloadedSpecIds = Set.from(widget.initialDownloadedSpecIds ?? []);
    _partialCacheMB = Map.from(widget.initialPartialCacheMB ?? {});

    _activeDownloads = Map.from(LocalModelManager.activeDownloads);
    if (widget.initialActiveDownloads != null) {
      _activeDownloads.addAll(widget.initialActiveDownloads!);
    }

    LocalModelManager.activeDownloadsNotifier.addListener(_onDownloadUpdates);
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
      if (entry.value.isCompleted && (prev == null || !prev.isCompleted)) {
        shouldRefresh = true;
      }
    }

    setState(() {
      _activeDownloads = Map.from(newDownloads);
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

  void _showSnack(String message) {
    if (widget.onShowSnack != null) {
      widget.onShowSnack!(message);
    } else if (mounted) {
      AppToast.show(context, message);
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
    if (widget.onRefreshState != null) {
      await widget.onRefreshState!();
    }
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
    final allFiles = await LocalModelManager.listDownloadedGgufFiles();
    final custom = allFiles.where((f) {
      final name = f.path.split(Platform.pathSeparator).last;
      return !LocalModelManager.catalog.any(
          (s) => s.fileName.toLowerCase() == name.toLowerCase());
    }).toList();

    if (mounted) {
      setState(() {
        _downloadedSpecIds = downloaded;
        _partialCacheMB = partial;
        _activeLocalModels = models;
        _customGgufFiles = custom;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final primaryColor = context.colorScheme.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. 运行环境状态卡
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _activeLocalModels.isNotEmpty
                ? colors.tagWorkContainer
                : colors.surfaceLow,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: _activeLocalModels.isNotEmpty
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
                    _activeLocalModels.isNotEmpty
                        ? Icons.check_circle
                        : Icons.info_outline,
                    size: 18,
                    color: _activeLocalModels.isNotEmpty
                        ? colors.tagWork
                        : primaryColor,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _activeLocalModels.isNotEmpty
                          ? '端侧引擎已挂载 ${_activeLocalModels.length} 个模型'
                          : '本地暂无模型，点击下方一键下载推荐模型',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed: _refresh,
                    icon: Icon(Icons.refresh, size: 14, color: primaryColor),
                    label: Text(
                      '刷新',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: primaryColor,
                      ),
                    ),
                  ),
                ],
              ),
              if (_activeLocalModels.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: _activeLocalModels.map((modelName) {
                    final isCurrent = LocalModelManager.isSameModel(
                      _selectedModelName ?? _activeLocalModels.first,
                      modelName,
                    );
                    final displayName =
                        LocalModelManager.getModelDisplayName(modelName);
                    return InputChip(
                      selected: isCurrent,
                      label: Text(
                        isCurrent ? '当前: $displayName' : displayName,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight:
                              isCurrent ? FontWeight.bold : FontWeight.normal,
                          color: isCurrent ? primaryColor : colors.textPrimary,
                        ),
                      ),
                      backgroundColor: colors.surfaceLow,
                      selectedColor: primaryColor.withValues(alpha: 0.15),
                      side: BorderSide(
                        color: isCurrent ? primaryColor : colors.borderSubtle,
                        width: 0.8,
                      ),
                      onSelected: (_) async {
                        setState(() => _selectedModelName = modelName);
                        widget.onSelectModel?.call(modelName);
                        AIExtractorService.currentPreferredModel = modelName;
                        await LocalModelManager.preloadModel(
                          preferredModelId: modelName,
                        );
                        await _refresh();
                      },
                      deleteIcon: const Icon(
                        Icons.delete_outline,
                        size: 15,
                        color: Colors.redAccent,
                      ),
                      deleteButtonTooltipMessage: '卸载并删除此模型',
                      onDeleted: () async {
                        final ok = await _confirmDeleteDialog(
                          '删除本地模型 $modelName？',
                          '删除后将从本机推理引擎中卸载「$modelName」并释放对应磁盘空间。确定继续吗？',
                        );
                        if (!ok) return;
                        final deleted =
                            await LocalModelManager.deleteRuntimeModel(modelName);
                        await _refresh();
                        _showSnack(deleted
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

        // 2. 官方预置端侧模型库标题
        Row(
          children: [
            Icon(Icons.cloud_download_outlined, size: 16, color: primaryColor),
            const SizedBox(width: 6),
            Text(
              '官方预置端侧模型库',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
                color: colors.textPrimary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),

        // 3. 模型卡片列表
        ...LocalModelManager.catalog.map((spec) {
          final isDownloaded = _downloadedSpecIds.contains(spec.id);
          final partMB = _partialCacheMB[spec.id] ?? 0.0;
          final downloadProgress = _activeDownloads[spec.id];
          final isDownloadingThis = downloadProgress != null &&
              !downloadProgress.isCompleted &&
              downloadProgress.error == null;
          final isCurrent = isDownloaded &&
              LocalModelManager.isSameModel(
                _selectedModelName ?? LocalModelManager.currentlyLoadedModelId,
                spec.id,
              );

          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors.surfaceLow,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isCurrent
                    ? primaryColor.withValues(alpha: 0.6)
                    : colors.borderSubtle,
                width: isCurrent ? 1.4 : 0.8,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        spec.name,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13.5,
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: isCurrent
                            ? primaryColor.withValues(alpha: 0.15)
                            : colors.infoContainer,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        spec.tag,
                        style: TextStyle(
                          fontSize: 10.5,
                          color: primaryColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  spec.description,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: colors.textSecondary,
                    height: 1.35,
                  ),
                ),
                if (isDownloadingThis) ...[
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: downloadProgress.progress,
                      minHeight: 6,
                      backgroundColor: colors.borderSubtle,
                      valueColor: AlwaysStoppedAnimation<Color>(primaryColor),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '下载中: ${(downloadProgress.receivedBytes / (1024 * 1024)).toStringAsFixed(1)} MB / '
                        '${(downloadProgress.totalBytes / (1024 * 1024)).toStringAsFixed(1)} MB '
                        '(${(downloadProgress.progress * 100).toStringAsFixed(0)}%)',
                        style: TextStyle(
                          fontSize: 11,
                          color: primaryColor,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        '${downloadProgress.speedMBps.toStringAsFixed(1)} MB/s',
                        style: TextStyle(
                          fontSize: 11,
                          color: primaryColor,
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
                      fontSize: 11,
                      color: colors.warningContainer,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      if (isDownloadingThis)
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                          ),
                          onPressed: () {
                            LocalModelManager.cancelDownload(spec.id);
                            _showSnack('⏸️ 已暂停 ${spec.name} 下载');
                          },
                          icon: const Icon(Icons.pause, size: 14),
                          label: const Text('暂停', style: TextStyle(fontSize: 11.5)),
                        ),
                      if (!isDownloadingThis &&
                          (isDownloaded || partMB > 0.1))
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            foregroundColor: Colors.red.shade700,
                            side: BorderSide(color: Colors.red.shade300),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
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
                            _showSnack(
                                '🗑️ 已删除 ${spec.name}（释放 ${freedMB.toStringAsFixed(1)} MB 空间）');
                          },
                          icon: const Icon(Icons.delete_outline, size: 14),
                          label: Text(
                            isDownloaded
                                ? '删除'
                                : '清理 (${partMB.toStringAsFixed(0)}MB)',
                            style: const TextStyle(fontSize: 11.5),
                          ),
                        ),
                      if (!isDownloadingThis && isDownloaded)
                        FilledButton.tonalIcon(
                          style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                          ),
                          onPressed: isCurrent
                              ? null
                              : () async {
                                  _showSnack('⏳ 正在挂载并预热模型：${spec.name}...');
                                  await LocalModelManager.preloadModel(
                                    preferredModelId: spec.id,
                                  );
                                  await _refresh();
                                  if (mounted) {
                                    setState(
                                        () => _selectedModelName = spec.id);
                                  }
                                  widget.onSelectModel?.call(spec.id);
                                  widget.onEngineModeChanged?.call(
                                      AIEngineMode.hybridAuto);
                                  AIExtractorService.currentPreferredModel =
                                      spec.id;
                                  _showSnack('✅ 已激活模型：${spec.name}');
                                },
                          icon: Icon(
                            isCurrent ? Icons.check : Icons.bolt,
                            size: 14,
                          ),
                          label: Text(
                            isCurrent ? '当前运行' : '设为默认',
                            style: const TextStyle(fontSize: 11.5),
                          ),
                        ),
                      if (!isDownloadingThis && !isDownloaded)
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                          ),
                          onPressed: () {
                            if (LocalModelManager.isModelDownloading(spec.id)) {
                              return;
                            }
                            _showSnack('🚀 开始高速下载 ${spec.name}...');
                            LocalModelManager.downloadModel(
                              spec: spec,
                              onProgress: (prog) async {
                                if (!mounted) return;
                                if (prog.isCompleted || prog.error != null) {
                                  await _refresh();
                                  if (prog.isCompleted) {
                                    _showSnack('🎉 ${spec.name} 下载并自动挂载完成！');
                                  }
                                }
                              },
                            );
                          },
                          icon: const Icon(Icons.download_rounded, size: 14),
                          label: Text(
                            partMB > 0.1 ? '继续续传' : '高速下载',
                            style: const TextStyle(fontSize: 11.5),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }),

        // 4. 本地扫描检测到的自定义模型
        if (_customGgufFiles.isNotEmpty) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(Icons.folder_open_outlined, size: 16, color: primaryColor),
              const SizedBox(width: 6),
              Text(
                '本地自定义模型 (${_customGgufFiles.length} 个)',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  color: colors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ..._customGgufFiles.map((file) {
            final fileName = file.path.split(Platform.pathSeparator).last;
            final sizeMB = file.lengthSync() / (1024 * 1024);
            final isCurrent = LocalModelManager.isSameModel(
              _selectedModelName,
              fileName,
            );

            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colors.surfaceLow,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isCurrent
                      ? primaryColor.withValues(alpha: 0.6)
                      : colors.borderSubtle,
                  width: isCurrent ? 1.4 : 0.8,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          fileName,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: colors.textPrimary,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: colors.surfaceCard,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: colors.borderSubtle, width: 0.8),
                        ),
                        child: Text(
                          sizeMB >= 1024
                              ? '${(sizeMB / 1024).toStringAsFixed(2)} GB'
                              : '${sizeMB.toStringAsFixed(1)} MB',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: colors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    file.path,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: colors.textTertiary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Wrap(
                      spacing: 6,
                      children: [
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            foregroundColor: Colors.red.shade700,
                            side: BorderSide(color: Colors.red.shade300),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                          ),
                          onPressed: () async {
                            final ok = await _confirmDeleteDialog(
                              '删除模型「$fileName」？',
                              '将从磁盘彻底删除该模型文件（${sizeMB.toStringAsFixed(1)} MB）。',
                            );
                            if (!ok) return;
                            await LocalModelManager.deleteRuntimeModel(fileName);
                            await _refresh();
                            _showSnack('🗑️ 已删除自定义模型：$fileName');
                          },
                          icon: const Icon(Icons.delete_outline, size: 14),
                          label: const Text('删除', style: TextStyle(fontSize: 11.5)),
                        ),
                        if (isCurrent)
                          FilledButton.tonalIcon(
                            style: FilledButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                            ),
                            onPressed: null,
                            icon: const Icon(Icons.check, size: 14),
                            label: const Text('运行中', style: TextStyle(fontSize: 11.5)),
                          )
                        else
                          FilledButton.tonalIcon(
                            style: FilledButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                            ),
                            onPressed: () async {
                              _showSnack('⏳ 正在挂载并预热模型：$fileName...');
                              await LocalModelManager.preloadModel(
                                preferredModelId: fileName,
                              );
                              await _refresh();
                              if (mounted) {
                                setState(() => _selectedModelName = fileName);
                              }
                              widget.onSelectModel?.call(fileName);
                              widget.onEngineModeChanged?.call(
                                  AIEngineMode.hybridAuto);
                              AIExtractorService.currentPreferredModel = fileName;
                              _showSnack('✅ 已切换至本地模型：$fileName');
                            },
                            icon: const Icon(Icons.play_arrow, size: 14),
                            label: const Text('切换运行', style: TextStyle(fontSize: 11.5)),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ],
    );
  }
}

/// 端侧 AI 模型中心对话框包装（兼容历史弹窗调用）
class ModelCenterDialog extends StatelessWidget {
  final List<String>? activeLocalModels;
  final String? selectedModelName;
  final Set<String>? downloadedSpecIds;
  final Map<String, double>? partialCacheMB;
  final ModelDownloadProgress? activeDownload;
  final Map<String, ModelDownloadProgress>? activeDownloads;
  final Future<void> Function()? onRefreshState;
  final ValueChanged<String>? onSelectModel;
  final void Function(AIEngineMode mode)? onEngineModeChanged;
  final void Function(String message)? onShowSnack;

  const ModelCenterDialog({
    super.key,
    this.activeLocalModels,
    this.selectedModelName,
    this.downloadedSpecIds,
    this.partialCacheMB,
    this.activeDownload,
    this.activeDownloads,
    this.onRefreshState,
    this.onSelectModel,
    this.onEngineModeChanged,
    this.onShowSnack,
  });

  static Future<void> show(
    BuildContext context, {
    List<String>? activeLocalModels,
    String? selectedModelName,
    Set<String>? downloadedSpecIds,
    Map<String, double>? partialCacheMB,
    ModelDownloadProgress? activeDownload,
    Map<String, ModelDownloadProgress>? activeDownloads,
    Future<void> Function()? onRefreshState,
    ValueChanged<String>? onSelectModel,
    void Function(AIEngineMode mode)? onEngineModeChanged,
    void Function(String message)? onShowSnack,
  }) {
    return showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.tune_rounded, color: Theme.of(ctx).colorScheme.primary),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                '端侧 AI 模型中心',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 540,
          child: SingleChildScrollView(
            child: ModelCenterView(
              initialActiveLocalModels: activeLocalModels,
              initialSelectedModelName: selectedModelName,
              initialDownloadedSpecIds: downloadedSpecIds,
              initialPartialCacheMB: partialCacheMB,
              initialActiveDownloads: activeDownloads,
              onRefreshState: onRefreshState,
              onSelectModel: onSelectModel,
              onEngineModeChanged: onEngineModeChanged,
              onShowSnack: onShowSnack,
              onClose: () => Navigator.of(ctx).pop(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540, maxHeight: 720),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: ModelCenterView(
            initialActiveLocalModels: activeLocalModels,
            initialSelectedModelName: selectedModelName,
            initialDownloadedSpecIds: downloadedSpecIds,
            initialPartialCacheMB: partialCacheMB,
            initialActiveDownloads: activeDownloads,
            onRefreshState: onRefreshState,
            onSelectModel: onSelectModel,
            onEngineModeChanged: onEngineModeChanged,
            onShowSnack: onShowSnack,
            onClose: () => Navigator.of(context).pop(),
          ),
        ),
      ),
    );
  }
}
