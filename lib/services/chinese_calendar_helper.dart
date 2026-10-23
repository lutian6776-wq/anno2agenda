import 'package:lunar/lunar.dart';

/// 中国农历与节假日信息实体
class ChineseCalendarInfo {
  final String lunarText;
  final String? holidayBadge; // "休" (放假) 或 "班" (调休补班)
  final bool isRest;
  final String? fullFestivalName;

  const ChineseCalendarInfo({
    required this.lunarText,
    this.holidayBadge,
    this.isRest = false,
    this.fullFestivalName,
  });
}

/// 农历、节气与法定节假日调休解析引擎
class ChineseCalendarHelper {
  ChineseCalendarHelper._();

  static final Map<String, ChineseCalendarInfo> _cache = {};

  /// 获取指定公历日期的农历、节气、法定节假日调休（休/班）信息
  static ChineseCalendarInfo getInfo(DateTime date) {
    final key = '${date.year}-${date.month}-${date.day}';
    if (_cache.containsKey(key)) {
      return _cache[key]!;
    }

    final s = Solar.fromYmd(date.year, date.month, date.day);
    final l = s.getLunar();

    // 1. 判断国务院法定节假日排班（休 / 班）
    final holiday = HolidayUtil.getHolidayByYmd(date.year, date.month, date.day);
    String? badge;
    bool isRest = false;
    if (holiday != null) {
      if (holiday.isWork()) {
        badge = '班';
        isRest = false;
      } else {
        badge = '休';
        isRest = true;
      }
    }

    String text = '';
    String? fullFestival;

    // 2. 若是法定假日主节日当天且为放假日
    if (holiday != null && !holiday.isWork() && holiday.getTarget() == holiday.getName()) {
      text = holiday.getName();
      fullFestival = holiday.getName();
    }

    // 3. 二十四节气优先显示
    if (text.isEmpty) {
      final jieQi = l.getJieQi();
      if (jieQi.isNotEmpty) {
        text = jieQi;
        fullFestival = jieQi;
      }
    }

    // 4. 传统农历节日（如重阳、端午、中秋、七夕）
    if (text.isEmpty) {
      final lFestivals = l.getFestivals();
      if (lFestivals.isNotEmpty) {
        String name = lFestivals.first;
        fullFestival = name;
        if (name.endsWith('节')) {
          name = name.substring(0, name.length - 1);
        }
        text = name;
      }
    }

    // 5. 核心历史与文化纪念日（辛亥革命、台湾光复、烈士纪念、万圣夜等）
    if (text.isEmpty) {
      final other = s.getOtherFestivals();
      for (final o in other) {
        if (o.contains('辛亥革命')) {
          text = '辛亥革命';
          fullFestival = o;
          break;
        }
        if (o.contains('台湾光复')) {
          text = '台湾光复';
          fullFestival = o;
          break;
        }
        if (o.contains('烈士纪念')) {
          text = '烈士纪念';
          fullFestival = o;
          break;
        }
        if (o.contains('抗美援朝')) {
          text = '台湾光复';
          fullFestival = o;
          break;
        }
      }
    }

    // 6. 知名公历重要节日
    if (text.isEmpty) {
      final sFestivals = s.getFestivals();
      for (final sf in sFestivals) {
        if (sf.contains('国庆')) {
          text = '国庆节';
          fullFestival = sf;
          break;
        }
        if (sf.contains('元旦')) {
          text = '元旦';
          fullFestival = sf;
          break;
        }
        if (sf.contains('万圣')) {
          text = '万圣夜';
          fullFestival = sf;
          break;
        }
        if (sf.contains('教师')) {
          text = '教师节';
          fullFestival = sf;
          break;
        }
        if (sf.contains('青年')) {
          text = '青年节';
          fullFestival = sf;
          break;
        }
        if (sf.contains('儿童')) {
          text = '儿童节';
          fullFestival = sf;
          break;
        }
        if (sf.contains('植树')) {
          text = '植树节';
          fullFestival = sf;
          break;
        }
        if (sf.contains('建军')) {
          text = '建军节';
          fullFestival = sf;
          break;
        }
        if (sf.contains('建党')) {
          text = '建党节';
          fullFestival = sf;
          break;
        }
      }
    }

    // 7. 农历月初（初一）显示农历月份名称（如 "八月"、"九月"）
    if (text.isEmpty && l.getDay() == 1) {
      text = '${l.getMonthInChinese()}月';
    }

    // 8. 默认返回农历日期（初二、初三...十二...廿一）
    if (text.isEmpty) {
      text = l.getDayInChinese();
    }

    final result = ChineseCalendarInfo(
      lunarText: text,
      holidayBadge: badge,
      isRest: isRest,
      fullFestivalName: fullFestival,
    );

    _cache[key] = result;
    return result;
  }
}
