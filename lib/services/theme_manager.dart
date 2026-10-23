import 'dart:io';
import 'package:flutter/material.dart';

/// 全局主题管理器（支持浅色、深色、跟随系统，并持久化到本地）
class ThemeManager {
  static final ThemeManager _instance = ThemeManager._internal();
  factory ThemeManager() => _instance;
  static ThemeManager get instance => _instance;

  ThemeManager._internal();

  ThemeMode _themeMode = ThemeMode.system;

  /// 主题模式监听器，供 MaterialApp 响应重建
  final ValueNotifier<ThemeMode> themeModeNotifier =
      ValueNotifier<ThemeMode>(ThemeMode.system);

  ThemeMode get themeMode => _themeMode;

  File? _settingsFile;

  /// 初始化并从本地读取上次保存的主题偏好
  Future<void> init() async {
    try {
      final baseDir = Directory.current.path;
      final file = File('$baseDir/theme_mode.txt');
      _settingsFile = file;

      if (await file.exists()) {
        final content = (await file.readAsString()).trim();
        if (content == 'dark') {
          _themeMode = ThemeMode.dark;
        } else if (content == 'light') {
          _themeMode = ThemeMode.light;
        } else {
          _themeMode = ThemeMode.system;
        }
        themeModeNotifier.value = _themeMode;
      }
    } catch (e) {
      debugPrint('[ThemeManager] 加载本地主题配置异常: $e');
    }
  }

  /// 切换主题模式并持久化
  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) return;
    _themeMode = mode;
    themeModeNotifier.value = mode;

    try {
      final file = _settingsFile ?? File('${Directory.current.path}/theme_mode.txt');
      final modeStr = switch (mode) {
        ThemeMode.dark => 'dark',
        ThemeMode.light => 'light',
        ThemeMode.system => 'system',
      };
      await file.writeAsString(modeStr);
    } catch (e) {
      debugPrint('[ThemeManager] 保存主题配置异常: $e');
    }
  }

  /// 获取当前生效的主题亮度（如果为跟随系统，则检测系统当前真实的深浅色）
  static Brightness getEffectiveBrightness(BuildContext context) {
    final mode = ThemeManager.instance.themeMode;
    if (mode == ThemeMode.dark) return Brightness.dark;
    if (mode == ThemeMode.light) return Brightness.light;
    return MediaQuery.platformBrightnessOf(context);
  }

  /// 判断当前是否处于深色环境
  static bool isDarkMode(BuildContext context) {
    return getEffectiveBrightness(context) == Brightness.dark;
  }
}

/// 统一定义知程应用的主题规范
class AppTheme {
  AppTheme._();

  static const Color primaryBlue = Color(0xFF2563EB);
  static const Color primaryBlueDark = Color(0xFF3B82F6);

  /// 浅色日间主题
  static ThemeData get lightTheme {
    final baseColorScheme = ColorScheme.fromSeed(
      seedColor: primaryBlue,
      brightness: Brightness.light,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: baseColorScheme.copyWith(
        primary: primaryBlue,
        surface: Colors.white,
        onSurface: const Color(0xFF0F172A),
      ),
      scaffoldBackgroundColor: const Color(0xFFF8FAFC),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        foregroundColor: Color(0xFF0F172A),
        elevation: 0,
        scrolledUnderElevation: 1,
        surfaceTintColor: Colors.transparent,
        iconTheme: IconThemeData(color: Color(0xFF0F172A)),
        titleTextStyle: TextStyle(
          color: Color(0xFF0F172A),
          fontSize: 17,
          fontWeight: FontWeight.bold,
        ),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFFE2E8F0)),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFFE2E8F0),
        thickness: 1,
      ),
      navigationRailTheme: const NavigationRailThemeData(
        backgroundColor: Colors.white,
        selectedIconTheme: IconThemeData(color: primaryBlue),
        unselectedIconTheme: IconThemeData(color: Color(0xFF64748B)),
        selectedLabelTextStyle: TextStyle(
          color: primaryBlue,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
        unselectedLabelTextStyle: TextStyle(
          color: Color(0xFF64748B),
          fontSize: 12,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.white,
        indicatorColor: primaryBlue.withValues(alpha: 0.12),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: primaryBlue,
            );
          }
          return const TextStyle(
            fontSize: 12,
            color: Color(0xFF64748B),
          );
        }),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
      ),
    );
  }

  /// 深色夜间主题
  static ThemeData get darkTheme {
    final baseColorScheme = ColorScheme.fromSeed(
      seedColor: primaryBlue,
      brightness: Brightness.dark,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: baseColorScheme.copyWith(
        primary: primaryBlueDark,
        surface: const Color(0xFF0F172A),
        onSurface: Colors.white,
      ),
      scaffoldBackgroundColor: const Color(0xFF0B0F19),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF0F172A),
        foregroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 1,
        surfaceTintColor: Colors.transparent,
        iconTheme: IconThemeData(color: Colors.white),
        titleTextStyle: TextStyle(
          color: Colors.white,
          fontSize: 17,
          fontWeight: FontWeight.bold,
        ),
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFF1E293B),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFF334155)),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFF334155),
        thickness: 1,
      ),
      navigationRailTheme: const NavigationRailThemeData(
        backgroundColor: Color(0xFF0F172A),
        selectedIconTheme: IconThemeData(color: primaryBlueDark),
        unselectedIconTheme: IconThemeData(color: Color(0xFF94A3B8)),
        selectedLabelTextStyle: TextStyle(
          color: primaryBlueDark,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
        unselectedLabelTextStyle: TextStyle(
          color: Color(0xFF94A3B8),
          fontSize: 12,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: const Color(0xFF0F172A),
        indicatorColor: primaryBlueDark.withValues(alpha: 0.2),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: primaryBlueDark,
            );
          }
          return const TextStyle(
            fontSize: 12,
            color: Color(0xFF94A3B8),
          );
        }),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Color(0xFF1E293B),
        surfaceTintColor: Colors.transparent,
      ),
    );
  }
}
