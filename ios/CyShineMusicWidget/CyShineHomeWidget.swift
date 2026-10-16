// CyShineMusic 桌面小组件。
//
// 数据来源：主 App 写入 App Group 的 UserDefaults（键名与
// packages/music_home_widget/ios/Classes/MusicHomeWidgetPlugin.swift 的
// SharedKey 对齐），以及 App Group 容器里的封面文件。
//
// ⚠️ App Group 需要「App Groups」签名能力。侧载时如果签名用不了该能力，
// 容器读不到东西 —— 这时小组件会显示引导态（打开栖弦播放），而不是空白。
// 这是刻意设计的降级：没有能力也能装、也能看，有能力则功能完整。

import SwiftUI
import UIKit
import WidgetKit

/// 与主 App 侧共享的键名。改这里必须同步改 MusicHomeWidgetPlugin.SharedKey
/// 与 CyShineLiveActivityBridge。
enum CyShineWidgetKey {
    static let appGroup = "group.com.cyshine.music"
    static let title = "widget.title"
    static let artist = "widget.artist"
    static let playing = "widget.playing"
    static let artworkFile = "widget.artworkFile"
    static let updatedAt = "widget.updatedAt"
}

struct CyShineHomeEntry: TimelineEntry {
    let date: Date
    let title: String?
    let artist: String?
    let playing: Bool
    let artwork: UIImage?

    static func placeholder() -> CyShineHomeEntry {
        CyShineHomeEntry(date: Date(), title: nil, artist: nil, playing: false, artwork: nil)
    }
}

struct CyShineHomeProvider: TimelineProvider {
    func placeholder(in context: Context) -> CyShineHomeEntry {
        .placeholder()
    }

    func getSnapshot(in context: Context, completion: @escaping (CyShineHomeEntry) -> Void) {
        completion(Self.readEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CyShineHomeEntry>) -> Void) {
        // 主 App 每次状态变化都会 WidgetCenter.reloadAllTimelines()，
        // 这里的 15 分钟只是兜底刷新。
        let entry = Self.readEntry()
        let next = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    static func readEntry() -> CyShineHomeEntry {
        guard let defaults = UserDefaults(suiteName: CyShineWidgetKey.appGroup) else {
            // 拿不到共享容器 —— 说明签名里没有 App Groups 能力
            return .placeholder()
        }
        let title = defaults.string(forKey: CyShineWidgetKey.title)
        let artist = defaults.string(forKey: CyShineWidgetKey.artist)
        let playing = defaults.bool(forKey: CyShineWidgetKey.playing)
        let artwork: UIImage? = {
            guard let relative = defaults.string(forKey: CyShineWidgetKey.artworkFile),
                  !relative.isEmpty,
                  let base = FileManager.default.containerURL(
                    forSecurityApplicationGroupIdentifier: CyShineWidgetKey.appGroup)
            else { return nil }
            return UIImage(contentsOfFile: base.appendingPathComponent(relative).path)
        }()
        let hasTrack = !(title ?? "").isEmpty
        return CyShineHomeEntry(
            date: Date(),
            title: hasTrack ? title : nil,
            artist: hasTrack ? artist : nil,
            playing: playing,
            artwork: artwork
        )
    }
}

struct CyShineHomeWidgetView: View {
    let entry: CyShineHomeEntry

    var body: some View {
        HStack(spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 3) {
                if let title = entry.title {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(entry.artist ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Label(
                        entry.playing ? "正在播放" : "已暂停",
                        systemImage: entry.playing ? "waveform" : "pause.fill"
                    )
                    .font(.caption2)
                    .foregroundStyle(entry.playing ? Color.green : Color.secondary)
                    .padding(.top, 1)
                } else {
                    Text("栖弦")
                        .font(.headline)
                    Text("打开 App 播放点什么")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .cyShineWidgetBackground()
    }

    private var artwork: some View {
        Group {
            if let image = entry.artwork {
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
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct CyShineHomeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CyShineHomeWidget", provider: CyShineHomeProvider()) { entry in
            CyShineHomeWidgetView(entry: entry)
        }
        .configurationDisplayName("正在播放")
        .description("显示栖弦当前播放的歌曲与状态。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

/// iOS 17 起 WidgetKit 要求用 `containerBackground` 提供背景；
/// 16.x 上只能用普通的 `background`。这里做一次可用性分支，
/// 让扩展在 16.1 与 17+ 上都能正常渲染。
private extension View {
    @ViewBuilder
    func cyShineWidgetBackground() -> some View {
        let gradient = LinearGradient(
            colors: [
                Color(red: 0.13, green: 0.77, blue: 0.37).opacity(0.22),
                Color.clear,
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        if #available(iOS 17.0, *) {
            containerBackground(for: .widget) { gradient }
        } else {
            background(gradient)
        }
    }
}
