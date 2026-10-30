import 'package:flutter/material.dart';

/// 1. 自定义日程专属语义色彩 (ThemeExtension)
/// 支持深浅模式平滑过渡插值
@immutable
class AppCustomColors extends ThemeExtension<AppCustomColors> {
  const AppCustomColors({
    // 画布与微层级
    required this.bgBase,
    required this.surfaceCard,
    required this.surfaceModal,
    required this.surfaceLow,
    required this.borderSubtle,
    required this.warmShadow,
    
    // 文本层级
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    
    // 状态容器色 (用于标签背景)
    required this.warningContainer,
    required this.errorContainer,
    required this.infoContainer,
    required this.successContainer,
    
    // 日程分类标签 (主色与背景容器色)
    required this.tagWork,
    required this.tagWorkContainer,
    required this.tagLife,
    required this.tagLifeContainer,
    required this.tagStudy,
    required this.tagStudyContainer,
    required this.tagSport,
    required this.tagSportContainer,
    required this.tagSocial,
    required this.tagSocialContainer,
    required this.tagRest,
    required this.tagRestContainer,
  });

  final Color bgBase;
  final Color surfaceCard;
  final Color surfaceModal;
  final Color surfaceLow;
  final Color borderSubtle;
  final Color warmShadow;

  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;

  final Color warningContainer;
  final Color errorContainer;
  final Color infoContainer;
  final Color successContainer;

  final Color tagWork;
  final Color tagWorkContainer;
  final Color tagLife;
  final Color tagLifeContainer;
  final Color tagStudy;
  final Color tagStudyContainer;
  final Color tagSport;
  final Color tagSportContainer;
  final Color tagSocial;
  final Color tagSocialContainer;
  final Color tagRest;
  final Color tagRestContainer;

  @override
  AppCustomColors copyWith({
    Color? bgBase,
    Color? surfaceCard,
    Color? surfaceModal,
    Color? surfaceLow,
    Color? borderSubtle,
    Color? warmShadow,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    Color? warningContainer,
    Color? errorContainer,
    Color? infoContainer,
    Color? successContainer,
    Color? tagWork,
    Color? tagWorkContainer,
    Color? tagLife,
    Color? tagLifeContainer,
    Color? tagStudy,
    Color? tagStudyContainer,
    Color? tagSport,
    Color? tagSportContainer,
    Color? tagSocial,
    Color? tagSocialContainer,
    Color? tagRest,
    Color? tagRestContainer,
  }) {
    return AppCustomColors(
      bgBase: bgBase ?? this.bgBase,
      surfaceCard: surfaceCard ?? this.surfaceCard,
      surfaceModal: surfaceModal ?? this.surfaceModal,
      surfaceLow: surfaceLow ?? this.surfaceLow,
      borderSubtle: borderSubtle ?? this.borderSubtle,
      warmShadow: warmShadow ?? this.warmShadow,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textTertiary: textTertiary ?? this.textTertiary,
      warningContainer: warningContainer ?? this.warningContainer,
      errorContainer: errorContainer ?? this.errorContainer,
      infoContainer: infoContainer ?? this.infoContainer,
      successContainer: successContainer ?? this.successContainer,
      tagWork: tagWork ?? this.tagWork,
      tagWorkContainer: tagWorkContainer ?? this.tagWorkContainer,
      tagLife: tagLife ?? this.tagLife,
      tagLifeContainer: tagLifeContainer ?? this.tagLifeContainer,
      tagStudy: tagStudy ?? this.tagStudy,
      tagStudyContainer: tagStudyContainer ?? this.tagStudyContainer,
      tagSport: tagSport ?? this.tagSport,
      tagSportContainer: tagSportContainer ?? this.tagSportContainer,
      tagSocial: tagSocial ?? this.tagSocial,
      tagSocialContainer: tagSocialContainer ?? this.tagSocialContainer,
      tagRest: tagRest ?? this.tagRest,
      tagRestContainer: tagRestContainer ?? this.tagRestContainer,
    );
  }

