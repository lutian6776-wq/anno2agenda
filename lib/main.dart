import 'package:flutter/material.dart';
import 'pages/home_workbench_page.dart';
import 'services/app_settings_service.dart';
import 'services/theme_manager.dart' hide AppTheme;
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppSettingsService.instance.init();
  await ThemeManager.instance.init();
  runApp(const Anno2AgendaApp());
}

class Anno2AgendaApp extends StatelessWidget {
  const Anno2AgendaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeManager.instance.themeModeNotifier,
      builder: (context, currentThemeMode, _) {
        return MaterialApp(
          title: '知程 Anno2Agenda - 端侧 AI 通知转日程助手',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: currentThemeMode,
          home: const HomeWorkbenchPage(),
        );
      },
    );
  }
}
