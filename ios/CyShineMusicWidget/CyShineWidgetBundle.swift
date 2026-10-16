// Widget Extension 的入口。
//
// 一个 WidgetBundle 里可以同时导出多个 widget：实时活动（灵动岛）与桌面小组件。
// 两者在系统「添加小组件」列表里会分别出现。

import SwiftUI
import WidgetKit

@main
struct CyShineMusicWidgetBundle: WidgetBundle {
    var body: some Widget {
        // 桌面小组件
        CyShineHomeWidget()

        // 实时活动（灵动岛 + 锁屏）
        //
        // ⚠️ 这里**刻意不用** `if #available(iOS 16.2, *)` 包一层。
        // WidgetBundleBuilder 的结果构建器对条件分支的支持在不同 Xcode 版本上
        // 行为不一致（早期版本没有 buildIf，会直接编译失败）。
        // 本扩展的 MinimumOSVersion 就是 16.2（见 tool/build_widget_extension.sh
        // 的 -target 与注入的 MinimumOSVersion），低于 16.2 的系统根本不会加载
        // 这个 .appex，所以无条件包含是安全的，也少一个编译期风险点。
        CyShineLiveActivityWidget()
    }
}
