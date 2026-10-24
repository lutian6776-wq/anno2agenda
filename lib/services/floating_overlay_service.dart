import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/agenda_event.dart';
import 'agenda_write_service.dart';
import 'platform_bridge.dart';

/// Flutter 侧全局悬浮窗控制与同步服务
///
/// 封装与 Android 原生 FloatingBubbleService 的状态监听、交互控制及跨进程日程同步。
/// 解耦 UI 页面与底层 PlatformBridge MethodChannel 通信。
class FloatingOverlayService {
  static final FloatingOverlayService _instance =
      FloatingOverlayService._internal();
  factory FloatingOverlayService() => _instance;
  static FloatingOverlayService get instance => _instance;

  FloatingOverlayService._internal();

  /// 悬浮窗运行状态通知器（驱动页面状态栏徽章、设置页开关即时联动）
  final ValueNotifier<bool> isRunningNotifier = ValueNotifier<bool>(false);

  /// 无障碍读屏与截屏助手服务激活状态通知器
  final ValueNotifier<bool> isAccessibilityEnabledNotifier =
      ValueNotifier<bool>(false);

  /// 悬浮窗原地解析出的日程草稿回调（当主工作台需要感知提取结果时）
  void Function(List<AgendaEvent> events, String engineUsed)?
      onOverlayExtractedEvents;

  bool get isRunning => isRunningNotifier.value;
  bool get isAccessibilityEnabled => isAccessibilityEnabledNotifier.value;

  /// 初始化并同步原生悬浮窗与无障碍服务状态
  Future<void> init() async {
    if (!Platform.isAndroid) return;
    await checkRunningState();
    await checkAccessibilityState();
  }

  /// 查询悬浮窗当前运行状态
  Future<bool> checkRunningState() async {
    if (!Platform.isAndroid) {
      isRunningNotifier.value = false;
      return false;
    }
    final running = await PlatformBridge.isFloatingWindowRunning();
    isRunningNotifier.value = running;
    return running;
  }

  /// 查询无障碍识屏与截屏服务当前激活状态
  Future<bool> checkAccessibilityState() async {
    if (!Platform.isAndroid) {
      isAccessibilityEnabledNotifier.value = false;
      return false;
    }
    final enabled = await PlatformBridge.isAccessibilityEnabled();
    isAccessibilityEnabledNotifier.value = enabled;
    return enabled;
  }

  /// 开启或关闭 Android 全局悬浮窗
  Future<Map<String, dynamic>> toggleFloatingWindow(bool enable) async {
    if (!Platform.isAndroid) {
      return {'running': false, 'message': '仅 Android 平台支持全局灵动悬浮窗'};
    }
    final res = await PlatformBridge.toggleAndroidFloatingWindow(enable);
    final running = res['running'] == true;
    isRunningNotifier.value = running;
    return res;
  }

  /// 打开系统无障碍服务设置界面
  Future<void> openAccessibilitySettings() async {
    if (!Platform.isAndroid) return;
    await PlatformBridge.openAccessibilitySettings();
    await checkAccessibilityState();
  }

  /// 处理从 Android 原生悬浮窗写入完成传回的日程数据
  ///
  /// 调用统一的 [AgendaWriteService] 进行去重、入库持久化，使应用内各页面即时感知。
  Future<AgendaBatchWriteResult> handleOverlayWrittenEvents(
    List<AgendaEvent> events,
  ) async {
    debugPrint(
      '[FloatingOverlayService] 收到悬浮窗直写日程通知（共 ${events.length} 项），开始同步至应用本地库...',
    );
    final res = await AgendaWriteService.instance.syncOverlayWrittenEvents(events);
    return res;
  }

  /// 接收悬浮窗原地通过 Flutter AI 引擎提取到的日程节点草稿
  void dispatchOverlayExtractedEvents(
    List<AgendaEvent> events,
    String engineUsed,
  ) {
    onOverlayExtractedEvents?.call(events, engineUsed);
  }
}
