// CyShineMusic 灵动岛（实时活动）+ 锁屏播放卡片。
//
// 灵动岛 UI 本身是 iOS 16.1 起的，但主 App 侧发起/更新/结束活动用的
// `Activity.request/update/end` 与 `ActivityContent` 是 **16.2** 才有的。
// 两端必须同一个门槛，否则会出现「UI 能编译、桥接编译不过」，这里统一按 16.2。
// 主 App 侧由 ios/Runner/CyShineLiveActivityBridge.swift 负责 start/update/end。

import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

/// 打开 App 的深链。主 App 在 Info.plist 里注册了 `cyshinemusic` scheme，
/// AppDelegate / SceneDelegate 收到后转给 Dart 处理（见 CyShineLiveActivityBridge）。
private let openPlayerURL = URL(string: "cyshinemusic://player")
private let toggleURL = URL(string: "cyshinemusic://player/toggle")
private let previousURL = URL(string: "cyshinemusic://player/previous")
private let nextURL = URL(string: "cyshinemusic://player/next")

@available(iOS 16.2, *)
struct CyShineLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CyShineActivityAttributes.self) { context in
            // 锁屏 / 通知中心上的卡片
            CyShineLockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(openPlayerURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    CyShineArtwork(context: context, size: 52, corner: 12)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    CyShineTransportButtons(
                        playing: context.state.playing,
                        tint: .white,
                        iconSize: 20
                    )
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.title.isEmpty ? "未在播放" : context.state.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(context.state.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.durationMs > 0 {
                        CyShineProgressBar(context: context)
                            .padding(.horizontal, 4)
                            .padding(.top, 2)
                    }
                }
            } compactLeading: {
                // 紧凑态左侧：小封面（拿不到就显示音符占位）
                CyShineArtwork(context: context, size: 20, corner: 5)
            } compactTrailing: {
                // 紧凑态右侧：播放中的波形 / 暂停图标
                Image(systemName: context.state.playing ? "waveform" : "pause.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(context.state.playing ? Color.green : Color.secondary)
                    .frame(width: 20)
            } minimal: {
                // 最小态：只放一个音符，避免和别的活动挤在一起时太乱
                Image(systemName: "music.note")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.green)
            }
            .keylineTint(.green)
            .widgetURL(openPlayerURL)
        }
    }
}

// MARK: - 锁屏卡片

@available(iOS 16.2, *)
private struct CyShineLockScreenView: View {
    let context: ActivityViewContext<CyShineActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            CyShineArtwork(context: context, size: 56, corner: 14)

            VStack(alignment: .leading, spacing: 3) {
                Text(context.state.title.isEmpty ? "栖弦" : context.state.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(context.state.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if context.state.durationMs > 0 {
                    HStack(spacing: 6) {
                        CyShineProgressBar(context: context)
                        Text(context.state.remainingText(at: Date()))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            CyShineTransportButtons(
                playing: context.state.playing,
                tint: .white,
                iconSize: 22
            )
        }
        .padding(14)
    }
}

// MARK: - 复用组件

/// 封面。优先读 App Group 共享容器里的文件；拿不到（没开 App Groups 能力）
/// 就回退到扩展内置的占位图 —— 这样灵动岛在两种情况下都好看。
@available(iOS 16.2, *)
private struct CyShineArtwork: View {
    let context: ActivityViewContext<CyShineActivityAttributes>
    let size: CGFloat
    let corner: CGFloat

    private var image: UIImage? {
        CyShineSharedArtwork.load(relativePath: context.state.artworkPath)
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(
                        colors: [Color(red: 0.13, green: 0.77, blue: 0.37),
                                 Color(red: 0.04, green: 0.55, blue: 0.23)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.5, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

/// 进度条。
///
/// 播放中用 `ProgressView(timerInterval:)` —— 系统会自己推进，主 App 不需要
/// 每秒推更新；暂停时退化成静态的 `ProgressView(value:)`。
@available(iOS 16.2, *)
private struct CyShineProgressBar: View {
    let context: ActivityViewContext<CyShineActivityAttributes>

    var body: some View {
        Group {
            if context.state.playing {
                ProgressView(
                    timerInterval: context.state.playbackStart(at: Date())
                        ... context.state.playbackEnd(at: Date()),
                    countsDown: false
                )
            } else {
                ProgressView(value: context.state.progress(at: Date()) ?? 0)
            }
        }
        .progressViewStyle(.linear)
        .tint(.green)
    }
}

/// 上一首 / 播放暂停 / 下一首。
///
/// 用 `Link` 而不是 AppIntent：`Link` 在 iOS 16.2 就能用，点一下会打开 App
/// 并交给 Dart 执行（见 CyShineLiveActivityBridge 对 `cyshinemusic://` 的处理）。
/// 代价是会切到前台 —— 锁屏上本来就有系统播放控件，所以这里够用。
@available(iOS 16.2, *)
private struct CyShineTransportButtons: View {
    let playing: Bool
    let tint: Color
    let iconSize: CGFloat

    var body: some View {
        HStack(spacing: 14) {
            Link(destination: previousURL ?? URL(string: "cyshinemusic://")!) {
                Image(systemName: "backward.fill")
                    .font(.system(size: iconSize * 0.8, weight: .semibold))
            }
            Link(destination: toggleURL ?? URL(string: "cyshinemusic://")!) {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: iconSize, weight: .bold))
            }
            Link(destination: nextURL ?? URL(string: "cyshinemusic://")!) {
                Image(systemName: "forward.fill")
                    .font(.system(size: iconSize * 0.8, weight: .semibold))
            }
        }
        .foregroundStyle(tint)
    }
}

// MARK: - App Group 封面读取

/// 从 App Group 共享容器读封面。容器不可用时返回 nil（不报错）。
enum CyShineSharedArtwork {
    /// 必须与主 App 侧（CyShineLiveActivityBridge / MusicHomeWidgetPlugin）一致。
    static let appGroupIdentifier = "group.com.cyshine.music"

    static func containerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    static func load(relativePath: String?) -> UIImage? {
        guard let relativePath, !relativePath.isEmpty else { return nil }
        guard let base = containerURL() else { return nil }
        return UIImage(contentsOfFile: base.appendingPathComponent(relativePath).path)
    }
}
