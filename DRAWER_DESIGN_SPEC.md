# 知程客户端 · 自动让位抽屉与底部弹窗设计规范
> **Document**: `DRAWER_DESIGN_SPEC.md`  
> **Version**: 1.0.0  
> **Target Platforms**: Desktop (Windows / macOS / Linux) & Mobile (Android / iOS)  
> **Purpose**: 规范应用内统一的“列表行点击 -> 桌面端右侧滑入且主页面自动让位 / 移动端从底部滑出”交互规范。后续前后端或 AI Agent 进行页面重构、添加新配置项或弹窗时，必须严格遵守本规范，杜绝风格碎片化与居中 Modal 弹窗泛滥。

---

## 目录
1. [核心设计理念](#1-核心设计理念)
2. [响应式双模布局架构](#2-响应式双模布局架构)
3. [触发列表项规范（Compact Param Tile）](#3-触发列表项规范compact-param-tile)
4. [桌面端右侧抽屉规范（Desktop Drawer）](#4-桌面端右侧抽屉规范desktop-drawer)
5. [移动端底部弹窗规范（Mobile Bottom Sheet）](#5-移动端底部弹窗规范mobile-bottom-sheet)
6. [统一头部与表单内容规范（Header & Content Form）](#6-统一头部与表单内容规范header--content-form)
7. [标准核心代码模板（Ready-to-Use Boilerplate）](#7-标准核心代码模板ready-to-use-boilerplate)
8. [与 AI Agent 协作时的沟通约定（Prompting Rules）](#8-与-ai-agent-协作时的沟通约定prompting-rules)

---

## 1. 核心设计理念

传统的居中对话框（`AlertDialog` / `Dialog`）存在以下严重体验弊端：
- **遮挡上下文**：完全盖住页面主体，用户无法在调节参数时参考页面原有配置或数据。
- **视觉割裂**：不同功能弹窗大小不一、操作按钮各异，造成强烈的视觉碎片化。
- **浪费横向空间**：在桌面端宽屏下，空有两侧大面积留白却在屏幕正中间堆砌小弹窗。

**自动让位抽屉（Auto-Yielding Drawer）体系的核心优势**：
1. **主页面自适应避让（Auto-Yielding）**：主视图使用 `Expanded` 包裹，右侧抽屉展开时占用 `380dp`，主页面平滑收缩并自动滚动聚焦至锚点，上下文完整可见。
2. **全行热区与选中高亮**：整个列表行均为点击触发热区，展开时整行呈现轻量主题色背景，状态一目了然。
3. **右侧代码徽章（Value Badge）**：右侧统一采用圆角矩形 Badge，紧凑展现当前配置值或同步状态，去除冗余按钮文字。
4. **跨端自适应形态**：
   - **桌面端（宽屏 `>= 880dp`）**：右侧常驻滑入抽屉（带阴影与分界线），同时主界面左缩。
   - **移动端（窄屏 `< 880dp`）**：底部优雅滑出 BottomSheet（带圆角把手，最大高度限制 `85%`）。

---

## 2. 响应式双模布局架构

```mermaid
flowchart TD
    A["屏幕宽度断点判断 (constraints.maxWidth >= 880dp)"] -->|是 (桌面宽屏)| B["桌面双栏协同布局"]
    A -->|否 (移动端/窄屏)| C["移动端流式布局"]

    subgraph 桌面宽屏架构 [Desktop Wide Mode]
        B --> D["左侧导航/侧边栏 (Optional SideNav)"]
        B --> E["Expanded (主视图 SingleChildScrollView)"]
        B --> F["AnimatedContainer (右侧抽屉 width: 380 / 0)"]
        F --> G["OverflowBox (minWidth: 380, maxWidth: 380)"]
        G --> H["_buildDesktopDrawerContent (统一标题栏 + 表单内容)"]
    end

    subgraph 移动端窄屏架构 [Mobile Narrow Mode]
        C --> I["主视图单列流式滚动"]
        C --> J["showModalBottomSheet (isScrollControlled: true)"]
        J --> K["_buildMobileCustomBottomSheet (最大高度 85% + 顶部圆角 20dp)"]
    end
```

---

## 3. 触发列表项规范（Compact Param Tile）

每一个可展开抽屉的列表项均必须采用 `_buildCompactParamTile` 标准组件构建，禁止各自写裸 `ListTile` 或零散 `InkWell`。

### 3.1 布局与尺寸参数
- **外边距/内边距**：`padding: EdgeInsets.symmetric(horizontal: 16, vertical: 11)`。
- **左侧图标槽宽**：严格固定为 `20dp`（搭配 `const SizedBox(width: 12)` 间距）。
- **文字对齐基线**：主标题与副标题起始 X 坐标严格对齐至 **`48dp`**（`16dp 边距 + 20dp 图标 + 12dp 间距`）。
- **右侧箭头**：统一保留 `Icons.chevron_right`（大小 `18dp`，未激活为 `appColors.textTertiary`，激活时为 `primaryColor`）。

### 3.2 选中状态变化（`isEditing`）
| 属性 | 未激活状态（`isEditing = false`） | 激活展开状态（`isEditing = true`） |
| :--- | :--- | :--- |
| **行背景色** | `Colors.transparent` | `primaryColor.withValues(alpha: 0.08)`（过渡 180ms） |
| **主标题字色** | `appColors.textPrimary` (13.5dp, w600) | `primaryColor` (13.5dp, w600) |
| **副标题字色** | `appColors.textSecondary` (11.5dp) | `primaryColor.withValues(alpha: 0.8)` (11.5dp) |
| **右侧 Badge 背景** | `appColors.surfaceLow` | `primaryColor.withValues(alpha: 0.16)` |
| **右侧 Badge 边框** | `appColors.borderSubtle` (0.8dp) | `primaryColor` (0.8dp) |

### 3.3 右侧 Badge 规范（Value Badge）
Badge 位于主文本区右侧、箭头左侧，统一使用圆角矩形容器：
- **容器参数**：`padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3)`，`borderRadius: BorderRadius.circular(6)`。
- **字体样式**：`fontFamily: 'monospace'`，`fontSize: 12.5dp`，`fontWeight: FontWeight.bold`。
- **双态状态 Badge（如同步中心）**：
  - **全部已同步**：绿色背景 `tagWork.withValues(alpha: 0.12)` + 边框 `tagWork` + 内容 `[ ✓ 已同步 ]`。
  - **存在未同步**：红色背景 `error.withValues(alpha: 0.12)` + 边框 `error` + 内容 `[ N 未同步 ]`。

---

## 4. 桌面端右侧抽屉规范（Desktop Drawer）

### 4.1 核心动画与尺寸
- **抽屉宽度**：展开时严格为 **`380dp`**，收起时为 **`0dp`**。
- **动画时长与曲线**：`duration: const Duration(milliseconds: 280)`, `curve: Curves.easeInOutCubic`。
- **背景与分界**：
  - 背景色：`colors.surfaceModal`。
  - 左侧边框：`Border(left: BorderSide(color: colors.borderSubtle, width: isDrawerOpen ? 1 : 0))`。
  - 阴影（仅展开时）：`BoxShadow(color: shadow.withValues(alpha: 0.16), blurRadius: 16, offset: Offset(-4, 0))`。

### 4.2 消除动画过程中的 Flex 溢出（关键技术点）
> [!IMPORTANT]
> 在 `width` 从 `0` 变到 `380` 的 280ms 动画过程中，Flutter 渲染树会尝试以极小宽度（如 `5dp`、`50dp`）渲染抽屉内部的 Row 和 Text，极易触发 `RenderFlex overflowed by N pixels` 报错。
> **必须** 在 `AnimatedContainer` 的子组件外包裹 `OverflowBox`：
> ```dart
> child: isDrawerOpen
>     ? OverflowBox(
>         minWidth: 380,
>         maxWidth: 380,
>         alignment: Alignment.topRight,
>         child: _buildDesktopDrawerContent(primaryColor),
>       )
>     : const SizedBox.shrink(),
> ```

### 4.3 锚点自动居中滚动（Scrollable.ensureVisible）
当抽屉打开时，为防止用户视线迷失，需要自动将触发该抽屉的列表行滚动到视窗舒适位置：
```dart
if (anchorKey?.currentContext != null) {
  Scrollable.ensureVisible(
    anchorKey!.currentContext!,
    duration: const Duration(milliseconds: 280),
    curve: Curves.easeOutCubic,
    alignment: 0.25, // 垂直方向停留在上部 1/4 处
  );
}
```

---

## 5. 移动端底部弹窗规范（Mobile Bottom Sheet）

当设备宽度 `< 880dp`（手机、折叠屏竖屏、小窗模式）时，自动降级为底部抽屉：

- **调用方法**：`showModalBottomSheet(context: context, isScrollControlled: true, backgroundColor: Colors.transparent)`。
- **最大高度约束**：`constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85)`（给顶部保留至少 15% 留白，防止误以为换了全屏页面）。
- **圆角与投影**：`borderRadius: BorderRadius.vertical(top: Radius.circular(20))`。
- **顶部极简把手**：
  - 宽度 `36dp`，高度 `4dp`，圆角 `2dp`，颜色 `colors.borderSubtle`，居中放置。
- **关闭机制**：
  - 点击右上角关闭图标 `Icons.close`。
  - 下拉手势滑动收起（系统原生支持）。
  - 点击外部遮罩区域收起。

---

## 6. 统一头部与表单内容规范（Header & Content Form）

### 6.1 抽屉头部（Drawer Header）
无论桌面端还是移动端，抽屉/弹窗顶部均使用完全一致的头部：
- **左侧图标**：8dp 圆角半透明背景方块（`padding: 6, color: primaryColor.withValues(alpha: 0.12)`）+ 主题色图标（`size: 18`）。
- **标题**：`fontSize: 14.5~15dp`，`fontWeight: FontWeight.bold`，单行截断。
- **副标题**：`fontSize: 11dp`，`color: colors.textSecondary`，简要单行描述该抽屉功能。
- **右上角关闭按钮**：`IconButton(icon: Icon(Icons.close, size: 18), tooltip: '关闭面板')`。
- **底部分割线**：`Divider(height: 1, thickness: 1, color: colors.borderSubtle)`。

### 6.2 抽屉内部表单（Form Content）
- **根布局**：返回 `Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [...])`。
- **避免多层嵌套滚动**：抽屉框架外部已经提供了 `SingleChildScrollView(padding: const EdgeInsets.all(16))`，内部表单组件 **切勿** 自行再嵌套全高度的 `SingleChildScrollView` 或未限制高度的 `ListView`，防止滚动条碰撞或触摸冲突。
- **卡片风格**：使用 `colors.surfaceLow` 背景，`colors.borderSubtle` 0.8dp 细边框，圆角 `10dp`。

---

## 7. 标准核心代码模板（Ready-to-Use Boilerplate）

新页面若要实现自动让位抽屉，可直接按以下骨架搭设：

```dart
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class MyPageWithDrawer extends StatefulWidget {
  const MyPageWithDrawer({super.key});

  @override
  State<MyPageWithDrawer> createState() => _MyPageWithDrawerState();
}

class _MyPageWithDrawerState extends State<MyPageWithDrawer> {
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _anchorKey1 = GlobalKey();

  // 当前激活的抽屉唯一标识（为 null 表示抽屉收起）
  String? _activeDrawerId;
  bool _isWide = false;

  void _closeDrawer() {
    if (_activeDrawerId != null) {
      setState(() => _activeDrawerId = null);
    }
  }

  void _openDrawer({
    required String drawerId,
    required String title,
    required String subtitle,
    required IconData icon,
    GlobalKey? anchorKey,
    required Widget Function(BuildContext context, StateSetter setDrawerState, VoidCallback onClose) formBuilder,
  }) async {
    // 再次点击同一行则折叠关闭
    if (_activeDrawerId == drawerId) {
      _closeDrawer();
      return;
    }

    if (_isWide) {
      setState(() => _activeDrawerId = drawerId);
      if (anchorKey?.currentContext != null) {
        Scrollable.ensureVisible(
          anchorKey!.currentContext!,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          alignment: 0.25,
        );
      }
    } else {
      if (anchorKey?.currentContext != null) {
        Scrollable.ensureVisible(
          anchorKey!.currentContext!,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
          alignment: 0.12,
        );
      }
      setState(() => _activeDrawerId = drawerId);
      await Future.delayed(const Duration(milliseconds: 60));
      if (!mounted) return;

      await showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (ctx) => _buildMobileBottomSheet(
          ctx,
          title: title,
          subtitle: subtitle,
          icon: icon,
          formBuilder: formBuilder,
        ),
      );

      if (mounted) setState(() => _activeDrawerId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final primaryColor = context.colorScheme.primary;

    return LayoutBuilder(
      builder: (context, constraints) {
        _isWide = constraints.maxWidth >= 880;
        final isDrawerOpen = _activeDrawerId != null;

        if (_isWide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1. 主页面区域（Expanded 保证右侧抽屉滑出时自动收缩避让）
              Expanded(
                child: SingleChildScrollView(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  child: _buildMainContent(),
                ),
              ),
              // 2. 桌面端右侧滑出抽屉
              AnimatedContainer(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeInOutCubic,
                width: isDrawerOpen ? 380 : 0,
                decoration: BoxDecoration(
                  color: colors.surfaceModal,
                  border: Border(
                    left: BorderSide(
                      color: colors.borderSubtle,
                      width: isDrawerOpen ? 1 : 0,
                    ),
                  ),
                  boxShadow: isDrawerOpen
                      ? [
                          BoxShadow(
                            color: context.colorScheme.shadow.withValues(alpha: 0.16),
                            blurRadius: 16,
                            offset: const Offset(-4, 0),
                          ),
                        ]
                      : null,
                ),
                clipBehavior: Clip.hardEdge,
                child: isDrawerOpen
                    ? OverflowBox(
                        minWidth: 380,
                        maxWidth: 380,
                        alignment: Alignment.topRight,
                        child: _buildDesktopDrawer(primaryColor, colors),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          );
        } else {
          return SingleChildScrollView(
            controller: _scrollController,
            padding: const EdgeInsets.all(14),
            child: _buildMainContent(),
          );
        }
      },
    );
  }

  Widget _buildMainContent() {
    return Column(
      children: [
        _buildCompactTile(
          key: _anchorKey1,
          icon: Icons.tune,
          title: '示例配置项',
          subtitle: '点击打开右侧让位抽屉并调参',
          badgeText: '4096',
          isEditing: _activeDrawerId == 'exampleParam',
          onTap: () {
            _openDrawer(
              drawerId: 'exampleParam',
              title: '示例配置项详情',
              subtitle: '调节此项参数并实时生效',
              icon: Icons.tune,
              anchorKey: _anchorKey1,
              formBuilder: (ctx, setDrawerState, onClose) {
                return _buildSampleForm(setDrawerState, onClose);
              },
            );
          },
        ),
      ],
    );
  }

  Widget _buildCompactTile({
    Key? key,
    required IconData icon,
    required String title,
    required String subtitle,
    String? badgeText,
    Widget? badgeWidget,
    required VoidCallback onTap,
    bool isEditing = false,
  }) {
    final colors = context.appColors;
    final primaryColor = context.colorScheme.primary;

    return InkWell(
      key: key,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        color: isEditing ? primaryColor.withValues(alpha: 0.08) : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(
          children: [
            Icon(icon, size: 20, color: primaryColor),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: isEditing ? primaryColor : colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: isEditing ? primaryColor.withValues(alpha: 0.8) : colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            if (badgeWidget != null)
              badgeWidget
            else if (badgeText != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: isEditing ? primaryColor.withValues(alpha: 0.16) : colors.surfaceLow,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: isEditing ? primaryColor : colors.borderSubtle,
                    width: 0.8,
                  ),
                ),
                child: Text(
                  badgeText,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12.5,
                    fontWeight: FontWeight.bold,
                    color: isEditing ? primaryColor : colors.textPrimary,
                  ),
                ),
              ),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, size: 18, color: isEditing ? primaryColor : colors.textTertiary),
          ],
        ),
      ),
    );
  }

  Widget _buildDesktopDrawer(Color primaryColor, AppCustomColors colors) {
    return StatefulBuilder(
      builder: (context, setDrawerState) {
        return Container(
          width: 380,
          color: colors.surfaceModal,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 统一顶部 Header
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 10, 12),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: primaryColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(Icons.tune, color: primaryColor, size: 18),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '抽屉详情标题',
                            style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: colors.textPrimary),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '抽屉操作副标题说明',
                            style: TextStyle(fontSize: 11, color: colors.textSecondary),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      tooltip: '关闭面板',
                      onPressed: _closeDrawer,
                    ),
                  ],
                ),
              ),
              Divider(height: 1, thickness: 1, color: colors.borderSubtle),
              // 统一表单内容滚动区
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: _buildSampleForm(setDrawerState, _closeDrawer),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMobileBottomSheet(
    BuildContext ctx, {
    required String title,
    required String subtitle,
    required IconData icon,
    required Widget Function(BuildContext context, StateSetter setSheetState, VoidCallback onClose) formBuilder,
  }) {
    final colors = ctx.appColors;
    final primaryColor = Theme.of(ctx).colorScheme.primary;

    return StatefulBuilder(
      builder: (context, setSheetState) {
        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.85,
          ),
          decoration: BoxDecoration(
            color: colors.surfaceModal,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 移动端顶部小把手
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(top: 8, bottom: 8),
                  decoration: BoxDecoration(
                    color: colors.borderSubtle,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              // 移动端头部 Header
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 10, 10),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: primaryColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(icon, color: primaryColor, size: 18),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: colors.textPrimary)),
                          Text(subtitle, style: TextStyle(fontSize: 11, color: colors.textSecondary)),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: colors.borderSubtle),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: formBuilder(ctx, setSheetState, () => Navigator.of(ctx).pop()),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSampleForm(StateSetter updateState, VoidCallback onClose) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: const [
        Text('表单内容组件（无需外层 SingleChildScrollView）'),
      ],
    );
  }
}
```

---

## 8. 与 AI Agent 协作时的沟通约定（Prompting Rules）

为了保证在后续的迭代编程中，你向 AI Assistant / Agent 发起需求时能够准确复用本规范，请参考以下 **标准化 Prompt 提示语**：

### 8.1 推荐沟通指令模板
> “请将 `[某个功能/某个配置项]` 改造成符合项目根目录 `DRAWER_DESIGN_SPEC.md` 的**自动让位抽屉规范**：
> 1. 列表行采用 `_buildCompactParamTile`，整行可点击，右侧展示 `[参数/状态 Badge]`；
> 2. 桌面端展开右侧 380dp 抽屉，主页面自动让位避让，当前行高亮；
> 3. 移动端展开底部 BottomSheet；
> 4. 抽屉内容与状态通过 `_openCustomOptionDrawer` 统一管理，请确保包裹 `OverflowBox` 避免动画溢出。”

### 8.2 必须检查的 5 条红线（Code Review Checklist）
1. ❌ **严禁使用居中弹窗**：除非是“二次确认销毁/删除”等阻断性提示（`showDialog` + `AlertDialog`），所有功能性、配置性、微调性面板一律使用让位抽屉/底部 Sheet。
2. ❌ **严禁漏掉 `OverflowBox`**：桌面端抽屉的 `AnimatedContainer` 内部必须包裹 `minWidth: 380, maxWidth: 380` 的 `OverflowBox`，否则在动画缩放期间必然报错。
3. ❌ **严禁内部表单自带全高滚动条**：表单组件根节点必须是 `Column`，由外层统一提供 `SingleChildScrollView`。
4. ❌ **严禁硬编码非主题色**：必须使用 `context.appColors` 与 `context.colorScheme`，确保浅色日间与深色暗夜模式自适应切换。
5. ❌ **严禁文字对齐偏移**：触发列表行左侧图标槽必须严格统一为 `20dp`，配合 `12dp` 间隙，确保所有行文字起始 X 坐标稳定在 `48dp`。
