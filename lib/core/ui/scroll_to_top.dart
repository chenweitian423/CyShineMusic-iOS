import 'dart:async';

import 'package:flutter/widgets.dart';

import '../services/app_logger.dart';

/// iOS「点状态栏把列表回到顶部」的支持。
///
/// ## 为什么不用框架自带的实现
///
/// Flutter 在 iOS 上确实处理了这个手势：引擎通过 `flutter/status_bar` 通道发
/// `handleScrollToTop`，`WidgetsBinding` 把它派发给所有
/// [WidgetsBindingObserver.handleStatusBarTap]，`_ScaffoldState` 收到后把
/// PrimaryScrollController 动画到 0。
///
/// 但 `_ScaffoldState.handleStatusBarTap()` 有两道门槛，**在本项目的结构下都过不去**：
///
/// 1. **要求 Scaffold 在屏幕原点 (0,0) 可命中**（框架里的 `_HitTestableAtOrigin`，
///    用来替代早期「在原点发假触摸」的方案）。本项目是
///    `ShellRoute` → `StatefulShellRoute.indexedStack` → 每页各自的 Scaffold，
///    而**外壳那个 Scaffold 也在 (0,0) 画了自己的 statusBar 槽**
///    （一个 opaque 的 MetaData，仅 iOS 存在），命中测试走到它就停了 ——
///    内层页面的 Scaffold 永远轮不到。
/// 2. **要求 PrimaryScrollController 有已挂载的 client**。外壳 Scaffold 拿到的
///    是 ShellRoute 那个路由级的 controller，而页面用的是各自分支路由的，
///    所以 `hasClients` 为 false，即使轮到了也不会滚。
///
/// 结果就是：手势事件其实到了，但**谁的列表都不动** —— 也就是「点状态栏没反应」。
/// 这是 iOS 独有的（Android 上 Scaffold 不注册 statusBar 槽，也没有这个手势），
/// 所以纯 Android 开发时永远发现不了。
///
/// ## 这里的做法
///
/// 自己接 [handleStatusBarTap]，并用滚动通知收集当前存活的 [ScrollPosition]，
/// 回顶时只动「纵向上确实还能往上滚」的那些。不依赖命中测试，也不依赖
/// PrimaryScrollController 的装配方式。
///
/// 挂在 `MaterialApp.builder` 的最外层即可覆盖所有路由（见 `lib/app.dart`）。
class ScrollToTopScope extends StatefulWidget {
  const ScrollToTopScope({super.key, required this.child});

  final Widget child;

  @override
  State<ScrollToTopScope> createState() => ScrollToTopScopeState();
}

class ScrollToTopScopeState extends State<ScrollToTopScope>
    with WidgetsBindingObserver {
  /// 见过、且还活着的纵向滚动位置。
  final Set<ScrollPosition> _positions = <ScrollPosition>{};

  /// 一次回顶的时长，接近 iOS 系统手感。
  static const Duration _duration = Duration(milliseconds: 320);

  /// 集合上限，超过就顺手清理掉已经卸载的位置。
  static const int _maxTracked = 32;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _remember(ScrollMetrics metrics) {
    if (metrics.axis != Axis.vertical) return;
    if (metrics is! ScrollPosition) return;
    _positions.add(metrics);
    if (_positions.length > _maxTracked) {
      _positions.removeWhere((position) => !position.haveDimensions);
    }
  }

  /// 当前需要回顶的位置：纵向、有内容、且确实已经滚下去了。
  List<ScrollPosition> currentTargets() {
    return _positions.where((position) {
      if (!position.haveDimensions || !position.hasPixels) return false;
      if (position.axis != Axis.vertical) return false;
      if (position.maxScrollExtent <= 0) return false;
      return position.pixels > 0;
    }).toList(growable: false);
  }

  /// iOS 点状态栏 → 引擎发 handleScrollToTop → 这里收到。
  @override
  void handleStatusBarTap() {
    super.handleStatusBarTap();
    final targets = currentTargets();
    // 真机上排查「点了没反应」时，这行日志能直接说明事件到底有没有到 Dart 侧。
    unawaited(
      AppLogger.write(
        'scroll',
        'status-bar tap：候选 ${_positions.length} 个，'
            '需要回顶 ${targets.length} 个'
            '（offset=${targets.map((p) => p.pixels.round()).take(4).join('/')}）',
      ),
    );
    for (final position in targets) {
      // 用 animateTo 而不是 jumpTo：与系统行为一致，也不会打断正在进行的惯性滚动。
      position.animateTo(0, duration: _duration, curve: Curves.easeOutCubic);
    }
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollMetricsNotification>(
      // 负责「刚进页面、还没滚动过」的首帧布局：ScrollMetricsNotification
      // 在度量变化时就会发，所以这时也能拿到 position。
      onNotification: (notification) {
        _remember(notification.metrics);
        return false; // 继续冒泡，不影响其它监听者
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          _remember(notification.metrics);
          return false;
        },
        child: widget.child,
      ),
    );
  }
}

/// 给需要「主动回到列表顶部」的地方用（比如将来做「点当前 Tab 回顶」）。
///
/// 拿不到时返回 null，调用方自行兜底。
ScrollToTopScopeState? scrollToTopScopeOf(BuildContext context) {
  return context.findAncestorStateOfType<ScrollToTopScopeState>();
}