  @override
  AppCustomColors lerp(ThemeExtension<AppCustomColors>? other, double t) {
    if (other is! AppCustomColors) return this;
    return AppCustomColors(
      bgBase: Color.lerp(bgBase, other.bgBase, t)!,
      surfaceCard: Color.lerp(surfaceCard, other.surfaceCard, t)!,
      surfaceModal: Color.lerp(surfaceModal, other.surfaceModal, t)!,
      surfaceLow: Color.lerp(surfaceLow, other.surfaceLow, t)!,
      borderSubtle: Color.lerp(borderSubtle, other.borderSubtle, t)!,
      warmShadow: Color.lerp(warmShadow, other.warmShadow, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textTertiary: Color.lerp(textTertiary, other.textTertiary, t)!,
      warningContainer: Color.lerp(warningContainer, other.warningContainer, t)!,
      errorContainer: Color.lerp(errorContainer, other.errorContainer, t)!,
      infoContainer: Color.lerp(infoContainer, other.infoContainer, t)!,
      successContainer: Color.lerp(successContainer, other.successContainer, t)!,
      tagWork: Color.lerp(tagWork, other.tagWork, t)!,
      tagWorkContainer: Color.lerp(tagWorkContainer, other.tagWorkContainer, t)!,
      tagLife: Color.lerp(tagLife, other.tagLife, t)!,
      tagLifeContainer: Color.lerp(tagLifeContainer, other.tagLifeContainer, t)!,
      tagStudy: Color.lerp(tagStudy, other.tagStudy, t)!,
      tagStudyContainer: Color.lerp(tagStudyContainer, other.tagStudyContainer, t)!,
      tagSport: Color.lerp(tagSport, other.tagSport, t)!,
      tagSportContainer: Color.lerp(tagSportContainer, other.tagSportContainer, t)!,
      tagSocial: Color.lerp(tagSocial, other.tagSocial, t)!,
      tagSocialContainer: Color.lerp(tagSocialContainer, other.tagSocialContainer, t)!,
      tagRest: Color.lerp(tagRest, other.tagRest, t)!,
      tagRestContainer: Color.lerp(tagRestContainer, other.tagRestContainer, t)!,
    );
  }

  // 浅色模式实例
  static const light = AppCustomColors(
    bgBase: Color(0xFFF8F6F2),
    surfaceCard: Color(0xFFFFFFFF),
    surfaceModal: Color(0xFFFFFFFF),
    surfaceLow: Color(0xFFF0ECE4),
    borderSubtle: Color(0xFFE6E1D8),
    warmShadow: Color(0x0F26302A),
    textPrimary: Color(0xFF1D2622),
    textSecondary: Color(0xFF5A6660),
    textTertiary: Color(0xFF929E97),
    warningContainer: Color(0xFFFDF4E7),
    errorContainer: Color(0xFFFCEEEB),
    infoContainer: Color(0xFFEDF5F8),
    successContainer: Color(0xFFEAF6F1),
    tagWork: Color(0xFF29A37E),
    tagWorkContainer: Color(0xFFEAF6F1),
    tagLife: Color(0xFFD97C5B),
    tagLifeContainer: Color(0xFFFBEFEA),
    tagStudy: Color(0xFFD49B35),
    tagStudyContainer: Color(0xFFFAF3E6),
    tagSport: Color(0xFF749E43),
    tagSportContainer: Color(0xFFF0F5E9),
    tagSocial: Color(0xFF95759E),
    tagSocialContainer: Color(0xFFF4EFF5),
    tagRest: Color(0xFF538C9C),
    tagRestContainer: Color(0xFFECF3F5),
  );

  // 深色模式实例
  static const dark = AppCustomColors(
    bgBase: Color(0xFF121614),
    surfaceCard: Color(0xFF1B221E),
    surfaceModal: Color(0xFF242D28),
    surfaceLow: Color(0xFF171C19),
    borderSubtle: Color(0xFF2B3630),
    warmShadow: Colors.transparent,
    textPrimary: Color(0xFFECF1EE),
    textSecondary: Color(0xFF9EACA5),
    textTertiary: Color(0xFF5B6862),
    warningContainer: Color(0xFF3D2611),
    errorContainer: Color(0xFF3D1B18),
    infoContainer: Color(0xFF172931),
    successContainer: Color(0xFF16352B),
    tagWork: Color(0xFF35B890),
    tagWorkContainer: Color(0xFF16352B),
    tagLife: Color(0xFFE58B6C),
    tagLifeContainer: Color(0xFF381F17),
    tagStudy: Color(0xFFE2B050),
    tagStudyContainer: Color(0xFF352710),
    tagSport: Color(0xFF8CB459),
    tagSportContainer: Color(0xFF212C15),
    tagSocial: Color(0xFFA98CB3),
    tagSocialContainer: Color(0xFF2C2030),
    tagRest: Color(0xFF68A0B0),
    tagRestContainer: Color(0xFF192A30),
  );
}

/// 2. ThemeData 主题配置
class AppTheme {
  static ThemeData get lightTheme {
    final colorScheme = const ColorScheme.light(
      primary: Color(0xFF29A37E),
      onPrimary: Colors.white,
      primaryContainer: Color(0xFFEAF6F1),
      onPrimaryContainer: Color(0xFF1D7F60),
      surface: Color(0xFFFFFFFF),
      onSurface: Color(0xFF1D2622),
      onSurfaceVariant: Color(0xFF5A6660),
      outline: Color(0xFFE6E1D8),
      error: Color(0xFFD65A4F),
      onError: Colors.white,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: AppCustomColors.light.bgBase,
      dividerColor: AppCustomColors.light.borderSubtle,
      cardTheme: CardThemeData(
        color: AppCustomColors.light.surfaceCard,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: AppCustomColors.light.borderSubtle, width: 1),
        ),
      ),
      extensions: const [AppCustomColors.light],
    );
  }

  static ThemeData get darkTheme {
    final colorScheme = const ColorScheme.dark(
      primary: Color(0xFF35B890),
      onPrimary: Color(0xFF121614),
      primaryContainer: Color(0xFF16352B),
      onPrimaryContainer: Color(0xFF8DE8CB),
      surface: Color(0xFF1B221E),
      onSurface: Color(0xFFECF1EE),
      onSurfaceVariant: Color(0xFF9EACA5),
      outline: Color(0xFF2B3630),
      error: Color(0xFFE26D63),
      onError: Color(0xFF121614),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: AppCustomColors.dark.bgBase,
      dividerColor: AppCustomColors.dark.borderSubtle,
      cardTheme: CardThemeData(
        color: AppCustomColors.dark.surfaceCard,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: AppCustomColors.dark.borderSubtle, width: 1),
        ),
      ),
      extensions: const [AppCustomColors.dark],
    );
  }
}

/// 3. BuildContext 主题快捷访问扩展
extension BuildContextThemeX on BuildContext {
  ThemeData get theme => Theme.of(this);
  ColorScheme get colorScheme => Theme.of(this).colorScheme;
  AppCustomColors get appColors =>
      Theme.of(this).extension<AppCustomColors>() ??
      (Theme.of(this).brightness == Brightness.dark
          ? AppCustomColors.dark
          : AppCustomColors.light);
}
