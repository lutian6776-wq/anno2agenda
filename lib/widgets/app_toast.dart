import 'dart:async';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Toast 语义类型，对应不同的主题色彩与反馈图标
enum AppToastType {
  normal,
  success,
  error,
  warning,
  info,
}

/// 内部 Toast 数据模型
class _ToastData {
  final String id;
  final String message;
  final AppToastType type;
  final IconData? customIcon;
  final Duration duration;
  final DateTime createdAt;
  VoidCallback? dismissCallback;

  _ToastData({
    required this.id,
    required this.message,
    required this.type,
    this.customIcon,
    required this.duration,
    required this.createdAt,
  });
}

/// 全局 Toast 管理器（单例模式）
class _ToastManager extends ChangeNotifier {
  static final _ToastManager instance = _ToastManager._();
  _ToastManager._();

  OverlayEntry? _entry;
  final List<_ToastData> _items = [];

  List<_ToastData> get items => List.unmodifiable(_items);

  void show(
    BuildContext context,
    String message, {
    AppToastType? type,
    IconData? icon,
    Duration duration = const Duration(seconds: 2),
  }) {
    if (!context.mounted) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true) ??
        Overlay.maybeOf(context);
    if (overlay == null) return;

    final resolvedType = type ?? AppToast._detectType(message);

    final id =
        '${DateTime.now().microsecondsSinceEpoch}_${_items.length}_${message.hashCode}';
    final item = _ToastData(
      id: id,
      message: message,
      type: resolvedType,
      customIcon: icon,
      duration: duration,
      createdAt: DateTime.now(),
    );

    // 最多同时展示 4 条，超过时让最顶部（最老）的一条提前退出
    if (_items.length >= 4) {
      final oldest = _items.last;
      oldest.dismissCallback?.call();
    }

    // 插入在头部（在 verticalDirection: VerticalDirection.up 的 Column 中，索引 0 位于最底部）
    _items.insert(0, item);
    notifyListeners();

    if (_entry == null || !_entry!.mounted) {
      _entry = OverlayEntry(
        builder: (ctx) => const _ToastOverlayWidget(),
      );
      overlay.insert(_entry!);
    }
  }

  void remove(String id) {
    final index = _items.indexWhere((e) => e.id == id);
    if (index != -1) {
      _items.removeAt(index);
      notifyListeners();
      if (_items.isEmpty) {
        _entry?.remove();
        _entry = null;
      }
    }
  }
}

/// 全局 Toast 浮层容器
class _ToastOverlayWidget extends StatefulWidget {
  const _ToastOverlayWidget();

  @override
  State<_ToastOverlayWidget> createState() => _ToastOverlayWidgetState();
}

class _ToastOverlayWidgetState extends State<_ToastOverlayWidget> {
  @override
  void initState() {
    super.initState();
    _ToastManager.instance.addListener(_onManagerChanged);
  }

  @override
  void dispose() {
    _ToastManager.instance.removeListener(_onManagerChanged);
    super.dispose();
  }

  void _onManagerChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final items = _ToastManager.instance.items;
    final bottomPadding = MediaQuery.of(context).viewInsets.bottom +
        MediaQuery.of(context).padding.bottom +
        24;

