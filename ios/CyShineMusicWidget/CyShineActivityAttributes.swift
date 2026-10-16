// CyShineMusic 灵动岛实时活动 / 桌面小组件 —— 共享的数据契约。
//
// ⚠️ 这个文件会被**同时**编译进两个目标：
//   1. 主 App（ios/Runner/CyShineLiveActivityBridge.swift 要构造它并发起活动）
//   2. Widget Extension（渲染灵动岛与锁屏卡片）
// 两边的 `ActivityAttributes` 类型必须逐字一致，否则系统匹配不到已经启动的活动。
// 所以除了各自的入口文件，业务代码都放在这个共享目录里，由
// tool/build_widget_extension.sh 用同一份源码分别编译。
//
// 设计要点：**不依赖 App Group**。
// 歌名 / 歌手 / 播放位置 / 时长 / 播放状态全部放在 ContentState 里随活动一起传，
// 所以即使签名时拿不到 App Group 权限，灵动岛也照常工作。
// 只有封面图需要共享容器 —— 拿不到就回退到扩展内置的占位图。

import ActivityKit
import Foundation

/// 与主 App `CyShineLiveActivityBridge` 里同名同结构的类型。
/// 改字段时两边必须同步（同一个文件，编译进两个目标，天然一致）。
struct CyShineActivityAttributes: ActivityAttributes {

    /// 随每次更新变化的部分。
    struct ContentState: Codable, Hashable {
        /// 歌名
        var title: String
        /// 歌手
        var artist: String
        /// 当前播放位置（毫秒）
        var positionMs: Int
        /// 总时长（毫秒）；0 表示未知（直播/未解析出时长）
        var durationMs: Int
        /// 是否正在播放
        var playing: Bool
        /// 这份状态生成的时刻（自 1970 起的秒）。
        ///
        /// 进度条不需要主 App 每秒推更新：UI 用 `positionMs + (now - updatedAt)`
        /// 自己推算当前位置，推更新只在换歌 / 播放暂停 / 跳转时发生。
        var updatedAt: TimeInterval
        /// 封面在 App Group 容器里的相对路径；拿不到共享容器时为 nil。
        var artworkPath: String?

        /// 按给定时刻推算播放进度（0...1）。时长未知时返回 nil。
        func progress(at date: Date) -> Double? {
            guard durationMs > 0 else { return nil }
            let elapsed = playing ? date.timeIntervalSince1970 - updatedAt : 0
            let position = Double(positionMs) / 1000 + elapsed
            let total = Double(durationMs) / 1000
            guard total > 0 else { return nil }
            return min(max(position / total, 0), 1)
        }

        /// 按给定时刻推算播放开始的时刻（用于 `ProgressView(timerInterval:)`
        /// 让进度条自己走，不需要主 App 反复推更新）。
        func playbackStart(at date: Date) -> Date {
            let elapsed = playing ? date.timeIntervalSince1970 - updatedAt : 0
            let position = Double(positionMs) / 1000 + elapsed
            return date.addingTimeInterval(-position)
        }

        /// 播放结束时刻，配合 `playbackStart` 给 `ProgressView(timerInterval:)` 用。
        func playbackEnd(at date: Date) -> Date {
            playbackStart(at: date).addingTimeInterval(Double(durationMs) / 1000)
        }

        /// 剩余时间文案，派生态，避免 UI 里重复算。
        func remainingText(at date: Date) -> String {
            guard durationMs > 0 else { return "" }
            let elapsed = playing ? date.timeIntervalSince1970 - updatedAt : 0
            let remain = max(0, Double(durationMs) / 1000 - Double(positionMs) / 1000 - elapsed)
            let total = Int(remain.rounded())
            return String(format: "%d:%02d", total / 60, total % 60)
        }
    }

    /// 整个活动生命周期内不变的部分。
    /// 放在 attributes 里而不是 ContentState，是为了让每次更新的载荷尽量小。
    ///
    /// 注意：**不要把「是否显示进度条」这类信息放这里**。
    /// attributes 在 `Activity.request` 时就固定了，而音频时长往往是播放开始后
    /// 才解析出来的 —— 那样会永远拿不到进度条。UI 直接看 `state.durationMs > 0`。
    var trackId: String
}