    return Positioned(
      left: 20,
      right: 20,
      bottom: bottomPadding,
      child: IgnorePointer(
        ignoring: true, // 不拦截屏幕点击
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            verticalDirection: VerticalDirection.up, // 索引 0 位于最下方，新条目从底部往上顶
            children: items.map((item) {
              return _ToastItemWidget(
                key: ValueKey(item.id),
                item: item,
                onDismissed: () => _ToastManager.instance.remove(item.id),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }
}

/// 单条 Toast 条目视图与进出场动效
class _ToastItemWidget extends StatefulWidget {
  final _ToastData item;
  final VoidCallback onDismissed;

  const _ToastItemWidget({
    super.key,
    required this.item,
    required this.onDismissed,
  });

  @override
  State<_ToastItemWidget> createState() => _ToastItemWidgetState();
}

class _ToastItemWidgetState extends State<_ToastItemWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fadeAnimation;
  late final Animation<Offset> _slideAnimation;
  late final Animation<double> _sizeAnimation;
  Timer? _dismissTimer;
  bool _isDismissing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
      reverseDuration: const Duration(milliseconds: 200),
    );

    _fadeAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
      reverseCurve: Curves.easeIn,
    );

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.4),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    ));

    _sizeAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInOutCubic,
    );

    _controller.addStatusListener((status) {
      if (status == AnimationStatus.dismissed) {
        widget.onDismissed();
      }
    });

    widget.item.dismissCallback = _dismiss;

    _controller.forward();

    // 每条的生命是两秒钟
    _dismissTimer = Timer(widget.item.duration, () {
      _dismiss();
    });
  }

  void _dismiss() {
    if (!mounted || _isDismissing) return;
    _isDismissing = true;
    _dismissTimer?.cancel();
    _controller.reverse();
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appColors = context.appColors;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final item = widget.item;
    final displayText = AppToast._cleanMessage(item.message, item.type);

    IconData? icon = item.customIcon;
    Color? iconColor;
    Color? iconBgColor;

    if (icon == null) {
      switch (item.type) {
        case AppToastType.success:
          icon = Icons.check_rounded;
          iconColor = appColors.tagWork;
          iconBgColor = appColors.successContainer;
          break;
        case AppToastType.error:
          icon = Icons.close_rounded;
          iconColor = context.theme.colorScheme.error;
          iconBgColor = appColors.errorContainer;
          break;
        case AppToastType.warning:
          icon = Icons.priority_high_rounded;
          iconColor = appColors.tagStudy;
          iconBgColor = appColors.warningContainer;
          break;
        case AppToastType.info:
          icon = Icons.info_outline_rounded;
          iconColor = appColors.tagRest;
          iconBgColor = appColors.infoContainer;
          break;
        case AppToastType.normal:
          icon = null;
          break;
      }
    } else {
      iconColor = appColors.tagWork;
      iconBgColor = appColors.successContainer;
    }

    return SizeTransition(
      sizeFactor: _sizeAnimation,
      axis: Axis.vertical,
      alignment: Alignment.bottomCenter,
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: SlideTransition(
          position: _slideAnimation,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width - 40,
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: appColors.surfaceModal,
                  borderRadius: BorderRadius.circular(15), // 边缘半径 15px
                  border: Border.all(
                    color: appColors.borderSubtle,
                    width: 1.0,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: isDark
                          ? const Color(0x66000000)
                          : const Color(0x1426302A),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    if (icon != null) ...[
                      Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          color: iconBgColor,
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: Icon(
                            icon,
                            size: 14,
                            color: iconColor,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],
                    Flexible(
                      child: Text(
                        displayText,
                        style: TextStyle(
                          fontSize: 14, // 字号 14sp
                          color: appColors.textPrimary,
                          fontWeight: FontWeight.w500,
                          height: 1.3,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 外部调用的 Toast 服务类
class AppToast {
  /// 展示一条 Toast 通知
  /// 
  /// - [duration]: 每条默认持续 2 秒钟
  /// - [type]: 语义类型（成功、错误、警告、信息），默认会根据内容自动推断
  static void show(
    BuildContext context,
    String message, {
    AppToastType? type,
    IconData? icon,
    Duration duration = const Duration(seconds: 2),
  }) {
    _ToastManager.instance.show(
      context,
      message,
      type: type,
      icon: icon,
      duration: duration,
    );
  }

  /// 成功类型快捷调用
  static void success(
    BuildContext context,
    String message, {
    Duration duration = const Duration(seconds: 2),
  }) {
    show(context, message, type: AppToastType.success, duration: duration);
  }

  /// 错误类型快捷调用
  static void error(
    BuildContext context,
    String message, {
    Duration duration = const Duration(seconds: 2),
  }) {
    show(context, message, type: AppToastType.error, duration: duration);
  }

  /// 警告类型快捷调用
  static void warning(
    BuildContext context,
    String message, {
    Duration duration = const Duration(seconds: 2),
  }) {
    show(context, message, type: AppToastType.warning, duration: duration);
  }

  /// 信息类型快捷调用
  static void info(
    BuildContext context,
    String message, {
    Duration duration = const Duration(seconds: 2),
  }) {
    show(context, message, type: AppToastType.info, duration: duration);
  }

  /// 根据文案智能推断 Toast 语义类型
  static AppToastType _detectType(String message) {
    if (message.startsWith('✅') ||
        message.contains('成功') ||
        message.contains('已保存') ||
        message.contains('已复制') ||
        message.contains('已恢复') ||
        message.contains('已开启') ||
        message.contains('已关闭') ||
        message.contains('已完成')) {
      return AppToastType.success;
    }
    if (message.startsWith('❌') ||
        message.contains('失败') ||
        message.contains('异常') ||
        message.contains('错误')) {
      return AppToastType.error;
    }
    if (message.startsWith('⚠️') ||
        message.contains('不能为空') ||
        message.contains('请先') ||
        message.contains('为空') ||
        message.contains('警告')) {
      return AppToastType.warning;
    }
    return AppToastType.info;
  }

  /// 清理已转换为原生图标的前置 Emoji，保持统一视觉
  static String _cleanMessage(String msg, AppToastType type) {
    if (msg.startsWith('✅')) {
      return msg.replaceFirst(RegExp(r'^✅\s*'), '');
    }
    if (msg.startsWith('❌')) {
      return msg.replaceFirst(RegExp(r'^❌\s*'), '');
    }
    if (msg.startsWith('⚠️')) {
      return msg.replaceFirst(RegExp(r'^⚠️\s*'), '');
    }
    return msg;
  }
}

/// BuildContext 便捷扩展方法
extension AppToastContextX on BuildContext {
  void showToast(
    String message, {
    AppToastType? type,
    IconData? icon,
    Duration duration = const Duration(seconds: 2),
  }) {
    AppToast.show(this, message, type: type, icon: icon, duration: duration);
  }
}
